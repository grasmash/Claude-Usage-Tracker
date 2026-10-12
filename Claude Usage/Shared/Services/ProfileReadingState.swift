import Foundation

/// What the app can honestly say about a profile's usage reading, kept apart
/// so the operator can tell "nothing to do" from "you must sign in".
///
/// - `signInNeeded`: the login is DEAD. A refresh returned `invalid_grant`
///   (which marks it in `deadLogins`) or `deadLogins` already holds it. Only a
///   new sign-in (`claude-usage-login`) fixes it; rotation skips it.
/// - `staleIdle`: an inactive profile's reading is old. That is normal: its
///   access token expired, the tracker never refreshes a login it does not
///   solely hold, and the refresh token is presumed fine. Rotation can still
///   switch there (the switch refreshes before it writes). No action needed.
///
/// Built ONLY from what the app already knows (the dead-login set and the last
/// refresh result). It never probes a refresh to find out: that is a token
/// write.
enum ProfileReadingState: Equatable {
    case neverUpdated
    case signInNeeded
    case fresh(fromMissionControl: Bool)
    /// Stale, and the last refresh of this profile failed for a reason other
    /// than a dead login (e.g. an expired claude.ai session key).
    case refreshFailed(String)
    /// Stale inactive profile: normal, no action.
    case staleIdle(age: TimeInterval, fromMissionControl: Bool)
    /// Stale ACTIVE profile with no recorded error: its live read is not landing.
    case staleActive(age: TimeInterval)

    static func classify(
        profile: Profile, isActive: Bool, isLoginDead: Bool, refreshError: String?, now: Date = Date()
    ) -> ProfileReadingState {
        // A dead login outranks any reading: even a fresh mc reading cannot
        // make an account usable that Claude Code cannot sign in to.
        if isLoginDead { return .signInNeeded }
        guard let usage = profile.claudeUsage else { return .neverUpdated }
        let age = max(0, now.timeIntervalSince(usage.lastUpdated))
        // A single failed refresh on otherwise-fresh data is noise (transient
        // 429s, blips). Only call it out once the data has actually gone stale.
        guard usage.isStale(now: now) else { return .fresh(fromMissionControl: usage.isFromMissionControl) }
        if let refreshError { return .refreshFailed(refreshError) }
        if isActive { return .staleActive(age: age) }
        return .staleIdle(age: age, fromMissionControl: usage.isFromMissionControl)
    }

    /// True when the operator has to do something about it.
    var needsAction: Bool {
        switch self {
        case .neverUpdated, .signInNeeded, .refreshFailed, .staleActive: return true
        case .fresh, .staleIdle: return false
        }
    }
}
