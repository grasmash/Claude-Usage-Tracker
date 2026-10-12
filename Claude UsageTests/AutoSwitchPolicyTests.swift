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

    func testAFreshCandidateIsPreferredOverAStaleOne() {
        // A profile whose refresh has been failing keeps a stale snapshot whose
        // reset windows have passed, so its effective usage reads 0%. A fresh
        // reading is evidence; the stale one is a presumption, so the fresh
        // candidate wins whenever there is one.
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

    func testAStaleReadingWithHeadroomIsALastResortCandidate() {
        // The single refresher never reads a non-active login again once its
        // access token expires, so every other account's reading goes stale
        // within hours. A stale reading that reports no limit still in force is
        // the best evidence there is; the switch is verified live afterwards.
        let now = Date()
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10, updatedAt: now))
        let stale = makeProfile("b", usage: makeUsage(session: 0, weekly: 0, updatedAt: now.addingTimeInterval(-3600)))

        XCTAssertEqual(AutoSwitchPolicy.nextAvailableProfile(in: [current, stale], after: current, now: now)?.id, stale.id)
    }

    func testAStaleReadingWhoseLimitIsStillInForceIsSkipped() {
        // Spent when last seen, and the window it reported has not passed yet:
        // nothing suggests it has freed up.
        let now = Date()
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10, updatedAt: now))
        let spent = makeProfile("b", usage: makeUsage(
            session: 0, weekly: 100, weeklyResetIn: 3 * 86400, updatedAt: now.addingTimeInterval(-7 * 3600)
        ))

        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [current, spent], after: current, now: now))
    }

    func testAStaleReadingWithAPassedWindowIsPresumedResetAndTaken() {
        // Spent when last seen, but the window it reported has since passed:
        // presumed reset, and chosen when nothing fresh is free.
        let now = Date()
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10, updatedAt: now))
        let rolledOver = makeProfile("b", usage: makeUsage(
            session: 100, weekly: 40, sessionResetIn: -30 * 60, updatedAt: now.addingTimeInterval(-4 * 3600)
        ))

        XCTAssertEqual(AutoSwitchPolicy.nextAvailableProfile(in: [current, rolledOver], after: current, now: now)?.id, rolledOver.id)
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

    // A pinned profile's keychain entry belongs to another Claude Code config
    // dir. Copying that login into the main one puts a single-use refresh
    // token in two places, and whichever side refreshes second is logged out.

    func testPinnedProfileWithoutItsOwnMainLoginCannotBeApplied() {
        let pinned = Profile(
            name: "p",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r"}}"#,
            customKeychainServiceName: "Claude Code-credentials-p"
        )
        XCTAssertFalse(AutoSwitchPolicy.canBeApplied(pinned))
    }

    func testPinnedProfileWithItsOwnMainLoginCanBeApplied() {
        let pinned = Profile(
            name: "p",
            cliCredentialsJSON: #"{"claudeAiOauth":{"accessToken":"t","refreshToken":"r"}}"#,
            customKeychainServiceName: "Claude Code-credentials-p",
            hasOwnMainLogin: true
        )
        XCTAssertTrue(AutoSwitchPolicy.canBeApplied(pinned))
    }

    func testPinnedProfileWithNoStoredLoginCannotBeApplied() {
        let pinned = Profile(name: "p", customKeychainServiceName: "Claude Code-credentials-p", hasOwnMainLogin: true)
        XCTAssertFalse(AutoSwitchPolicy.canBeApplied(pinned))
    }

    // A paused account (e.g. a lapsed subscription) is never switched to and
    // its saved login is left alone until it is resumed.

    func testPausedProfileIsNotASwitchTarget() {
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 50))
        var paused = makeProfile("b", usage: makeUsage(session: 0, weekly: 0))
        paused.isPaused = true
        let healthy = makeProfile("c", usage: makeUsage(session: 0, weekly: 68))

        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, paused, healthy], after: current)
        XCTAssertEqual(next?.id, healthy.id)
    }

    // The active login belongs to Claude Code's sessions, which hold it in
    // memory and refresh it themselves. A tracker refresh of the same
    // single-use token is treated as reuse and kills the login for everyone —
    // however long it has been expired, because a session asleep through any
    // grace period wakes still holding the old token.

    func testActiveLoginIsNotRefreshedRightAtExpiry() {
        let now = Date()
        XCTAssertFalse(AutoSwitchPolicy.mayRefreshActiveLogin(expiresAt: now.addingTimeInterval(-5), now: now))
    }

    func testActiveLoginIsNotRefreshedWhileValid() {
        let now = Date()
        XCTAssertFalse(AutoSwitchPolicy.mayRefreshActiveLogin(expiresAt: now.addingTimeInterval(600), now: now))
    }

    func testActiveLoginIsNotRefreshedHoweverLongItHasBeenExpired() {
        let now = Date()
        let expiries: [TimeInterval] = [15 * 60, 3600, 86_400, 30 * 86_400]
        for expiredFor in expiries {
            XCTAssertFalse(AutoSwitchPolicy.mayRefreshActiveLogin(expiresAt: now.addingTimeInterval(-expiredFor), now: now),
                           "expired for \(expiredFor)s")
        }
    }

    func testMainLoginIsItsOwnWhenItsTokenDiffersFromThePinnedEntry() {
        XCTAssertTrue(AutoSwitchPolicy.isOwnMainLogin(mainRefreshToken: "main", pinnedRefreshToken: "pinned"))
    }

    func testMainLoginIsNotItsOwnWhenItIsACopyOfThePinnedEntry() {
        XCTAssertFalse(AutoSwitchPolicy.isOwnMainLogin(mainRefreshToken: "same", pinnedRefreshToken: "same"))
    }

    func testMainLoginWithoutARefreshTokenIsNotItsOwn() {
        XCTAssertFalse(AutoSwitchPolicy.isOwnMainLogin(mainRefreshToken: nil, pinnedRefreshToken: "pinned"))
    }

    func testMainLoginIsItsOwnWhenThePinnedEntryIsUnreadable() {
        XCTAssertTrue(AutoSwitchPolicy.isOwnMainLogin(mainRefreshToken: "main", pinnedRefreshToken: nil))
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

    func testSkipsProfilesWhoseLoginIsDead() {
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 50))
        let loggedOut = makeProfile("b", usage: makeUsage(session: 0, weekly: 0))
        let healthy = makeProfile("c", usage: makeUsage(session: 40, weekly: 40))

        let next = AutoSwitchPolicy.nextAvailableProfile(
            in: [current, loggedOut, healthy], after: current,
            isLoginDead: { $0.id == loggedOut.id }
        )
        XCTAssertEqual(next?.id, healthy.id)
    }

    func testReturnsNilWhenOnlyOtherProfileHasDeadLogin() {
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 50))
        let loggedOut = makeProfile("b", usage: makeUsage(session: 0, weekly: 0))

        let next = AutoSwitchPolicy.nextAvailableProfile(
            in: [current, loggedOut], after: current,
            isLoginDead: { $0.id == loggedOut.id }
        )
        XCTAssertNil(next)
    }

    func testReturnsNilWhenCurrentNotInList() {
        let current = makeProfile("a", usage: nil)
        let other = makeProfile("b", usage: nil)
        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [other], after: current))
    }

    // MARK: - Fable model limit

    func testFableLimitCountsOnlyWhenFableSelected() {
        let usage = makeUsage(session: 10, weekly: 40, fable: 100)
        XCTAssertFalse(usage.isLimitReached, "base limits are untouched")
        XCTAssertFalse(usage.isLimitReached(usingFable: false))
        XCTAssertTrue(usage.isLimitReached(usingFable: true))
    }

    func testFableLimitIgnoredAfterItsWindowResets() {
        let usage = makeUsage(session: 10, weekly: 40, fable: 100, fableResetIn: -60)
        XCTAssertEqual(usage.effectiveFableWeeklyPercentage, 0)
        XCTAssertFalse(usage.isLimitReached(usingFable: true))
    }

    func testFableSelectedSkipsProfilesWithFableExhausted() {
        let current = makeProfile("a", usage: makeUsage(session: 10, weekly: 40, fable: 100))
        let fableDead = makeProfile("b", usage: makeUsage(session: 0, weekly: 0, fable: 100))
        let fableOK = makeProfile("c", usage: makeUsage(session: 20, weekly: 50, fable: 30))

        let next = AutoSwitchPolicy.nextAvailableProfile(
            in: [current, fableDead, fableOK], after: current, usingFable: true)
        XCTAssertEqual(next?.id, fableOK.id)
    }

    func testFableExhaustedProfileIsFineWhenFableNotSelected() {
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 40))
        let fableDead = makeProfile("b", usage: makeUsage(session: 0, weekly: 0, fable: 100))

        let next = AutoSwitchPolicy.nextAvailableProfile(in: [current, fableDead], after: current)
        XCTAssertEqual(next?.id, fableDead.id)
    }

    func testReturnsNilWhenEveryOtherProfileHasFableExhausted() {
        let current = makeProfile("a", usage: makeUsage(session: 10, weekly: 40, fable: 100))
        let b = makeProfile("b", usage: makeUsage(session: 0, weekly: 0, fable: 100))
        XCTAssertNil(AutoSwitchPolicy.nextAvailableProfile(in: [current, b], after: current, usingFable: true))
    }

    func testIsFableModelRecognisesAliasesAndIds() {
        XCTAssertTrue(AutoSwitchPolicy.isFableModel("fable"))
        XCTAssertTrue(AutoSwitchPolicy.isFableModel("claude-fable-5-1"))
        XCTAssertTrue(AutoSwitchPolicy.isFableModel("claude-fable-5-1[1m]"))
        XCTAssertTrue(AutoSwitchPolicy.isFableModel("Mythos"))
        XCTAssertFalse(AutoSwitchPolicy.isFableModel("opus"))
        XCTAssertFalse(AutoSwitchPolicy.isFableModel("claude-opus-5-5"))
        XCTAssertFalse(AutoSwitchPolicy.isFableModel(nil))
    }

    func testSelectedModelReadFromSettingsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")

        XCTAssertNil(AutoSwitchPolicy.selectedClaudeCodeModel(settingsURL: url), "missing file")

        try #"{"model":"fable"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AutoSwitchPolicy.selectedClaudeCodeModel(settingsURL: url), "fable")

        try #"{"env":{"ANTHROPIC_MODEL":"claude-fable-5-1"}}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AutoSwitchPolicy.selectedClaudeCodeModel(settingsURL: url), "claude-fable-5-1")

        try #"{"statusLine":{}}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(AutoSwitchPolicy.selectedClaudeCodeModel(settingsURL: url), "default model")
    }

    func testFableDetectedFromActiveSessionTranscriptWithoutSettings() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let settings = root.appendingPathComponent("settings.json")
        try writeTranscript(in: projects, models: ["claude-opus-5-5", "claude-fable-5-1", "<synthetic>"])

        XCTAssertTrue(AutoSwitchPolicy.isClaudeCodeUsingFable(projectsURL: projects, settingsURL: settings),
                      "latest real reply was Fable; the synthetic rate-limit notice is skipped")
    }

    func testIdleTranscriptsAndOtherModelsDoNotCountAsFable() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("projects")
        let settings = root.appendingPathComponent("settings.json")
        try writeTranscript(in: projects, models: ["claude-opus-5-5"])
        let old = try writeTranscript(in: projects, models: ["claude-fable-5-1"])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * AutoSwitchPolicy.activeSessionWindow)],
            ofItemAtPath: old.path
        )

        XCTAssertFalse(AutoSwitchPolicy.isClaudeCodeUsingFable(projectsURL: projects, settingsURL: settings))

        try #"{"model":"fable"}"#.write(to: settings, atomically: true, encoding: .utf8)
        XCTAssertTrue(AutoSwitchPolicy.isClaudeCodeUsingFable(projectsURL: projects, settingsURL: settings),
                      "settings file is the fallback")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes a session transcript whose assistant replies came from `models`, in order.
    @discardableResult
    private func writeTranscript(in projects: URL, models: [String]) throws -> URL {
        let project = projects.appendingPathComponent("-Users-me-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let lines = models.flatMap { model in [
            #"{"type":"user","message":{"role":"user","content":"hi"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","model":"\#(model)","content":[]}}"#,
        ] }
        let url = project.appendingPathComponent("\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A profile that is a valid switch target: it has CLI credentials the
    /// tracker can write into the keychain.
    // MARK: - Fable in use: target choice and last resort (operator, 2026-10-11)

    func testWhenFableIsInUseAProfileWithFableHeadroomIsPreferred() {
        let current = makeProfile("A", usage: makeUsage(session: 10, weekly: 100))
        let noFable = makeProfile("B", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        let fableLeft = makeProfile("C", usage: makeUsage(session: 10, weekly: 10, fable: 20))

        let target = AutoSwitchPolicy.switchTarget(
            in: [current, noFable, fableLeft], after: current, usingFable: true, blockedBeyondFable: true)

        XCTAssertEqual(target, .profile(fableLeft))
    }

    func testWhenNoProfileHasFableHeadroomASessionOrWeeklyBlockStillMovesToOneWithout() {
        let current = makeProfile("A", usage: makeUsage(session: 10, weekly: 100))
        let noFable = makeProfile("B", usage: makeUsage(session: 10, weekly: 10, fable: 100))

        let target = AutoSwitchPolicy.switchTarget(
            in: [current, noFable], after: current, usingFable: true, blockedBeyondFable: true)

        XCTAssertEqual(target, .profileWithoutFable(noFable), "the sessions can run Opus there; on A they can run nothing")
    }

    func testAFableOnlyBlockDoesNotMoveToAnAccountWithoutFableHeadroom() {
        let current = makeProfile("A", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        let noFable = makeProfile("B", usage: makeUsage(session: 10, weekly: 10, fable: 100))

        let target = AutoSwitchPolicy.switchTarget(
            in: [current, noFable], after: current, usingFable: true, blockedBeyondFable: false)

        XCTAssertEqual(target, .noFableHeadroom, "moving gains nothing: Opus runs on A as well as on B")
    }

    func testWithoutFableTheTargetIsTheNextProfileUnderSessionAndWeekly() {
        let current = makeProfile("A", usage: makeUsage(session: 100, weekly: 10))
        let b = makeProfile("B", usage: makeUsage(session: 10, weekly: 10, fable: 100))

        XCTAssertEqual(AutoSwitchPolicy.switchTarget(in: [current, b], after: current, usingFable: false, blockedBeyondFable: true), .profile(b))
        XCTAssertEqual(AutoSwitchPolicy.switchTarget(in: [current], after: current, usingFable: false, blockedBeyondFable: true), .none)
    }

    func testFableHeadroomIsAnApplicableFreshAccountUnderAllThreeLimits() {
        let spent = makeProfile("A", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        let weeklyGone = makeProfile("B", usage: makeUsage(session: 10, weekly: 100, fable: 10))
        let stale = makeProfile("C", usage: makeUsage(session: 10, weekly: 10, fable: 10, updatedAt: Date().addingTimeInterval(-3600)))
        let ok = makeProfile("D", usage: makeUsage(session: 10, weekly: 10, fable: 10))
        let rolled = makeProfile("E", usage: makeUsage(session: 10, weekly: 10, fable: 100, fableResetIn: -60))

        XCTAssertFalse(AutoSwitchPolicy.anyProfileHasFableHeadroom([spent, weeklyGone, stale]))
        XCTAssertTrue(AutoSwitchPolicy.anyProfileHasFableHeadroom([spent, ok]))
        XCTAssertTrue(AutoSwitchPolicy.anyProfileHasFableHeadroom([rolled]), "a Fable window that reset is headroom again")
        XCTAssertFalse(AutoSwitchPolicy.anyProfileHasFableHeadroom([ok], isLoginDead: { _ in true }))
    }

    // MARK: - Ending the Opus fallback: restore only on an account with Fable headroom

    func testRestoreWhenTheActiveAccountHasFableHeadroom() {
        let active = makeProfile("A", usage: makeUsage(session: 10, weekly: 10, fable: 10))
        let other = makeProfile("B", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        XCTAssertEqual(AutoSwitchPolicy.fableRestoreAction(profiles: [active, other], activeId: active.id), .restore)
    }

    func testSwitchFirstWhenOnlyAnotherAccountHasFableHeadroom() {
        // Restoring here would put Claude Code back on Fable while the shared
        // login still sits on a Fable-spent account.
        let active = makeProfile("A", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        let other = makeProfile("B", usage: makeUsage(session: 10, weekly: 10, fable: 10))
        XCTAssertEqual(AutoSwitchPolicy.fableRestoreAction(profiles: [active, other], activeId: active.id), .switchFirst)
    }

    func testWaitWhenNoAccountHasFableHeadroom() {
        let active = makeProfile("A", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        let other = makeProfile("B", usage: makeUsage(session: 10, weekly: 100, fable: 10))
        XCTAssertEqual(AutoSwitchPolicy.fableRestoreAction(profiles: [active, other], activeId: active.id), .wait(.noHeadroom))
        XCTAssertEqual(AutoSwitchPolicy.fableRestoreAction(profiles: [active], activeId: nil), .wait(.activeUnverifiable))
    }

    func testTheMostRecentlyObservedStaleCandidateIsPreferred() {
        let now = Date()
        let current = makeProfile("a", usage: makeUsage(session: 100, weekly: 10, updatedAt: now))
        let older = makeProfile("b", usage: makeUsage(session: 0, weekly: 0, updatedAt: now.addingTimeInterval(-6 * 3600)))
        let newer = makeProfile("c", usage: makeUsage(session: 0, weekly: 0, updatedAt: now.addingTimeInterval(-1 * 3600)))

        XCTAssertEqual(AutoSwitchPolicy.nextAvailableProfile(in: [current, older, newer], after: current, now: now)?.id, newer.id)
    }

    // MARK: - Probe D (gate on 2070d8b): an automatic switch INTO a login that cannot be applied
    //
    // With tracker-active = B and the keychain still = spent A, isLoginDead(B)
    // judged by A's unproven keychain login (false), B's stale "free" reading
    // read .stay, adoption never fired, and switchLanded announced a switch
    // that had not happened. The tracker must stay on A so the decider re-arms.

    func testAnAutomaticSwitchWhoseLoginWasRejectedDoesNotActivate() {
        struct RefreshRejected: Error {}
        XCTAssertFalse(AutoSwitchPolicy.activateAfterMainLoginSwitch(.failure(RefreshRejected()), selectedBy: "auto"))
        XCTAssertFalse(AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(.refused(.untrustedStoredLogin(.unknownProvenance))), selectedBy: "auto"))
        XCTAssertFalse(AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(.refused(.notTheSharedLoginEntry(service: "Claude Code-credentials-x"))), selectedBy: "auto"))
    }

    func testAnAutomaticSwitchActivatesWhenTheLoginWasWrittenOrTheRefusalIsRetried() {
        for outcome: ClaudeCodeSyncService.MainLoginSwitch in [
            .applied(racedHolders: 0), .alreadyApplied,
            .refused(.sessionsRunning(count: 3)), .refused(.unknownKeychainLogin),
            .refused(.processListUnavailable), .refused(.keychainUnreadable),
        ] {
            XCTAssertTrue(AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(outcome), selectedBy: "auto"), "\(outcome)")
        }
    }

    func testAUserSwitchAlwaysActivates() {
        struct RefreshRejected: Error {}
        XCTAssertTrue(AutoSwitchPolicy.activateAfterMainLoginSwitch(.failure(RefreshRejected()), selectedBy: "user"))
        XCTAssertTrue(AutoSwitchPolicy.activateAfterMainLoginSwitch(.success(.refused(.untrustedStoredLogin(.copyOfPinnedEntry))), selectedBy: "user"))
    }

    // MARK: - Replay 2026-10-11 11:52 PM: a freed account with a stale reading
    //
    // madmatter23 hit its 5-hour limit at 11:52 PM (window to 12:40 AM). The
    // status line read "⚠ no account free · next: matt 11:51PM" (matt =
    // matt@guitargate.com, and 11:51 was the current tick: its freeAt was NOW)
    // and nothing switched; the operator ran /login by hand. The tracker's
    // readings at that tick, from profiles-backup.json and the usageHistory
    // files: madmatter fresh at 100% session; grasmash, littlewing,
    // matt.grasmick and goose stale since 16:50 / 11:45 with weekly 100% and
    // resets days away (truly spent); matt@guitargate.com stale since ~19:30 —
    // 100% session with a window that ended 19:29:59, weekly 44%, Fable 38% —
    // free for four hours and skipped only because its reading was older than
    // maxUsageAge (the single refresher never read its expired login again).

    func testReplay20261011_aFreedAccountWithAStaleReadingIsTheSwitchTarget() {
        let now = Date()
        let h: TimeInterval = 3600
        let madmatter = makeProfile("madmatter23@gmail.com", usage: makeUsage(
            session: 100, weekly: 82, sessionResetIn: 48 * 60, weeklyResetIn: 6 * 24 * h, fable: 80, updatedAt: now))
        let grasmash = makeProfile("grasmashllc@gmail.com", usage: makeUsage(
            session: 0, weekly: 100, sessionResetIn: -2 * h, weeklyResetIn: 3 * 24 * h, fable: 59, updatedAt: now - 7 * h))
        let littlewing = makeProfile("littlewing@guitargate.com", usage: makeUsage(
            session: 82, weekly: 100, sessionResetIn: -10 * h, weeklyResetIn: 35 * h, fable: 66, updatedAt: now - 12 * h))
        let mattg = makeProfile("matt.grasmick@gmail.com", usage: makeUsage(
            session: 0, weekly: 100, sessionResetIn: -2 * h, weeklyResetIn: 3 * 24 * h, fable: 100, updatedAt: now - 7 * h))
        let goose = makeProfile("gooseappai@gmail.com", usage: makeUsage(
            session: 0, weekly: 100, sessionResetIn: -2 * h, weeklyResetIn: 2 * 24 * h, fable: 38, updatedAt: now - 7 * h))
        let mattgg = makeProfile("matt@guitargate.com", usage: makeUsage(
            session: 100, weekly: 44, sessionResetIn: -(4 * h + 22 * 60), weeklyResetIn: 6 * 24 * h, fable: 38,
            updatedAt: now - (4 * h + 25 * 60)))
        let profiles = [grasmash, littlewing, madmatter, mattg, goose, mattgg]

        var decider = AutoSwitchDecider()
        for usingFable in [false, true] {
            XCTAssertEqual(
                decider.decide(current: madmatter, profiles: profiles, usingFable: usingFable, now: now),
                .switchTo(mattgg, withoutFable: false), "usingFable=\(usingFable)")
            decider.reset(madmatter.id)
        }
        XCTAssertFalse(AutoSwitchStatus.build(profiles: profiles, activeId: madmatter.id, now: now).stuck)
    }

    // MARK: - Stuck with no free account: retry every tick (2026-10-11 6:05 PM)
    //
    // The app showed "no account free · next: madmatter23 6:05PM"; madmatter's
    // window reset at 6:05 and nothing switched, because the spent profile was
    // latched and only its OWN limits clearing re-armed the check.

    func testWhenAnotherAccountFreesUpTheNextTickSwitchesToIt() {
        var a = makeProfile("A", usage: makeUsage(session: 10, weekly: 100))
        var b = makeProfile("B", usage: makeUsage(session: 100, weekly: 10))
        let c = makeProfile("C", usage: makeUsage(session: 10, weekly: 100))
        var decider = AutoSwitchDecider()

        XCTAssertEqual(decider.decide(current: a, profiles: [a, b, c], usingFable: false), .noTarget(notify: true))

        b.claudeUsage = makeUsage(session: 0, weekly: 10)   // B's window reset
        a.claudeUsage = makeUsage(session: 10, weekly: 100)
        XCTAssertEqual(decider.decide(current: a, profiles: [a, b, c], usingFable: false), .switchTo(b, withoutFable: false))
    }

    func testWhileEverythingIsSpentItNeitherSwitchesNorReNotifies() {
        let a = makeProfile("A", usage: makeUsage(session: 10, weekly: 100))
        let b = makeProfile("B", usage: makeUsage(session: 100, weekly: 10))
        var decider = AutoSwitchDecider()

        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: false), .noTarget(notify: true))
        for _ in 0..<5 {
            XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: false), .noTarget(notify: false))
        }
    }

    func testAfterSwitchingItDoesNotFireAgainForTheSameProfile() {
        let a = makeProfile("A", usage: makeUsage(session: 10, weekly: 100))
        let b = makeProfile("B", usage: makeUsage(session: 10, weekly: 10))
        var decider = AutoSwitchDecider()

        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: false), .switchTo(b, withoutFable: false))
        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: false), .stay, "the switch is in flight")
    }

    func testAProfileWithHeadroomResetsItsLatch() {
        var a = makeProfile("A", usage: makeUsage(session: 10, weekly: 100))
        let b = makeProfile("B", usage: makeUsage(session: 100, weekly: 10))
        var decider = AutoSwitchDecider()
        _ = decider.decide(current: a, profiles: [a, b], usingFable: false)

        a.claudeUsage = makeUsage(session: 10, weekly: 10)
        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: false), .stay)
        a.claudeUsage = makeUsage(session: 10, weekly: 100)
        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: false), .noTarget(notify: true), "a new episode notifies again")
    }

    func testFableOnlyBlockWithNoFableHeadroomRetriesToo() {
        let a = makeProfile("A", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        var b = makeProfile("B", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        var decider = AutoSwitchDecider()

        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: true), .noFableHeadroom(notify: true))
        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: true), .noFableHeadroom(notify: false))
        b.claudeUsage = makeUsage(session: 10, weekly: 10, fable: 5)
        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: true), .switchTo(b, withoutFable: false))
    }

    func testFableSpentAloneIsNotABlockWhenFableIsNotInUse() {
        let a = makeProfile("A", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        let b = makeProfile("B", usage: makeUsage(session: 10, weekly: 10))
        var decider = AutoSwitchDecider()
        XCTAssertEqual(decider.decide(current: a, profiles: [a, b], usingFable: false), .stay)
    }

    func testAnActiveAccountTheTrackerCannotVouchForWaitsEvenIfAnotherHasHeadroom() {
        let other = makeProfile("B", usage: makeUsage(session: 10, weekly: 10, fable: 10))
        let stale = makeProfile("A", usage: makeUsage(session: 10, weekly: 10, fable: 100, updatedAt: Date().addingTimeInterval(-3600)))
        var paused = makeProfile("P", usage: makeUsage(session: 10, weekly: 10, fable: 100))
        paused.isPaused = true
        let unapplicable = Profile(name: "U", claudeUsage: makeUsage(session: 10, weekly: 10, fable: 100))

        for active in [stale, paused, unapplicable] {
            XCTAssertEqual(AutoSwitchPolicy.fableRestoreAction(profiles: [active, other], activeId: active.id),
                           .wait(.activeUnverifiable), active.name)
        }
    }

    func testASwitchIsAnnouncedOnlyWhenTheActiveProfileActuallyChangedToTheTarget() {
        let a = UUID(), b = UUID(), c = UUID()
        XCTAssertTrue(AutoSwitchPolicy.switchLanded(fromId: a, targetId: b, activeIdAfter: b))
        XCTAssertFalse(AutoSwitchPolicy.switchLanded(fromId: a, targetId: b, activeIdAfter: a), "activateProfile bailed (switch in flight)")
        XCTAssertFalse(AutoSwitchPolicy.switchLanded(fromId: b, targetId: b, activeIdAfter: b), "already on the target: no second notice")
        XCTAssertFalse(AutoSwitchPolicy.switchLanded(fromId: a, targetId: b, activeIdAfter: c))
    }

    // MARK: - Dead-login switch: a switch that does not land is retried

    func testADeadLoginSwitchThatDoesNotLandIsRetriedNextTick() {
        let a = UUID()
        var latch = DeadLoginSwitchLatch()

        XCTAssertTrue(latch.mayAttempt(a, switchInFlight: false))
        latch.attempted(a)
        XCTAssertFalse(latch.mayAttempt(a, switchInFlight: false), "no second attempt while the first is pending")

        latch.didNotLand(a)   // activateProfile returned without switching
        XCTAssertTrue(latch.mayAttempt(a, switchInFlight: false), "the next tick tries again")
    }

    func testADeadLoginSwitchIsNotAttemptedWhileAnotherSwitchIsInFlight() {
        let a = UUID()
        var latch = DeadLoginSwitchLatch()
        XCTAssertFalse(latch.mayAttempt(a, switchInFlight: true))
        latch.attempted(a)
        latch.loginAlive(a)
        XCTAssertTrue(latch.mayAttempt(a, switchInFlight: false), "a live login ends the episode")
    }

    func testDeadLoginWithNoTargetIsReportedOncePerEpisode() {
        let a = UUID()
        var latch = DeadLoginSwitchLatch()
        XCTAssertTrue(latch.noTarget(a))
        XCTAssertFalse(latch.noTarget(a))
        XCTAssertTrue(latch.mayAttempt(a, switchInFlight: false), "no target does not latch: retried every tick")
        latch.loginAlive(a)
        XCTAssertTrue(latch.noTarget(a))
    }

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
        fable: Double = 0,
        fableResetIn: TimeInterval = 86400,
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
            fableWeeklyTokensUsed: Int(fable * 10000),
            fableWeeklyPercentage: fable,
            fableWeeklyResetTime: Date().addingTimeInterval(fableResetIn),
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: updatedAt,
            userTimezone: .current
        )
    }
}
