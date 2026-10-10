import Foundation

/// What the status line is told about auto-switching: whether it is stuck
/// (Claude Code is blocked and no other account can take over), when the
/// soonest account frees up, and which accounts need a fresh login.
///
/// Built from the same rules `AutoSwitchPolicy` switches by, so the status line
/// never has to re-derive them.
struct AutoSwitchStatus {
    var stuck: Bool
    var nextFree: (name: String, at: Date)?
    var needsLogin: [String]

    static func build(
        profiles: [Profile],
        activeId: UUID?,
        usingFable: Bool = false,
        now: Date = Date(),
        isLoginDead: (Profile) -> Bool = { _ in false }
    ) -> AutoSwitchStatus {
        // Paused accounts are set aside on purpose; they are neither
        // candidates nor something to nag about. The active one still counts.
        let switchable = profiles.filter {
            $0.provider.descriptor.capabilities.cliAccountSync && (!$0.isPaused || $0.id == activeId)
        }

        let needsLogin = switchable
            .filter { isLoginDead($0) || !AutoSwitchPolicy.canBeApplied($0) }
            .map { shortName($0.name) }

        var stuck = false
        if let active = switchable.first(where: { $0.id == activeId }) {
            let blocked = isLoginDead(active)
                || (active.claudeUsage?.isLimitReached(usingFable: usingFable) ?? false)
            stuck = blocked && AutoSwitchPolicy.nextAvailableProfile(
                in: switchable, after: active, usingFable: usingFable, now: now, isLoginDead: isLoginDead
            ) == nil
        }

        let nextFree = switchable
            .filter { !isLoginDead($0) && AutoSwitchPolicy.canBeApplied($0) }
            .compactMap { profile -> (name: String, at: Date)? in
                guard let usage = profile.claudeUsage else { return nil }
                return (shortName(profile.name), freeAt(usage, usingFable: usingFable, now: now))
            }
            .min { $0.at < $1.at }

        return AutoSwitchStatus(stuck: stuck, nextFree: nextFree, needsLogin: needsLogin)
    }

    /// When an account can be used again: once every limit it has exhausted has reset.
    static func freeAt(_ usage: ClaudeUsage, usingFable: Bool, now: Date) -> Date {
        var resets: [Date] = []
        if usage.effectiveSessionPercentage >= 100 { resets.append(usage.sessionResetTime) }
        if usage.effectiveWeeklyPercentage >= 100 { resets.append(usage.weeklyResetTime) }
        if usingFable, usage.effectiveFableWeeklyPercentage >= 100, let reset = usage.fableWeeklyResetTime {
            resets.append(reset)
        }
        return resets.max() ?? now
    }

    /// Profiles are named by email; the part before `@` is enough on one line.
    static func shortName(_ name: String) -> String {
        name.split(separator: "@").first.map(String.init) ?? name
    }

    /// `KEY=value` lines, simple enough for the status line's bash to read.
    func stateFileContents(timeFormatter: (Date) -> String) -> String {
        let free = nextFree.map { "\($0.name) \(timeFormatter($0.at))" } ?? ""
        return "STUCK=\(stuck ? 1 : 0)\nNEXT_FREE=\(free)\nNEEDS_LOGIN=\(needsLogin.joined(separator: ", "))\n"
    }
}
