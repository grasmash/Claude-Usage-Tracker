import Foundation

/// Pure selection logic for the auto-switch feature. Kept free of app state so
/// it can be unit tested without a `ProfileManager` or `MenuBarManager`.
enum AutoSwitchPolicy {

    /// Usage data older than this is not trusted for switching decisions.
    ///
    /// A profile the tracker can no longer refresh (expired session key, dead
    /// token) keeps its last snapshot forever. Once that snapshot's reset
    /// windows pass, its *effective* percentages read 0% and it looks like the
    /// freshest account on the machine — while in reality we know nothing about
    /// it. Switching to such a profile hands Claude Code credentials we cannot
    /// vouch for. So a candidate must have been observed recently.
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

    /// Candidates must be applicable (see `canBeApplied`), observed recently,
    /// and under both limits. When `usingFable` is true they must also be under
    /// their Fable weekly limit, since switching to an account whose Fable
    /// quota is spent would not unblock a Claude Code set to Fable.
    ///
    /// Profiles with no usage data, or data older than `maxUsageAge`, are
    /// skipped: the tracker cannot currently see them, so there is no evidence
    /// they have capacity (see `maxUsageAge`). Profiles `isLoginDead` reports
    /// as logged out, and paused profiles, are skipped too.
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

        for offset in 1..<count {
            let candidate = profiles[(currentIndex + offset) % count]

            guard !candidate.isPaused, canBeApplied(candidate) else { continue }

            // A rejected refresh token means the account is logged out;
            // applying it would hand Claude Code a login that cannot work.
            guard !isLoginDead(candidate) else { continue }

            guard let usage = candidate.claudeUsage else { continue }

            guard !usage.isStale(now: now) else { continue }

            if !usage.isLimitReached(usingFable: usingFable) {
                return candidate
            }
        }

        return nil
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
            return !usage.isLimitReached(usingFable: true)
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
        case wait
    }

    static func fableRestoreAction(
        profiles: [Profile], activeId: UUID?, now: Date = Date(), isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> FableRestoreAction {
        if let active = profiles.first(where: { $0.id == activeId }),
           anyProfileHasFableHeadroom([active], now: now, isLoginDead: isLoginDead) {
            return .restore
        }
        let others = profiles.filter { $0.id != activeId }
        return anyProfileHasFableHeadroom(others, now: now, isLoginDead: isLoginDead) ? .switchFirst : .wait
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
        case noTarget(notify: Bool)
        case noFableHeadroom(notify: Bool)
    }

    /// Profiles already switched away from in this episode (switch in flight).
    private(set) var switched: Set<UUID> = []
    /// Profiles already reported as stuck in this episode.
    private(set) var notifiedStuck: Set<UUID> = []

    mutating func decide(
        current: Profile, profiles: [Profile], usingFable: Bool, now: Date = Date(),
        isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> Decision {
        guard let usage = current.claudeUsage, usage.isLimitReached(usingFable: usingFable) else {
            reset(current.id)   // a window reset ends the episode
            return .stay
        }
        guard !switched.contains(current.id) else { return .stay }

        switch AutoSwitchPolicy.switchTarget(
            in: profiles, after: current, usingFable: usingFable, blockedBeyondFable: usage.isLimitReached,
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

    /// Forgets a profile's episode (its limits cleared, or a re-arm).
    mutating func reset(_ id: UUID) {
        switched.remove(id)
        notifiedStuck.remove(id)
    }
}
