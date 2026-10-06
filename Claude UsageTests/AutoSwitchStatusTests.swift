import XCTest
@testable import Claude_Usage

/// What the status line is told about auto-switching: whether it is stuck,
/// when the soonest account frees up, and which accounts need a /login.
final class AutoSwitchStatusTests: XCTestCase {

    private let now = Date()

    func testNotStuckWhileActiveAccountHasRoom() {
        let active = makeProfile("a@x.com", session: 40, weekly: 40)
        let status = AutoSwitchStatus.build(profiles: [active, makeProfile("b@x.com", session: 100, weekly: 0)],
                                            activeId: active.id, now: now)
        XCTAssertFalse(status.stuck)
    }

    func testNotStuckWhenAnotherAccountCanTakeOver() {
        let active = makeProfile("a@x.com", session: 100, weekly: 40)
        let spare = makeProfile("b@x.com", session: 0, weekly: 10)
        let status = AutoSwitchStatus.build(profiles: [active, spare], activeId: active.id, now: now)
        XCTAssertFalse(status.stuck)
    }

    func testStuckWhenActiveIsLimitedAndNoOtherAccountHasRoom() {
        let active = makeProfile("a@x.com", session: 100, weekly: 40)
        let full = makeProfile("b@x.com", session: 0, weekly: 100)
        let status = AutoSwitchStatus.build(profiles: [active, full], activeId: active.id, now: now)
        XCTAssertTrue(status.stuck)
    }

    func testStuckWhenActiveLoginIsDeadAndNoOtherAccountHasRoom() {
        let active = makeProfile("a@x.com", session: 0, weekly: 0)
        let full = makeProfile("b@x.com", session: 0, weekly: 100)
        let status = AutoSwitchStatus.build(profiles: [active, full], activeId: active.id, now: now,
                                            isLoginDead: { $0.id == active.id })
        XCTAssertTrue(status.stuck)
    }

    func testDeadLoginsAreListedAsNeedingLogin() {
        let active = makeProfile("a@x.com", session: 0, weekly: 0)
        let dead = makeProfile("goose@x.com", session: 0, weekly: 0)
        let status = AutoSwitchStatus.build(profiles: [active, dead], activeId: active.id, now: now,
                                            isLoginDead: { $0.id == dead.id })
        XCTAssertEqual(status.needsLogin, ["goose"])
    }

    func testAccountWithoutItsOwnMainLoginNeedsLogin() {
        let active = makeProfile("a@x.com", session: 0, weekly: 0)
        var pinned = makeProfile("p@x.com", session: 0, weekly: 0)
        pinned.customKeychainServiceName = "Claude Code-credentials-p"
        pinned.hasOwnMainLogin = false
        let status = AutoSwitchStatus.build(profiles: [active, pinned], activeId: active.id, now: now)
        XCTAssertEqual(status.needsLogin, ["p"])
    }

    func testSoonestFreeIsTheEarliestResetAmongUsableLogins() {
        let active = makeProfile("a@x.com", session: 100, weekly: 40, sessionResetIn: 7200)
        let soon = makeProfile("soon@x.com", session: 100, weekly: 10, sessionResetIn: 600)
        let deadSooner = makeProfile("dead@x.com", session: 100, weekly: 10, sessionResetIn: 60)
        let status = AutoSwitchStatus.build(profiles: [active, soon, deadSooner], activeId: active.id, now: now,
                                            isLoginDead: { $0.id == deadSooner.id })
        XCTAssertEqual(status.nextFree?.name, "soon")
    }

    func testAccountFreesOnlyWhenEveryExhaustedLimitHasReset() {
        // Session resets in 10 min but the weekly limit holds for a day.
        let active = makeProfile("a@x.com", session: 100, weekly: 100, sessionResetIn: 600, weeklyResetIn: 86400)
        let status = AutoSwitchStatus.build(profiles: [active], activeId: active.id, now: now)
        let free = try? XCTUnwrap(status.nextFree)
        XCTAssertEqual(free?.at.timeIntervalSince(now) ?? 0, 86400, accuracy: 5)
    }

    func testStateFileLines() {
        let at = Date(timeIntervalSince1970: 0)
        let status = AutoSwitchStatus(stuck: true, nextFree: (name: "goose", at: at), needsLogin: ["lw", "mad"])
        let text = status.stateFileContents(timeFormatter: { _ in "20:09" })
        XCTAssertEqual(text, "STUCK=1\nNEXT_FREE=goose 20:09\nNEEDS_LOGIN=lw, mad\n")
    }

    // MARK: - Helpers

    private func makeProfile(
        _ name: String, session: Double, weekly: Double,
        sessionResetIn: TimeInterval = 3600, weeklyResetIn: TimeInterval = 86400
    ) -> Profile {
        Profile(
            name: name,
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r"}}"#,
            claudeUsage: ClaudeUsage(
                sessionTokensUsed: 0, sessionLimit: 100000, sessionPercentage: session,
                sessionResetTime: now.addingTimeInterval(sessionResetIn),
                weeklyTokensUsed: 0, weeklyLimit: 1000000, weeklyPercentage: weekly,
                weeklyResetTime: now.addingTimeInterval(weeklyResetIn),
                opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0,
                sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
                designWeeklyTokensUsed: 0, designWeeklyPercentage: 0,
                designWeeklyResetTime: nil,
                fableWeeklyTokensUsed: 0, fableWeeklyPercentage: 0, fableWeeklyResetTime: nil,
                costUsed: nil, costLimit: nil, costCurrency: nil,
                lastUpdated: now, userTimezone: .current
            )
        )
    }
}
