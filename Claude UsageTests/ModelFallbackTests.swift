import XCTest
@testable import Claude_Usage

/// Last resort when Fable is in use and no account has Fable headroom
/// (operator, 2026-10-11: "App switches default to Opus"): the tracker sets
/// Claude Code's default `model` to Opus, touching only that key, and restores
/// the previous value once Fable is available again, unless the user changed
/// the setting in the meantime.
final class ModelFallbackTests: XCTestCase {

    private var dir: URL!
    private var settings: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var fallback: ModelFallback!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        settings = dir.appendingPathComponent("settings.json")
        suiteName = "ModelFallbackTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        fallback = ModelFallback(settingsURL: settings, defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ text: String, mode: Int = 0o644) throws {
        try text.write(to: settings, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: settings.path)
    }

    private func json() throws -> [String: Any] {
        let data = try Data(contentsOf: settings)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func mode() throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int)
    }

    private let original = """
    {
      "model": "fable",
      "env": {"FOO": "bar", "N": "1"},
      "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/x/y.sh"}]}]},
      "statusLine": {"type": "command", "command": "~/.claude/statusline.sh", "padding": 0},
      "alwaysThinkingEnabled": true
    }
    """

    // MARK: - The edit

    func testSetsTheDefaultModelToOpusAndKeepsEveryOtherKey() throws {
        try write(original, mode: 0o600)

        XCTAssertEqual(fallback.applyOpus(), .applied(previous: "fable"))

        let after = try json()
        XCTAssertEqual(after["model"] as? String, ModelFallback.opusModel)
        XCTAssertEqual(after["env"] as? [String: String], ["FOO": "bar", "N": "1"])
        XCTAssertEqual(after["alwaysThinkingEnabled"] as? Bool, true)
        XCTAssertEqual((after["statusLine"] as? [String: Any])?["padding"] as? Int, 0)
        let hooks = try XCTUnwrap(after["hooks"] as? [String: Any])
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertEqual(Set(after.keys), ["model", "env", "hooks", "statusLine", "alwaysThinkingEnabled"])
        XCTAssertEqual(try mode(), 0o600, "the file mode is kept")
        XCTAssertTrue(fallback.isActive)
    }

    func testApplyingTwiceDoesNotOverwriteTheRecordedPreviousValue() throws {
        try write(original)
        XCTAssertEqual(fallback.applyOpus(), .applied(previous: "fable"))
        XCTAssertEqual(fallback.applyOpus(), .alreadyApplied)
        XCTAssertEqual(fallback.restore(), .restored)
        XCTAssertEqual(try json()["model"] as? String, "fable")
    }

    // MARK: - Restore

    func testRestoresThePreviousValueWhenTheSettingIsStillOurs() throws {
        try write(original, mode: 0o640)
        _ = fallback.applyOpus()

        XCTAssertEqual(fallback.restore(), .restored)

        let after = try json()
        XCTAssertEqual(after["model"] as? String, "fable")
        XCTAssertEqual(after["env"] as? [String: String], ["FOO": "bar", "N": "1"])
        XCTAssertEqual(try mode(), 0o640)
        XCTAssertFalse(fallback.isActive)
    }

    func testRestoringRemovesTheKeyWhenThereWasNoneBefore() throws {
        try write(#"{"env": {"A": "b"}}"#)
        XCTAssertEqual(fallback.applyOpus(), .applied(previous: nil))
        XCTAssertEqual(try json()["model"] as? String, ModelFallback.opusModel)

        XCTAssertEqual(fallback.restore(), .restored)

        let after = try json()
        XCTAssertNil(after["model"], "Claude Code is back on its own default")
        XCTAssertEqual(after["env"] as? [String: String], ["A": "b"])
    }

    func testDoesNotRestoreAfterTheUserChangedTheSetting() throws {
        try write(original)
        _ = fallback.applyOpus()
        var edited = try json()
        edited["model"] = "sonnet"
        try JSONSerialization.data(withJSONObject: edited).write(to: settings)

        XCTAssertEqual(fallback.restore(), .userChanged)

        XCTAssertEqual(try json()["model"] as? String, "sonnet", "the user's choice is left alone")
        XCTAssertFalse(fallback.isActive, "and the tracker forgets its own edit")
    }

    func testRestoreIsANoOpWhenNothingWasApplied() throws {
        try write(original)
        let before = try Data(contentsOf: settings)
        XCTAssertEqual(fallback.restore(), .nothingToRestore)
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    // MARK: - Fail safe

    func testAMalformedSettingsFileIsNeverEdited() throws {
        try write(#"{"model": "fable", "env": {"#)
        let before = try Data(contentsOf: settings)

        guard case .failed = fallback.applyOpus() else { return XCTFail("expected .failed") }

        XCTAssertEqual(try Data(contentsOf: settings), before)
        XCTAssertFalse(fallback.isActive)
    }

    func testANonObjectSettingsFileIsNeverEdited() throws {
        try write(#"["model", "fable"]"#)
        let before = try Data(contentsOf: settings)
        guard case .failed = fallback.applyOpus() else { return XCTFail("expected .failed") }
        XCTAssertEqual(try Data(contentsOf: settings), before)
    }

    func testAMissingSettingsFileIsNotCreated() {
        guard case .failed = fallback.applyOpus() else { return XCTFail("expected .failed") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.path))
        XCTAssertFalse(fallback.isActive)
    }

    func testRestoreLeavesAMalformedFileAloneAndKeepsTheRecord() throws {
        try write(original)
        _ = fallback.applyOpus()
        try write(#"{"model": "#)
        guard case .failed = fallback.restore() else { return XCTFail("expected .failed") }
        XCTAssertTrue(fallback.isActive, "retried once the file parses again")
    }

    func testASymlinkedSettingsFileStaysASymlink() throws {
        let real = dir.appendingPathComponent("real-settings.json")
        try original.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: real)

        XCTAssertEqual(fallback.applyOpus(), .applied(previous: "fable"))

        let attrs = try FileManager.default.attributesOfItem(atPath: settings.path)
        XCTAssertEqual(attrs[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(try json()["model"] as? String, ModelFallback.opusModel)
    }
}
