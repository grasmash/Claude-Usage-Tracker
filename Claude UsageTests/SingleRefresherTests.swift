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

    override func setUp() {
        super.setUp()
        savedRunner = sync.securityCommandRunner
        savedRefresher = sync.tokenRefresher
        savedProcesses = sync.runningProcesses
        savedHolderModel = sync.holderModel
        holderModels = [:]
        savedCredentialsFile = sync.credentialsFileURL
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

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

    // MARK: - A3: the shared login is rewritten only when nothing holds it

    func testSwitchIsRefusedWhileABareClaudeSessionRuns() async throws {
        keychain[mainService] = login("A", expiresIn: 3600)
        processes = [bareClaude(500), rotateClaude(501)]
        let b = imported("B", login("B", expiresIn: -600))

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.sessionsRunning(count: 1)), "the claude-rotate session does not count")
        XCTAssertEqual(keychain[mainService]?.contains("refresh-A"), true, "A is untouched")
        XCTAssertEqual(refreshCalls, 0, "B's stored login is not refreshed while the switch is refused")
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: - A3b: sessions stranded on a spent login do not block the switch
    //
    // 2026-10-11 15:45Z: the shared login (littlewing) hit its weekly limit with
    // ten bare `claude` sessions on it. Auto-switch chose madmatter, but the
    // swap was refused as `sessionsRunning(count: 10)` on every retry, so every
    // session sat on "You've hit your weekly limit" until a manual /login.
    // Sessions on a spent login can make no request; holding them there
    // protects nothing.

    func testSwitchProceedsWhenTheSessionsAreStrandedOnASpentLogin() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500), bareClaude(501)]
        let b = imported("B", login("B", expiresIn: 3600))
        let creds = sync.credentialsFileURL
        FileManager.default.createFile(atPath: creds.path, contents: Data())
        let past = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: creds.path)

        let outcome = try await sync.switchMainLogin(
            to: b, knownLogins: [a, b.cliCredentialsJSON!], spentLogins: [a])

        XCTAssertEqual(outcome, .applied(racedHolders: 0), "the stranded sessions were there before the write; none raced it")
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
        XCTAssertEqual(writes.count, 1, "exactly one in-place write: \(writes)")
        let mtime = try FileManager.default.attributesOfItem(atPath: creds.path)[.modificationDate] as? Date
        XCTAssertGreaterThan(mtime ?? past, past, "the stranded sessions are told to reload onto B")
    }

    func testAFailedReloadSignalToStrandedSessionsIsReported() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500)]
        let b = imported("B", login("B", expiresIn: 3600))
        let creds = sync.credentialsFileURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: creds.path))

        let outcome = try await sync.switchMainLogin(
            to: b, knownLogins: [a, b.cliCredentialsJSON!], spentLogins: [a])

        XCTAssertEqual(outcome, .applied(racedHolders: 0, strandedSignalled: false),
                       "the stranded session could not be told to reload; the caller must say so")
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
        XCTAssertFalse(FileManager.default.fileExists(atPath: creds.path), "the signal never creates the file")
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

    func testAFableLimitStrandsTheSessionsWhenEveryHolderIsOnFable() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500), bareClaude(501)]
        holderModels = [500: "claude-fable-5-1", 501: "claude-fable-5-1[1m]"]
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(
            to: b, knownLogins: [a, b.cliCredentialsJSON!], fableSpentLogins: [a])

        XCTAssertEqual(outcome, .applied(racedHolders: 0, strandedSignalled: false))
        XCTAssertEqual(keychain[mainService], b.cliCredentialsJSON)
    }

    func testAFableLimitDoesNotOverrideAHolderThatIsNotOnFable() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500), bareClaude(501)]
        holderModels = [500: "claude-fable-5-1", 501: "claude-opus-5-5"]
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(
            to: b, knownLogins: [a, b.cliCredentialsJSON!], fableSpentLogins: [a])

        XCTAssertEqual(outcome, .refused(.sessionsRunning(count: 2)), "the Opus session on A is working")
        XCTAssertTrue(writes.isEmpty)
    }

    func testSessionsStillBlockTheSwitchWhenTheSpentLoginIsNotTheSharedOne() async throws {
        let a = login("A", expiresIn: 3600)
        keychain[mainService] = a
        processes = [bareClaude(500)]
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(
            to: b, knownLogins: [a, b.cliCredentialsJSON!], spentLogins: [login("C", expiresIn: 3600)])

        XCTAssertEqual(outcome, .refused(.sessionsRunning(count: 1)), "A has headroom: its sessions are working")
        XCTAssertTrue(writes.isEmpty)
    }

    func testASpentLoginNeverOverridesTheCompareAndSwap() async throws {
        keychain[mainService] = login("fresh-login", expiresIn: 3600)
        processes = [bareClaude(500)]
        let a = login("A", expiresIn: 3600)
        let b = imported("B", login("B", expiresIn: 3600))

        let outcome = try await sync.switchMainLogin(
            to: b, knownLogins: [a, b.cliCredentialsJSON!], spentLogins: [a])

        XCTAssertEqual(outcome, .refused(.sessionsRunning(count: 1)), "the keychain is not the spent login A")
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

    func testSwitchIsRefusedWhileHappyRunsClaudeByItsVersionedPath() async throws {
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

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.sessionsRunning(count: 1)))
        XCTAssertTrue(writes.isEmpty)
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

        let outcome = try await sync.switchMainLogin(to: b, knownLogins: [keychain[mainService]!, b.cliCredentialsJSON!])

        XCTAssertEqual(outcome, .refused(.sessionsRunning(count: 1)))
        XCTAssertTrue(writes.isEmpty)
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

        XCTAssertFalse(FileManager.default.fileExists(atPath: sync.credentialsFileURL.path),
                       "the keychain is the only store; no copy on disk")
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
}
