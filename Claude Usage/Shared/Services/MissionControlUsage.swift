import CryptoKit
import Foundation

/// One account's usage as mission control (mc) last stored it: mc's
/// `getThroughput` `accounts[].usage` (AccountUsage). Only complete readings
/// (session AND weekly known) are kept.
struct McUsageReading: Equatable {
    let account: String
    let sampledAt: Date
    let sessionPct: Double
    let sessionResetsAt: Date?
    let weeklyPct: Double
    let weeklyResetsAt: Date?
    let fablePct: Double?
    let fableResetsAt: Date?
}

/// Usage for INACTIVE profiles from mission control.
///
/// Why: since the single refresher (0bca20c) the tracker never refreshes a
/// login it is not the sole holder of, so an inactive profile's own reading
/// ages for hours once its access token expires; refreshing stored logins was
/// shelved after three gates found logout-class paths
/// (docs/stored-login-refresh-shelved.md on fix/usage-all-accounts). mc's
/// `usage-self` lane on littlewing reads each account read-only every 5 min
/// with no refresh code at all. This file only ever READS mc over one GET; it
/// holds no login and never touches a token of any account.
///
/// Rules (each pinned by MissionControlUsageTests):
/// - an mc account is matched to a profile only when proven: the local
///   claude-rotate config names exactly one account with that mc name, its
///   email is named by no other rotate account, exactly one Anthropic profile
///   records that account email (`oauthAccountJSON.emailAddress`), and a
///   pinned profile's keychain entry is that rotate account's config dir.
///   Anything ambiguous or contradictory matches nothing;
/// - a reading is taken only when newer than the profile's own (by more than
///   `echoMargin`) and fresher than `Constants.usageStaleAfter`; its
///   `lastUpdated` is mc's sample time, never the fetch time;
/// - the active profile is never overlaid: it is read live;
/// - no config, or any fetch failure, yields no readings: today's behaviour.
enum McUsage {

    /// mc stores the tracker's own readings too (its laptop `usage` lane posts
    /// them with the tracker's own timestamp, truncated to the second). A
    /// reading within this margin of the profile's own is that echo, not news.
    static let echoMargin: TimeInterval = 1

    /// Clock skew tolerated on mc's `sampled_at` (mc itself refuses samples
    /// more than 300 s in its future).
    static let maxFutureSkew: TimeInterval = 300

    private static let accountNamePattern = try! NSRegularExpression(pattern: "^[a-z0-9][a-z0-9._-]{0,63}$")

    // MARK: - mc response

