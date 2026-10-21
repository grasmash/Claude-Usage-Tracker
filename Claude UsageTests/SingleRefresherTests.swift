import XCTest
@testable import Claude_Usage

/// Each Claude Code login has exactly one refresher. The tracker reads logins
/// and never refreshes or rewrites one that any `claude` process holds:
/// pinned entries are read-only, the shared login is never refreshed, and it
/// is rewritten only when idle, over a login the tracker has seen, in place.
///
/// `security` and the token endpoint are replaced with recorders, so these
/// tests prove the absence of network calls and keychain writes directly.
final class SingleRefresherTests: XCTestCase {

    private let sync = ClaudeCodeSyncService.shared
    private let mainService = "Claude Code-credentials"
    private let pinnedService = "Claude Code-credentials-0a1b2c3d"

    /// Fake keychain: service name -> stored JSON.
    private var keychain: [String: String] = [:]
    private var securityCalls: [[String]] = []
    private var refreshCalls = 0
    /// nil = "ps failed", which the swap must treat as unknown (C1).
    private var processes: [MainLoginSwapPolicy.RunningProcess]? = []
    private var holderModels: [Int32: String] = [:]
    private var savedHolderModel: ((Int32) -> String?)!
    private var tempDir: URL!

    private var savedRunner: ((_ arguments: [String], _ timeout: TimeInterval) -> ClaudeCodeSyncService.SecurityCommandResult?)!
    private var savedRefresher: ((_ refreshToken: String) async throws -> ClaudeCodeSyncService.OAuthRefreshResponse)!
    private var savedProcesses: (() -> [MainLoginSwapPolicy.RunningProcess]?)!
    private var savedCredentialsFile: URL!
    private var savedSessionsDirectory: URL!
    private var savedProjectsDirectory: URL!

    override func setUp() {
        super.setUp()
        savedRunner = sync.securityCommandRunner
        savedRefresher = sync.tokenRefresher
        savedProcesses = sync.runningProcesses
        savedHolderModel = sync.holderModel
        holderModels = [:]
        savedCredentialsFile = sync.credentialsFileURL
        savedSessionsDirectory = sync.sessionsDirectory
        savedProjectsDirectory = sync.projectsDirectory
        savedCloudRunsURL = sync.cloudRunsURL
        savedRotateConfigURL = sync.rotateConfigURL
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sync.cloudRunsURL = tempDir.appendingPathComponent("runs.ndjson")          // absent: no cloud runs
        sync.rotateConfigURL = tempDir.appendingPathComponent("rotate-config.json")
        sync.sessionsDirectory = tempDir.appendingPathComponent("sessions")
        sync.projectsDirectory = tempDir.appendingPathComponent("projects")
        sync.resetHandoffRecordsForTesting()

        keychain = [:]
        securityCalls = []
        refreshCalls = 0
        processes = []

        // Pin the resolved entry to the legacy shared name: the real resolution
        // chain persists to UserDefaults.standard, which a test must not touch.
        sync.setResolvedServiceNameForTesting(mainService)
        sync.credentialsFileURL = tempDir.appendingPathComponent(".credentials.json")
        sync.runningProcesses = { [unowned self] in self.processes }
        sync.holderModel = { [unowned self] pid in self.holderModels[pid] }
        sync.tokenRefresher = { [unowned self] _ in
            self.refreshCalls += 1
            return ClaudeCodeSyncService.OAuthRefreshResponse(
                access_token: "new-access", refresh_token: "new-refresh", expires_in: 3600, token_type: "Bearer")
        }
        sync.securityCommandRunner = { [unowned self] arguments, _ in
            self.securityCalls.append(arguments)
            func result(_ code: Int32, _ out: String = "") -> ClaudeCodeSyncService.SecurityCommandResult {
                .init(exitCode: code, stdout: out, stderr: "", timedOut: false)
            }
            guard let verb = arguments.first,
                  let s = arguments.firstIndex(of: "-s"), s + 1 < arguments.count else { return result(1) }
            let service = arguments[s + 1]
            switch verb {
            case "find-generic-password":
                guard let json = self.keychain[service] else { return result(44) }
                return result(0, arguments.contains("-w") ? json : "attributes")
            case "add-generic-password":
                guard let w = arguments.firstIndex(of: "-w"), w + 1 < arguments.count else { return result(1) }
                self.keychain[service] = arguments[w + 1]
                return result(0)
            case "delete-generic-password":
                self.keychain[service] = nil
                return result(0)
            default:
                return result(1)
            }
        }
    }

