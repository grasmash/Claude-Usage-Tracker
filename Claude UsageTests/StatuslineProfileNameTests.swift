import XCTest
@testable import Claude_Usage

/// The status line shows the account name from its config file next to usage
/// numbers from the usage cache. The name must follow the active account even
/// when the switch came from a /login rather than from the tracker.
final class StatuslineProfileNameTests: XCTestCase {

    func testReplacesAStaleName() {
        let config = "SHOW_PROFILE=1\nPROFILE_NAME=\"old@x.com\"\nSHOW_WEEKLY=1\n"
        XCTAssertEqual(StatuslineService.config(config, withProfileName: "new@x.com"),
                       "SHOW_PROFILE=1\nPROFILE_NAME=\"new@x.com\"\nSHOW_WEEKLY=1\n")
    }

    func testNoChangeWhenNameAlreadyMatches() {
        let config = "PROFILE_NAME=\"same@x.com\"\n"
        XCTAssertNil(StatuslineService.config(config, withProfileName: "same@x.com"))
    }

    func testAddsTheNameWhenMissing() {
        XCTAssertEqual(StatuslineService.config("SHOW_PROFILE=1\n", withProfileName: "a@x.com"),
                       "SHOW_PROFILE=1\n\nPROFILE_NAME=\"a@x.com\"\n")
    }
}
