import Foundation

/// When the tracker may rewrite Claude Code's shared login — the item in the
/// main keychain entry that every `claude` started without `CLAUDE_CONFIG_DIR`
/// uses.
///
/// Claude Code OAuth refresh tokens are single-use, and every running session
/// keeps its login in memory. Rewriting the shared login while a session holds
/// it leaves two holders of one lineage: whichever refreshes second is logged
/// out ("Login expired · Please run /login"), and a session that still has the
/// old login writes it back over the new one. So the shared login is rewritten
/// only when nothing holds it, only over a login the tracker has seen — never
/// over a `/login` it has not yet captured — and only into the keychain entry
/// that IS the shared login, never a per-config-dir one. When any of that
/// cannot be established (no process list, keychain unreadable) the answer is
/// refuse, never "probably fine".
///
/// Pure functions over a process list, service names and keychain
/// fingerprints, so the policy is unit tested without `ps` or the keychain.
enum MainLoginSwapPolicy {

    /// One running process. Only `CLAUDE_CONFIG_DIR` is kept from its
    /// environment: nothing else is needed, and an environment can carry
    /// secrets (W11).
    struct RunningProcess: Equatable {
        let pid: Int32
        let ppid: Int32
        let command: String
        /// `CLAUDE_CONFIG_DIR` as set in the process's environment; nil when
        /// unset, empty, or the environment could not be read.
        let configDir: String?

        init(pid: Int32, ppid: Int32 = 1, command: String, configDir: String? = nil) {
            self.pid = pid
            self.ppid = ppid
            self.command = command
            self.configDir = (configDir?.isEmpty ?? true) ? nil : configDir
        }
    }

    /// Parses two `ps` listings of the same instant:
    /// - `commands`: `ps -axww -o pid=,ppid=,command=` — the plain command line;
    /// - `withEnvironment`: `ps -axwwE -o pid=,ppid=,command=` — the same with
    ///   the environment appended.
    ///
    /// The environment of a process is ONLY what follows its plain command
    /// line in the second listing. Reading `KEY=value` tokens anywhere in the
    /// line would let an argument such as `claude -p "… CLAUDE_CONFIG_DIR=/x …"`
    /// (free text; `cloud answer` passes such text) masquerade as a pinned
    /// process and escape the holder count (W4). A process whose environment
    /// cannot be aligned (missing from one listing, line truncated) is kept
    /// with `configDir == nil`, i.e. it counts as a shared-login holder when
    /// it is Claude Code — erring toward refusal.
    static func parsePsOutput(commands: String, withEnvironment: String) -> [RunningProcess] {
        var plain: [Int32: (ppid: Int32, command: String)] = [:]
        var order: [Int32] = []
        for line in commands.split(separator: "\n") {
            guard let (pid, ppid, rest) = splitLeading(line) else { continue }
            plain[pid] = (ppid, rest)
            order.append(pid)
        }
        var envRest: [Int32: String] = [:]
        for line in withEnvironment.split(separator: "\n") {
            guard let (pid, _, rest) = splitLeading(line) else { continue }
            envRest[pid] = rest
        }
        return order.compactMap { pid in
            guard let p = plain[pid] else { return nil }
            var configDir: String?
            if let full = envRest[pid], full.hasPrefix(p.command) {
                let envText = full.dropFirst(p.command.count)
                for token in envText.split(separator: " ") where token.hasPrefix("CLAUDE_CONFIG_DIR=") {
                    configDir = String(token.dropFirst("CLAUDE_CONFIG_DIR=".count))
                }
            }
            return RunningProcess(pid: pid, ppid: p.ppid, command: p.command, configDir: configDir)
        }
    }

