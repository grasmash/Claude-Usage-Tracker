import CryptoKit
import Foundation

/// Remembers refresh tokens the OAuth server has rejected for good.
///
/// A rejected refresh token never recovers: only a new `/login` (which writes
/// a different token) fixes the profile. Retrying it on every refresh cycle is
/// pointless, and hammering the token endpoint with a consumed token risks the
/// server revoking the whole login. Keyed by the token itself, so a re-login
/// is picked up with no explicit reset.
///
/// With a `storeURL` the set survives restarts, so a dead login stays visible
/// (to auto-switch and the status line) after the app relaunches. Only SHA-256
/// digests of tokens are kept, never the tokens.
final class DeadLoginTracker {

    private var deadTokens: Set<String> = []
    private let lock = NSLock()
    private let storeURL: URL?

    init(storeURL: URL? = nil) {
        self.storeURL = storeURL
        if let storeURL,
           let data = try? Data(contentsOf: storeURL),
           let digests = try? JSONDecoder().decode([String].self, from: data) {
            deadTokens = Set(digests)
        }
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func save() {
        guard let storeURL, let data = try? JSONEncoder().encode(deadTokens.sorted()) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: [.atomic])
    }

    /// True when a failed refresh means the refresh token itself is dead, as
    /// opposed to a transient failure (offline, 5xx, rate limit).
    static func isInvalidGrant(status: Int, body: String) -> Bool {
        (status == 400 || status == 401) && body.contains("invalid_grant")
    }

    func markDead(_ refreshToken: String) {
        lock.lock(); defer { lock.unlock() }
        guard deadTokens.insert(Self.digest(refreshToken)).inserted else { return }
        save()
    }

    func isDead(_ refreshToken: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deadTokens.contains(Self.digest(refreshToken))
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
