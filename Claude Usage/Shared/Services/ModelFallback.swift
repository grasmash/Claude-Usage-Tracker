import Foundation

/// The last resort when Fable is in use and no account has Fable headroom
/// (operator, 2026-10-11: "App switches default to Opus"). Claude Code does not
/// fall back from Fable by itself on a Fable limit, so the tracker sets Claude
/// Code's default `model` in `~/.claude/settings.json` to Opus, and restores the
/// previous value once Fable is available again.
///
/// Rules:
/// - Only the `model` value changes, by a minimal TEXT edit: the top-level
///   object is tokenised, an existing `"model"` value is spliced (or the key is
///   inserted after the opening brace with the file's indent, or removed on a
///   restore to "unset"), and every other byte is kept. The result must
///   strict-parse to exactly the original object with only `model` changed,
///   or nothing is written.
/// - Refused, never edited: a missing, unreadable or unparseable file, one
///   that is not a JSON object, one with comments (Claude Code accepts JSONC;
///   the user is told to edit the model key by hand), one with duplicate
///   top-level keys, or a `model` that is not a string.
/// - Written atomically: a temp file created with the original mode in the
///   same directory, then rename(2), through a symlink if there is one. Stale
///   temp files from an interrupted edit are swept first.
/// - The record (active, previous, written) is saved BEFORE the rename and
///   cleared if the write fails, so a crash after the rename cannot leave an
///   edit the tracker does not know to undo.
/// - Restore writes the previous value back only if the setting still holds
///   the value the tracker wrote; a user's change in between is left alone and
///   the record dropped.
///
/// Residual race, stated honestly: the file is re-read and compared with what
/// was parsed just before the rename, but nothing locks it. A write by Claude
/// Code or the user that lands between that final read and the rename is lost
/// (the rename replaces it). The window is microseconds and settings.json is
/// written rarely, but it is not zero.
struct ModelFallback {
    static let opusModel = "opus"

    enum Failure: Error, Equatable {
        case unreadable
        case unparseable
        case hasComments
        case duplicateKeys
        case modelNotAString
        case changedDuringEdit
        case verifyMismatch
        case writeFailed(String)

        var message: String {
            switch self {
            case .unreadable: return "settings.json is missing or unreadable"
            case .unparseable: return "settings.json is not a strict JSON object"
            case .hasComments: return "settings.json has comments; edit the model key by hand"
            case .duplicateKeys: return "settings.json has duplicate top-level keys"
            case .modelNotAString: return "settings.json `model` is not a string"
            case .changedDuringEdit: return "settings.json changed while it was being edited"
            case .verifyMismatch: return "the edited settings.json did not verify"
            case .writeFailed(let why): return "could not write settings.json (\(why))"
            }
        }
    }

    enum ApplyResult: Equatable {
        case applied(previous: String?)
        case alreadyApplied
        case failed(Failure)
    }

    enum RestoreResult: Equatable {
        case restored
        case userChanged
        case nothingToRestore
        case failed(Failure)
    }

    private static let activeKey = "ModelFallback.active"
    private static let previousKey = "ModelFallback.previousModel"
    private static let writtenKey = "ModelFallback.writtenModel"
    static let tempPrefix = ".settings.json.claude-usage-"

    let settingsURL: URL
    let defaults: UserDefaults

    init(
        settingsURL: URL = Constants.ClaudePaths.claudeDirectory.appendingPathComponent("settings.json"),
        defaults: UserDefaults = AppEnvironment.userDefaults
    ) {
        self.settingsURL = settingsURL
        self.defaults = defaults
    }

    var isActive: Bool { defaults.bool(forKey: Self.activeKey) }
    private var written: String { defaults.string(forKey: Self.writtenKey) ?? Self.opusModel }

