import XCTest
@testable import Claude_Usage

/// End-to-end rotation harness over the pure policy: each scenario drives the
/// decider, the swap policy and the status line the way one refresh tick does,
/// and asserts (1) the switch that happens, (2) that no step would log an
/// account out (no write over an unknown keychain login, no refresh of a
/// lineage a session may still hold, no dead target), (3) that the status line
/// names the same target. The three 2026-10-12 failures are replayed as
/// fixtures. Live proof is the next real limit on the installed build; see the
/// install plan.
@MainActor
final class RotationScenarioTests: XCTestCase {

    private let now = Date()
    private let et = TimeZone(identifier: "America/New_York")!
    private func fmt(_ d: Date) -> String { AutoSwitchStatus.americanTime(d, now: now, timeZone: et) }

    /// One tick: decision + status line + the swap policy's verdict for the
    /// keychain state, so a scenario asserts all three from one call.
    private struct Tick {
        let decision: AutoSwitchDecider.Decision
        let status: AutoSwitchStatus
        let nextLine: String
    }

    private func tick(_ decider: inout AutoSwitchDecider, active: Profile, profiles: [Profile], usingFable: Bool = false,
                      isLoginDead: @escaping (Profile) -> Bool = { _ in false }) -> Tick {
        let decision = decider.decide(current: active, profiles: profiles, usingFable: usingFable, now: now, isLoginDead: isLoginDead)
        let status = AutoSwitchStatus.build(profiles: profiles, activeId: active.id, usingFable: usingFable, now: now, isLoginDead: isLoginDead)
        return Tick(decision: decision, status: status, nextLine: status.nextLine(timeFormatter: fmt))
    }

    /// The "no logout" invariants every decided switch must satisfy.
    private func assertSafeSwitch(to target: Profile, isLoginDead: (Profile) -> Bool = { _ in false },
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(isLoginDead(target), "never into a dead login", file: file, line: line)
        XCTAssertTrue(AutoSwitchPolicy.canBeApplied(target), "never into a login that cannot be applied", file: file, line: line)
        // The compare-and-swap never writes over a login the tracker did not capture.
        XCTAssertEqual(MainLoginSwapPolicy.refusal(holders: 0, keychainFingerprint: "someone-elses", knownFingerprints: ["known"]),
                       .unknownKeychainLogin, file: file, line: line)
        // An auto switch whose login could not be applied moves nothing.
        XCTAssertFalse(AutoSwitchPolicy.activateAfterMainLoginSwitch(.failure(ClaudeCodeError.noProfileCredentials), selectedBy: "auto"),
                       file: file, line: line)
    }

    // MARK: - A. active at 95% then 100%, another account free

