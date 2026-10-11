//
//  ClaudeCodeSyncService.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Security
import CryptoKit

/// Manages synchronization of Claude Code CLI credentials between system Keychain and profiles
class ClaudeCodeSyncService {
    static let shared = ClaudeCodeSyncService()

    /// Cached resolved keychain service name (in-memory, cleared per app session)
    private var resolvedServiceName: String?

    /// UserDefaults key for persisting the last successfully resolved hashed service name
    /// so we don't re-run the expensive `security dump-keychain` on every launch.
    private static let persistedServiceNameKey = "ClaudeCodeSyncService.resolvedServiceName"

    /// UserDefaults key marking that hashed-name discovery has already been attempted
    /// once on this machine. When set, we avoid `security dump-keychain` on launch.
    private static let discoveryAttemptedKey = "ClaudeCodeSyncService.discoveryAttempted"

    /// Timeout for blocking `/usr/bin/security` invocations. macOS 26.3.x has been
    /// observed to hang indefinitely on `security` subprocesses in some environments
    /// (see issue #179), so every shell-out is bounded to avoid deadlocking launch.
    private static let securityCommandTimeout: TimeInterval = 3.0

    private init() {}

    // MARK: - Seams (replaceable in tests)

    /// Runs `/usr/bin/security`. Tests replace this to observe every keychain
    /// read and write without a keychain. The default refuses mutating verbs
    /// under tests, so a test can never touch the user's real login.
    var securityCommandRunner: (_ arguments: [String], _ timeout: TimeInterval) -> SecurityCommandResult? = { arguments, timeout in
        if AppEnvironment.isRunningTests, ClaudeCodeSyncService.isMutatingSecurityVerb(arguments.first) {
            return SecurityCommandResult(exitCode: -1, stdout: "", stderr: "keychain writes are disabled while running tests", timedOut: false)
        }
        return ClaudeCodeSyncService.runSecurityProcess(arguments: arguments, timeout: timeout)
    }

    /// Posts the `refresh_token` grant. Tests replace this to prove a path
    /// makes no network call. The default refuses under tests: refresh tokens
    /// are single-use, so a refresh from a test run would log out whoever
    /// holds that login.
    var tokenRefresher: (_ refreshToken: String) async throws -> OAuthRefreshResponse = { refreshToken in
        guard !AppEnvironment.isRunningTests else {
            throw ClaudeCodeError.refreshFailed(status: 0, body: "token refresh disabled while running tests")
        }
        return try await ClaudeCodeSyncService.postTokenRefresh(refreshToken: refreshToken)
    }

    /// The processes running now, for `MainLoginSwapPolicy`. Tests supply a list.
    var runningProcesses: () -> [MainLoginSwapPolicy.RunningProcess] = {
        ClaudeCodeSyncService.listRunningProcesses()
    }

    static func isMutatingSecurityVerb(_ verb: String?) -> Bool {
        guard let verb else { return false }
        return verb.hasPrefix("add-") || verb.hasPrefix("delete-") || verb.hasPrefix("set-")
            || verb == "import" || verb == "unlock-keychain"
    }

