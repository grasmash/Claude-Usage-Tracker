import XCTest
@testable import Claude_Usage

/// The shared Claude Code login is rewritten only when nothing holds it and
/// the keychain still holds a login the tracker has seen. Pure policy; a fake
/// process list stands in for `ps`.
final class MainLoginSwapPolicyTests: XCTestCase {

    typealias P = MainLoginSwapPolicy.RunningProcess

    private func claude(_ pid: Int32, dir: String? = nil, command: String = "claude") -> P {
        var env = ["HOME": "/Users/me", "TERM": "xterm-256color"]
        if let dir { env["CLAUDE_CONFIG_DIR"] = dir }
        return P(pid: pid, command: command, environment: env)
    }

    // MARK: - ps output

    func testParsesPidCommandAndEnvironmentFromPsLines() {
        let text = """
        101 /opt/homebrew/bin/claude --model opus HOME=/Users/me CLAUDE_CONFIG_DIR=/Users/me/.claude-rotate/accounts/goose TERM=xterm
        102 claude SHELL=/bin/zsh HOME=/Users/me
        103 /usr/sbin/cfprefsd agent
        """
        let processes = MainLoginSwapPolicy.parsePsOutput(text)
        XCTAssertEqual(processes.count, 3)
        XCTAssertEqual(processes[0].pid, 101)
        XCTAssertEqual(processes[0].command, "/opt/homebrew/bin/claude --model opus")
        XCTAssertEqual(processes[0].environment["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-rotate/accounts/goose")
        XCTAssertEqual(processes[1].command, "claude")
        XCTAssertNil(processes[1].environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(processes[2].command, "/usr/sbin/cfprefsd agent")
    }

    func testOptionsAreNotMistakenForEnvironment() {
        let processes = MainLoginSwapPolicy.parsePsOutput("7 claude --output-format=json -p hi HOME=/u")
        XCTAssertEqual(processes.first?.command, "claude --output-format=json -p hi")
        XCTAssertEqual(processes.first?.environment, ["HOME": "/u"])
    }

    func testSkipsMalformedLines() {
        XCTAssertTrue(MainLoginSwapPolicy.parsePsOutput("PID COMMAND\n\nnot-a-pid claude").isEmpty)
    }

    // MARK: - Which processes hold the shared login

    func testBareClaudeIsASharedLoginHolder() {
        let holders = MainLoginSwapPolicy.sharedLoginHolders(in: [claude(1)])
        XCTAssertEqual(holders.map(\.pid), [1])
    }

    func testClaudeByFullPathIsAHolder() {
        let holders = MainLoginSwapPolicy.sharedLoginHolders(in: [claude(2, command: "/opt/homebrew/bin/claude --resume abc")])
        XCTAssertEqual(holders.map(\.pid), [2])
    }

    func testLegacyNodeCliIsAHolder() {
        let p = claude(3, command: "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js")
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [p]).map(\.pid), [3])
    }

    func testClaudeOnItsOwnConfigDirIsNotAHolder() {
        // A per-account dir has its own login, which the tracker never touches.
        let p = claude(4, dir: "/Users/me/.claude-rotate/accounts/goose")
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [p]).isEmpty)
    }

    func testEmptyConfigDirCountsAsTheSharedLogin() {
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [claude(5, dir: "")]).count, 1)
    }

    func testOtherProcessesAreNotHolders() {
        let others = [
            P(pid: 6, command: "/Applications/Claude Usage.app/Contents/MacOS/Claude Usage", environment: [:]),
            P(pid: 7, command: "grep claude", environment: [:]),
            P(pid: 8, command: "/bin/zsh -c claude-rotate status", environment: [:]),
            P(pid: 9, command: "node server.js", environment: [:]),
        ]
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: others).isEmpty)
    }

    func testAuthStatusProbeIsAHolderToo() {
        // `claude auth status` refreshes an expired login like any session.
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [claude(10, command: "claude auth status --json")]).count, 1)
    }

    // MARK: - Compare-and-swap decision

    func testRefusesWhileAnySessionHoldsTheSharedLogin() {
        XCTAssertEqual(
            MainLoginSwapPolicy.refusal(holders: 3, keychainFingerprint: "a", knownFingerprints: ["a"]),
            .sessionsRunning(count: 3)
        )
    }

    func testRefusesALoginTheTrackerHasNotCaptured() {
        // A /login the tracker has not caught up with, or a rotation by another
        // refresher: never overwrite it.
        XCTAssertEqual(
            MainLoginSwapPolicy.refusal(holders: 0, keychainFingerprint: "rotated", knownFingerprints: ["a", "b"]),
            .unknownKeychainLogin
        )
    }

    func testAllowsWhenIdleAndKeychainIsAsLastSeen() {
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 0, keychainFingerprint: "a", knownFingerprints: ["a", "b"]))
    }

    func testAllowsWritingAnEmptyKeychain() {
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 0, keychainFingerprint: nil, knownFingerprints: []))
    }

    func testSessionsOutrankAnUnknownLogin() {
        XCTAssertEqual(
            MainLoginSwapPolicy.refusal(holders: 1, keychainFingerprint: "x", knownFingerprints: []),
            .sessionsRunning(count: 1)
        )
    }
}
