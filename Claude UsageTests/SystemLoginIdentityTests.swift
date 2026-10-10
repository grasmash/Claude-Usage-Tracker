import XCTest
@testable import Claude_Usage

/// Which account the keychain login belongs to must come from the login
/// itself. `oauthAccount` in `.claude.json` is a cache that any running
/// Claude Code session can rewrite from its own stale copy, so it can name a
/// different account than the token in the keychain.
final class SystemLoginIdentityTests: XCTestCase {

    private let sync = ClaudeCodeSyncService.shared
    private let madConfig = #"{"accountUuid":"u-mad","emailAddress":"mad@x.com"}"#
    private let gooseConfig = #"{"accountUuid":"u-goose","emailAddress":"goose@x.com","organizationName":"Goose"}"#

    private func login(_ refreshToken: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"at-\#(refreshToken)","refreshToken":"\#(refreshToken)"}}"#
    }

    override func tearDown() {
        sync.fetchLoginAccountUuid = { _ in nil }
        super.tearDown()
    }

    func testTheLoginsOwnAccountWinsOverAStaleConfigAccount() async {
        sync.fetchLoginAccountUuid = { $0 == "at-rt-goose-1" ? "u-goose" : nil }
        let creds = login("rt-goose-1")
        await sync.resolveLoginAccount(credentials: creds)

        XCTAssertEqual(sync.loginAccountIdentity(credentials: creds, configOAuthAccount: madConfig), "u-goose")
        XCTAssertNil(sync.loginOAuthAccount(credentials: creds, configOAuthAccount: madConfig),
                     "the config's account belongs to another login and must not be copied")
    }

    func testTheConfigAccountIsUsedWhenItBelongsToTheLogin() async {
        sync.fetchLoginAccountUuid = { _ in "u-goose" }
        let creds = login("rt-goose-2")
        await sync.resolveLoginAccount(credentials: creds)

        XCTAssertEqual(sync.loginAccountIdentity(credentials: creds, configOAuthAccount: gooseConfig), "u-goose")
        XCTAssertEqual(sync.loginOAuthAccount(credentials: creds, configOAuthAccount: gooseConfig), gooseConfig)
    }

    func testAnUnresolvedLoginHasNoAccountYet() {
        sync.fetchLoginAccountUuid = { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return "u-goose"
        }
        let creds = login("rt-pending-\(UUID().uuidString)")

        XCTAssertNil(sync.loginAccountIdentity(credentials: creds, configOAuthAccount: madConfig))
        XCTAssertNil(sync.loginOAuthAccount(credentials: creds, configOAuthAccount: madConfig))
    }

    func testFallsBackToTheConfigAccountWhenTheLoginCannotBeResolved() async {
        sync.fetchLoginAccountUuid = { _ in nil }
        let creds = login("rt-offline-\(UUID().uuidString)")
        await sync.resolveLoginAccount(credentials: creds)

        XCTAssertEqual(sync.loginAccountIdentity(credentials: creds, configOAuthAccount: madConfig), "u-mad")
        XCTAssertEqual(sync.loginOAuthAccount(credentials: creds, configOAuthAccount: madConfig), madConfig)
    }

    func testALoginWithoutARefreshTokenUsesTheConfigAccount() {
        // Manually pasted setup tokens: nothing to resolve or cache by.
        let creds = #"{"claudeAiOauth":{"accessToken":"at-manual"}}"#
        XCTAssertEqual(sync.loginAccountIdentity(credentials: creds, configOAuthAccount: madConfig), "u-mad")
    }
}
