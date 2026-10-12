import Foundation

/// What is shown for the active account the moment it changes.
///
/// 2026-10-12 ~2:50 PM ET: the session auto-switched from littlewing (100%) to
/// matt@guitargate; the status line showed the NEW name next to the OLD
/// account's figures until the next refresh, because the name came from the
/// status-line config (rewritten at once) and the figures from the usage
/// cache (rewritten only by the next fetch). The name and the figures must
/// change together: the new account's proven reading, or explicitly
/// "reading…", never the previous account's numbers under the new name.
enum ActiveAccountReading: Equatable {
    /// A reading of THIS account (fresh, so it is evidence, not a memory).
    case proven(ClaudeUsage)
    /// Nothing measured for this account yet: shown as "reading…".
    case notMeasured

    /// Only a FRESH stored reading (not `isStale`) is shown at the switch: it
    /// was fetched for this profile under its identity check, or taken from a
    /// proven mission-control row, within the staleness window. An older one
    /// is a memory of the account, not what it is at now.
    static func forNewlyActive(_ profile: Profile, now: Date = Date()) -> ActiveAccountReading {
        guard let usage = profile.claudeUsage, !usage.isStale(now: now) else { return .notMeasured }
        return .proven(usage)
    }
}
