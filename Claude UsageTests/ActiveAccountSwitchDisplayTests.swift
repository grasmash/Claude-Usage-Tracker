import XCTest
@testable import Claude_Usage

/// The account NAME and its usage FIGURES change together on a switch.
///
/// 2026-10-12 ~2:50 PM ET (operator): the session auto-switched from
/// littlewing (100%) to matt@guitargate. The status line showed the new name
/// first and the limits followed later, so for a while it showed littlewing's
/// usage against matt@guitargate's name. "make sure the limits and the
/// account name switch at the same time". The name came from
/// `statusline-config.txt` (rewritten at the switch) and the figures from
/// `.statusline-usage-cache` (rewritten only by the next fetch).
///
/// These tests run the REAL installed status-line script (`bashScript`) under
/// a temporary HOME, so they check what the operator reads, not a paraphrase.
final class ActiveAccountSwitchDisplayTests: XCTestCase {

    private var home: URL!
    private var claudeDir: URL!
    private let statusline = StatuslineService.shared

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory.appendingPathComponent("statusline-\(UUID().uuidString)")
        claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        statusline.claudeDirectoryOverride = claudeDir
        try statusline.bashScript.write(to: claudeDir.appendingPathComponent("statusline-command.sh"), atomically: true, encoding: .utf8)
        let config = """
        SHOW_MODEL=0
        SHOW_DIRECTORY=0
        SHOW_BRANCH=0
        SHOW_CONTEXT=0
        SHOW_USAGE=1
        SHOW_PROGRESS_BAR=0
        SHOW_PACE_MARKER=0
        SHOW_RESET_TIME=0
        SHOW_USAGE_LABEL=1
        COLOR_MODE=monochrome
        SHOW_PROFILE=1
        PROFILE_NAME="littlewing@x.com"
        SHOW_WEEKLY=1
        SHOW_WEEKLY_BAR=0
        SHOW_WEEKLY_PACE_MARKER=0
        SHOW_WEEKLY_RESET_TIME=0
        SHOW_WEEKLY_LABEL=1
        SHOW_EXTRA_USAGE=0

        """
        try config.write(to: claudeDir.appendingPathComponent("statusline-config.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        statusline.claudeDirectoryOverride = nil
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    // MARK: - The 2026-10-12 2:50 PM switch

    func testAutoSwitchNeverShowsTheOldAccountsFiguresUnderTheNewName() throws {
        // littlewing at its limit: the app's last refresh wrote its figures.
        statusline.writeUsageCache(usage: usage(session: 100, weekly: 100), profileName: "littlewing@x.com")
        let before = try render()
        XCTAssertTrue(before.contains("littlewing@x.com") && before.contains("100%"), before)

        // Auto-switch to matt@guitargate, whose last reading is 40 minutes old:
        // not evidence of what the account is at now.
        let matt = profile("matt@guitargate.com", session: 12, weekly: 30, age: 40 * 60)
        statusline.activeAccountChanged(to: matt)

        let during = try render()
        XCTAssertTrue(during.contains("matt@guitargate.com"), during)
        XCTAssertFalse(during.contains("100%"), "littlewing's figures under matt@guitargate's name: \(during)")
        XCTAssertFalse(during.contains("12%"), "a 40-minute-old reading is not a proven reading: \(during)")
        XCTAssertTrue(during.contains("reading…"), "the figures say they are not measured yet: \(during)")
        // The menu bar decides the same way.
        XCTAssertEqual(ActiveAccountReading.forNewlyActive(matt), .notMeasured)

        // The first proven reading of matt@guitargate: name and figures together.
        statusline.writeUsageCache(usage: usage(session: 7, weekly: 31), profileName: "matt@guitargate.com")
        let after = try render()
        XCTAssertTrue(after.contains("matt@guitargate.com") && after.contains("7%") && after.contains("31%"), after)
        XCTAssertFalse(after.contains("reading…"), after)
    }

    func testSwitchToAnAccountWithAFreshReadingShowsThatReadingAtOnce() throws {
        statusline.writeUsageCache(usage: usage(session: 100, weekly: 100), profileName: "littlewing@x.com")
        let matt = profile("matt@guitargate.com", session: 12, weekly: 30, age: 60)
        statusline.activeAccountChanged(to: matt)

        let line = try render()
        XCTAssertTrue(line.contains("matt@guitargate.com") && line.contains("12%") && line.contains("30%"), line)
        XCTAssertFalse(line.contains("100%"), line)
        XCTAssertEqual(ActiveAccountReading.forNewlyActive(matt), .proven(matt.claudeUsage!))
    }

    /// The name is taken from the SAME file as the figures, so no write order
    /// between the config and the cache can pair one account's name with
    /// another's numbers.
    func testTheNameComesFromTheFileTheFiguresComeFrom() throws {
        statusline.writeUsageCache(usage: usage(session: 100, weekly: 100), profileName: "littlewing@x.com")
        // Something else rewrote the config's name first (the old switch path did).
        try statusline.updateProfileNameInConfig("matt@guitargate.com")
        let line = try render()
        XCTAssertTrue(line.contains("littlewing@x.com") && line.contains("100%"), line)
        XCTAssertFalse(line.contains("matt@guitargate.com"), "a name without its figures: \(line)")
    }

    func testAnAccountWithNoReadingAtAllShowsReading() throws {
        statusline.writeUsageCache(usage: usage(session: 100, weekly: 100), profileName: "littlewing@x.com")
        var fresh = Profile(name: "goose@x.com")
        fresh.claudeUsage = nil
        statusline.activeAccountChanged(to: fresh)
        let line = try render()
        XCTAssertTrue(line.contains("goose@x.com") && line.contains("reading…"), line)
        XCTAssertFalse(line.contains("100%"), line)
    }

    // MARK: - The next switch target is on the status line, at 100% too

    func testStatusLineNamesTheNextAccountWhileAtTheLimit() throws {
        statusline.writeUsageCache(usage: usage(session: 100, weekly: 100), profileName: "littlewing@x.com")
        var status = AutoSwitchStatus(stuck: false, nextFree: nil, needsLogin: [])
        status.next = .ready(name: "matt", presumed: false)
        try status.stateFileContents { _ in "" }
            .write(to: claudeDir.appendingPathComponent(".autoswitch-state"), atomically: true, encoding: .utf8)
        let line = try render()
        XCTAssertTrue(line.contains("next: matt (ready)"), line)

        status.next = .limited(name: "goose", at: Date().addingTimeInterval(3600))
        status.stuck = true
        try status.stateFileContents { _ in "5:10 PM" }
            .write(to: claudeDir.appendingPathComponent(".autoswitch-state"), atomically: true, encoding: .utf8)
        XCTAssertTrue(try render().contains("→ goose at 5:10 PM"))
    }

    // MARK: - The bash script is installed even when the fetch script cannot be

    /// 2026-10-12: the operator's statusline-command.sh was dated Oct 3. The
    /// update threw `sessionKeyNotFound` (the active profile has no claude.ai
    /// session key) before it reached the bash script, so no fix to the status
    /// line ever arrived.
    func testTheBashScriptIsUpdatedEvenWhenTheFetchScriptCannotBeInjected() throws {
        let bash = claudeDir.appendingPathComponent("statusline-command.sh")
        try "#!/bin/bash\necho old\n".write(to: bash, atomically: true, encoding: .utf8)
        try "// old fetch script\n".write(to: claudeDir.appendingPathComponent("fetch-claude-usage.swift"), atomically: true, encoding: .utf8)
        XCTAssertTrue(statusline.isInstalled)

        var keyless = Profile(name: "matt@guitargate.com")
        keyless.claudeSessionKey = nil
        XCTAssertThrowsError(try statusline.updateScriptsIfInstalled(activeProfile: keyless), "no session key: the fetch script cannot be injected")

        XCTAssertEqual(try String(contentsOf: bash, encoding: .utf8), statusline.bashScript, "the bash script is current all the same")
        XCTAssertEqual(try String(contentsOf: claudeDir.appendingPathComponent("fetch-claude-usage.swift"), encoding: .utf8),
                       "// old fetch script\n", "the fetch script is left as it was")
    }

    // MARK: - Hardening: both files are data, never code

    /// statusline-config.txt is `source`d: a profile name must not run.
    func testAProfileNameIsNeverExecutedByTheStatusLine() throws {
        let evil = #"x"; touch "$HOME/pwned"; echo "$(touch $HOME/pwned2)`touch $HOME/pwned3`"#
        statusline.writeUsageCache(usage: usage(session: 5, weekly: 6), profileName: evil)
        let line = try render()
        for file in ["pwned", "pwned2", "pwned3"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(file).path), "\(file): the name ran as shell")
        }
        XCTAssertTrue(line.contains("5%"), line)
        // The config still round-trips the literal name for the script's fallback.
        let sourced = try shell(#"source "$HOME/.claude/statusline-config.txt"; printf '%s' "$PROFILE_NAME""#)
        XCTAssertEqual(sourced, evil)
        // ... and the name is replaced, not appended, on the next switch.
        try statusline.updateProfileNameInConfig("plain@x.com")
        XCTAssertEqual(try shell(#"source "$HOME/.claude/statusline-config.txt"; printf '%s' "$PROFILE_NAME""#), "plain@x.com")
        XCTAssertEqual(try String(contentsOf: claudeDir.appendingPathComponent("statusline-config.txt"), encoding: .utf8)
            .components(separatedBy: "PROFILE_NAME=").count, 2)
    }

    /// Bash arithmetic evaluates `a[$(cmd)]`: a TIMESTAMP that is not a number
    /// must never reach it.
    func testANonNumericCacheTimestampIsNeverEvaluated() throws {
        let cache = "UTILIZATION=55\nRESETS_AT=2026-10-12T19:19:59Z\nTIMESTAMP=x[$(touch $HOME/pwned)]\nPROFILE_NAME=littlewing@x.com\nWEEKLY_UTILIZATION=9\nWEEKLY_RESETS_AT=2026-10-17T18:59:59Z\nCOST_USED=1.00\nCOST_LIMIT=2.00\nCOST_CURRENCY=USD"
        try cache.write(to: claudeDir.appendingPathComponent(".statusline-usage-cache"), atomically: true, encoding: .utf8)
        var config = try String(contentsOf: claudeDir.appendingPathComponent("statusline-config.txt"), encoding: .utf8)
        config = config.replacingOccurrences(of: "SHOW_EXTRA_USAGE=0", with: "SHOW_EXTRA_USAGE=1")
        try config.write(to: claudeDir.appendingPathComponent("statusline-config.txt"), atomically: true, encoding: .utf8)
        _ = try render()
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pwned").path), "the timestamp ran as shell")

        // The same for the figures, with a valid timestamp and the bars on.
        let figures = "UTILIZATION=x[$(touch $HOME/pwned2)]\nRESETS_AT=2026-10-12T19:19:59Z\nTIMESTAMP=\(Int(Date().timeIntervalSince1970))\nPROFILE_NAME=littlewing@x.com\nWEEKLY_UTILIZATION=x[$(touch $HOME/pwned3)]\nWEEKLY_RESETS_AT=2026-10-17T18:59:59Z"
        try figures.write(to: claudeDir.appendingPathComponent(".statusline-usage-cache"), atomically: true, encoding: .utf8)
        config = config.replacingOccurrences(of: "SHOW_PROGRESS_BAR=0", with: "SHOW_PROGRESS_BAR=1")
            .replacingOccurrences(of: "SHOW_WEEKLY_BAR=0", with: "SHOW_WEEKLY_BAR=1")
        try config.write(to: claudeDir.appendingPathComponent("statusline-config.txt"), atomically: true, encoding: .utf8)
        _ = try render()
        for file in ["pwned2", "pwned3"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(file).path), "\(file): a figure ran as shell")
        }
    }

    private func shell(_ script: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.currentDirectoryURL = home
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Helpers

    /// Runs the installed script the way Claude Code does, with ANSI stripped.
    private func render() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [claudeDir.appendingPathComponent("statusline-command.sh").path]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.currentDirectoryURL = home
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(#"{"model":{"display_name":"Opus"},"workspace":{"current_dir":"/tmp"}}"#.data(using: .utf8)!)
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private func usage(session: Double, weekly: Double, age: TimeInterval = 0) -> ClaudeUsage {
        let now = Date()
        return ClaudeUsage(
            sessionTokensUsed: 0, sessionLimit: 100000, sessionPercentage: session,
            sessionResetTime: now.addingTimeInterval(3600),
            weeklyTokensUsed: 0, weeklyLimit: 1000000, weeklyPercentage: weekly,
            weeklyResetTime: now.addingTimeInterval(86400),
            opusWeeklyTokensUsed: 0, opusWeeklyPercentage: 0,
            sonnetWeeklyTokensUsed: 0, sonnetWeeklyPercentage: 0, sonnetWeeklyResetTime: nil,
            designWeeklyTokensUsed: 0, designWeeklyPercentage: 0, designWeeklyResetTime: nil,
            fableWeeklyTokensUsed: 0, fableWeeklyPercentage: 0, fableWeeklyResetTime: nil,
            costUsed: nil, costLimit: nil, costCurrency: nil,
            lastUpdated: now.addingTimeInterval(-age), userTimezone: .current
        )
    }

    private func profile(_ name: String, session: Double, weekly: Double, age: TimeInterval) -> Profile {
        Profile(name: name, claudeUsage: usage(session: session, weekly: weekly, age: age))
    }
}
