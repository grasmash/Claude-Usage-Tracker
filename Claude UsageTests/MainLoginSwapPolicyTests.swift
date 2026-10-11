import XCTest
@testable import Claude_Usage

/// The shared Claude Code login is rewritten only when nothing holds it and
/// the keychain still holds a login the tracker has seen. Pure policy; a fake
/// process list stands in for `ps`.
final class MainLoginSwapPolicyTests: XCTestCase {

    typealias P = MainLoginSwapPolicy.RunningProcess

    private func claude(_ pid: Int32, ppid: Int32 = 1, dir: String? = nil, command: String = "claude") -> P {
        P(pid: pid, ppid: ppid, command: command, configDir: dir)
    }

    /// The two listings `listRunningProcesses` takes, built from one description.
    private func listings(_ rows: [(pid: Int32, ppid: Int32, command: String, env: String)]) -> (String, String) {
        let plain = rows.map { "\($0.pid) \($0.ppid) \($0.command)" }.joined(separator: "\n")
        let withEnv = rows.map { "\($0.pid) \($0.ppid) \($0.command)\($0.env.isEmpty ? "" : " " + $0.env)" }.joined(separator: "\n")
        return (plain, withEnv)
    }

    // MARK: - ps output (two listings; environment only after the command)

    func testParsesPidPpidCommandAndConfigDirFromTwoListings() {
        let (plain, withEnv) = listings([
            (101, 900, "/opt/homebrew/bin/claude --model opus", "HOME=/Users/me CLAUDE_CONFIG_DIR=/Users/me/.claude-rotate/accounts/goose TERM=xterm"),
            (102, 901, "claude", "SHELL=/bin/zsh HOME=/Users/me"),
            (103, 1, "/usr/sbin/cfprefsd agent", ""),
        ])
        let processes = MainLoginSwapPolicy.parsePsOutput(commands: plain, withEnvironment: withEnv)
        XCTAssertEqual(processes.count, 3)
        XCTAssertEqual(processes[0].pid, 101)
        XCTAssertEqual(processes[0].ppid, 900)
        XCTAssertEqual(processes[0].command, "/opt/homebrew/bin/claude --model opus")
        XCTAssertEqual(processes[0].configDir, "/Users/me/.claude-rotate/accounts/goose")
        XCTAssertEqual(processes[1].command, "claude")
        XCTAssertNil(processes[1].configDir)
        XCTAssertEqual(processes[2].command, "/usr/sbin/cfprefsd agent")
    }

    func testLeadingSpacesFromPsColumnAlignmentAreTolerated() {
        let processes = MainLoginSwapPolicy.parsePsOutput(commands: "   7     1 claude -p hi", withEnvironment: "   7     1 claude -p hi HOME=/u")
        XCTAssertEqual(processes.first?.pid, 7)
        XCTAssertEqual(processes.first?.command, "claude -p hi")
    }

