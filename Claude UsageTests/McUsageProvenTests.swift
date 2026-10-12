import XCTest
@testable import Claude_Usage

/// Mission control now says, per account, whether the reading's identity was
/// PROVEN (the reporter asked /api/oauth/profile with the same token and the
/// email matched the account's rotate config). From 05:44Z to 16:16Z on
/// 2026-10-12 mc's "littlewing" row was madmatter's usage, relayed by the
/// laptop under the wrong label; an unproven row is at best a presumption and
/// must never be taken as a fresh reading. `source`/`proven`/`host` are
/// SIBLINGS of `usage` in `accounts[]`; an older mc omits them (= unproven).
final class McUsageProvenTests: XCTestCase {

    private func body(_ accounts: String) -> Data {
        Data(#"{"accounts":[\#(accounts)]}"#.utf8)
    }

    private func account(_ name: String, proven: String?) -> String {
        let flag = proven.map { #","proven":\#($0),"source":"usage-self","host":"littlewing""# } ?? ""
        return #"{"name":"\#(name)","usage":{"sampled_at":"2026-10-12T16:22:14Z","session":{"used_pct":10,"resets_at":null},"weekly":{"used_pct":3,"resets_at":null},"fable":null,"paused":false}\#(flag)}"#
    }

    func testOnlyProvenRowsAreReadings() {
        let data = body([account("littlewing", proven: "true"), account("mattgg", proven: "false"), account("goose", proven: nil)].joined(separator: ","))
        let readings = McUsage.parseAccountUsage(data) ?? []
        XCTAssertEqual(readings.map(\.account), ["littlewing"], "unproven and legacy rows are not readings")
    }

    func testProvenMustBeAJSONBoolean() {
        let data = body(account("littlewing", proven: "1"))
        XCTAssertEqual(McUsage.parseAccountUsage(data)?.map(\.account) ?? [], [], "1 is not true")
        let str = body(account("littlewing", proven: #""true""#))
        XCTAssertEqual(McUsage.parseAccountUsage(str)?.map(\.account) ?? [], [], "\"true\" is not true")
    }
}
