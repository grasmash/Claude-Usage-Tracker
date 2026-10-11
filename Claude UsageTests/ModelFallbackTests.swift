import XCTest
import UserNotifications
@testable import Claude_Usage

/// Last resort when Fable is in use and no account has Fable headroom
/// (operator, 2026-10-11: "App switches default to Opus"): the tracker sets
/// Claude Code's default `model` to Opus with a minimal text edit, and restores
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
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func write(_ text: String, mode: Int = 0o644) throws {
        try text.write(to: settings, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: settings.path)
    }

    private func text() throws -> String { try String(contentsOf: settings, encoding: .utf8) }

    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    private func mode() throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int)
    }

    private func failure(_ result: ModelFallback.ApplyResult) -> ModelFallback.Failure? {
        if case .failed(let f) = result { return f }
        return nil
    }

    private let original = """
    {
      "model": "fable",
      "env": {"FOO": "bar", "URL": "https://example.com//x"},
      "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/x/y.sh"}]}]},
      "alwaysThinkingEnabled": true,
      "padding": 1.50
    }

    """

    // MARK: - The edit is minimal

    func testOnlyTheModelValueChangesAndTheModeIsKept() throws {
        try write(original, mode: 0o600)

        XCTAssertEqual(fallback.applyOpus(), .applied(previous: "fable"))

        XCTAssertEqual(try text(), original.replacingOccurrences(of: #""model": "fable""#, with: #""model": "opus""#),
                       "every other byte is kept, including key order, spacing and 1.50")
        XCTAssertEqual(try mode(), 0o600)
        XCTAssertTrue(fallback.isActive)
    }

    func testAMissingModelKeyIsInsertedAfterTheBraceWithTheFilesIndent() throws {
        let before = "{\n    \"env\": {\"A\": \"b\"},\n    \"x\": 1\n}\n"
        try write(before)

        XCTAssertEqual(fallback.applyOpus(), .applied(previous: nil))
        XCTAssertEqual(try text(), "{\n    \"model\": \"opus\",\n    \"env\": {\"A\": \"b\"},\n    \"x\": 1\n}\n")

        XCTAssertEqual(fallback.restore(), .restored)
        XCTAssertEqual(try text(), before, "restore puts back the exact bytes")
    }

    func testCompactAndEmptyObjects() throws {
        try write(#"{"a":1}"#)
        XCTAssertEqual(fallback.applyOpus(), .applied(previous: nil))
        XCTAssertEqual(try text(), #"{"model": "opus","a":1}"#)
        XCTAssertEqual(fallback.restore(), .restored)
        XCTAssertEqual(try text(), #"{"a":1}"#)

        try write("{}")
        XCTAssertEqual(fallback.applyOpus(), .applied(previous: nil))
        XCTAssertEqual(try json()["model"] as? String, ModelFallback.opusModel)
        XCTAssertEqual(fallback.restore(), .restored)
        XCTAssertEqual(try text(), "{}")
    }

    func testCRLFAndSpacedObjectsRoundTripByteExact() throws {
        for before in ["{\r\n  \"a\": 1,\r\n  \"b\": [1, 2]\r\n}\r\n", #"{ "a": 1 }"#, "{ }", "{\n\t\"a\": true\n}"] {
            try write(before)
            XCTAssertEqual(fallback.applyOpus(), .applied(previous: nil), before)
            XCTAssertEqual(try json()["model"] as? String, ModelFallback.opusModel, before)
            XCTAssertEqual(fallback.restore(), .restored, before)
            XCTAssertEqual(try text(), before, "restore puts back the exact bytes: \(before.debugDescription)")
        }
    }

    func testCRLFInsertUsesTheFilesLineEnding() throws {
        try write("{\r\n  \"a\": 1\r\n}")
        _ = fallback.applyOpus()
        XCTAssertEqual(try text(), "{\r\n  \"model\": \"opus\",\r\n  \"a\": 1\r\n}")
    }

    func testRemovingTheLastMemberLeavesTheRestIntact() throws {
        let before = "{\n  \"a\": 1,\n  \"model\": \"fable\"\n}"
        try write(before)
        _ = fallback.applyOpus()
        XCTAssertEqual(try text(), "{\n  \"a\": 1,\n  \"model\": \"opus\"\n}")
        XCTAssertEqual(fallback.restore(), .restored)
        XCTAssertEqual(try text(), before)
    }

    func testApplyingTwiceKeepsTheFirstRecord() throws {
        try write(original)
        XCTAssertEqual(fallback.applyOpus(), .applied(previous: "fable"))
        XCTAssertEqual(fallback.applyOpus(), .alreadyApplied)
        XCTAssertEqual(fallback.restore(), .restored)
        XCTAssertEqual(try text(), original)
    }

    func testWhileActiveAUserChangeIsNotOverwrittenByAnotherApply() throws {
        try write(original)
        _ = fallback.applyOpus()
        try write(original.replacingOccurrences(of: #""model": "fable""#, with: #""model": "sonnet""#))
        let before = try text()
        XCTAssertEqual(fallback.applyOpus(), .alreadyApplied)
        XCTAssertEqual(try text(), before)
    }

    // MARK: - Restore

    func testRestoresThePreviousValueWhenTheSettingIsStillOurs() throws {
        try write(original, mode: 0o640)
        _ = fallback.applyOpus()

        XCTAssertEqual(fallback.restore(), .restored)

        XCTAssertEqual(try text(), original)
        XCTAssertEqual(try mode(), 0o640)
        XCTAssertFalse(fallback.isActive)
    }

    func testDoesNotRestoreAfterTheUserChangedTheSetting() throws {
        try write(original)
        _ = fallback.applyOpus()
        let edited = original.replacingOccurrences(of: #""model": "fable""#, with: #""model": "sonnet""#)
        try write(edited)

        XCTAssertEqual(fallback.restore(), .userChanged)

        XCTAssertEqual(try text(), edited, "the user's choice is left alone")
        XCTAssertFalse(fallback.isActive, "and the tracker forgets its own edit")
    }

    func testRestoreIsANoOpWhenNothingWasApplied() throws {
        try write(original)
        XCTAssertEqual(fallback.restore(), .nothingToRestore)
        XCTAssertEqual(try text(), original)
    }

    // MARK: - Fail safe

    func testAMalformedSettingsFileIsNeverEdited() throws {
        try write(#"{"model": "fable", "env": {"#)
        let before = try text()
        XCTAssertNotNil(failure(fallback.applyOpus()))
        XCTAssertEqual(try text(), before)
        XCTAssertFalse(fallback.isActive)
    }

    func testANonObjectSettingsFileIsNeverEdited() throws {
        try write(#"["model", "fable"]"#)
        XCTAssertNotNil(failure(fallback.applyOpus()))
        XCTAssertEqual(try text(), #"["model", "fable"]"#)
    }

    func testAFileWithCommentsIsNeverEditedAndSaysSo() throws {
        let jsonc = "{\n  // pick a model\n  \"model\": \"fable\"\n}"
        try write(jsonc)
        XCTAssertEqual(failure(fallback.applyOpus()), .hasComments)
        XCTAssertEqual(try text(), jsonc)
        XCTAssertTrue(ModelFallback.Failure.hasComments.message.contains("has comments; edit the model key by hand"))
    }

    func testSlashesInsideStringsAreNotComments() throws {
        try write(#"{"url": "https://x/*y*/", "model": "fable"}"#)
        XCTAssertEqual(fallback.applyOpus(), .applied(previous: "fable"))
        XCTAssertEqual(try text(), #"{"url": "https://x/*y*/", "model": "opus"}"#)
    }

    func testDuplicateTopLevelKeysAreRefused() throws {
        try write(#"{"model": "fable", "a": 1, "model": "sonnet"}"#)
        XCTAssertEqual(failure(fallback.applyOpus()), .duplicateKeys)
        XCTAssertFalse(fallback.isActive)
    }

    func testANonStringModelIsRefused() throws {
        try write(#"{"model": {"name": "fable"}}"#)
        XCTAssertEqual(failure(fallback.applyOpus()), .modelNotAString)
    }

    func testAMissingSettingsFileIsNotCreated() {
        XCTAssertEqual(failure(fallback.applyOpus()), .unreadable)
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

    func testAFailedWriteLeavesNoRecord() throws {
        try write(original)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        guard case .failed(.writeFailed) = fallback.applyOpus() else { return XCTFail("expected .writeFailed") }

        XCTAssertFalse(fallback.isActive, "the record written before the rename is cleared")
        XCTAssertEqual(try text(), original)
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

    func testStaleTemporaryFilesAreSwept() throws {
        try write(original)
        let stale = dir.appendingPathComponent(".settings.json.claude-usage-OLD")
        FileManager.default.createFile(atPath: stale.path, contents: Data("x".utf8))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)

        _ = fallback.applyOpus()

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("claude-usage-") }
        XCTAssertEqual(leftovers, [], "the edit leaves no temporary file behind")
    }

    // MARK: - Notifications honour the profile's settings

    func testModelFallbackNotificationsHonourEnabled() {
        let on = NotificationSettings(enabled: true)
        let off = NotificationSettings(enabled: false)

        XCTAssertNil(NotificationManager.modelFallbackContent(applied: true, movedTo: nil, settings: off))
        XCTAssertNil(NotificationManager.modelFallbackContent(applied: false, movedTo: nil, settings: off))
        XCTAssertNil(NotificationManager.modelFallbackFailedContent(failure: .hasComments, settings: off))
        XCTAssertNotNil(NotificationManager.modelFallbackContent(applied: true, movedTo: "B", settings: on))
        XCTAssertNotNil(NotificationManager.modelFallbackContent(applied: false, movedTo: nil, settings: on))
        XCTAssertTrue(NotificationManager.modelFallbackFailedContent(failure: .hasComments, settings: on)?.body
            .contains("has comments; edit the model key by hand") ?? false)
    }
}
