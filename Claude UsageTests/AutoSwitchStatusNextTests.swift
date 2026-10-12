import XCTest
@testable import Claude_Usage

/// The status line ALWAYS says which profile auto-switch would move to next,
/// and when (operator, 2026-10-12). It used to say so only when stuck, and on
/// 2026-10-11 23:52 it said "next: matt 11:51PM" (free NOW) while the policy
/// refused the switch — two computations that could disagree. The value here
/// comes from the SAME function the switcher uses (`AutoSwitchPolicy`), and a
/// presumed (stale) reading is marked with a trailing `?`.
@MainActor
final class AutoSwitchStatusNextTests: XCTestCase {

    private let now = Date()
    private let et = TimeZone(identifier: "America/New_York")!

    private func line(_ status: AutoSwitchStatus) -> String {
        status.nextLine(timeFormatter: { AutoSwitchStatus.americanTime($0, now: self.now, timeZone: self.et) })
    }

    func testReadyNowNamesTheSwitchersTarget() {
        let active = profile("madmatter", session: 100, weekly: 40)
        let busy = profile("mattgg", session: 90, weekly: 20)
        let spare = profile("littlewing", session: 10, weekly: 5)
        let status = AutoSwitchStatus.build(profiles: [active, busy, spare], activeId: active.id, now: now)
        // The switcher (nextAvailableProfile) picks the first under-limit account in wrap order: mattgg at 90% still counts at 100%.
        let target = AutoSwitchPolicy.switchTarget(in: [active, busy, spare], after: active, usingFable: false, blockedBeyondFable: true, now: now)
        XCTAssertEqual(target, .profile(busy))
        XCTAssertEqual(line(status), "next: mattgg (ready)")
    }

    func testHandoffTargetShowsWhileActiveIsNearItsLimit() {
        let active = profile("madmatter", session: 92, weekly: 40)
        let busy = profile("mattgg", session: 90, weekly: 20)
        let spare = profile("littlewing", session: 10, weekly: 5)
        let status = AutoSwitchStatus.build(profiles: [active, busy, spare], activeId: active.id, now: now)
        XCTAssertEqual(line(status), "next: littlewing (ready)", "near the limit the hand-off target is what fires next")
    }

    func testPresumedTargetIsMarked() {
        let active = profile("madmatter", session: 100, weekly: 40)
        // mattgg: read 4 h ago at 100% with a window that has since passed -> presumed free (the 11:52 PM state).
        let presumed = profile("mattgg", session: 100, weekly: 44, sessionResetIn: -60, age: 4 * 3600)
        let status = AutoSwitchStatus.build(profiles: [active, presumed], activeId: active.id, now: now)
        XCTAssertEqual(line(status), "next: mattgg? (ready)")
        XCTAssertFalse(status.stuck)
    }

    func testLimitedCandidateShowsItsResetTime() {
        let active = profile("madmatter", session: 100, weekly: 40)
        let limited = profile("mattgg", session: 100, weekly: 20, sessionResetIn: 2 * 3600)
        let status = AutoSwitchStatus.build(profiles: [active, limited], activeId: active.id, now: now)
        let expected = AutoSwitchStatus.americanTime(limited.claudeUsage!.sessionResetTime, now: now, timeZone: et)
        XCTAssertEqual(line(status), "next: mattgg · \(expected)")
        XCTAssertTrue(status.stuck)
    }

    func testNoFreshCandidateStillNamesTheEarliestReset() {
        let active = profile("madmatter", session: 100, weekly: 40)
        // Stale readings at 100% weekly with future resets (the midday state): not
        // targets now, but their reset times are recorded facts and the switcher
        // goes to the first one that passes.
        let staleA = profile("littlewing", session: 0, weekly: 100, weeklyResetIn: 3 * 86400, age: 7 * 3600)
        let staleB = profile("goose", session: 0, weekly: 100, weeklyResetIn: 86400, age: 20 * 3600)
        let status = AutoSwitchStatus.build(profiles: [active, staleA, staleB], activeId: active.id, now: now)
        let expected = AutoSwitchStatus.americanTime(staleB.claudeUsage!.weeklyResetTime, now: now, timeZone: et)
        XCTAssertEqual(line(status), "next: goose · \(expected)")
    }

    func testNoOtherAccountAtAll() {
        let active = profile("madmatter", session: 100, weekly: 40)
        let dead = profile("goose", session: 0, weekly: 0)
        let status = AutoSwitchStatus.build(profiles: [active, dead], activeId: active.id, now: now,
                                            isLoginDead: { $0.id == dead.id })
        XCTAssertEqual(line(status), "next: none")
    }

    func testFableBindingIsNamed() {
        let active = profile("madmatter", session: 20, weekly: 20, fable: 100)
        let withFable = profile("littlewing", session: 10, weekly: 10, fable: 10)
        let status = AutoSwitchStatus.build(profiles: [active, withFable], activeId: active.id, usingFable: true, now: now)
        XCTAssertEqual(line(status), "next (Fable): littlewing (ready)")
    }

    func testFableExhaustedEverywhereNamesTheOpusFallbackTarget() {
        let active = profile("madmatter", session: 20, weekly: 20, fable: 100)
        let noFable = profile("littlewing", session: 10, weekly: 10, fable: 100)
        let status = AutoSwitchStatus.build(profiles: [active, noFable], activeId: active.id, usingFable: true, now: now)
        XCTAssertEqual(line(status), "next (Fable): none · opus stays on madmatter")
    }

    func testStateFileCarriesTheLineAndItsParts() {
        let active = profile("madmatter", session: 100, weekly: 40)
        let spare = profile("littlewing", session: 10, weekly: 5)
        let status = AutoSwitchStatus.build(profiles: [active, spare], activeId: active.id, now: now)
        let file = status.stateFileContents(timeFormatter: { AutoSwitchStatus.americanTime($0, now: self.now, timeZone: self.et) })
        XCTAssertTrue(file.contains("\nNEXT=next: littlewing (ready)\n"), file)
        XCTAssertTrue(file.contains("\nNEXT_KIND=ready\n"), file)
        XCTAssertTrue(file.contains("\nNEXT_NAME=littlewing\n"), file)
        XCTAssertTrue(file.contains("\nNEXT_PRESUMED=0\n"), file)
        XCTAssertTrue(file.hasPrefix("STUCK=0\nNEXT_FREE="), "the old keys stay for the installed status line")
    }

    func testAmericanTimeFormat() {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 12; c.hour = 14; c.minute = 40
        let today = Calendar(identifier: .gregorian).date(from: c)!    // interpreted in the current zone; format in ET below
        let cal = { var k = Calendar(identifier: .gregorian); k.timeZone = self.et; return k }()
        let d = cal.date(from: c)!
        XCTAssertEqual(AutoSwitchStatus.americanTime(d, now: d.addingTimeInterval(-3600), timeZone: et), "2:40 PM")
        XCTAssertEqual(AutoSwitchStatus.americanTime(d.addingTimeInterval(5 * 86400), now: d, timeZone: et), "Sat 2:40 PM")
        _ = today
    }

    // MARK: - Fixtures

    private func profile(_ name: String, session: Double, weekly: Double, fable: Double = 0,
                         sessionResetIn: TimeInterval = 3600, weeklyResetIn: TimeInterval = 86400,
                         age: TimeInterval = 0) -> Profile {
        Profile(
            name: "\(name)@x.com",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"t-\#(name)","refreshToken":"r-\#(name)"}}"#,
            claudeUsage: ClaudeUsage(
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
        )
    }
}