    func testConfigDirInArgumentsIsNotEnvironment() {
        // W4: `cloud answer` passes free text; it must never read as a pin.
        let argv = "claude -p ANSWER for run R: set CLAUDE_CONFIG_DIR=/x --cloud session_1"
        let processes = MainLoginSwapPolicy.parsePsOutput(commands: "500 1 \(argv)", withEnvironment: "500 1 \(argv) HOME=/Users/me")
        XCTAssertNil(processes.first?.configDir)
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: processes).map(\.pid), [500])
    }

    func testRealConfigDirAfterTheCommandIsRead() {
        let argv = "claude -p set CLAUDE_CONFIG_DIR=/x"
        let processes = MainLoginSwapPolicy.parsePsOutput(
            commands: "501 1 \(argv)", withEnvironment: "501 1 \(argv) CLAUDE_CONFIG_DIR=/Users/me/.claude-rotate/accounts/a HOME=/u")
        XCTAssertEqual(processes.first?.configDir, "/Users/me/.claude-rotate/accounts/a")
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: processes).isEmpty)
    }

    func testEnvironmentThatCannotBeAlignedLeavesConfigDirUnknown() {
        // The E listing's line does not start with the plain command (truncated
        // or missing): the process is kept and, being Claude Code, counts.
        let processes = MainLoginSwapPolicy.parsePsOutput(commands: "7 1 claude --resume x", withEnvironment: "8 1 other")
        XCTAssertEqual(processes.count, 1)
        XCTAssertNil(processes[0].configDir)
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: processes).count, 1)
    }

    func testSkipsMalformedLines() {
        XCTAssertTrue(MainLoginSwapPolicy.parsePsOutput(commands: "PID PPID COMMAND\n\nnot-a-pid 1 claude\n7 claude", withEnvironment: "").isEmpty)
    }

    // MARK: - Which processes hold the shared login

    func testBareClaudeIsASharedLoginHolder() {
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [claude(1)]).map(\.pid), [1])
    }

    func testClaudeByFullPathIsAHolder() {
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [claude(2, command: "/opt/homebrew/bin/claude --resume abc")]).map(\.pid), [2])
    }

    func testLegacyNodeCliIsAHolder() {
        let p = claude(3, command: "node /usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js")
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [p]).map(\.pid), [3])
    }

    func testClaudeOnItsOwnConfigDirIsNotAHolder() {
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [claude(4, dir: "/Users/me/.claude-rotate/accounts/goose")]).isEmpty)
    }

    func testEmptyConfigDirCountsAsTheSharedLogin() {
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [claude(5, dir: "")]).count, 1)
    }

    func testOtherProcessesAreNotHolders() {
        let others = [
            P(pid: 6, command: "/Applications/Claude Usage.app/Contents/MacOS/Claude Usage"),
            P(pid: 7, command: "grep claude"),
            P(pid: 8, command: "/bin/zsh -c claude-rotate status"),
            P(pid: 9, command: "node server.js"),
        ]
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: others).isEmpty)
    }

    func testAuthStatusProbeIsAHolderToo() {
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [claude(10, command: "claude auth status --json")]).count, 1)
    }

    // MARK: - F1: Claude Code by its versioned path, and launcher children

    func testVersionedBinaryUnderHappyIsAHolder() {
        // The exact shape measured live on 2026-10-11: happy's launcher execs the
        // updater's versioned binary with --resume and no CLAUDE_CONFIG_DIR.
        let (plain, withEnv) = listings([
            (41200, 1, "node /Users/me/.npm-global/lib/node_modules/happy-coder/dist/claude_local_launcher.cjs", "HOME=/Users/me HAPPY_SERVER_URL=https://littlewing.example"),
            (41233, 41200, "/Users/me/.local/share/claude/versions/2.1.292 --resume 3f2b7a9c-1d2e-4f5a-8b6c-7d8e9f0a1b2c", "HOME=/Users/me TERM=xterm-256color"),
        ])
        let processes = MainLoginSwapPolicy.parsePsOutput(commands: plain, withEnvironment: withEnv)
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeCode(processes[1]), "versioned binary is Claude Code")
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: processes).map(\.pid), [41233])
    }

    func testVersionedBinaryOnItsOwnConfigDirIsNotAHolder() {
        let p = claude(5, dir: "/Users/me/.claude-rotate/accounts/goose", command: "/Users/me/.local/share/claude/versions/2.1.292 --resume abc")
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeCode(p))
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [p]).isEmpty)
    }

    func testUnrecognisedChildOfALauncherIsCountedAsAHolder() {
        let launcher = P(pid: 100, ppid: 1, command: "node /x/happy-coder/dist/claude_local_launcher.cjs")
        let child = P(pid: 101, ppid: 100, command: "/Users/me/.local/share/some-new-binary --resume x")
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [launcher, child]).map(\.pid), [101])
    }

    func testLauncherChildOnItsOwnConfigDirIsNotAHolder() {
        let launcher = P(pid: 100, ppid: 1, command: "happy")
        let child = P(pid: 101, ppid: 100, command: "/x/unknown", configDir: "/u/.claude-rotate/accounts/a")
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [launcher, child]).isEmpty)
    }

    func testLauncherItselfIsNotAHolder() {
        let launcher = P(pid: 100, ppid: 1, command: "node /x/happy-coder/dist/claude_local_launcher.cjs")
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [launcher]).isEmpty)
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeLauncher(launcher))
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeLauncher(P(pid: 1, command: "/Users/me/.npm-global/bin/happy")))
        XCTAssertFalse(MainLoginSwapPolicy.isClaudeLauncher(P(pid: 1, command: "/usr/bin/happyfeet")))
    }

    func testClaudeDesktopIsNotALauncherAndItsHelpersAreNotHolders() {
        // Electron helpers under Claude.app would otherwise be permanent holders.
        let desktop = P(pid: 200, ppid: 1, command: "/Applications/Claude.app/Contents/MacOS/Claude")
        let helper = P(pid: 201, ppid: 200, command: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer) --type=renderer")
        XCTAssertFalse(MainLoginSwapPolicy.isClaudeLauncher(desktop))
        XCTAssertTrue(MainLoginSwapPolicy.sharedLoginHolders(in: [desktop, helper]).isEmpty)
    }

    func testFreeTextMentioningHappyDoesNotMakeAClaudeALauncher() {
        // Only argv0 and path-shaped tokens count, so a real claude's children
        // (MCP servers) are not mis-counted as holders.
        let claudeWithPrompt = P(pid: 300, ppid: 1, command: "claude --append-system-prompt be happy and use happy paths")
        let mcpChild = P(pid: 301, ppid: 300, command: "node /x/some-mcp-server/index.js")
        XCTAssertFalse(MainLoginSwapPolicy.isClaudeLauncher(claudeWithPrompt))
        XCTAssertEqual(MainLoginSwapPolicy.sharedLoginHolders(in: [claudeWithPrompt, mcpChild]).map(\.pid), [300], "the claude itself is the holder; its MCP child is not")
    }

    func testPathShapedHappyTokenInArgumentsDoesCount() {
        // `node /…/happy-coder/dist/claude_local_launcher.cjs` is argv1, path-shaped.
        XCTAssertTrue(MainLoginSwapPolicy.isClaudeLauncher(P(pid: 1, command: "/usr/local/bin/node /Users/me/.npm-global/lib/node_modules/happy-coder/dist/claude_local_launcher.cjs --foo")))
    }

    // MARK: - W8: processes on one config dir

    func testFindsClaudeOnTheImportDir() {
        let importDir = "/Users/me/.claude-import"
        let processes = [
            claude(1, dir: importDir),
            claude(2, dir: "/Users/me/.claude-import/"),   // trailing slash: same dir
            claude(3, dir: "/Users/me/.claude-rotate/accounts/a"),
            claude(4),
            P(pid: 5, command: "/bin/zsh", configDir: importDir),   // not claude
        ]
        XCTAssertEqual(MainLoginSwapPolicy.processes(onConfigDir: importDir, in: processes).map(\.pid), [1, 2])
    }

    // MARK: - F2: only the shared login's keychain entry may be written

    func testOnlyTheLegacyOrDefaultDirHashedNameIsTheSharedEntry() {
        XCTAssertTrue(MainLoginSwapPolicy.isSharedLoginServiceName("Claude Code-credentials", claudeDirectoryHash: "0a1b2c3d"))
        XCTAssertTrue(MainLoginSwapPolicy.isSharedLoginServiceName("Claude Code-credentials-0a1b2c3d", claudeDirectoryHash: "0a1b2c3d"))
        XCTAssertFalse(MainLoginSwapPolicy.isSharedLoginServiceName("Claude Code-credentials-fad1eca0", claudeDirectoryHash: "0a1b2c3d"), "another config dir's entry")
        XCTAssertFalse(MainLoginSwapPolicy.isSharedLoginServiceName("com.claudeusagetracker.profile-credentials", claudeDirectoryHash: "0a1b2c3d"))
        XCTAssertFalse(MainLoginSwapPolicy.isSharedLoginServiceName("", claudeDirectoryHash: "0a1b2c3d"))
    }

    // MARK: - W6: stored logins that may be copies of a pinned lineage

    func testIdenticalRefreshTokenIsACopy() {
        XCTAssertEqual(MainLoginSwapPolicy.distrust(storedRefreshToken: "r1", pinnedRefreshTokens: ["r0", "r1"], provenance: "import"), .copyOfPinnedEntry)
        XCTAssertEqual(MainLoginSwapPolicy.distrust(storedRefreshToken: "r1", pinnedRefreshTokens: ["r1"], provenance: nil), .copyOfPinnedEntry)
    }

    func testLoginWithoutProvenanceIsDistrustedForEveryProfile() {
        // W15: a login an older build stored is distrusted whether or not the
        // profile is pinned, until this build re-captures or re-imports it.
        XCTAssertEqual(MainLoginSwapPolicy.distrust(storedRefreshToken: "main", pinnedRefreshTokens: ["pinned"], provenance: nil), .unknownProvenance)
        XCTAssertEqual(MainLoginSwapPolicy.distrust(storedRefreshToken: "main", pinnedRefreshTokens: [], provenance: nil), .unknownProvenance)
    }

    func testRecordedProvenanceIsTrusted() {
        XCTAssertNil(MainLoginSwapPolicy.distrust(storedRefreshToken: "main", pinnedRefreshTokens: ["pinned"], provenance: "import"))
        XCTAssertNil(MainLoginSwapPolicy.distrust(storedRefreshToken: "main", pinnedRefreshTokens: ["pinned"], provenance: "keychain"))
    }

    // MARK: - Compare-and-swap decision

    func testRefusesWhileAnySessionHoldsTheSharedLogin() {
        XCTAssertEqual(MainLoginSwapPolicy.refusal(holders: 3, keychainFingerprint: "a", knownFingerprints: ["a"]), .sessionsRunning(count: 3))
    }

    func testRefusesALoginTheTrackerHasNotCaptured() {
        XCTAssertEqual(MainLoginSwapPolicy.refusal(holders: 0, keychainFingerprint: "rotated", knownFingerprints: ["a", "b"]), .unknownKeychainLogin)
    }

    func testAllowsWhenIdleAndKeychainIsAsLastSeen() {
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 0, keychainFingerprint: "a", knownFingerprints: ["a", "b"]))
    }

    func testAllowsWritingAnEmptyKeychain() {
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 0, keychainFingerprint: nil, knownFingerprints: []))
    }

    func testSessionsOutrankAnUnknownLogin() {
        XCTAssertEqual(MainLoginSwapPolicy.refusal(holders: 1, keychainFingerprint: "x", knownFingerprints: []), .sessionsRunning(count: 1))
    }

    func testSessionsOnASpentKeychainLoginDoNotBlock() {
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 10, keychainFingerprint: "a", knownFingerprints: ["a", "b"], keychainLoginSpent: true))
    }

    func testASpentLoginStillNeedsTheKeychainToBeAsLastSeen() {
        XCTAssertEqual(MainLoginSwapPolicy.refusal(holders: 2, keychainFingerprint: "rotated", knownFingerprints: ["a"], keychainLoginSpent: true), .unknownKeychainLogin)
    }

    // MARK: - Which stored logins are spent

    func testSpentLoginsAreThoseAtALimitWhoseWindowHasNotReset() {
        let weekly = profile("weekly", spentUsage(weekly: 100))
        let session = profile("session", spentUsage(session: 100))
        let headroom = profile("headroom", spentUsage(weekly: 99))
        let rolledOver = profile("rolled", spentUsage(weekly: 100, weeklyResetIn: -60))
        let unread = Profile(name: "unread", cliCredentialsJSON: "json-unread")

        let spent = MainLoginSwapPolicy.spentLogins(
            in: [weekly, session, headroom, rolledOver, unread], isLoginDead: { _ in false })

        XCTAssertEqual(spent, ["json-weekly", "json-session"])
    }

    func testAnOldReadingOfASpentWindowStillCounts() {
        // The tracker stops polling an account once it is no longer the active
        // profile; a 100% weekly window stays spent until its reset regardless.
        let old = profile("old", spentUsage(weekly: 100, updatedAt: Date().addingTimeInterval(-3 * 3600)))
        XCTAssertEqual(MainLoginSwapPolicy.spentLogins(in: [old], isLoginDead: { _ in false }), ["json-old"])
    }

    func testASpentFableQuotaIsNotASessionOrWeeklySpentLogin() {
        let fable = profile("fable", spentUsage(fable: 100))
        XCTAssertEqual(MainLoginSwapPolicy.spentLogins(in: [fable], isLoginDead: { _ in false }), [])
    }

    func testFableSpentLoginsAreThoseWhoseFableWeeklyIsAt100() {
        let fable = profile("fable", spentUsage(fable: 100))
        let weekly = profile("weekly", spentUsage(weekly: 100))
        let some = profile("some", spentUsage(fable: 80))
        XCTAssertEqual(MainLoginSwapPolicy.fableSpentLogins(in: [fable, weekly, some]), ["json-fable"])
    }

    // MARK: - Is Fable in use by the sessions holding the shared login?

    func testFableIsInUseOnlyWhenEveryHolderIsOnFable() {
        let holders: [MainLoginSwapPolicy.RunningProcess] = [
            .init(pid: 1, command: "claude", configDir: nil), .init(pid: 2, command: "claude", configDir: nil)]
        let models: [Int32: String] = [1: "claude-fable-5-1", 2: "claude-fable-5-1"]
        XCTAssertTrue(MainLoginSwapPolicy.allHoldersOnFable(holders, modelOf: { models[$0] }))
        XCTAssertFalse(MainLoginSwapPolicy.allHoldersOnFable(holders, modelOf: { $0 == 1 ? "claude-fable-5-1" : "claude-opus-5-5" }),
                       "a holder on Opus is working; it is not stranded")
        XCTAssertFalse(MainLoginSwapPolicy.allHoldersOnFable(holders, modelOf: { $0 == 1 ? "claude-fable-5-1" : nil }),
                       "a holder whose model is unknown is not assumed stranded")
        XCTAssertFalse(MainLoginSwapPolicy.allHoldersOnFable([], modelOf: { _ in "claude-fable-5-1" }))
    }

    func testAHolderModelIsReadFromItsOwnSessionTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions")
        let project = root.appendingPathComponent("projects/-Users-me-work")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"pid":4242,"sessionId":"sess-1","cwd":"/Users/me/work"}"#.write(
            to: sessions.appendingPathComponent("4242.json"), atomically: true, encoding: .utf8)
        try """
        {"type":"assistant","message":{"model":"claude-fable-5-1","content":[]}}
        {"type":"assistant","message":{"model":"<synthetic>","content":[]}}
        """.write(to: project.appendingPathComponent("sess-1.jsonl"), atomically: true, encoding: .utf8)
        try #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[]}}"#.write(
            to: project.appendingPathComponent("other.jsonl"), atomically: true, encoding: .utf8)

        XCTAssertEqual(MainLoginSwapPolicy.holderModel(pid: 4242, sessionsDirectory: sessions, projectsDirectory: root.appendingPathComponent("projects")), "claude-fable-5-1")
        XCTAssertNil(MainLoginSwapPolicy.holderModel(pid: 999, sessionsDirectory: sessions, projectsDirectory: root.appendingPathComponent("projects")))
    }

    func testADeadLoginIsSpent() {
        let dead = profile("dead", spentUsage(weekly: 10))
        XCTAssertEqual(MainLoginSwapPolicy.spentLogins(in: [dead], isLoginDead: { $0.name == "dead" }), ["json-dead"])
    }

    private func profile(_ name: String, _ usage: ClaudeUsage) -> Profile {
        var p = Profile(name: name, cliCredentialsJSON: "json-\(name)")
        p.claudeUsage = usage
        return p
    }

    private func spentUsage(
        session: Double = 0, weekly: Double = 0, fable: Double = 0,
        weeklyResetIn: TimeInterval = 86400, updatedAt: Date = Date()
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0, sessionLimit: 0, sessionPercentage: session,
            sessionResetTime: Date().addingTimeInterval(3600),
            weeklyTokensUsed: 0, weeklyLimit: 1_000_000, weeklyPercentage: weekly,
            weeklyResetTime: Date().addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0, designWeeklyPercentage: 0, designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0, fableWeeklyPercentage: fable,
            fableWeeklyResetTime: Date().addingTimeInterval(86400),
            costUsed: nil, costLimit: nil, costCurrency: nil,
            lastUpdated: updatedAt, userTimezone: .current)
    }

    // MARK: - One tracker per user

    func testQuitsWhenAnotherInstanceRuns() {
        XCTAssertTrue(MainLoginSwapPolicy.shouldQuitAsDuplicateInstance(myPid: 10, instancePids: [10, 42]))
        XCTAssertFalse(MainLoginSwapPolicy.shouldQuitAsDuplicateInstance(myPid: 10, instancePids: [10]))
        XCTAssertFalse(MainLoginSwapPolicy.shouldQuitAsDuplicateInstance(myPid: 10, instancePids: []))
    }
}
