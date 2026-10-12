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
    private var tag = ""

    override func setUp() {
        super.setUp()
        tag = UUID().uuidString.prefix(8).lowercased()   // fingerprints are cached per login: unique per test
        savedFetch = sync.fetchLoginAccountUuid
        savedConfig = sync.configOAuthAccountReader
        sync.configOAuthAccountReader = { nil }
    }

    override func tearDown() {
        sync.fetchLoginAccountUuid = savedFetch
        sync.configOAuthAccountReader = savedConfig
        super.tearDown()
    }

    private func login(_ name: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"access-\#(name)-\#(tag)","refreshToken":"refresh-\#(name)-\#(tag)","expiresAt":1,"scopes":["user:inference"]}}"#
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

    func testAProvenUuidIsOnlyAResolvedLookup() async {
        sync.fetchLoginAccountUuid = { _ in nil }
        let goose = login("goose-unresolved")
        await sync.resolveLoginAccount(credentials: goose)
        sync.configOAuthAccountReader = { self.mainConfig }
        XCTAssertNil(sync.provenLoginAccountUuid(goose))
        XCTAssertNil(sync.provenLoginAccountUuid(#"{"claudeAiOauth":{"accessToken":"x"}}"#), "no refresh token, no fingerprint")
    }
}
