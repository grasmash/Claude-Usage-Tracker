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
/// that IS the shared login, never a per-config-dir one.
///
/// Pure functions over a process list, service names and keychain
/// fingerprints, so the policy is unit tested without `ps` or the keychain.
enum MainLoginSwapPolicy {

    /// One running process, as `ps -E` reports it.
    struct RunningProcess: Equatable {
        let pid: Int32
        let ppid: Int32
        let command: String
        let environment: [String: String]

        init(pid: Int32, ppid: Int32 = 1, command: String, environment: [String: String]) {
            self.pid = pid
            self.ppid = ppid
            self.command = command
            self.environment = environment
        }
    }

    /// Parses `ps -axwwE -o pid=,ppid=,command=` output: one process per line,
    /// `PID PPID command args… KEY=value KEY=value…`. The environment is
    /// whatever trailing tokens look like assignments; arguments that happen to
    /// look like one (`FOO=bar`) are read as environment too, which errs toward
    /// counting a process as a holder.
    static func parsePsOutput(_ text: String) -> [RunningProcess] {
        text.split(separator: "\n").compactMap { line in
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 3, let pid = Int32(tokens[0]), let ppid = Int32(tokens[1]) else { return nil }
            var command: [String] = []
            var environment: [String: String] = [:]
            for token in tokens.dropFirst(2) {
                if let separator = token.firstIndex(of: "="),
                   isEnvironmentName(token[token.startIndex..<separator]) {
                    environment[String(token[token.startIndex..<separator])] = String(token[token.index(after: separator)...])
                } else {
                    command.append(token)
                }
            }
            return RunningProcess(pid: pid, ppid: ppid, command: command.joined(separator: " "), environment: environment)
        }
    }

    private static func isEnvironmentName(_ name: Substring) -> Bool {
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// `…/claude/versions/<semver>`: Claude Code's native binary as installed
    /// by its own updater (`~/.local/share/claude/versions/2.1.292`), which is
    /// what `happy` and other launchers exec directly. Measured live 2026-10-11:
    /// argv0 was that path, no `CLAUDE_CONFIG_DIR`, parent `claude_local_launcher.cjs`.
    private static let versionedBinary = try! NSRegularExpression(pattern: #"/claude/versions/\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.]+)?$"#)

    /// True for a Claude Code process: the native `claude` binary (by any
    /// path), the updater's versioned binary, or the older
    /// `node …/@anthropic-ai/claude-code/cli.js` form.
    static func isClaudeCode(_ process: RunningProcess) -> Bool {
        let argv = process.command.split(separator: " ").map(String.init)
        guard let argv0 = argv.first else { return false }
        if URL(fileURLWithPath: argv0).lastPathComponent == "claude" { return true }
        if versionedBinary.firstMatch(in: argv0, range: NSRange(argv0.startIndex..., in: argv0)) != nil { return true }
        return argv.contains { $0.hasSuffix("@anthropic-ai/claude-code/cli.js") }
    }

    /// True for a process known to launch Claude Code as a child: `happy`
    /// (`claude_local_launcher.cjs`, the `happy` CLI) and the Claude desktop
    /// app. Any child of one that is not on its own config dir is counted as a
    /// holder even when its binary is not recognised, because that is exactly
    /// where an unrecognised Claude Code is most likely to be.
    static func isClaudeLauncher(_ process: RunningProcess) -> Bool {
        let argv = process.command.split(separator: " ").map(String.init)
        return argv.contains { token in
            let base = URL(fileURLWithPath: token).lastPathComponent
            return token.contains("claude_local_launcher")
                || base == "happy" || base.hasPrefix("happy.") || token.contains("/happy-coder/")
                || token.contains("Claude.app/Contents/MacOS/")
        }
    }

    /// The Claude Code processes using the shared login: those started without
    /// a `CLAUDE_CONFIG_DIR`. A process on a per-account config dir holds that
    /// dir's own login, which the tracker never touches.
    static func sharedLoginHolders(in processes: [RunningProcess]) -> [RunningProcess] {
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        return processes.filter { process in
            let dir = process.environment["CLAUDE_CONFIG_DIR"] ?? ""
            guard dir.isEmpty else { return false }
            if isClaudeCode(process) { return true }
            if let parent = byPid[process.ppid], isClaudeLauncher(parent), !isClaudeLauncher(process) { return true }
            return false
        }
    }

    /// The only keychain entries that ARE the shared login: the legacy name and
    /// the hashed name Claude Code derives from the default `~/.claude` dir.
    /// Any other `Claude Code-credentials-<hash>` belongs to another config dir
    /// and is never a target for the swap, whatever `resolveServiceName` found.
    static func isSharedLoginServiceName(_ name: String, claudeDirectoryHash: String) -> Bool {
        name == "Claude Code-credentials" || name == "Claude Code-credentials-\(claudeDirectoryHash)"
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
    /// Returns nil when the rewrite may proceed. An empty keychain may always
    /// be written: there is nothing to clobber.
    static func refusal(
        holders: Int,
        keychainFingerprint: String?,
        knownFingerprints: Set<String>
    ) -> Refusal? {
        if holders > 0 { return .sessionsRunning(count: holders) }
        if let current = keychainFingerprint, !knownFingerprints.contains(current) {
            return .unknownKeychainLogin
        }
        return nil
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
