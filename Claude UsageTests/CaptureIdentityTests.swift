import XCTest
@testable import Claude_Usage

/// A login from the shared keychain item is stored under a profile only when
/// it is PROVEN to be that profile's: the login's own account lookup
/// (`.resolved` uuid) names the profile's account, or its refresh token is the
/// profile's stored one. `.claude.json`'s `oauthAccount` never decides: after a
/// `/login` it can still name the previous account. Trusting it stored goose's
/// live login under main's profile; a later switch to main then refreshed a
/// spent rotation of goose's lineage, which logs goose's sessions out.
final class CaptureIdentityTests: XCTestCase {

    private let sync = ClaudeCodeSyncService.shared
    private let mainConfig = #"{"accountUuid":"u-main","emailAddress":"main@x.com"}"#
    private var savedFetch: ((String) async -> String?)!
    private var savedConfig: (() -> String?)!
    private var savedRetryInterval: TimeInterval = 60
    private var tag = ""

    override func setUp() {
        super.setUp()
        tag = UUID().uuidString.prefix(8).lowercased()   // fingerprints are cached per login: unique per test
        savedFetch = sync.fetchLoginAccountUuid
        savedConfig = sync.configOAuthAccountReader
        savedRetryInterval = sync.loginAccountRetryInterval
        sync.configOAuthAccountReader = { nil }
    }

    override func tearDown() {
        sync.fetchLoginAccountUuid = savedFetch
        sync.configOAuthAccountReader = savedConfig
        sync.loginAccountRetryInterval = savedRetryInterval
        super.tearDown()
    }

    private func login(_ name: String) -> String {
        login(access: name, refresh: name)
    }