    func applyOpus() -> ApplyResult {
        let target = settingsURL.resolvingSymlinksInPath()
        if isActive {
            if case .success(let doc) = load(target), doc.object["model"] as? String != written {
                LoggingService.shared.log("⚠️ ModelFallback: active, but settings.json `model` is no longer '\(written)' (changed by the user?); leaving it")
            }
            return .alreadyApplied
        }
        let doc: Document
        switch load(target) {
        case .failure(let f): return .failed(f)
        case .success(let d): doc = d
        }
        if doc.object["model"] != nil && !(doc.object["model"] is String) { return .failed(.modelNotAString) }
        let previous = doc.object["model"] as? String
        let edited: Data
        switch doc.settingModel(to: Self.opusModel) {
        case .failure(let f): return .failed(f)
        case .success(let d): edited = d
        }

        // Record first: a crash after the rename must not strand an edit.
        defaults.set(true, forKey: Self.activeKey)
        defaults.set(Self.opusModel, forKey: Self.writtenKey)
        if let previous { defaults.set(previous, forKey: Self.previousKey) } else { defaults.removeObject(forKey: Self.previousKey) }
        if let f = write(edited, to: target, expecting: doc.data) {
            clearRecord()
            return .failed(f)
        }
        return .applied(previous: previous)
    }

    func restore() -> RestoreResult {
        guard isActive else { return .nothingToRestore }
        let target = settingsURL.resolvingSymlinksInPath()
        let doc: Document
        switch load(target) {
        case .failure(let f): return .failed(f)   // record kept; retried later
        case .success(let d): doc = d
        }
        guard doc.object["model"] as? String == written else {
            clearRecord()
            return .userChanged
        }
        let edited: Data
        switch doc.settingModel(to: defaults.string(forKey: Self.previousKey)) {
        case .failure(let f): return .failed(f)
        case .success(let d): edited = d
        }
        if let f = write(edited, to: target, expecting: doc.data) { return .failed(f) }
        clearRecord()
        return .restored
    }

    private func clearRecord() {
        defaults.removeObject(forKey: Self.activeKey)
        defaults.removeObject(forKey: Self.previousKey)
        defaults.removeObject(forKey: Self.writtenKey)
    }

    // MARK: - Reading

