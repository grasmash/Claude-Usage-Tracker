import XCTest
@testable import Claude_Usage

/// The spawn-free process listing used when `ps` fails (2026-10-12: seven
/// hours of "cannot list processes" refused every switch).
final class ProcessListingTests: XCTestCase {

    func testListsThisProcessWithItsPathAndParent() {
        let processes = ProcessListing.listViaLibproc()
        XCTAssertGreaterThan(processes.count, 10, "a machine always has processes")
        let me = processes.first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertEqual(me?.ppid, getppid())
        XCTAssertTrue(me?.command.hasPrefix("/") ?? false, "argv0 is an absolute path: \(me?.command ?? "nil")")
        XCTAssertNil(me?.configDir, "environments are not readable here: every Claude Code process counts as a holder")
    }

    /// A Claude Code binary found by the fallback is a shared-login holder
    /// (configDir nil), the refusal-leaning reading.
    func testFallbackProcessesCountAsSharedLoginHolders() {
        let claude = MainLoginSwapPolicy.RunningProcess(pid: 4242, ppid: 1, command: "/Users/x/.local/share/claude/versions/2.1.296", configDir: nil)
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [claude]).map(\.pid), [4242])
    }
}
