import Foundation

/// Pure selection logic for the auto-switch feature. Kept free of app state so
/// it can be unit tested without a `ProfileManager` or `MenuBarManager`.
enum AutoSwitchPolicy {

    /// Usage data older than this is a presumption, not an observation.
    ///
    /// A fresh reading (within this age) is evidence an account has room and
    /// always wins. An older reading is taken only as a last resort, and only
    /// when it reports no limit still in force — a limit it reported as
    /// reached whose window has since passed counts as reset (the effective
    /// percentages). It used to be a hard gate: a profile the tracker could no
    /// longer refresh kept a snapshot whose windows had passed, looked free, and
    /// on 2026-09-17 auto-switch wrote its dead login into the keychain. That
    /// hazard is handled where it arises now — `isLoginDead` skips a login the
    /// server has rejected, and the swap's own refresh
    /// (`refreshStoredMainLoginIfExpired`) marks a login dead on `invalid_grant`
    /// so the next tick moves on — while the gate had become the thing that
    /// kept rotation stuck: since the single refresher (0bca20c) the tracker
    /// never reads a non-active login again once its access token expires, so
    /// EVERY other account's reading is stale within hours and nothing was ever
    /// a candidate. 2026-10-11 11:52 PM: madmatter hit its limit, the status
    /// line said "no account free · next: matt 11:51PM" (free NOW), and
    /// matt@guitargate.com — last read ~19:30 at 100% with a window that ended
    /// 19:29:59, weekly 44% — was skipped for four hours. A presumed-free
    /// account is verified after the switch: active, it is read live, and a
    /// spent reading re-runs this search.
    static let maxUsageAge: TimeInterval = Constants.usageStaleAfter

    /// Finds the next profile (wrapping around) that has credentials, has been
    /// observed recently, and has neither its 5-hour session nor its weekly
    /// quota exhausted.
    ///
    /// A switch only helps Claude Code if we can actually write the target's
    /// CLI credentials into the system keychain. A profile with no stored CLI
    /// credentials (never linked, or session-key-only) "activates" in the
    /// tracker while the keychain stays on the exhausted account — the user
    /// sees a switch that changed nothing. Such profiles are not switch
    /// targets. Expired tokens are fine: `activateProfile` refreshes them.
    ///
    /// A pinned profile additionally needs its own main login (see
    /// `Profile.hasOwnMainLogin`): its pinned keychain entry is never copied
    /// into the main keychain.
    static func canBeApplied(_ profile: Profile) -> Bool {
        guard profile.provider.descriptor.capabilities.cliAccountSync,
              profile.cliCredentialsJSON != nil else { return false }
        return profile.customKeychainServiceName == nil || profile.hasOwnMainLogin
    }

    /// Whether the tracker may refresh the ACTIVE login (the one in Claude
    /// Code's keychain entry): never.
    ///
    /// Claude Code sessions hold that login in memory and refresh it themselves
    /// when they need it. A tracker refresh uses the same single-use refresh
    /// token; the server treats the second use as reuse and rejects the login
    /// for everyone ("Login expired"). Observed 2026-10-06/07: matt.grasmick
    /// and goose each died seconds after their access token expired while
    /// active. A grace period after expiry did not fix it — a session asleep
    /// through the grace period still wakes holding the old token — so the
    /// tracker now never refreshes a login any `claude` process may hold.
    /// (`ClaudeCodeSyncService.switchMainLogin(to:)` refreshes a STORED login
    /// only after proving no process holds the shared login.)
    static func mayRefreshActiveLogin(expiresAt: Date, now: Date = Date()) -> Bool {
        false
    }

    /// True when a login found in the main keychain is separate from a
    /// profile's pinned entry rather than a copy of it. An unreadable pinned
    /// entry cannot be the source of a copy.
    static func isOwnMainLogin(mainRefreshToken: String?, pinnedRefreshToken: String?) -> Bool {
        guard let mainRefreshToken else { return false }
        return mainRefreshToken != pinnedRefreshToken
    }

