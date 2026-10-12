import XCTest
@testable import Claude_Usage

/// An INACTIVE profile's usage is read from its stored own main login when its
/// pinned entry's token has expired. That stored login belongs to this app
/// alone: `claude-usage-login` imports it and deletes the import dir's item,
/// and a switch captures it from the keychain under a compare-and-swap before
/// writing another account's login there. Claude Code only ever posts the
/// refresh token it finds in its own storage at that moment (it re-reads under
/// its refresh lock), so a refresh token that is in NO Claude Code keychain
/// item and not in the credentials file has no other holder, and refreshing it
/// can log nobody out. These tests pin that the refresh happens only then.
final class StoredLoginUsageTests: XCTestCase {

    private let sync = ClaudeCodeSyncService.shared
    private let mainService = "Claude Code-credentials"
    private let pinnedService = "Claude Code-credentials-75e53f42"
    private let otherDirService = "Claude Code-credentials-0badf00d"

    private var keychain: [String: String] = [:]
    private var listed: [String]? = nil
    private var securityCalls: [[String]] = []
    private var refreshCalls = 0
    private var refreshDelayNs: UInt64 = 0
    private var refreshError: Error?
    private var persisted: [UUID: String] = [:]
    private var tempDir: URL!
    private var tag = ""

    private var savedRunner: ((_ arguments: [String], _ timeout: TimeInterval) -> ClaudeCodeSyncService.SecurityCommandResult?)!
    private var savedRefresher: ((_ refreshToken: String) async throws -> ClaudeCodeSyncService.OAuthRefreshResponse)!
    private var savedLister: (() -> [String]?)!
    private var savedLoader: ((UUID) -> Profile?)!
    private var savedPersister: ((UUID, String) -> Void)!
    private var savedCredentialsFile: URL!
    private var savedFetchUuid: ((String) async -> String?)!

    override func setUp() {
        super.setUp()
        tag = UUID().uuidString.prefix(8).lowercased()   // the dead-login tracker is shared: unique tokens per test
        savedRunner = sync.securityCommandRunner
        savedRefresher = sync.tokenRefresher
        savedLister = sync.claudeCodeServiceLister
        savedLoader = sync.storedProfileLoader
        savedPersister = sync.storedLoginPersister
        savedCredentialsFile = sync.credentialsFileURL
        savedFetchUuid = sync.fetchLoginAccountUuid
        // Whose login an access token is: "access-main-*" is another account, "access-stored-*" and
        // "access-newer-*" are goose's own (a newer rotation in the shared item is still goose).
        sync.fetchLoginAccountUuid = { at in
            at.hasPrefix("access-main-") || at.hasPrefix("access-other-") ? "u-main"
                : at.hasPrefix("access-stored-") || at.hasPrefix("access-newer-") ? "u-goose" : nil
        }
        sync.setResolvedServiceNameForTesting(mainService)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        keychain = [:]
        securityCalls = []
        refreshCalls = 0
        refreshDelayNs = 0
        refreshError = nil
        persisted = [:]
        listed = nil

        sync.credentialsFileURL = tempDir.appendingPathComponent(".credentials.json")
        sync.claudeCodeServiceLister = { [unowned self] in self.listed ?? self.keychain.keys.sorted() }
        sync.storedProfileLoader = { [unowned self] id in
            self.persisted[id].map { json in var p = self.profileTemplate!; p.cliCredentialsJSON = json; return p }
        }
        sync.storedLoginPersister = { [unowned self] id, json in self.persisted[id] = json }
        sync.tokenRefresher = { [unowned self] _ in
            self.refreshCalls += 1
            if self.refreshDelayNs > 0 { try await Task.sleep(nanoseconds: self.refreshDelayNs) }
            if let e = self.refreshError { throw e }
            return .init(access_token: "access-renewed-\(self.tag)", refresh_token: "refresh-renewed-\(self.tag)",
                         expires_in: 28_800, token_type: "Bearer")
        }
        sync.securityCommandRunner = { [unowned self] arguments, _ in
            self.securityCalls.append(arguments)
            guard arguments.first == "find-generic-password",
                  let s = arguments.firstIndex(of: "-s"), s + 1 < arguments.count else {
                return .init(exitCode: 1, stdout: "", stderr: "", timedOut: false)
            }
            guard let json = self.keychain[arguments[s + 1]] else {
                return .init(exitCode: 44, stdout: "", stderr: "", timedOut: false)
            }
            return .init(exitCode: 0, stdout: json, stderr: "", timedOut: false)
        }
    }

