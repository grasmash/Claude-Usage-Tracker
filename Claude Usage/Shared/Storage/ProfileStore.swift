//
//  ProfileStore.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation

/// Manages storage and retrieval of profiles and profile-related data
class ProfileStore {
    static let shared = ProfileStore()

    private let defaults: UserDefaults
    private let keychainService = KeychainService.shared

    private enum Keys {
        static let profiles = "profiles_v3"
        static let undecodableProfiles = "profiles_v3.undecodable"
        static let activeProfileId = "activeProfileId"
        static let displayMode = "profileDisplayMode"
        static let multiProfileConfig = "multiProfileDisplayConfig"
    }

    /// One-time flag so the expected no-keychain-store situation on ad-hoc dev
    /// builds is logged once, not on every save cycle.
    private static var loggedNoKeychainStoreOnce = false

    /// `backupURL` overrides where the profile backup lives; nil uses the
    /// default location (and no backup at all under tests).
    init(defaults: UserDefaults = AppEnvironment.userDefaults, backupURL: URL? = nil) {
        // Standard UserDefaults (app container); an isolated suite under tests
        self.defaults = defaults
        self.backupURLOverride = backupURL
        LoggingService.shared.log("ProfileStore: Using standard app container storage")
    }

    // MARK: - Profile Management

    func saveProfiles(_ profiles: [Profile]) {
        // Persist credential fields to the Keychain FIRST; the plist encoding below
        // excludes them (#267 / GHSA-mfxh-xpwm-23c7 — the plist is cleartext on disk).
        var allSecretsInKeychain = true
        for profile in profiles {
            allSecretsInKeychain = persistSecrets(of: profile) && allSecretsInKeychain
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted // For debugging
            if !allSecretsInKeychain {
                // Zero-data-loss fallback: if any Keychain write failed, keep the
                // credentials in the plist for this save so nothing is lost; the
                // migration retries on the next save.
                encoder.userInfo[Profile.includeSecretsKey] = true
                if keychainService.profileSecretStorageKnownUnavailable {
                    // Expected on ad-hoc dev builds — not an error, and saves run
                    // on every refresh, so say it once instead of every cycle.
                    if !Self.loggedNoKeychainStoreOnce {
                        Self.loggedNoKeychainStoreOnce = true
                        LoggingService.shared.log("ProfileStore: no reachable keychain store in this build — credentials remain in plist (expected for ad-hoc dev builds)")
                    }
                } else {
                    LoggingService.shared.logError("ProfileStore: Keychain write failed — keeping credentials in plist for this save (will retry)")
                }
            }
            let data = try encoder.encode(profiles)
            defaults.set(data, forKey: Keys.profiles)

            // Verify save
            if let savedData = defaults.data(forKey: Keys.profiles) {
                LoggingService.shared.log("ProfileStore: Saved \(profiles.count) profiles (\(savedData.count) bytes)")
            } else {
                LoggingService.shared.logError("ProfileStore: Failed to verify save!")
            }

            writeBackup(of: profiles)
        } catch {
            LoggingService.shared.logStorageError("saveProfiles", error: error)
        }
    }

