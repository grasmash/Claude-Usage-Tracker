import XCTest
@testable import Claude_Usage

/// Logins made with `claude-usage-login` land in a dedicated config dir; the
/// tracker must file each under the right profile and find it in the keychain.
final class LoginImportTests: XCTestCase {

    func testMatchesProfileByStoredAccountIdentity() {
        let other = Profile(name: "other@x.com", oauthAccountJSON: #"{"accountUuid":"u-other"}"#)
        let goose = Profile(name: "renamed", oauthAccountJSON: #"{"accountUuid":"u-goose"}"#)
        let index = ProfileManager.matchingProfileIndex(
            in: [other, goose], oauthAccountJSON: #"{"accountUuid":"u-goose","emailAddress":"g@x.com"}"#)
        XCTAssertEqual(index, 1)
    }

    func testFallsBackToProfileNamedAfterTheEmail() {
        let goose = Profile(name: "G@x.com")
        let index = ProfileManager.matchingProfileIndex(
            in: [goose], oauthAccountJSON: #"{"accountUuid":"u-goose","emailAddress":"g@x.com"}"#)
        XCTAssertEqual(index, 0)
    }

    func testUnknownAccountMatchesNothing() {
        let other = Profile(name: "other@x.com", oauthAccountJSON: #"{"accountUuid":"u-other"}"#)
        XCTAssertNil(ProfileManager.matchingProfileIndex(
            in: [other], oauthAccountJSON: #"{"accountUuid":"u-new","emailAddress":"new@x.com"}"#))
    }

    func testImportDirectoryKeychainEntryFollowsClaudeCodesNaming() {
        let sync = ClaudeCodeSyncService.shared
        let dir = ClaudeCodeSyncService.loginImportDirectory.path
        XCTAssertTrue(dir.hasSuffix("/.claude-import"))
        XCTAssertEqual(sync.loginImportServiceName,
                       "Claude Code-credentials-\(sync.sha256HexPrefix(dir, length: 8))")
    }
}