    /// Candidates must be applicable (see `canBeApplied`) and under both
    /// limits. When `usingFable` is true they must also be under their Fable
    /// weekly limit, since switching to an account whose Fable quota is spent
    /// would not unblock a Claude Code set to Fable.
    ///
    /// The first candidate (wrapping around) with a FRESH reading under its
    /// limits is returned. Failing that, the first whose stale reading reports
    /// no limit still in force — presumed free, see `maxUsageAge`. Profiles
    /// with no usage data at all are skipped: nothing was ever observed.
    /// Profiles `isLoginDead` reports as logged out, and paused profiles, are
    /// skipped too.
    static func nextAvailableProfile(
        in profiles: [Profile],
        after current: Profile,
        usingFable: Bool = false,
        now: Date = Date(),
        isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> Profile? {
        guard let currentIndex = profiles.firstIndex(where: { $0.id == current.id }) else { return nil }

        let count = profiles.count
        guard count > 1 else { return nil }

        var presumedFree: Profile?
        for offset in 1..<count {
            let candidate = profiles[(currentIndex + offset) % count]

            guard !candidate.isPaused, canBeApplied(candidate) else { continue }

            // A rejected refresh token means the account is logged out;
            // applying it would hand Claude Code a login that cannot work.
            guard !isLoginDead(candidate) else { continue }

            guard let usage = candidate.claudeUsage,
                  !usage.isLimitReached(usingFable: usingFable, now: now) else { continue }

            if !usage.isStale(now: now) {
                return candidate
            }
            // Among presumptions, the most recently observed is the best one.
            if let held = presumedFree?.claudeUsage?.lastUpdated, held >= usage.lastUpdated { continue }
            presumedFree = candidate
        }

        return presumedFree
    }

    // MARK: - Proactive hand-off (switch BEFORE the limit)

    /// The active account's binding window at or above this (on a FRESH
    /// reading) hands the shared login to another account before the limit
    /// interrupts work. Operator, 2026-10-12: every limit hit that day killed
    /// in-flight subagents with 429s before the 100% switch could land.
    static let proactiveThreshold: Double = 90

    /// A hand-off target has EVERY binding window at or below this. The gap to
    /// `proactiveThreshold` is the hysteresis: an account handed off at 90%
    /// cannot be handed back to until its window resets, so two accounts never
    /// ping-pong, and the target has real room, not a sliver.
    static let handoffTargetCeiling: Double = 75

    /// The highest window in force that could stop Claude Code: session,
    /// weekly, and the Fable weekly only while Fable is in use.
    static func bindingPercentage(_ usage: ClaudeUsage, usingFable: Bool, now: Date = Date()) -> Double {
        var binding = max(usage.effectiveSessionPercentage(now: now), usage.effectiveWeeklyPercentage(now: now))
        if usingFable { binding = max(binding, usage.effectiveFableWeeklyPercentage(now: now)) }
        return binding
    }

    /// True when `usage` is a fresh reading at or above the hand-off threshold.
    /// A stale reading never triggers a hand-off: it may be hours old.
    static func isNearLimit(_ usage: ClaudeUsage, usingFable: Bool, now: Date = Date()) -> Bool {
        !usage.isStale(now: now) && bindingPercentage(usage, usingFable: usingFable, now: now) >= proactiveThreshold
    }

    /// The first profile (wrapping around) fit to take the shared login
    /// proactively: applicable, not paused, not dead, with a FRESH reading whose
    /// every binding window is at or below `handoffTargetCeiling`. A presumed
    /// account (stale reading) is never a hand-off target — proactivity is a
    /// convenience, and it must not move working sessions onto a guess.
    static func handoffTarget(
        in profiles: [Profile], after current: Profile, usingFable: Bool,
        now: Date = Date(), isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> Profile? {
        guard let currentIndex = profiles.firstIndex(where: { $0.id == current.id }), profiles.count > 1 else { return nil }
        for offset in 1..<profiles.count {
            let candidate = profiles[(currentIndex + offset) % profiles.count]
            guard !candidate.isPaused, canBeApplied(candidate), !isLoginDead(candidate),
                  let usage = candidate.claudeUsage, !usage.isStale(now: now),
                  bindingPercentage(usage, usingFable: usingFable, now: now) <= handoffTargetCeiling else { continue }
            return candidate
        }
        return nil
    }

    /// Whether an auto-switch may make `target` the tracker's active profile
    /// given what `switchMainLogin` did with the shared login.
    ///
    /// A switch the user clicked always activates: they chose the account, and
    /// the notification tells them what Claude Code's login is doing. An
    /// AUTOMATIC switch activates only when the shared login was written, or
    /// its refusal will be retried (sessions running, an unknown or unreadable
    /// keychain, no process list). When the stored login could not be applied
    /// at all — the switch threw (its refresh was rejected: the login is dead,
    /// and `refreshStoredMainLoginIfExpired` has marked it so), or the refusal
    /// is final (`untrustedStoredLogin`, `notTheSharedLoginEntry`) — the
    /// tracker must NOT move: with tracker-active = target and keychain = the
    /// spent account, `isLoginDead(target)` would judge by the keychain's
    /// login, the target's stale "free" reading would read `.stay`, adoption
    /// never fires, and rotation stalls behind a false "switched" notice.
    /// Staying put makes `switchLanded` false, so the decider re-arms and the
    /// next tick skips the now-dead target (probe D, gate on 2070d8b).
    static func activateAfterMainLoginSwitch(
        _ outcome: Result<ClaudeCodeSyncService.MainLoginSwitch, Error>, selectedBy: String, handoff: Bool = false
    ) -> Bool {
        guard selectedBy == "auto" else { return true }
        // A proactive hand-off moves the tracker only when the shared login was
        // actually written. Otherwise the sessions stay on the near-limit
        // account; a tracker that moved anyway stops reading it (its reading
        // goes stale) and, believing it already switched, never rescues the
        // sessions when that account then hits 100%. Retried next tick.
        if handoff {
            switch outcome {
            case .success(.applied), .success(.alreadyApplied): return true
            default: return false
            }
        }
        switch outcome {
        case .failure:
            return false
        case .success(.refused(.untrustedStoredLogin)), .success(.refused(.notTheSharedLoginEntry)):
            return false
        case .success:
            return true
        }
    }

    /// Where auto-switch goes (operator, 2026-10-11: "if fable is being used,
    /// and a fable limit is hit, change profile. only if being used. if none
    /// is available, downgrade to opus as last resort").
    enum SwitchTarget: Equatable {
        /// A profile that unblocks Claude Code as it is configured (with Fable
        /// headroom when Fable is in use).
        case profile(Profile)
        /// Fable is in use and no profile has Fable headroom, but the current
        /// account is blocked beyond Fable (session/weekly/dead) and this one
        /// is not: the sessions can run there once switched to Opus.
        case profileWithoutFable(Profile)
        /// Fable is in use, only its Fable quota is spent, and no profile has
        /// Fable headroom: moving gains nothing; the sessions stay.
        case noFableHeadroom
        /// Nothing available.
        case none
    }

    /// `blockedBeyondFable`: the current account is blocked by its session or
    /// weekly limit (or a dead login), not only by its Fable quota.
    static func switchTarget(
        in profiles: [Profile], after current: Profile, usingFable: Bool, blockedBeyondFable: Bool,
        now: Date = Date(), isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> SwitchTarget {
        if let p = nextAvailableProfile(in: profiles, after: current, usingFable: usingFable, now: now, isLoginDead: isLoginDead) {
            return .profile(p)
        }
        guard usingFable else { return .none }
        guard blockedBeyondFable else { return .noFableHeadroom }
        if let p = nextAvailableProfile(in: profiles, after: current, usingFable: false, now: now, isLoginDead: isLoginDead) {
            return .profileWithoutFable(p)
        }
        return .none
    }

    /// True when some account could run Fable now: applicable, not paused, not
    /// logged out, observed recently, and under its session, weekly and Fable
    /// weekly limits. Ends the Opus fallback (`ModelFallback.restore`).
    static func anyProfileHasFableHeadroom(
        _ profiles: [Profile], now: Date = Date(), isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> Bool {
        profiles.contains { p in
            guard !p.isPaused, canBeApplied(p), !isLoginDead(p),
                  let usage = p.claudeUsage, !usage.isStale(now: now) else { return false }
            return !usage.isLimitReached(usingFable: true, now: now)
        }
    }

    /// What to do about an active Opus fallback.
    enum FableRestoreAction: Equatable {
        /// The active account (the shared login) can run Fable: restore.
        case restore
        /// Another account can run Fable but the active one cannot: switch the
        /// shared login there first, restore after. Restoring now would put
        /// Claude Code back on Fable on a Fable-spent account.
        case switchFirst
        /// No account can run Fable yet.
        case wait(WaitReason)
    }

    enum WaitReason: Equatable {
        /// No account can run Fable yet.
        case noHeadroom
        /// The active account's reading is stale, or it is paused or cannot be
        /// applied: the tracker cannot tell whether it has Fable headroom, so it
        /// neither restores nor re-arms a switch.
        case activeUnverifiable
    }

    /// True when an auto-switch actually moved the active profile from `fromId`
    /// to the target. activateProfile returns early (no change) while another
    /// switch is in flight, and a re-armed tick may target the profile that is
    /// already active; neither is announced.
    static func switchLanded(fromId: UUID, targetId: UUID, activeIdAfter: UUID?) -> Bool {
        fromId != targetId && activeIdAfter == targetId
    }

    static func fableRestoreAction(
        profiles: [Profile], activeId: UUID?, now: Date = Date(), isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> FableRestoreAction {
        guard let active = profiles.first(where: { $0.id == activeId }),
              !active.isPaused, canBeApplied(active),
              let usage = active.claudeUsage, !usage.isStale(now: now) else {
            return .wait(.activeUnverifiable)
        }
        if anyProfileHasFableHeadroom([active], now: now, isLoginDead: isLoginDead) {
            return .restore
        }
        let others = profiles.filter { $0.id != activeId }
        return anyProfileHasFableHeadroom(others, now: now, isLoginDead: isLoginDead) ? .switchFirst : .wait(.noHeadroom)
    }

    // MARK: - Claude Code model selection

    /// True when a Claude Code model setting (alias like `fable`, or a full id
    /// like `claude-fable-5-1[1m]`) selects the Fable/Mythos model.
    static func isFableModel(_ model: String?) -> Bool {
        guard let model = model?.lowercased() else { return false }
        return model.contains("fable") || model.contains("mythos")
    }

    /// The model Claude Code is configured to use, from the user settings file.
    ///
    /// `/model` persists its choice as `"model"`; an `env.ANTHROPIC_MODEL`
    /// entry is honoured as a fallback. Returns nil when neither is set, which
    /// means Claude Code is on its default model. A `/model` change made only
    /// for the current session, or a per-project setting, is not visible here.
    static func selectedClaudeCodeModel(
        settingsURL: URL = Constants.ClaudePaths.claudeDirectory.appendingPathComponent("settings.json")
    ) -> String? {
        guard let data = try? Data(contentsOf: settingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let model = json["model"] as? String, !model.isEmpty { return model }
        if let env = json["env"] as? [String: Any],
           let model = env["ANTHROPIC_MODEL"] as? String, !model.isEmpty { return model }
        return nil
    }

    /// True when Claude Code is (or was just) running on Fable.
    ///
    /// The settings file misses the common cases — Fable as Claude Code's
    /// default model, or a session-only `/model` — so the models actually
    /// answering in recently active sessions are checked first.
    static func isClaudeCodeUsingFable(
        projectsURL: URL = Constants.ClaudePaths.projectsDirectory,
        settingsURL: URL = Constants.ClaudePaths.claudeDirectory.appendingPathComponent("settings.json"),
        now: Date = Date()
    ) -> Bool {
        if recentSessionModels(projectsURL: projectsURL, now: now).contains(where: { isFableModel($0) }) {
            return true
        }
        return isFableModel(selectedClaudeCodeModel(settingsURL: settingsURL))
    }

    /// How recently a session transcript must have been written to count as active.
    static let activeSessionWindow: TimeInterval = 30 * 60

    /// Bytes read from the end of each transcript when looking for its latest reply.
    private static let transcriptTailBytes = 256 * 1024

    /// The model of the latest real assistant reply in each Claude Code session
    /// transcript (`projects/<project>/<session>.jsonl`) modified within
    /// `activeSessionWindow`. Synthetic replies (e.g. the rate-limit notice
    /// Claude Code writes when a quota is exhausted) are skipped.
    static func recentSessionModels(projectsURL: URL, now: Date = Date()) -> [String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var models: [String] = []
        for dir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(forKeys: Set(keys)).contentModificationDate,
                      now.timeIntervalSince(modified) <= activeSessionWindow,
                      let model = latestAssistantModel(in: file) else { continue }
                models.append(model)
            }
        }
        return models
    }

    /// The `message.model` of the last non-synthetic assistant entry in a transcript.
    static func latestAssistantModel(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(transcriptTailBytes) ? size - UInt64(transcriptTailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() where line.contains("\"assistant\"") {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.isEmpty, !model.hasPrefix("<") else { continue }
            return model
        }
        return nil
    }
}

/// Decides, each refresh tick, whether the active profile's limit calls for a
/// switch. While the active profile stays spent and no target exists, the
/// target search re-runs EVERY tick, so another account freeing up (its window
/// resetting) is picked up on the next tick. 2026-10-11 6:05 PM: the app showed
/// "no account free · next: madmatter23 6:05PM" and never switched, because a
/// spent profile was latched until its OWN limits cleared. The user is told
/// "no account free" once per episode, not every tick; a switch fires once.
struct AutoSwitchDecider {
    enum Decision: Equatable {
        case stay
        case switchTo(Profile, withoutFable: Bool)
        /// Proactive: the active account is near its limit and this account has
        /// fresh, proven room. Nothing is blocked yet; nobody is notified of a
        /// problem.
        case handOff(Profile)
        case noTarget(notify: Bool)
        case noFableHeadroom(notify: Bool)
    }

    /// Profiles already switched away from in this episode (switch in flight).
    private(set) var switched: Set<UUID> = []
    /// Profiles already reported as stuck in this episode.
    private(set) var notifiedStuck: Set<UUID> = []
    /// Profiles handed off in the current window, keyed by the window's reset
    /// time, so one window fires one hand-off (a new window is a new episode).
    private(set) var handedOff: [UUID: Date] = [:]
    /// Proactive hand-off on/off (the operator's kill switch).
    var proactive: Bool

    init(proactive: Bool = true) {
        self.proactive = proactive
    }

    mutating func decide(
        current: Profile, profiles: [Profile], usingFable: Bool, now: Date = Date(),
        isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> Decision {
        guard let usage = current.claudeUsage, usage.isLimitReached(usingFable: usingFable, now: now) else {
            reset(current.id)   // a window reset ends the episode
            return decideHandoff(current: current, profiles: profiles, usingFable: usingFable, now: now, isLoginDead: isLoginDead)
        }
        guard !switched.contains(current.id) else { return .stay }

        switch AutoSwitchPolicy.switchTarget(
            in: profiles, after: current, usingFable: usingFable, blockedBeyondFable: usage.isLimitReached(now: now),
            now: now, isLoginDead: isLoginDead
        ) {
        case .profile(let p):
            switched.insert(current.id); notifiedStuck.remove(current.id)
            return .switchTo(p, withoutFable: false)
        case .profileWithoutFable(let p):
            switched.insert(current.id); notifiedStuck.remove(current.id)
            return .switchTo(p, withoutFable: true)
        case .noFableHeadroom:
            return .noFableHeadroom(notify: notifiedStuck.insert(current.id).inserted)
        case .none:
            return .noTarget(notify: notifiedStuck.insert(current.id).inserted)
        }
    }

    /// The proactive branch: the active account is not at a limit. Hands off
    /// once per window when its fresh reading is near the limit and a fit
    /// target exists; otherwise stays, silently.
    private mutating func decideHandoff(
        current: Profile, profiles: [Profile], usingFable: Bool, now: Date, isLoginDead: (Profile) -> Bool
    ) -> Decision {
        guard proactive, let usage = current.claudeUsage,
              AutoSwitchPolicy.isNearLimit(usage, usingFable: usingFable, now: now) else {
            handedOff.removeValue(forKey: current.id)   // below the threshold: the window reset or never fired
            return .stay
        }
        let window = Self.bindingWindowReset(usage, usingFable: usingFable, now: now)
        if let latched = handedOff[current.id], latched == window { return .stay }
        guard let target = AutoSwitchPolicy.handoffTarget(
            in: profiles, after: current, usingFable: usingFable, now: now, isLoginDead: isLoginDead
        ) else { return .stay }
        handedOff[current.id] = window
        return .handOff(target)
    }

    /// The reset time of the window that binds (minute precision: the API's
    /// reset time jitters by seconds between reads).
    static func bindingWindowReset(_ usage: ClaudeUsage, usingFable: Bool, now: Date) -> Date {
        let binding = AutoSwitchPolicy.bindingPercentage(usage, usingFable: usingFable, now: now)
        var reset = usage.sessionResetTime
        if usage.effectiveWeeklyPercentage(now: now) == binding { reset = usage.weeklyResetTime }
        if usingFable, usage.effectiveFableWeeklyPercentage(now: now) == binding, let f = usage.fableWeeklyResetTime { reset = f }
        if usage.effectiveSessionPercentage(now: now) == binding { reset = usage.sessionResetTime }
        return Date(timeIntervalSince1970: (reset.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// The hand-off did not change the active profile (refused, raced): retry
    /// next tick.
    mutating func handoffDidNotLand(_ id: UUID) {
        handedOff.removeValue(forKey: id)
    }

    /// Forgets a profile's episode (its limits cleared, or a re-arm).
    mutating func reset(_ id: UUID) {
        switched.remove(id)
        notifiedStuck.remove(id)
    }
}

/// The dead-login auto-switch's per-profile state: one attempt per episode
/// while a switch is pending, retried when a switch did not land, and "no way
/// out" reported once per episode while the target search re-runs every tick.
struct DeadLoginSwitchLatch {
    private(set) var switched: Set<UUID> = []
    private(set) var stuckNotified: Set<UUID> = []

    /// The login works again: the episode is over.
    mutating func loginAlive(_ id: UUID) {
        switched.remove(id)
        stuckNotified.remove(id)
    }

    func mayAttempt(_ id: UUID, switchInFlight: Bool) -> Bool {
        !switchInFlight && !switched.contains(id)
    }

    /// No target this tick; returns true the first time in the episode.
    mutating func noTarget(_ id: UUID) -> Bool {
        stuckNotified.insert(id).inserted
    }

    mutating func attempted(_ id: UUID) {
        switched.insert(id)
        stuckNotified.remove(id)
    }

    /// activateProfile returned without switching: retry next tick.
    mutating func didNotLand(_ id: UUID) { switched.remove(id) }

    /// Re-armed from outside (the Opus fallback's `.switchFirst`).
    mutating func rearm(_ id: UUID) { switched.remove(id) }
}
