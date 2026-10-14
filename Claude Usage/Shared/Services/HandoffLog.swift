import Foundation

/// A durable, human-readable record of every shared-login switch the tracker
/// performs, refuses or fails: `~/Library/Logs/Claude Usage/handoff.log`.
///
/// One line per outcome, KEY="value" pairs, newest last:
///
///     2026-10-14 14:30:01 -0400 HANDOFF from="jrand@…" to="goose@…" reason="near limit: session 86%" holders="18" signalled="yes" raced="0"
///     2026-10-14 14:31:02 -0400 REFUSED from="unknown login" to="goose@…" reason="near limit: session 87%" refusal="unknownKeychainLogin" holders="18"
///
/// The unified log (`LoggingService`) is also written, but it is not retained
/// for long and is hard to query; the 2026-10-14 incident (eleven refused
/// hand-offs, then ~20 agents killed at the limit) had to be reconstructed
/// from it. This file is the place to look after the next hand-off.
///
/// Only names, reasons and counts are written — never a token, never a
/// credential payload.
enum HandoffLog {
    enum Event: String {
        /// The shared login was written and the sessions on it signalled.
        case handoff = "HANDOFF"
        /// The keychain already held the target's login.
        case alreadyOn = "ALREADY-ON"
        /// The policy refused; `refusal=` says why.
        case refused = "REFUSED"
        /// The switch threw before anything was written; `why=` says why.
        case failed = "FAILED"
    }

    /// Where the lines go. Tests point this at a temporary file; outside tests
    /// it is the real log. Under tests it defaults to a temporary file so a test
    /// that forgets to redirect it never writes "from=A to=B" into the real one.
    static var fileURL: URL = AppEnvironment.isRunningTests
        ? FileManager.default.temporaryDirectory.appendingPathComponent("claude-usage-handoff-tests.log")
        : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Claude Usage/handoff.log")

    /// Past this size the file is rotated once to `handoff.log.1`.
    static let maxBytes = 2_000_000

    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// Writes one line and returns it. `fields` follow the three fixed ones.
    @discardableResult
    static func record(_ event: Event, from: String, to: String, reason: String, fields: [(String, String)] = [], at date: Date = Date()) -> String {
        var line = "\(stamp.string(from: date)) \(event.rawValue) from=\(quoted(from)) to=\(quoted(to)) reason=\(quoted(reason))"
        for (key, value) in fields { line += " \(key)=\(quoted(value))" }
        LoggingService.shared.log("handoff.log: \(line)")
        append(line)
        return line
    }

    /// The file's lines, oldest first (for tests and the popover).
    static func lines() -> [String] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func quoted(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\"", with: "'")
        return "\"\(flat)\""
    }

    private static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.intValue, size > maxBytes {
            let rotated = fileURL.deletingLastPathComponent().appendingPathComponent(fileURL.lastPathComponent + ".1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}
