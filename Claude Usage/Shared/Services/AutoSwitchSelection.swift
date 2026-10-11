import Foundation

/// The account the tracker has chosen for NEW work, written to
/// `~/.claude/.autoswitch-selected` on every switch (automatic or by click).
///
/// This is how rotation reaches sessions without rewriting the login running
/// sessions hold: `cca` (claude-rotate) reads the file and starts the next
/// session in that account's own config dir, whose login nothing else uses.
/// The file names the account; it never carries a token.
struct AutoSwitchSelection: Equatable {
    var profileName: String
    var email: String?
    var accountUuid: String?
    var selectedAt: Date
    /// `auto` for a switch the tracker made on a limit or dead login, `user`
    /// for a click in the menu.
    var selectedBy: String

    static let fileName = ".autoswitch-selected"

    static var defaultFileURL: URL {
        Constants.ClaudePaths.claudeDirectory.appendingPathComponent(fileName)
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `KEY=value` lines, like `.autoswitch-state`, so a shell can `sed` them.
    func fileContents() -> String {
        var lines = [
            "SELECTED_PROFILE=\(profileName)",
            "SELECTED_EMAIL=\(email ?? "")",
            "SELECTED_ACCOUNT_UUID=\(accountUuid ?? "")",
            "SELECTED_AT=\(Self.formatter.string(from: selectedAt))",
            "SELECTED_BY=\(selectedBy)",
        ]
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String) -> AutoSwitchSelection? {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        guard let name = fields["SELECTED_PROFILE"], !name.isEmpty,
              let at = fields["SELECTED_AT"].flatMap(formatter.date(from:)) else { return nil }
        return AutoSwitchSelection(
            profileName: name,
            email: fields["SELECTED_EMAIL"].flatMap { $0.isEmpty ? nil : $0 },
            accountUuid: fields["SELECTED_ACCOUNT_UUID"].flatMap { $0.isEmpty ? nil : $0 },
            selectedAt: at,
            selectedBy: fields["SELECTED_BY"] ?? "unknown"
        )
    }

    /// Writes the selection atomically. Returns false when it could not be written.
    @discardableResult
    func write(to url: URL = AutoSwitchSelection.defaultFileURL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileContents().write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            LoggingService.shared.logError("AutoSwitchSelection: could not write \(url.lastPathComponent)", error: error)
            return false
        }
    }

    static func read(from url: URL = AutoSwitchSelection.defaultFileURL) -> AutoSwitchSelection? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// The selection for a profile, with the account details its captured
    /// `oauthAccount` provides.
    static func forProfile(_ profile: Profile, by: String, now: Date = Date()) -> AutoSwitchSelection {
        var email: String?
        var uuid: String?
        if let json = profile.oauthAccountJSON,
           let data = json.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            email = obj["emailAddress"] as? String
            uuid = obj["accountUuid"] as? String
        }
        return AutoSwitchSelection(profileName: profile.name, email: email, accountUuid: uuid, selectedAt: now, selectedBy: by)
    }
}
