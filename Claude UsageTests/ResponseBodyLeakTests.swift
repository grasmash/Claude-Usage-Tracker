import XCTest
@testable import Claude_Usage

/// Answers the OAuth token endpoint in tests with a fixed status and body; nothing reaches the network.
final class RefreshStub: URLProtocol {
    static var reply: (Int, Data)?

    override class func canInit(with request: URLRequest) -> Bool {
        reply != nil && request.url?.host == "platform.claude.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let (status, body) = Self.reply, let url = request.url else { return }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

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

    // MARK: - the real refresh path

    /// Fable round 2 on PR #3 (a behaviour bug): postTokenRefresh cut the body to 200 bytes BEFORE parsing it, so a
    /// long invalid_grant body (a long error_description) became invalid JSON, the code read "unknown", and the dead
    /// login was never marked dead and kept being retried. Runs the real postTokenRefresh against a stubbed server.
    func testALongInvalidGrantBodyFromTheServerIsStillADeadLogin() async {
        let description = String(repeating: "Refresh token not found or invalid. ", count: 12)   // ~430 bytes
        RefreshStub.reply = (400, Data(#"{"error":"invalid_grant","error_description":"\#(description)"}"#.utf8))
        XCTAssertGreaterThan(RefreshStub.reply!.1.count, 200)
        URLProtocol.registerClass(RefreshStub.self)
        defer { URLProtocol.unregisterClass(RefreshStub.self); RefreshStub.reply = nil }
        do {
            _ = try await ClaudeCodeSyncService.postTokenRefresh(refreshToken: "fake-refresh-not-real")
            XCTFail("a 400 must throw")
        } catch let error as ClaudeCodeError {
            XCTAssertTrue(DeadLoginTracker.isInvalidGrant(error), "a long invalid_grant body is still a dead login: \(error)")
            XCTAssertFalse("\(error)".contains("Refresh token not found"), "and the body text is still not carried")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - the class: every app source file

    /// A body decoded from a response (`String(data: data …)`) may be inspected in place (the Cloudflare check reads
    /// it for "Just a moment"), but its text must never be interpolated into technicalDetails, a LoggingService call
    /// or the network logger's stored preview. The scan names the exact file:line of any such path.
    func testNoErrorOrLogPathInterpolatesADecodedResponseBody() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Claude Usage")
        var leaks: [String] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 50, "the scan must see the app sources (\(root.path))")
        for file in files {
            leaks += Self.leaks(in: try String(contentsOf: file, encoding: .utf8), file: file.lastPathComponent)
        }
        XCTAssertEqual(leaks, [], "raw HTTP response bodies reach an error or a log:\n" + leaks.joined(separator: "\n"))
    }

    /// The scanner must catch the shapes the review named: a body that is not the last interpolation on the line, a
    /// body decoded from any variable, the print/NSLog/os_log sinks, and a sink call that spans several lines.
    func testTheScannerCatchesEveryShapeTheReviewNamed() {
        let notLast = """
            let preview = String(data: payload, encoding: .utf8) ?? ""
            LoggingService.shared.log("got \\(preview) for \\(endpoint)")
            """
        let printed = """
            let text = String(decoding: body, as: UTF8.self)
            print("raw: \\(text)")
            """
        let multiLine = """
            let raw = String(data: responseBytes, encoding: .utf8)
            throw AppError(
                code: .unknown,
                technicalDetails:
                    "status \\(code) body \\(raw)"
            )
            """
        let derived = """
            if let s = String(data: d, encoding: .utf8) {
                let cut = s.prefix(100)
                NSLog("cut: %@ \\(cut)")
            }
            """
        for (name, source) in [("notLast", notLast), ("printed", printed), ("multiLine", multiLine), ("derived", derived)] {
            XCTAssertFalse(Self.leaks(in: source, file: name).isEmpty, "the scanner missed the \(name) shape")
        }
        XCTAssertEqual(Self.leaks(in: "LoggingService.shared.log(\"\\(ResponseBody.summary(data))\")", file: "ok"), [])
    }

    private static let sinkRE = try! NSRegularExpression(
        pattern: #"technicalDetails:|LoggingService\.shared\.log\w*\(|responsePreview:|\bprint\(|\bNSLog\(|\bos_log\(|ErrorLogger\."#)
    private static let decodeRE = try! NSRegularExpression(pattern: #"(?:let|var) (\w+) = String\((?:data|decoding): *\w+"#)
    private static let deriveRE = try! NSRegularExpression(pattern: #"(?:let|var) (\w+) = (\w+)\."#)
    private static let interpRE = try! NSRegularExpression(pattern: #"\\\((\w+)"#)

    private static func groups(_ re: NSRegularExpression, _ line: String) -> [[String]] {
        re.matches(in: line, range: NSRange(line.startIndex..., in: line)).map { m in
            (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: line).map { String(line[$0]) } ?? "" }
        }
    }

    /// file:line of every place a decoded body (or a name derived from one) reaches a sink in `text`. A sink call is
    /// read until its parentheses balance (at most 8 lines), so a multi-line call is covered.
    static func leaks(in text: String, file: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var bodyNames = Set<String>()
        for line in lines { groups(decodeRE, line).forEach { bodyNames.insert($0[0]) } }
        for _ in 0..<3 {   // names derived from a body, a few levels deep
            for line in lines { groups(deriveRE, line).filter { bodyNames.contains($0[1]) }.forEach { bodyNames.insert($0[0]) } }
        }
        var leaks: [String] = []
        for (i, line) in lines.enumerated()
        where sinkRE.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
            var stmt = line
            var depth = line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
            var j = i + 1
            while (depth > 0 || stmt.hasSuffix("technicalDetails:")) && j < min(lines.count, i + 8) {
                stmt += "\n" + lines[j]
                depth += lines[j].filter { $0 == "(" }.count - lines[j].filter { $0 == ")" }.count
                j += 1
            }
            if stmt.contains("String(data:") || stmt.contains("String(decoding:") {
                leaks.append("\(file):\(i + 1) decodes a body inside a log or error")
            }
            for name in Set(groups(interpRE, stmt).map { $0[0] }) where bodyNames.contains(name) {
                leaks.append("\(file):\(i + 1) puts the decoded body '\(name)' into a log or error")
            }
        }
        if file == "NetworkLoggerService.swift", text.contains("String(data:") {
            leaks.append("NetworkLoggerService.swift stores decoded body text")
        }
        return leaks
    }
}
