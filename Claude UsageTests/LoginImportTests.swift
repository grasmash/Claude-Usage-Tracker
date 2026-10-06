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

    // Open Claude Code sessions reload their login only when the modification
    // time of ~/.claude/.credentials.json changes. A /login in one session
    // updates the keychain alone, so the tracker must signal the others. It
    // does so by touching the file — never by copying keychain secrets into it.

    func testANewKeychainLoginIsAChange() {
        let sync = ClaudeCodeSyncService.shared
        let seen = sync.systemLoginFingerprint(#"{"claudeAiOauth":{"accessToken":"a1","refreshToken":"old"}}"#)
        let now = sync.systemLoginFingerprint(#"{"claudeAiOauth":{"accessToken":"a2","refreshToken":"new"}}"#)
        XCTAssertNotNil(now)
        XCTAssertNotEqual(seen, now)
    }

    func testTheSameKeychainLoginIsNotAChange() {
        let sync = ClaudeCodeSyncService.shared
        let json = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"same"}}"#
        XCTAssertEqual(sync.systemLoginFingerprint(json), sync.systemLoginFingerprint(json))
    }

    func testFingerprintDoesNotContainTheToken() {
        let sync = ClaudeCodeSyncService.shared
        let fingerprint = sync.systemLoginFingerprint(#"{"claudeAiOauth":{"accessToken":"a","refreshToken":"rt-secret-value"}}"#)
        XCTAssertFalse(fingerprint?.contains("rt-secret-value") ?? true)
    }

    func testKeychainPayloadWithoutARefreshTokenHasNoFingerprint() {
        // A truncated or regex-recovered payload is not a full login; ignore it.
        XCTAssertNil(ClaudeCodeSyncService.shared.systemLoginFingerprint(#"{"claudeAiOauth":{"accessToken":"a"}}"#))
    }

    func testSignallingTouchesTheFileWithoutChangingItsContents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try "original".write(to: file, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)

        XCTAssertTrue(ClaudeCodeSyncService.signalCredentialsReload(at: file))

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(modified.timeIntervalSince(old), 3000)
    }

    func testSignallingNeverCreatesTheFile() {
        // No file means credentials live only in the keychain; keep it that way.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("creds-\(UUID().uuidString).json")
        XCTAssertFalse(ClaudeCodeSyncService.signalCredentialsReload(at: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testImportDirectoryKeychainEntryFollowsClaudeCodesNaming() {
        let sync = ClaudeCodeSyncService.shared
        let dir = ClaudeCodeSyncService.loginImportDirectory.path
        XCTAssertTrue(dir.hasSuffix("/.claude-import"))
        XCTAssertEqual(sync.loginImportServiceName,
                       "Claude Code-credentials-\(sync.sha256HexPrefix(dir, length: 8))")
    }
}
