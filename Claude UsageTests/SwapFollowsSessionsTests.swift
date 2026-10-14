import XCTest
@testable import Claude_Usage

/// The 2026-10-14 incident, pinned: jrand at 90-98% with ~20 agents, the hand-off
/// to goose REFUSED every tick (`sessionsRunning`) from 11:52 to 12:03, then the
/// limit card. Three things had to be true for that to happen and each is now
/// a test here:
///
/// 1. running sessions blocked the swap — they no longer do, they follow it
///    (`SingleRefresherTests` covers the write, the stub and the record);
/// 2. the keychain login was not recognised as jrand's (its token had rotated
///    and the stored copy lagged) — a login PROVEN by its account lookup now
///    counts as that profile's, so the account the tracker shows as active is
///    the keychain's;
/// 3. nothing durable said why — every outcome is now a `HandoffLog` line
///    with from/to/reason (and the refusal, when refused).
final class SwapFollowsSessionsTests: XCTestCase {

    private let sync = ClaudeCodeSyncService.shared
    private let mainService = "Claude Code-credentials"

    private var keychain: [String: String] = [:]
    private var processes: [MainLoginSwapPolicy.RunningProcess]? = []
    private var accountOf: [String: String] = [:]   // access token -> account uuid
    private var tempDir: URL!

    private var savedRunner: ((_ arguments: [String], _ timeout: TimeInterval) -> ClaudeCodeSyncService.SecurityCommandResult?)!
    private var savedProcesses: (() -> [MainLoginSwapPolicy.RunningProcess]?)!
    private var savedCredentialsFile: URL!
    private var savedLookup: ((String) async -> String?)!
    private var savedLog: URL!
    private var savedRetry: TimeInterval = 60

    override func setUp() {
        super.setUp()
        savedRunner = sync.securityCommandRunner
        savedProcesses = sync.runningProcesses
        savedCredentialsFile = sync.credentialsFileURL
        savedLookup = sync.fetchLoginAccountUuid
        savedLog = HandoffLog.fileURL
        savedRetry = sync.loginAccountRetryInterval
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sync.setResolvedServiceNameForTesting(mainService)
        sync.credentialsFileURL = tempDir.appendingPathComponent(".credentials.json")
        sync.sessionsDirectory = tempDir.appendingPathComponent("sessions")
        sync.projectsDirectory = tempDir.appendingPathComponent("projects")
        sync.resetHandoffRecordsForTesting()
        sync.loginAccountRetryInterval = 0
        HandoffLog.fileURL = tempDir.appendingPathComponent("handoff.log")
        keychain = [:]
        processes = []
        accountOf = [:]
        sync.runningProcesses = { [unowned self] in self.processes }
        sync.fetchLoginAccountUuid = { [unowned self] accessToken in self.accountOf[accessToken] }
        sync.securityCommandRunner = { [unowned self] arguments, _ in
            func result(_ code: Int32, _ out: String = "") -> ClaudeCodeSyncService.SecurityCommandResult {
                .init(exitCode: code, stdout: out, stderr: "", timedOut: false)
            }
            guard let verb = arguments.first, let s = arguments.firstIndex(of: "-s"), s + 1 < arguments.count else { return result(1) }
            let service = arguments[s + 1]
            switch verb {
            case "find-generic-password":
                guard let json = self.keychain[service] else { return result(44) }
                return result(0, arguments.contains("-w") ? json : "attributes")
            case "add-generic-password":
                guard let w = arguments.firstIndex(of: "-w"), w + 1 < arguments.count else { return result(1) }
                self.keychain[service] = arguments[w + 1]
                return result(0)
            default:
                return result(1)
            }
        }
    }

