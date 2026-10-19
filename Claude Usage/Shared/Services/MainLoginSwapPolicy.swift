import Foundation

/// When the tracker may rewrite Claude Code's shared login — the item in the
/// main keychain entry that every `claude` started without `CLAUDE_CONFIG_DIR`
/// uses.
///
/// Claude Code OAuth refresh tokens are single-use, and every running session
/// keeps its login in memory — but a session re-reads the keychain before its
/// next request once `~/.claude/.credentials.json`'s mtime changes (measured
/// 2026-10-14 against Claude Code 2.1.299; claude-rotate
/// `tests/test_session_follows_login.sh`). So running sessions FOLLOW a swap:
/// the tracker writes the keychain, touches the stub, and writes the holders
/// down (`HandoffRecord`) so the replaced lineage is not refreshed until every
/// one of them has released it. They never block the swap. (Until 2026-10-14
/// they did, and that refusal — eleven ticks of `sessionsRunning` while the
/// account climbed from 90% to the limit — killed ~20 agents.)
///
/// What still refuses: the shared login is rewritten only over a login the
/// tracker knows — a stored copy, or one proven by its account lookup — never
/// over a `/login` it has not yet captured; and only into the keychain entry
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
        /// False when only the executable path is known (the spawn-free
        /// libproc listing): `command` is then argv0 alone, without the script
        /// a `node` runs.
        let argvKnown: Bool

        init(pid: Int32, ppid: Int32 = 1, command: String, configDir: String? = nil, argvKnown: Bool = true) {
            self.pid = pid
            self.ppid = ppid
            self.command = command
            self.configDir = (configDir?.isEmpty ?? true) ? nil : configDir
            self.argvKnown = argvKnown
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
    ///
    /// Without its arguments (the libproc fallback, `argvKnown == false`) a
    /// `node` process may be `node …/cli.js`, and nothing can tell it apart:
    /// it counts as Claude Code, refusal-leaning like the rest of the fallback.
    static func isClaudeCode(_ process: RunningProcess) -> Bool {
        let argv = process.argvKnown ? process.command.split(separator: " ").map(String.init) : [process.command]
        guard let argv0 = argv.first else { return false }
        let base = URL(fileURLWithPath: argv0).lastPathComponent
        if base == "claude" { return true }
        if isNameOnlyNode(process) { return true }
        if versionedBinary.firstMatch(in: argv0, range: NSRange(argv0.startIndex..., in: argv0)) != nil { return true }
        return argv.prefix(2).contains { $0.hasSuffix("@anthropic-ai/claude-code/cli.js") }
    }

    /// A `node` whose arguments could not be read: counted as Claude Code on
    /// its name alone.
    static func isNameOnlyNode(_ process: RunningProcess) -> Bool {
        !process.argvKnown && URL(fileURLWithPath: process.command).lastPathComponent.hasPrefix("node")
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

    /// A refusal that will not clear by itself: retrying every tick only
    /// repeats it (and its notification).
    static func isRetryable(_ refusal: Refusal) -> Bool {
        switch refusal {
        case .untrustedStoredLogin, .notTheSharedLoginEntry: return false
        case .unknownKeychainLogin, .processListUnavailable, .keychainUnreadable: return true
        }
    }

    /// Decides a compare-and-swap of the shared login. Running sessions are
    /// not an input: they follow the swap (see the type comment).
    ///
    /// - `keychainFingerprint`: fingerprint of the login in the keychain now
    ///   (nil when the entry is empty or missing).
    /// - `knownFingerprints`: fingerprints of the logins the tracker knows —
    ///   its stored copies, plus the keychain login itself when its account
    ///   lookup proved it to be one of the profiles'. The keychain login must
    ///   be one of them, so a `/login` to an account the tracker has not
    ///   adopted is never overwritten.
    ///
    /// Returns nil when the rewrite may proceed. An empty keychain may always
    /// be written: there is nothing to clobber.
    static func refusal(keychainFingerprint: String?, knownFingerprints: Set<String>) -> Refusal? {
        if let current = keychainFingerprint, !knownFingerprints.contains(current) {
            return .unknownKeychainLogin
        }
        return nil
    }

    /// A shared login replaced under holders: which processes held it, and
    /// when the reload signal was sent.
    struct HandoffRecord: Equatable, Codable {
        let fingerprint: String
        let holderPids: [Int32]
        let at: Date
        /// Each holder's process start time (key: pid), so a recycled pid is
        /// told from the holder. Absent in records written by older builds.
        var holderStartTimes: [String: Date]? = nil
        /// The holders that had a `sessions/<pid>.json` when the hand-off was
        /// recorded, i.e. were Claude Code sessions. Absent in older records.
        var holdersWithSession: [Int32]? = nil
        /// The holders counted only because they are a `node` whose arguments
        /// could not be read (`isNameOnlyNode`): possibly not Claude Code at
        /// all. Absent in older records.
        var holdersByNameOnly: [Int32]? = nil
    }

    /// After this long a hand-off record is PRUNED, but only when every
    /// holder is gone (exited, or its pid reused). It never releases a lineage
    /// a live holder may still carry: see `lineageReleased`.
    static let handoffRecordTTL: TimeInterval = 8 * 3600

    /// A recorded holder as seen now.
    enum HolderProcess: Equatable {
        /// No such process: the holder exited.
        case gone
        /// A process with this pid is running; `startedAt` is nil when it
        /// cannot be read.
        case running(startedAt: Date?)
    }

    /// True once every holder has released the replaced lineage. Until then
    /// the tracker must not refresh that stored login: the session may still
    /// carry the same single-use refresh token.
    ///
    /// A holder has released it when:
    /// - it exited, or its pid now belongs to a different process (the start
    ///   time differs from the one recorded: pids are reused);
    /// - or it was counted ONLY as a `node` with unknown arguments
    ///   (`holdersByNameOnly`: without `ps` every node is a holder, mc daemons
    ///   and vite included) and was never a Claude Code session: no
    ///   `sessions/<pid>.json` when the hand-off was recorded and none now. A
    ///   holder identified by its arguments (`claude`, the versioned binary,
    ///   `cli.js`) IS Claude Code and gets no such release;
    /// - or it made a NEW request after the signal and got an answer
    ///   (`requestedAfter`): Claude Code re-reads the credentials file's mtime
    ///   before each request and drops its cached login when it changed. A
    ///   transcript merely modified after the signal proves nothing: a reply
    ///   streamed to a request sent BEFORE the swap writes to it too.
    ///
    /// Time alone never releases it. An idle session that still holds the
    /// lineage pins it, and that is the SAFE state: releasing it would let the
    /// tracker refresh a token the session still carries, which logs it out.
    static func lineageReleased(
        _ record: HandoffRecord,
        process: (Int32) -> HolderProcess, hasSession: (Int32) -> Bool, requestedAfter: (Int32, Date) -> Bool
    ) -> Bool {
        record.holderPids.allSatisfy { pid in
            if holderIsGone(record, pid: pid, process: process) { return true }
            if record.holdersByNameOnly?.contains(pid) == true,
               let withSession = record.holdersWithSession, !withSession.contains(pid), !hasSession(pid) { return true }
            return requestedAfter(pid, record.at)
        }
    }

    /// The recorded holder no longer exists: no such process, or the pid now
    /// names a process that started at another time.
    static func holderIsGone(_ record: HandoffRecord, pid: Int32, process: (Int32) -> HolderProcess) -> Bool {
        guard case .running(let startedAt) = process(pid) else { return true }
        if let recorded = record.holderStartTimes?[String(pid)], let startedAt,
           abs(recorded.timeIntervalSince(startedAt)) > 1 { return true }
        return false
    }

    /// A record old enough to drop: past the TTL AND every holder gone.
    static func isPrunable(_ record: HandoffRecord, now: Date, process: (Int32) -> HolderProcess) -> Bool {
        now.timeIntervalSince(record.at) > handoffRecordTTL
            && record.holderPids.allSatisfy { holderIsGone(record, pid: $0, process: process) }
    }

    /// True when a transcript (JSONL, possibly starting mid-line) shows a
    /// request made after `at` that was answered: a `user` entry timestamped
    /// after `at`, followed later in the file by an `assistant` entry.
    static func transcriptShowsAnsweredRequest(after at: Date, transcript: String) -> Bool {
        var requestAfter = false
        for line in transcript.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = entry["type"] as? String else { continue }
            if type == "user", let ts = entry["timestamp"] as? String, let when = parseTimestamp(ts), when > at {
                requestAfter = true
            } else if type == "assistant", requestAfter {
                return true
            }
        }
        return false
    }

    private static let fractionalTimestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainTimestamp = ISO8601DateFormatter()

    private static func parseTimestamp(_ text: String) -> Date? {
        fractionalTimestamp.date(from: text) ?? plainTimestamp.date(from: text)
    }

    /// True when every holder's session is on Fable. A holder on another model,
    /// or one whose model cannot be read, is not assumed to need the Opus
    /// fallback (`fallBackToOpusIfHoldersOnFable`).
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


/// Which accounts have a live claude-rotate CLOUD run (operator, 2026-10-18).
/// Local Claude Code sessions are signalled to reload the shared login on a
/// switch, so they never hold an account; a cloud session launched on an
/// account is the only thing a token refresh could break.
enum CloudRunHold {
    /// A launched run with no end marker is treated as live for this long.
    /// (The ledger has ~1200 launched runs that never recorded an end.)
    static let liveWindow: TimeInterval = 12 * 3600
    private static let endMarkers = ["closed", "landed", "stopped", "dead", "superseded_by"]

    /// Account names (claude-rotate names, e.g. "madmatter") with a live run
    /// in `ndjson` (`~/.claude/cloud/runs.ndjson`: one JSON object per line,
    /// merged per `run`).
    static func activeAccounts(ndjson: String, now: Date = Date()) -> Set<String> {
        var runs: [String: [String: Any]] = [:]
        for line in ndjson.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let run = e["run"] as? String else { continue }
            runs[run, default: [:]].merge(e) { _, new in new }
        }
        let iso = ISO8601DateFormatter()
        var out = Set<String>()
        for (_, r) in runs {
            guard let account = r["account"] as? String, let launched = (r["launched"] as? String).flatMap(iso.date(from:)),
                  now.timeIntervalSince(launched) < liveWindow,
                  !endMarkers.contains(where: { r[$0] != nil && !(r[$0] is NSNull) }) else { continue }
            out.insert(account)
        }
        return out
    }

    /// claude-rotate account name for an email, from `~/.claude-rotate/config.json`.
    static func accountName(forEmail email: String, configJSON: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: configJSON) as? [String: Any],
              let accounts = root["accounts"] as? [[String: Any]] else { return nil }
        return accounts.first { ($0["email"] as? String)?.lowercased() == email.lowercased() }?["name"] as? String
    }
}
