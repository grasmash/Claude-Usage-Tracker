import XCTest
@testable import Claude_Usage

/// The child-process runners (`security`, `ps`) must not leak file descriptors.
///
/// 2026-10-14: after 33 hours the tracker (pid 78782) held 4,929 descriptors,
/// 4,841 of them pipes — one end of every pipe it had ever handed a `Process`,
/// two when the launch itself failed. From 05:39 every `security` launch
/// failed ("Bad file descriptor") and `ps` returned nothing; the keychain login
/// could no longer be captured, so the 11:52-12:03 hand-off was refused eleven
/// times and ~20 agents died at the limit. Measured with a standalone script
/// before the fix: +2 fds per `security` run, +1 per `ps` run, +4 per failed
/// launch; 0 after closing the handles explicitly.
final class ProcessRunnerFdTests: XCTestCase {

    private static let runs = 30
    /// Descriptors other work on the process may legitimately open or close
    /// while a test runs (logging, XCTest). Each run used to leak at least one.
    private static let slack = 4

    private func openDescriptors() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    private func assertNoGrowth(_ label: String, file: StaticString = #filePath, line: UInt = #line, _ body: () -> Void) throws {
        let before = try openDescriptors()
        for _ in 0..<Self.runs { body() }
        let after = try openDescriptors()
        XCTAssertLessThanOrEqual(after - before, Self.slack,
                                 "\(label): \(after - before) descriptors leaked over \(Self.runs) runs (a leak of 1 per run reads as \(Self.runs))",
                                 file: file, line: line)
    }

    func testSecurityRunnerDoesNotLeakOnANormalExit() throws {
        try assertNoGrowth("security exit 44") {
            _ = ClaudeCodeSyncService.runSecurityProcess(
                arguments: ["find-generic-password", "-s", "claude-usage-fd-test-no-such-item", "-w"], timeout: 10)
        }
    }

    func testSecurityRunnerDoesNotLeakOnATimeout() throws {
        try assertNoGrowth("security timeout") {
            _ = ClaudeCodeSyncService.runSecurityProcess(
                arguments: ["5"], timeout: 0.05, executable: URL(fileURLWithPath: "/bin/sleep"))
        }
    }

    func testSecurityRunnerDoesNotLeakWhenTheLaunchFails() throws {
        try assertNoGrowth("security launch failure") {
            let result = ClaudeCodeSyncService.runSecurityProcess(
                arguments: [], timeout: 10, executable: URL(fileURLWithPath: "/nonexistent/claude-usage-fd-test"))
            XCTAssertNil(result, "a failed launch is reported as nil (unknown), never as a result")
        }
    }

    func testPsRunnerDoesNotLeakOnANormalExit() throws {
        try assertNoGrowth("ps") {
            _ = ClaudeCodeSyncService.runPs(["-o", "pid=", "-p", String(getpid())])
        }
    }

    func testPsRunnerDoesNotLeakWhenTheLaunchFails() throws {
        try assertNoGrowth("ps launch failure") {
            XCTAssertNil(ClaudeCodeSyncService.runPs([], executable: URL(fileURLWithPath: "/nonexistent/claude-usage-fd-test")))
        }
    }

    func testPsRunnerStillReturnsOutput() throws {
        let out = try XCTUnwrap(ClaudeCodeSyncService.runPs(["-o", "pid=", "-p", String(getpid())]))
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), String(getpid()))
    }
}
