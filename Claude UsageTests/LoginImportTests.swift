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

    // Open Claude Code sessions reload their login only when
    // ~/.claude/.credentials.json changes. A /login in one session updates the
    // keychain alone, so the file must be brought in line or every other
    // session stays on its old account.

    func testCredentialsFileIsRewrittenWhenTheKeychainHoldsAnotherLogin() {
        let sync = ClaudeCodeSyncService.shared
        XCTAssertTrue(sync.credentialsFileIsOutOfDate(
            keychainJSON: #"{"claudeAiOauth":{"accessToken":"a2","refreshToken":"new"}}"#,
            fileJSON: #"{"claudeAiOauth":{"accessToken":"a1","refreshToken":"old"}}"#))
    }

    func testCredentialsFileIsLeftAloneWhenItMatchesTheKeychain() {
        let sync = ClaudeCodeSyncService.shared
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"same"}}"#
        XCTAssertFalse(sync.credentialsFileIsOutOfDate(keychainJSON: json, fileJSON: json))
    }

    func testMissingCredentialsFileIsOutOfDate() {
        let sync = ClaudeCodeSyncService.shared
        XCTAssertTrue(sync.credentialsFileIsOutOfDate(
            keychainJSON: #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r"}}"#, fileJSON: nil))
    }

    func testKeychainWithoutARefreshTokenNeverOverwritesTheFile() {
        // A truncated or regex-recovered keychain payload is not a full login.
        let sync = ClaudeCodeSyncService.shared
        XCTAssertFalse(sync.credentialsFileIsOutOfDate(
            keychainJSON: #"{"claudeAiOauth":{"accessToken":"a"}}"#,
            fileJSON: #"{"claudeAiOauth":{"accessToken":"a1","refreshToken":"old"}}"#))
    }

    func testImportDirectoryKeychainEntryFollowsClaudeCodesNaming() {
        let sync = ClaudeCodeSyncService.shared
        let dir = ClaudeCodeSyncService.loginImportDirectory.path
        XCTAssertTrue(dir.hasSuffix("/.claude-import"))
        XCTAssertEqual(sync.loginImportServiceName,
                       "Claude Code-credentials-\(sync.sha256HexPrefix(dir, length: 8))")
    }
}
