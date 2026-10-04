import Foundation

/// Remembers refresh tokens the OAuth server has rejected for good.
///
/// A rejected refresh token never recovers: only a new `/login` (which writes
/// a different token) fixes the profile. Retrying it on every refresh cycle is
/// pointless, and hammering the token endpoint with a consumed token risks the
/// server revoking the whole login. Keyed by the token itself, so a re-login
/// is picked up with no explicit reset.
final class DeadLoginTracker {

    private var deadTokens: Set<String> = []
    private let lock = NSLock()

    /// True when a failed refresh means the refresh token itself is dead, as
    /// opposed to a transient failure (offline, 5xx, rate limit).
    static func isInvalidGrant(status: Int, body: String) -> Bool {
        (status == 400 || status == 401) && body.contains("invalid_grant")
    }

    func markDead(_ refreshToken: String) {
        lock.lock(); defer { lock.unlock() }
        deadTokens.insert(refreshToken)
    }

    func isDead(_ refreshToken: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deadTokens.contains(refreshToken)
    }

    /// True when nothing has been marked dead, so callers can skip the
    /// keychain reads needed to collect a profile's tokens.
    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return deadTokens.isEmpty
    }

    /// A login is dead when every refresh token it could use is dead. A login
    /// with no refresh tokens at all (session-key-only) is not judged here.
    func isLoginDead(refreshTokens: [String]) -> Bool {
        !refreshTokens.isEmpty && refreshTokens.allSatisfy(isDead)
    }
}
