import Foundation

/// The last resort when Fable is in use and no account has Fable headroom
/// (operator, 2026-10-11: "App switches default to Opus"). Claude Code does not
/// fall back from Fable by itself on a Fable limit, so the tracker sets Claude
/// Code's default `model` in `~/.claude/settings.json` to Opus, and restores the
/// previous value once Fable is available again.
///
/// Rules:
/// - Only the `model` key is touched: read-modify-write of the parsed object,
///   every other key kept, written atomically (temp file + rename in the same
///   directory) with the original file mode, through a symlink if there is one.
/// - The file is re-read just before the rename; if it changed meanwhile
///   (Claude Code or the user wrote it), nothing is written.
/// - An unreadable, missing or unparseable file is never edited.
/// - The previous value is recorded in the tracker's own defaults. Restore
///   writes it back only if the setting still holds the value the tracker
///   wrote; a user's change in between is left alone and the record dropped.
struct ModelFallback {
    static let opusModel = "opus"

    enum ApplyResult: Equatable {
        case applied(previous: String?)
        case alreadyApplied
        case failed(String)
    }

    enum RestoreResult: Equatable {
        case restored
        case userChanged
        case nothingToRestore
        case failed(String)
    }

    private static let activeKey = "ModelFallback.active"
    private static let previousKey = "ModelFallback.previousModel"
    private static let writtenKey = "ModelFallback.writtenModel"

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

    func applyOpus() -> ApplyResult {
        if isActive { return .alreadyApplied }
        let target = settingsURL.resolvingSymlinksInPath()
        let original: Data
        var object: [String: Any]
        switch read(target) {
        case .failure(let reason): return .failed(reason)
        case .success(let (data, json)): original = data; object = json
        }
        let previous = object["model"] as? String
        if object["model"] != nil && previous == nil {
            return .failed("settings.json `model` is not a string; not editing it")
        }
        object["model"] = Self.opusModel
        if let reason = write(object, to: target, expecting: original) { return .failed(reason) }

        defaults.set(true, forKey: Self.activeKey)
        defaults.set(Self.opusModel, forKey: Self.writtenKey)
        if let previous { defaults.set(previous, forKey: Self.previousKey) } else { defaults.removeObject(forKey: Self.previousKey) }
        return .applied(previous: previous)
    }

    func restore() -> RestoreResult {
        guard isActive else { return .nothingToRestore }
        let target = settingsURL.resolvingSymlinksInPath()
        let original: Data
        var object: [String: Any]
        switch read(target) {
        case .failure(let reason): return .failed(reason)   // record kept; retried later
        case .success(let (data, json)): original = data; object = json
        }
        let written = defaults.string(forKey: Self.writtenKey) ?? Self.opusModel
        guard object["model"] as? String == written else {
            clearRecord()
            return .userChanged
        }
        if let previous = defaults.string(forKey: Self.previousKey) {
            object["model"] = previous
        } else {
            object.removeValue(forKey: "model")
        }
        if let reason = write(object, to: target, expecting: original) { return .failed(reason) }
        clearRecord()
        return .restored
    }

    // MARK: - File I/O

    private func clearRecord() {
        defaults.removeObject(forKey: Self.activeKey)
        defaults.removeObject(forKey: Self.previousKey)
        defaults.removeObject(forKey: Self.writtenKey)
    }

    private enum ReadResult { case success((Data, [String: Any])), failure(String) }

    private func read(_ url: URL) -> ReadResult {
        guard let data = try? Data(contentsOf: url) else { return .failure("settings.json is missing or unreadable") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("settings.json does not parse as a JSON object")
        }
        return .success((data, json))
    }

    /// Writes `object` over `url` atomically, keeping the file mode. Returns a
    /// reason on failure (nothing written), nil on success.
    private func write(_ object: [String: Any], to url: URL, expecting original: Data) -> String? {
        let fm = FileManager.default
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "could not serialise settings.json"
        }
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).claude-usage-\(UUID().uuidString)")
        do {
            try data.write(to: temp)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)
        } catch {
            try? fm.removeItem(at: temp)
            return "could not write a temporary settings file: \(error.localizedDescription)"
        }
        // Compare-and-swap: someone else wrote the file since we read it.
        guard (try? Data(contentsOf: url)) == original else {
            try? fm.removeItem(at: temp)
            return "settings.json changed while it was being edited; not writing"
        }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            return "could not replace settings.json (errno \(errno))"
        }
        return nil
    }
}
