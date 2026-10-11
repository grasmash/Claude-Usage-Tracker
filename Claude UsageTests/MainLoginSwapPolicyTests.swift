import XCTest
@testable import Claude_Usage

/// The shared Claude Code login is rewritten only when nothing holds it and
/// the keychain still holds a login the tracker has seen. Pure policy; a fake
/// process list stands in for `ps`.
final class MainLoginSwapPolicyTests: XCTestCase {

    typealias P = MainLoginSwapPolicy.RunningProcess

    private func claude(_ pid: Int32, ppid: Int32 = 1, dir: String? = nil, command: String = "claude") -> P {
        var env = ["HOME": "/Users/me", "TERM": "xterm-256color"]
        if let dir { env["CLAUDE_CONFIG_DIR"] = dir }
        return P(pid: pid, ppid: ppid, command: command, environment: env)
    }

    // MARK: - ps output

    func testParsesPidPpidCommandAndEnvironmentFromPsLines() {
        let text = """
        101   900 /opt/homebrew/bin/claude --model opus HOME=/Users/me CLAUDE_CONFIG_DIR=/Users/me/.claude-rotate/accounts/goose TERM=xterm
        102 901 claude SHELL=/bin/zsh HOME=/Users/me
        103 1 /usr/sbin/cfprefsd agent
        """
        let processes = MainLoginSwapPolicy.parsePsOutput(text)
        XCTAssertEqual(processes.count, 3)
        XCTAssertEqual(processes[0].pid, 101)
        XCTAssertEqual(processes[0].ppid, 900)
        XCTAssertEqual(processes[0].command, "/opt/homebrew/bin/claude --model opus")
        XCTAssertEqual(processes[0].environment["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-rotate/accounts/goose")
        XCTAssertEqual(processes[1].command, "claude")
        XCTAssertNil(processes[1].environment["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(processes[2].command, "/usr/sbin/cfprefsd agent")
    }

    func testOptionsAreNotMistakenForEnvironment() {
        let processes = MainLoginSwapPolicy.parsePsOutput("7 1 claude --output-format=json -p hi HOME=/u")
        XCTAssertEqual(processes.first?.command, "claude --output-format=json -p hi")
        XCTAssertEqual(processes.first?.environment, ["HOME": "/u"])
    }

    func testSkipsMalformedLines() {
        XCTAssertTrue(MainLoginSwapPolicy.parsePsOutput("PID PPID COMMAND\n\nnot-a-pid 1 claude\n7 claude").isEmpty)
    }

    // MARK: - F1: Claude Code by its versioned path, and launcher children

    func testVersionedBinaryUnderHappyIsAHolder() {
        // The exact shape measured live on 2026-10-11: happy's launcher execs the
        // updater's versioned binary with --resume and no CLAUDE_CONFIG_DIR.
        let text = """
        41200 1 node /Users/me/.npm-global/lib/node_modules/happy-coder/dist/claude_local_launcher.cjs HOME=/Users/me HAPPY_SERVER_URL=https://littlewing.example
        41233 41200 /Users/me/.local/share/claude/versions/2.1.292 --resume 3f2b7a9c-1d2e-4f5a-8b6c-7d8e9f0a1b2c HOME=/Users/me TERM=xterm-256color
        """
        let processes = MainLoginSwapPolicy.parsePsOutput(text)
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeCode(processes[1]), "versioned binary is Claude Code")
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: processes).map(\.pid), [41233])
    }

    func testVersionedBinaryOnItsOwnConfigDirIsNotAHolder() {
        let p = claude(5, dir: "/Users/me/.claude-rotate/accounts/goose",
                       command: "/Users/me/.local/share/claude/versions/2.1.292 --resume abc")
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeCode(p))
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [p]).isEmpty)
    }

    func testUnrecognisedChildOfALauncherIsCountedAsAHolder() {
        // A binary we cannot name under happy is treated as Claude Code: that is
        // where an unrecognised Claude Code is most likely to be.
        let launcher = P(pid: 100, ppid: 1, command: "node /x/happy-coder/dist/claude_local_launcher.cjs", environment: ["HOME": "/u"])
        let child = P(pid: 101, ppid: 100, command: "/Users/me/.local/share/some-new-binary --resume x", environment: ["HOME": "/u"])
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [launcher, child]).map(\.pid), [101])
    }

    func testLauncherChildOnItsOwnConfigDirIsNotAHolder() {
        let launcher = P(pid: 100, ppid: 1, command: "happy", environment: ["HOME": "/u"])
        let child = P(pid: 101, ppid: 100, command: "/x/unknown", environment: ["CLAUDE_CONFIG_DIR": "/u/.claude-rotate/accounts/a"])
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [launcher, child]).isEmpty)
    }

    func testLauncherItselfIsNotAHolder() {
        let launcher = P(pid: 100, ppid: 1, command: "node /x/happy-coder/dist/claude_local_launcher.cjs", environment: ["HOME": "/u"])
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [launcher]).isEmpty)
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeLauncher(launcher))
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeLauncher(P(pid: 1, command: "/Applications/Claude.app/Contents/MacOS/Claude", environment: [:])))
        XCTAssertFalse(MainLoginSwapPolicy.isClaudeLauncher(P(pid: 1, command: "/usr/bin/happyfeet", environment: [:])))
    }

    // MARK: - F2: only the shared login's keychain entry may be written

    func testOnlyTheLegacyOrDefaultDirHashedNameIsTheSharedEntry() {
        XCTAssertTrue(MainLoginSwapPolicy.isSharedLoginServiceName("Claude Code-credentials", claudeDirectoryHash: "0a1b2c3d"))
        XCTAssertTrue(MainLoginSwapPolicy.isSharedLoginServiceName("Claude Code-credentials-0a1b2c3d", claudeDirectoryHash: "0a1b2c3d"))
        XCTAssertFalse(MainLoginSwapPolicy.isSharedLoginServiceName("Claude Code-credentials-fad1eca0", claudeDirectoryHash: "0a1b2c3d"), "another config dir's entry")
        XCTAssertFalse(MainLoginSwapPolicy.isSharedLoginServiceName("com.claudeusagetracker.profile-credentials", claudeDirectoryHash: "0a1b2c3d"))
        XCTAssertFalse(MainLoginSwapPolicy.isSharedLoginServiceName("", claudeDirectoryHash: "0a1b2c3d"))
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