    /// `ps -axwwE`: every process with its arguments and environment.
    static func listRunningProcesses() -> [MainLoginSwapPolicy.RunningProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axwwE", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            LoggingService.shared.logError("listRunningProcesses: could not run ps", error: error)
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [] }
        return MainLoginSwapPolicy.parsePsOutput(text)
    }

    // MARK: - Cached Availability Check

    /// Refresh tokens the OAuth server has rejected with `invalid_grant`.
    let deadLogins = DeadLoginTracker(storeURL: AppEnvironment.isRunningTests ? nil :
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Claude Usage/dead-logins.json"))

    /// Cached result of the "are usable system CLI credentials present?" check.
    /// Keychain access is a blocking XPC round-trip, and UI render paths
    /// (updateAllButtons, popover gating) ask this on every repaint.
    private var systemCredsUsableCache: (value: Bool, checkedAt: Date)?
    private static let systemCredsCacheMaxAge: TimeInterval = 15

    /// Returns whether the system keychain/credentials file holds a
    /// non-expired CLI token, caching the answer briefly so hot render
    /// paths don't hit the keychain on every call.
    func hasUsableSystemCredentials() -> Bool {
        if let cached = systemCredsUsableCache,
           Date().timeIntervalSince(cached.checkedAt) < Self.systemCredsCacheMaxAge {
            return cached.value
        }

        var usable = false
        do {
            if let creds = try readSystemCredentials(),
               !isTokenExpired(creds),
               extractAccessToken(from: creds) != nil {
                usable = true
            }
        } catch {
            LoggingService.shared.log("hasUsableSystemCredentials: system keychain check failed: \(error.localizedDescription)")
        }

        systemCredsUsableCache = (usable, Date())
        return usable
    }

    /// Drops the cached availability answer (call after syncs/logins that
    /// change the keychain state).
    func invalidateSystemCredentialsCache() {
        systemCredsUsableCache = nil
    }

    // MARK: - System Credentials Access (Fallback Chain)

    /// Reads Claude Code credentials using a fallback chain:
    /// 1. ~/.claude/.credentials.json (always complete, not subject to keychain truncation)
    /// 2. System Keychain (may be truncated for large payloads >2KB)
    /// 3. Regex extraction of accessToken from truncated keychain data (last resort)
    func readSystemCredentials() throws -> String? {
        // The KEYCHAIN is authoritative: on macOS Claude Code rotates tokens there
        // and nowhere else. `.credentials.json` is only consulted when there is no
        // keychain item at all (a Linux-style or file-only install). Earlier builds
        // picked whichever source expired later, which let a stale plaintext mirror
        // this app once wrote shadow the live login.
        var keychainJSON: String?
        let rawKeychain: String?
        do {
            rawKeychain = try readKeychainCredentials()
        } catch {
            // A read error is fatal only when there is no file to fall back to.
            guard let file = readCredentialsFile() else { throw error }
            LoggingService.shared.log("Read credentials from .credentials.json file (keychain unreadable)")
            return file
        }
        if let rawJSON = rawKeychain {
            if let data = rawJSON.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil {
                keychainJSON = rawJSON
            } else {
                // Validate JSON; fall back to regex extraction for truncated payloads.
                LoggingService.shared.log("Keychain JSON is invalid (likely truncated), attempting regex extraction")
                if let token = extractAccessTokenViaRegex(from: rawJSON) {
                    keychainJSON = "{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}"
                    LoggingService.shared.log("Built minimal credentials from regex-extracted token")
                } else {
                    throw ClaudeCodeError.invalidJSON
                }
            }
        }
        if let keychainJSON {
            return keychainJSON
        }
        guard let file = readCredentialsFile() else { return nil }
        LoggingService.shared.log("Read credentials from .credentials.json file (no keychain entry)")
        return file
    }

    // MARK: - Private Credential Sources

    /// Reads credentials from ~/.claude/.credentials.json or ~/.claude/credentials.json file
    private func readCredentialsFile() -> String? {
        let paths = [
            credentialsFileURL,
            credentialsFileURL.deletingLastPathComponent().appendingPathComponent("credentials.json")
        ]

        for fileURL in paths {
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else {
                LoggingService.shared.log("credentials file exists but could not be read: \(fileURL.lastPathComponent)")
                continue
            }

            // Validate it's actually valid JSON
            guard let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                LoggingService.shared.log("credentials file contains invalid JSON: \(fileURL.lastPathComponent)")
                continue
            }

            LoggingService.shared.log("Read credentials from \(fileURL.lastPathComponent)")
            return jsonString
        }

        return nil
    }

    /// Result of a bounded `/usr/bin/security` invocation.
    struct SecurityCommandResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    /// Runs `/usr/bin/security` through `securityCommandRunner`.
    private func runSecurityCommand(
        arguments: [String],
        timeout: TimeInterval = ClaudeCodeSyncService.securityCommandTimeout
    ) -> SecurityCommandResult? {
        securityCommandRunner(arguments, timeout)
    }

    /// Runs `/usr/bin/security` with the given arguments and a hard timeout.
    /// If the timeout elapses, the subprocess is terminated and `timedOut` is true.
    /// This is critical: without the timeout, a hung `security` call blocks the
    /// calling thread (and, if called from main, the whole app) indefinitely.
    private static func runSecurityProcess(
        arguments: [String],
        timeout: TimeInterval
    ) -> SecurityCommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            LoggingService.shared.log("runSecurityCommand: failed to launch security: \(error.localizedDescription)")
            return nil
        }

        // Wait for the process with a hard deadline. DispatchGroup lets us block
        // the current thread up to `timeout` seconds, then terminate if still running.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            group.leave()
        }

        let waitResult = group.wait(timeout: .now() + timeout)
        if waitResult == .timedOut {
            LoggingService.shared.log("runSecurityCommand: TIMEOUT after \(timeout)s, terminating security subprocess (args: \(arguments.prefix(2).joined(separator: " ")))")
            process.terminate()
            // Give it a brief moment to die, then force-kill if needed
            _ = group.wait(timeout: .now() + 0.5)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return SecurityCommandResult(exitCode: -1, stdout: "", stderr: "timeout", timedOut: true)
        }

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        return SecurityCommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: false
        )
    }

    /// Reads Claude Code credentials from system Keychain using security command
    private func readKeychainCredentials() throws -> String? {
        let serviceName = resolveServiceName()
        guard let result = runSecurityCommand(arguments: [
            "find-generic-password",
            "-s", serviceName,
            "-a", NSUserName(),
            "-w"  // Print password only
        ]) else {
            // Failed to launch security — treat as "no credentials"
            return nil
        }

        if result.timedOut {
            LoggingService.shared.log("readKeychainCredentials: security command timed out")
            return nil
        }

        let exitCode = result.exitCode

        if exitCode == 0 {
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } else if exitCode == 44 {
            // Exit code 44 = item not found
            return nil
        } else {
            LoggingService.shared.log("Failed to read keychain: \(result.stderr)")
            throw ClaudeCodeError.keychainReadFailed(status: OSStatus(exitCode))
        }
    }

    /// Extracts accessToken from potentially truncated JSON using regex
    private func extractAccessTokenViaRegex(from rawString: String) -> String? {
        let pattern = "\"accessToken\"\\s*:\\s*\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: rawString, range: NSRange(rawString.startIndex..., in: rawString)),
              let tokenRange = Range(match.range(at: 1), in: rawString) else {
            return nil
        }
        return String(rawString[tokenRange])
    }

    // MARK: - Keychain Service Name Discovery

    private static let legacyServiceName = "Claude Code-credentials"

    /// Resolves the correct keychain service name for Claude Code credentials.
    /// Claude Code v2.1.52+ changed from "Claude Code-credentials" to
    /// "Claude Code-credentials-HASH".
    ///
    /// Resolution order (each step is bounded by `securityCommandTimeout`):
    /// 1. In-memory cache
    /// 2. UserDefaults-persisted name from a previous successful resolution
    /// 3. Legacy name probe (`find-generic-password`)
    /// 4. Hashed-name discovery (`dump-keychain`) — only if discovery has not
    ///    been attempted before OR the caller explicitly forced a retry
    ///
    /// Important: `security dump-keychain` is the call most prone to hanging
    /// on macOS 26.3.x (see #179), so we persist a "discovery attempted" flag
    /// and never re-run it on subsequent launches unless the cache is invalidated.
    private func resolveServiceName() -> String {
        if let cached = resolvedServiceName {
            return cached
        }

        // Honor any previously persisted resolution — this avoids the expensive
        // `dump-keychain` shell-out on every launch after the first.
        if let persisted = UserDefaults.standard.string(forKey: Self.persistedServiceNameKey),
           !persisted.isEmpty {
            resolvedServiceName = persisted
            return persisted
        }

        // Try legacy name first (fast path, bounded by timeout)
        if keychainItemExists(serviceName: Self.legacyServiceName) {
            persistResolvedServiceName(Self.legacyServiceName)
            return Self.legacyServiceName
        }

        // Only run the (potentially slow/hanging) hashed-name discovery ONCE
        // per machine. If we've already tried and failed, default to the legacy
        // name and let downstream callers handle the "no credentials" case.
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.discoveryAttemptedKey) {
            resolvedServiceName = Self.legacyServiceName
            return Self.legacyServiceName
        }

        // First-time discovery attempt — mark as attempted BEFORE running so that
        // even if the command hangs and gets force-terminated by the timeout,
        // we won't retry it on the next launch.
        defaults.set(true, forKey: Self.discoveryAttemptedKey)

        if let hashedName = findHashedServiceName() {
            persistResolvedServiceName(hashedName)
            LoggingService.shared.log("Resolved hashed keychain service name: \(hashedName)")
            return hashedName
        }

        // Default to legacy name (will fail gracefully if not found)
        resolvedServiceName = Self.legacyServiceName
        return Self.legacyServiceName
    }

    /// Persists a successfully resolved service name to UserDefaults and in-memory cache.
    private func persistResolvedServiceName(_ name: String) {
        resolvedServiceName = name
        UserDefaults.standard.set(name, forKey: Self.persistedServiceNameKey)
    }

    /// Checks if a keychain item exists with the given service name, bounded by
    /// `securityCommandTimeout` so a hung `security` process can't block the caller.
    private func keychainItemExists(serviceName: String) -> Bool {
        guard let result = runSecurityCommand(arguments: [
            "find-generic-password", "-s", serviceName, "-a", NSUserName()
        ]) else {
            return false
        }
        if result.timedOut {
            LoggingService.shared.log("keychainItemExists: security command timed out for service '\(serviceName)'")
            return false
        }
        return result.exitCode == 0
    }

    /// Human-readable summary of a keychain entry, used to label the picker so the user
    /// doesn't have to memorize raw hashes.
    struct KeychainEntryDescription {
        let serviceName: String
        let emailAddress: String?
        let organizationName: String?
        let subscriptionType: String?

        /// Picker label combining the most identifying info available with the
        /// keychain svc shorthand so two similarly-described accounts stay distinct.
        var displayLabel: String {
            let svcShort: String
            if serviceName == "Claude Code-credentials" {
                svcShort = "default"
            } else if serviceName.hasPrefix("Claude Code-credentials-") {
                svcShort = String(serviceName.dropFirst("Claude Code-credentials-".count))
            } else {
                svcShort = serviceName
            }

            if let email = emailAddress {
                if let org = organizationName, !org.isEmpty {
                    return "\(email) — \(org) · \(svcShort)"
                }
                return "\(email) · \(svcShort)"
            }
            if let sub = subscriptionType, !sub.isEmpty {
                return "\(svcShort) — \(sub)"
            }
            return serviceName
        }
    }

    /// Builds a `KeychainEntryDescription` for the given service name. Tries to enrich
    /// the raw hash with human-readable info by:
    /// 1. Reading the keychain payload for `subscriptionType` + `organizationUuid`
    /// 2. Matching that organizationUuid against any of `knownProfiles`' `oauthAccountJSON`
    ///    to recover `emailAddress` + `organizationName`
    /// 3. If still unknown, consulting `accountMap` (built once via
    ///    `discoverAccountLabels()`) which derives hashes from local `.claude*` dirs.
    /// Returns a description that always at least falls back to a sensible svc shorthand.
    func describeKeychainEntry(
        serviceName: String,
        knownProfiles: [Profile],
        accountMap: [String: (email: String, organizationName: String?)] = [:]
    ) -> KeychainEntryDescription {
        var subscription: String?
        var orgUuid: String?

        if let payload = readKeychainCredentials(serviceName: serviceName),
           let data = payload.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? [:]
            subscription = oauth["subscriptionType"] as? String
            orgUuid = (root["organizationUuid"] as? String) ?? (oauth["organizationUuid"] as? String)
        }

        var email: String?
        var orgName: String?
        if let orgUuid = orgUuid {
            for profile in knownProfiles {
                guard let json = profile.oauthAccountJSON,
                      let d = json.data(using: .utf8),
                      let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      (r["organizationUuid"] as? String) == orgUuid else {
                    continue
                }
                email = r["emailAddress"] as? String
                orgName = r["organizationName"] as? String
                break
            }
        }

        // Fall back to the path-derived account map (covers entries whose keychain
        // payload doesn't carry an organizationUuid — newer Claude Code schemas).
        if email == nil, let mapped = accountMap[serviceName] {
            email = mapped.email
            orgName = mapped.organizationName
        }

        return KeychainEntryDescription(
            serviceName: serviceName,
            emailAddress: email,
            organizationName: orgName,
            subscriptionType: subscription
        )
    }

    /// Discovers a `keychain-svc → (email, org)` mapping by walking the user's home
    /// directory for `.claude` and `.claude-*` config dirs, reading each one's
    /// `.claude.json` `oauthAccount`, and computing the keychain hash Claude Code
    /// derives from each directory path.
    ///
    /// Reverse-engineered fact (validated against live entries): for any non-default
    /// CLAUDE_CONFIG_DIR, Claude Code stores credentials under
    /// `Claude Code-credentials-<SHA256(absolute path)[:8]>`. The default `~/.claude`
    /// maps to the unsuffixed `Claude Code-credentials` entry.
    ///
    /// This is the best path-independent way to label a keychain entry when its
    /// payload doesn't include an organizationUuid (no token data is ever read here —
    /// only `.claude.json` `oauthAccount` metadata, which is plain user identity info).
    func discoverAccountLabels() -> [String: (email: String, organizationName: String?)] {
        var labels: [String: (email: String, organizationName: String?)] = [:]
        let fm = FileManager.default
        let homeURL = fm.homeDirectoryForCurrentUser
        let homePath = homeURL.path

        var candidates: [String] = ["\(homePath)/.claude"]
        if let entries = try? fm.contentsOfDirectory(atPath: homePath) {
            for name in entries where name.hasPrefix(".claude-") {
                candidates.append("\(homePath)/\(name)")
            }
        }

        for dir in candidates {
            let configFile = "\(dir)/.claude.json"
            guard fm.fileExists(atPath: configFile),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: configFile)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oa = root["oauthAccount"] as? [String: Any],
                  let email = oa["emailAddress"] as? String else {
                continue
            }
            let orgName = oa["organizationName"] as? String

            let svc: String
            if dir == "\(homePath)/.claude" {
                svc = "Claude Code-credentials"
            } else {
                let hash = sha256HexPrefix(dir, length: 8)
                svc = "Claude Code-credentials-\(hash)"
            }
            labels[svc] = (email, orgName)
        }
        return labels
    }

    // internal (not private) so unit tests can pin the live-validated hash algorithm.
    func sha256HexPrefix(_ s: String, length: Int) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }

    /// Enumerates every Claude Code credentials keychain item — both the legacy
    /// unsuffixed `Claude Code-credentials` entry and all hash-suffix variants
    /// (`Claude Code-credentials-<HASH>`). Used by the Advanced settings UI so the
    /// user can pick the exact entry to pin a profile to.
    ///
    /// Uses `SecItemCopyMatching` (Security.framework) instead of shelling out to
    /// `security dump-keychain` — the shell tool requires broad keychain-access
    /// authorization and on macOS 26.x has been observed to hang indefinitely when
    /// invoked from a background-app context where the keychain prompt cannot be
    /// presented. The Security API is fast, doesn't spawn a subprocess, and only
    /// returns attributes for items the app is already entitled to read.
    func listClaudeCodeKeychainServices() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                LoggingService.shared.log("listClaudeCodeKeychainServices: SecItemCopyMatching failed (status=\(status))")
            }
            return []
        }
        guard let items = result as? [[String: Any]] else { return [] }

        let prefix = "Claude Code-credentials"
        var found: Set<String> = []
        for item in items {
            guard let name = item[kSecAttrService as String] as? String else { continue }
            if name == prefix || name.hasPrefix("\(prefix)-") {
                found.insert(name)
            }
        }
        return found.sorted()
    }

    /// Searches the keychain for a hashed service name matching "Claude Code-credentials-*".
    /// This uses `security dump-keychain` which can be slow or hang on some macOS
    /// versions, so it is bounded by a longer timeout and only called once per machine.
    private func findHashedServiceName() -> String? {
        // `dump-keychain` enumerates every keychain item and can be slow on large
        // keychains; give it a slightly more generous budget than other commands
        // but still a hard ceiling to prevent indefinite hangs.
        guard let result = runSecurityCommand(arguments: ["dump-keychain"], timeout: 5.0) else {
            return nil
        }

        if result.timedOut {
            LoggingService.shared.log("findHashedServiceName: `security dump-keychain` timed out — falling back to legacy name")
            return nil
        }

        guard result.exitCode == 0 else { return nil }

        let output = result.stdout
        let prefix = "Claude Code-credentials-"

        // Parse service names from dump-keychain output (format: "svce"<blob>="ServiceName")
        for line in output.components(separatedBy: "\n") {
            guard line.contains("\"svce\""), line.contains(prefix) else { continue }
            // Extract the value between quotes after the =
            if let equalsRange = line.range(of: "=\""),
               let endQuoteRange = line.range(of: "\"", range: equalsRange.upperBound..<line.endIndex) {
                let name = String(line[equalsRange.upperBound..<endQuoteRange.lowerBound])
                if name.hasPrefix(prefix) {
                    return name
                }
            }
        }
        return nil
    }

    /// Invalidates the cached service name, forcing re-discovery on next access.
    /// This also clears the persisted resolution and the discovery-attempted flag
    /// so a subsequent call will re-run the full resolution chain.
    func invalidateServiceNameCache() {
        resolvedServiceName = nil
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Self.persistedServiceNameKey)
        defaults.removeObject(forKey: Self.discoveryAttemptedKey)
    }

    /// The plaintext mirror `~/.claude/.credentials.json`, which earlier builds
    /// rewrote on every switch. The tracker no longer writes credentials to it:
    /// on macOS Claude Code keeps its login in the keychain and uses the file's
    /// modification time only as a reload signal (`signalCredentialsReload`).
    /// Copying keychain secrets to plaintext on disk bought nothing. Replaceable
    /// so tests can prove the file is left alone.
    var credentialsFileURL: URL = Constants.ClaudePaths.credentialsFile

    /// Writes Claude Code's shared login (the main keychain entry) in place with
    /// a single `add-generic-password -U`. Never delete-then-add: that left the
    /// entry momentarily empty or half-written for any session reading it.
    ///
    /// Only `switchMainLogin(to:)` calls this, after `MainLoginSwapPolicy` has
    /// confirmed nothing holds the login being replaced.
    func writeSystemCredentials(_ jsonData: String) throws {
        let serviceName = resolveServiceName()
        LoggingService.shared.log("Writing the shared Claude Code login in place (service: \(serviceName))")
        try writeKeychainCredentials(serviceName: serviceName, jsonData: jsonData)
    }

    // MARK: - Claude Code Config File (oauthAccount)

    /// Finds the actual `.claude.json` file path on disk by probing the known
    /// candidate locations. Returns nil if none exist.
    private func locateClaudeConfigFile() -> URL? {
        for candidate in Constants.ClaudePaths.claudeConfigCandidates
        where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }

    /// Reads the `oauthAccount` object from Claude Code's `.claude.json` config
    /// file and returns it as a serialized JSON string. Returns nil if the file
    /// does not exist, is unreadable, or has no `oauthAccount` field.
    ///
    /// Storing the object as a raw JSON string (rather than a typed struct)
    /// preserves unknown/future fields — Claude Code may add new keys over time,
    /// and we want to faithfully round-trip whatever is present.
    func readOAuthAccount() -> String? {
        guard let url = locateClaudeConfigFile() else {
            LoggingService.shared.log("readOAuthAccount: no .claude.json config file found")
            return nil
        }

        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauthAccount = root["oauthAccount"] as? [String: Any] else {
            return nil
        }

        guard let serialized = try? JSONSerialization.data(
            withJSONObject: oauthAccount,
            options: [.sortedKeys]
        ),
              let jsonString = String(data: serialized, encoding: .utf8) else {
            LoggingService.shared.log("readOAuthAccount: failed to serialize oauthAccount object")
            return nil
        }

        return jsonString
    }

    /// Extracts a stable account identity from an `oauthAccount` JSON string.
    /// Prefers `accountUuid` (stable across logins), falls back to `emailAddress`.
    /// Returns nil if the JSON is missing or has neither field.
    func accountIdentity(fromOAuthAccountJSON json: String?) -> String? {
        guard let json = json,
              let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let uuid = obj["accountUuid"] as? String, !uuid.isEmpty { return uuid }
        if let email = obj["emailAddress"] as? String, !email.isEmpty { return email }
        return nil
    }

    /// Writes an `oauthAccount` object (serialized JSON string) back into
    /// Claude Code's `.claude.json` config file, replacing whatever was there.
    /// Preserves all other top-level keys in the file. Does nothing if no
    /// `.claude.json` file exists (we don't want to create a file from scratch
    /// and accidentally overwrite user settings).
    func writeOAuthAccount(_ oauthAccountJSON: String) throws {
        // Never touch the user's real .claude.json from a test run.
        guard !AppEnvironment.isRunningTests else { return }
        guard let url = locateClaudeConfigFile() else {
            LoggingService.shared.log("writeOAuthAccount: no .claude.json config file found — skipping write")
            return
        }

        // Parse the stored oauthAccount string
        guard let newAccountData = oauthAccountJSON.data(using: .utf8),
              let newAccount = try? JSONSerialization.jsonObject(with: newAccountData) as? [String: Any] else {
            LoggingService.shared.log("writeOAuthAccount: stored oauthAccount JSON is invalid, skipping")
            throw ClaudeCodeError.invalidJSON
        }

        // Read + merge existing file (preserve all other top-level keys)
        let existingData = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            LoggingService.shared.log("writeOAuthAccount: .claude.json root is not a JSON object")
            throw ClaudeCodeError.invalidJSON
        }

        root["oauthAccount"] = newAccount

        // Pretty-print to match Claude Code's on-disk format (best-effort)
        let updatedData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        // Atomic write so a crash mid-write can't corrupt the file
        try updatedData.write(to: url, options: [.atomic])
        LoggingService.shared.log("✓ Updated oauthAccount in \(url.lastPathComponent)")
    }

    // MARK: - Profile Sync Operations

    /// Syncs credentials from system to profile (one-time copy)
    func syncToProfile(_ profileId: UUID) throws {
        guard let jsonData = try readSystemCredentials() else {
            throw ClaudeCodeError.noCredentialsFound
        }

        // Validate JSON format
        guard let data = jsonData.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeCodeError.invalidJSON
        }

        // Capture current oauthAccount from .claude.json (if present) so we can
        // restore it when this profile is re-activated. See issue #175.
        let capturedOAuthAccount = loginOAuthAccount(credentials: jsonData, configOAuthAccount: readOAuthAccount())

        // Save to profile directly
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ClaudeCodeError.noProfileCredentials
        }

        profiles[index].cliCredentialsJSON = jsonData
        profiles[index].hasOwnMainLogin = isOwnMainLogin(jsonData, for: profiles[index])
        if let capturedOAuthAccount = capturedOAuthAccount {
            profiles[index].oauthAccountJSON = capturedOAuthAccount
        }
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Synced CLI credentials to profile: \(profileId)\(capturedOAuthAccount != nil ? " (with oauthAccount)" : "")")
    }

    /// Outcome of `switchMainLogin(to:)`.
    enum MainLoginSwitch: Equatable {
        /// The shared login was written. `racedHolders` is how many Claude Code
        /// processes on the shared login were found in a re-scan right after
        /// the write: normally 0; more means one started in the window between
        /// the scan and the write and may hold the login that was replaced.
        case applied(racedHolders: Int)
        /// The keychain already held this profile's login; nothing was written.
        case alreadyApplied
        /// Not done, for a reason the policy names. Retry on a later cycle.
        case refused(MainLoginSwapPolicy.Refusal)
    }

    /// Serialises `switchMainLogin`: two overlapping switches would be two
    /// refreshes of one stored login, or two writes racing each other.
    private let switchMutex = AsyncMutex()

    /// Only for tests: pins the resolved service name so a test never runs
    /// the real resolution chain (which persists to `UserDefaults.standard`).
    func setResolvedServiceNameForTesting(_ name: String?) {
        resolvedServiceName = name
    }

    /// The hash Claude Code derives from the default config dir for its
    /// keychain entry name (`Claude Code-credentials-<hash>`).
    var defaultClaudeDirectoryHash: String {
        sha256HexPrefix(Constants.ClaudePaths.claudeDirectory.path, length: 8)
    }

    /// Makes `profile`'s stored main login the shared Claude Code login — the
    /// one `claude` sessions started without `CLAUDE_CONFIG_DIR` use — when,
    /// and only when, that is safe:
    ///
    /// 1. No Claude Code process is running on the shared login. Every such
    ///    process holds the login in memory; swapping it under them leaves two
    ///    holders of one single-use refresh token.
    /// 2. The keychain holds a login the tracker has captured (compare-and-
    ///    swap on its fingerprint), or nothing. A login that changed since the
    ///    last capture — a `/login`, or a rotation by a refresher the tracker
    ///    does not know about — is never overwritten.
    /// 3. The write is one in-place `-U` update.
    ///
    /// Only after 1 and 2 pass is the stored login refreshed if it has expired:
    /// at that moment the tracker is its only holder. A stored login that is
    /// already the keychain login is left entirely alone.
    ///
    /// `knownLogins` are the main logins the tracker has captured (every
    /// profile's `cliCredentialsJSON`), for the compare-and-swap.
    func switchMainLogin(to profile: Profile, knownLogins: [String]) async throws -> MainLoginSwitch {
        await switchMutex.lock()
        do {
            let outcome = try await performMainLoginSwitch(to: profile, knownLogins: knownLogins)
            await switchMutex.unlock()
            return outcome
        } catch {
            await switchMutex.unlock()
            throw error
        }
    }

    private func performMainLoginSwitch(to profile: Profile, knownLogins: [String]) async throws -> MainLoginSwitch {
        guard let storedJSON = profile.cliCredentialsJSON, AutoSwitchPolicy.canBeApplied(profile) else {
            // A pinned entry's login is never copied into the main keychain:
            // that puts one single-use refresh token in two config dirs.
            LoggingService.shared.log("switchMainLogin: '\(profile.name)' has no main login of its own; nothing to apply")
            throw ClaudeCodeError.noProfileCredentials
        }

        // The target entry must BE the shared login's. `resolveServiceName` can
        // land on a hashed name; if that is another config dir's entry, writing
        // it would hand a second holder's login to that dir's sessions.
        let service = resolveServiceName()
        guard MainLoginSwapPolicy.isSharedLoginServiceName(service, claudeDirectoryHash: defaultClaudeDirectoryHash) else {
            LoggingService.shared.logError("switchMainLogin: resolved keychain entry '\(service)' is not the shared login's; refusing to write it")
            return .refused(.notTheSharedLoginEntry(service: service))
        }

        let keychainJSON = try? readKeychainCredentials()
        let keychainFingerprint = keychainJSON.flatMap(systemLoginFingerprint)
        if let keychainFingerprint, keychainFingerprint == systemLoginFingerprint(storedJSON) {
            return .alreadyApplied
        }

        let holders = MainLoginSwapPolicy.sharedLoginHolders(in: runningProcesses())
        let known = Set(knownLogins.compactMap(systemLoginFingerprint))
        if let refusal = MainLoginSwapPolicy.refusal(
            holders: holders.count, keychainFingerprint: keychainFingerprint, knownFingerprints: known
        ) {
            LoggingService.shared.log("switchMainLogin: not switching Claude Code to '\(profile.name)': \(refusal)")
            return .refused(refusal)
        }

        // Nothing holds the shared login and the keychain is what we last saw.
        // The stored login's only holder is this app, so it may be refreshed.
        guard let jsonData = await refreshStoredMainLoginIfExpired(storedJSON, profileId: profile.id, profileName: profile.name) else {
            throw ClaudeCodeError.noProfileCredentials
        }

        try writeSystemCredentials(jsonData)
        guard let written = try? readKeychainCredentials(),
              systemLoginFingerprint(written) == systemLoginFingerprint(jsonData) else {
            LoggingService.shared.logError("switchMainLogin: keychain does not hold the login just written for '\(profile.name)'")
            throw ClaudeCodeError.keychainWriteFailed(status: -1)
        }
        lastSeenSystemLoginFingerprint = systemLoginFingerprint(jsonData)

        // Re-scan: a `claude` that started between the scan above and the write
        // read the keychain before or after it, and we cannot tell which. Say so
        // loudly; the caller notifies, and the keychain-mdat log will show it.
        let raced = MainLoginSwapPolicy.sharedLoginHolders(in: runningProcesses())
        if !raced.isEmpty {
            LoggingService.shared.logError("⚠️ switchMainLogin: \(raced.count) Claude Code process(es) on the shared login appeared during the switch to '\(profile.name)' (pids \(raced.map { String($0.pid) }.joined(separator: ","))); one may hold the replaced login")
        }

        // Restore the profile's captured oauthAccount (if any) so Claude Code's
        // /status Status tab shows the right email/org/plan for this profile.
        // No session is running (see 1), so none can write a stale copy back.
        if let storedOAuthAccount = profile.oauthAccountJSON {
            do {
                try writeOAuthAccount(storedOAuthAccount)
            } catch {
                LoggingService.shared.logError("Failed to restore oauthAccount (non-fatal)", error: error)
            }
        }

        LoggingService.shared.log("✅ switchMainLogin: Claude Code's shared login is now '\(profile.name)'")
        return .applied(racedHolders: raced.count)
    }

    /// `switchMainLogin(to:knownLogins:)` for a stored profile, with every
    /// profile's captured main login as the known set.
    func switchMainLogin(to profileId: UUID) async throws -> MainLoginSwitch {
        let profiles = ProfileStore.shared.loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            throw ClaudeCodeError.noProfileCredentials
        }
        return try await switchMainLogin(to: profile, knownLogins: profiles.compactMap(\.cliCredentialsJSON))
    }

    /// Removes CLI credentials from profile (doesn't affect system)
    func removeFromProfile(_ profileId: UUID) throws {
        var profiles = ProfileStore.shared.loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw ClaudeCodeError.noProfileCredentials
        }

        profiles[index].cliCredentialsJSON = nil
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("Removed CLI credentials from profile: \(profileId)")
    }

    // MARK: - Access Token Extraction

    func extractAccessToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            return nil
        }
        return token
    }

    func extractRefreshToken(from jsonData: String) -> String? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["refreshToken"] as? String else {
            return nil
        }
        return token
    }

    func extractSubscriptionInfo(from jsonData: String) -> (type: String, scopes: [String])? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else {
            return nil
        }

        let subType = oauth["subscriptionType"] as? String ?? "unknown"
        let scopes = oauth["scopes"] as? [String] ?? []

        return (subType, scopes)
    }

    /// Extracts the token expiry date from CLI credentials JSON
    func extractTokenExpiry(from jsonData: String) -> Date? {
        guard let data = jsonData.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? TimeInterval else {
            return nil
        }
        // Claude Code CLI stores expiresAt in milliseconds since epoch
        // Values > 1e12 are definitely milliseconds (year 2001+ in ms vs year 33658 in seconds)
        let epochSeconds = expiresAt > 1e12 ? expiresAt / 1000.0 : expiresAt
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// Checks if the OAuth token in the credentials JSON is expired
    func isTokenExpired(_ jsonData: String) -> Bool {
        guard let expiryDate = extractTokenExpiry(from: jsonData) else {
            // No expiry info = assume valid
            return false
        }
        return Date() > expiryDate
    }

    // MARK: - OAuth Token Auto-Refresh

    /// Endpoint used by Claude Code's HUD to swap a refresh token for a fresh access token.
    /// Mirrors `TOKEN_REFRESH_URL_*` in `oh-my-claude-sisyphus/dist/hud/usage-api.js`.
    private static let oauthRefreshURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /// Public OAuth client ID for Claude Code, as shipped in the HUD source.
    /// Overridable via `CLAUDE_CODE_OAUTH_CLIENT_ID` for parity with the HUD.
    private static let defaultOAuthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// How many seconds before expiry we proactively refresh the token.
    /// Matches the HUD's 60-second leeway so a request never goes out with a token
    /// that's about to expire mid-flight.
    private static let refreshLeewaySeconds: TimeInterval = 60

    /// Reads a specific Claude Code keychain item (e.g. `Claude Code-credentials-11e1b79e`)
    /// by explicit service name, bypassing the `resolveServiceName()` chain. Used when a
    /// profile pins itself to a non-default keychain entry via
    /// `Profile.customKeychainServiceName`, so the Tracker can target the same entry Claude
    /// Code rotates during normal CLI use. Returns nil if the entry is missing, the
    /// security command timed out, or stdout was empty.
    func readKeychainCredentials(serviceName: String) -> String? {
        guard let result = runSecurityCommand(arguments: [
            "find-generic-password", "-s", serviceName, "-a", NSUserName(), "-w"
        ]) else {
            return nil
        }
        if result.timedOut {
            LoggingService.shared.log("readKeychainCredentials(svc=\(serviceName)): security command timed out")
            return nil
        }
        if result.exitCode != 0 {
            return nil
        }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Writes a credentials JSON string into a specific keychain item by explicit service name.
    /// Mirrors `writeSystemCredentials` but does not consult `resolveServiceName()` — callers
    /// supply the exact target (e.g. a hash-suffix entry tied to one Claude Code account) so
    /// rotated tokens from auto-refresh can be written back to the same place Claude Code reads.
    func writeKeychainCredentials(serviceName: String, jsonData: String) throws {
        // `-U` already updates an existing entry in place, so the previous delete-then-add
        // pattern is unnecessary and was observed to leave the entry in a partially-overwritten
        // (invalid-JSON) state under concurrent refreshes. Rely on a single atomic `-U` add.
        guard let result = runSecurityCommand(arguments: [
            "add-generic-password", "-s", serviceName, "-a", NSUserName(), "-w", jsonData, "-U"
        ]) else {
            throw ClaudeCodeError.keychainWriteFailed(status: -1)
        }
        if result.timedOut {
            throw ClaudeCodeError.keychainWriteFailed(status: -1)
        }
        if result.exitCode != 0 {
            throw ClaudeCodeError.keychainWriteFailed(status: OSStatus(result.exitCode))
        }
    }

    // internal so unit tests can construct fixtures to feed mergeRefreshedCredentials.
    struct OAuthRefreshResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let token_type: String?
    }

    /// Posts the `refresh_token` grant through `tokenRefresher`.
    private func performTokenRefresh(refreshToken: String) async throws -> OAuthRefreshResponse {
        try await tokenRefresher(refreshToken)
    }

    /// Posts the `refresh_token` grant to platform.claude.com and decodes the response.
    static func postTokenRefresh(refreshToken: String) async throws -> OAuthRefreshResponse {
        let clientId = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_CLIENT_ID"]
            ?? Self.defaultOAuthClientID

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        let bodyString = components.percentEncodedQuery ?? ""
        let body = Data(bodyString.utf8)

        var request = URLRequest(url: Self.oauthRefreshURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeCodeError.refreshFailed(status: -1, body: "No HTTP response")
        }
        guard http.statusCode == 200 else {
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? "<binary>"
            throw ClaudeCodeError.refreshFailed(status: http.statusCode, body: String(snippet))
        }
        return try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
    }

    /// The credentials to read usage with for a profile — READ ONLY. This never
    /// refreshes a token and never writes a keychain entry.
    ///
    /// Every login the tracker can see is kept fresh by whoever owns it:
    /// - A pinned entry (`profile.customKeychainServiceName`) belongs to the
    ///   `claude` sessions on that config dir (`cca`, claude-rotate, the cloud
    ///   watchdog's `claude auth status`); they rotate it. A tracker refresh of
    ///   the same entry raced theirs, and the loser was logged out.
    /// - The shared login (the main keychain entry) belongs to the `claude`
    ///   sessions started without `CLAUDE_CONFIG_DIR`.
    /// - A stored snapshot of an inactive account's main login is refreshed in
    ///   exactly one place: `switchMainLogin(to:)`, once it is safe to write.
    ///
    /// So when the token here has expired, the answer is stale and the caller
    /// shows last-known usage; it is not refreshed. Returns nil when the profile
    /// has no credentials at all.
    func ensureFreshCredentials(for profileId: UUID) async -> String? {
        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }) else {
            return nil
        }
        return usableCredentials(for: profile, isActive: ProfileStore.shared.loadActiveProfileId() == profileId)
    }

    /// `ensureFreshCredentials` without the store, for tests and callers that
    /// already hold the profile.
    func usableCredentials(for profile: Profile, isActive: Bool) -> String? {
        let customSvc = profile.customKeychainServiceName
        let pinnedJSON = customSvc.flatMap { readKeychainCredentials(serviceName: $0) }
        // A pinned entry whose refresh token is dead cannot be revived from
        // here. If this is the active profile, Claude Code's own login may
        // have been renewed with /login — follow that instead.
        let pinIsDead = pinnedJSON.flatMap { extractRefreshToken(from: $0) }.map(deadLogins.isDead) ?? false

        if customSvc == nil || pinIsDead, isActive {
            // The shared login, when it is this account's. Claude Code keeps it
            // fresh while sessions run; expired means idle, and it stays so.
            if let systemJSON = try? readSystemCredentials(), systemCredentials(systemJSON, belongTo: profile) {
                persistProfileCredentialsJSON(profileId: profile.id, json: systemJSON, ownMainLogin: isOwnMainLogin(systemJSON, for: profile))
                return systemJSON
            }
            return profile.cliCredentialsJSON
        }

        guard let svc = customSvc else {
            // Inactive and unpinned: the stored snapshot, however old.
            return profile.cliCredentialsJSON
        }
        guard let json = pinnedJSON else {
            LoggingService.shared.logError("usableCredentials: profile '\(profile.name)' pins keychain '\(svc)' but it was not found")
            return profile.cliCredentialsJSON
        }
        if extractRefreshToken(from: json) == nil {
            // The entry exists but is unparseable (a half-written payload).
            LoggingService.shared.logError("usableCredentials: keychain '\(svc)' payload for '\(profile.name)' is unparseable; using the stored snapshot")
            return profile.cliCredentialsJSON
        }
        // A pinned entry is NOT mirrored into the profile cache: the cache holds
        // the account's separate main login, which is what a switch applies.
        return json
    }

    /// True when the system (Claude Code) credentials are for the same account as `profile`.
    private func systemCredentials(_ systemJSON: String, belongTo profile: Profile) -> Bool {
        let systemIdentity = loginAccountIdentity(credentials: systemJSON, configOAuthAccount: readOAuthAccount())
        let profileIdentity = accountIdentity(fromOAuthAccountJSON: profile.oauthAccountJSON)
        return (systemIdentity != nil && systemIdentity == profileIdentity)
            || extractRefreshToken(from: systemJSON) == profile.cliCredentialsJSON.flatMap(extractRefreshToken)
    }

    /// True when `mainJSON` (a login from the main keychain) is this profile's
    /// own main login rather than a copy of its pinned entry.
    func isOwnMainLogin(_ mainJSON: String, for profile: Profile) -> Bool {
        guard let svc = profile.customKeychainServiceName else { return true }
        return AutoSwitchPolicy.isOwnMainLogin(
            mainRefreshToken: extractRefreshToken(from: mainJSON),
            pinnedRefreshToken: readKeychainCredentials(serviceName: svc).flatMap { extractRefreshToken(from: $0) }
        )
    }

    /// Stores the system (main) login into the profile when it belongs to the
    /// profile's account, flagging whether it is the profile's own main login.
    /// Returns true when anything changed. Never refreshes or writes the
    /// keychain.
    @discardableResult
    func captureMainLogin(for profileId: UUID) -> Bool {
        guard let systemJSON = try? readSystemCredentials() else { return false }
        return captureMainLogin(systemJSON, for: profileId)
    }

    /// `captureMainLogin(for:)` with the system login already read, so one
    /// keychain read serves every profile in a cycle.
    @discardableResult
    func captureMainLogin(_ systemJSON: String, for profileId: UUID) -> Bool {
        guard let profile = ProfileStore.shared.loadProfiles().first(where: { $0.id == profileId }),
              extractRefreshToken(from: systemJSON) != nil,
              systemCredentials(systemJSON, belongTo: profile) else { return false }
        let own = isOwnMainLogin(systemJSON, for: profile)
        guard profile.cliCredentialsJSON != systemJSON || profile.hasOwnMainLogin != own else { return false }
        persistProfileCredentialsJSON(profileId: profileId, json: systemJSON, ownMainLogin: own)
        return true
    }

    // MARK: - Credentials file as a reload signal

    /// A digest identifying the login in a keychain payload, or nil when the
    /// payload is not a full login. Never contains the token.
    func systemLoginFingerprint(_ keychainJSON: String) -> String? {
        extractRefreshToken(from: keychainJSON).map { sha256HexPrefix($0, length: 64) }
    }

    /// Bumps the file's modification time, leaving its contents alone. Returns
    /// false (and creates nothing) when the file does not exist.
    static func signalCredentialsReload(at fileURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
        return (try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: fileURL.path)) != nil
    }

    private var lastSeenSystemLoginFingerprint: String?

    /// Tells open Claude Code sessions to reload their login when the keychain
    /// login has changed.
    ///
    /// Sessions cache their login and reload it only when the modification
    /// time of `~/.claude/.credentials.json` changes. The tracker rewrites the
    /// file on its own switches, but a `/login` in one session (or Claude Code
    /// rotating its tokens) changes the keychain alone — leaving every other
    /// session on its old account, where it can sit at a limit the tracker
    /// cannot see.
    ///
    /// Only the modification time is touched: copying the keychain login into
    /// the file would spread a keychain-protected secret to plaintext on disk
    /// for no gain, since sessions re-read the keychain once signalled.
    /// Returns true when a signal was sent.
    @discardableResult
    func signalSessionsIfKeychainLoginChanged() -> Bool {
        guard !AppEnvironment.isRunningTests,
              let raw = try? readKeychainCredentials(),
              let fingerprint = systemLoginFingerprint(raw),
              fingerprint != lastSeenSystemLoginFingerprint else { return false }
        lastSeenSystemLoginFingerprint = fingerprint
        guard Self.signalCredentialsReload(at: Constants.ClaudePaths.credentialsFile) else { return false }
        LoggingService.shared.log("signalSessionsIfKeychainLoginChanged: keychain login changed; touched credentials file so open sessions reload")
        return true
    }

    // MARK: - Whose login is in the keychain

    /// The account a keychain login belongs to, asked of the OAuth server with
    /// the login's access token. Nil when it could not be found out.
    /// Replaceable in tests.
    var fetchLoginAccountUuid: (_ accessToken: String) async -> String? = { accessToken in
        guard !AppEnvironment.isRunningTests,
              let url = URL(string: "https://api.anthropic.com/api/oauth/profile") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["account"] as? [String: Any],
              let uuid = account["uuid"] as? String, !uuid.isEmpty else { return nil }
        return uuid
    }

    private enum LoginAccount {
        case resolving
        case resolved(String)
        case unresolvable
    }

    /// Keyed by `systemLoginFingerprint`, so a login is looked up once.
    private var loginAccounts: [String: LoginAccount] = [:]
    private let loginAccountsLock = NSLock()

    /// The account identity (`accountUuid`) of the login in `credentials`.
    ///
    /// `oauthAccount` in `.claude.json` cannot answer this: every running
    /// Claude Code session rewrites that file from its own copy, so after a
    /// `/login` it can go on naming the previous account while the keychain
    /// holds the new one. Trusting it kept the tracker (and the status line)
    /// on an account Claude Code was no longer using.
    ///
    /// Until the login has been looked up this returns nil, so callers treat
    /// the account as unknown rather than guess. If it cannot be looked up
    /// (offline, a token without a refresh token) the config's account is used.
    func loginAccountIdentity(credentials: String, configOAuthAccount: String?) -> String? {
        guard let fingerprint = systemLoginFingerprint(credentials) else {
            return accountIdentity(fromOAuthAccountJSON: configOAuthAccount)
        }
        loginAccountsLock.lock()
        let known = loginAccounts[fingerprint]
        loginAccountsLock.unlock()

        switch known {
        case .resolved(let uuid):
            return uuid
        case .unresolvable:
            return accountIdentity(fromOAuthAccountJSON: configOAuthAccount)
        case .resolving:
            return nil
        case nil:
            Task { await resolveLoginAccount(credentials: credentials) }
            return nil
        }
    }

    /// `configOAuthAccount` when it describes the login in `credentials`,
    /// otherwise nil — so another account's details are never stored with
    /// this login.
    func loginOAuthAccount(credentials: String, configOAuthAccount: String?) -> String? {
        guard let config = configOAuthAccount,
              let identity = loginAccountIdentity(credentials: credentials, configOAuthAccount: config),
              identity == accountIdentity(fromOAuthAccountJSON: config) else { return nil }
        return config
    }

    /// Looks up which account the login in `credentials` belongs to.
    func resolveLoginAccount(credentials: String) async {
        guard let fingerprint = systemLoginFingerprint(credentials) else { return }
        loginAccountsLock.lock()
        if case .resolved = loginAccounts[fingerprint] {
            loginAccountsLock.unlock()
            return
        }
        loginAccounts[fingerprint] = .resolving
        loginAccountsLock.unlock()

        var uuid: String?
        if let accessToken = extractAccessToken(from: credentials) {
            uuid = await fetchLoginAccountUuid(accessToken)
        }

        loginAccountsLock.lock()
        loginAccounts[fingerprint] = uuid.map(LoginAccount.resolved) ?? .unresolvable
        loginAccountsLock.unlock()
        if uuid == nil {
            LoggingService.shared.log("resolveLoginAccount: could not look up the keychain login's account; using .claude.json")
        }
    }

    // MARK: - Login import (claude-usage-login)

    /// Config dir `claude-usage-login` signs in through. Nothing else uses it.
    static var loginImportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-import")
    }

    /// Keychain entry Claude Code writes for a login in `loginImportDirectory`.
    var loginImportServiceName: String {
        "Claude Code-credentials-\(sha256HexPrefix(Self.loginImportDirectory.path, length: 8))"
    }

    /// A login waiting in the import dir: its credentials and `oauthAccount`.
    func readImportedLogin() -> (credentials: String, oauthAccount: String)? {
        guard let credentials = readKeychainCredentials(serviceName: loginImportServiceName),
              extractRefreshToken(from: credentials) != nil else { return nil }
        let configFile = Self.loginImportDirectory.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: configFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any],
              let accountData = try? JSONSerialization.data(withJSONObject: account, options: [.sortedKeys]),
              let oauthAccount = String(data: accountData, encoding: .utf8) else { return nil }
        return (credentials, oauthAccount)
    }

    /// Deletes the import dir's keychain entry locally. This is NOT a logout:
    /// nothing is revoked, the login lives on in the profile.
    func clearImportedLogin() {
        guard !AppEnvironment.isRunningTests else { return }
        _ = runSecurityCommand(arguments: ["delete-generic-password", "-s", loginImportServiceName, "-a", NSUserName()])
    }

    /// The ONE place the tracker refreshes a token: a stored main login about to
    /// be written into the keychain by `switchMainLogin(to:)`, after that has
    /// established that no process holds the shared login and the keychain
    /// holds a different, known login — so this app is the stored login's only
    /// holder. Returns the login to write (refreshed if it had expired), or nil
    /// when it cannot be made usable. A rejected refresh token is remembered as
    /// dead and not retried until a `/login` replaces it.
    private func refreshStoredMainLoginIfExpired(_ mainJSON: String, profileId: UUID, profileName: String) async -> String? {
        if let expiryDate = extractTokenExpiry(from: mainJSON),
           expiryDate.timeIntervalSinceNow > Self.refreshLeewaySeconds {
            return mainJSON
        }
        guard let refreshToken = extractRefreshToken(from: mainJSON) else {
            LoggingService.shared.log("switchMainLogin: stored login for '\(profileName)' has no refresh token")
            return nil
        }
        guard !deadLogins.isDead(refreshToken) else { return nil }
        do {
            let refreshed = try await performTokenRefresh(refreshToken: refreshToken)
            guard let updatedJSON = mergeRefreshedCredentials(into: mainJSON, refreshed: refreshed) else { return nil }
            persistProfileCredentialsJSON(profileId: profileId, json: updatedJSON)
            LoggingService.shared.log("✓ switchMainLogin: refreshed the stored main login for '\(profileName)' before writing it")
            return updatedJSON
        } catch let ClaudeCodeError.refreshFailed(status, body) {
            // 4xx bodies carry no tokens, only `{ "error": ... }`, so logging is safe.
            LoggingService.shared.logError("switchMainLogin: refresh failed for '\(profileName)' (HTTP \(status)) body=\(body)")
            if DeadLoginTracker.isInvalidGrant(status: status, body: body) {
                deadLogins.markDead(refreshToken)
                LoggingService.shared.logError("switchMainLogin: login for '\(profileName)' is dead — not retrying until /login")
            }
        } catch {
            LoggingService.shared.logError("switchMainLogin: refresh failed for '\(profileName)'", error: error)
        }
        return nil
    }

    /// True when the login Claude Code's main sessions use (or would use after
    /// a switch) for this profile has been rejected by the OAuth server, i.e.
    /// the account needs a fresh `/login`.
    ///
    /// For the active profile that is the system keychain login; for any other
    /// profile it is the stored login a switch would apply.
    func isLoginDead(for profile: Profile) -> Bool {
        guard !deadLogins.isEmpty else { return false }

        let mainJSON: String?
        if ProfileStore.shared.loadActiveProfileId() == profile.id {
            mainJSON = (try? readSystemCredentials()).flatMap { systemCredentials($0, belongTo: profile) ? $0 : nil }
        } else {
            mainJSON = profile.cliCredentialsJSON
        }
        let tokens = [mainJSON.flatMap { extractRefreshToken(from: $0) }].compactMap { $0 }
        return deadLogins.isLoginDead(refreshTokens: tokens)
    }

    /// Re-loads profiles and writes `json` into the profile's `cliCredentialsJSON` if it
    /// differs from what's already stored. Re-loading inside the call minimizes the risk
    /// of clobbering concurrent edits to other profile fields.
    /// `ownMainLogin`, when given, also records whether `json` is the profile's
    /// own main login (see `Profile.hasOwnMainLogin`).
    private func persistProfileCredentialsJSON(profileId: UUID, json: String, ownMainLogin: Bool? = nil) {
        var reloaded = ProfileStore.shared.loadProfiles()
        guard let idx = reloaded.firstIndex(where: { $0.id == profileId }) else { return }
        let own = ownMainLogin ?? reloaded[idx].hasOwnMainLogin
        guard reloaded[idx].cliCredentialsJSON != json || reloaded[idx].hasOwnMainLogin != own else {
            return
        }
        reloaded[idx].cliCredentialsJSON = json
        reloaded[idx].hasOwnMainLogin = own
        ProfileStore.shared.saveProfiles(reloaded)
    }

    /// Merges an OAuth refresh response into the existing `claudeAiOauth` payload,
    /// preserving fields the refresh response does not touch (scopes, subscriptionType, etc.).
    // internal so unit tests can verify the merge correctness against fixtures.
    func mergeRefreshedCredentials(into cliJSON: String, refreshed: OAuthRefreshResponse) -> String? {
        guard let data = cliJSON.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = root["claudeAiOauth"] as? [String: Any] else {
            return nil
        }

        oauth["accessToken"] = refreshed.access_token
        if let newRT = refreshed.refresh_token {
            oauth["refreshToken"] = newRT
        }
        // Claude Code persists `expiresAt` in milliseconds since the Unix epoch.
        let newExpiryMs = Int64(Date().timeIntervalSince1970 * 1000)
            + Int64(refreshed.expires_in) * 1000
        oauth["expiresAt"] = newExpiryMs

        root["claudeAiOauth"] = oauth

        // Single-line, sorted-keys output. Avoid `prettyPrinted` here because the
        // resulting JSON is round-tripped through `security add-generic-password -w`,
        // and embedded newlines have been observed to corrupt the stored payload on
        // some macOS builds — readers then see "Extra data" parse errors.
        guard let outData = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys]),
              let outString = String(data: outData, encoding: .utf8) else {
            return nil
        }
        return outString
    }

    // MARK: - Auto Re-sync Before Switching

    /// Re-syncs credentials from system Keychain before profile switching
    /// This ensures we always have the latest CLI login when switching profiles
    func resyncBeforeSwitching(for profileId: UUID) throws {
        LoggingService.shared.log("Re-syncing CLI credentials before profile switch: \(profileId)")

        // Read fresh credentials from system (if user is logged in)
        guard let freshJSON = try readSystemCredentials() else {
            // No credentials in system - user not logged into CLI anymore
            LoggingService.shared.log("No system credentials found - skipping re-sync")
            return
        }

        // Validate JSON before saving (defense-in-depth against truncated data)
        guard let data = freshJSON.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LoggingService.shared.log("Re-synced credentials contain invalid JSON - skipping save")
            return
        }

        // Verify the system credentials belong to the same account as this profile.
        // IMPORTANT: compare ACCOUNT IDENTITY (oauthAccount.accountUuid), not refresh
        // tokens. Claude Code ROTATES refresh tokens during normal use, so for the same
        // account the system refresh token routinely differs from our stored snapshot —
        // that rotation is exactly what we must capture here, or the profile keeps a
        // consumed refresh token and every later refresh fails with invalid_grant.
        var profiles = ProfileStore.shared.loadProfiles()
        if let profile = profiles.first(where: { $0.id == profileId }) {
            let systemIdentity = loginAccountIdentity(credentials: freshJSON, configOAuthAccount: readOAuthAccount())
            let profileIdentity = accountIdentity(fromOAuthAccountJSON: profile.oauthAccountJSON)
            if let sys = systemIdentity, let stored = profileIdentity {
                if sys != stored {
                    LoggingService.shared.log("⚠️ resyncBeforeSwitching: skipping for '\(profile.name)' — system account (\(sys)) differs from profile account (\(stored))")
                    return
                }
                // Same account — capture even though the refresh token rotated.
            } else if let storedJSON = profile.cliCredentialsJSON {
                // Identity unavailable on one side — fall back to the conservative
                // refresh-token equality check to avoid cross-profile contamination.
                let freshRefreshToken = extractRefreshToken(from: freshJSON)
                let storedRefreshToken = extractRefreshToken(from: storedJSON)
                if let fresh = freshRefreshToken, let stored = storedRefreshToken, fresh != stored {
                    LoggingService.shared.log("⚠️ resyncBeforeSwitching: skipping for '\(profile.name)' — no account identity available and refresh token differs")
                    return
                }
                // A manually pasted setup token has neither an oauthAccount id
                // nor a refreshToken, so no identity check can vouch that the
                // system keychain belongs to the same account — never overwrite
                // the manual token with potentially foreign credentials.
                if storedRefreshToken == nil && profileIdentity == nil {
                    LoggingService.shared.log("⚠️ resyncBeforeSwitching: skipping for '\(profile.name)' — profile uses a manual setup token; account identity unverifiable")
                    return
                }
            }
        }

        // Capture latest oauthAccount too, so if the user logged in with a
        // different account since the last sync we keep the profile's
        // `.claude.json` identity in sync with its keychain credentials.
        let freshOAuthAccount = loginOAuthAccount(credentials: freshJSON, configOAuthAccount: readOAuthAccount())

        // Update profile's stored credentials with fresh ones (profiles already loaded above)
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            return
        }

        profiles[index].cliCredentialsJSON = freshJSON
        profiles[index].hasOwnMainLogin = isOwnMainLogin(freshJSON, for: profiles[index])
        if let freshOAuthAccount = freshOAuthAccount {
            profiles[index].oauthAccountJSON = freshOAuthAccount
        }
        profiles[index].cliAccountSyncedAt = Date()  // Update sync timestamp
        ProfileStore.shared.saveProfiles(profiles)

        LoggingService.shared.log("✓ Re-synced CLI credentials from system and updated timestamp\(freshOAuthAccount != nil ? " (with oauthAccount)" : "")")
    }
}

// MARK: - ClaudeCodeError

enum ClaudeCodeError: LocalizedError {
    case noCredentialsFound
    case invalidJSON
    case keychainReadFailed(status: OSStatus)
    case keychainWriteFailed(status: OSStatus)
    case noProfileCredentials
    case refreshFailed(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .noCredentialsFound:
            return "No Claude Code credentials found in system Keychain. Please log in to Claude Code first."
        case .invalidJSON:
            return "Claude Code credentials are corrupted or invalid."
        case .keychainReadFailed(let status):
            return "Failed to read credentials from system Keychain (status: \(status))."
        case .keychainWriteFailed(let status):
            return "Failed to write credentials to system Keychain (status: \(status))."
        case .noProfileCredentials:
            return "This profile has no synced CLI account."
        case .refreshFailed(let status, _):
            return "OAuth token refresh failed (status: \(status))."
        }
    }
}
