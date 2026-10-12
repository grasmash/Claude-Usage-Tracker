import XCTest
@testable import Claude_Usage

/// The shared login is handed to another account BEFORE the active one hits
/// its limit (operator, 2026-10-12: "switch BEFORE the limit interrupts work";
/// every limit hit today killed in-flight subagents with 429s and the
/// coordinator relaunched ~15 agents by hand).
///
/// Rules pinned here:
/// - trigger: the active account's binding window (session, weekly, and Fable
///   weekly when Fable is in use) is at or above `proactiveThreshold` on a
///   FRESH reading; a stale or presumed reading never triggers a hand-off;
/// - target: fresh, proven, applicable, not dead, not paused, and EVERY
///   binding window at or below `handoffTargetCeiling` — the gap between the
///   two thresholds is the hysteresis, so two accounts cannot ping-pong;
/// - a presumed-free (stale) account is never a hand-off target; it stays a
///   last resort for the 100% path;
/// - once handed off, the same window does not fire again (latched on the
///   window's reset time); a hand-off that did not land is retried;
/// - Fable in use and no account with Fable headroom under the ceiling: no
///   hand-off (the Opus fallback belongs to the real exhaustion, not here).
@MainActor
final class ProactiveHandoffTests: XCTestCase {

    private let now = Date()

    // MARK: - Policy

    func testBindingPercentageIsTheHighestWindowInForce() {
        let u = usage(session: 40, weekly: 91, fable: 20)
        XCTAssertEqual(AutoSwitchPolicy.bindingPercentage(u, usingFable: false, now: now), 91)
        XCTAssertEqual(AutoSwitchPolicy.bindingPercentage(usage(session: 40, weekly: 50, fable: 95), usingFable: true, now: now), 95)
        XCTAssertEqual(AutoSwitchPolicy.bindingPercentage(usage(session: 40, weekly: 50, fable: 95), usingFable: false, now: now), 50,
                       "Fable only binds when Fable is in use")
    }

    func testHandoffTargetNeedsFreshReadingUnderTheCeiling() {
        let active = profile("a", session: 92, weekly: 30)
        let fresh = profile("b", session: 10, weekly: 20)
        let busy = profile("c", session: 80, weekly: 20)                 // under 100 but over the ceiling
        let stale = profile("d", session: 0, weekly: 0, age: 3600)      // presumed, not proven
        XCTAssertEqual(
            AutoSwitchPolicy.handoffTarget(in: [active, busy, stale, fresh], after: active, usingFable: false, now: now)?.id,
            fresh.id)
        XCTAssertNil(AutoSwitchPolicy.handoffTarget(in: [active, busy, stale], after: active, usingFable: false, now: now),
                     "an over-ceiling or stale account is not a hand-off target")
    }

    func testHandoffSkipsDeadAndPausedLogins() {
        let active = profile("a", session: 95, weekly: 30)
        let dead = profile("b", session: 0, weekly: 0)
        var paused = profile("c", session: 0, weekly: 0)
        paused.isPaused = true
        XCTAssertNil(AutoSwitchPolicy.handoffTarget(in: [active, dead, paused], after: active, usingFable: false, now: now,
                                                     isLoginDead: { $0.id == dead.id }))
    }

    func testHandoffUnderFableRequiresFableHeadroom() {
        let active = profile("a", session: 20, weekly: 20, fable: 93)
        let noFable = profile("b", session: 5, weekly: 5, fable: 100)
        let withFable = profile("c", session: 5, weekly: 5, fable: 10)
        XCTAssertNil(AutoSwitchPolicy.handoffTarget(in: [active, noFable], after: active, usingFable: true, now: now))
        XCTAssertEqual(AutoSwitchPolicy.handoffTarget(in: [active, noFable, withFable], after: active, usingFable: true, now: now)?.id,
                       withFable.id)
    }

    // MARK: - Decider

    func testDeciderHandsOffAtTheThresholdOncePerWindow() {
        var decider = AutoSwitchDecider()
        let spare = profile("b", session: 10, weekly: 10)
        var active = profile("a", session: 89, weekly: 30)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .stay)

