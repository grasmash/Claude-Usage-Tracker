import Foundation

/// Pure selection logic for the auto-switch feature. Kept free of app state so
/// it can be unit tested without a `ProfileManager` or `MenuBarManager`.
enum AutoSwitchPolicy {

    /// Finds the next profile (wrapping around) that has credentials and has
    /// neither its 5-hour session nor its weekly quota exhausted.
    ///
    /// Candidates are filtered on `hasAnyCredentials`, not `hasUsageCredentials`:
    /// the latter drops profiles whose CLI OAuth access token has expired, but
    /// `ProfileManager.activateProfile` refreshes expired tokens (with rotation)
    /// before applying them, so such profiles are perfectly switchable. Idle
    /// profiles almost always hold an expired token (~8h lifetime), so the
    /// stricter check made the best rotation targets invisible.
    ///
    /// Profiles without any saved usage data are treated as available: the app
    /// has not observed them yet, so there is no evidence they are limited.
    static func nextAvailableProfile(in profiles: [Profile], after current: Profile) -> Profile? {
        guard let currentIndex = profiles.firstIndex(where: { $0.id == current.id }) else { return nil }

        let count = profiles.count
        guard count > 1 else { return nil }

        for offset in 1..<count {
            let candidate = profiles[(currentIndex + offset) % count]

            guard candidate.hasAnyCredentials else { continue }

            guard let usage = candidate.claudeUsage else { return candidate }

            if !usage.isLimitReached {
                return candidate
            }
        }

        return nil
    }
}
