import XCTest
@testable import Claude_Usage

final class DeadLoginTrackerTests: XCTestCase {

    // MARK: - Recognising a dead refresh token

    func testInvalidGrantResponseMeansTheRefreshTokenIsDead() {
        let body = #"{"error": "invalid_grant", "error_description": "Refresh token not found or invalid"}"#
        XCTAssertTrue(DeadLoginTracker.isInvalidGrant(status: 400, body: body))
    }

    func testServerErrorIsNotADeadRefreshToken() {
        XCTAssertFalse(DeadLoginTracker.isInvalidGrant(status: 500, body: "invalid_grant"))
    }

    func testOtherClientErrorIsNotADeadRefreshToken() {
        XCTAssertFalse(DeadLoginTracker.isInvalidGrant(status: 400, body: #"{"error": "invalid_request"}"#))
    }

    func testOfflineFailureIsNotADeadRefreshToken() {
        XCTAssertFalse(DeadLoginTracker.isInvalidGrant(status: 0, body: "The Internet connection appears to be offline."))
    }

    // MARK: - Remembering dead tokens

    func testMarkedTokenIsDead() {
        let tracker = DeadLoginTracker()
        tracker.markDead("rt-old")
        XCTAssertTrue(tracker.isDead("rt-old"))
    }

    func testReplacedTokenIsNotDead() {
        // A /login writes a new refresh token; the profile must be retried.
        let tracker = DeadLoginTracker()
        tracker.markDead("rt-old")
        XCTAssertFalse(tracker.isDead("rt-new"))
    }

    // MARK: - Is a login dead?

    func testLoginIsDeadWhenEveryTokenItCouldUseIsDead() {
        let tracker = DeadLoginTracker()
        tracker.markDead("pinned")
        tracker.markDead("system")
        XCTAssertTrue(tracker.isLoginDead(refreshTokens: ["pinned", "system"]))
    }

    func testLoginIsAliveWhenOneTokenStillWorks() {
        // Pinned entry is dead but Claude Code was re-logged-in: still usable.
        let tracker = DeadLoginTracker()
        tracker.markDead("pinned")
        XCTAssertFalse(tracker.isLoginDead(refreshTokens: ["pinned", "system"]))
    }

    func testLoginWithNoRefreshTokensIsNotCalledDead() {
        // Session-key-only profiles have nothing to refresh; not our call.
        let tracker = DeadLoginTracker()
        tracker.markDead("x")
        XCTAssertFalse(tracker.isLoginDead(refreshTokens: []))
    }
}
