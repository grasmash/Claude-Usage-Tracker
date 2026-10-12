import Foundation

/// Remembers, per switch target, that the shared-login swap keeps being
/// refused, so that:
/// - a target whose refusal cannot clear by itself (`untrustedStoredLogin`,
///   `notTheSharedLoginEntry`) is not picked again every tick
///   (`isUnavailable`), which repeated the attempt and its notification;
/// - the user is told ONCE per episode (`record` returns true): at once for a
///   non-retryable refusal, after `repeatsBeforeNotice` ticks for one that is
///   retried;
/// - the status line stops saying "next: X (ready)" for it (`isRefusing`).
///
/// An episode ends when the swap succeeds or the target's stored login
/// changes (a re-import). A non-retryable target is tried again after
/// `hold`, quietly, in case whatever refused it was fixed.
struct SwitchRefusalTracker {
    static let repeatsBeforeNotice = 3
    static let hold: TimeInterval = 3600

    private struct Entry {
        var nonRetryable: Bool
        var count: Int
        var loginFingerprint: String?
        var lastAt: Date
        var notified: Bool
    }
    private var entries: [UUID: Entry] = [:]

    /// Returns true when the user should be told about this refusal now.
    mutating func record(
        _ outcome: ClaudeCodeSyncService.MainLoginSwitch, target: UUID, loginFingerprint: String?, now: Date = Date()
    ) -> Bool {
        guard case .refused(let refusal) = outcome else {
            entries[target] = nil
            return false
        }
        var entry = entries[target].flatMap { $0.loginFingerprint == loginFingerprint ? $0 : nil }
            ?? Entry(nonRetryable: false, count: 0, loginFingerprint: loginFingerprint, lastAt: now, notified: false)
        entry.count += 1
        entry.lastAt = now
        entry.nonRetryable = entry.nonRetryable || !MainLoginSwapPolicy.isRetryable(refusal)
        let tell = !entry.notified && (entry.nonRetryable || entry.count >= Self.repeatsBeforeNotice)
        if tell { entry.notified = true }
        entries[target] = entry
        return tell
    }

    private func current(_ target: UUID, _ loginFingerprint: String?, _ now: Date) -> Entry? {
        guard let entry = entries[target], entry.loginFingerprint == loginFingerprint,
              now.timeIntervalSince(entry.lastAt) < Self.hold else { return nil }
        return entry
    }

    /// Not a switch target now: its refusal will not clear by itself.
    func isUnavailable(_ target: UUID, loginFingerprint: String?, now: Date = Date()) -> Bool {
        current(target, loginFingerprint, now)?.nonRetryable ?? false
    }

    /// Keeps refusing (non-retryable, or retried `repeatsBeforeNotice` times):
    /// not "ready" as far as the status line is concerned.
    func isRefusing(_ target: UUID, loginFingerprint: String?, now: Date = Date()) -> Bool {
        guard let entry = current(target, loginFingerprint, now) else { return false }
        return entry.nonRetryable || entry.count >= Self.repeatsBeforeNotice
    }
}
