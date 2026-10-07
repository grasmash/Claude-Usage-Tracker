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

    /// How long the active login must have been expired before the tracker
    /// refreshes it itself.
    static let activeLoginRefreshGrace: TimeInterval = 15 * 60

    /// True when the tracker may refresh the ACTIVE login (the one in Claude
    /// Code's keychain entry).
    ///
    /// Claude Code refreshes that login itself the moment a session needs it
    /// after expiry. A tracker refresh in that same window uses the same
    /// single-use refresh token; the server treats the second use as reuse and
    /// rejects the login for everyone ("Login expired"). Observed 2026-10-06/07:
    /// matt.grasmick and goose each died seconds after their access token
    /// expired while active. Once the login has sat expired for the grace
    /// period, no session is refreshing it and the tracker may.
    static func mayRefreshActiveLogin(expiresAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(expiresAt) >= activeLoginRefreshGrace
    }

    /// True when an idle account's saved main login has expired and should be
    /// refreshed now. Doing it ahead of time keeps the login alive and, if the
    /// server rejects it, reveals the dead login before auto-switch needs it.
    ///
    /// Only for pinned profiles' own main logins: the tracker is their only
    /// holder while the profile is inactive. The active login belongs to
    /// Claude Code, and an unpinned profile's lineage may be owned elsewhere.
    static func shouldRefreshIdleLogin(_ profile: Profile, activeId: UUID?, now: Date = Date()) -> Bool {
        guard profile.id != activeId,
              profile.customKeychainServiceName != nil,
              profile.hasOwnMainLogin,
              let json = profile.cliCredentialsJSON,
              let expiry = ClaudeCodeSyncService.shared.extractTokenExpiry(from: json) else { return false }
        return expiry <= now
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
    /// as logged out are skipped too.
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

            guard canBeApplied(candidate) else { continue }

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
