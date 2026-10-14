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

    /// The processes running now, for `MainLoginSwapPolicy`; nil when they
    /// could not be listed, which the swap treats as "refuse" (C1). Tests
    /// supply a list.
    var runningProcesses: () -> [MainLoginSwapPolicy.RunningProcess]? = {
        ClaudeCodeSyncService.listRunningProcesses()
    }

    /// The model a shared-login holder's session last answered with, from its
    /// `~/.claude/sessions/<pid>.json` and that session's transcript; nil when
    /// unknown. Tests supply a map.
    var holderModel: (Int32) -> String? = { pid in
        MainLoginSwapPolicy.holderModel(
            pid: pid,
            sessionsDirectory: Constants.ClaudePaths.claudeDirectory.appendingPathComponent("sessions"),
            projectsDirectory: Constants.ClaudePaths.projectsDirectory)
    }

    /// Reads `.claude.json`'s `oauthAccount`; every `readOAuthAccount()` call
    /// goes through it. Tests replace it so they never read the real file.
    var configOAuthAccountReader: () -> String? = {
        ClaudeCodeSyncService.shared.readOAuthAccountFromConfigFile()
    }

    /// True when Claude Code sessions hold the shared login and every one of
    /// them is on Fable (per holder, from its own transcript).
    func sharedLoginHoldersAllOnFable() -> Bool {
        guard let processes = runningProcesses() else { return false }
        return MainLoginSwapPolicy.allHoldersOnFable(MainLoginSwapPolicy.sharedLoginHolders(in: processes), modelOf: holderModel)
    }

    static func isMutatingSecurityVerb(_ verb: String?) -> Bool {
        guard let verb else { return false }
        return verb.hasPrefix("add-") || verb.hasPrefix("delete-") || verb.hasPrefix("set-")
            || verb == "import" || verb == "unlock-keychain"
    }

    /// Two `ps` listings (plain, and with the environment appended) so the
    /// environment is read only from after each command line (W4). Returns nil
    /// — never an empty list — when either `ps` fails to run, exits non-zero,
    /// or its output cannot be decoded: an empty list would read as "no
    /// holders" and let a switch proceed blind (C1).
    static func listRunningProcesses() -> [MainLoginSwapPolicy.RunningProcess]? {
        if let commands = runPs(["-axww", "-o", "pid=,ppid=,command="]),
           let withEnvironment = runPs(["-axwwE", "-o", "pid=,ppid=,command="]) {
            let processes = MainLoginSwapPolicy.parsePsOutput(commands: commands, withEnvironment: withEnvironment)
            // A machine always has processes; an empty parse means ps changed shape.
            if !processes.isEmpty { return processes }
            LoggingService.shared.logError("listRunningProcesses: ps output parsed to no processes (\(commands.utf8.count) and \(withEnvironment.utf8.count) bytes); using the in-process listing")
        }
        // 2026-10-12 03:14-10:21 EDT: `ps` failed 856 times in a row and every
        // switch was refused for seven hours ("cannot list processes"). The
        // in-process listing needs no spawn. It cannot read environments, so
        // every Claude Code process counts as a shared-login holder — erring
        // toward refusal, never toward a blind write.
        let fallback = ProcessListing.listViaLibproc()
        if fallback.isEmpty {
            LoggingService.shared.logError("listRunningProcesses: the in-process listing found no processes either; refusing")
            return nil
        }
        return fallback
    }

    /// Runs `ps` (or, for tests, `executable`) and returns its stdout.
    ///
    /// Every pipe end is closed here, explicitly. Measured 2026-10-14: left to
    /// `Pipe` deallocation, each run leaked one descriptor of its pipe (two when
    /// the launch itself failed), and after 33 hours the tracker held 4,841 pipe
    /// descriptors, could not spawn `security` or `ps` at all, and refused
    /// every hand-off until the limit hit (`ProcessRunnerFdTests`).
    static func runPs(_ arguments: [String], executable: URL = URL(fileURLWithPath: "/bin/ps")) -> String? {
        autoreleasepool {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            defer { try? pipe.fileHandleForReading.close() }
            do {
                try process.run()
            } catch {
                // Never launched: the parent still holds BOTH ends.
                try? pipe.fileHandleForWriting.close()
                LoggingService.shared.logError("listRunningProcesses: could not run ps \(arguments.first ?? "") (errno \(errno))", error: error)
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                LoggingService.shared.logError("listRunningProcesses: ps \(arguments.first ?? "") exited \(process.terminationStatus) (reason \(process.terminationReason.rawValue), \(data.count) bytes)")
                return nil
            }
            // ps output is not guaranteed UTF-8 (arguments can be any bytes).
            if let text = String(data: data, encoding: .utf8) { return text }
            if let text = String(data: data, encoding: .isoLatin1) { return text }
            LoggingService.shared.logError("listRunningProcesses: ps output could not be decoded")
            return nil
        }
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

            guard let data = try? Data(contentsOf: fileURL) else {
                LoggingService.shared.log("credentials file exists but could not be read: \(fileURL.lastPathComponent)")
                continue
            }
            // A 0-byte file is the reload-signal stub (`signalCredentialsReload`),
            // not a login: Claude Code keeps the login in the keychain and only
            // watches this file's mtime. Nothing to read, nothing to report.
            guard let jsonString = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !jsonString.isEmpty else { continue }

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
    ///
    /// Every pipe end is closed here, explicitly: the read ends after the run
    /// (or the timeout), and the write ends too when the launch failed, since
    /// only a launched `Process` closes the parent's copies. See `runPs` for the
    /// measured leak this closes. `executable` is only overridden by tests.
    static func runSecurityProcess(
        arguments: [String],
        timeout: TimeInterval,
        executable: URL = URL(fileURLWithPath: "/usr/bin/security")
    ) -> SecurityCommandResult? {
        autoreleasepool {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            defer {
                try? outputPipe.fileHandleForReading.close()
                try? errorPipe.fileHandleForReading.close()
            }

            do {
                try process.run()
            } catch {
                // Never launched: the parent still holds BOTH ends of each pipe.
                try? outputPipe.fileHandleForWriting.close()
                try? errorPipe.fileHandleForWriting.close()
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
            // Failed to launch security: UNKNOWN, not "no credentials" (C2).
            LoggingService.shared.log("readKeychainCredentials: could not run security")
            throw ClaudeCodeError.keychainReadFailed(status: -1)
        }

        if result.timedOut {
            // UNKNOWN, not "no credentials" (C2): only exit 44 means not found.
            LoggingService.shared.log("readKeychainCredentials: security command timed out")
            throw ClaudeCodeError.keychainReadFailed(status: -2)
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
        configOAuthAccountReader()
    }

    fileprivate func readOAuthAccountFromConfigFile() -> String? {
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
        if let refusal = syncToProfileRefusal(jsonData, profile: profiles[index]) {
            LoggingService.shared.log("⚠️ syncToProfile: not storing Claude Code's login under '\(profiles[index].name)': \(refusal)")
            throw ClaudeCodeError.loginNotProven(refusal)
        }

        profiles[index].cliCredentialsJSON = jsonData
        profiles[index].hasOwnMainLogin = isOwnMainLogin(jsonData, for: profiles[index])
        profiles[index].mainLoginProvenance = "keychain"
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
        /// the scan and the write and may hold the login that was replaced;
        /// nil means the re-scan itself failed, so the window is unverified.
        ///
        /// `strandedSignalled` is false only when the sessions switched under
        /// could not be told to reload (the credentials-file stub could not be
        /// touched or created): they stay on the replaced login until they
        /// restart or the user runs /login.
        case applied(racedHolders: Int?, strandedSignalled: Bool = true)
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
    /// one `claude` sessions started without `CLAUDE_CONFIG_DIR` use — and
    /// moves every running session with it:
    ///
    /// 1. Running sessions FOLLOW the swap (measured 2026-10-14, claude-rotate
    ///    `tests/test_session_follows_login.sh`): after the keychain write the
    ///    credentials-file stub is touched, and each session re-reads the
    ///    keychain before its next request. They never block the swap. The
    ///    holders are written down (`HandoffRecord`) so the replaced login's
    ///    lineage is not refreshed by the tracker until every one of them has
    ///    released it (it is a single-use refresh token they may still carry).
    ///    Until 2026-10-14 running sessions refused the swap; that refusal is
    ///    what let the 90-98% hand-off fail eleven ticks in a row and ~20
    ///    agents die at the limit.
    /// 2. The keychain holds a login the tracker knows — a stored copy
    ///    (`knownLogins`), or a login PROVEN to belong to one of `owners` by
    ///    its account lookup (a rotation the tracker has not stored yet) — or
    ///    nothing. A `/login` the tracker has not adopted is never overwritten.
    /// 3. The write is one in-place `-U` update.
    ///
    /// Only after 2 passes is the stored login refreshed if it has expired: at
    /// that moment the tracker is its only holder. A stored login that is
    /// already the keychain login is left entirely alone.
    ///
    /// `reason` is why the caller is switching (near limit, limit reached, user
    /// click, pending retry…); it is written to `HandoffLog` with the from/to
    /// accounts and the outcome.
    func switchMainLogin(
        to profile: Profile, knownLogins: [String], pinnedLogins: [String] = [], reason: String = "user", owners: [Profile] = []
    ) async throws -> MainLoginSwitch {
        try await withSwitchMutex {
            try await performMainLoginSwitch(to: profile, knownLogins: knownLogins, pinnedLogins: pinnedLogins, reason: reason, owners: owners)
        }
    }

    private func withSwitchMutex<T>(_ body: () async throws -> T) async throws -> T {
        await switchMutex.lock()
        do {
            let result = try await body()
            await switchMutex.unlock()
            return result
        } catch {
            await switchMutex.unlock()
            throw error
        }
    }

    private func performMainLoginSwitch(
        to profile: Profile, knownLogins: [String], pinnedLogins: [String], reason: String, owners: [Profile]
    ) async throws -> MainLoginSwitch {
        // Who the keychain login belongs to, as far as can be told: by a stored
        // copy, or by a proven account lookup. Filled in once the keychain is
        // read; "unknown login" until then. Names only, never a token.
        var fromName = "unknown login"
        var holderCount = 0
        func logged(_ outcome: MainLoginSwitch, _ extra: [(String, String)] = []) -> MainLoginSwitch {
            switch outcome {
            case .applied(let raced, let signalled):
                HandoffLog.record(.handoff, from: fromName, to: profile.name, reason: reason,
                                  fields: [("holders", String(holderCount)), ("signalled", signalled ? "yes" : "NO"),
                                           ("raced", raced.map(String.init) ?? "unverified")] + extra)
            case .alreadyApplied:
                HandoffLog.record(.alreadyOn, from: fromName, to: profile.name, reason: reason)
            case .refused(let refusal):
                HandoffLog.record(.refused, from: fromName, to: profile.name, reason: reason,
                                  fields: [("refusal", "\(refusal)"), ("holders", String(holderCount))] + extra)
            }
            return outcome
        }

        guard let storedJSON = profile.cliCredentialsJSON, AutoSwitchPolicy.canBeApplied(profile) else {
            // A pinned entry's login is never copied into the main keychain:
            // that puts one single-use refresh token in two config dirs.
            LoggingService.shared.log("switchMainLogin: '\(profile.name)' has no main login of its own; nothing to apply")
            HandoffLog.record(.failed, from: fromName, to: profile.name, reason: reason, fields: [("why", "no main login of its own")])
            throw ClaudeCodeError.noProfileCredentials
        }

        // The target entry must BE the shared login's. `resolveServiceName` can
        // land on a hashed name; if that is another config dir's entry, writing
        // it would hand a second holder's login to that dir's sessions.
        let service = resolveServiceName()
        guard MainLoginSwapPolicy.isSharedLoginServiceName(service, claudeDirectoryHash: defaultClaudeDirectoryHash) else {
            LoggingService.shared.logError("switchMainLogin: resolved keychain entry '\(service)' is not the shared login's; refusing to write it")
            return logged(.refused(.notTheSharedLoginEntry(service: service)))
        }

        // C2: only exit 44 (not found) means the entry is empty. A timeout, a
        // launch failure or any other error means UNKNOWN, never "may write".
        let keychainJSON: String?
        do {
            keychainJSON = try readKeychainCredentials()
        } catch {
            LoggingService.shared.logError("switchMainLogin: cannot read the shared keychain entry; refusing", error: error)
            return logged(.refused(.keychainUnreadable), [("why", "keychain unreadable: \(error.localizedDescription)")])
        }
        let keychainFingerprint = keychainJSON.flatMap(systemLoginFingerprint)
        // The account the keychain login belongs to. A stored copy proves it;
        // so does a resolved account lookup (`loginIsProvenToBelong`), which is
        // how a login Claude Code rotated since the last capture is still
        // recognised as, say, jrand's rather than "unknown" — the tracker's
        // active account and the keychain's must be the same thing.
        let keychainOwner = keychainJSON.flatMap { json in owners.first { loginIsProvenToBelong(json, to: $0) } }
        if keychainJSON == nil {
            fromName = "(empty keychain)"
        } else if let keychainOwner {
            fromName = keychainOwner.name
        } else if let keychainFingerprint, keychainFingerprint == systemLoginFingerprint(storedJSON) {
            fromName = profile.name
        }
        if let keychainFingerprint, keychainFingerprint == systemLoginFingerprint(storedJSON) {
            return logged(.alreadyApplied)
        }

        // W6/W15: a stored login that is (or may be) a copy of a lineage someone
        // else holds is never written: bare sessions would become that lineage's
        // second holder. Only a login this build captured (`keychain`) or
        // imported (`import`) is trusted; anything an older build stored must be
        // re-imported or re-captured first.
        if let distrust = MainLoginSwapPolicy.distrust(
            storedRefreshToken: extractRefreshToken(from: storedJSON),
            pinnedRefreshTokens: pinnedLogins.compactMap(extractRefreshToken),
            provenance: profile.mainLoginProvenance
        ) {
            LoggingService.shared.logError("switchMainLogin: not writing '\(profile.name)''s stored login: \(distrust); re-import it with claude-usage-login")
            return logged(.refused(.untrustedStoredLogin(distrust)))
        }

        // C1: no process list means no knowledge of holders. They no longer
        // block the swap, but they must be written down (the replaced lineage
        // is held back from any refresh until they release it), so refuse.
        guard let processes = runningProcesses() else {
            LoggingService.shared.logError("switchMainLogin: cannot list processes; refusing to switch to '\(profile.name)'")
            return logged(.refused(.processListUnavailable))
        }
        let holders = MainLoginSwapPolicy.sharedLoginHolders(in: processes)
        holderCount = holders.count
        var known = Set(knownLogins.compactMap(systemLoginFingerprint))
        if let keychainFingerprint, keychainOwner != nil { known.insert(keychainFingerprint) }
        if let refusal = MainLoginSwapPolicy.refusal(keychainFingerprint: keychainFingerprint, knownFingerprints: known) {
            LoggingService.shared.log("switchMainLogin: not switching Claude Code from '\(fromName)' to '\(profile.name)' (\(reason)): \(refusal)")
            return logged(.refused(refusal))
        }
        if !holders.isEmpty {
            LoggingService.shared.log("switchMainLogin: hand-off (\(reason)): \(holders.count) Claude Code session(s) on '\(fromName)' will follow the shared login to '\(profile.name)'")
        }

        // The keychain is what we last saw. The stored login's only holder is
        // this app (or a lineage whose holders have all released it), so it
        // may be refreshed.
        guard let jsonData = await refreshStoredMainLoginIfExpired(storedJSON, profileId: profile.id, profileName: profile.name) else {
            HandoffLog.record(.failed, from: fromName, to: profile.name, reason: reason,
                              fields: [("why", "stored login could not be refreshed (dead, held by an unreleased hand-off, or no refresh token)")])
            throw ClaudeCodeError.noProfileCredentials
        }

        // Re-do the compare-and-swap: the refresh above is a network call, and
        // a session (or a /login) may have rotated the keychain meanwhile. The
        // pending retry picks this up on a later cycle.
        let keychainNow: String?
        do {
            keychainNow = try readKeychainCredentials()
        } catch {
            LoggingService.shared.logError("switchMainLogin: cannot re-read the shared keychain entry before writing; refusing", error: error)
            return logged(.refused(.keychainUnreadable), [("why", "re-read before write failed")])
        }
        if keychainNow.flatMap(systemLoginFingerprint) != keychainFingerprint {
            LoggingService.shared.log("switchMainLogin: the shared login changed while '\(profile.name)''s stored login was refreshed; not writing")
            return logged(.refused(.unknownKeychainLogin), [("why", "keychain login changed during the stored login's refresh")])
        }

        try writeSystemCredentials(jsonData)
        // Verify the write. A read that THROWS (timeout, launch failure) after a
        // write that succeeded is not a failed write: retry once, and if it still
        // cannot be read, report the switch as applied-but-unverified rather than
        // raise a false "apply failed" (which would also clear pending wrongly).
        var verified = false
        for attempt in 1...2 {
            do {
                let written = try readKeychainCredentials()
                guard let written, systemLoginFingerprint(written) == systemLoginFingerprint(jsonData) else {
                    LoggingService.shared.logError("switchMainLogin: keychain does not hold the login just written for '\(profile.name)'")
                    throw ClaudeCodeError.keychainWriteFailed(status: -1)
                }
                verified = true
                break
            } catch let error as ClaudeCodeError {
                if case .keychainWriteFailed = error { throw error }
                LoggingService.shared.logError("switchMainLogin: post-write read failed (attempt \(attempt)) for '\(profile.name)'", error: error)
            }
        }
        if !verified {
            LoggingService.shared.logError("⚠️ switchMainLogin: wrote '\(profile.name)' but could not read the entry back; the switch is UNVERIFIED")
        }
        lastSeenSystemLoginFingerprint = systemLoginFingerprint(jsonData)

        // A swap under holders: remember who may still carry the replaced
        // lineage, so it is not refreshed until they have released it.
        if !holders.isEmpty, let replaced = keychainFingerprint {
            var started: [String: Date] = [:]
            for holder in holders {
                if case .running(let at?) = holderProcess(holder.pid) { started[String(holder.pid)] = at }
            }
            recordHandoff(MainLoginSwapPolicy.HandoffRecord(
                fingerprint: replaced, holderPids: holders.map(\.pid), at: Date(), holderStartTimes: started,
                holdersWithSession: holders.map(\.pid).filter(holderHasSession),
                holdersByNameOnly: holders.filter(MainLoginSwapPolicy.isNameOnlyNode).map(\.pid)))
        }

        // Tell every session to reload onto the new login: ALWAYS, not only
        // when holders were seen — the listing can miss one (the libproc
        // fallback, a session that started during the write) and the signal is
        // a touch of a stub, free when nobody is listening. The stub is created
        // when missing; a failure is reported to the caller.
        let strandedSignalled = Self.signalCredentialsReload(at: credentialsFileURL)
        if strandedSignalled {
            LoggingService.shared.log("switchMainLogin: touched \(credentialsFileURL.lastPathComponent) so the \(holders.count) session(s) on '\(fromName)' reload onto '\(profile.name)' before their next request")
        } else {
            LoggingService.shared.logError("⚠️ switchMainLogin: could not touch or create \(credentialsFileURL.lastPathComponent); the \(holders.count) session(s) stay on '\(fromName)' until restarted or /login")
        }

        // Re-scan: a `claude` that started between the scan above and the write
        // read the keychain before or after it, and we cannot tell which. Say so
        // loudly; the caller notifies, and the keychain-mdat log will show it.
        let racedCount: Int?
        if let after = runningProcesses() {
            let before = Set(holders.map(\.pid))
            let raced = MainLoginSwapPolicy.sharedLoginHolders(in: after).filter { !before.contains($0.pid) }
            racedCount = raced.count
            if !raced.isEmpty {
                LoggingService.shared.logError("⚠️ switchMainLogin: \(raced.count) Claude Code process(es) on the shared login appeared during the switch to '\(profile.name)' (pids \(raced.map { String($0.pid) }.joined(separator: ","))); one may hold the replaced login")
                // Tell it to reload: sessions re-read the keychain when the
                // credentials file's mtime changes, so it converges on the new login.
                if Self.signalCredentialsReload(at: credentialsFileURL) {
                    LoggingService.shared.log("switchMainLogin: touched the credentials file so the raced session reloads")
                }
            }
        } else {
            racedCount = nil
            LoggingService.shared.logError("⚠️ switchMainLogin: could not re-scan processes after writing '\(profile.name)'; the switch window is unverified")
        }

        // Restore the profile's captured oauthAccount (if any) so Claude Code's
        // /status Status tab shows the right email/org/plan for this profile.
        // Running sessions reload onto the new login (the stub was touched).
        if let storedOAuthAccount = profile.oauthAccountJSON {
            do {
                try writeOAuthAccount(storedOAuthAccount)
            } catch {
                LoggingService.shared.logError("Failed to restore oauthAccount (non-fatal)", error: error)
            }
        }

        LoggingService.shared.log("✅ switchMainLogin: Claude Code's shared login is now '\(profile.name)' (was '\(fromName)'; \(reason))")
        return logged(.applied(racedHolders: verified ? racedCount : nil, strandedSignalled: strandedSignalled))
    }

    /// `switchMainLogin(to:knownLogins:pinnedLogins:reason:owners:)` for a
    /// stored profile, with every profile's captured main login as the known
    /// set, every profile as a possible owner of the keychain login, and every
    /// pinned entry's current contents (read-only) for the copy check. The
    /// store is loaded INSIDE the mutex, so a queued caller sees the login the
    /// previous switch just refreshed and stored (`.alreadyApplied`), not a
    /// stale copy it would then mis-read as an unknown keychain login.
    func switchMainLogin(to profileId: UUID, reason: String) async throws -> MainLoginSwitch {
        try await withSwitchMutex {
            let profiles = ProfileStore.shared.loadProfiles()
            guard let profile = profiles.first(where: { $0.id == profileId }) else {
                throw ClaudeCodeError.noProfileCredentials
            }
            let pinned = Set(profiles.compactMap(\.customKeychainServiceName)).compactMap { readKeychainCredentials(serviceName: $0) }
            return try await performMainLoginSwitch(
                to: profile, knownLogins: profiles.compactMap(\.cliCredentialsJSON), pinnedLogins: pinned,
                reason: reason, owners: profiles)
        }
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
                persistProfileCredentialsJSON(profileId: profile.id, json: systemJSON, ownMainLogin: isOwnMainLogin(systemJSON, for: profile), provenance: "keychain")
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
    /// Proven only (`loginIsProvenToBelong`): a capture stores this login under
    /// the profile, and a switch later refreshes what was stored, so a guess
    /// from `.claude.json` would put a live lineage under the wrong account.
    func systemCredentials(_ systemJSON: String, belongTo profile: Profile) -> Bool {
        loginIsProvenToBelong(systemJSON, to: profile)
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
        persistProfileCredentialsJSON(profileId: profileId, json: systemJSON, ownMainLogin: own, provenance: "keychain")
        return true
    }

    // MARK: - Credentials file as a reload signal

    /// A digest identifying the login in a keychain payload, or nil when the
    /// payload is not a full login. Never contains the token.
    func systemLoginFingerprint(_ keychainJSON: String) -> String? {
        extractRefreshToken(from: keychainJSON).map { sha256HexPrefix($0, length: 64) }
    }

    /// Bumps the file's modification time, leaving its contents alone, so every
    /// running Claude Code session re-reads the keychain before its next
    /// request (measured against Claude Code 2.1.299, 2026-10-14: a session
    /// stats this file before EVERY request and drops its cached login when the
    /// mtime changed; the content is not consulted on macOS, the keychain is).
    ///
    /// When the file is missing it is CREATED as a 0-byte, mode 0600 stub — the
    /// same stub claude-rotate's `reload-signal.sh` writes. Without the file
    /// there is nothing for sessions to watch, so a swap could not reach them.
    /// Nothing is ever written into it. Returns false only on a filesystem
    /// error (no config dir, permission denied).
    static func signalCredentialsReload(at fileURL: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                return false
            }
            LoggingService.shared.log("signalCredentialsReload: created the 0-byte stub \(fileURL.lastPathComponent) so sessions can follow the shared login")
            return true
        }
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
        /// The lookup failed (offline, an expired access token the server
        /// rejects). Not final: retried after `loginAccountRetryInterval`,
        /// doubling per consecutive failure up to `loginAccountMaxRetryInterval`
        /// (an expired token is not re-sent every minute for hours), or at once
        /// when the login turns up with a renewed access token (`accessToken`
        /// is a fingerprint of the one that failed).
        case unresolvable(at: Date, accessToken: String?, failures: Int)
    }

    /// Keyed by `systemLoginFingerprint` (the refresh token), so a login is
    /// looked up once — one lookup in flight per login, a resolved answer kept.
    private var loginAccounts: [String: LoginAccount] = [:]
    private let loginAccountsLock = NSLock()

    /// How long a failed lookup is left alone before the same login is asked
    /// about again. Tests set it to 0 (retry at once) or `.infinity` (never).
    var loginAccountRetryInterval: TimeInterval = 60
    /// Ceiling for the doubling retry interval.
    var loginAccountMaxRetryInterval: TimeInterval = 3600

    private func accessTokenFingerprint(_ credentials: String) -> String? {
        extractAccessToken(from: credentials).map { sha256HexPrefix($0, length: 16) }
    }

    /// The wait after `failures` consecutive failures: base, 2x, 4x … capped.
    func loginAccountRetryDelay(afterFailures failures: Int) -> TimeInterval {
        let doublings = max(0, min(failures - 1, 16))
        return min(loginAccountRetryInterval * pow(2, Double(doublings)), loginAccountMaxRetryInterval)
    }

    /// Whether `credentials` should be looked up now, given what is known.
    /// Caller holds `loginAccountsLock`.
    private func lookupDue(_ known: LoginAccount?, credentials: String, now: Date) -> Bool {
        switch known {
        case nil:
            return true
        case .resolving, .resolved:
            return false
        case .unresolvable(let at, let failedToken, let failures):
            if let failedToken, failedToken != accessTokenFingerprint(credentials) { return true }
            return now.timeIntervalSince(at) >= loginAccountRetryDelay(afterFailures: failures)
        }
    }

    /// Starts a lookup for `credentials` if one is due. Fire-and-forget: the
    /// caller answers "unknown" this cycle and asks again next cycle.
    private func lookUpIfDue(_ credentials: String, fingerprint: String) {
        loginAccountsLock.lock()
        let due = lookupDue(loginAccounts[fingerprint], credentials: credentials, now: Date())
        loginAccountsLock.unlock()
        if due {
            Task { await resolveLoginAccount(credentials: credentials) }
        }
    }

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
            lookUpIfDue(credentials, fingerprint: fingerprint)
            return accountIdentity(fromOAuthAccountJSON: configOAuthAccount)
        case .resolving:
            return nil
        case nil:
            lookUpIfDue(credentials, fingerprint: fingerprint)
            return nil
        }
    }

    /// `configOAuthAccount` when it describes the login in `credentials`,
    /// otherwise nil — so another account's details are never stored with
    /// this login.
    func loginOAuthAccount(credentials: String, configOAuthAccount: String?) -> String? {
        // Proven identity only: with an unresolved login, loginAccountIdentity IS the config's
        // account, so comparing the two would always "match".
        guard let config = configOAuthAccount,
              let identity = provenLoginAccountUuid(credentials),
              identity == accountIdentity(fromOAuthAccountJSON: config) else { return nil }
        return config
    }

    /// The account uuid of the login in `credentials`, ONLY when its own
    /// lookup succeeded (`.resolved`). Never `.claude.json`'s `oauthAccount`,
    /// which can name the previous account after a `/login`. A login not yet
    /// looked up — or whose last lookup failed and is due a retry — starts a
    /// lookup and returns nil (unknown) for now. Anything that STORES a login
    /// under a profile must use this, not `loginAccountIdentity`.
    func provenLoginAccountUuid(_ credentials: String) -> String? {
        guard let fingerprint = systemLoginFingerprint(credentials) else { return nil }
        loginAccountsLock.lock()
        let known = loginAccounts[fingerprint]
        loginAccountsLock.unlock()
        switch known {
        case .resolved(let uuid): return uuid
        case nil, .unresolvable: lookUpIfDue(credentials, fingerprint: fingerprint); return nil
        case .resolving: return nil
        }
    }

    /// Whether `json` (a login from the shared item) is PROVEN to be
    /// `profile`'s: the same refresh token as its stored login, or a resolved
    /// account lookup equal to its account. Unknown is not proof.
    func loginIsProvenToBelong(_ json: String, to profile: Profile) -> Bool {
        if let token = extractRefreshToken(from: json), token == profile.cliCredentialsJSON.flatMap(extractRefreshToken) {
            return true
        }
        guard let uuid = provenLoginAccountUuid(json),
              let profileIdentity = accountIdentity(fromOAuthAccountJSON: profile.oauthAccountJSON) else { return false }
        return uuid == profileIdentity
    }

    /// The access token of the shared keychain login, for reading `profile`'s
    /// usage: only when the login is unexpired AND proven to be this profile's
    /// account. Nil otherwise — an unproven login (another account's, or one
    /// whose lookup has not succeeded) must never produce a reading that is
    /// stored under this profile. A nil here also starts the account lookup
    /// (`provenLoginAccountUuid`), so the next cycle can prove it.
    func usageAccessToken(fromSharedLogin json: String, for profile: Profile) -> String? {
        guard !isTokenExpired(json), loginIsProvenToBelong(json, to: profile) else { return nil }
        return extractAccessToken(from: json)
    }

    /// Why `syncToProfile` must not store `json` under `profile`, or nil.
    /// A profile with no account yet takes the user's explicit sync (there is
    /// nothing to contradict); a profile that has one takes only a proven login.
    func syncToProfileRefusal(_ json: String, profile: Profile) -> String? {
        guard accountIdentity(fromOAuthAccountJSON: profile.oauthAccountJSON) != nil else { return nil }
        if loginIsProvenToBelong(json, to: profile) { return nil }
        return provenLoginAccountUuid(json) == nil
            ? "Claude Code's login could not be proven to be this profile's account (its account lookup has not succeeded); try again in a moment"
            : "Claude Code is logged into a different account than this profile"
    }

    /// Looks up which account the login in `credentials` belongs to.
    ///
    /// One lookup per login at a time: a call while another is in flight
    /// returns and leaves the in-flight one to answer. A resolved answer is
    /// final — a failure can never overwrite it, however late it lands. A
    /// failure is retried (see `LoginAccount.unresolvable`).
    func resolveLoginAccount(credentials: String) async {
        guard let fingerprint = systemLoginFingerprint(credentials) else { return }
        loginAccountsLock.lock()
        let priorFailures: Int
        switch loginAccounts[fingerprint] {
        case .resolved, .resolving:
            loginAccountsLock.unlock()
            return
        case nil:
            priorFailures = 0
        case .unresolvable(_, _, let failures):
            priorFailures = failures
        }
        loginAccounts[fingerprint] = .resolving
        loginAccountsLock.unlock()

        var uuid: String?
        if let accessToken = extractAccessToken(from: credentials) {
            uuid = await fetchLoginAccountUuid(accessToken)
        }

        loginAccountsLock.lock()
        if case .resolved = loginAccounts[fingerprint] {
            // Answered meanwhile; never downgrade.
        } else if let uuid {
            loginAccounts[fingerprint] = .resolved(uuid)
        } else {
            loginAccounts[fingerprint] = .unresolvable(
                at: Date(), accessToken: accessTokenFingerprint(credentials), failures: priorFailures + 1)
        }
        loginAccountsLock.unlock()
        if uuid == nil {
            LoggingService.shared.log("resolveLoginAccount: could not look up the keychain login's account; will retry")
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
        // A lineage handed off under working holders may still sit in a
        // session's memory; refreshing it here would be a second use of its
        // single-use refresh token. Wait until every holder has released it.
        if let fingerprint = systemLoginFingerprint(mainJSON), let record = handoffRecord(for: fingerprint) {
            guard lineageIsReleased(record) else {
                LoggingService.shared.log("switchMainLogin: '\(profileName)''s stored login was handed off under \(record.holderPids.count) working session(s) and not every one has released it yet; not refreshing it (retried next tick)")
                return nil
            }
            forgetHandoff(fingerprint)
        }
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

    // MARK: - Hand-off records (replaced lineages possibly still held)

    static let handoffRecordsKey = "mainLoginHandoffRecords"
    private var handoffRecordsInMemory: [MainLoginSwapPolicy.HandoffRecord] = []

    private func loadHandoffRecords() -> [MainLoginSwapPolicy.HandoffRecord] {
        if AppEnvironment.isRunningTests { return handoffRecordsInMemory }
        guard let data = UserDefaults.standard.data(forKey: Self.handoffRecordsKey),
              let records = try? JSONDecoder().decode([MainLoginSwapPolicy.HandoffRecord].self, from: data) else { return [] }
        return records
    }

    private func saveHandoffRecords(_ records: [MainLoginSwapPolicy.HandoffRecord]) {
        if AppEnvironment.isRunningTests { handoffRecordsInMemory = records; return }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: Self.handoffRecordsKey)
        }
    }

    func recordHandoff(_ record: MainLoginSwapPolicy.HandoffRecord) {
        // Old records are dropped only when nobody can be holding them any more.
        var records = loadHandoffRecords().filter {
            $0.fingerprint != record.fingerprint
                && !MainLoginSwapPolicy.isPrunable($0, now: record.at, process: holderProcess)
        }
        records.append(record)
        saveHandoffRecords(records)
        LoggingService.shared.log("switchMainLogin: recorded hand-off of the replaced login under \(record.holderPids.count) working session(s); it is not refreshed until they release it")
    }

    func handoffRecord(for fingerprint: String) -> MainLoginSwapPolicy.HandoffRecord? {
        loadHandoffRecords().first { $0.fingerprint == fingerprint }
    }

    func forgetHandoff(_ fingerprint: String) {
        saveHandoffRecords(loadHandoffRecords().filter { $0.fingerprint != fingerprint })
    }

    /// `kill(pid, 0)`: 0 or EPERM means the process exists; ESRCH means gone.
    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Where Claude Code records live sessions and transcripts. Tests point
    /// these at a temporary directory.
    var sessionsDirectory: URL = Constants.ClaudePaths.claudeDirectory.appendingPathComponent("sessions")
    var projectsDirectory: URL = Constants.ClaudePaths.projectsDirectory

    /// A recorded holder's pid as seen now (exited, or running since when).
    var holderProcess: (Int32) -> MainLoginSwapPolicy.HolderProcess = { pid in
        if let started = ProcessListing.startTime(pid: pid) { return .running(startedAt: started) }
        return ClaudeCodeSyncService.processIsAlive(pid) ? .running(startedAt: nil) : .gone
    }

    /// The last part of a transcript read for the release proof: enough for
    /// the requests since a hand-off without reading a long session whole.
    static let transcriptTailBytes = 1 << 20

    /// Whether a holder made a request after `at` that was answered, from its
    /// own transcript (`sessions/<pid>.json` -> `projects/<project>/<sessionId>.jsonl`).
    func holderRequestedAfter(pid: Int32, at: Date) -> Bool {
        guard let transcript = MainLoginSwapPolicy.holderTranscriptURL(
            pid: pid, sessionsDirectory: sessionsDirectory, projectsDirectory: projectsDirectory),
              let handle = try? FileHandle(forReadingFrom: transcript) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return false }
        let offset = size > UInt64(Self.transcriptTailBytes) ? size - UInt64(Self.transcriptTailBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return false }
        return MainLoginSwapPolicy.transcriptShowsAnsweredRequest(after: at, transcript: text)
    }

    /// Whether Claude Code has a live-session record for `pid`.
    func holderHasSession(_ pid: Int32) -> Bool {
        FileManager.default.fileExists(atPath: sessionsDirectory.appendingPathComponent("\(pid).json").path)
    }

    /// Whether every holder of a handed-off lineage has released it.
    func lineageIsReleased(_ record: MainLoginSwapPolicy.HandoffRecord) -> Bool {
        MainLoginSwapPolicy.lineageReleased(
            record, process: holderProcess, hasSession: holderHasSession,
            requestedAfter: { self.holderRequestedAfter(pid: $0, at: $1) })
    }

    // MARK: - Targets that keep refusing the swap

    private var switchRefusals = SwitchRefusalTracker()

    /// Notes what a switch to `profile` did with the shared login. True when
    /// the user should be told about a refusal now (once per episode).
    func noteSwitchOutcome(_ outcome: MainLoginSwitch, for profile: Profile, now: Date = Date()) -> Bool {
        switchRefusals.record(outcome, target: profile.id,
                              loginFingerprint: profile.cliCredentialsJSON.flatMap(systemLoginFingerprint), now: now)
    }

    /// The switch to `profile` keeps being refused: not "ready".
    func isRefusingSwitch(_ profile: Profile, now: Date = Date()) -> Bool {
        switchRefusals.isRefusing(profile.id, loginFingerprint: profile.cliCredentialsJSON.flatMap(systemLoginFingerprint), now: now)
    }

    func resetSwitchRefusalsForTesting() {
        switchRefusals = SwitchRefusalTracker()
    }

    /// True while `profile`'s stored login was handed off under working
    /// holders that have not released it AND it needs a refresh before it can
    /// be written: a switch to it would refuse to refresh and throw, every
    /// tick, so it is not a switch target until released.
    func isHeldByHandoff(_ profile: Profile, now: Date = Date()) -> Bool {
        guard let json = profile.cliCredentialsJSON, let fingerprint = systemLoginFingerprint(json),
              let record = handoffRecord(for: fingerprint) else { return false }
        if let expiry = extractTokenExpiry(from: json), expiry.timeIntervalSince(now) > Self.refreshLeewaySeconds {
            return false   // usable as stored: the switch writes it without a refresh
        }
        return !lineageIsReleased(record)
    }

    /// Not a switch target now: a dead login, a stored login held back by an
    /// unreleased hand-off that would need a refresh, or one whose swap is
    /// refused for a reason that will not clear by itself.
    func isUnavailableAsTarget(for profile: Profile) -> Bool {
        isLoginDead(for: profile) || isHeldByHandoff(profile)
            || switchRefusals.isUnavailable(profile.id, loginFingerprint: profile.cliCredentialsJSON.flatMap(systemLoginFingerprint))
    }

    func resetHandoffRecordsForTesting() {
        handoffRecordsInMemory = []
    }

    /// True when the login Claude Code's main sessions use (or would use after
    /// a switch) for this profile has been rejected by the OAuth server, i.e.
    /// the account needs a fresh `/login`.
    ///
    /// For the active profile that is the system keychain login when it is
    /// proven to be this profile's (Claude Code may have rotated it); when it
    /// is not — another account's login, or one not yet looked up — the
    /// profile is judged by its stored login, the one a switch would apply,
    /// like any other profile. Judging nothing in that case read "alive" for a
    /// dead login whenever the tracker's active profile and the keychain
    /// disagreed (probe D, gate on 2070d8b). For any other profile it is the
    /// stored login.
    func isLoginDead(for profile: Profile) -> Bool {
        guard !deadLogins.isEmpty else { return false }

        let mainJSON: String?
        if ProfileStore.shared.loadActiveProfileId() == profile.id {
            mainJSON = (try? readSystemCredentials()).flatMap { systemCredentials($0, belongTo: profile) ? $0 : nil }
                ?? profile.cliCredentialsJSON
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
    private func persistProfileCredentialsJSON(profileId: UUID, json: String, ownMainLogin: Bool? = nil, provenance: String? = nil) {
        var reloaded = ProfileStore.shared.loadProfiles()
        guard let idx = reloaded.firstIndex(where: { $0.id == profileId }) else { return }
        let own = ownMainLogin ?? reloaded[idx].hasOwnMainLogin
        let origin = provenance ?? reloaded[idx].mainLoginProvenance
        guard reloaded[idx].cliCredentialsJSON != json || reloaded[idx].hasOwnMainLogin != own
                || reloaded[idx].mainLoginProvenance != origin else {
            return
        }
        reloaded[idx].cliCredentialsJSON = json
        reloaded[idx].hasOwnMainLogin = own
        reloaded[idx].mainLoginProvenance = origin
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

    /// Whether `resyncBeforeSwitching` may store `freshJSON` (the shared
    /// login) as `profile`'s own login.
    func resyncAllowed(freshJSON: String, profile: Profile) -> Bool {
        // Claude Code ROTATES refresh tokens, so for the same account the shared
        // login's token routinely differs from the stored one; that rotation is
        // what this captures. Proof is the login's own resolved account lookup,
        // or an unchanged refresh token. `.claude.json` is never used: after a
        // /login it can name the previous account.
        if loginIsProvenToBelong(freshJSON, to: profile) { return true }
        LoggingService.shared.log("⚠️ resyncBeforeSwitching: skipping for '\(profile.name)' — Claude Code's login is not proven to be this account (\(provenLoginAccountUuid(freshJSON) == nil ? "account lookup not resolved" : "a different account"))")
        return false
    }

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
        if let profile = profiles.first(where: { $0.id == profileId }), !resyncAllowed(freshJSON: freshJSON, profile: profile) {
            return
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
        profiles[index].mainLoginProvenance = "keychain"
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
    case loginNotProven(String)

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
        case .loginNotProven(let why):
            return why
        }
    }
}