    override func tearDown() {
        sync.setResolvedServiceNameForTesting(nil)
        sync.securityCommandRunner = savedRunner
        sync.tokenRefresher = savedRefresher
        sync.runningProcesses = savedProcesses
        sync.holderModel = savedHolderModel
        sync.credentialsFileURL = savedCredentialsFile
        sync.sessionsDirectory = savedSessionsDirectory
        sync.projectsDirectory = savedProjectsDirectory
        sync.cloudRunsURL = savedCloudRunsURL
        sync.rotateConfigURL = savedRotateConfigURL
        sync.resetHandoffRecordsForTesting()
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func login(_ tag: String, expiresIn: TimeInterval) -> String {
        let ms = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        return #"{"claudeAiOauth":{"accessToken":"access-\#(tag)","refreshToken":"refresh-\#(tag)","expiresAt":\#(ms),"scopes":["user:inference"],"subscriptionType":"max"}}"#
    }

    private var writes: [[String]] { securityCalls.filter { ClaudeCodeSyncService.isMutatingSecurityVerb($0.first) } }

    /// An unpinned profile whose stored main login this build imported, i.e. a
    /// trusted switch target (W15: a login with no recorded origin is refused).
    private var savedCloudRunsURL: URL!
    private var savedRotateConfigURL: URL!

    /// A live claude-rotate cloud run launched on the account named `account` (email `email`).
    /// `throughSharedLogin` (the default) records it the way `cloud` does for a run
    /// reached through the stock ~/.claude login (`"via":"default"`): the only kind
    /// that can hold the tracker's stored main login. `false` is a run launched
    /// under the account's own claude-rotate dir (`CLAUDE_CONFIG_DIR`).
    private func startCloudRun(account: String, email: String, ended: Bool = false, throughSharedLogin: Bool = true) throws {
        try #"{"accounts":[{"name":"\#(account)","email":"\#(email)"}]}"#.write(to: sync.rotateConfigURL, atomically: true, encoding: .utf8)
        let ts = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-600))
        let via = throughSharedLogin ? #","via":"default""# : ""
        var lines = [#"{"run":"r1","created":"\#(ts)"}"#, #"{"run":"r1","account":"\#(account)","launched":"\#(ts)"\#(via)}"#]
        if ended { lines.append(#"{"run":"r1","closed":"\#(ts)"}"#) }
        try lines.joined(separator: "\n").write(to: sync.cloudRunsURL, atomically: true, encoding: .utf8)
    }

    private func imported(_ name: String, _ json: String) -> Profile {
        var p = Profile(name: name, cliCredentialsJSON: json)
        p.mainLoginProvenance = "import"
        return p
    }

    /// Fails `find-generic-password` on the shared entry only AFTER a write has
    /// happened, `times` times, then behaves again; for the post-write verify.
    private func failFindAfterWrite(times: Int, with failure: ClaudeCodeSyncService.SecurityCommandResult?) {
        let inner = sync.securityCommandRunner
        var written = false
        var failures = 0
        sync.securityCommandRunner = { [unowned self] arguments, timeout in
            if arguments.first == "add-generic-password" { written = true }
            if written, failures < times, arguments.first == "find-generic-password", arguments.contains(self.mainService) {
                failures += 1
                self.securityCalls.append(arguments)
                return failure
            }
            return inner(arguments, timeout)
        }
    }

    private func bareClaude(_ pid: Int32) -> MainLoginSwapPolicy.RunningProcess {
        .init(pid: pid, command: "claude", configDir: nil)
    }

    private func rotateClaude(_ pid: Int32) -> MainLoginSwapPolicy.RunningProcess {
        .init(pid: pid, command: "claude", configDir: "/Users/me/.claude-rotate/accounts/goose")
    }

    /// A security runner whose `find-generic-password` fails the given way
    /// while everything else behaves; for C2.
    private func failingFind(_ failure: ClaudeCodeSyncService.SecurityCommandResult?) {
        let inner = sync.securityCommandRunner
        sync.securityCommandRunner = { [unowned self] arguments, timeout in
            if arguments.first == "find-generic-password", arguments.contains(self.mainService) {
                self.securityCalls.append(arguments)
                return failure
            }
            return inner(arguments, timeout)
        }
    }

    // MARK: - A1: pinned profiles are read-only

    func testExpiredPinnedEntryIsReadButNeverRefreshedOrWritten() {
        keychain[pinnedService] = login("pinned", expiresIn: -3600)
        let profile = Profile(name: "goose", customKeychainServiceName: pinnedService)

        let json = sync.usableCredentials(for: profile, isActive: false)

        XCTAssertEqual(json, keychain[pinnedService], "the stale login is reported as is")
        XCTAssertEqual(refreshCalls, 0, "no network refresh of a login claude-rotate sessions own")
        XCTAssertTrue(writes.isEmpty, "no keychain write: \(writes)")
    }

    func testPinnedEntryAboutToExpireIsNotRefreshedEither() {
        // Inside the old 60-second leeway window, where the tracker used to
        // refresh — at the same moment the pinned dir's sessions did.
        keychain[pinnedService] = login("pinned", expiresIn: 30)
        let profile = Profile(name: "goose", customKeychainServiceName: pinnedService)

        _ = sync.usableCredentials(for: profile, isActive: true)

        XCTAssertEqual(refreshCalls, 0)
        XCTAssertTrue(writes.isEmpty)
    }

    func testUsageReadsOfAnExpiredPinnedEntryCountAsStale() {
        keychain[pinnedService] = login("pinned", expiresIn: -60)
        let profile = Profile(name: "goose", customKeychainServiceName: pinnedService)
        let json = sync.usableCredentials(for: profile, isActive: false)!
        XCTAssertTrue(sync.isTokenExpired(json), "the caller falls back to last-known usage")
    }

    // MARK: - A2: the shared (active) login is never refreshed

    func testExpiredSharedLoginOfTheActiveProfileIsNotRefreshed() {
        // Expired for hours: the old 15-minute grace would have refreshed it.
        keychain[mainService] = login("main", expiresIn: -4 * 3600)
        let profile = Profile(name: "me", cliCredentialsJSON: keychain[mainService])

        let json = sync.usableCredentials(for: profile, isActive: true)

        XCTAssertEqual(json, keychain[mainService])
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertTrue(writes.isEmpty)
    }

    func testInactiveUnpinnedSnapshotIsNotRefreshed() {
        let stored = login("idle", expiresIn: -86_400)
        let profile = Profile(name: "idle", cliCredentialsJSON: stored)

        XCTAssertEqual(sync.usableCredentials(for: profile, isActive: false), stored)
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: - A3: running sessions FOLLOW the swap (2026-10-14)
    //
    // Measured against Claude Code 2.1.299 (claude-rotate, tests/
    // test_session_follows_login.sh): a session stats ~/.claude/.credentials.json
    // before every request and re-reads the keychain when its mtime changed. So
    // the swap is written under running sessions, the stub is touched, and they
    // pick the new login up before their next request. Until this date they
    // REFUSED the swap, which on 2026-10-14 held jrand's sessions on a 90-98%
    // account for eleven ticks until the limit killed ~20 agents.

    func testSwitchUnderABareClaudeSessionWritesAndSignalsIt() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500), rotateClaude(501)]
        let b = imported("B", login("B", expiresIn: 3600))
        let creds = sync.credentialsFileURL
        FileManager.default.createFile(atPath: creds.path, contents: Data())
        let past = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: creds.path)

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0), "the bare session was there before the write; none raced it")
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
        XCTAssertEqual(writes.count, 1, "exactly one in-place write: \(writes)")
        let mtime = try FileManager.default.attributesOfItem(atPath: creds.path)[.modificationDate] as? Date
        XCTAssertGreaterThan(mtime ?? past, past, "the session is told to reload onto B")
        let record = sync.handoffRecord(for: try XCTUnwrap(sync.systemLoginFingerprint(a)))
        XCTAssertEqual(record?.holderPids, [500], "the bare session holds A's lineage until it releases it; the rotate session never held it")
    }

    func testAMissingCredentialsStubIsCreatedSoSessionsCanFollow() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500)]
        let b = imported("B", login("B", expiresIn: 3600))
        let creds = sync.credentialsFileURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: creds.path))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0, strandedSignalled: true))
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
        let attrs = try FileManager.default.attributesOfItem(atPath: creds.path)
        XCTAssertEqual(attrs[.size] as? Int, 0, "the stub is 0 bytes: never a credential")
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the stub is 0600, like reload-signal.sh's")
    }

    func testTheSignalIsSentEvenWhenNoHolderWasSeen() async throws {
        // The listing can miss a session (libproc fallback, one that started
        // during the write); the touch is free when nobody is listening.
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = []
        let b = imported("B", login("B", expiresIn: 3600))
        let creds = sync.credentialsFileURL
        FileManager.default.createFile(atPath: creds.path, contents: Data())
        let past = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: creds.path)

        _ = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        let mtime = try FileManager.default.attributesOfItem(atPath: creds.path)[.modificationDate] as? Date
        XCTAssertGreaterThan(mtime ?? past, past)
    }

    func testSwitchIsRefusedWhenTheKeychainChangesDuringTheStoredLoginRefresh() async throws {
        // A session refreshed (or the user ran /login) while the tracker was
        // refreshing B's expired stored login: the compare-and-swap is re-done
        // right before the write.
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        let b = imported("B", login("B", expiresIn: -600))
        let rotated = login("A-rotated", expiresIn: 3600)
        let inner = sync.tokenRefresher
        sync.tokenRefresher = { [unowned self] token in
            self.keychain[self.mainService] = rotated
            return try await inner(token)
        }

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.unknownKeychainLogin))
        XCTAssertEqual(keychain[mainService], rotated, "the rotated login is never overwritten")
        XCTAssertFalse(securityCalls.contains { $0.first == "add-generic-password" && $0.contains(self.mainService) },
                       "no write to the shared entry: \(writes)")
    }

    func testHoldersOnAnyModelFollowTheSwap() async throws {
        // The holders' model no longer matters to the swap decision.
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500), bareClaude(501)]
        holderModels = [500: "claude-fable-5-1", 501: "claude-opus-5-5"]
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
        XCTAssertEqual(sync.handoffRecord(for: try XCTUnwrap(sync.systemLoginFingerprint(a)))?.holderPids.sorted(), [500, 501])
    }

    func testHoldersNeverOverrideTheCompareAndSwap() async throws {
        keychain[mainService] = login("fresh-login", expiresIn: 3600)
        processes = [bareClaude(500)]
        let a = login("A", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.unknownKeychainLogin), "the keychain holds a login the tracker never captured")
        XCTAssertTrue(writes.isEmpty)
    }

    func testSwitchIsRefusedOverALoginTheTrackerNeverCaptured() async throws {
        keychain[mainService] = login("fresh-login", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [b.cliCredentialsJSON!, login("A", expiresIn: 3600)])

        XCTAssertEqual(outcome, .refused(.unknownKeychainLogin))
        XCTAssertEqual(keychain[mainService]?.contains("refresh-fresh-login"), true)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testSwitchWritesInPlaceWhenIdleAndTheKeychainIsAsLastSeen() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
        XCTAssertEqual(writes.count, 1, "exactly one write: \(writes)")
        XCTAssertEqual(writes.first?.first, "add-generic-password")
        XCTAssertTrue(writes.first?.contains("-U") ?? false, "in-place update")
        XCTAssertFalse(securityCalls.contains { $0.first == "delete-generic-password" }, "never delete-then-add")
        XCTAssertEqual(refreshCalls, 0, "a valid stored login is written as is")
    }

    func testStoredLoginIsRefreshedOnlyAfterTheGuardPasses() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        let b = imported("B", login("B", expiresIn: -600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(refreshCalls, 1, "the tracker is the stored login's only holder at this point")
        XCTAssertEqual(keychain[mainService]?.contains("new-refresh"), true, "the rotated login is what was written")
    }

    func testSwitchLeavesTheKeychainAloneWhenItAlreadyHoldsThatLogin() async throws {
        // Switching back to the account the shared login already is: Claude
        // Code's sessions own that lineage, even if it has expired.
        let b = login("B", expiresIn: -600)
        keychain[mainService] = b
        let profile = imported("B", b)
        processes = [bareClaude(1)]

        let outcome = try await sync.switchMainLogin(to: profile, knownLogins: [b])

        XCTAssertEqual(outcome, .alreadyApplied)
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertTrue(writes.isEmpty)
    }

    func testAPinnedEntryIsNeverCopiedIntoTheSharedLogin() async {
        keychain[mainService] = login("A", expiresIn: 3600)
        keychain[pinnedService] = login("pinned", expiresIn: 3600)
        let pinned = Profile(name: "goose", cliCredentialsJSON: keychain[pinnedService], customKeychainServiceName: pinnedService, hasOwnMainLogin: false)

        do {
            _ = try await sync.switchMainLogin(to: pinned, knownLogins: [keychain[mainService]!])
            XCTFail("expected noProfileCredentials")
        } catch {
            XCTAssertTrue(writes.isEmpty)
            XCTAssertEqual(refreshCalls, 0)
        }
    }

    func testSwitchWritesAnEmptyKeychain() async throws {
        let b = imported("B", login("B", expiresIn: 3600))
        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [b.cliCredentialsJSON!])
        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
    }

    // MARK: - F1: a Claude Code run by its versioned path counts as a holder

    func testHappyRunningClaudeByItsVersionedPathIsRecordedAsAHolder() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        processes = MainLoginSwapPolicy.parsePsOutput(
            commands: """
            41200 1 node /Users/me/.npm-global/lib/node_modules/happy-coder/dist/claude_local_launcher.cjs
            41233 41200 /Users/me/.local/share/claude/versions/2.1.292 --resume 3f2b7a9c-1d2e-4f5a-8b6c-7d8e9f0a1b2c
            """,
            withEnvironment: """
            41200 1 node /Users/me/.npm-global/lib/node_modules/happy-coder/dist/claude_local_launcher.cjs HOME=/Users/me
            41233 41200 /Users/me/.local/share/claude/versions/2.1.292 --resume 3f2b7a9c-1d2e-4f5a-8b6c-7d8e9f0a1b2c HOME=/Users/me
            """)
        let b = imported("B", login("B", expiresIn: 3600))
        let a = keychain[mainService]!

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(sync.handoffRecord(for: try XCTUnwrap(sync.systemLoginFingerprint(a)))?.holderPids, [41233],
                       "the versioned-binary claude under happy holds A's lineage; the launcher itself does not")
    }

    // MARK: - F2: never write a keychain entry that is not the shared login's

    func testSwitchRefusesWhenTheResolvedEntryIsAPinnedOne() async throws {
        // resolveServiceName landed on another config dir's entry (e.g. a stale
        // persisted resolution). Writing it would hand that dir's sessions a
        // second holder's login.
        sync.setResolvedServiceNameForTesting(pinnedService)
        keychain[pinnedService] = login("pinned", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: -600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [b.cliCredentialsJSON!, keychain[pinnedService]!])

        XCTAssertEqual(outcome, .refused(.notTheSharedLoginEntry(service: pinnedService)))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertEqual(keychain[pinnedService]?.contains("refresh-pinned"), true)
    }

    func testTheDefaultDirHashedNameIsAcceptedAsTheSharedEntry() async throws {
        let hashed = "Claude Code-credentials-\(sync.defaultClaudeDirectoryHash)"
        sync.setResolvedServiceNameForTesting(hashed)
        keychain[hashed] = login("A", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[hashed]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(keychain[hashed], b.cliCredentialsJSON)
    }

    // MARK: - F3: concurrent switches are serialised

    func testConcurrentSwitchesYieldOneRefreshAndOneWrite() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        let b = imported("B", login("B", expiresIn: -600))
        let known = [a, b.cliCredentialsJSON!]

        async let first = sync.switchMainLogin(to: b, knownLogins: known)
        async let second = sync.switchMainLogin(to: b, knownLogins: known)
        let outcomes = try await [first, second]

        XCTAssertEqual(refreshCalls, 1, "the second switch never refreshed")
        XCTAssertEqual(writes.count, 1, "one write: \(writes)")
        XCTAssertEqual(outcomes.filter { $0 == .applied(racedHolders: 0) }.count, 1, "exactly one switch wrote: \(outcomes)")
        // The second call runs after the first (mutex) and holds the by-value
        // Profile whose stored login the first call just refreshed, so to it the
        // keychain holds a rotated, unknown login: the compare-and-swap refuses
        // rather than overwrite it. (The id-based wrapper reloads the store and
        // sees `.alreadyApplied` instead.) Either way: no second refresh, no
        // second write.
        let other = outcomes.first { $0 != .applied(racedHolders: 0) }
        XCTAssertTrue(other == .alreadyApplied || other == .refused(.unknownKeychainLogin), "\(outcomes)")
    }

    // MARK: - F4: the keychain is authoritative; the file only when there is no item

    func testKeychainWinsOverAFresherPlaintextFile() throws {
        let stale = login("keychain", expiresIn: 60)
        keychain[mainService] = stale
        try login("file", expiresIn: 36_000).write(to: sync.credentialsFileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(try sync.readSystemCredentials(), stale)
    }

    func testFileIsUsedOnlyWhenThereIsNoKeychainItem() throws {
        let file = login("file", expiresIn: 3600)
        try file.write(to: sync.credentialsFileURL, atomically: true, encoding: .utf8)

        XCTAssertEqual(try sync.readSystemCredentials(), file)
    }

    // MARK: - F5: a holder that appears during the switch is reported

    func testAHolderAppearingAfterTheWriteIsReported() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        let b = imported("B", login("B", expiresIn: 3600))
        var scans = 0
        sync.runningProcesses = { [unowned self] in
            scans += 1
            return scans == 1 ? [] : [self.bareClaude(77)]   // idle at the guard, a session right after the write
        }

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 1))
        XCTAssertEqual(scans, 2, "scanned before and after the write")
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON, "the write itself was legitimate at the time")
    }

    // MARK: - C1: no process list means refuse, never "no holders"

    func testSwitchIsRefusedWhenProcessesCannotBeListed() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        processes = nil
        let b = imported("B", login("B", expiresIn: -600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.processListUnavailable))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testAFailedRescanIsReportedAsUnverified() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: 3600))
        var scans = 0
        sync.runningProcesses = { scans += 1; return scans == 1 ? [] : nil }

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: nil))
    }

    // MARK: - C2: only "not found" is an empty keychain; everything else is unknown

    func testSwitchIsRefusedWhenTheKeychainReadTimesOut() async throws {
        failingFind(.init(exitCode: -1, stdout: "", stderr: "timeout", timedOut: true))
        let b = imported("B", login("B", expiresIn: -600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.keychainUnreadable))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testSwitchIsRefusedWhenSecurityCannotBeLaunched() async throws {
        failingFind(nil)
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.keychainUnreadable))
        XCTAssertTrue(writes.isEmpty)
    }

    func testSwitchIsRefusedOnAKeychainReadError() async throws {
        failingFind(.init(exitCode: 36, stdout: "", stderr: "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.", timedOut: false))
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.keychainUnreadable))
        XCTAssertTrue(writes.isEmpty)
    }

    func testExit44IsAnEmptyKeychainAndMayBeWritten() async throws {
        // The default stub answers 44 for a missing entry: this is the empty case.
        let b = imported("B", login("B", expiresIn: 3600))
        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [b.cliCredentialsJSON!])
        XCTAssertEqual(outcome, .applied(racedHolders: 0))
    }

    // MARK: - W4: free text in argv never hides a holder

    func testConfigDirMentionedInArgumentsDoesNotHideAHolder() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        let argv = "claude -p ANSWER for cloud run R: set CLAUDE_CONFIG_DIR=/x in the plist --cloud session_1"
        processes = MainLoginSwapPolicy.parsePsOutput(
            commands: "500 1 \(argv)",
            withEnvironment: "500 1 \(argv) HOME=/Users/me TERM=xterm")
        let b = imported("B", login("B", expiresIn: 3600))
        let a = keychain[mainService]!

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(sync.handoffRecord(for: try XCTUnwrap(sync.systemLoginFingerprint(a)))?.holderPids, [500],
                       "free text naming CLAUDE_CONFIG_DIR does not hide the holder from the record")
    }

    // MARK: - W6: a stored login that may be a copy of a pinned lineage is never written

    func testStoredLoginEqualToAPinnedEntryIsRefused() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        let pinnedJSON = login("goose-pinned", expiresIn: 3600)
        keychain[pinnedService] = pinnedJSON
        var goose = Profile(name: "goose", cliCredentialsJSON: pinnedJSON, customKeychainServiceName: pinnedService, hasOwnMainLogin: true)
        goose.mainLoginProvenance = "import"   // even a recorded origin does not excuse an identical token

        let outcome = try await sync.switchMainLogin(to: goose, knownLogins: [keychain[mainService]!, pinnedJSON], pinnedLogins: [pinnedJSON])

        XCTAssertEqual(outcome, .refused(.untrustedStoredLogin(.copyOfPinnedEntry)))
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testPinnedProfilesLoginFromAnOlderBuildIsRefusedUntilReimported() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        keychain[pinnedService] = login("goose-pinned", expiresIn: 3600)
        let goose = Profile(name: "goose", cliCredentialsJSON: login("goose-main", expiresIn: 3600),
                            customKeychainServiceName: pinnedService, hasOwnMainLogin: true)
        XCTAssertNil(goose.mainLoginProvenance, "precondition: no record of where the login came from")

        let outcome = try await sync.switchMainLogin(to: goose, knownLogins: [keychain[mainService]!, goose.cliCredentialsJSON!], pinnedLogins: [keychain[pinnedService]!])

        XCTAssertEqual(outcome, .refused(.untrustedStoredLogin(.unknownProvenance)))
        XCTAssertTrue(writes.isEmpty)
    }

    func testPinnedProfilesImportedLoginIsWritten() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        keychain[pinnedService] = login("goose-pinned", expiresIn: 3600)
        var goose = Profile(name: "goose", cliCredentialsJSON: login("goose-main", expiresIn: 3600),
                            customKeychainServiceName: pinnedService, hasOwnMainLogin: true)
        goose.mainLoginProvenance = "import"

        let outcome = try await sync.switchMainLogin(to: goose, knownLogins: [keychain[mainService]!, goose.cliCredentialsJSON!], pinnedLogins: [keychain[pinnedService]!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(keychain[mainService], goose.cliCredentialsJSON)
    }

    func testUnpinnedLoginFromAnOlderBuildIsRefusedUntilRecaptured() async throws {
        // W15: with no record of where it came from, even an unpinned profile's
        // stored login may be a copy some session still holds.
        keychain[mainService] = login("A", expiresIn: 3600)
        let b = Profile(name: "B", cliCredentialsJSON: login("B", expiresIn: 3600))
        XCTAssertNil(b.mainLoginProvenance)

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.untrustedStoredLogin(.unknownProvenance)))
        XCTAssertTrue(writes.isEmpty)
    }

    func testRecapturedLoginIsTrustedAgain() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        var b = Profile(name: "B", cliCredentialsJSON: login("B", expiresIn: 3600))
        b.mainLoginProvenance = "keychain"   // what captureMainLogin stamps within a cycle

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])
        XCTAssertEqual(outcome, .applied(racedHolders: 0))
    }

    func testAlreadyAppliedWinsOverProvenanceDistrust() async throws {
        // The keychain already holds this (older-build) login: nothing to write,
        // nothing to distrust; a refusal here would clear pending and nag.
        let b = login("B", expiresIn: 3600)
        keychain[mainService] = b
        let outcome = try await sync.switchMainLogin(to: Profile(name: "B", cliCredentialsJSON: b), knownLogins: [b])
        XCTAssertEqual(outcome, .alreadyApplied)
    }

    // MARK: - NIT 1: the post-write verify never turns a successful write into "apply failed"

    func testPostWriteReadTimeoutIsRetriedOnce() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: 3600))
        failFindAfterWrite(times: 1, with: .init(exitCode: -1, stdout: "", stderr: "timeout", timedOut: true))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0), "the retry read the written login back")
        XCTAssertEqual(writes.count, 1)
    }

    func testPostWriteReadFailingTwiceReportsAppliedButUnverified() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: 3600))
        failFindAfterWrite(times: 2, with: .init(exitCode: -1, stdout: "", stderr: "timeout", timedOut: true))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: nil), "written, unverified — never a thrown 'apply failed'")
        XCTAssertEqual(writes.count, 1, "no second write")
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
    }

    func testPostWriteMismatchIsStillAFailedWrite() async throws {
        // The entry reads back as something else: that IS a failed write.
        keychain[mainService] = login("A", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: 3600))
        let inner = sync.securityCommandRunner
        sync.securityCommandRunner = { arguments, timeout in
            let r = inner(arguments, timeout)
            if arguments.first == "add-generic-password" { self.keychain[self.mainService] = self.login("other", expiresIn: 3600) }
            return r
        }
        do {
            _ = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])
            XCTFail("expected keychainWriteFailed")
        } catch ClaudeCodeError.keychainWriteFailed {
        }
    }

    func testProvenanceRoundTripsThroughCoding() throws {
        var p = Profile(name: "p")
        p.mainLoginProvenance = "import"
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: data).mainLoginProvenance, "import")
        XCTAssertNil(try JSONDecoder().decode(Profile.self, from: JSONEncoder().encode(Profile(name: "old"))).mainLoginProvenance)
    }

    // MARK: - A4: no plaintext mirror

    func testSwitchDoesNotWriteThePlaintextCredentialsMirror() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        let b = imported("B", login("B", expiresIn: 3600))

        _ = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        // The keychain is the only store. The file exists only as the 0-byte
        // reload-signal stub (created by the switch so sessions can follow).
        let attrs = try FileManager.default.attributesOfItem(atPath: sync.credentialsFileURL.path)
        XCTAssertEqual(attrs[.size] as? Int, 0, "no copy of any login on disk")
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAnExistingMirrorIsLeftUntouchedBySwitch() async throws {
        // Earlier builds wrote this file; it must not be rewritten with the new login.
        let stale = "{\"stale\":true}"
        try stale.write(to: sync.credentialsFileURL, atomically: true, encoding: .utf8)
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        let b = imported("B", login("B", expiresIn: 3600))

        _ = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(try String(contentsOf: sync.credentialsFileURL, encoding: .utf8), stale)
    }

    // MARK: - Test seams fail closed

    func testDefaultSecurityRunnerRefusesMutationsUnderTests() {
        sync.securityCommandRunner = savedRunner
        XCTAssertThrowsError(try sync.writeKeychainCredentials(serviceName: "Claude Code-credentials-test-\(UUID())", jsonData: "{}"))
    }

    func testMutatingVerbsAreRecognised() {
        XCTAssertTrue(ClaudeCodeSyncService.isMutatingSecurityVerb("add-generic-password"))
        XCTAssertTrue(ClaudeCodeSyncService.isMutatingSecurityVerb("delete-generic-password"))
        XCTAssertFalse(ClaudeCodeSyncService.isMutatingSecurityVerb("find-generic-password"))
        XCTAssertFalse(ClaudeCodeSyncService.isMutatingSecurityVerb("dump-keychain"))
    }

    // MARK: - Probe D (gate on 2070d8b): switching INTO a dead login
    //
    // A presumed-free target's reading is stale because its token expired, so
    // every such switch refreshes the stored login; a rejected refresh must
    // leave the tracker on the spent account, mark the target dead, and make
    // the next tick skip it. `ProfileManager.activateProfile` itself is not
    // driven here: the singleton writes the real statusline config and posts
    // notifications under the test host. Its decision is
    // `AutoSwitchPolicy.activateAfterMainLoginSwitch` (AutoSwitchPolicyTests).

    private func staleFreeUsage() -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = 100
        u.sessionResetTime = Date().addingTimeInterval(-4 * 3600)   // window long passed
        u.lastUpdated = Date().addingTimeInterval(-5 * 3600)
        return u
    }

    func testProbeD_aRejectedStoredLoginRefreshThrowsMarksItDeadAndTheNextTickSkipsIt() async {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        var spentA = imported("A", a)
        spentA.claudeUsage = ClaudeUsage.empty
        spentA.claudeUsage?.sessionPercentage = 100
        var b = imported("B", login("B-dead-\(UUID().uuidString.prefix(6))", expiresIn: -600))
        b.claudeUsage = staleFreeUsage()
        sync.tokenRefresher = { [unowned self] _ in
            self.refreshCalls += 1
            throw ClaudeCodeError.refreshFailed(status: 400, body: #"{"error":"invalid_grant","error_description":"Refresh token not found or invalid"}"#)
        }
        XCTAssertEqual(AutoSwitchPolicy.nextAvailableProfile(in: [spentA, b], after: spentA, isLoginDead: sync.isLoginDead(for:))?.id, b.id,
                       "precondition: B is the presumed-free target")

        var thrown: Error?
        do { _ = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!]) } catch { thrown = error }

        XCTAssertNotNil(thrown, "the switch throws: the stored login could not be applied")
        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(keychain[mainService], a, "A's login is untouched")
        XCTAssertTrue(sync.isLoginDead(for: b), "B is marked dead")
        XCTAssertFalse(AutoSwitchPolicy.activateAfterMainLoginSwitch(.failure(thrown!), selectedBy: "auto"),
                       "the tracker stays on A …")
        XCTAssertFalse(AutoSwitchPolicy.switchLanded(fromId: spentA.id, targetId: b.id, activeIdAfter: spentA.id),
                       "… so the auto-switch did not land and the decider re-arms")
        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [spentA, b], after: spentA, isLoginDead: sync.isLoginDead(for:)),
                     "the next tick skips B")
    }

    func testProbeD_theActiveProfileIsJudgedByItsStoredLoginWhenTheKeychainLoginIsNotProvenItsOwn() {
        // The pre-fix end state: tracker-active = B, keychain still = A.
        keychain[mainService] = login("A", expiresIn: 3600)
        let tag = UUID().uuidString.prefix(6)
        let b = imported("B", login("B-dead-\(tag)", expiresIn: -600))
        sync.deadLogins.markDead("refresh-B-dead-\(tag)")
        let previousActive = ProfileStore.shared.loadActiveProfileId()
        ProfileStore.shared.saveActiveProfileId(b.id)
        defer { if let previousActive { ProfileStore.shared.saveActiveProfileId(previousActive) } }

        XCTAssertTrue(sync.isLoginDead(for: b), "A's login in the keychain is not proven to be B's; B is judged by the login a switch would apply")
    }

    // MARK: - Gate fix 3a: a hand-off under working holders records them

    /// The swap moved working sessions off a near-limit login: the replaced
    /// lineage is written down with its holders, so it is not refreshed until
    /// they release it. (Mutant: drop `recordHandoff` -> this fails.)
    func testHandoffUnderWorkingHoldersWritesAndRecordsTheHandoff() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500), bareClaude(501),
                     .init(pid: 502, command: "/opt/homebrew/bin/node", configDir: nil, argvKnown: false)]
        let b = imported("B", login("B", expiresIn: 3600))
        FileManager.default.createFile(atPath: sync.credentialsFileURL.path, contents: Data())
        try FileManager.default.createDirectory(at: sync.sessionsDirectory, withIntermediateDirectories: true)
        try #"{"sessionId":"s"}"#.write(to: sync.sessionsDirectory.appendingPathComponent("501.json"), atomically: true, encoding: .utf8)

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .applied(racedHolders: 0))
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON, "the hand-off wrote B")
        let record = sync.handoffRecord(for: try XCTUnwrap(sync.systemLoginFingerprint(a)))
        XCTAssertEqual(record?.holderPids.sorted(), [500, 501, 502], "A's lineage is held back until its holders release it")
        XCTAssertEqual(record?.holdersWithSession, [501], "which holders were Claude Code sessions is written down")
        XCTAssertEqual(record?.holdersByNameOnly, [502], "and which were counted only as a node with unknown arguments")
        XCTAssertEqual(refreshCalls, 0)
    }

    func testNoHandoffIsRecordedWhenNothingHeldTheLogin() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = []
        let b = imported("B", login("B", expiresIn: 3600))
        _ = try await sync.switchMainLogin(to: b, knownLogins: [a, b.cliCredentialsJSON!])
        XCTAssertNil(sync.handoffRecord(for: try XCTUnwrap(sync.systemLoginFingerprint(a))))
    }

    // MARK: - Gate fix 3b: an unreleased hand-off blocks the refresh

    /// B's stored login has expired and a CLOUD run is live on B's account:
    /// refreshing it could break that run. The switch must not refresh it.
    /// (Operator, 2026-10-18: only cloud runs hold an account.)
    func testLiveCloudRunBlocksTheRefreshOfTheStoredLogin() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = []
        let bJSON = login("B", expiresIn: -600)
        let b = imported("b@x.com", bJSON)
        try startCloudRun(account: "bee", email: "b@x.com")

        do {
            _ = try await sync.switchMainLogin(to: b, knownLogins: [a, bJSON])
            XCTFail("the switch cannot proceed without a usable login")
        } catch {}

        XCTAssertEqual(refreshCalls, 0, "an account with a live cloud run was refreshed")
        XCTAssertTrue(writes.isEmpty, "\(writes)")
        XCTAssertEqual(keychain[mainService], a)
    }

    /// Replay 2026-10-18: pid 93749, an interactive session idle since before
    /// the 23:28 hand-off, pinned madmatter and left no account free. A local
    /// holder (even a live one named in the hand-off record) never holds now.
    func testIdleLocalHolderNeverBlocksTheRefreshOrTheCandidate() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = []
        let bJSON = login("B", expiresIn: -600)
        let b = imported("b@x.com", bJSON)
        sync.recordHandoff(MainLoginSwapPolicy.HandoffRecord(
            fingerprint: try XCTUnwrap(sync.systemLoginFingerprint(bJSON)), holderPids: [getpid()], at: Date()))
        XCTAssertFalse(sync.isUnavailableAsTarget(for: b), "a live local holder must not hold an account")
        _ = try? await sync.switchMainLogin(to: b, knownLogins: [a, bJSON])
        XCTAssertGreaterThan(refreshCalls, 0, "the expired stored login should have been refreshed")
    }

    // MARK: - Gate fix 4: held back + expired = not a candidate

    func testHeldBackExpiredLoginIsNotASwitchCandidate() throws {
        let bJSON = login("B", expiresIn: -600)
        let b = imported("b@x.com", bJSON)
        let c = imported("C", login("C", expiresIn: 3600))
        XCTAssertFalse(sync.isUnavailableAsTarget(for: b), "no cloud run: B is a candidate (the switch refreshes it)")

        try startCloudRun(account: "bee", email: "b@x.com")
        XCTAssertTrue(sync.isUnavailableAsTarget(for: b),
                      "live cloud run and expired: switching to it would throw every tick (a notification storm)")

        try startCloudRun(account: "bee", email: "b@x.com", ended: true)
        XCTAssertFalse(sync.isUnavailableAsTarget(for: b), "the run ended: released")

        // A cloud-held login that has NOT expired needs no refresh: still a candidate.
        try startCloudRun(account: "bee", email: "fresh@x.com")
        let freshB = imported("fresh@x.com", login("B2", expiresIn: 3600))
        XCTAssertFalse(sync.isUnavailableAsTarget(for: freshB))

        // The policy skips a held B and picks C.
        try startCloudRun(account: "bee", email: "b@x.com")
        var active = Profile(name: "A", cliCredentialsJSON: login("A", expiresIn: 3600))
        active.claudeUsage = Self.usage(session: 100)
        var bp = b; bp.claudeUsage = Self.usage(session: 0)
        var cp = c; cp.claudeUsage = Self.usage(session: 10)
        XCTAssertEqual(AutoSwitchPolicy.switchTarget(in: [active, bp, cp], after: active, usingFable: false, blockedBeyondFable: true,
                                                     isLoginDead: sync.isUnavailableAsTarget(for:)), .profile(cp))
    }

    func testCloudLedgerIgnoresEndedAndAncientRuns() {
        let now = Date()
        let iso = ISO8601DateFormatter()
        let fresh = iso.string(from: now.addingTimeInterval(-60)), old = iso.string(from: now.addingTimeInterval(-13 * 3600))
        let ledger = [
            #"{"run":"a","account":"live","launched":"\#(fresh)","via":"default"}"#,
            #"{"run":"b","account":"done","launched":"\#(fresh)","via":"default"}"#, #"{"run":"b","landed":"\#(fresh)"}"#,
            #"{"run":"c","account":"ancient","launched":"\#(old)","via":"default"}"#,
            #"{"run":"d","account":"notlaunched","launching":"\#(fresh)","via":"default"}"#,
            #"{"run":"e","account":"cleared","launched":"\#(fresh)","via":"default"}"#, #"{"run":"e","stopped":null}"#,
            #"{"run":"f","account":"owndir","launched":"\#(fresh)"}"#,
        ].joined(separator: "\n")
        XCTAssertEqual(CloudRunHold.activeAccounts(ndjson: ledger, now: now), ["live", "cleared"],
                       "stopped:null is a cleared stop, not an end; a run under its own account dir holds nothing")
    }

    /// Replay 2026-10-20 9:12 PM ET. littlewing hit its session limit; madmatter
    /// (97% weekly, ~0% session) was the only account with room. madmatter's
    /// stored main login had been captured at the 11:35 AM hand-off, so its
    /// access token had expired, and the ledger held ten unended `om-work` cloud
    /// runs on madmatter, launched by `cloud` with
    /// `CLAUDE_CONFIG_DIR=~/.claude-rotate/accounts/madmatter`: no `via`. That
    /// dir's login is the profile's PINNED keychain entry, a different lineage
    /// from the stored main login (`hasOwnMainLogin`), so refreshing the main
    /// login cannot touch those runs. The hold counted them anyway, madmatter
    /// was "unavailable", the switcher logged "All profiles at session/weekly
    /// limit or unavailable" and the coordinator sat on a dead account until
    /// the operator ran /login by hand.
    func testReplay20261020_OwnDirCloudRunsDoNotHoldTheStoredMainLogin() throws {
        let madJSON = login("mad", expiresIn: -5 * 3600)   // captured 15:35Z, expired by 01:12Z
        var mad = imported("madmatter23@gmail.com", madJSON)
        mad.claudeUsage = Self.usage(session: 0)
        try startCloudRun(account: "madmatter", email: "madmatter23@gmail.com", throughSharedLogin: false)
        XCTAssertFalse(sync.isUnavailableAsTarget(for: mad),
                       "a cloud run under the account's own dir cannot hold the tracker's stored main login")

        var littlewing = imported("littlewing@guitargate.com", login("lw", expiresIn: 3600))
        littlewing.claudeUsage = Self.usage(session: 100)
        XCTAssertEqual(AutoSwitchPolicy.switchTarget(in: [littlewing, mad], after: littlewing, usingFable: false,
                                                     blockedBeyondFable: true, isLoginDead: sync.isUnavailableAsTarget(for:)),
                       .profile(mad))

        // A run reached through the shared login (`via: default`) still holds it.
        try startCloudRun(account: "madmatter", email: "madmatter23@gmail.com", throughSharedLogin: true)
        XCTAssertTrue(sync.isUnavailableAsTarget(for: mad))
    }

    // MARK: - Gate fix 2: what "released" means

    /// A response streamed AFTER the swap to a request sent BEFORE it moves the
    /// transcript's mtime past the record, but proves nothing: that session
    /// never re-read the login.
    func testAStreamedReplyToAnEarlierRequestDoesNotReleaseTheLineage() throws {
        let at = Date().addingTimeInterval(-60)
        try writeTranscript(pid: getpid(), entries: [("user", at.addingTimeInterval(-30)), ("assistant", at.addingTimeInterval(10))])
        let record = MainLoginSwapPolicy.HandoffRecord(fingerprint: "f", holderPids: [getpid()], at: at)
        XCTAssertFalse(sync.lineageIsReleased(record))
    }

    func testANewRequestAfterTheSwapThatWasAnsweredReleasesTheLineage() throws {
        let at = Date().addingTimeInterval(-60)
        try writeTranscript(pid: getpid(), entries: [("user", at.addingTimeInterval(-30)), ("assistant", at.addingTimeInterval(-20)),
                                                       ("user", at.addingTimeInterval(5)), ("assistant", at.addingTimeInterval(8))])
        let record = MainLoginSwapPolicy.HandoffRecord(fingerprint: "f", holderPids: [getpid()], at: at)
        XCTAssertTrue(sync.lineageIsReleased(record))
    }

    func testARequestAfterTheSwapStillInFlightDoesNotReleaseIt() throws {
        let at = Date().addingTimeInterval(-60)
        try writeTranscript(pid: getpid(), entries: [("assistant", at.addingTimeInterval(-20)), ("user", at.addingTimeInterval(5))])
        let record = MainLoginSwapPolicy.HandoffRecord(fingerprint: "f", holderPids: [getpid()], at: at)
        XCTAssertFalse(sync.lineageIsReleased(record))
    }

    /// pids recycle: a live process whose start time is not the holder's is
    /// not the holder; the holder exited.
    func testARecycledPidDoesNotHoldTheLineage() {
        let record = MainLoginSwapPolicy.HandoffRecord(
            fingerprint: "f", holderPids: [getpid()], at: Date().addingTimeInterval(-60),
            holderStartTimes: ["\(getpid())": Date(timeIntervalSince1970: 1_000)])
        XCTAssertTrue(sync.lineageIsReleased(record))
    }

    func testTheSameLiveHolderWithNoNewRequestStillHoldsIt() throws {
        let started = try XCTUnwrap(ProcessListing.startTime(pid: getpid()))
        let record = MainLoginSwapPolicy.HandoffRecord(
            fingerprint: "f", holderPids: [getpid()], at: Date().addingTimeInterval(-60),
            holderStartTimes: ["\(getpid())": started])
        XCTAssertFalse(sync.lineageIsReleased(record))
    }

    /// The TTL never releases a lineage a live holder may still carry: an idle
    /// session pinning it is the SAFE state (releasing it lets the tracker
    /// refresh a single-use token the session still holds: a logout).
    func testALiveHolderPastTheTTLStillHoldsTheLineage() throws {
        let started = try XCTUnwrap(ProcessListing.startTime(pid: getpid()))
        let old = Date().addingTimeInterval(-MainLoginSwapPolicy.handoffRecordTTL - 60)
        XCTAssertFalse(sync.lineageIsReleased(MainLoginSwapPolicy.HandoffRecord(
            fingerprint: "f", holderPids: [getpid()], at: old, holderStartTimes: ["\(getpid())": started])))
        XCTAssertFalse(sync.lineageIsReleased(MainLoginSwapPolicy.HandoffRecord(fingerprint: "f", holderPids: [getpid()], at: old)),
                       "start time unknown: still the safe answer")
    }

    /// The TTL only prunes records nobody can be holding any more.
    func testOnlyRecordsWhoseHoldersAreAllGoneArePrunedAfterTheTTL() throws {
        let started = try XCTUnwrap(ProcessListing.startTime(pid: getpid()))
        let old = Date().addingTimeInterval(-MainLoginSwapPolicy.handoffRecordTTL - 60)
        let gonePid = Int32.max - 7
        sync.recordHandoff(MainLoginSwapPolicy.HandoffRecord(fingerprint: "live", holderPids: [getpid()], at: old,
                                                             holderStartTimes: ["\(getpid())": started]))
        sync.recordHandoff(MainLoginSwapPolicy.HandoffRecord(fingerprint: "gone", holderPids: [gonePid], at: old))
        sync.recordHandoff(MainLoginSwapPolicy.HandoffRecord(fingerprint: "new", holderPids: [getpid()], at: Date()))
        XCTAssertNotNil(sync.handoffRecord(for: "live"), "a live holder's record is never pruned")
        XCTAssertNil(sync.handoffRecord(for: "gone"))
        XCTAssertNotNil(sync.handoffRecord(for: "new"))
    }

    /// End to end: a live process that never had a session record is released;
    /// the same process WITH one (a real session) is not.
    func testALiveNonSessionHolderIsReleasedButASessionIsNot() throws {
        let at = Date().addingTimeInterval(-60)
        let record = MainLoginSwapPolicy.HandoffRecord(fingerprint: "f", holderPids: [getpid()], at: at, holdersWithSession: [],
                                                       holdersByNameOnly: [getpid()])
        XCTAssertTrue(sync.lineageIsReleased(record), "a name-only node with no session record then or now: not a Claude Code session")
        XCTAssertFalse(sync.lineageIsReleased(MainLoginSwapPolicy.HandoffRecord(
            fingerprint: "f", holderPids: [getpid()], at: at, holdersWithSession: [], holdersByNameOnly: [])),
            "identified by its arguments: Claude Code, session record or not")
        try writeTranscript(pid: getpid(), entries: [("user", at.addingTimeInterval(-30))])
        XCTAssertFalse(sync.lineageIsReleased(record), "it has a session record now")
    }

    // MARK: - Regate fix 2: a target whose swap keeps being refused

    func testANonRetryableRefusalMakesTheTargetUnavailableAndIsToldOnce() throws {
        sync.resetSwitchRefusalsForTesting()
        defer { sync.resetSwitchRefusalsForTesting() }
        let b = imported("B", login("B", expiresIn: 3600))
        let c = imported("C", login("C", expiresIn: 3600))
        XCTAssertFalse(sync.isUnavailableAsTarget(for: b))

        XCTAssertTrue(sync.noteSwitchOutcome(.refused(.untrustedStoredLogin(.unknownProvenance)), for: b), "told at once")
        XCTAssertTrue(sync.isUnavailableAsTarget(for: b), "not picked again every tick")
        XCTAssertTrue(sync.isRefusingSwitch(b))
        XCTAssertFalse(sync.noteSwitchOutcome(.refused(.untrustedStoredLogin(.unknownProvenance)), for: b), "once per episode")
        XCTAssertFalse(sync.isUnavailableAsTarget(for: c))

        // The switcher goes past it; the status line does not call it ready.
        var active = Profile(name: "A", cliCredentialsJSON: login("A", expiresIn: 3600))
        active.claudeUsage = Self.usage(session: 100)
        var bp = b; bp.claudeUsage = Self.usage(session: 0)
        XCTAssertEqual(AutoSwitchPolicy.switchTarget(in: [active, bp], after: active, usingFable: false, blockedBeyondFable: true,
                                                     isLoginDead: sync.isUnavailableAsTarget(for:)), AutoSwitchPolicy.SwitchTarget.none)
        let status = AutoSwitchStatus.build(profiles: [active, bp], activeId: active.id, isRefusing: { self.sync.isRefusingSwitch($0) })
        XCTAssertEqual(status.next, .refused(name: "B"))
        XCTAssertTrue(status.stuck)
        let state = status.stateFileContents { _ in "" }
        XCTAssertTrue(state.contains("NEXT=next: none · B refused the switch\n") && state.contains("NEXT_KIND=refused\nNEXT_NAME=B\n"), state)
        XCTAssertEqual(AutoSwitchStatus.build(profiles: [active, bp], activeId: active.id).next, .ready(name: "B", presumed: false),
                       "without the refusal it would read ready")

        // A re-import (a different stored login) ends the episode.
        var reimported = b
        reimported.cliCredentialsJSON = login("B2", expiresIn: 3600)
        XCTAssertFalse(sync.isUnavailableAsTarget(for: reimported))
        // So does a swap that lands.
        XCTAssertFalse(sync.noteSwitchOutcome(.applied(racedHolders: 0), for: b))
        XCTAssertFalse(sync.isUnavailableAsTarget(for: b))
    }

    func testARetryableRefusalIsToldAfterItRepeatsAndStaysATarget() {
        var tracker = SwitchRefusalTracker()
        let id = UUID()
        let t0 = Date()
        for tick in 1..<SwitchRefusalTracker.repeatsBeforeNotice {
            XCTAssertFalse(tracker.record(.refused(.unknownKeychainLogin), target: id, loginFingerprint: "f", now: t0.addingTimeInterval(Double(tick))))
            XCTAssertFalse(tracker.isRefusing(id, loginFingerprint: "f", now: t0.addingTimeInterval(Double(tick))))
        }
        XCTAssertTrue(tracker.record(.refused(.unknownKeychainLogin), target: id, loginFingerprint: "f", now: t0.addingTimeInterval(10)), "told once it has repeated")
        XCTAssertFalse(tracker.record(.refused(.unknownKeychainLogin), target: id, loginFingerprint: "f", now: t0.addingTimeInterval(11)))
        XCTAssertTrue(tracker.isRefusing(id, loginFingerprint: "f", now: t0.addingTimeInterval(11)), "the status line stops saying ready")
        XCTAssertFalse(tracker.isUnavailable(id, loginFingerprint: "f", now: t0.addingTimeInterval(11)), "still retried: it can clear by itself")
        // A non-retryable target is tried again after the hold, quietly.
        XCTAssertTrue(tracker.record(.refused(.notTheSharedLoginEntry(service: "x")), target: UUID(), loginFingerprint: nil, now: t0))
        var other = SwitchRefusalTracker()
        let o = UUID()
        _ = other.record(.refused(.untrustedStoredLogin(.unknownProvenance)), target: o, loginFingerprint: "f", now: t0)
        XCTAssertTrue(other.isUnavailable(o, loginFingerprint: "f", now: t0.addingTimeInterval(SwitchRefusalTracker.hold - 1)))
        XCTAssertFalse(other.isUnavailable(o, loginFingerprint: "f", now: t0.addingTimeInterval(SwitchRefusalTracker.hold + 1)))
        XCTAssertFalse(other.record(.refused(.untrustedStoredLogin(.unknownProvenance)), target: o, loginFingerprint: "f", now: t0.addingTimeInterval(SwitchRefusalTracker.hold + 2)),
                       "the retry after the hold does not notify again")
    }

    private func writeTranscript(pid: Int32, entries: [(String, Date)]) throws {
        let sessionId = UUID().uuidString.lowercased()
        let sessions = sync.sessionsDirectory, project = sync.projectsDirectory.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try #"{"pid":\#(pid),"sessionId":"\#(sessionId)"}"#.write(to: sessions.appendingPathComponent("\(pid).json"), atomically: true, encoding: .utf8)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = entries.map { #"{"type":"\#($0.0)","timestamp":"\#(f.string(from: $0.1))","message":{"role":"\#($0.0)","content":"x"}}"# }
        try (lines.joined(separator: "\n") + "\n").write(to: project.appendingPathComponent("\(sessionId).jsonl"), atomically: true, encoding: .utf8)
    }

    private static func usage(session: Double) -> ClaudeUsage {
        let now = Date()
        return ClaudeUsage(
            sessionTokensUsed: 0, sessionLimit: 100000, sessionPercentage: session, sessionResetTime: now.addingTimeInterval(3600),
            weeklyTokensUsed: 0, weeklyLimit: 1000000, weeklyPercentage: 0, weeklyResetTime: now.addingTimeInterval(86400),
            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0, sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0, designWeeklyPercentage: 0, designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0, fableWeeklyPercentage: 0, fableWeeklyResetTime: nil,
            costUsed: nil, costLimit: nil, costCurrency: nil, lastUpdated: now, userTimezone: .current)
    }
}
