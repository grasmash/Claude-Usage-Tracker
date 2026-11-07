import XCTest
@testable import Claude_Usage

/// No error or log path carries a raw HTTP response body (PR #3, Opus and Fable review, 2026-11-07).
///
/// A server can echo a credential in a response body (an OAuth refresh token in an error description, a session
/// cookie in a challenge page). Error details (AppError.technicalDetails), the system log (LoggingService, os_log
/// %{public}@) and the network logger's file are all read by people and tools, so a body may only reach them as
/// `ResponseBody.summary(data)`: its size and its error code, never its text.
final class ResponseBodyLeakTests: XCTestCase {

    // MARK: - the one allowed way to describe a body

    func testTheSummaryKeepsOnlySizeAndErrorCode() {
        let echoed = "sk-ant-ort01-\(UUID().uuidString)"
        let oauth = Data(#"{"error":"invalid_grant","error_description":"token \#(echoed) was reused"}"#.utf8)
        let api = Data(#"{"type":"error","error":{"type":"authentication_error","message":"bad key \#(echoed)"}}"#.utf8)
        let html = Data("<html>Just a moment... \(echoed)</html>".utf8)

        XCTAssertEqual(ResponseBody.summary(oauth), "\(oauth.count) bytes, error=invalid_grant")
        XCTAssertEqual(ResponseBody.summary(api), "\(api.count) bytes, error=authentication_error")
        XCTAssertEqual(ResponseBody.summary(html), "\(html.count) bytes")
        XCTAssertEqual(ResponseBody.summary(nil), "no body")
        for data in [oauth, api, html] {
            XCTAssertFalse(ResponseBody.summary(data).contains(echoed))
            XCTAssertFalse(ResponseBody.summary(data).contains("reused"))
        }
    }

    func testAnErrorCodeThatIsNotACodeIsDropped() {
        let data = Data(#"{"error":"token sk-ant-ort01-abc was reused, see https://x"}"#.utf8)
        XCTAssertEqual(ResponseBody.summary(data), "\(data.count) bytes")
    }

    // MARK: - the class: every app source file

    /// A body decoded from a response (`String(data: data …)`) may be inspected in place (the Cloudflare check reads
    /// it for "Just a moment"), but its text must never be interpolated into technicalDetails, a LoggingService call
    /// or the network logger's stored preview. The scan names the exact file:line of any such path.
    func testNoErrorOrLogPathInterpolatesADecodedResponseBody() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Claude Usage")
        let sinks = try NSRegularExpression(
            pattern: #"(technicalDetails:|LoggingService\.shared\.log\w*\(|responsePreview:)[^\n]*\\\((\w+)"#)
        var leaks: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the scan must see the app sources (\(root.path))")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: "\n")
            // names bound to a decoded response body anywhere in this file
            var bodyNames = Set<String>()
            let decode = try NSRegularExpression(pattern: #"let (\w+) = String\(data: *(data|responseData)\b"#)
            for line in lines {
                for m in decode.matches(in: line, range: NSRange(line.startIndex..., in: line)) {
                    bodyNames.insert(String(line[Range(m.range(at: 1), in: line)!]))
                }
            }
            // and names derived from one (`let truncated = responseString.prefix(500)`)
            let derive = try NSRegularExpression(pattern: #"let (\w+) = (\w+)\."#)
            for line in lines {
                for m in derive.matches(in: line, range: NSRange(line.startIndex..., in: line))
                where bodyNames.contains(String(line[Range(m.range(at: 2), in: line)!])) {
                    bodyNames.insert(String(line[Range(m.range(at: 1), in: line)!]))
                }
            }
            for (i, line) in lines.enumerated() {
                if line.contains("technicalDetails:") && line.contains("String(data:") {
                    leaks.append("\(file.lastPathComponent):\(i + 1) decodes a body into technicalDetails")
                }
                let range = NSRange(line.startIndex..., in: line)
                for m in sinks.matches(in: line, range: range) {
                    let name = String(line[Range(m.range(at: 2), in: line)!])
                    if bodyNames.contains(name) {
                        leaks.append("\(file.lastPathComponent):\(i + 1) puts the decoded body '\(name)' into a log or error")
                    }
                }
            }
            if file.lastPathComponent == "NetworkLoggerService.swift", text.contains("String(data: data") {
                leaks.append("NetworkLoggerService.swift stores decoded body text")
            }
        }
        XCTAssertEqual(leaks, [], "raw HTTP response bodies reach an error or a log:\n" + leaks.joined(separator: "\n"))
    }
}