    override func tearDown() {
        sync.setResolvedServiceNameForTesting(nil)
        sync.securityCommandRunner = savedRunner
        sync.runningProcesses = savedProcesses
        sync.credentialsFileURL = savedCredentialsFile
        sync.fetchLoginAccountUuid = savedLookup
        sync.loginAccountRetryInterval = savedRetry
        sync.resetHandoffRecordsForTesting()
        HandoffLog.fileURL = savedLog
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func login(_ tag: String, expiresIn: TimeInterval = 3600) -> String {
        let ms = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        return #"{"claudeAiOauth":{"accessToken":"access-\#(tag)","refreshToken":"refresh-\#(tag)","expiresAt":\#(ms),"scopes":["user:inference"],"subscriptionType":"max"}}"#
    }

    private func account(_ name: String, storedLogin: String, uuid: String) -> Profile {
        var p = Profile(name: name, cliCredentialsJSON: storedLogin)
        p.mainLoginProvenance = "keychain"
        p.oauthAccountJSON = #"{"accountUuid":"\#(uuid)","emailAddress":"\#(name)"}"#
        return p
    }

    private func claude(_ pid: Int32) -> MainLoginSwapPolicy.RunningProcess { .init(pid: pid, command: "claude", configDir: nil) }

    // MARK: - 2. The keychain login is recognised by its account, not only its token

    /// jrand's token rotated (Claude Code refreshed it); the tracker's stored
    /// copy is the OLD token, so by fingerprint the keychain login is unknown.
    /// Its account lookup says it is jrand's: the swap proceeds and the log
    /// names jrand as the account the sessions left.
    func testARotatedLoginProvenByItsAccountIsKnownAndHandedOff() async throws {
        let jrandStored = login("jrand-old")
        let jrandRotated = login("jrand-rotated")
        keychain[mainService] = jrandRotated
        accountOf["access-jrand-rotated"] = "uuid-jrand"
        let jrand = account("jrand@x", storedLogin: jrandStored, uuid: "uuid-jrand")
        let goose = account("goose@x", storedLogin: login("goose"), uuid: "uuid-goose")
        processes = [claude(500), claude(501), claude(502)]

        // First call: the lookup is fire-and-forget, so the first attempt may
        // refuse as unknown while the lookup resolves; a tick later it is known.
        var outcome = try await sync.switchMainLogin(
            to: goose, knownLogins: [jrandStored, goose.cliCredentialsJSON!], reason: "near limit: 86%", owners: [jrand, goose])
        if outcome == .refused(.unknownKeychainLogin) {
            try await Task.sleep(nanoseconds: 200_000_000)
            outcome = try await sync.switchMainLogin(
                to: goose, knownLogins: [jrandStored, goose.cliCredentialsJSON!], reason: "near limit: 86%", owners: [jrand, goose])
        }

        XCTAssertEqual(outcome, .applied(racedHolders: 0), "a rotated login proven to be jrand's is not 'unknown'")
        XCTAssertEqual(keychain[mainService], goose.cliCredentialsJSON)
        let line = try XCTUnwrap(HandoffLog.lines().last { $0.contains(" HANDOFF ") })
        XCTAssertTrue(line.contains(#"from="jrand@x""#), line)
        XCTAssertTrue(line.contains(#"to="goose@x""#), line)
        XCTAssertTrue(line.contains(#"reason="near limit: 86%""#), line)
        XCTAssertTrue(line.contains(#"holders="3""#), line)
        XCTAssertTrue(line.contains(#"signalled="yes""#), line)
        XCTAssertFalse(line.contains("refresh-"), "never a token in the log: \(line)")
        XCTAssertFalse(line.contains("access-"), "never a token in the log: \(line)")
    }

    /// A rotated login whose lookup FAILS stays unknown: the compare-and-swap
    /// refuses (a `/login` to a foreign account looks exactly like this), and
    /// the refusal is logged with its reason — the line the 2026-10-14
    /// incident never had.
    func testAnUnprovenRotatedLoginIsRefusedAndTheRefusalIsLogged() async throws {
        let jrandStored = login("jrand-old")
        keychain[mainService] = login("jrand-rotated")   // no accountOf entry: lookup fails
        let jrand = account("jrand@x", storedLogin: jrandStored, uuid: "uuid-jrand")
        let goose = account("goose@x", storedLogin: login("goose"), uuid: "uuid-goose")
        processes = [claude(500)]

        let outcome = try await sync.switchMainLogin(
            to: goose, knownLogins: [jrandStored, goose.cliCredentialsJSON!], reason: "near limit: 91%", owners: [jrand, goose])

        XCTAssertEqual(outcome, .refused(.unknownKeychainLogin))
        XCTAssertEqual(keychain[mainService]?.contains("refresh-jrand-rotated"), true, "never overwritten")
        let line = try XCTUnwrap(HandoffLog.lines().last)
        XCTAssertTrue(line.contains(" REFUSED "), line)
        XCTAssertTrue(line.contains(#"from="unknown login""#), line)
        XCTAssertTrue(line.contains(#"to="goose@x""#), line)
        XCTAssertTrue(line.contains(#"refusal="unknownKeychainLogin""#), line)
        XCTAssertTrue(line.contains(#"reason="near limit: 91%""#), line)
    }

    // MARK: - 1 + 3. Holders never refuse; every outcome is logged

    func testHoldersDoNotRefuseAndTheHandoffLineNamesBothAccounts() async throws {
        let jrandLogin = login("jrand")
        keychain[mainService] = jrandLogin
        let jrand = account("jrand@x", storedLogin: jrandLogin, uuid: "uuid-jrand")
        let goose = account("goose@x", storedLogin: login("goose"), uuid: "uuid-goose")
        processes = (1...18).map { claude(Int32(500 + $0)) }

        let outcome = try await sync.switchMainLogin(
            to: goose, knownLogins: [jrandLogin, goose.cliCredentialsJSON!], reason: "near limit: 90%", owners: [jrand, goose])

        XCTAssertEqual(outcome, .applied(racedHolders: 0), "18 running sessions do not block; they follow")
        let line = try XCTUnwrap(HandoffLog.lines().last)
        XCTAssertTrue(line.hasPrefix("20"), "timestamped: \(line)")
        XCTAssertTrue(line.contains(#" HANDOFF from="jrand@x" to="goose@x" reason="near limit: 90%" holders="18""#), line)
        XCTAssertEqual(sync.handoffRecord(for: try XCTUnwrap(sync.systemLoginFingerprint(jrandLogin)))?.holderPids.count, 18)
    }

    func testAlreadyOnTheTargetIsLoggedAsSuch() async throws {
        let goose = account("goose@x", storedLogin: login("goose"), uuid: "uuid-goose")
        keychain[mainService] = goose.cliCredentialsJSON
        let outcome = try await sync.switchMainLogin(to: goose, knownLogins: [goose.cliCredentialsJSON!], reason: "pending switch retried", owners: [goose])
        XCTAssertEqual(outcome, .alreadyApplied)
        let line = try XCTUnwrap(HandoffLog.lines().last)
        XCTAssertTrue(line.contains(#" ALREADY-ON from="goose@x" to="goose@x" reason="pending switch retried""#), line)
    }

    func testAFailedSwitchIsLogged() async {
        let pinnedOnly = Profile(name: "pinned@x", cliCredentialsJSON: nil)
        do {
            _ = try await sync.switchMainLogin(to: pinnedOnly, knownLogins: [], reason: "user switch")
            XCTFail("no login to apply")
        } catch {}
        let line = HandoffLog.lines().last ?? ""
        XCTAssertTrue(line.contains(#" FAILED from="unknown login" to="pinned@x" reason="user switch""#), line)
    }

    // MARK: - The reload signal

    func testSignalCreatesAZeroByteStubWithMode600ThenOnlyTouchesIt() throws {
        let stub = tempDir.appendingPathComponent("stub/.credentials.json")
        try FileManager.default.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(ClaudeCodeSyncService.signalCredentialsReload(at: stub))
        var attrs = try FileManager.default.attributesOfItem(atPath: stub.path)
        XCTAssertEqual(attrs[.size] as? Int, 0)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // Existing content is never touched, only the mtime.
        try "not-a-login-but-content".write(to: stub, atomically: true, encoding: .utf8)
        let past = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: stub.path)
        XCTAssertTrue(ClaudeCodeSyncService.signalCredentialsReload(at: stub))
        attrs = try FileManager.default.attributesOfItem(atPath: stub.path)
        XCTAssertGreaterThan(attrs[.modificationDate] as? Date ?? past, past)
        XCTAssertEqual(try String(contentsOf: stub, encoding: .utf8), "not-a-login-but-content")

        XCTAssertFalse(ClaudeCodeSyncService.signalCredentialsReload(at: tempDir.appendingPathComponent("no-such-dir/.credentials.json")),
                       "no config dir: reported, not invented")
    }

    // MARK: - HandoffLog hygiene

    func testHandoffLogFlattensQuotesAndNewlinesAndRotates() throws {
        let line = HandoffLog.record(.refused, from: "a \"quoted\"\nname", to: "b", reason: "r", fields: [("k", "v")])
        XCTAssertFalse(line.contains("\n"))
        XCTAssertTrue(line.contains(#"from="a 'quoted' name""#), line)
        XCTAssertTrue(line.hasSuffix(#"k="v""#), line)
        XCTAssertEqual(HandoffLog.lines().count, 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: HandoffLog.fileURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
