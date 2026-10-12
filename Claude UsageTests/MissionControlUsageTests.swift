import XCTest
@testable import Claude_Usage

/// Inactive profiles' usage from mission control (mc). The tracker never
/// refreshes an inactive login (0bca20c; option B shelved, see
/// docs/stored-login-refresh-shelved.md on fix/usage-all-accounts), so an
/// inactive profile's own reading ages for hours. mc's `usage-self` lane on
/// littlewing reads every account read-only every 5 minutes; these tests pin
/// how the tracker takes those readings: only for a proven profile, only when
/// newer than its own and fresh, never for the active profile, nothing at all
/// when mc is unconfigured or the fetch fails, and never a token in a log.
final class MissionControlUsageTests: XCTestCase {

    private let home = "/Users/tester"
    private let token = "mcu_SECRET-token-value-1234567890"
    private var now: Date!

    override func setUp() {
        super.setUp()
        now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    // MARK: - Mapping

    func testMapsAnMcAccountToTheProfileWhoseAccountEmailTheRotateConfigNames() throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        let littlewing = profile(email: "littlewing@example.com", pinnedDir: "\(home)/.claude-rotate/accounts/littlewing")
        let goose = profile(email: "goose@example.com", pinnedDir: "\(home)/.claude-rotate/accounts/goose")
        let mattgg = profile(email: "matt@example.com", pinnedDir: nil)   // unpinned: the email alone proves it

        let matched = McUsage.matchProfiles(
            readings: [reading("littlewing"), reading("goose"), reading("mattgg")],
            rotate: rotate, profiles: [littlewing, goose, mattgg])

        XCTAssertEqual(matched[littlewing.id]?.account, "littlewing")
        XCTAssertEqual(matched[goose.id]?.account, "goose")
        XCTAssertEqual(matched[mattgg.id]?.account, "mattgg")
    }