    override func tearDown() {
        sync.setResolvedServiceNameForTesting(nil)
        sync.fetchLoginAccountUuid = savedFetchUuid
        sync.securityCommandRunner = savedRunner
        sync.tokenRefresher = savedRefresher
        sync.claudeCodeServiceLister = savedLister
        sync.storedProfileLoader = savedLoader
        sync.storedLoginPersister = savedPersister
        sync.credentialsFileURL = savedCredentialsFile
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private var profileTemplate: Profile?

    private func login(_ name: String, expiresIn: TimeInterval) -> String {
        let ms = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        return #"{"claudeAiOauth":{"accessToken":"access-\#(name)-\#(tag)","refreshToken":"refresh-\#(name)-\#(tag)","expiresAt":\#(ms),"scopes":["user:inference"],"subscriptionType":"max"}}"#
    }

    /// goose on the laptop: pinned to its claude-rotate dir, with its own
    /// imported main login stored in the app.
    private func goose(stored: String, provenance: String? = "import", own: Bool = true) -> Profile {
        var p = Profile(name: "gooseappai@gmail.com", cliCredentialsJSON: stored, customKeychainServiceName: pinnedService)
        p.hasOwnMainLogin = own
        p.mainLoginProvenance = provenance
        p.oauthAccountJSON = #"{"accountUuid":"u-goose","emailAddress":"gooseappai@gmail.com"}"#
        profileTemplate = p
        return p
    }

    private var writes: [[String]] { securityCalls.filter { ClaudeCodeSyncService.isMutatingSecurityVerb($0.first) } }

    // MARK: - Reading with a valid access token never refreshes anything

    func testAValidStoredLoginIsUsedAsIsWithoutRefresh() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        keychain[pinnedService] = login("pinned", expiresIn: -3600)
        let stored = login("stored", expiresIn: 3600)

        let json = await sync.storedLoginForUsage(goose(stored: stored), isActive: false)

        XCTAssertEqual(json, stored)
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: - An expired stored login no Claude Code storage holds is refreshed once

    func testAnExpiredStoredLoginHeldNowhereElseIsRefreshedAndPersisted() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        keychain[pinnedService] = login("pinned", expiresIn: -3600)
        keychain[otherDirService] = login("other", expiresIn: 3600)
        let profile = goose(stored: login("stored", expiresIn: -7 * 3600))

        let json = await sync.storedLoginForUsage(profile, isActive: false)

        XCTAssertEqual(refreshCalls, 1)
        XCTAssertEqual(json.flatMap(sync.extractAccessToken), "access-renewed-\(tag)")
        XCTAssertEqual(json.flatMap(sync.extractRefreshToken), "refresh-renewed-\(tag)")
        XCTAssertFalse(json.map(sync.isTokenExpired) ?? true)
        XCTAssertEqual(persisted[profile.id], json, "the rotated login replaces the stored copy (a switch then applies it)")
        XCTAssertTrue(writes.isEmpty, "no keychain write: \(writes)")
        let read = Set(securityCalls.compactMap { a in a.firstIndex(of: "-s").map { a[$0 + 1] } })
        XCTAssertEqual(read, [mainService, pinnedService, otherDirService], "every Claude Code item was checked")
    }

    // MARK: - Shared lineages are never refreshed

