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
    /// Where auto-switch goes next, from the SAME policy the switcher runs
    /// (`AutoSwitchPolicy.handoffTarget` / `switchTarget`), so the status line
    /// can never say "free now" while the policy refuses (2026-10-11 23:52).
    var next: NextSwitch = .none
    /// Fable is in use: the binding limit includes the Fable weekly window.
    var fableBinding: Bool = false
    /// The active profile's short name (for "opus stays on …").
    var activeName: String = ""

    enum NextSwitch: Equatable {
        /// A profile the switcher would move to right now. `presumed`: its
        /// reading is stale (a window that has passed), not observed.
        case ready(name: String, presumed: Bool)
        /// Fable in use, no account has Fable headroom, but this one can run
        /// the sessions on Opus.
        case readyWithoutFable(name: String, presumed: Bool)
        /// Fable in use, only Fable is spent everywhere: the sessions stay and
        /// run on Opus.
        case noFableHeadroom
        /// Every candidate is still at a limit; this one frees first, at `at`.
        case limited(name: String, at: Date)
        /// This account has room, but the swap to it keeps being refused
        /// (an untrusted stored login, a hand-off refused tick after tick):
        /// it is not "ready" until that is fixed.
        case refused(name: String)
        /// Nothing known at all.
        case none
    }
    /// Accounts whose login is DEAD (refresh rejected with `invalid_grant`,
    /// held in `deadLogins`): only a new sign-in fixes them. A subset of
    /// `needsLogin`, which also lists accounts with no saved login at all.
    /// An account whose reading is merely old is never listed: that is normal.
    var signInNeeded: [String] = []

    static func build(
        profiles: [Profile],
        activeId: UUID?,
        usingFable: Bool = false,
        proactive: Bool = true,
        now: Date = Date(),
        isLoginDead: (Profile) -> Bool = { _ in false },
        isHeldBack: (Profile) -> Bool = { _ in false },
        isRefusing: (Profile) -> Bool = { _ in false }
    ) -> AutoSwitchStatus {
        // Not a switch target: dead, or held back by an unreleased hand-off
        // (the same predicate the switcher uses). Only DEAD logins need a sign-in.
        func unavailable(_ profile: Profile) -> Bool { isLoginDead(profile) || isHeldBack(profile) || isRefusing(profile) }
        func unavailableButForRefusal(_ profile: Profile) -> Bool { isLoginDead(profile) || isHeldBack(profile) }
        // Paused accounts are set aside on purpose; they are neither
        // candidates nor something to nag about. The active one still counts.
        let switchable = profiles.filter {
            $0.provider.descriptor.capabilities.cliAccountSync && (!$0.isPaused || $0.id == activeId)
        }

        let needsLogin = switchable
            .filter { isLoginDead($0) || !AutoSwitchPolicy.canBeApplied($0) }
            .map { shortName($0.name) }

        let signInNeeded = switchable.filter { isLoginDead($0) }.map { shortName($0.name) }

        var stuck = false
        var next: NextSwitch = .none
        var activeName = ""
        if let active = switchable.first(where: { $0.id == activeId }) {
            activeName = shortName(active.name)
            let blocked = isLoginDead(active)
                || (active.claudeUsage?.isLimitReached(usingFable: usingFable, now: now) ?? false)
            stuck = blocked && AutoSwitchPolicy.nextAvailableProfile(
                in: switchable, after: active, usingFable: usingFable, now: now, isLoginDead: unavailable
            ) == nil
            next = nextSwitch(active: active, in: switchable, usingFable: usingFable, proactive: proactive,
                              now: now, isLoginDead: unavailable)
            // Nobody is ready, but one WOULD be if its swap were not refused: say that.
            switch next {
            case .ready, .readyWithoutFable:
                break
            default:
                switch nextSwitch(active: active, in: switchable, usingFable: usingFable, proactive: proactive,
                                  now: now, isLoginDead: unavailableButForRefusal) {
                case .ready(let name, _), .readyWithoutFable(let name, _):
                    next = .refused(name: name)
                default:
                    break
                }
            }
        }

        let nextFree = switchable
            .filter { !unavailable($0) && AutoSwitchPolicy.canBeApplied($0) }
            .compactMap { profile -> (name: String, at: Date)? in
                guard let usage = profile.claudeUsage else { return nil }
                return (shortName(profile.name), freeAt(usage, usingFable: usingFable, now: now))
            }
            .min { $0.at < $1.at }

        var status = AutoSwitchStatus(stuck: stuck, nextFree: nextFree, needsLogin: needsLogin, signInNeeded: signInNeeded)
        status.next = next
        status.fableBinding = usingFable
        status.activeName = activeName
        return status
    }

    /// The switcher's own answer for the current state: the hand-off target
    /// while the active account is near its limit (and proactive is on), else
    /// what the 100% path would pick; failing both, the best candidate still
    /// at a limit: the one whose limit resets first.
    static func nextSwitch(
        active: Profile, in profiles: [Profile], usingFable: Bool, proactive: Bool,
        now: Date, isLoginDead: (Profile) -> Bool
    ) -> NextSwitch {
        let usage = active.claudeUsage
        if proactive, let usage, !usage.isLimitReached(usingFable: usingFable, now: now),
           AutoSwitchPolicy.isNearLimit(usage, usingFable: usingFable, now: now),
           let target = AutoSwitchPolicy.handoffTarget(in: profiles, after: active, usingFable: usingFable, now: now, isLoginDead: isLoginDead) {
            return .ready(name: shortName(target.name), presumed: false)
        }
        // Only when Fable alone is spent does the Opus fallback keep the sessions here.
        let onlyFableSpent = usingFable && (usage.map { $0.isLimitReached(usingFable: true, now: now) && !$0.isLimitReached(now: now) } ?? false)
            && !isLoginDead(active)
        switch AutoSwitchPolicy.switchTarget(in: profiles, after: active, usingFable: usingFable,
                                             blockedBeyondFable: !onlyFableSpent, now: now, isLoginDead: isLoginDead) {
        case .profile(let p):
            return .ready(name: shortName(p.name), presumed: p.claudeUsage?.isStale(now: now) ?? true)
        case .profileWithoutFable(let p):
            return .readyWithoutFable(name: shortName(p.name), presumed: p.claudeUsage?.isStale(now: now) ?? true)
        case .noFableHeadroom:
            return .noFableHeadroom
        case .none:
            break
        }
        // Nobody can take over now: who frees first? The reset time of a spent
        // window is a recorded fact however old the reading (an account at its
        // limit accrues nothing until then), and it is where the switcher goes
        // the moment it passes (2026-10-12: matt -> littlewing at 5:10:18 PM,
        // after two hours in which nothing said so). So the EARLIEST reset is
        // named, fresh reading or not.
        let soonest = profiles
            .filter { $0.id != active.id && !$0.isPaused && !isLoginDead($0) && AutoSwitchPolicy.canBeApplied($0) }
            .compactMap { p -> (name: String, at: Date)? in
                guard let u = p.claudeUsage else { return nil }
                let at = freeAt(u, usingFable: usingFable, now: now)
                return at > now ? (shortName(p.name), at) : nil
            }
            .min(by: { $0.at < $1.at })
        if let soonest { return .limited(name: soonest.name, at: soonest.at) }
        return .none
    }

    /// One line for the status line, in every state.
    func nextLine(timeFormatter: (Date) -> String) -> String {
        let prefix = fableBinding ? "next (Fable): " : "next: "
        switch next {
        case .ready(let name, let presumed):
            return "\(prefix)\(name)\(presumed ? "?" : "") (ready)"
        case .readyWithoutFable(let name, let presumed):
            return "next (Fable): none · opus: \(name)\(presumed ? "?" : "") (ready)"
        case .noFableHeadroom:
            return "next (Fable): none · opus stays on \(activeName)"
        case .refused(let name):
            return "\(prefix)none · \(name) refused the switch"
        case .limited(let name, let at):
            return "\(prefix)\(name) · \(timeFormatter(at))"
        case .none:
            return "\(prefix)none"
        }
    }

    /// American 12-hour time (operator rule): "2:40 PM" within a day, "Sat
    /// 2:40 PM" further out.
    static func americanTime(_ date: Date, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = date.timeIntervalSince(now) < 86400 ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    /// When an account can be used again: once every limit it has exhausted has reset.
    static func freeAt(_ usage: ClaudeUsage, usingFable: Bool, now: Date) -> Date {
        var resets: [Date] = []
        if usage.effectiveSessionPercentage(now: now) >= 100 { resets.append(usage.sessionResetTime) }
        if usage.effectiveWeeklyPercentage(now: now) >= 100 { resets.append(usage.weeklyResetTime) }
        if usingFable, usage.effectiveFableWeeklyPercentage(now: now) >= 100, let reset = usage.fableWeeklyResetTime {
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
        let kind: String, name: String, at: String, presumed: Bool
        switch next {
        case .ready(let n, let p), .readyWithoutFable(let n, let p): (kind, name, at, presumed) = ("ready", n, "", p)
        case .limited(let n, let d): (kind, name, at, presumed) = ("limited", n, timeFormatter(d), false)
        case .refused(let n): (kind, name, at, presumed) = ("refused", n, "", false)
        case .noFableHeadroom, .none: (kind, name, at, presumed) = ("none", "", "", false)
        }
        return "STUCK=\(stuck ? 1 : 0)\nNEXT_FREE=\(free)\nNEEDS_LOGIN=\(needsLogin.joined(separator: ", "))\n"
            + "SIGNIN_NEEDED=\(signInNeeded.joined(separator: ", "))\n"
            + "NEXT=\(nextLine(timeFormatter: timeFormatter))\n"
            + "NEXT_KIND=\(kind)\nNEXT_NAME=\(name)\nNEXT_AT=\(at)\nNEXT_PRESUMED=\(presumed ? 1 : 0)\nNEXT_FABLE=\(fableBinding ? 1 : 0)\n"
    }
}