    private func login(access: String, refresh: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"access-\#(access)-\#(tag)","refreshToken":"refresh-\#(refresh)-\#(tag)","expiresAt":1,"scopes":["user:inference"]}}"#
    }

    /// Polls until `condition` holds or `timeout` passes (a fire-and-forget
    /// lookup Task has no handle to await).
    private func eventually(_ timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func mainProfile(stored: String? = nil) -> Profile {
        var p = Profile(name: "main@x.com", cliCredentialsJSON: stored)
        p.oauthAccountJSON = mainConfig
        p.mainLoginProvenance = "keychain"
        return p
    }

    /// goose's live login sits in the shared item; its account lookup failed
    /// (idle expired access token, or offline); `.claude.json` still names main.
    private func gooseLoginUnresolvedWithStaleConfig() async -> String {
        sync.fetchLoginAccountUuid = { _ in nil }
        sync.configOAuthAccountReader = { self.mainConfig }
        let goose = login("goose")
        await sync.resolveLoginAccount(credentials: goose)   // -> unresolvable
        return goose
    }

    // MARK: - Probe 1: the per-cycle capture (systemCredentials -> captureMainLogin / usableCredentials)

    func testAnUnresolvedLoginIsNotAttributedThroughClaudeJson() async {
        let goose = await gooseLoginUnresolvedWithStaleConfig()
        XCTAssertFalse(sync.systemCredentials(goose, belongTo: mainProfile(stored: login("main-old"))))
    }

    // MARK: - Probe 2: resyncBeforeSwitching

    func testResyncRefusesAnUnresolvedLoginEvenWhenClaudeJsonNamesTheProfile() async {
        let goose = await gooseLoginUnresolvedWithStaleConfig()
        XCTAssertFalse(sync.resyncAllowed(freshJSON: goose, profile: mainProfile(stored: login("main-old"))))
    }

    // MARK: - oauthAccount attribution and syncToProfile

    func testTheConfigAccountIsNotCopiedOntoAnUnresolvedLogin() async {
        let goose = await gooseLoginUnresolvedWithStaleConfig()
        XCTAssertNil(sync.loginOAuthAccount(credentials: goose, configOAuthAccount: mainConfig))
    }

    func testSyncToProfileRefusesAnUnprovenLoginForAProfileWithAnAccount() async {
        let goose = await gooseLoginUnresolvedWithStaleConfig()
        XCTAssertNotNil(sync.syncToProfileRefusal(goose, profile: mainProfile(stored: login("main-old"))))
    }

    // MARK: - Proof still works

    func testAResolvedLoginOfTheProfilesAccountIsAttributed() async {
        sync.fetchLoginAccountUuid = { _ in "u-main" }
        let rotated = login("main-new")
        await sync.resolveLoginAccount(credentials: rotated)
        let profile = mainProfile(stored: login("main-old"))
        XCTAssertTrue(sync.systemCredentials(rotated, belongTo: profile))
        XCTAssertTrue(sync.resyncAllowed(freshJSON: rotated, profile: profile))
        XCTAssertNil(sync.syncToProfileRefusal(rotated, profile: profile))
        XCTAssertNil(sync.loginOAuthAccount(credentials: rotated, configOAuthAccount: #"{"accountUuid":"u-goose"}"#))
        XCTAssertEqual(sync.loginOAuthAccount(credentials: rotated, configOAuthAccount: mainConfig), mainConfig)
    }

    func testTheSameRefreshTokenIsProofWithoutALookup() async {
        sync.fetchLoginAccountUuid = { _ in nil }
        let same = login("main-same")
        await sync.resolveLoginAccount(credentials: same)
        let profile = mainProfile(stored: same)
        XCTAssertTrue(sync.systemCredentials(same, belongTo: profile))
        XCTAssertTrue(sync.resyncAllowed(freshJSON: same, profile: profile))
    }

    func testAResolvedLoginOfAnotherAccountIsRefusedEverywhere() async {
        sync.fetchLoginAccountUuid = { _ in "u-goose" }
        let goose = login("goose-resolved")
        await sync.resolveLoginAccount(credentials: goose)
        let profile = mainProfile(stored: login("main-old"))
        XCTAssertFalse(sync.systemCredentials(goose, belongTo: profile))
        XCTAssertFalse(sync.resyncAllowed(freshJSON: goose, profile: profile))
        XCTAssertNotNil(sync.syncToProfileRefusal(goose, profile: profile))
    }

    // MARK: - Lookup liveness (gate on 96bba96)
    //
    // Proof now requires the login's own account lookup, so a lookup that
    // fails once must not leave the login unprovable for the rest of the app's
    // life: the capture, resync and adopt paths would all stay refused.

    func testProbeA_aTransientLookupFailureIsRetried() async {
        sync.loginAccountRetryInterval = 0
        sync.fetchLoginAccountUuid = { _ in nil }                 // offline
        let main = login("main-flaky")
        await sync.resolveLoginAccount(credentials: main)          // -> unresolvable
        XCTAssertNil(sync.provenLoginAccountUuid(main))

        sync.fetchLoginAccountUuid = { _ in "u-main" }            // back online
        _ = sync.provenLoginAccountUuid(main)                      // the next cycle asks again
        let proven = await eventually { self.sync.provenLoginAccountUuid(main) == "u-main" }
        XCTAssertTrue(proven, "a failed lookup must be retried, not remembered forever")
    }

    func testProbeB_aRenewedAccessTokenWithTheSameRefreshTokenIsLookedUpAgain() async {
        sync.loginAccountRetryInterval = .infinity                 // only the token change may trigger it
        sync.fetchLoginAccountUuid = { token in token.hasPrefix("access-expired") ? nil : "u-main" }
        let expired = login(access: "expired", refresh: "main-lineage")
        await sync.resolveLoginAccount(credentials: expired)       // -> unresolvable (401 on the old token)
        XCTAssertNil(sync.provenLoginAccountUuid(expired))

        let renewed = login(access: "renewed", refresh: "main-lineage")
        _ = sync.provenLoginAccountUuid(renewed)
        let proven = await eventually { self.sync.provenLoginAccountUuid(renewed) == "u-main" }
        XCTAssertTrue(proven, "the same login with a fresh access token is a new chance to prove it")
    }

    func testProbeC_aLateParallelFailureNeverOverwritesAResolvedLookup() async {
        // Two cycles ask about the same login before the first lookup answers.
        // The first answers; a second, slower one fails. The login stays proven.
        let main = login("main-raced")
        let calls = Counter()
        sync.fetchLoginAccountUuid = { _ in
            if calls.increment() == 1 {
                // Let a second lookup start (if one is going to) before answering.
                _ = await self.eventually(0.3) { calls.value >= 2 }
                return "u-main"
            }
            // Fail only after the first answer has landed.
            _ = await self.eventually(2) { self.sync.provenLoginAccountUuid(main) != nil }
            return nil
        }

        async let first: Void = sync.resolveLoginAccount(credentials: main)
        async let second: Void = sync.resolveLoginAccount(credentials: main)
        _ = await (first, second)

        XCTAssertEqual(sync.provenLoginAccountUuid(main), "u-main")
        XCTAssertEqual(calls.value, 1, "one lookup per login at a time")
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }

    func testAProvenUuidIsOnlyAResolvedLookup() async {
        sync.fetchLoginAccountUuid = { _ in nil }
        let goose = login("goose-unresolved")
        await sync.resolveLoginAccount(credentials: goose)
        sync.configOAuthAccountReader = { self.mainConfig }
        XCTAssertNil(sync.provenLoginAccountUuid(goose))
        XCTAssertNil(sync.provenLoginAccountUuid(#"{"claudeAiOauth":{"accessToken":"x"}}"#), "no refresh token, no fingerprint")
    }
}
