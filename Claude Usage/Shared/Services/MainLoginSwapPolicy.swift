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
/// only when nothing holds it, and only over a login the tracker has seen —
/// never over a `/login` it has not yet captured.
///
/// Pure functions over a process list and keychain fingerprints, so the policy
/// is unit tested without `ps` or the keychain.
enum MainLoginSwapPolicy {

    /// One running process, as `ps -E` reports it.
    struct RunningProcess: Equatable {
        let pid: Int32
        let command: String
        let environment: [String: String]
    }

    /// Parses `ps -axwwE -o pid=,command=` output: one process per line,
    /// `PID command args… KEY=value KEY=value…`. The environment is whatever
    /// trailing tokens look like assignments; arguments that happen to look like
    /// one (`FOO=bar`) are read as environment too, which errs toward counting a
    /// process as a holder.
    static func parsePsOutput(_ text: String) -> [RunningProcess] {
        text.split(separator: "\n").compactMap { line in
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2, let pid = Int32(tokens[0]) else { return nil }
            var command: [String] = []
            var environment: [String: String] = [:]
            for token in tokens.dropFirst() {
                if let separator = token.firstIndex(of: "="),
                   isEnvironmentName(token[token.startIndex..<separator]) {
                    environment[String(token[token.startIndex..<separator])] = String(token[token.index(after: separator)...])
                } else {
                    command.append(token)
                }
            }
            return RunningProcess(pid: pid, command: command.joined(separator: " "), environment: environment)
        }
    }

    private static func isEnvironmentName(_ name: Substring) -> Bool {
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// True for a Claude Code process: the native `claude` binary (by any path)
    /// or the older `node …/@anthropic-ai/claude-code/cli.js` form.
    static func isClaudeCode(_ process: RunningProcess) -> Bool {
        let argv = process.command.split(separator: " ").map(String.init)
        guard let argv0 = argv.first else { return false }
        if URL(fileURLWithPath: argv0).lastPathComponent == "claude" { return true }
        return argv.contains { $0.hasSuffix("@anthropic-ai/claude-code/cli.js") }
    }

    /// The Claude Code processes using the shared login: those started without
    /// a `CLAUDE_CONFIG_DIR`. A process on a per-account config dir holds that
    /// dir's own login, which the tracker never touches.
    static func sharedLoginHolders(in processes: [RunningProcess]) -> [RunningProcess] {
        processes.filter { process in
            guard isClaudeCode(process) else { return false }
            let dir = process.environment["CLAUDE_CONFIG_DIR"] ?? ""
            return dir.isEmpty
        }
    }

    /// Why a rewrite of the shared login was not done.
    enum Refusal: Equatable {
        /// Claude Code sessions are running on the shared login; they hold it.
        case sessionsRunning(count: Int)
        /// The keychain holds a login the tracker never captured (a `/login` it
        /// has not adopted yet, or a foreign account). Never overwrite it.
        case unknownKeychainLogin
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