        active.claudeUsage = usage(session: 91, weekly: 30)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .handOff(spare))
        // Same window, next tick: latched.
        active.claudeUsage = usage(session: 93, weekly: 30)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .stay)
        // The hand-off did not land: retried.
        decider.handoffDidNotLand(active.id)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .handOff(spare))
    }

    func testDeciderDoesNotHandOffOnAStaleReading() {
        var decider = AutoSwitchDecider()
        let spare = profile("b", session: 10, weekly: 10)
        let active = profile("a", session: 96, weekly: 30, age: 1800)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .stay)
    }

    func testDeciderStaysWhenNoHandoffTargetAndLimitNotReached() {
        var decider = AutoSwitchDecider()
        let busy = profile("b", session: 85, weekly: 10)
        let active = profile("a", session: 96, weekly: 30)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, busy], usingFable: false, now: now), .stay,
                       "nothing is wrong yet; the 100% path still has 'busy' as a last resort")
        // ... and at 100% the existing path takes the under-100 account.
        var spent = active
        spent.claudeUsage = usage(session: 100, weekly: 30)
        XCTAssertEqual(decider.decide(current: spent, profiles: [spent, busy], usingFable: false, now: now),
                       .switchTo(busy, withoutFable: false))
    }

    func testDeciderCanBeToldToLeaveProactiveOff() {
        var decider = AutoSwitchDecider(proactive: false)
        let spare = profile("b", session: 10, weekly: 10)
        let active = profile("a", session: 96, weekly: 30)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .stay)
    }

    func testHandoffLatchClearsWhenTheWindowResets() {
        var decider = AutoSwitchDecider()
        let spare = profile("b", session: 10, weekly: 10)
        var active = profile("a", session: 91, weekly: 30, sessionResetIn: 600)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .handOff(spare))
        // The window reset (a new reset time, low usage) and climbed again: a new episode.
        active.claudeUsage = usage(session: 92, weekly: 30, sessionResetIn: 5 * 3600)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .handOff(spare))
    }

    // MARK: - Swap policy: writing under WORKING holders

    func testRefusalAllowsHoldersOnlyWhenSpentOrNearLimit() {
        XCTAssertEqual(MainLoginSwapPolicy.refusal(holders: 2, keychainFingerprint: "k", knownFingerprints: ["k"]),
                       .sessionsRunning(count: 2))
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 2, keychainFingerprint: "k", knownFingerprints: ["k"], keychainLoginSpent: true))
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 2, keychainFingerprint: "k", knownFingerprints: ["k"], keychainLoginNearLimit: true))
        // The compare-and-swap still holds under a hand-off.
        XCTAssertEqual(MainLoginSwapPolicy.refusal(holders: 2, keychainFingerprint: "x", knownFingerprints: ["k"], keychainLoginNearLimit: true),
                       .unknownKeychainLogin)
    }

    func testNearLimitLoginsAreFreshReadingsAtOrAboveTheThreshold() {
        let near = profile("a", session: 91, weekly: 10)
        let staleNear = profile("b", session: 95, weekly: 10, age: 3600)
        let fine = profile("c", session: 50, weekly: 10)
        let fableNear = profile("d", session: 10, weekly: 10, fable: 92)
        XCTAssertEqual(MainLoginSwapPolicy.nearLimitLogins(in: [near, staleNear, fine, fableNear], usingFable: false, now: now),
                       [near.cliCredentialsJSON!])
        XCTAssertEqual(MainLoginSwapPolicy.nearLimitLogins(in: [near, staleNear, fine, fableNear], usingFable: true, now: now),
                       [near.cliCredentialsJSON!, fableNear.cliCredentialsJSON!])
    }

    /// After a hand-off under working holders the replaced login's lineage may
    /// still sit in a session's memory. A holder RELEASES it once that process
    /// has exited (or its pid now names another process), or once it made a
    /// NEW request after the hand-off signal that was answered (Claude Code
    /// re-reads the credentials file's mtime before each request and drops its
    /// cached login when it changed). Until every holder has released it, the
    /// tracker must not refresh that stored login: a refresh then would be a
    /// second use of a single-use refresh token lineage.
    func testHandedOffLineageIsRefreshableOnlyOnceEveryHolderReleasedIt() {
        let t0 = now
        let record = MainLoginSwapPolicy.HandoffRecord(fingerprint: "old", holderPids: [11, 22], at: t0)
        let both: (Int32) -> MainLoginSwapPolicy.HolderProcess = { _ in .running(startedAt: nil) }
        let only22: (Int32) -> MainLoginSwapPolicy.HolderProcess = { $0 == 22 ? .running(startedAt: nil) : .gone }
        // Nobody released: refuse.
        XCTAssertFalse(MainLoginSwapPolicy.lineageReleased(record, process: both, hasSession: { _ in true }, requestedAfter: { _, _ in false }))
        // 11 exited, 22 made an answered request after the touch: released.
        XCTAssertTrue(MainLoginSwapPolicy.lineageReleased(record, process: only22, hasSession: { _ in true }, requestedAfter: { pid, _ in pid == 22 }))
        // 22 has not: still holding.
        XCTAssertFalse(MainLoginSwapPolicy.lineageReleased(record, process: only22, hasSession: { _ in true }, requestedAfter: { _, _ in false }))
        // Time alone releases nothing: a live holder pins the lineage (the safe
        // state). The TTL only prunes records whose holders are all gone.
        let late = t0.addingTimeInterval(MainLoginSwapPolicy.handoffRecordTTL + 1)
        XCTAssertFalse(MainLoginSwapPolicy.isPrunable(record, now: late, process: both))
        XCTAssertFalse(MainLoginSwapPolicy.isPrunable(record, now: late, process: only22))
        XCTAssertTrue(MainLoginSwapPolicy.isPrunable(record, now: late, process: { _ in .gone }))
        XCTAssertFalse(MainLoginSwapPolicy.isPrunable(record, now: t0, process: { _ in .gone }), "not before the TTL")
    }

    /// Without `ps`, every `node` is counted as a holder. One that had no
    /// Claude Code session record at the hand-off and has none now never held
    /// the login: it does not pin the lineage. A real session does.
    func testAHolderThatWasNeverAClaudeSessionDoesNotPinTheLineage() {
        let running: (Int32) -> MainLoginSwapPolicy.HolderProcess = { _ in .running(startedAt: nil) }
        let daemon = MainLoginSwapPolicy.HandoffRecord(fingerprint: "old", holderPids: [11, 22], at: now, holdersWithSession: [22])
        // 11 (an mc daemon) never had a session; 22 (a session) answered a new request.
        XCTAssertTrue(MainLoginSwapPolicy.lineageReleased(daemon, process: running, hasSession: { $0 == 22 }, requestedAfter: { pid, _ in pid == 22 }))
        // 22 has made no new request: it still holds.
        XCTAssertFalse(MainLoginSwapPolicy.lineageReleased(daemon, process: running, hasSession: { $0 == 22 }, requestedAfter: { _, _ in false }))
        // 11 has a session record NOW: it may be a session that started late; it holds.
        XCTAssertFalse(MainLoginSwapPolicy.lineageReleased(daemon, process: running, hasSession: { _ in true }, requestedAfter: { pid, _ in pid == 22 }))
        // A record from a build that did not note sessions: nothing is assumed.
        let legacy = MainLoginSwapPolicy.HandoffRecord(fingerprint: "old", holderPids: [11], at: now)
        XCTAssertFalse(MainLoginSwapPolicy.lineageReleased(legacy, process: running, hasSession: { _ in false }, requestedAfter: { _, _ in false }))
    }

    /// The release proof reads the transcript: a new user entry after the
    /// signal, then an assistant entry. A reply streamed after the signal to a
    /// request sent before it is not one.
    func testTranscriptReleaseProof() {
        let at = now
        func line(_ type: String, _ offset: TimeInterval) -> String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return #"{"type":"\#(type)","timestamp":"\#(f.string(from: at.addingTimeInterval(offset)))"}"#
        }
        XCTAssertFalse(MainLoginSwapPolicy.transcriptShowsAnsweredRequest(after: at, transcript: [line("user", -5), line("assistant", 3)].joined(separator: "\n")))
        XCTAssertFalse(MainLoginSwapPolicy.transcriptShowsAnsweredRequest(after: at, transcript: [line("assistant", -1), line("user", 2)].joined(separator: "\n")))
        XCTAssertTrue(MainLoginSwapPolicy.transcriptShowsAnsweredRequest(after: at, transcript: [line("user", 2), line("assistant", 4)].joined(separator: "\n")))
        // A tail that starts mid-line is fine.
        XCTAssertTrue(MainLoginSwapPolicy.transcriptShowsAnsweredRequest(after: at, transcript: "tial\":1}\n" + [line("user", 2), line("assistant", 4)].joined(separator: "\n")))
    }

    // MARK: - Fixtures

    private func usage(session: Double, weekly: Double, fable: Double = 0,
                       sessionResetIn: TimeInterval = 3600, weeklyResetIn: TimeInterval = 86400,
                       age: TimeInterval = 0) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0, sessionLimit: 100000, sessionPercentage: session,
            sessionResetTime: now.addingTimeInterval(sessionResetIn),
            weeklyTokensUsed: 0, weeklyLimit: 1000000, weeklyPercentage: weekly,
            weeklyResetTime: now.addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0, designWeeklyPercentage: 0, designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0, fableWeeklyPercentage: fable,
            fableWeeklyResetTime: now.addingTimeInterval(weeklyResetIn),
            costUsed: nil, costLimit: nil, costCurrency: nil,
            lastUpdated: now.addingTimeInterval(-age), userTimezone: .current
        )
    }

    private func profile(_ name: String, session: Double, weekly: Double, fable: Double = 0,
                         sessionResetIn: TimeInterval = 3600, age: TimeInterval = 0) -> Profile {
        Profile(
            name: "\(name)@x.com",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"t-\#(name)","refreshToken":"r-\#(name)"}}"#,
            claudeUsage: usage(session: session, weekly: weekly, fable: fable, sessionResetIn: sessionResetIn, age: age)
        )
    }
}