    func loadProfiles() -> [Profile] {
        var profiles: [Profile] = []
        if let data = defaults.data(forKey: Keys.profiles) {
            do {
                profiles = try JSONDecoder().decode([Profile].self, from: data)
            } catch {
                // Keep a copy: the save that follows an empty load would
                // otherwise destroy the only one. Credentials are stripped
                // first — nothing ever scrubs this key again, so cleartext
                // secrets kept here would sit in the plist for good (#267).
                if let scrubbed = Self.scrubbedForQuarantine(data) {
                    defaults.set(scrubbed, forKey: Keys.undecodableProfiles)
                } else {
                    defaults.removeObject(forKey: Keys.undecodableProfiles)
                }
                LoggingService.shared.logStorageError("loadProfiles", error: error)
                LoggingService.shared.logError("ProfileStore: Failed to decode profiles; credential-free copy kept under \(Keys.undecodableProfiles)")
            }
        } else {
            LoggingService.shared.log("ProfileStore: No profiles found in storage")
        }

        let restored = restoreFromBackupIfWiped(&profiles)
        guard !profiles.isEmpty else { return [] }

        do {

            // Hydrate credential fields from the Keychain. A value still present in
            // the plist wins (it is either pre-migration, or was written by an older
            // app version more recently than our Keychain copy) and gets migrated on
            // the save below.
            var plistHadSecrets = false
            for i in profiles.indices {
                let id = profiles[i].id
                if profiles[i].claudeSessionKey != nil {
                    plistHadSecrets = true
                } else {
                    profiles[i].claudeSessionKey = keychainService.loadProfileSecret(profileId: id, field: .claudeSessionKey)
                }
                if profiles[i].apiSessionKey != nil {
                    plistHadSecrets = true
                } else {
                    profiles[i].apiSessionKey = keychainService.loadProfileSecret(profileId: id, field: .apiSessionKey)
                }
                if profiles[i].cliCredentialsJSON != nil {
                    plistHadSecrets = true
                } else {
                    profiles[i].cliCredentialsJSON = keychainService.loadProfileSecret(profileId: id, field: .cliCredentialsJSON)
                }
                if profiles[i].codexCredentialsJSON != nil {
                    plistHadSecrets = true
                } else {
                    profiles[i].codexCredentialsJSON = keychainService.loadProfileSecret(profileId: id, field: .codexCredentialsJSON)
                }
            }

            if plistHadSecrets {
                LoggingService.shared.log("ProfileStore: migrating plaintext credentials from plist to Keychain (#267)")
                saveProfiles(profiles)  // writes Keychain + scrubbed plist (or keeps plist on failure)
            } else if restored {
                saveProfiles(profiles)
            }

            LoggingService.shared.log("ProfileStore: Loaded \(profiles.count) profiles from storage")
            return profiles
        }
    }

    // MARK: - Backup

    /// Last known-good profile list, outside UserDefaults. Another build sharing
    /// this bundle id (e.g. the upstream release) reads the same defaults; if it
    /// can't decode them it starts over with a fresh profile and saves, wiping
    /// every profile. The backup lets us notice and undo that on next launch.
    /// Secrets are not in it — they stay in the Keychain under the profile id.
    private var backupURL: URL? {
        if let backupURLOverride { return backupURLOverride }
        guard !AppEnvironment.isRunningTests,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return support.appendingPathComponent("Claude Usage/profiles-backup.json")
    }

    private let backupURLOverride: URL?
    private var lastBackupData: Data?

    /// Credential fields a profile's stored JSON may carry (legacy plists, or
    /// the Keychain-unavailable fallback encoding).
    private static let secretFieldNames = ["claudeSessionKey", "apiSessionKey", "cliCredentialsJSON", "codexCredentialsJSON"]

