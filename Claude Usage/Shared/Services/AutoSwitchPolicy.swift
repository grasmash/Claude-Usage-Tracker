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
    static let maxUsageAge: TimeInterval = 10 * 60

    /// Finds the next profile (wrapping around) that has credentials, has been
    /// observed recently, and has neither its 5-hour session nor its weekly
    /// quota exhausted.
    ///
    /// Candidates are filtered on `hasAnyCredentials`, not `hasUsageCredentials`:
    /// the latter drops profiles whose CLI OAuth access token has expired, but
    /// `ProfileManager.activateProfile` refreshes expired tokens (with rotation)
    /// before applying them, so such profiles are perfectly switchable. Idle
    /// profiles almost always hold an expired token (~8h lifetime), so the
    /// stricter check made the best rotation targets invisible.
    ///
    /// Profiles with no usage data, or data older than `maxUsageAge`, are
    /// skipped: the tracker cannot currently see them, so there is no evidence
    /// they have capacity (see `maxUsageAge`).
    static func nextAvailableProfile(
        in profiles: [Profile],
        after current: Profile,
        now: Date = Date()
    ) -> Profile? {
        guard let currentIndex = profiles.firstIndex(where: { $0.id == current.id }) else { return nil }

        let count = profiles.count
        guard count > 1 else { return nil }

        for offset in 1..<count {
            let candidate = profiles[(currentIndex + offset) % count]

            guard candidate.hasAnyCredentials else { continue }

            guard let usage = candidate.claudeUsage else { continue }

            guard now.timeIntervalSince(usage.lastUpdated) <= maxUsageAge else { continue }

            if !usage.isLimitReached {
                return candidate
            }
        }

        return nil
    }
}
