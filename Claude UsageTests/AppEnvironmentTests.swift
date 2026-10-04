import XCTest
@testable import Claude_Usage

/// Guards that keep a test run from acting on the user's real data.
final class AppEnvironmentTests: XCTestCase {

    func testDetectsTestHost() {
        XCTAssertTrue(AppEnvironment.isRunningTests)
    }

    func testStoresUseIsolatedDefaults() {
        XCTAssertFalse(AppEnvironment.userDefaults === UserDefaults.standard)

        let key = "appEnvironmentTests.probe.\(UUID().uuidString)"
        AppEnvironment.userDefaults.set(true, forKey: key)
        defer { AppEnvironment.userDefaults.removeObject(forKey: key) }
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "write leaked into real defaults")
    }

    func testClaudeCodeKeychainWritesAreBlocked() {
        XCTAssertThrowsError(try ClaudeCodeSyncService.shared.writeSystemCredentials("{}"))
        XCTAssertThrowsError(try ClaudeCodeSyncService.shared.writeKeychainCredentials(
            serviceName: "Claude Code-credentials-test-\(UUID().uuidString)", jsonData: "{}"))
    }
}
