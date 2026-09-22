import XCTest
@testable import Claude_Usage

final class AutoSwitchPolicyTests: XCTestCase {

    // MARK: - ClaudeUsage limit helpers

    func testEffectiveWeeklyPercentageReturnsRawWhenWindowActive() {
        let usage = makeUsage(session: 10, weekly: 100, weeklyResetIn: 3600)
        XCTAssertEqual(usage.effectiveWeeklyPercentage, 100)
    }

    func testEffectiveWeeklyPercentageReturnsZeroWhenWindowExpired() {
        let usage = makeUsage(session: 10, weekly: 100, weeklyResetIn: -60)
        XCTAssertEqual(usage.effectiveWeeklyPercentage, 0)
    }

    func testIsLimitReachedWhenSessionExhausted() {
        XCTAssertTrue(makeUsage(session: 100, weekly: 20).isLimitReached)
    }

    func testIsLimitReachedWhenWeeklyExhausted() {
        XCTAssertTrue(makeUsage(session: 0, weekly: 100).isLimitReached)
    }

    func testIsLimitNotReachedWhenBothBelow100() {
        XCTAssertFalse(makeUsage(session: 99, weekly: 99).isLimitReached)
    }

    func testIsStaleWhenOlderThanThreshold() {
        let now = Date()
        let old = makeUsage(session: 0, weekly: 0, updatedAt: now.addingTimeInterval(-(Constants.usageStaleAfter + 1)))
        XCTAssertTrue(old.isStale(now: now))
    }

    func testIsNotStaleWithinThreshold() {
        let now = Date()
        let recent = makeUsage(session: 0, weekly: 0, updatedAt: now.addingTimeInterval(-(Constants.usageStaleAfter - 1)))
        XCTAssertFalse(recent.isStale(now: now))
    }