    /// Stored profile data with every credential field removed, or nil when the
    /// bytes cannot be parsed well enough to be sure nothing secret remains.
    static func scrubbedForQuarantine(_ data: Data) -> Data? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let scrubbed = entries.map { entry in
            entry.filter { !secretFieldNames.contains($0.key) }
        }
        return try? JSONSerialization.data(withJSONObject: scrubbed)
    }

    private func writeBackup(of profiles: [Profile]) {
        // An empty list saved by this build means the profiles were removed on
        // purpose. Drop the backup too: keeping it would restore them on the
        // next load and leave their account details on disk. (A wipe by
        // another build never comes through here, so it is still undone.)
        if profiles.isEmpty {
            if let url = backupURL { try? FileManager.default.removeItem(at: url) }
            lastBackupData = nil
            return
        }
        guard let url = backupURL,
              let data = try? JSONEncoder().encode(profiles),  // default encoding excludes secrets
              data != lastBackupData else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastBackupData = data
        } catch {
            LoggingService.shared.logStorageError("writeProfilesBackup", error: error)
        }
    }

    /// Restores backed-up profiles when the stored list looks wiped: empty,
    /// undecodable, or sharing no profile with the backup. Our own saves keep
    /// the backup in step with the list, so no overlap means something else
    /// replaced it. Profiles found only in the current list are kept.
    private func restoreFromBackupIfWiped(_ profiles: inout [Profile]) -> Bool {
        guard let url = backupURL,
              let data = try? Data(contentsOf: url),
              let backup = try? JSONDecoder().decode([Profile].self, from: data),
              !backup.isEmpty else { return false }

        let currentIds = Set(profiles.map(\.id))
        guard !backup.contains(where: { currentIds.contains($0.id) }) else { return false }

        LoggingService.shared.logError("ProfileStore: stored profiles replaced by another build — restoring \(backup.count) from backup")
        profiles = backup + profiles
        return true
    }

    /// Writes a profile's credential fields to the Keychain (nil deletes the item so a
    /// signed-out credential can't be resurrected). Returns false if any write failed.
    /// Every non-nil write is READ BACK and byte-compared before we trust it — the
    /// plist copy is only ever scrubbed for values proven to be retrievable.
    private func persistSecrets(of profile: Profile) -> Bool {
        var ok = true
        ok = persistSecret(profile.claudeSessionKey, profile.id, .claudeSessionKey) && ok
        ok = persistSecret(profile.apiSessionKey, profile.id, .apiSessionKey) && ok
        ok = persistSecret(profile.cliCredentialsJSON, profile.id, .cliCredentialsJSON) && ok
        ok = persistSecret(profile.codexCredentialsJSON, profile.id, .codexCredentialsJSON) && ok
        return ok
    }

    private func persistSecret(_ value: String?, _ profileId: UUID, _ field: KeychainService.ProfileSecretField) -> Bool {
        guard keychainService.saveProfileSecret(value, profileId: profileId, field: field) else {
            return false
        }
        guard let value = value else { return true }  // deletions need no read-back
        return keychainService.verifyProfileSecret(value, profileId: profileId, field: field)
    }

    /// Removes a deleted profile's Keychain items.
    func deleteProfileSecrets(_ profileId: UUID) {
        keychainService.deleteAllProfileSecrets(profileId: profileId)
    }

    func saveActiveProfileId(_ id: UUID) {
        defaults.set(id.uuidString, forKey: Keys.activeProfileId)
    }

    func loadActiveProfileId() -> UUID? {
        guard let uuidString = defaults.string(forKey: Keys.activeProfileId) else {
            return nil
        }
        return UUID(uuidString: uuidString)
    }

    func saveDisplayMode(_ mode: ProfileDisplayMode) {
        defaults.set(mode.rawValue, forKey: Keys.displayMode)
    }

    func loadDisplayMode() -> ProfileDisplayMode {
        guard let rawValue = defaults.string(forKey: Keys.displayMode),
              let mode = ProfileDisplayMode(rawValue: rawValue) else {
            return .single
        }
        return mode
    }

    // MARK: - Multi-Profile Display Config

    func saveMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: Keys.multiProfileConfig)
        } catch {
            LoggingService.shared.logStorageError("saveMultiProfileConfig", error: error)
        }
    }

    func loadMultiProfileConfig() -> MultiProfileDisplayConfig {
        guard let data = defaults.data(forKey: Keys.multiProfileConfig) else {
            return .default
        }
        do {
            return try JSONDecoder().decode(MultiProfileDisplayConfig.self, from: data)
        } catch {
            LoggingService.shared.logStorageError("loadMultiProfileConfig", error: error)
            return .default
        }
    }

    // MARK: - Credential Helpers

    func saveProfileCredentials(_ profileId: UUID, credentials: ProfileCredentials) throws {
        var profiles = loadProfiles()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        // Update credentials directly in profile
        profiles[index].claudeSessionKey = credentials.claudeSessionKey
        profiles[index].organizationId = credentials.organizationId
        profiles[index].apiSessionKey = credentials.apiSessionKey
        profiles[index].apiOrganizationId = credentials.apiOrganizationId
        profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON

        saveProfiles(profiles)
    }

    func loadProfileCredentials(_ profileId: UUID) throws -> ProfileCredentials {
        let profiles = loadProfiles()
        guard let profile = profiles.first(where: { $0.id == profileId }) else {
            throw NSError(domain: "ProfileStore", code: 404, userInfo: [NSLocalizedDescriptionKey: "Profile not found"])
        }

        return ProfileCredentials(
            claudeSessionKey: profile.claudeSessionKey,
            organizationId: profile.organizationId,
            apiSessionKey: profile.apiSessionKey,
            apiOrganizationId: profile.apiOrganizationId,
            cliCredentialsJSON: profile.cliCredentialsJSON
        )
    }
}