    private func load(_ url: URL) -> Result<Document, Failure> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.unreadable) }
        return Document.parse(data)
    }

    // MARK: - Writing

    /// Writes `data` over `url` atomically with the original mode. Returns the
    /// failure (nothing written) or nil.
    private func write(_ data: Data, to url: URL, expecting original: Data) -> Failure? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        sweepStaleTemps(in: dir)
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
        let temp = dir.appendingPathComponent(Self.tempPrefix + UUID().uuidString)
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: mode]) else {
            return .writeFailed("cannot create a temporary file in \(dir.path)")
        }
        guard (try? Data(contentsOf: url)) == original else {
            try? fm.removeItem(at: temp)
            return .changedDuringEdit
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            return .writeFailed("rename errno \(code)")
        }
        return nil
    }

    /// Removes temp files an interrupted edit left behind (older than a minute,
    /// so a concurrent edit's temp is never touched).
    private func sweepStaleTemps(in dir: URL) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix(Self.tempPrefix) {
            let path = dir.appendingPathComponent(name).path
            if let modified = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(modified) > 60 {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}

// MARK: - Minimal text edit of a top-level JSON object

extension ModelFallback {
    /// A strict-parsed settings file plus the byte spans of its top-level members.
    struct Document {
        struct Member {
            let key: String
            let keyStart: Int
            let valueStart: Int
            let valueEnd: Int      // exclusive
            let comma: Int?        // index of the comma after the value, if any
        }

        let data: Data
        let object: [String: Any]
        let openBrace: Int
        let closeBrace: Int
        let members: [Member]

        static func parse(_ data: Data) -> Result<Document, Failure> {
            let b = [UInt8](data)
            if hasComments(b) { return .failure(.hasComments) }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return .failure(.unparseable)
            }
            var scanner = Scanner(b)
            guard let scan = scanner.scanTopLevel() else { return .failure(.unparseable) }
            if Set(scan.members.map { $0.key }).count != scan.members.count { return .failure(.duplicateKeys) }
            return .success(Document(data: data, object: object, openBrace: scan.open, closeBrace: scan.close, members: scan.members))
        }

        /// The file with `model` set to `value` (or removed when nil), every
        /// other byte kept, verified by a strict re-parse.
        func settingModel(to value: String?) -> Result<Data, Failure> {
            var b = [UInt8](data)
            let model = members.firstIndex { $0.key == "model" }
            if let value {
                guard let literal = Self.literal(value) else { return .failure(.verifyMismatch) }
                if let i = model {
                    b.replaceSubrange(members[i].valueStart..<members[i].valueEnd, with: literal)
                } else if let first = members.first {
                    let between = b[(openBrace + 1)..<first.keyStart]
                    let pair = Array(#""model": "#.utf8) + literal + [UInt8(ascii: ",")]
                    if let nl = between.lastIndex(of: UInt8(ascii: "\n")) {
                        let indent = Array(b[(nl + 1)..<first.keyStart])
                        b.insert(contentsOf: [UInt8(ascii: "\n")] + indent + pair, at: openBrace + 1)
                    } else {
                        b.insert(contentsOf: pair + [UInt8(ascii: " ")], at: openBrace + 1)
                    }
                } else {
                    b.insert(contentsOf: Array(#""model": "#.utf8) + literal, at: openBrace + 1)
                }
            } else if let i = model {
                let m = members[i]
                if members.count == 1 {
                    b.removeSubrange((openBrace + 1)..<closeBrace)
                } else if i + 1 < members.count {
                    b.removeSubrange(m.keyStart..<members[i + 1].keyStart)
                } else if let prevComma = members[i - 1].comma {
                    b.removeSubrange(prevComma..<m.valueEnd)
                } else {
                    return .failure(.verifyMismatch)
                }
            }
            let result = Data(b)
            var expected = object
            if let value { expected["model"] = value } else { expected.removeValue(forKey: "model") }
            guard let reparsed = (try? JSONSerialization.jsonObject(with: result)) as? [String: Any],
                  NSDictionary(dictionary: reparsed).isEqual(to: expected),
                  case .success = Document.parse(result) else {
                return .failure(.verifyMismatch)
            }
            return .success(result)
        }

        private static func literal(_ s: String) -> [UInt8]? {
            (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed, .withoutEscapingSlashes])).map { [UInt8]($0) }
        }

        /// `//` or `/*` outside a string literal.
        static func hasComments(_ b: [UInt8]) -> Bool {
            var i = 0
            var inString = false
            while i < b.count {
                let c = b[i]
                if inString {
                    if c == UInt8(ascii: "\\") { i += 2; continue }
                    if c == UInt8(ascii: "\"") { inString = false }
                } else if c == UInt8(ascii: "\"") {
                    inString = true
                } else if c == UInt8(ascii: "/"), i + 1 < b.count,
                          b[i + 1] == UInt8(ascii: "/") || b[i + 1] == UInt8(ascii: "*") {
                    return true
                }
                i += 1
            }
            return false
        }
    }

    /// Finds the top-level members of a JSON object (input already strict-parsed).
    private struct Scanner {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        mutating func skipWS() {
            while i < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
        }

        mutating func skipString() -> Bool {
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { return false }
            i += 1
            while i < b.count {
                if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                if b[i] == UInt8(ascii: "\"") { i += 1; return true }
                i += 1
            }
            return false
        }

        mutating func skipValue() -> Bool {
            guard i < b.count else { return false }
            switch b[i] {
            case UInt8(ascii: "\""):
                return skipString()
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while i < b.count {
                    let c = b[i]
                    if c == UInt8(ascii: "\"") { guard skipString() else { return false }; continue }
                    if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
                    if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    }
                    i += 1
                }
                return false
            default:
                let start = i
                while i < b.count, ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
                return i > start
            }
        }

        mutating func scanTopLevel() -> (open: Int, close: Int, members: [Document.Member])? {
            if b.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
            skipWS()
            guard i < b.count, b[i] == UInt8(ascii: "{") else { return nil }
            let open = i
            i += 1
            var members: [Document.Member] = []
            while true {
                skipWS()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: "}") && members.isEmpty { break }
                let keyStart = i
                guard skipString(),
                      let key = (try? JSONSerialization.jsonObject(with: Data(b[keyStart..<i]), options: .fragmentsAllowed)) as? String
                else { return nil }
                skipWS()
                guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }
                i += 1
                skipWS()
                let valueStart = i
                guard skipValue() else { return nil }
                let valueEnd = i
                skipWS()
                guard i < b.count else { return nil }
                if b[i] == UInt8(ascii: ",") {
                    members.append(.init(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd, comma: i))
                    i += 1
                    continue
                }
                guard b[i] == UInt8(ascii: "}") else { return nil }
                members.append(.init(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: valueEnd, comma: nil))
                break
            }
            let close = i
            i += 1
            skipWS()
            return i == b.count ? (open, close, members) : nil
        }
    }
}
