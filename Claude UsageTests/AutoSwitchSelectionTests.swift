import XCTest
@testable import Claude_Usage

/// The selection file tells `cca` which account new work uses. It names the
/// account and never carries a token.
final class AutoSwitchSelectionTests: XCTestCase {

    func testRoundTripsThroughTheKeyValueFile() {
        let at = Date(timeIntervalSince1970: 1_760_000_000)
        let selection = AutoSwitchSelection(
            profileName: "goose@example.com", email: "goose@example.com", accountUuid: "u-goose", selectedAt: at, selectedBy: "auto")
        let parsed = AutoSwitchSelection.parse(selection.fileContents())
        XCTAssertEqual(parsed, selection)
    }

    func testFileIsKeyValueLinesAShellCanRead() {
        let contents = AutoSwitchSelection(
            profileName: "p", email: "e@x", accountUuid: nil, selectedAt: Date(), selectedBy: "user").fileContents()
        XCTAssertTrue(contents.hasPrefix("SELECTED_PROFILE=p\nSELECTED_EMAIL=e@x\nSELECTED_ACCOUNT_UUID=\n"))
        XCTAssertTrue(contents.hasSuffix("SELECTED_BY=user\n"))
    }

    func testBuiltFromAProfilesCapturedAccount() {
        let profile = Profile(name: "renamed", oauthAccountJSON: #"{"accountUuid":"u-1","emailAddress":"me@x.com"}"#)
        let selection = AutoSwitchSelection.forProfile(profile, by: "auto")
        XCTAssertEqual(selection.profileName, "renamed")
        XCTAssertEqual(selection.email, "me@x.com")
        XCTAssertEqual(selection.accountUuid, "u-1")
        XCTAssertEqual(selection.selectedBy, "auto")
    }

    func testCarriesNoToken() {
        let profile = Profile(
            name: "p",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"ACCESS-SECRET","refreshToken":"REFRESH-SECRET"}}"#,
            oauthAccountJSON: #"{"accountUuid":"u","emailAddress":"p@x"}"#)
        let contents = AutoSwitchSelection.forProfile(profile, by: "auto").fileContents()
        XCTAssertFalse(contents.contains("SECRET"))
    }

    func testWritesAndReadsBackAtomically() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(AutoSwitchSelection.fileName)
        let selection = AutoSwitchSelection(profileName: "p", email: nil, accountUuid: nil,
                                            selectedAt: Date(timeIntervalSince1970: 1_000), selectedBy: "user")
        XCTAssertTrue(selection.write(to: url))
        XCTAssertEqual(AutoSwitchSelection.read(from: url), selection)
    }

    func testUnparseableFileReadsAsNoSelection() {
        XCTAssertNil(AutoSwitchSelection.parse("garbage"))
        XCTAssertNil(AutoSwitchSelection.parse("SELECTED_PROFILE=\nSELECTED_AT=2026-10-10T00:00:00Z\n"))
    }
}
