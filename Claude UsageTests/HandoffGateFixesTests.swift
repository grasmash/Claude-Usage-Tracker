import XCTest
@testable import Claude_Usage

/// Fixes from the independent gate on 459c34e (PASS-WITH-FIXES).
@MainActor
final class HandoffGateFixesTests: XCTestCase {

    private let now = Date()

    // MARK: - 1. A refused hand-off does not move the tracker

    /// Scenario: madmatter at 92% with three working sessions; the decider
    /// hands off to littlewing; the swap is REFUSED (the keychain holds a
    /// login the tracker never captured). Before the fix the tracker moved to
    /// littlewing anyway while every session stayed on madmatter: madmatter's
    /// reading went stale (the tracker stopped polling it), and when it hit
    /// 100% nobody switched the stranded sessions, because the tracker thought
    /// it was already on littlewing.
    func testRefusedHandoffKeepsTheTrackerOnTheAccountTheSessionsUse() {
        var decider = AutoSwitchDecider()
        let littlewing = profile("littlewing", session: 10, weekly: 5)
        var madmatter = profile("madmatter", session: 92, weekly: 40)
        XCTAssertEqual(decider.decide(current: madmatter, profiles: [madmatter, littlewing], usingFable: false, now: now),
                       .handOff(littlewing))

        let refusals: [MainLoginSwapPolicy.Refusal] = [
            .unknownKeychainLogin, .processListUnavailable, .keychainUnreadable,
            .untrustedStoredLogin(.unknownProvenance), .notTheSharedLoginEntry(service: "x"),
        ]
        for refusal in refusals {
            XCTAssertFalse(
                AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(.refused(refusal)), selectedBy: "auto", handoff: true),
                "a hand-off refused with \(refusal) must not move the tracker")
        }
        XCTAssertTrue(AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(.applied(racedHolders: 0)), selectedBy: "auto", handoff: true))
        XCTAssertTrue(AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(.alreadyApplied), selectedBy: "auto", handoff: true))
        XCTAssertFalse(AutoSwitchPolicy.activateAfterMainLoginSwitch(.failure(ClaudeCodeError.noProfileCredentials), selectedBy: "auto", handoff: true))

        // The tracker stayed on madmatter, so it keeps reading it; the hand-off
        // did not land, so it is retried next tick ...
        decider.handoffDidNotLand(madmatter.id)
        XCTAssertEqual(decider.decide(current: madmatter, profiles: [madmatter, littlewing], usingFable: false, now: now),
                       .handOff(littlewing), "retried next tick")
        // ... and when madmatter reaches 100% the stranded rescue still fires.
        madmatter.claudeUsage = usage(session: 100, weekly: 40)
        var atLimit = AutoSwitchDecider()
        XCTAssertEqual(atLimit.decide(current: madmatter, profiles: [madmatter, littlewing], usingFable: false, now: now),
                       .switchTo(littlewing, withoutFable: false))
    }

    func testTheHundredPercentPathStillMovesOnARetryableRefusal() {
        // Unchanged: at the limit, a retryable refusal keeps the switch pending
        // and the tracker moves (the pending retry applies it once safe).
        XCTAssertTrue(AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(.refused(.keychainUnreadable)), selectedBy: "auto"))
        XCTAssertTrue(AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(.refused(.keychainUnreadable)), selectedBy: "user", handoff: false))
    }

    // MARK: - 5. Without ps, a bare node process is a holder

    func testLibprocNodeProcessCountsAsAHolder() {
        // The libproc fallback knows argv0 only: `node …/cli.js` reads as `node`.
        let node = MainLoginSwapPolicy.RunningProcess(pid: 10, command: "/opt/homebrew/bin/node", argvKnown: false)
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [node]).map(\.pid), [10])
        // With ps, a node whose script is known and is not Claude Code is not one.
        let vite = MainLoginSwapPolicy.RunningProcess(pid: 11, command: "/opt/homebrew/bin/node /x/node_modules/.bin/vite")
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [vite]).isEmpty)
        let cli = MainLoginSwapPolicy.RunningProcess(pid: 12, command: "/usr/local/bin/node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js")
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [cli]).map(\.pid), [12])
        // A non-node libproc entry is judged by its path as before.
        let zsh = MainLoginSwapPolicy.RunningProcess(pid: 13, command: "/bin/zsh", argvKnown: false)
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [zsh]).isEmpty)
    }

    // MARK: - 6a. (2026-10-14) every switch moves running sessions; the
    // near-limit/holder gating that `nearLimitLoginsForSwitch` provided is
    // gone with it — sessions follow the swap, see SwapFollowsSessionsTests.

    // MARK: - 6b. The effective percentage uses the policy's `now`

    func testBindingPercentageHonoursThePolicyNow() {
        let wall = Date()
        let later = wall.addingTimeInterval(2 * 3600)
        // Session window at 95% resets one hour from the wall clock; judged two
        // hours later it has passed. Fresh at `later`.
        var u = usage(session: 95, weekly: 40)
        u.sessionResetTime = wall.addingTimeInterval(3600)
        u.weeklyResetTime = wall.addingTimeInterval(86400)
        u.lastUpdated = later.addingTimeInterval(-60)
        XCTAssertEqual(AutoSwitchPolicy.bindingPercentage(u, usingFable: false, now: later), 40)
        XCTAssertFalse(AutoSwitchPolicy.isNearLimit(u, usingFable: false, now: later))
        XCTAssertEqual(AutoSwitchStatus.freeAt(usage(session: 100, weekly: 0), usingFable: false, now: now.addingTimeInterval(7200)),
                       now.addingTimeInterval(7200), "a passed window is free at `now`")
    }

    // MARK: - 6c. The auto-start parser reads Fable from limits[], as mc does

    func testAutoStartParserReadsFableFromLimits() throws {
        let body = #"""
        {"five_hour":{"utilization":10,"resets_at":"2026-10-12T20:00:00.000Z"},
         "seven_day":{"utilization":20,"resets_at":"2026-10-17T19:00:00.000Z"},
         "seven_day_fable":null,
         "limits":[{"kind":"weekly_scoped","percent":81,"resets_at":"2026-10-16T19:00:00.000Z",
                    "scope":{"model":{"id":null,"display_name":"Fable"}}}]}
        """#
        let u = try AutoStartSessionService.shared.parseUsageResponseForTesting(Data(body.utf8))
        XCTAssertEqual(u.fableWeeklyPercentage, 81)
        XCTAssertNotNil(u.fableWeeklyResetTime)

        let legacy = #"{"five_hour":{"utilization":1},"seven_day":{"utilization":2},"seven_day_fable":{"utilization":44,"resets_at":"2026-10-16T19:00:00.000Z"}}"#
        XCTAssertEqual(try AutoStartSessionService.shared.parseUsageResponseForTesting(Data(legacy.utf8)).fableWeeklyPercentage, 44)
    }

    // MARK: - Fixtures

    private func usage(session: Double, weekly: Double, fable: Double = 0, age: TimeInterval = 0) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0, sessionLimit: 100000, sessionPercentage: session,
            sessionResetTime: now.addingTimeInterval(3600),
            weeklyTokensUsed: 0, weeklyLimit: 1000000, weeklyPercentage: weekly,
            weeklyResetTime: now.addingTimeInterval(86400),
            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0, designWeeklyPercentage: 0, designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0, fableWeeklyPercentage: fable, fableWeeklyResetTime: now.addingTimeInterval(86400),
            costUsed: nil, costLimit: nil, costCurrency: nil,
            lastUpdated: now.addingTimeInterval(-age), userTimezone: .current
        )
    }

    private func profile(_ name: String, session: Double, weekly: Double) -> Profile {
        Profile(name: "\(name)@x.com",
                cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"t-\#(name)","refreshToken":"r-\#(name)"}}"#,
                claudeUsage: usage(session: session, weekly: weekly))
    }
}