    func testTheEmailMatchIsCaseInsensitiveButExact() throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        let upper = profile(email: "LittleWing@Example.com", pinnedDir: "\(home)/.claude-rotate/accounts/littlewing")
        let lookalike = profile(email: "littlewing@example.co", pinnedDir: nil)
        XCTAssertEqual(McUsage.matchProfiles(readings: [reading("littlewing")], rotate: rotate,
                                             profiles: [upper])[upper.id]?.account, "littlewing")
        XCTAssertTrue(McUsage.matchProfiles(readings: [reading("littlewing")], rotate: rotate,
                                            profiles: [lookalike]).isEmpty)
    }

    func testNeverGuessesAMatch() throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))

        // The profile NAME looks right but its account email is another account's.
        var renamed = profile(email: "goose@example.com", pinnedDir: nil)
        renamed.name = "littlewing@example.com"
        XCTAssertNil(McUsage.matchProfiles(readings: [reading("littlewing")], rotate: rotate,
                                           profiles: [renamed])[renamed.id])

        // No account identity recorded on the profile at all.
        var unknown = profile(email: "littlewing@example.com", pinnedDir: nil)
        unknown.oauthAccountJSON = nil
        unknown.name = "littlewing@example.com"
        XCTAssertTrue(McUsage.matchProfiles(readings: [reading("littlewing")], rotate: rotate,
                                            profiles: [unknown]).isEmpty)

        // The email matches but the profile is pinned to a different config dir:
        // contradictory evidence refuses.
        let wrongPin = profile(email: "littlewing@example.com", pinnedDir: "\(home)/.claude-rotate/accounts/goose")
        XCTAssertTrue(McUsage.matchProfiles(readings: [reading("littlewing")], rotate: rotate,
                                            profiles: [wrongPin]).isEmpty)

        // An mc account the local rotate config does not name.
        let lw = profile(email: "littlewing@example.com", pinnedDir: nil)
        XCTAssertTrue(McUsage.matchProfiles(readings: [reading("stranger")], rotate: rotate,
                                            profiles: [lw]).isEmpty)

        // Two profiles carry the same account email: ambiguous, neither matches.
        let a = profile(email: "littlewing@example.com", pinnedDir: nil)
        let b = profile(email: "littlewing@example.com", pinnedDir: nil)
        XCTAssertTrue(McUsage.matchProfiles(readings: [reading("littlewing")], rotate: rotate,
                                            profiles: [a, b]).isEmpty)

        // mc lists the same account twice: ambiguous, ignored.
        XCTAssertTrue(McUsage.matchProfiles(readings: [reading("littlewing"), reading("littlewing")],
                                            rotate: rotate, profiles: [lw]).isEmpty)

        // A Codex profile is never an Anthropic account.
        var codex = profile(email: "littlewing@example.com", pinnedDir: nil)
        codex.provider = .codex
        XCTAssertTrue(McUsage.matchProfiles(readings: [reading("littlewing")], rotate: rotate,
                                            profiles: [codex]).isEmpty)
    }

    func testARotateConfigNamingOneEmailTwiceMatchesNothingForIt() throws {
        let json = #"{"accounts":[{"name":"a","email":"x@example.com","dir":"~/r/a"},{"name":"b","email":"X@example.com","dir":"~/r/b"}]}"#
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(Data(json.utf8), home: home))
        let p = profile(email: "x@example.com", pinnedDir: nil)
        XCTAssertTrue(McUsage.matchProfiles(readings: [reading("a"), reading("b")], rotate: rotate, profiles: [p]).isEmpty)
    }

    func testPinnedServiceNameIsClaudeCodesHashOfTheExpandedDir() throws {
        // The same derivation Claude Code (and mc's usage_self.service_name) uses.
        XCTAssertEqual(McUsage.pinnedServiceName(forConfigDir: "/Users/matthewgrasmick/.claude-rotate/accounts/grasmash"),
                       "Claude Code-credentials-ad69966b")
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        XCTAssertEqual(rotate.first { $0.name == "littlewing" }?.dir, "\(home)/.claude-rotate/accounts/littlewing")
    }

    func testParsesMcAccountUsage() throws {
        let readings = try XCTUnwrap(McUsage.parseAccountUsage(accountUsageJSON([
            account("littlewing", sampledAt: now.addingTimeInterval(-60), session: 3, weekly: 0, fable: 12),
            #"{"name":"nousage","usage":null}"#,
            account("noweekly", sampledAt: now, session: 3, weekly: nil, fable: nil),
        ])))
        XCTAssertEqual(readings.map(\.account), ["littlewing"])   // incomplete readings stay unknown
        let r = try XCTUnwrap(readings.first)
        XCTAssertEqual(r.sessionPct, 3)
        XCTAssertEqual(r.weeklyPct, 0)
        XCTAssertEqual(r.fablePct, 12)
        XCTAssertEqual(r.sampledAt.timeIntervalSince1970, now.addingTimeInterval(-60).timeIntervalSince1970, accuracy: 1)
        XCTAssertNil(McUsage.parseAccountUsage(Data("not json".utf8)))
        XCTAssertNil(McUsage.parseAccountUsage(Data(#"{"no_accounts":true}"#.utf8)))
    }

    // MARK: - Freshness precedence

    func testAnMcReadingNewerThanTheProfilesOwnAndFreshIsTakenAndMarked() throws {
        let own = usage(weekly: 100, updatedAt: now.addingTimeInterval(-5 * 3600))
        let r = reading("littlewing", sampledAt: now.addingTimeInterval(-120), session: 4, weekly: 0, fable: 7)
        let taken = try XCTUnwrap(McUsage.usage(from: r, over: own, now: now))
        XCTAssertEqual(taken.weeklyPercentage, 0)
        XCTAssertEqual(taken.sessionPercentage, 4)
        XCTAssertEqual(taken.fableWeeklyPercentage, 7)
        XCTAssertEqual(taken.lastUpdated, r.sampledAt, "lastUpdated is mc's sample time, never the fetch time")
        XCTAssertEqual(taken.source, ClaudeUsage.sourceMissionControl)
        XCTAssertFalse(taken.isStale(now: now))
    }

    func testTheProfilesOwnReadingWinsWhenItIsNewerOrTheSame() {
        let own = usage(weekly: 50, updatedAt: now.addingTimeInterval(-60))
        XCTAssertNil(McUsage.usage(from: reading("a", sampledAt: now.addingTimeInterval(-120)), over: own, now: now))
        XCTAssertNil(McUsage.usage(from: reading("a", sampledAt: own.lastUpdated), over: own, now: now))
        // mc echoing the tracker's own reading (the laptop `usage` lane posts it) is not newer.
        XCTAssertNil(McUsage.usage(from: reading("a", sampledAt: own.lastUpdated.addingTimeInterval(0.5)), over: own, now: now))
    }

    func testAnMcReadingTenMinutesOldOrMoreIsNeverTaken() {
        let own = usage(weekly: 100, updatedAt: now.addingTimeInterval(-5 * 3600))
        XCTAssertNil(McUsage.usage(from: reading("a", sampledAt: now.addingTimeInterval(-Constants.usageStaleAfter)), over: own, now: now))
        XCTAssertNil(McUsage.usage(from: reading("a", sampledAt: now.addingTimeInterval(-3600)), over: own, now: now))
        XCTAssertNotNil(McUsage.usage(from: reading("a", sampledAt: now.addingTimeInterval(-(Constants.usageStaleAfter - 5))), over: own, now: now))
    }

    func testAnMcReadingFromTheFutureIsNeverTaken() {
        XCTAssertNil(McUsage.usage(from: reading("a", sampledAt: now.addingTimeInterval(400)), over: nil, now: now))
        // Small clock skew is tolerated but never makes the reading look newer than now.
        let skewed = McUsage.usage(from: reading("a", sampledAt: now.addingTimeInterval(30)), over: nil, now: now)
        XCTAssertEqual(skewed?.lastUpdated, now)
    }

    func testTheOverlayNeverTouchesTheActiveProfile() throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        var active = profile(email: "littlewing@example.com", pinnedDir: nil)
        active.claudeUsage = usage(weekly: 100, updatedAt: now.addingTimeInterval(-3600))
        var inactive = profile(email: "goose@example.com", pinnedDir: nil)
        inactive.claudeUsage = usage(weekly: 100, updatedAt: now.addingTimeInterval(-3600))

        let updates = McUsage.overlay(
            profiles: [active, inactive], activeProfileId: active.id,
            readings: [reading("littlewing", sampledAt: now.addingTimeInterval(-60), weekly: 0),
                       reading("goose", sampledAt: now.addingTimeInterval(-60), weekly: 0)],
            rotate: rotate, now: now)

        XCTAssertEqual(updates.map(\.profileId), [inactive.id])
        XCTAssertEqual(updates.first?.usage.weeklyPercentage, 0)
    }

    func testAPausedProfileIsStillShownItsMcReading() throws {
        // Paused only removes it from auto-switch; the reading is still true.
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        var paused = profile(email: "goose@example.com", pinnedDir: nil)
        paused.isPaused = true
        let updates = McUsage.overlay(profiles: [paused], activeProfileId: nil,
                                      readings: [reading("goose", sampledAt: now.addingTimeInterval(-60))],
                                      rotate: rotate, now: now)
        XCTAssertEqual(updates.count, 1)
    }

    // MARK: - Fetch failure falls back to today's behaviour

    func testNoConfigMakesNoRequestAndReturnsNothing() async {
        var requests = 0
        let client = McUsageClient(transport: { _ in requests += 1; return (Data(), self.http(200)) },
                                   log: { _ in }, now: { self.now })
        let readings = await client.fetchReadings(config: nil)
        XCTAssertTrue(readings.isEmpty)
        XCTAssertEqual(requests, 0)
        XCTAssertNil(McUsageClient.Config(baseURL: "", token: token))
        XCTAssertNil(McUsageClient.Config(baseURL: "https://mc.example", token: "  "))
        XCTAssertNil(McUsageClient.Config(baseURL: "http://mc.example", token: token), "a bearer token is never sent in clear text")
    }

    func testAFailedFetchReturnsNothingAndChangesNoProfile() async throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        var goose = profile(email: "goose@example.com", pinnedDir: nil)
        let own = usage(weekly: 100, updatedAt: now.addingTimeInterval(-3 * 3600))
        goose.claudeUsage = own
        let config = try XCTUnwrap(McUsageClient.Config(baseURL: "https://mc.example:8443", token: token))

        let failures: [(Data, URLResponse)?] = [
            nil,                                        // transport error
            (Data(#"{"error":"unauthenticated"}"#.utf8), http(401)),
            (Data(#"{"error":"boom"}"#.utf8), http(500)),
            (Data("<html>".utf8), http(200)),           // unparseable
            (accountUsageJSON([account("goose", sampledAt: now.addingTimeInterval(-60), session: 0, weekly: 0, fable: 0)]),
             URLResponse(url: URL(string: "https://mc.example")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)),
        ]
        for failure in failures {
            let client = McUsageClient(transport: { _ in
                guard let failure else { throw URLError(.timedOut) }
                return failure
            }, log: { _ in }, now: { self.now })
            let readings = await client.fetchReadings(config: config)
            XCTAssertTrue(readings.isEmpty)
            XCTAssertTrue(McUsage.overlay(profiles: [goose], activeProfileId: nil, readings: readings,
                                          rotate: rotate, now: now).isEmpty)
            XCTAssertEqual(goose.claudeUsage, own)
        }
    }

    func testAFailureDoesNotServeAnEarlierSuccessAsFresh() async throws {
        let config = try XCTUnwrap(McUsageClient.Config(baseURL: "https://mc.example", token: token))
        var clock = now!
        var fail = false
        let body = accountUsageJSON([account("goose", sampledAt: now.addingTimeInterval(-60), session: 0, weekly: 0, fable: 0)])
        let client = McUsageClient(transport: { _ in
            if fail { throw URLError(.notConnectedToInternet) }
            return (body, self.http(200))
        }, log: { _ in }, minInterval: 60, now: { clock })

        let first = await client.fetchReadings(config: config)
        XCTAssertEqual(first.count, 1)
        fail = true
        clock = clock.addingTimeInterval(61)
        let second = await client.fetchReadings(config: config)
        XCTAssertTrue(second.isEmpty, "a failed fetch is no readings, not the last good ones")
    }

    func testFetchesAreThrottledAndSendTheTokenOnlyAsABearerHeader() async throws {
        let config = try XCTUnwrap(McUsageClient.Config(baseURL: "https://mc.example:8443/", token: token))
        var seen: [URLRequest] = []
        var clock = now!
        let body = accountUsageJSON([account("goose", sampledAt: now.addingTimeInterval(-60), session: 0, weekly: 0, fable: 0)])
        let client = McUsageClient(transport: { req in seen.append(req); return (body, self.http(200)) },
                                   log: { _ in }, minInterval: 60, now: { clock })

        _ = await client.fetchReadings(config: config)
        clock = clock.addingTimeInterval(30)
        let cached = await client.fetchReadings(config: config)
        XCTAssertEqual(seen.count, 1, "at most one request per minInterval")
        XCTAssertEqual(cached.count, 1)

        let req = try XCTUnwrap(seen.first)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString, "https://mc.example:8443/v1/accounts/usage")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertFalse(req.url?.absoluteString.contains(token) ?? true)
        XCTAssertNil(req.httpBody)
    }

    // MARK: - No token in logs

    func testTheTokenNeverReachesALogOrTheStatusText() async throws {
        let config = try XCTUnwrap(McUsageClient.Config(baseURL: "https://mc.example", token: token))
        struct Leaky: LocalizedError { let t: String; var errorDescription: String? { "failed with \(t)" } }
        let responses: [() throws -> (Data, URLResponse)] = [
            { (self.accountUsageJSON([self.account("goose", sampledAt: self.now, session: 0, weekly: 0, fable: 0)]), self.http(200)) },
            { (Data("unknown token \(self.token)".utf8), self.http(401)) },   // a server echoing the token
            { (Data("bad \(self.token)".utf8), self.http(200)) },
            { throw Leaky(t: self.token) },                                   // an error whose text holds it
        ]
        var logs: [String] = []
        var statuses: [String] = []
        for respond in responses {
            let client = McUsageClient(transport: { _ in try respond() }, log: { logs.append($0) }, now: { self.now })
            _ = await client.fetchReadings(config: config)
            statuses.append(client.lastStatus)
        }
        XCTAssertFalse(logs.isEmpty, "the client does log its outcomes")
        for line in logs + statuses {
            XCTAssertFalse(line.contains(token), "token leaked: \(line)")
            XCTAssertFalse(line.contains("SECRET"), "token fragment leaked: \(line)")
        }
    }

    // MARK: - The auto-switch policy sees an mc reading as fresh

    func testThePolicyTakesAnMcFreshAccountOverAPresumedFreeOne() throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        // Current account is spent.
        let current = applicable(email: "matt@example.com", usage: usage(weekly: 100, updatedAt: now))
        // goose: stale, its 100% window has passed -> only "presumed free".
        let goose = applicable(email: "goose@example.com",
                               usage: usage(weekly: 100, weeklyResetIn: -60, updatedAt: now.addingTimeInterval(-4 * 3600)))
        // littlewing: own reading 15:45Z, 100% weekly, window still in force -> skipped today.
        let littlewing = applicable(email: "littlewing@example.com",
                                    usage: usage(weekly: 100, weeklyResetIn: 3 * 86400, updatedAt: now.addingTimeInterval(-6 * 3600)))
        let profiles = [current, goose, littlewing]

        XCTAssertEqual(AutoSwitchPolicy.nextAvailableProfile(in: profiles, after: current, now: now)?.id, goose.id,
                       "without mc, the only target is a presumption")

        let updates = McUsage.overlay(profiles: profiles, activeProfileId: current.id,
                                      readings: [reading("littlewing", sampledAt: now.addingTimeInterval(-90), weekly: 0)],
                                      rotate: rotate, now: now)
        var after = profiles
        for u in updates { after[after.firstIndex { $0.id == u.profileId }!].claudeUsage = u.usage }

        XCTAssertFalse(after[2].claudeUsage!.isStale(now: now))
        XCTAssertEqual(AutoSwitchPolicy.nextAvailableProfile(in: after, after: current, now: now)?.id, littlewing.id,
                       "an mc-fresh reading is an observation and beats a presumption")
    }

    func testAnMcFreshSpentReadingKeepsTheAccountOutOfRotation() throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        let current = applicable(email: "matt@example.com", usage: usage(weekly: 100, updatedAt: now))
        // goose's own stale reading would be presumed free; mc says it is spent right now.
        let goose = applicable(email: "goose@example.com",
                               usage: usage(weekly: 100, weeklyResetIn: -60, updatedAt: now.addingTimeInterval(-4 * 3600)))
        let profiles = [current, goose]
        let updates = McUsage.overlay(profiles: profiles, activeProfileId: current.id,
                                      readings: [reading("goose", sampledAt: now.addingTimeInterval(-60), session: 100, weekly: 40)],
                                      rotate: rotate, now: now)
        var after = profiles
        for u in updates { after[after.firstIndex { $0.id == u.profileId }!].claudeUsage = u.usage }
        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: after, after: current, now: now))
    }

    // MARK: - A missing Fable reading is never "0% Fable"

    func testANullFableMcReadingOverAStaleSpentFableProfileIsNeitherATargetNorHeadroom() throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        let current = applicable(email: "matt@example.com", usage: usage(weekly: 100, updatedAt: now))
        // goose: own reading 4h old, Fable 100% with its window still in force.
        var gooseUsage = usage(weekly: 20, updatedAt: now.addingTimeInterval(-4 * 3600))
        gooseUsage.fableWeeklyPercentage = 100
        gooseUsage.fableWeeklyResetTime = now.addingTimeInterval(2 * 86400)
        let goose = applicable(email: "goose@example.com", usage: gooseUsage)

        let updates = McUsage.overlay(profiles: [current, goose], activeProfileId: current.id,
                                      readings: [reading("goose", sampledAt: now.addingTimeInterval(-60), weekly: 20, fable: nil)],
                                      rotate: rotate, now: now)
        var after = [current, goose]
        for u in updates { after[after.firstIndex { $0.id == u.profileId }!].claudeUsage = u.usage }

        XCTAssertNotEqual(after[1].claudeUsage?.fableWeeklyPercentage, 0, "no fabricated Fable headroom")
        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: after, after: current, usingFable: true, now: now))
        XCTAssertFalse(AutoSwitchPolicy.anyProfileHasFableHeadroom([after[1]], now: now))
        // When it IS carried, it is the profile's own 100% in force, not a fresh 0%.
        if let u = updates.first { XCTAssertEqual(u.usage.fableWeeklyPercentage, 100) }
    }

    func testANullFableMcReadingIsNotTakenWhenTheProfilesFableWindowHasPassedOrIsUnknown() {
        var own = usage(weekly: 100, updatedAt: now.addingTimeInterval(-5 * 3600))
        own.fableWeeklyPercentage = 100
        own.fableWeeklyResetTime = now.addingTimeInterval(-60)   // passed
        let r = reading("a", sampledAt: now.addingTimeInterval(-60), weekly: 0, fable: nil)
        XCTAssertNil(McUsage.usage(from: r, over: own, now: now))
        own.fableWeeklyResetTime = nil                           // unknown
        XCTAssertNil(McUsage.usage(from: r, over: own, now: now))
        XCTAssertNil(McUsage.usage(from: r, over: nil, now: now))
        // An hours-old PARTIAL Fable value (window in force) is not certain any more:
        // never carried under a fresh timestamp.
        own.fableWeeklyResetTime = now.addingTimeInterval(2 * 86400)
        for partial in [60.0, 0.0] {
            own.fableWeeklyPercentage = partial
            XCTAssertNil(McUsage.usage(from: r, over: own, now: now), "own Fable \(partial)%")
        }
        // A measured Fable value is still taken as measured.
        XCTAssertEqual(McUsage.usage(from: reading("a", sampledAt: now.addingTimeInterval(-60), fable: 5), over: own, now: now)?
            .fableWeeklyPercentage, 5)
    }

    func testANullFableMcReadingOverAStalePartialFableProfileInventsNoFableHeadroom() throws {
        let rotate = try XCTUnwrap(McUsage.parseRotateConfig(rotateConfig(), home: home))
        let current = applicable(email: "matt@example.com", usage: usage(weekly: 100, updatedAt: now))
        // goose: own reading 4h old, Fable 60% with its window in force.
        var own = usage(weekly: 20, updatedAt: now.addingTimeInterval(-4 * 3600))
        own.fableWeeklyPercentage = 60
        own.fableWeeklyResetTime = now.addingTimeInterval(2 * 86400)
        let goose = applicable(email: "goose@example.com", usage: own)

        let updates = McUsage.overlay(profiles: [current, goose], activeProfileId: current.id,
                                      readings: [reading("goose", sampledAt: now.addingTimeInterval(-60), weekly: 20, fable: nil)],
                                      rotate: rotate, now: now)
        var after = [current, goose]
        for u in updates { after[after.firstIndex { $0.id == u.profileId }!].claudeUsage = u.usage }

        XCTAssertTrue(updates.isEmpty, "the own (stale) reading stands")
        XCTAssertFalse(AutoSwitchPolicy.anyProfileHasFableHeadroom([after[1]], now: now),
                       "a stale 60% must not become fresh Fable headroom (would fire .switchFirst)")
        XCTAssertEqual(AutoSwitchPolicy.fableRestoreAction(profiles: after, activeId: current.id, now: now), .wait(.noHeadroom))
    }

    func testTheClientRefusesRedirects() {
        let expectation = expectation(description: "redirect decision")
        let task = URLSession.shared.dataTask(with: URL(string: "https://mc.example/v1/accounts/usage")!)
        McUsageClient.NoRedirects().urlSession(
            URLSession.shared, task: task,
            willPerformHTTPRedirection: http(302),
            newRequest: URLRequest(url: URL(string: "https://elsewhere.example/")!)) { next in
                XCTAssertNil(next, "the bearer token is never forwarded to a redirect target")
                expectation.fulfill()
            }
        task.cancel()
        wait(for: [expectation], timeout: 1)
    }

    // MARK: - Fixtures

    private func rotateConfig() -> Data {
        Data(#"""
        {"accounts":[
          {"name":"littlewing","email":"littlewing@example.com","dir":"~/.claude-rotate/accounts/littlewing"},
          {"name":"goose","email":"goose@example.com","dir":"~/.claude-rotate/accounts/goose"},
          {"name":"mattgg","email":"matt@example.com","dir":"/Users/tester/.claude-rotate/accounts/mattgg"}
        ]}
        """#.utf8)
    }

    private func profile(email: String, pinnedDir: String?) -> Profile {
        Profile(
            name: email,
            customKeychainServiceName: pinnedDir.map { McUsage.pinnedServiceName(forConfigDir: $0) },
            oauthAccountJSON: #"{"emailAddress":"\#(email)","accountUuid":"\#(UUID().uuidString)"}"#
        )
    }

    private func applicable(email: String, usage: ClaudeUsage) -> Profile {
        var p = profile(email: email, pinnedDir: nil)
        p.cliCredentialsJSON = #"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r"}}"#
        p.claudeUsage = usage
        return p
    }

    private func reading(_ account: String, sampledAt: Date? = nil, session: Double = 0, weekly: Double = 0,
                         fable: Double? = 0) -> McUsageReading {
        let at = sampledAt ?? now.addingTimeInterval(-60)
        return McUsageReading(account: account, sampledAt: at,
                              sessionPct: session, sessionResetsAt: at.addingTimeInterval(3600),
                              weeklyPct: weekly, weeklyResetsAt: at.addingTimeInterval(3 * 86400),
                              fablePct: fable, fableResetsAt: fable == nil ? nil : at.addingTimeInterval(3 * 86400))
    }

    private func usage(weekly: Double, session: Double = 0, weeklyResetIn: TimeInterval = 86400,
                       updatedAt: Date) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0, sessionLimit: 0, sessionPercentage: session,
            sessionResetTime: Date().addingTimeInterval(3600),
            weeklyTokensUsed: 0, weeklyLimit: 1_000_000, weeklyPercentage: weekly,
            weeklyResetTime: Date().addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0, designWeeklyPercentage: 0, designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0, fableWeeklyPercentage: 0, fableWeeklyResetTime: nil,
            costUsed: nil, costLimit: nil, costCurrency: nil,
            lastUpdated: updatedAt, userTimezone: .current)
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    private func window(_ pct: Double?, _ resets: Date, _ s: Int) -> String {
        guard let pct else { return "null" }
        return #"{"used_pct":\#(pct),"resets_at":"\#(iso(resets))","window_s":\#(s)}"#
    }

    private func account(_ name: String, sampledAt: Date, session: Double?, weekly: Double?, fable: Double?) -> String {
        let r = sampledAt.addingTimeInterval(3600)
        return #"{"name":"\#(name)","usage":{"sampled_at":"\#(iso(sampledAt))","paused":false,"session":\#(window(session, r, 18000)),"weekly":\#(window(weekly, r, 604800)),"fable":\#(window(fable, r, 604800))}}"#
    }

    private func accountUsageJSON(_ accounts: [String]) -> Data {
        Data(#"{"accounts":[\#(accounts.joined(separator: ","))]}"#.utf8)
    }

    private func http(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://mc.example/v1/accounts/usage")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// The mc token lives in the app's own keychain item, never in UserDefaults:
/// the prefs domain is cleartext, and mc's laptop `usage` lane runs
/// `defaults export` on it, which would ship the token to mc itself.
final class MissionControlTokenStorageTests: XCTestCase {

    private let token = "mcu_SECRET-storage-token-0987654321"

    func testTheTokenIsAbsentFromUserDefaultsAndFromADefaultsExport() throws {
        let store = SharedDataStore.shared
        let saved = store.missionControlTokenStore
        defer { store.missionControlTokenStore = saved }
        var held: String?
        store.missionControlTokenStore = .init(load: { held }, save: { held = $0; return true })

        XCTAssertTrue(store.saveMissionControlToken("  \(token)\n"))
        XCTAssertEqual(held, token, "the token went to the token store")
        XCTAssertEqual(store.loadMissionControlToken(), token)
        XCTAssertNotNil(store.missionControlConfig())

        let defaults = AppEnvironment.userDefaults
        defaults.synchronize()
        let flat = defaults.dictionaryRepresentation().map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        XCTAssertFalse(flat.contains(token))
        XCTAssertFalse(flat.contains("SECRET"))

        // What mc's usage_push actually runs, against the domain the store writes.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["export", AppEnvironment.testDefaultsSuiteName, "-"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let exported = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(exported.contains(token), "token in defaults export")
        XCTAssertFalse(exported.contains("SECRET"))
    }

    func testAKeychainRefusalStoresTheTokenNowhereAndLeavesTheFeatureOff() {
        let store = SharedDataStore.shared
        let saved = store.missionControlTokenStore
        defer { store.missionControlTokenStore = saved }
        store.missionControlTokenStore = .init(load: { nil }, save: { _ in false })
        XCTAssertFalse(store.saveMissionControlToken(token))
        XCTAssertEqual(store.loadMissionControlToken(), "")
        XCTAssertNil(store.missionControlConfig())
        XCTAssertFalse(AppEnvironment.userDefaults.dictionaryRepresentation().values.contains { "\($0)".contains(token) })
    }

    func testALegacyDefaultsCopyIsDeletedOnLoad() {
        let store = SharedDataStore.shared
        let saved = store.missionControlTokenStore
        defer { store.missionControlTokenStore = saved }
        store.missionControlTokenStore = .init(load: { nil }, save: { _ in true })
        AppEnvironment.userDefaults.set(token, forKey: "missionControlToken")
        _ = store.loadMissionControlToken()
        XCTAssertNil(AppEnvironment.userDefaults.object(forKey: "missionControlToken"))
    }

    func testClearingTheTokenTurnsTheFeatureOff() {
        let store = SharedDataStore.shared
        let saved = store.missionControlTokenStore
        defer { store.missionControlTokenStore = saved }
        var held: String?
        store.missionControlTokenStore = .init(load: { held }, save: { held = $0; return true })
        store.saveMissionControlToken(token)
        store.saveMissionControlToken("")
        XCTAssertNil(held)
        XCTAssertNil(store.missionControlConfig())
    }

    func testTheKeychainItemIsTheAppsOwnNeverAClaudeCodeEntry() {
        XCTAssertEqual(KeychainService.missionControlTokenService, "com.claudeusagetracker.mission-control-token")
        XCTAssertFalse(KeychainService.missionControlTokenService.hasPrefix("Claude Code-credentials"))
    }
}
