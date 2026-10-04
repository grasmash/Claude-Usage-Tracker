import XCTest
@testable import Claude_Usage

/// The profile backup and the undecodable-data quarantine must not undo a
/// deliberate removal of profiles, and must never hold credentials in
/// cleartext (#267 / GHSA-mfxh-xpwm-23c7).
final class ProfileStoreBackupTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var backupURL: URL!

    override func setUp() {
        super.setUp()
        suiteName = "ProfileStoreBackupTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        backupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("profiles-backup.json")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: backupURL.deletingLastPathComponent())
        super.tearDown()
    }

    // MARK: - Backup must not resurrect removed profiles

    func testSavingProfilesWritesBackup() {
        let store = ProfileStore(defaults: defaults, backupURL: backupURL)
        store.saveProfiles([Profile(name: "a")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testRemovingEveryProfileRemovesTheBackup() {
        let store = ProfileStore(defaults: defaults, backupURL: backupURL)
        store.saveProfiles([Profile(name: "a"), Profile(name: "b")])

        store.saveProfiles([])

        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path),
                       "a backup left behind keeps account details on disk after removal")
    }

    func testRemovedProfilesAreNotRestoredOnNextLoad() {
        let store = ProfileStore(defaults: defaults, backupURL: backupURL)
        store.saveProfiles([Profile(name: "a"), Profile(name: "b")])

        store.saveProfiles([])

        XCTAssertTrue(ProfileStore(defaults: defaults, backupURL: backupURL).loadProfiles().isEmpty)
    }

    func testProfilesWipedByAnotherBuildAreStillRestored() {
        let profile = Profile(name: "a")
        ProfileStore(defaults: defaults, backupURL: backupURL).saveProfiles([profile])

        // Another build overwrites the shared defaults without going through us.
        defaults.removeObject(forKey: "profiles_v3")

        let loaded = ProfileStore(defaults: defaults, backupURL: backupURL).loadProfiles()
        XCTAssertEqual(loaded.map(\.id), [profile.id])
    }

    // MARK: - Quarantined data must not keep credentials

    func testQuarantineCopyDropsCredentialFields() throws {
        let raw = Data(#"""
        [{"name":"a","organizationId":"org-1","claudeSessionKey":"sk-ant-secret",
          "apiSessionKey":"api-secret","cliCredentialsJSON":"cli-secret","codexCredentialsJSON":"codex-secret"}]
        """#.utf8)

        let scrubbed = try XCTUnwrap(ProfileStore.scrubbedForQuarantine(raw))
        let text = try XCTUnwrap(String(data: scrubbed, encoding: .utf8))

        XCTAssertFalse(text.contains("secret"))
        XCTAssertTrue(text.contains("org-1"), "non-secret fields are kept for recovery")
    }

    func testUnparseableDataIsNotQuarantined() {
        // Nothing can be scrubbed from bytes we cannot read, so keep nothing.
        XCTAssertNil(ProfileStore.scrubbedForQuarantine(Data("sk-ant-secret not json".utf8)))
    }

    func testUndecodableStoredProfilesAreQuarantinedWithoutCredentials() throws {
        // `id` is missing, so the profile list cannot be decoded.
        let raw = Data(#"[{"name":"a","claudeSessionKey":"sk-ant-secret"}]"#.utf8)
        defaults.set(raw, forKey: "profiles_v3")

        _ = ProfileStore(defaults: defaults, backupURL: backupURL).loadProfiles()

        let kept = try XCTUnwrap(defaults.data(forKey: "profiles_v3.undecodable"))
        XCTAssertFalse(String(decoding: kept, as: UTF8.self).contains("sk-ant-secret"))
    }
}