    func testAgeDescriptionFormats() {
        let now = Date()
        XCTAssertEqual(MenuBarManager.ageDescription(since: now.addingTimeInterval(-90), now: now), "1m")
        XCTAssertEqual(MenuBarManager.ageDescription(since: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(MenuBarManager.ageDescription(since: now.addingTimeInterval(-(86400 + 3 * 3600)), now: now), "1d 3h")
    }

    func testIsLimitNotReachedWhenExhaustedWindowsExpired() {
        let usage = makeUsage(session: 100, weekly: 100, sessionResetIn: -60, weeklyResetIn: -60)
        XCTAssertFalse(usage.isLimitReached)
    }

    // MARK: - Next profile selection

    func testSkipsProfilesWithWeeklyLimitReached() {
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 50))
        let weeklyDead = makeProfile("b", usage: makeUsage(session: 0, weekly: 100))
        let healthy = makeProfile("c", usage: makeUsage(session: 0, weekly: 68))

        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, weeklyDead, healthy], after: current)
        XCTAssertEqual(next?.id, healthy.id)
    }

    func testSkipsProfilesWithSessionLimitReached() {
        let current = makeProfile("a", usage: makeUsage(session: 0, weekly: 100))
        let sessionDead = makeProfile("b", usage: makeUsage(session: 100, weekly: 10))
        let healthy = makeProfile("c", usage: makeUsage(session: 40, weekly: 40))

        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, sessionDead, healthy], after: current)
        XCTAssertEqual(next?.id, healthy.id)
    }

    func testWrapsAroundToEarlierProfiles() {
        let healthy = makeProfile("a", usage: makeUsage(session: 0, weekly: 0))
        let dead = makeProfile("b", usage: makeUsage(session: 0, weekly: 100))
        let current = makeProfile("c", usage: makeUsage(session: 100, weekly: 100))

        let next = AutoSwitchPolicy.nextAvailableProfile(in: [healthy, dead, current], after: current)
        XCTAssertEqual(next?.id, healthy.id)
    }

    func testReturnsNilWhenEveryOtherProfileExhausted() {
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10))
        let b = makeProfile("b", usage: makeUsage(session: 0, weekly: 100))
        let c = makeProfile("c", usage: makeUsage(session: 100, weekly: 0))

        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [current, b, c], after: current))
    }

    func testProfileWithoutUsageDataIsSkipped() {
        // Never observed by the tracker: no evidence it has capacity, and its
        // credentials may be dead. Do not hand Claude Code an unknown account.
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10))
        let unknown = makeProfile("b", usage: nil)
        let healthy = makeProfile("c", usage: makeUsage(session: 0, weekly: 0))

        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, unknown, healthy], after: current)
        XCTAssertEqual(next?.id, healthy.id)
    }

    func testProfileWithStaleUsageIsSkipped() {
        // Regression: a profile whose refresh has been failing keeps a stale
        // snapshot whose reset windows have passed, so its effective usage reads
        // 0% and it looks like the best target. It must be skipped.
        let now = Date()
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10, updatedAt: now))
        let stale = makeProfile("b", usage: makeUsage(
            session: 100, weekly: 100,
            sessionResetIn: -3 * 86400, weeklyResetIn: -2 * 86400,   // windows long expired
            updatedAt: now.addingTimeInterval(-3 * 86400)             // last seen 3 days ago
        ))
        let healthy = makeProfile("c", usage: makeUsage(session: 0, weekly: 0, updatedAt: now))

        XCTAssertFalse(stale.claudeUsage!.isLimitReached, "precondition: stale data looks available")
        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, stale, healthy], after: current, now: now)
        XCTAssertEqual(next?.id, healthy.id)
    }

    func testUsageJustInsideFreshnessWindowIsACandidate() {
        let now = Date()
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10, updatedAt: now))
        let recent = makeProfile("b", usage: makeUsage(
            session: 0, weekly: 0,
            updatedAt: now.addingTimeInterval(-(AutoSwitchPolicy.maxUsageAge - 1))
        ))

        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, recent], after: current, now: now)
        XCTAssertEqual(next?.id, recent.id)
    }

    func testReturnsNilWhenOnlyOtherProfileIsStale() {
        let now = Date()
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10, updatedAt: now))
        let stale = makeProfile("b", usage: makeUsage(session: 0, weekly: 0, updatedAt: now.addingTimeInterval(-3600)))

        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [current, stale], after: current, now: now))
    }

    func testSkipsProfilesWithoutAnyCredentials() {
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10))
        let noCreds = Profile(name: "b", claudeUsage: makeUsage(session: 0, weekly: 0))
        let healthy = makeProfile("c", usage: makeUsage(session: 0, weekly: 0))

        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, noCreds, healthy], after: current)
        XCTAssertEqual(next?.id, healthy.id)
    }

    func testSkipsSessionKeyOnlyProfileBecauseItCannotBeApplied() {
        // Regression 2026-09-22: a profile with a claude.ai session key but no
        // CLI credentials is trackable but NOT switchable — activating it
        // leaves the keychain on the exhausted account. It must be skipped.
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10))
        let sessionKeyOnly = Profile(
            name: "b",
            claudeSessionKey: "sk-ant-test",
            organizationId: "org-test",
            claudeUsage: makeUsage(session: 0, weekly: 0)
        )
        let applicable = makeProfile("c", usage: makeUsage(session: 0, weekly: 0))

        XCTAssertTrue(sessionKeyOnly.hasAnyCredentials, "precondition: it IS trackable")
        XCTAssertFalse(AutoSwitchPolicy.canBeApplied(sessionKeyOnly))
        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, sessionKeyOnly, applicable], after: current)
        XCTAssertEqual(next?.id, applicable.id)
    }

    func testPinnedKeychainProfileCanBeApplied() {
        let pinned = Profile(name: "p", customKeychainServiceName: "Claude Code-credentials-p")
        XCTAssertTrue(AutoSwitchPolicy.canBeApplied(pinned))
    }

    func testReturnsNilWhenOnlyOtherProfileIsSessionKeyOnly() {
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10))
        let sessionKeyOnly = Profile(
            name: "b",
            claudeSessionKey: "sk-ant-test",
            organizationId: "org-test",
            claudeUsage: makeUsage(session: 0, weekly: 0)
        )
        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [current, sessionKeyOnly], after: current))
    }

    func testProfileWithExpiredCLITokenIsStillACandidate() {
        // An idle profile's CLI OAuth token is usually expired; activateProfile
        // refreshes it on switch, so it must not be filtered out here.
        let expiredMillis = Int((Date().timeIntervalSince1970 - 3600) * 1000)
        let expiredJSON = """
        {"claudeAiOauth":{"accessToken":"old","refreshToken":"r","expiresAt":\(expiredMillis)}}
        """
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10))
        let expiredCLI = Profile(name: "b", cliCredentialsJSON: expiredJSON, claudeUsage: makeUsage(session: 0, weekly: 68))

        XCTAssertFalse(expiredCLI.hasUsageCredentials, "precondition: token is expired")
        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, expiredCLI], after: current)
        XCTAssertEqual(next?.id, expiredCLI.id)
    }

    func testReturnsNilWhenCurrentNotInList() {
        let current = makeProfile("a", usage: nil)
        let other = makeProfile("b", usage: nil)
        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [other], after: current))
    }

    // MARK: - Helpers

    /// A profile that is a valid switch target: it has CLI credentials the
    /// tracker can write into the keychain.
    private func makeProfile(_ name: String, usage: ClaudeUsage?) -> Profile {
        Profile(
            name: name,
            claudeSessionKey: "sk-ant-test",
            organizationId: "org-test",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r"}}"#,
            claudeUsage: usage
        )
    }

    private func makeUsage(
        session: Double,
        weekly: Double,
        sessionResetIn: TimeInterval = 3600,
        weeklyResetIn: TimeInterval = 86400,
        updatedAt: Date = Date()
    ) -> ClaudeUsage {
        ClaudeUsage(
            sessionTokensUsed: Int(session * 1000),
            sessionLimit: 100000,
            sessionPercentage: session,
            sessionResetTime: Date().addingTimeInterval(sessionResetIn),
            weeklyTokensUsed: Int(weekly * 10000),
            weeklyLimit: 1000000,
            weeklyPercentage: weekly,
            weeklyResetTime: Date().addingTimeInterval(weeklyResetIn),
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0,
            designWeeklyPercentage: 0,
            designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0,
            fableWeeklyPercentage: 0,
            fableWeeklyResetTime: nil,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: updatedAt,
            userTimezone: .current
        )
    }
}