    func testAStoredLoginThatIsTheSharedLoginIsNotRefreshed() async {
        let stored = login("stored", expiresIn: -600)
        keychain[mainService] = stored
        let json = await sync.storedLoginForUsage(goose(stored: stored), isActive: false)
        XCTAssertNil(json)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testAStoredLoginInAnyConfigDirsItemIsNotRefreshed() async {
        let stored = login("stored", expiresIn: -600)
        keychain[mainService] = login("main", expiresIn: 3600)
        keychain[otherDirService] = login("stored", expiresIn: 3600)   // same lineage, an unknown dir's item
        let r1 = await sync.storedLoginForUsage(goose(stored: stored), isActive: false)
        XCTAssertNil(r1)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testAStoredLoginInThePlaintextCredentialsFileIsNotRefreshed() async throws {
        let stored = login("stored", expiresIn: -600)
        keychain[mainService] = login("main", expiresIn: 3600)
        try stored.write(to: sync.credentialsFileURL, atomically: true, encoding: .utf8)
        let r2 = await sync.storedLoginForUsage(goose(stored: stored), isActive: false)
        XCTAssertNil(r2)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testTheActiveProfileIsNeverRefreshedHere() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        let r3 = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600)), isActive: true)
        XCTAssertNil(r3)
        XCTAssertEqual(refreshCalls, 0)
    }

    // MARK: - Unknown means no refresh (fail closed)

    func testNoListOfClaudeCodeItemsMeansNoRefresh() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        listed = []   // the query failed or found nothing: there is always at least the shared item
        let r4 = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600)), isActive: false)
        XCTAssertNil(r4)
        sync.claudeCodeServiceLister = { nil }
        let r5 = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600)), isActive: false)
        XCTAssertNil(r5)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testAnUnreadableClaudeCodeItemMeansNoRefresh() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        keychain[otherDirService] = login("other", expiresIn: 3600)
        let inner = sync.securityCommandRunner
        sync.securityCommandRunner = { [unowned self] arguments, timeout in
            if arguments.contains(self.otherDirService) {
                self.securityCalls.append(arguments)
                return .init(exitCode: -1, stdout: "", stderr: "timeout", timedOut: true)
            }
            return inner(arguments, timeout)
        }
        let r6 = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600)), isActive: false)
        XCTAssertNil(r6)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testAnUntrustedOrBorrowedStoredLoginIsNotRefreshed() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        let r7 = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600), provenance: nil), isActive: false)
        XCTAssertNil(r7,
                     "a login an older build stored has no known origin")
        let r8 = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600), own: false), isActive: false)
        XCTAssertNil(r8,
                     "a pinned profile without its own main login has nothing of its own to refresh")
        XCTAssertEqual(refreshCalls, 0)
    }

    func testARejectedRefreshMarksTheLoginDeadAndIsNotRetried() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        refreshError = ClaudeCodeError.refreshFailed(status: 400, body: #"{"error":"invalid_grant"}"#)
        let profile = goose(stored: login("stored", expiresIn: -600))
        let r9 = await sync.storedLoginForUsage(profile, isActive: false)
        XCTAssertNil(r9)
        let r10 = await sync.storedLoginForUsage(profile, isActive: false)
        XCTAssertNil(r10)
        XCTAssertEqual(refreshCalls, 1, "a dead refresh token is not posted again")
    }

    // MARK: - One refresher at a time

    func testConcurrentReadsRefreshOnce() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        refreshDelayNs = 100_000_000
        let profile = goose(stored: login("stored", expiresIn: -600))
        async let a = sync.storedLoginForUsage(profile, isActive: false)
        async let b = sync.storedLoginForUsage(profile, isActive: false)
        let (ja, jb) = await (a, b)
        XCTAssertEqual(refreshCalls, 1, "the second caller sees the first one's refreshed copy")
        XCTAssertEqual(ja, jb)
    }

    // MARK: - The read-only path stays read-only

    func testUsableCredentialsStillNeverRefreshes() {
        keychain[pinnedService] = login("pinned", expiresIn: -3600)
        _ = sync.usableCredentials(for: goose(stored: login("stored", expiresIn: -600)), isActive: false)
        XCTAssertEqual(refreshCalls, 0)
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: - Gate criticals (2026-10-11 re-gate)

    /// A refused switch can leave the shared login on this INACTIVE account,
    /// rotated past the stored copy by the sessions using it. The stored copy's
    /// refresh token then appears nowhere, yet it is a spent rotation of a live
    /// lineage: posting it is reuse. The shared login being this account's,
    /// by identity, is a refusal.
    func testTheSharedItemHoldingANewerRotationOfThisAccountBlocksTheRefresh() async {
        keychain[mainService] = login("newer", expiresIn: 3600)   // goose, one rotation ahead
        let r = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600)), isActive: false)
        XCTAssertNil(r)
        XCTAssertEqual(refreshCalls, 0)
    }

    func testASharedLoginWhoseAccountCannotBeToldBlocksTheRefresh() async {
        sync.fetchLoginAccountUuid = { at in at.hasPrefix("access-stored-") ? "u-goose" : nil }
        keychain[mainService] = login("unknown", expiresIn: 3600)
        let p = goose(stored: login("stored", expiresIn: -600))
        var noIdentity = p
        noIdentity.oauthAccountJSON = nil
        let r = await sync.storedLoginForUsage(noIdentity, isActive: false)
        XCTAssertNil(r, "no identity for the profile: cannot prove the shared login is another account's")
        XCTAssertEqual(refreshCalls, 0)
    }

    func testAnItemWithNoParsableRefreshTokenBlocksTheRefresh() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        keychain[otherDirService] = "{not json"
        let r = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600)), isActive: false)
        XCTAssertNil(r, "an unreadable payload may be this lineage, half-written")
        XCTAssertEqual(refreshCalls, 0)
    }

    func testAnItemGoneBetweenListAndReadBlocksTheRefresh() async {
        keychain[mainService] = login("main", expiresIn: 3600)
        listed = [mainService, otherDirService]   // listed, but reads back exit 44
        let r = await sync.storedLoginForUsage(goose(stored: login("stored", expiresIn: -600)), isActive: false)
        XCTAssertNil(r)
        XCTAssertEqual(refreshCalls, 0)
    }
}
