import Foundation

/// Facts about the process the app is running in.
///
/// Unit tests run inside the app itself (the app is the XCTest host). Debug and
/// Release share one bundle identifier, so without these guards a test run is a
/// second, full copy of the tracker working on the user's real profiles,
/// settings and Claude Code logins — including rotating OAuth refresh tokens
/// out from under the running tracker and Claude Code, which forces `/login`.
enum AppEnvironment {

    /// True when this process is hosting XCTest.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// Suite that stands in for `UserDefaults.standard` under tests.
    static let testDefaultsSuiteName = "HamedElfayome.Claude-Usage.tests"

    /// The defaults the app's stores should use: the real ones normally, and an
    /// isolated suite (emptied at startup) under tests, so tests never read or
    /// overwrite the user's profiles and settings.
    static let userDefaults: UserDefaults = {
        guard isRunningTests, let suite = UserDefaults(suiteName: testDefaultsSuiteName) else {
            return .standard
        }
        suite.removePersistentDomain(forName: testDefaultsSuiteName)
        return suite
    }()
}