    /// `PID PPID rest…` with the rest's internal spacing preserved.
    private static func splitLeading(_ line: Substring) -> (Int32, Int32, String)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard let s1 = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<s1]) else { return nil }
        let afterPid = trimmed[s1...].drop(while: { $0 == " " })
        guard let s2 = afterPid.firstIndex(of: " "), let ppid = Int32(afterPid[..<s2]) else { return nil }
        let rest = afterPid[s2...].drop(while: { $0 == " " })
        guard !rest.isEmpty else { return nil }
        return (pid, ppid, String(rest))
    }

    /// `…/claude/versions/<semver>`: Claude Code's native binary as installed
    /// by its own updater (`~/.local/share/claude/versions/2.1.292`), which is
    /// what `happy` and other launchers exec directly. Measured live 2026-10-11:
    /// argv0 was that path, no `CLAUDE_CONFIG_DIR`, parent `claude_local_launcher.cjs`.
    private static let versionedBinary = try! NSRegularExpression(pattern: #"/claude/versions/\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.]+)?$"#)

    /// True for a Claude Code process: the native `claude` binary (by any
    /// path), the updater's versioned binary, or the older
    /// `node …/@anthropic-ai/claude-code/cli.js` form (the script path is the
    /// token right after `node`, so only argv0/argv1 are consulted).
    static func isClaudeCode(_ process: RunningProcess) -> Bool {
        let argv = process.command.split(separator: " ").map(String.init)
        guard let argv0 = argv.first else { return false }
        if URL(fileURLWithPath: argv0).lastPathComponent == "claude" { return true }
        if versionedBinary.firstMatch(in: argv0, range: NSRange(argv0.startIndex..., in: argv0)) != nil { return true }
        return argv.prefix(2).contains { $0.hasSuffix("@anthropic-ai/claude-code/cli.js") }
    }

    /// True for a process known to launch Claude Code as a child: `happy`'s
    /// `claude_local_launcher.cjs` or the `happy` CLI itself. Matched ONLY on
    /// argv0 and path-shaped tokens (containing `/`), so free text in a real
    /// claude's arguments (`--append-system-prompt "… be happy …"`) never turns
    /// it into a "launcher" whose MCP children would then count as holders.
    /// The Claude desktop app is deliberately NOT a launcher: its Electron
    /// helpers would be permanent "holders" and refuse every switch.
    static func isClaudeLauncher(_ process: RunningProcess) -> Bool {
        let argv = process.command.split(separator: " ").map(String.init)
        guard let argv0 = argv.first else { return false }
        let candidates = [argv0] + argv.dropFirst().filter { $0.contains("/") }
        return candidates.contains { token in
            let base = URL(fileURLWithPath: token).lastPathComponent
            return base == "claude_local_launcher.cjs" || base == "claude_local_launcher.js"
                || base == "happy" || base == "happy.mjs" || base == "happy.js" || base == "happy.cjs"
                || token.contains("/happy-coder/")
        }
    }

    /// The Claude Code processes using the shared login: those with no
    /// `CLAUDE_CONFIG_DIR` (or none we could read). A process on a per-account
    /// config dir holds that dir's own login, which the tracker never touches.
    /// A child of a known launcher is counted even when its binary is not
    /// recognised — that is where an unrecognised Claude Code is most likely
    /// to be — unless its argv0 is inside an app bundle's `Claude.app/`.
    static func sharedLoginHolders(in processes: [RunningProcess]) -> [RunningProcess] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return processes.filter { process in
            guard process.configDir == nil else { return false }
            if isClaudeCode(process) { return true }
            if let parent = byPid[process.ppid], isClaudeLauncher(parent), !isClaudeLauncher(process),
               !(process.command.split(separator: " ").first?.contains("Claude.app/") ?? false) {
                return true
            }
            return false
        }
    }

    /// The Claude Code processes running on one specific config dir (W8: an
    /// import must not be picked up while `claude-usage-login` is still in it).
    static func processes(onConfigDir dir: String, in processes: [RunningProcess]) -> [RunningProcess] {
        let target = URL(fileURLWithPath: dir).standardizedFileURL.path
        return processes.filter { process in
            guard let d = process.configDir, isClaudeCode(process) else { return false }
            return URL(fileURLWithPath: d).standardizedFileURL.path == target
        }
    }

    /// The only keychain entries that ARE the shared login: the legacy name and
    /// the hashed name Claude Code derives from the default `~/.claude` dir.
    /// Any other `Claude Code-credentials-<hash>` belongs to another config dir
    /// and is never a target for the swap, whatever `resolveServiceName` found.
    static func isSharedLoginServiceName(_ name: String, claudeDirectoryHash: String) -> Bool {
        name == "Claude Code-credentials" || name == "Claude Code-credentials-\(claudeDirectoryHash)"
    }

    /// Why a stored main login may not be written into the shared entry (W6,
    /// W15): a login an older build stored may be a COPY of a lineage some
    /// session holds (a pinned config dir's, or a bare session's that was never
    /// swapped out under the guard). Writing that copy makes bare sessions a
    /// second holder of it.
    enum StoredLoginDistrust: Equatable {
        /// Its refresh token IS a pinned entry's: a copy, beyond doubt.
        case copyOfPinnedEntry
        /// The stored login predates this build (no record of where it came
        /// from). It is trusted again once this build re-captures it from the
        /// shared keychain (`keychain`) or it is re-imported via
        /// `claude-usage-login` (`import`).
        case unknownProvenance
    }

    /// `storedRefreshToken`: the target's stored main login's refresh token;
    /// `pinnedRefreshTokens`: the refresh tokens of every pinned entry in the
    /// keychain; `provenance`: the recorded origin of the stored login
    /// (`import`, `keychain`, or nil for a login an older build stored).
    static func distrust(
        storedRefreshToken: String?,
        pinnedRefreshTokens: [String],
        provenance: String?
    ) -> StoredLoginDistrust? {
        if let token = storedRefreshToken, pinnedRefreshTokens.contains(token) { return .copyOfPinnedEntry }
        if provenance == nil { return .unknownProvenance }
        return nil
    }

    /// Why a rewrite of the shared login was not done.
    enum Refusal: Equatable {
        /// Claude Code sessions are running on the shared login; they hold it.
        case sessionsRunning(count: Int)
        /// The keychain holds a login the tracker never captured (a `/login` it
        /// has not adopted yet, or a foreign account). Never overwrite it.
        case unknownKeychainLogin
        /// The resolved keychain entry is not the shared login's (a pinned,
        /// per-config-dir entry); never written.
        case notTheSharedLoginEntry(service: String)
        /// `ps` failed, so nothing is known about holders (C1).
        case processListUnavailable
        /// The keychain could not be read (timeout, launch failure, error), so
        /// "empty" cannot be told from "unknown" (C2).
        case keychainUnreadable
        /// The stored login may be a copy of a pinned lineage (W6).
        case untrustedStoredLogin(StoredLoginDistrust)
    }

    /// Decides a compare-and-swap of the shared login.
    ///
    /// - `holders`: Claude Code processes on the shared login right now.
    /// - `keychainFingerprint`: fingerprint of the login in the keychain now
    ///   (nil when the entry is empty or missing).
    /// - `knownFingerprints`: fingerprints of the logins the tracker has
    ///   captured from the keychain. The keychain login must be one of them,
    ///   so a login that rotated or changed since the last capture (another
    ///   refresher exists, or the user ran `/login`) is never overwritten.
    ///
    /// - `keychainLoginSpent`: the keychain login's account is at a limit (or
    ///   its login is dead). Its sessions are stranded: every request they make
    ///   is refused, so holding them there protects nothing, and leaving them
    ///   is the outage auto-switch exists to prevent (2026-10-11: ten sessions
    ///   sat on a spent weekly limit while the swap was refused each cycle).
    ///   Running sessions then do not block; the compare-and-swap still does.
    ///
    /// Returns nil when the rewrite may proceed. An empty keychain may always
    /// be written: there is nothing to clobber.
    /// - `keychainLoginNearLimit`: the keychain login's account is near its
    ///   limit on a fresh reading (`AutoSwitchPolicy.isNearLimit`) and a
    ///   proactive hand-off is wanted. Working sessions then do not block
    ///   either: they are told to reload (the credentials file is touched) and
    ///   pick the new login up before their next request, while the replaced
    ///   login's lineage is held back from any refresh until every holder has
    ///   released it (`lineageReleased`). The compare-and-swap still holds.
    static func refusal(
        holders: Int,
        keychainFingerprint: String?,
        knownFingerprints: Set<String>,
        keychainLoginSpent: Bool = false,
        keychainLoginNearLimit: Bool = false
    ) -> Refusal? {
        if holders > 0 && !keychainLoginSpent && !keychainLoginNearLimit { return .sessionsRunning(count: holders) }
        if let current = keychainFingerprint, !knownFingerprints.contains(current) {
            return .unknownKeychainLogin
        }
        return nil
    }

    /// The stored main logins of every account Claude Code cannot use right
    /// now: a session, weekly (or, on Fable, Fable weekly) window at 100% that
    /// has not reset yet, or a dead login. The reading need not be fresh: a
    /// spent window stays spent until its reset time, which the effective
    /// percentages already honour, and the tracker stops polling an account
    /// once it is no longer the active profile. A spent Fable-weekly quota
    /// is not here: see `fableSpentLogins`.
    static func spentLogins(in profiles: [Profile], isLoginDead: (Profile) -> Bool) -> [String] {
        profiles.compactMap { profile in
            guard let json = profile.cliCredentialsJSON else { return nil }
            let atLimit = profile.claudeUsage?.isLimitReached ?? false
            return atLimit || isLoginDead(profile) ? json : nil
        }
    }

    /// The stored main logins of every account whose FRESH reading is at or
    /// above the hand-off threshold (`AutoSwitchPolicy.isNearLimit`). A stale
    /// reading is not here: a hand-off moves working sessions, and that is
    /// done on evidence only.
    static func nearLimitLogins(in profiles: [Profile], usingFable: Bool, now: Date = Date()) -> [String] {
        profiles.compactMap { profile in
            guard let json = profile.cliCredentialsJSON, let usage = profile.claudeUsage,
                  AutoSwitchPolicy.isNearLimit(usage, usingFable: usingFable, now: now) else { return nil }
            return json
        }
    }

    /// A shared login replaced under WORKING holders (a proactive hand-off):
    /// which processes held it, and when the reload signal was sent.
    struct HandoffRecord: Equatable, Codable {
        let fingerprint: String
        let holderPids: [Int32]
        let at: Date
    }

    /// True once every holder has released the replaced lineage: the process
    /// exited, or it made a request after the signal (`lastRequestAt` — the
    /// mtime of its transcript; Claude Code re-reads the credentials file's
    /// mtime before each request and drops its cached login when it changed).
    /// A holder with no observable request is assumed to still hold it. Until
    /// this is true the tracker must not refresh that stored login: the
    /// session may still carry the same single-use refresh token.
    static func lineageReleased(
        _ record: HandoffRecord, alive: (Int32) -> Bool, lastRequestAt: (Int32) -> Date?
    ) -> Bool {
        record.holderPids.allSatisfy { pid in
            guard alive(pid) else { return true }
            guard let last = lastRequestAt(pid) else { return false }
            return last > record.at
        }
    }

    /// The stored main logins whose Fable weekly quota is at 100% and has not
    /// reset. Spent for the swap only when every holder is on Fable
    /// (`allHoldersOnFable`): a session on another model is still working.
    static func fableSpentLogins(in profiles: [Profile]) -> [String] {
        profiles.compactMap { profile in
            guard let json = profile.cliCredentialsJSON,
                  let usage = profile.claudeUsage, usage.effectiveFableWeeklyPercentage >= 100.0 else { return nil }
            return json
        }
    }

    /// True when every holder's session is on Fable. A holder on another model,
    /// or one whose model cannot be read, is not assumed stranded.
    static func allHoldersOnFable(_ holders: [RunningProcess], modelOf: (Int32) -> String?) -> Bool {
        !holders.isEmpty && holders.allSatisfy { AutoSwitchPolicy.isFableModel(modelOf($0.pid)) }
    }

    /// The model a holder's own session last answered with: Claude Code
    /// records each live session in `sessions/<pid>.json` (`sessionId`), and
    /// the transcript is `projects/<project>/<sessionId>.jsonl`. nil when
    /// either is missing or has no real reply yet.
    /// Claude Code session ids are UUIDs: only `[A-Za-z0-9-]` is followed into
    /// a file name (no `.`, `/`, spaces or anything that could leave the dir).
    static func isSessionIdShaped(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
        }
    }

    static func holderModel(pid: Int32, sessionsDirectory: URL, projectsDirectory: URL) -> String? {
        guard let transcript = holderTranscriptURL(pid: pid, sessionsDirectory: sessionsDirectory, projectsDirectory: projectsDirectory) else { return nil }
        return AutoSwitchPolicy.latestAssistantModel(in: transcript)
    }

    /// The transcript file of a holder's live session, or nil when the session
    /// record or the transcript is missing.
    static func holderTranscriptURL(pid: Int32, sessionsDirectory: URL, projectsDirectory: URL) -> URL? {
        let record = sessionsDirectory.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: record),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["sessionId"] as? String, isSessionIdShaped(sessionId) else { return nil }
        guard let projects = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        for dir in projects {
            let transcript = dir.appendingPathComponent("\(sessionId).jsonl")
            if FileManager.default.fileExists(atPath: transcript.path) { return transcript }
        }
        return nil
    }

    /// Only one tracker may run per user: two would be two refreshers and two
    /// writers of the same logins. `others` are the running applications with
    /// this bundle identifier; this process must quit when any other exists.
    static func shouldQuitAsDuplicateInstance(myPid: Int32, instancePids: [Int32]) -> Bool {
        instancePids.contains { $0 != myPid }
    }
}

/// A FIFO mutex for async code: `switchMainLogin` must never run twice at
/// once (two refreshes of one stored login, or two writes racing each other).
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