    /// `getThroughput` body -> complete readings; nil when the body is not a
    /// throughput response at all. An account listed twice is dropped (which
    /// of the two is right is unknowable).
    static func parseThroughput(_ data: Data) -> [McUsageReading]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = json["accounts"] as? [[String: Any]] else { return nil }
        var out: [McUsageReading] = []
        var seen: [String: Int] = [:]
        for a in accounts {
            guard let name = a["name"] as? String, isAccountName(name) else { continue }
            seen[name, default: 0] += 1
            guard let u = a["usage"] as? [String: Any],
                  let sampled = (u["sampled_at"] as? String).flatMap(parseDate),
                  let session = window(u["session"]), let weekly = window(u["weekly"]) else { continue }
            let fable = window(u["fable"])
            out.append(McUsageReading(account: name, sampledAt: sampled,
                                      sessionPct: session.pct, sessionResetsAt: session.resets,
                                      weeklyPct: weekly.pct, weeklyResetsAt: weekly.resets,
                                      fablePct: fable?.pct, fableResetsAt: fable?.resets))
        }
        return out.filter { seen[$0.account] == 1 }
    }

    private static func isAccountName(_ s: String) -> Bool {
        accountNamePattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func window(_ any: Any?) -> (pct: Double, resets: Date?)? {
        guard let w = any as? [String: Any], let n = w["used_pct"] as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let pct = n.doubleValue
        guard pct.isFinite, pct >= 0, pct <= 1000 else { return nil }
        return (pct, (w["resets_at"] as? String).flatMap(parseDate))
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: - Proven mapping

    struct RotateAccount: Equatable {
        let name: String
        let email: String
        /// Absolute config dir (`~` expanded), or nil when the config gives none.
        let dir: String?
    }

    static var rotateConfigURL: URL {
        Constants.ClaudePaths.homeDirectory.appendingPathComponent(".claude-rotate/config.json")
    }

    /// The claude-rotate config's accounts (`name`, `email`, `dir` only); nil
    /// when the file is not a rotate config.
    static func parseRotateConfig(_ data: Data, home: String) -> [RotateAccount]? {
        guard data.count <= 256 * 1024,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["accounts"] as? [[String: Any]] else { return nil }
        return rows.compactMap { a in
            guard let name = a["name"] as? String, isAccountName(name),
                  let email = (a["email"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !email.isEmpty else { return nil }
            var dir = a["dir"] as? String
            if let d = dir, d == "~" || d.hasPrefix("~/") { dir = home + d.dropFirst() }
            if let d = dir, !d.hasPrefix("/") { dir = nil }
            if let d = dir, d.count > 1, d.hasSuffix("/") { dir = String(d.dropLast()) }
            return RotateAccount(name: name, email: email, dir: dir)
        }
    }

    static func loadRotateConfig() -> [RotateAccount]? {
        guard let data = try? Data(contentsOf: rotateConfigURL) else { return nil }
        return parseRotateConfig(data, home: Constants.ClaudePaths.homeDirectory.path)
    }

    /// The keychain item Claude Code keeps for `CLAUDE_CONFIG_DIR=dir`
    /// (mc's `usage_self.service_name`, `claude-usage-login`'s `svc`).
    static func pinnedServiceName(forConfigDir dir: String) -> String {
        let hex = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return "Claude Code-credentials-" + hex.prefix(8)
    }

    /// The account email recorded on the profile (from Claude Code's
    /// `oauthAccount`), lowercased; nil when none. Never the display name.
    static func accountEmail(of profile: Profile) -> String? {
        guard let json = profile.oauthAccountJSON,
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let email = (obj["emailAddress"] as? String)?.trimmingCharacters(in: .whitespaces),
              !email.isEmpty else { return nil }
        return email.lowercased()
    }

    /// Profile id -> its proven mc reading. See the type comment for the rules.
    static func matchProfiles(readings: [McUsageReading], rotate: [RotateAccount],
                              profiles: [Profile]) -> [UUID: McUsageReading] {
        var nameCount: [String: Int] = [:]
        for r in readings { nameCount[r.account, default: 0] += 1 }
        var rotateByName: [String: [RotateAccount]] = [:]
        var rotateEmailCount: [String: Int] = [:]
        for a in rotate {
            rotateByName[a.name, default: []].append(a)
            rotateEmailCount[a.email.lowercased(), default: 0] += 1
        }
        var profilesByEmail: [String: [Profile]] = [:]
        for p in profiles where p.provider == .anthropic {
            if let e = accountEmail(of: p) { profilesByEmail[e, default: []].append(p) }
        }

        var out: [UUID: McUsageReading] = [:]
        for r in readings where nameCount[r.account] == 1 {
            guard let entries = rotateByName[r.account], entries.count == 1, let entry = entries.first else { continue }
            let email = entry.email.lowercased()
            guard rotateEmailCount[email] == 1,
                  let candidates = profilesByEmail[email], candidates.count == 1,
                  let profile = candidates.first else { continue }
            if let pinned = profile.customKeychainServiceName {
                // Contradictory evidence refuses: the profile reads a different login dir.
                guard let dir = entry.dir, pinnedServiceName(forConfigDir: dir) == pinned else { continue }
            }
            out[profile.id] = r
        }
        return out
    }

    // MARK: - Freshness precedence

    /// The usage to store for a profile from `reading`, or nil when the
    /// profile's own reading stands (it is newer, mc's is not fresh, or mc's
    /// is from the future). Only what mc measured is carried: per-model rows
    /// (Opus, Sonnet, Design) are left empty rather than copied from an older
    /// reading under a fresh timestamp.
    static func usage(from reading: McUsageReading, over existing: ClaudeUsage?, now: Date) -> ClaudeUsage? {
        guard reading.sampledAt <= now.addingTimeInterval(maxFutureSkew) else { return nil }
        let sampled = min(reading.sampledAt, now)
        guard now.timeIntervalSince(sampled) < Constants.usageStaleAfter else { return nil }
        if let existing, sampled.timeIntervalSince(existing.lastUpdated) <= echoMargin { return nil }

        // Same defaults the app's own parser uses when the API omits a reset time.
        let sessionReset = reading.sessionResetsAt ?? sampled.addingTimeInterval(Constants.sessionWindow)
        let weeklyReset = reading.weeklyResetsAt ?? sampled.nextMonday1259pm()
        let limit = Constants.weeklyLimit
        let fablePct = reading.fablePct ?? 0
        return ClaudeUsage(
            sessionTokensUsed: 0,
            sessionLimit: 0,
            sessionPercentage: reading.sessionPct,
            sessionResetTime: sessionReset,
            weeklyTokensUsed: Int(Double(limit) * (reading.weeklyPct / 100.0)),
            weeklyLimit: limit,
            weeklyPercentage: reading.weeklyPct,
            weeklyResetTime: weeklyReset,
            opusWeeklyTokensUsed: 0,
            opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0,
            sonnetWeeklyPercentage: 0,
            sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0,
            designWeeklyPercentage: 0,
            designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: Int(Double(limit) * (fablePct / 100.0)),
            fableWeeklyPercentage: fablePct,
            fableWeeklyResetTime: reading.fableResetsAt,
            costUsed: nil,
            costLimit: nil,
            costCurrency: nil,
            lastUpdated: sampled,
            userTimezone: existing?.userTimezone ?? .current,
            source: ClaudeUsage.sourceMissionControl
        )
    }

    struct Update: Equatable {
        let profileId: UUID
        let usage: ClaudeUsage
    }

    /// The updates to apply: proven, inactive profiles whose mc reading wins
    /// over their own.
    static func overlay(profiles: [Profile], activeProfileId: UUID?, readings: [McUsageReading],
                        rotate: [RotateAccount], now: Date) -> [Update] {
        guard !readings.isEmpty else { return [] }
        let matched = matchProfiles(readings: readings, rotate: rotate, profiles: profiles)
        return profiles.compactMap { p in
            guard p.id != activeProfileId, let r = matched[p.id],
                  let u = usage(from: r, over: p.claudeUsage, now: now) else { return nil }
            return Update(profileId: p.id, usage: u)
        }
    }
}

/// One read-only GET of mc's `getThroughput`, throttled. Every failure is "no
/// readings". The token is sent only in the Authorization header and never
/// appears in a log line or in `lastStatus`.
final class McUsageClient {

    struct Config {
        let baseURL: URL
        let token: String

        /// nil (feature off) unless both are set and the URL is https: a bearer
        /// token is never sent in clear text.
        init?(baseURL: String, token: String) {
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while b.hasSuffix("/") { b.removeLast() }
            guard !t.isEmpty, !t.contains(where: { $0.isWhitespace || $0.isNewline }),
                  let url = URL(string: b), url.scheme?.lowercased() == "https", url.host != nil,
                  url.query == nil, url.user == nil, url.password == nil else { return nil }
            self.baseURL = url
            self.token = t
        }

        var throughputURL: URL? {
            URL(string: baseURL.absoluteString + "/v1/throughput?window=1h")
        }
    }

    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    static let shared = McUsageClient()

    private let transport: Transport
    private let log: (String) -> Void
    private let minInterval: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var lastAttempt: Date?
    private var lastReadings: [McUsageReading] = []
    private var _lastStatus = "Not configured"

    static let maxBodyBytes = 1_048_576

    init(transport: Transport? = nil, log: @escaping (String) -> Void = { LoggingService.shared.log($0) },
         minInterval: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.transport = transport ?? McUsageClient.urlSessionTransport
        self.log = log
        self.minInterval = minInterval
        self.now = now
    }

    /// Short human status for Settings (never holds the token).
    var lastStatus: String {
        lock.lock(); defer { lock.unlock() }
        return _lastStatus
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 15
        c.httpCookieStorage = nil
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static let urlSessionTransport: Transport = { request in
        try await session.data(for: request)
    }

    /// mc's readings, or [] when unconfigured or the fetch fails. Within
    /// `minInterval` of the last attempt, the last attempt's outcome is reused
    /// (a failure stays a failure: [] — never an older success).
    func fetchReadings(config: Config?) async -> [McUsageReading] {
        guard let config, let url = config.throughputURL else {
            set(status: "Not configured", readings: [], at: nil)
            return []
        }
        let t = now()
        lock.lock()
        if let last = lastAttempt, t.timeIntervalSince(last) < minInterval, t >= last {
            let cached = lastReadings
            lock.unlock()
            return cached
        }
        lastAttempt = t
        lock.unlock()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let outcome: String
        var readings: [McUsageReading] = []
        do {
            let (data, response) = try await transport(request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode != 200 {
                    outcome = "Mission control answered HTTP \(http.statusCode)"
                } else if data.count > Self.maxBodyBytes {
                    outcome = "Mission control response too large"
                } else if let parsed = McUsage.parseThroughput(data) {
                    readings = parsed
                    outcome = "OK: \(parsed.count) account reading\(parsed.count == 1 ? "" : "s")"
                } else {
                    outcome = "Mission control response was not usage data"
                }
            } else {
                outcome = "Mission control response was not HTTP"
            }
        } catch let error as URLError {
            // The code only: a URLError's text can carry the URL, never the header.
            outcome = "Mission control unreachable (URLError \(error.code.rawValue))"
        } catch {
            outcome = "Mission control request failed"   // never the error's own text
        }
        set(status: outcome, readings: readings, at: t)
        log("McUsageClient: \(outcome)")
        return readings
    }

    private func set(status: String, readings: [McUsageReading], at: Date?) {
        lock.lock(); defer { lock.unlock() }
        _lastStatus = status
        lastReadings = readings
        if at == nil { lastAttempt = nil }
    }
}
