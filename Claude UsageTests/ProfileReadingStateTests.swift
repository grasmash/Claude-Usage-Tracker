import XCTest
@testable import Claude_Usage

/// The two states the operator must be able to tell apart (2026-10-12: the
/// app said "Not updated for 13h — check the…" for littlewing and nobody could
/// tell what to do):
/// (a) STALE reading on an inactive account: normal, no action, rotation can
///     still switch there;
/// (b) DEAD login: sign-in needed, with the exact fix; rotation skips it.
/// Both are decided from what the app already knows (the dead-login set and
/// the last refresh result), never from a probe refresh.
final class ProfileReadingStateTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: (a) stale reading

    func testAnOldReadingOnAnInactiveAccountIsStaleIdleAndNeedsNoAction() {
        let p = profile("littlewing@guitargate.com", updatedAgo: 13 * 3600)
        let state = ProfileReadingState.classify(profile: p, isActive: false, isLoginDead: false, refreshError: nil, now: now)
        XCTAssertEqual(state, .staleIdle(age: 13 * 3600, fromMissionControl: false))
        XCTAssertFalse(state.needsAction, "no notification, no orange banner")

        let text = MenuBarManager.readingMessage(state, profile: p, now: now) ?? ""
        XCTAssertTrue(text.contains("13h"), text)
        XCTAssertTrue(text.contains("No action needed"), text)
        XCTAssertFalse(text.contains("check this profile"), text)
        XCTAssertFalse(text.contains("claude-usage-login"), text)
    }

    func testAStaleIdleMcReadingSaysWhereItCameFrom() {
        var p = profile("littlewing@guitargate.com", updatedAgo: 2 * 3600)
        p.claudeUsage?.source = ClaudeUsage.sourceMissionControl
        let state = ProfileReadingState.classify(profile: p, isActive: false, isLoginDead: false, refreshError: nil, now: now)
        XCTAssertEqual(state, .staleIdle(age: 2 * 3600, fromMissionControl: true))
        XCTAssertTrue((MenuBarManager.readingMessage(state, profile: p, now: now) ?? "").contains("mission control"))
    }

    func testAFreshMcReadingIsFreshAndLabelledButNotAWarning() {
        var p = profile("littlewing@guitargate.com", updatedAgo: 120)
        p.claudeUsage?.source = ClaudeUsage.sourceMissionControl
        let state = ProfileReadingState.classify(profile: p, isActive: false, isLoginDead: false, refreshError: nil, now: now)
        XCTAssertEqual(state, .fresh(fromMissionControl: true))
        XCTAssertFalse(state.needsAction)
        XCTAssertEqual(MenuBarManager.readingMessage(state, profile: p, now: now),
                       "Read by mission control 2m ago (this account is not active).")
    }

    func testAStaleReadingStaysASwitchTargetAndIsNotListedForSignIn() {
        let current = applicable("matt@guitargate.com", weekly: 100, updatedAgo: 0)
        // littlewing: 13h old, window passed -> presumed free; login alive.
        let lw = applicable("littlewing@guitargate.com", weekly: 100, weeklyResetIn: -60, updatedAgo: 13 * 3600)
        XCTAssertEqual(AutoSwitchPolicy.nextAvailableProfile(in: [current, lw], after: current, now: now)?.id, lw.id)
        let status = AutoSwitchStatus.build(profiles: [current, lw], activeId: current.id, now: now)
        XCTAssertEqual(status.signInNeeded, [])
        XCTAssertTrue(status.stateFileContents(timeFormatter: { _ in "" }).contains("SIGNIN_NEEDED=\n"))
    }

    // MARK: (b) dead login

    func testADeadLoginIsSignInNeededWithTheExactFix() {
        let p = profile("littlewing@guitargate.com", updatedAgo: 13 * 3600)
        let state = ProfileReadingState.classify(profile: p, isActive: false, isLoginDead: true, refreshError: nil, now: now)
        XCTAssertEqual(state, .signInNeeded)
        XCTAssertTrue(state.needsAction)
        XCTAssertEqual(MenuBarManager.readingMessage(state, profile: p, now: now),
                       "littlewing: sign-in needed. Run claude-usage-login in Terminal and sign in as littlewing@guitargate.com. Auto-switch skips this account until then.")
    }

    func testADeadLoginOutranksEvenAFreshReading() {
        var p = profile("littlewing@guitargate.com", updatedAgo: 60)
        p.claudeUsage?.source = ClaudeUsage.sourceMissionControl
        XCTAssertEqual(ProfileReadingState.classify(profile: p, isActive: false, isLoginDead: true, refreshError: nil, now: now),
                       .signInNeeded)
    }

    func testADeadLoginIsSkippedByRotationAndListedForTheStatusLine() {
        let current = applicable("matt@guitargate.com", weekly: 100, updatedAgo: 0)
        let lw = applicable("littlewing@guitargate.com", weekly: 0, updatedAgo: 60)
        let dead: (Profile) -> Bool = { $0.id == lw.id }
        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [current, lw], after: current, now: now, isLoginDead: dead))
        let status = AutoSwitchStatus.build(profiles: [current, lw], activeId: current.id, now: now, isLoginDead: dead)
        XCTAssertEqual(status.signInNeeded, ["littlewing"])
        XCTAssertTrue(status.stateFileContents(timeFormatter: { _ in "" }).contains("SIGNIN_NEEDED=littlewing\n"))
    }

    func testAnAccountWithNoSavedLoginIsNotCalledDead() {
        // Not applicable (no saved login) still shows under NEEDS_LOGIN as before,
        // but only a rejected login is a "sign-in needed" warning.
        let current = applicable("matt@guitargate.com", weekly: 100, updatedAgo: 0)
        let bare = profile("goose@example.com", updatedAgo: 60)
        let status = AutoSwitchStatus.build(profiles: [current, bare], activeId: current.id, now: now)
        XCTAssertEqual(status.needsLogin, ["goose"])
        XCTAssertEqual(status.signInNeeded, [])
    }

    // MARK: Other states keep their meaning

    func testAStaleActiveProfileAndARefreshErrorStillNeedAction() {
        let p = profile("matt@guitargate.com", updatedAgo: 3600)
        XCTAssertEqual(ProfileReadingState.classify(profile: p, isActive: true, isLoginDead: false, refreshError: nil, now: now),
                       .staleActive(age: 3600))
        XCTAssertEqual(ProfileReadingState.classify(profile: p, isActive: false, isLoginDead: false, refreshError: "401", now: now),
                       .refreshFailed("401"))
        var none = p
        none.claudeUsage = nil
        XCTAssertEqual(ProfileReadingState.classify(profile: none, isActive: false, isLoginDead: false, refreshError: nil, now: now),
                       .neverUpdated)
    }

    // MARK: Fixtures

    private func profile(_ email: String, updatedAgo: TimeInterval, weekly: Double = 100,
                         weeklyResetIn: TimeInterval = 86400) -> Profile {
        Profile(name: email, claudeUsage: ClaudeUsage(
            sessionTokensUsed: 0, sessionLimit: 0, sessionPercentage: 0,
            sessionResetTime: now.addingTimeInterval(3600),
            weeklyTokensUsed: 0, weeklyLimit: 1_000_000, weeklyPercentage: weekly,
            weeklyResetTime: Date().addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0, designWeeklyPercentage: 0, designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0, fableWeeklyPercentage: 0, fableWeeklyResetTime: nil,
            costUsed: nil, costLimit: nil, costCurrency: nil,
            lastUpdated: now.addingTimeInterval(-updatedAgo), userTimezone: .current))
    }

    private func applicable(_ email: String, weekly: Double, weeklyResetIn: TimeInterval = 86400,
                            updatedAgo: TimeInterval) -> Profile {
        var p = profile(email, updatedAgo: updatedAgo, weekly: weekly, weeklyResetIn: weeklyResetIn)
        p.cliCredentialsJSON = #"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r"}}"#
        return p
    }
}