    func testA_NearLimitHandsOffAndAtTheLimitSwitches() {
        var decider = AutoSwitchDecider()
        let spare = profile("littlewing", session: 10, weekly: 5)
        var active = profile("madmatter", session: 95, weekly: 40)

        let t1 = tick(&decider, active: active, profiles: [active, spare])
        XCTAssertEqual(t1.decision, .handOff(spare))
        XCTAssertEqual(t1.nextLine, "next: littlewing (ready)")
        assertSafeSwitch(to: spare)
        // The hand-off writes under working holders, with the reload signal; nothing else blocks.
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 3, keychainFingerprint: "mad", knownFingerprints: ["mad"], keychainLoginNearLimit: true))
        // ... and the replaced lineage is not refreshable until the holders release it.
        let record = MainLoginSwapPolicy.HandoffRecord(fingerprint: "mad", holderPids: [1, 2, 3], at: now)
        XCTAssertFalse(MainLoginSwapPolicy.lineageReleased(record, now: now, process: { _ in .running(startedAt: nil) }, requestedAfter: { _, _ in false }))
        XCTAssertTrue(MainLoginSwapPolicy.lineageReleased(record, now: now, process: { _ in .running(startedAt: nil) }, requestedAfter: { _, _ in true }))

        // Had the hand-off been refused (proactive off), 100% still switches.
        var strict = AutoSwitchDecider(proactive: false)
        XCTAssertEqual(strict.decide(current: active, profiles: [active, spare], usingFable: false, now: now), .stay)
        active.claudeUsage = usage(session: 100, weekly: 40)
        let t2 = tick(&strict, active: active, profiles: [active, spare])
        XCTAssertEqual(t2.decision, .switchTo(spare, withoutFable: false))
        XCTAssertEqual(t2.nextLine, "next: littlewing (ready)")
        XCTAssertNil(MainLoginSwapPolicy.refusal(holders: 3, keychainFingerprint: "mad", knownFingerprints: ["mad"], keychainLoginSpent: true))
    }

    // MARK: - B. everything spent

    func testB_AllSpentStaysAndNamesWhoFreesFirst() {
        var decider = AutoSwitchDecider()
        let active = profile("madmatter", session: 100, weekly: 40)
        let b = profile("mattgg", session: 100, weekly: 20, sessionResetIn: 2 * 3600)
        let c = profile("littlewing", session: 0, weekly: 100, weeklyResetIn: 3 * 86400)
        let t = tick(&decider, active: active, profiles: [active, b, c])
        XCTAssertEqual(t.decision, .noTarget(notify: true))
        XCTAssertTrue(t.status.stuck)
        XCTAssertEqual(t.nextLine, "next: mattgg · \(fmt(b.claudeUsage!.sessionResetTime))")
        // Said once; searched again every tick.
        XCTAssertEqual(decider.decide(current: active, profiles: [active, b, c], usingFable: false, now: now), .noTarget(notify: false))
        // mattgg's window resets: picked up on the next tick.
        var freed = b; freed.claudeUsage = usage(session: 0, weekly: 20)
        XCTAssertEqual(decider.decide(current: active, profiles: [active, freed, c], usingFable: false, now: now), .switchTo(freed, withoutFable: false))
    }

    // MARK: - C. Fable exhausted (operator: Fable on any account that has it, else Opus)

    func testC_FableOnlyExhaustion() {
        var decider = AutoSwitchDecider()
        let active = profile("madmatter", session: 20, weekly: 20, fable: 100)
        let noFable = profile("mattgg", session: 10, weekly: 10, fable: 100)
        let t1 = tick(&decider, active: active, profiles: [active, noFable], usingFable: true)
        XCTAssertEqual(t1.decision, .noFableHeadroom(notify: true), "only Fable is spent everywhere: stay, Opus fallback")
        XCTAssertEqual(t1.nextLine, "next (Fable): none · opus stays on madmatter")

        let withFable = profile("littlewing", session: 10, weekly: 10, fable: 10)
        var decider2 = AutoSwitchDecider()
        let t2 = tick(&decider2, active: active, profiles: [active, noFable, withFable], usingFable: true)
        XCTAssertEqual(t2.decision, .switchTo(withFable, withoutFable: false), "an account WITH Fable headroom is preferred")
        XCTAssertEqual(t2.nextLine, "next (Fable): littlewing (ready)")
        assertSafeSwitch(to: withFable)
        // Fable near its limit hands off to the account with Fable room, not to the one without.
        var decider3 = AutoSwitchDecider()
        let nearFable = profile("madmatter", session: 20, weekly: 20, fable: 92)
        XCTAssertEqual(decider3.decide(current: nearFable, profiles: [nearFable, noFable, withFable], usingFable: true, now: now), .handOff(withFable))
        // Not using Fable: the Fable window does not bind at all.
        var decider4 = AutoSwitchDecider()
        XCTAssertEqual(decider4.decide(current: nearFable, profiles: [nearFable, noFable, withFable], usingFable: false, now: now), .stay)
    }

    // MARK: - D. stale readings

    func testD_StaleReadingWithItsLimitStillInForceIsNotATarget() {
        var decider = AutoSwitchDecider()
        let active = profile("madmatter", session: 100, weekly: 40)
        let stale = profile("littlewing", session: 0, weekly: 100, weeklyResetIn: 3 * 86400, age: 7 * 3600)
        let t = tick(&decider, active: active, profiles: [active, stale])
        XCTAssertEqual(t.decision, .noTarget(notify: true))
        XCTAssertEqual(t.nextLine, "next: littlewing · \(fmt(stale.claudeUsage!.weeklyResetTime))")
    }

    func testD_StaleReadingWhoseWindowPassedIsPresumedFree_Replay2359() {
        // 2026-10-11 23:52: madmatter spent; mattgg last read 19:30 at 100% session, window ended 19:29:59, weekly 44%.
        var decider = AutoSwitchDecider()
        let active = profile("madmatter", session: 100, weekly: 40)
        let mattgg = profile("mattgg", session: 100, weekly: 44, sessionResetIn: -4 * 3600, age: 4 * 3600 + 20 * 60)
        let others = [profile("goose", session: 0, weekly: 100, weeklyResetIn: 86400, age: 20 * 3600),
                      profile("grasmash", session: 0, weekly: 100, weeklyResetIn: 86400, age: 20 * 3600)]
        let t = tick(&decider, active: active, profiles: [active] + others + [mattgg])
        XCTAssertEqual(t.decision, .switchTo(mattgg, withoutFable: false))
        XCTAssertEqual(t.nextLine, "next: mattgg? (ready)", "presumed, marked, and the same account the policy picked")
        XCTAssertFalse(t.status.stuck)
        assertSafeSwitch(to: mattgg)
    }

    func testD_HandoffNeverTargetsAPresumedAccount() {
        var decider = AutoSwitchDecider()
        let active = profile("madmatter", session: 93, weekly: 40)
        let presumed = profile("mattgg", session: 100, weekly: 44, sessionResetIn: -4 * 3600, age: 4 * 3600)
        let t = tick(&decider, active: active, profiles: [active, presumed])
        XCTAssertEqual(t.decision, .stay)
        XCTAssertEqual(t.nextLine, "next: mattgg? (ready)", "at 100% it would be the (presumed) target; the hand-off waits for evidence")
    }

    // MARK: - E. dead login

    func testE_DeadLoginIsNeverTheTarget() {
        var decider = AutoSwitchDecider()
        let active = profile("madmatter", session: 100, weekly: 40)
        let dead = profile("goose", session: 0, weekly: 0)
        let isDead: (Profile) -> Bool = { $0.id == dead.id }
        let t = tick(&decider, active: active, profiles: [active, dead], isLoginDead: isDead)
        XCTAssertEqual(t.decision, .noTarget(notify: true))
        XCTAssertEqual(t.nextLine, "next: none")
        XCTAssertEqual(t.status.signInNeeded, ["goose"])
        // A target whose stored login turns out dead at apply time: the tracker stays put.
        XCTAssertFalse(AutoSwitchPolicy.activateAfterMainLoginSwitch(.failure(ClaudeCodeError.noProfileCredentials), selectedBy: "auto"))
    }

    // MARK: - F. replay: midday 2026-10-12 — littlewing really free, app's stale reading said 100% weekly

    func testF_MissionControlProvenReadingUnblocksAStaleAccount() {
        let stale = profileWithEmail("littlewing", session: 0, weekly: 100, weeklyResetIn: 3 * 86400, age: 7 * 3600)
        let active = profile("madmatter", session: 100, weekly: 40)
        let rotate = [McUsage.RotateAccount(name: "littlewing", email: "littlewing@x.com", dir: nil)]
        let mcBody = Data(#"""
        {"accounts":[{"name":"littlewing","proven":true,"source":"usage-self","host":"littlewing",
          "usage":{"sampled_at":"\#(iso(now.addingTimeInterval(-60)))","paused":false,
                   "session":{"used_pct":10,"resets_at":null},"weekly":{"used_pct":3,"resets_at":null},
                   "fable":{"used_pct":0,"resets_at":null}}}]}
        """#.utf8)
        let readings = McUsage.parseAccountUsage(mcBody) ?? []
        XCTAssertEqual(readings.count, 1)
        let updates = McUsage.overlay(profiles: [active, stale], activeProfileId: active.id, readings: readings, rotate: rotate, now: now)
        XCTAssertEqual(updates.map(\.profileId), [stale.id])

        var littlewing = stale
        littlewing.claudeUsage = updates[0].usage
        var decider = AutoSwitchDecider()
        let t = tick(&decider, active: active, profiles: [active, littlewing])
        XCTAssertEqual(t.decision, .switchTo(littlewing, withoutFable: false))
        XCTAssertEqual(t.nextLine, "next: littlewing (ready)")
        assertSafeSwitch(to: littlewing)
    }

    func testF_AnUnprovenMissionControlRowChangesNothing() {
        // The same row relayed by the laptop under the littlewing LABEL (madmatter's numbers, 05:44Z-16:16Z).
        let mcBody = Data(#"""
        {"accounts":[{"name":"littlewing","proven":false,"source":"laptop-tracker","host":"laptop",
          "usage":{"sampled_at":"\#(iso(now.addingTimeInterval(-60)))","paused":false,
                   "session":{"used_pct":67,"resets_at":null},"weekly":{"used_pct":100,"resets_at":null},"fable":null}}]}
        """#.utf8)
        XCTAssertEqual(McUsage.parseAccountUsage(mcBody) ?? [], [])
    }

    // MARK: - G. replay: 02:57 — another account's shared login never produces this profile's reading

    func testG_SharedLoginOfAnotherAccountYieldsNoUsageToken() async {
        let sync = ClaudeCodeSyncService.shared
        let saved = sync.fetchLoginAccountUuid
        defer { sync.fetchLoginAccountUuid = saved }
        let tag = UUID().uuidString.prefix(6)
        let expiry = Int((Date().timeIntervalSince1970 + 3600) * 1000)
        let madmatterLogin = #"{"claudeAiOauth":{"accessToken":"a-\#(tag)","refreshToken":"r-\#(tag)","expiresAt":\#(expiry)}}"#
        sync.fetchLoginAccountUuid = { _ in "u-madmatter" }
        await sync.resolveLoginAccount(credentials: madmatterLogin)
        var littlewing = profile("littlewing", session: 3, weekly: 3)
        littlewing.oauthAccountJSON = #"{"accountUuid":"u-littlewing","emailAddress":"littlewing@x.com"}"#
        XCTAssertNil(sync.usageAccessToken(fromSharedLogin: madmatterLogin, for: littlewing))
    }

    // MARK: - H. replay: 2026-10-12 2:49 PM to 5:10 PM — everything spent, the status line says who is next and when

    /// App log: 2:49:45 PM littlewing hit its session limit, switched to matt.
    /// 2:56 PM to 5:10 PM "All profiles at session/weekly limit or
    /// unavailable". 5:10:18 PM "matt hit weekly limit, switching to
    /// littlewing": the switch landed the moment littlewing's window reset.
    /// For those two hours nothing told the operator "next: littlewing at
    /// 5:10 PM". A spent window's reset time is a recorded fact, however old
    /// the reading, and it is where the switcher goes: NEXT names it.
    func testH_EverythingSpentNamesTheEarliestResetUntilTheSwitchLands() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = et
        func at(_ hour: Int, _ minute: Int, _ second: Int = 0, day: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
        }
        func reading(session: Double, sessionReset: Date, weekly: Double, weeklyReset: Date, read: Date) -> ClaudeUsage {
            var u = usage(session: session, weekly: weekly)
            u.sessionResetTime = sessionReset
            u.weeklyResetTime = weeklyReset
            u.fableWeeklyResetTime = weeklyReset
            u.lastUpdated = read
            return u
        }
        // littlewing: session spent at 2:49:45 PM, resets 5:10 PM; never read again (it is not active).
        var littlewing = profile("littlewing", session: 0, weekly: 0)
        littlewing.claudeUsage = reading(session: 100, sessionReset: at(17, 10), weekly: 60, weeklyReset: at(15, 0, day: 17), read: at(14, 49, 45))
        // goose: weekly spent until Saturday, read by mission control a minute ago at every tick.
        var goose = profile("goose", session: 0, weekly: 0)
        var decider = AutoSwitchDecider()

        var matt = profile("matt", session: 0, weekly: 0)
        for (tick, expectNotify) in [(at(14, 56), true), (at(15, 30), false), (at(17, 9, 30), false)] {
            matt.claudeUsage = reading(session: 20, sessionReset: tick.addingTimeInterval(3600), weekly: 100, weeklyReset: at(14, 59, day: 17), read: tick)
            goose.claudeUsage = reading(session: 0, sessionReset: tick.addingTimeInterval(3600), weekly: 100, weeklyReset: at(14, 0, day: 17), read: tick.addingTimeInterval(-60))
            let profiles = [littlewing, matt, goose]

            XCTAssertEqual(decider.decide(current: matt, profiles: profiles, usingFable: false, now: tick), .noTarget(notify: expectNotify))
            let status = AutoSwitchStatus.build(profiles: profiles, activeId: matt.id, now: tick)
            let time: (Date) -> String = { AutoSwitchStatus.americanTime($0, now: tick, timeZone: self.et) }
            XCTAssertTrue(status.stuck)
            XCTAssertEqual(status.nextLine(timeFormatter: time), "next: littlewing · 5:10 PM",
                           "at \(time(tick)): the earliest reset is named, fresh reading or not")
            let state = status.stateFileContents(timeFormatter: time)
            for expected in ["STUCK=1", "NEXT=next: littlewing · 5:10 PM", "NEXT_KIND=limited", "NEXT_NAME=littlewing", "NEXT_AT=5:10 PM"] {
                XCTAssertTrue(state.split(separator: "\n").contains(Substring(expected)), "\(expected) missing at \(time(tick)):\n\(state)")
            }
        }

        // 5:10:18 PM: littlewing's window has reset; the switch lands there.
        let landed = at(17, 10, 18)
        matt.claudeUsage = reading(session: 20, sessionReset: landed.addingTimeInterval(3600), weekly: 100, weeklyReset: at(14, 59, day: 17), read: landed)
        goose.claudeUsage = reading(session: 0, sessionReset: landed.addingTimeInterval(3600), weekly: 100, weeklyReset: at(14, 0, day: 17), read: landed.addingTimeInterval(-60))
        XCTAssertEqual(decider.decide(current: matt, profiles: [littlewing, matt, goose], usingFable: false, now: landed),
                       .switchTo(littlewing, withoutFable: false))
        let status = AutoSwitchStatus.build(profiles: [littlewing, matt, goose], activeId: matt.id, now: landed)
        XCTAssertEqual(status.nextLine { _ in "" }, "next: littlewing? (ready)")
    }

    // MARK: - Fixtures

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d)
    }

    private func usage(session: Double, weekly: Double, fable: Double = 0,
                       sessionResetIn: TimeInterval = 3600, weeklyResetIn: TimeInterval = 86400, age: TimeInterval = 0) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: 0, sessionLimit: 100000, sessionPercentage: session,
            sessionResetTime: now.addingTimeInterval(sessionResetIn),
            weeklyTokensUsed: 0, weeklyLimit: 1000000, weeklyPercentage: weekly,
            weeklyResetTime: now.addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0, designWeeklyPercentage: 0, designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0, fableWeeklyPercentage: fable, fableWeeklyResetTime: now.addingTimeInterval(weeklyResetIn),
            costUsed: nil, costLimit: nil, costCurrency: nil,
            lastUpdated: now.addingTimeInterval(-age), userTimezone: .current
        )
    }

    private func profile(_ name: String, session: Double, weekly: Double, fable: Double = 0,
                         sessionResetIn: TimeInterval = 3600, weeklyResetIn: TimeInterval = 86400, age: TimeInterval = 0) -> Profile {
        Profile(name: "\(name)@x.com",
                cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"t-\#(name)","refreshToken":"r-\#(name)"}}"#,
                claudeUsage: usage(session: session, weekly: weekly, fable: fable,
                                   sessionResetIn: sessionResetIn, weeklyResetIn: weeklyResetIn, age: age))
    }

    private func profileWithEmail(_ name: String, session: Double, weekly: Double,
                                  weeklyResetIn: TimeInterval = 86400, age: TimeInterval = 0) -> Profile {
        var p = profile(name, session: session, weekly: weekly, weeklyResetIn: weeklyResetIn, age: age)
        p.oauthAccountJSON = #"{"accountUuid":"u-\#(name)","emailAddress":"\#(name)@x.com"}"#
        return p
    }
}
