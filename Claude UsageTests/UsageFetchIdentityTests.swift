import XCTest
@testable import Claude_Usage

/// A usage reading is stored under a profile ONLY when the login that fetched
/// it is proven to be that profile's account.
///
/// 2026-10-12, 01:43 to 12:16 EDT: auto-switch made littlewing the tracker's
/// active profile while the swap of the shared login was REFUSED (a working
/// session held madmatter's login). The active-profile fallback then read the
/// shared keychain login — madmatter's — with no identity check, and saved
/// madmatter's usage (21% rising to 67% session, 100% weekly) under the
/// littlewing profile for ten hours. The laptop relay pushed it to mission
/// control as "littlewing", and at 02:57 the wrong reading drove a real
/// auto-switch away from littlewing. `loginIsProvenToBelong` already guards
/// the paths that STORE a login; the usage fetch was the one consumer of the
/// shared token that did not use it.
@MainActor
final class UsageFetchIdentityTests: XCTestCase {

    private let sync = ClaudeCodeSyncService.shared
    private var savedFetch: ((String) async -> String?)!
    private var savedConfig: (() -> String?)!
    private var tag = ""

    override func setUp() {
        super.setUp()
        tag = UUID().uuidString.prefix(8).lowercased()
        savedFetch = sync.fetchLoginAccountUuid
        savedConfig = sync.configOAuthAccountReader
        sync.configOAuthAccountReader = { nil }
    }

    override func tearDown() {
        sync.fetchLoginAccountUuid = savedFetch
        sync.configOAuthAccountReader = savedConfig
        super.tearDown()
    }

    /// A login JSON whose access token is valid for an hour.
    private func login(_ who: String, expiresIn: TimeInterval = 3600) -> String {
        let expiry = Int((Date().timeIntervalSince1970 + expiresIn) * 1000)
        return #"{"claudeAiOauth":{"accessToken":"access-\#(who)-\#(tag)","refreshToken":"refresh-\#(who)-\#(tag)","expiresAt":\#(expiry),"scopes":["user:inference"]}}"#
    }

    private func profile(_ email: String, uuid: String, stored: String?, cached: ClaudeUsage?) -> Profile {
        var p = Profile(name: email, cliCredentialsJSON: stored, claudeUsage: cached)
        p.oauthAccountJSON = #"{"accountUuid":"\#(uuid)","emailAddress":"\#(email)"}"#
        p.mainLoginProvenance = "keychain"
        return p
    }

    private func cachedReading(session: Double) -> ClaudeUsage {
        var u = ClaudeUsage.empty
        u.sessionPercentage = session
        u.lastUpdated = Date().addingTimeInterval(-3 * 3600)
        return u
    }

    /// The shared keychain holds madmatter's login, proven by its own account
    /// lookup; the tracker's active profile is littlewing (its stored login
    /// expired, no session key). The reading must NOT be fetched with
    /// madmatter's token and must NOT land on littlewing.
    func testActiveProfileNeverFetchesWithAnotherAccountsSharedLogin() async throws {
        let madmatterLogin = login("madmatter")
        sync.fetchLoginAccountUuid = { token in token.contains("madmatter") ? "u-madmatter" : nil }
        await sync.resolveLoginAccount(credentials: madmatterLogin)   // -> .resolved(u-madmatter)

        let littlewing = profile("littlewing@x.com", uuid: "u-littlewing",
                                 stored: login("littlewing", expiresIn: -600), cached: cachedReading(session: 3))
        var fetchedWith: [String] = []
        let provider = AnthropicUsageProvider(
            readSystemLogin: { madmatterLogin },
            isActiveProfile: { _ in true },
            fetchWithOAuth: { token in
                fetchedWith.append(token)
                var u = ClaudeUsage.empty; u.sessionPercentage = 67; return u
            }
        )

        let result = try await provider.fetchUsage(for: littlewing)

        XCTAssertEqual(fetchedWith, [], "madmatter's shared login must never fetch littlewing's usage")
        XCTAssertEqual(result.sessionPercentage, 3, "littlewing keeps its own last reading, not madmatter's 67%")
    }

    /// Same keychain login, but its account lookup has not succeeded: unknown is
    /// not proof. No fetch.
    func testUnprovenSharedLoginIsNotUsedEither() async throws {
        let unknownLogin = login("unknown")
        sync.fetchLoginAccountUuid = { _ in nil }
        await sync.resolveLoginAccount(credentials: unknownLogin)   // -> .unresolvable

        let littlewing = profile("littlewing@x.com", uuid: "u-littlewing",
                                 stored: login("littlewing", expiresIn: -600), cached: cachedReading(session: 3))
        var fetched = 0
        let provider = AnthropicUsageProvider(
            readSystemLogin: { unknownLogin },
            isActiveProfile: { _ in true },
            fetchWithOAuth: { _ in fetched += 1; return ClaudeUsage.empty }
        )

        _ = try await provider.fetchUsage(for: littlewing)
        XCTAssertEqual(fetched, 0)
    }

    /// The shared login IS the active profile's (proven by lookup): the live
    /// read goes ahead. The gate must not turn the active profile stale.
    func testProvenOwnSharedLoginStillFetches() async throws {
        let ownLogin = login("littlewing-live")
        sync.fetchLoginAccountUuid = { _ in "u-littlewing" }
        await sync.resolveLoginAccount(credentials: ownLogin)

        let littlewing = profile("littlewing@x.com", uuid: "u-littlewing",
                                 stored: login("littlewing", expiresIn: -600), cached: cachedReading(session: 3))
        var fetched = 0
        let provider = AnthropicUsageProvider(
            readSystemLogin: { ownLogin },
            isActiveProfile: { _ in true },
            fetchWithOAuth: { _ in fetched += 1; var u = ClaudeUsage.empty; u.sessionPercentage = 11; return u }
        )

        let result = try await provider.fetchUsage(for: littlewing)
        XCTAssertEqual(fetched, 1)
        XCTAssertEqual(result.sessionPercentage, 11)
    }

    /// Proof by refresh token: the shared login is the profile's own stored
    /// login (same lineage, rotated access token), no lookup needed.
    func testSharedLoginMatchingTheStoredLineageFetches() async throws {
        sync.fetchLoginAccountUuid = { _ in nil }
        let stored = login("mattgg", expiresIn: -600)          // expired stored copy
        let live = login("mattgg").replacingOccurrences(of: "access-mattgg", with: "access-mattgg-rotated")

        let mattgg = profile("mattgg@x.com", uuid: "u-mattgg", stored: stored, cached: nil)
        var fetched = 0
        let provider = AnthropicUsageProvider(
            readSystemLogin: { live },
            isActiveProfile: { _ in true },
            fetchWithOAuth: { _ in fetched += 1; return ClaudeUsage.empty }
        )
        _ = try await provider.fetchUsage(for: mattgg)
        XCTAssertEqual(fetched, 1, "the valid same-lineage shared login fetches")
    }
}

/// The single-profile refresh saved its reading under whichever profile was
/// active when the request COMPLETED, not the one it was made for.
final class UsageAttributionTests: XCTestCase {
    func testReadingIsFiledUnderTheProfileItWasFetchedFor() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(UsageAttribution.saveTarget(fetchedFor: a, activeNow: a), a)
        XCTAssertNil(UsageAttribution.saveTarget(fetchedFor: a, activeNow: b), "active changed mid-flight: discard")
        XCTAssertNil(UsageAttribution.saveTarget(fetchedFor: nil, activeNow: b))
    }
}
