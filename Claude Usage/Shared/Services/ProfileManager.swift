//
//  ProfileManager.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-01-07.
//

import Foundation
import Combine

@MainActor
class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []
    @Published var activeProfile: Profile?
    @Published var displayMode: ProfileDisplayMode = .single
    @Published var multiProfileConfig: MultiProfileDisplayConfig = .default
    @Published var isSwitchingProfile: Bool = false

    private let profileStore = ProfileStore.shared
    private let cliSyncService = ClaudeCodeSyncService.shared

    private var switchingSemaphore = false

    /// When the tracker last switched profiles (whether or not the keychain
    /// write succeeded). `adoptExternalLoginIfNeeded` stays quiet for a grace
    /// period after this, so it never mistakes the tracker's own switch — or a
    /// switch that could not be applied — for a user `/login`.
    private var lastProfileSwitchAt: Date?
    private static let adoptionGracePeriod: TimeInterval = 90

    /// Set when a switch could not rewrite the shared Claude Code login (sessions
    /// were holding it); `applyPendingMainLoginSwitchIfSafe` retries each cycle.
    private static let pendingMainLoginSwitchKey = "ProfileManager.pendingMainLoginSwitch"
    private static let pendingMainLoginSwitchSinceKey = "ProfileManager.pendingMainLoginSwitchSince"
    private static let pendingMainLoginPreviousKey = "ProfileManager.pendingMainLoginPrevious"
    /// A pending switch older than this is dropped: the account that was chosen
    /// a day ago is not necessarily the one with room now.
    static let pendingMainLoginSwitchMaxAge: TimeInterval = 24 * 3600
    private var pendingMainLoginSwitch: Bool {
        get { AppEnvironment.userDefaults.bool(forKey: Self.pendingMainLoginSwitchKey) }
        set {
            AppEnvironment.userDefaults.set(newValue, forKey: Self.pendingMainLoginSwitchKey)
            if newValue {
                AppEnvironment.userDefaults.set(Date().timeIntervalSince1970, forKey: Self.pendingMainLoginSwitchSinceKey)
            } else {
                AppEnvironment.userDefaults.removeObject(forKey: Self.pendingMainLoginSwitchSinceKey)
                AppEnvironment.userDefaults.removeObject(forKey: Self.pendingMainLoginPreviousKey)
            }
        }
    }
    private var pendingMainLoginSwitchSince: Date? {
        let t = AppEnvironment.userDefaults.double(forKey: Self.pendingMainLoginSwitchSinceKey)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    /// The account the shared login still belongs to while a switch is pending.
    private var pendingMainLoginPrevious: String? {
        get { AppEnvironment.userDefaults.string(forKey: Self.pendingMainLoginPreviousKey) }
        set { AppEnvironment.userDefaults.set(newValue, forKey: Self.pendingMainLoginPreviousKey) }
    }
    /// True while a pending-switch retry is in flight, so cycles never overlap.
    private var isApplyingPendingSwitch = false

    /// The account the keychain login belonged to when the tracker last looked,
    /// so a `/login` (the keychain changing account) is told apart from the
    /// keychain simply still holding the account the tracker switched away from.
    private static let lastKeychainIdentityKey = "ProfileManager.lastKeychainIdentity"
    private var lastKeychainIdentity: String? {
        get { AppEnvironment.userDefaults.string(forKey: Self.lastKeychainIdentityKey) }
        set { AppEnvironment.userDefaults.set(newValue, forKey: Self.lastKeychainIdentityKey) }
    }

    private init() {}

    // MARK: - Initialization

    func loadProfiles() {
        profiles = profileStore.loadProfiles()

        // Ensure minimum 1 profile
        if profiles.isEmpty {
            let defaultProfile = createDefaultProfile()
            profiles = [defaultProfile]
            profileStore.saveProfiles(profiles)

            // On first launch, try to sync CLI credentials to the new default profile
            syncCLICredentialsToDefaultProfile(defaultProfile.id)
        }

        // Load active profile
        if let activeId = profileStore.loadActiveProfileId(),
           let profile = profiles.first(where: { $0.id == activeId }) {
            activeProfile = profile
        } else {
            activeProfile = profiles.first
            if let first = profiles.first {
                profileStore.saveActiveProfileId(first.id)
            }
        }

        // First run of this build: the keychain login was the active profile's
        // (earlier builds kept them equal), so seed the last-seen identity from
        // it rather than treating the first look as a `/login`.
        if lastKeychainIdentity == nil, let active = activeProfile,
           let identity = cliSyncService.accountIdentity(fromOAuthAccountJSON: active.oauthAccountJSON) {
            lastKeychainIdentity = identity
        }

        displayMode = profileStore.loadDisplayMode()
        multiProfileConfig = profileStore.loadMultiProfileConfig()

        LoggingService.shared.log("ProfileManager: Loaded \(profiles.count) profile(s), active: \(activeProfile?.name ?? "none")")
    }

    // MARK: - Profile Operations

    func createProfile(name: String? = nil, provider: Provider = .anthropic, copySettingsFrom: Profile? = nil) -> Profile {
        let usedNames = profiles.map { $0.name }
        let profileName = name ?? FunnyNameGenerator.getRandomName(excluding: usedNames)

        // Copied icon settings may reference displays the new provider can't
        // render (e.g. token counts) — sanitize against its capabilities.
        var iconConfig = copySettingsFrom?.iconConfig ?? .default
        if !provider.descriptor.capabilities.tokenCounts {
            for index in iconConfig.metrics.indices where iconConfig.metrics[index].weekDisplayMode == .tokens {
                iconConfig.metrics[index].weekDisplayMode = .percentage
            }
        }

        let newProfile = Profile(
            id: UUID(),
            name: profileName,
            provider: provider,
            hasCliAccount: false,
            iconConfig: iconConfig,
            refreshInterval: copySettingsFrom?.refreshInterval ?? 30.0,
            autoStartSessionEnabled: copySettingsFrom?.autoStartSessionEnabled ?? false,
            checkOverageLimitEnabled: copySettingsFrom?.checkOverageLimitEnabled ?? true,
            notificationSettings: copySettingsFrom?.notificationSettings ?? NotificationSettings(),
            isSelectedForDisplay: true
        )

        profiles.append(newProfile)
        profileStore.saveProfiles(profiles)

        LoggingService.shared.log("Created new profile: \(newProfile.name)")
        return newProfile
    }

    func updateProfile(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile

            if activeProfile?.id == profile.id {
                activeProfile = profile

                // Detailed logging for credential state
                LoggingService.shared.log("ProfileManager.updateProfile: Updated ACTIVE profile '\(profile.name)'")
                LoggingService.shared.log("  - claudeSessionKey: \(profile.claudeSessionKey == nil ? "NIL" : "EXISTS (len: \(profile.claudeSessionKey!.count))")")
                LoggingService.shared.log("  - organizationId: \(profile.organizationId == nil ? "NIL" : "EXISTS")")
                LoggingService.shared.log("  - hasClaudeAI: \(profile.hasClaudeAI)")
                LoggingService.shared.log("  - hasAnyCredentials: \(profile.hasAnyCredentials)")
                LoggingService.shared.log("  - claudeUsage: \(profile.claudeUsage == nil ? "NIL" : "EXISTS")")
            } else {
                LoggingService.shared.log("Updated profile: \(profile.name) (not active)")
            }

            profileStore.saveProfiles(profiles)
        }
    }

    func deleteProfile(_ id: UUID) throws {
        guard profiles.count > 1 else {
            throw ProfileError.cannotDeleteLastProfile
        }

        let profileName = profiles.first(where: { $0.id == id })?.name ?? "unknown"

        // Remove the profile's terminal launcher script, if any (the launcher's
        // config dir and login are left in place — see TerminalLauncherService).
        if let profile = profiles.first(where: { $0.id == id }) {
            TerminalLauncherService.shared.uninstall(profile)
        }

        // Clean up usage history for this profile
        UsageHistoryService.shared.deleteHistory(for: id)
        LoggingService.shared.log("Successfully deleted usage history for profile: \(profileName)")

        profiles.removeAll { $0.id == id }

        // Remove the profile's credentials from the Keychain (they no longer live
        // in the profiles plist — #267).
        profileStore.deleteProfileSecrets(id)

        // Switch to first profile if deleted active
        if activeProfile?.id == id {
            if let first = profiles.first {
                Task {
                    await activateProfile(first.id)
                }
            }
        }

        profileStore.saveProfiles(profiles)
        LoggingService.shared.log("Deleted profile: \(profileName)")
    }

    func toggleProfileSelection(_ id: UUID) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = self.profiles.firstIndex(where: { $0.id == id }) {
                self.profiles[index].isSelectedForDisplay.toggle()
                self.profileStore.saveProfiles(self.profiles)
            }
        }
    }

    func getSelectedProfiles() -> [Profile] {
        displayMode == .single
            ? [activeProfile].compactMap { $0 }
            : profiles.filter { $0.isSelectedForDisplay }
    }

    func updateDisplayMode(_ mode: ProfileDisplayMode) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.displayMode = mode
            self?.profileStore.saveDisplayMode(mode)
            LoggingService.shared.log("Updated display mode to: \(mode.rawValue)")
        }
    }

    func updateMultiProfileConfig(_ config: MultiProfileDisplayConfig) {
        // Use async to avoid "Publishing changes from within view updates" warning
        DispatchQueue.main.async { [weak self] in
            self?.multiProfileConfig = config
            self?.profileStore.saveMultiProfileConfig(config)
            LoggingService.shared.log("Updated multi-profile config: style=\(config.iconStyle.rawValue), showWeek=\(config.showWeek)")
        }
    }

    // MARK: - Profile Activation (Centralized)

    /// `selectedBy` is recorded in the selection file: `auto` for a switch the
    /// tracker made (limit reached, dead login), `user` for a click.
    func activateProfile(_ id: UUID, selectedBy: String = "user") async {
        guard !switchingSemaphore else {
            LoggingService.shared.log("Profile switch already in progress, ignoring")
            return
        }

        guard let profile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found: \(id)")
            return
        }

        if activeProfile?.id == id {
            LoggingService.shared.log("Profile already active: \(profile.name)")
            return
        }

        switchingSemaphore = true
        isSwitchingProfile = true
        lastProfileSwitchAt = Date()

        LoggingService.shared.log("Switching to profile: \(profile.name)")

        // Re-sync current profile before leaving (Anthropic-only: providers
        // without CLI account sync never touch the Claude Code keychain)
        if let currentProfile = activeProfile,
           currentProfile.provider.descriptor.capabilities.cliAccountSync,
           currentProfile.cliCredentialsJSON != nil || currentProfile.customKeychainServiceName != nil {
            do {
                try cliSyncService.resyncBeforeSwitching(for: currentProfile.id)
                // Reload profiles to get the updated data in memory
                profiles = profileStore.loadProfiles()
                LoggingService.shared.log("✓ Re-synced current profile before switching")
            } catch {
                LoggingService.shared.logError("Failed to re-sync current profile (non-fatal)", error: error)
            }
        }

        // Reload profiles from disk to get latest data (including any resyncs from other profiles)
        profiles = profileStore.loadProfiles()

        // Get the updated target profile from the reloaded data
        guard let updatedProfile = profiles.first(where: { $0.id == id }) else {
            LoggingService.shared.log("Profile not found after reload: \(id)")
            switchingSemaphore = false
            isSwitchingProfile = false
            return
        }

        // Rotation first reaches NEW work: the selection file names the account
        // `cca` (claude-rotate) starts its next session in. That never touches a
        // login a running session holds. (Anthropic-only — switching to e.g. a
        // Codex profile must not rewrite anything of Claude Code's.)
        if updatedProfile.provider.descriptor.capabilities.cliAccountSync {
            writeSelection(for: updatedProfile, by: selectedBy)
        }

        // Then the shared Claude Code login (the main keychain entry), but only
        // when nothing holds it — see `ClaudeCodeSyncService.switchMainLogin`.
        LoggingService.shared.log("Checking CLI credentials for profile '\(updatedProfile.name)': hasJSON=\(updatedProfile.cliCredentialsJSON != nil)")

        if AutoSwitchPolicy.canBeApplied(updatedProfile) {
            let previousName = activeProfile?.name ?? "the previous account"
            pendingMainLoginSwitch = true
            pendingMainLoginPrevious = previousName
            do {
                let outcome = try await cliSyncService.switchMainLogin(to: updatedProfile.id)
                // Reload: the switch may have refreshed and stored the login.
                profiles = profileStore.loadProfiles()
                handleMainLoginSwitch(outcome, for: updatedProfile, previousName: previousName, announceLater: false)
            } catch {
                pendingMainLoginSwitch = false
                LoggingService.shared.logError("Failed to apply CLI credentials (non-fatal)", error: error)
                NotificationManager.shared.sendSwitchNotAppliedNotification(
                    profileName: updatedProfile.name,
                    reason: "notification.switch_not_applied.apply_failed".localized,
                    settings: updatedProfile.notificationSettings
                )
            }
        } else if updatedProfile.provider.descriptor.capabilities.cliAccountSync {
            // The tracker will show this profile as active, but Claude Code is
            // still on the previous account. Say so — silently "succeeding" here
            // is how a user ends up hitting a limit on an account the tracker
            // claims it left.
            // A pinned profile's keychain entry belongs to another config dir
            // and is never copied here; it needs its own /login in Claude Code.
            pendingMainLoginSwitch = false   // nothing to apply later either
            let needsMainLogin = updatedProfile.customKeychainServiceName != nil
            LoggingService.shared.log("⚠️ Profile '\(updatedProfile.name)' has no \(needsMainLogin ? "main login of its own" : "CLI credentials JSON") — Claude Code NOT switched")
            NotificationManager.shared.sendSwitchNotAppliedNotification(
                profileName: updatedProfile.name,
                reason: (needsMainLogin
                    ? "notification.switch_not_applied.needs_main_login"
                    : "notification.switch_not_applied.no_cli_creds").localized,
                settings: updatedProfile.notificationSettings
            )
        }

        // Update last used timestamp
        var updated = updatedProfile
        updated.lastUsedAt = Date()

        if let index = profiles.firstIndex(where: { $0.id == updatedProfile.id }) {
            profiles[index] = updated
        }

        activeProfile = updated
        profileStore.saveActiveProfileId(id)
        profileStore.saveProfiles(profiles)

        // Update statusline script if the new profile has credentials
        // (statusline is Claude Code infrastructure — capability-gated)
        if updated.provider.descriptor.capabilities.cliAccountSync,
           updated.claudeSessionKey != nil && updated.organizationId != nil {
            do {
                try StatuslineService.shared.updateScriptsIfInstalled()
                LoggingService.shared.log("✓ Updated statusline for profile: \(updated.name)")
            } catch {
                LoggingService.shared.logError("Failed to update statusline (non-fatal)", error: error)
            }
        }

        // Update profile name in statusline config
        do {
            try StatuslineService.shared.updateProfileNameInConfig(updated.name)
        } catch {
            LoggingService.shared.logError("Failed to update statusline profile name (non-fatal)", error: error)
        }

        switchingSemaphore = false
        isSwitchingProfile = false

        LoggingService.shared.log("Successfully activated profile: \(updatedProfile.name)")
    }

    // MARK: - External Login Adoption

    /// Follows a `/login` done directly in Claude Code.
    ///
    /// Claude Code's `/login` rewrites the system keychain and `.claude.json`
    /// without telling us. Until now the tracker only noticed a new account when
    /// the user clicked a profile here, so after a CLI-side login it kept
    /// polling and switching on behalf of the wrong profile — and the profile
    /// that was actually logged in went stale because it was "not active".
    ///
    /// Each refresh cycle, compare the keychain's account identity with the
    /// active profile's. If the keychain now belongs to a *different* known
    /// profile, snapshot its credentials into that profile and make it active,
    /// WITHOUT rewriting the keychain (it is already right). Unknown accounts
    /// are left alone and only logged.
    ///
    /// Returns the adopted profile, or nil if nothing changed.
    /// Saves made from the in-memory list must not undo credential updates
    /// `ClaudeCodeSyncService` wrote straight to the store (rotated tokens, a
    /// captured main login). Pull those fields in before such a save.
    private func reloadStoredCredentialState() {
        let stored = profileStore.loadProfiles()
        for index in profiles.indices {
            guard let fresh = stored.first(where: { $0.id == profiles[index].id }) else { continue }
            profiles[index].cliCredentialsJSON = fresh.cliCredentialsJSON
            profiles[index].hasOwnMainLogin = fresh.hasOwnMainLogin
            profiles[index].oauthAccountJSON = fresh.oauthAccountJSON
            profiles[index].cliAccountSyncedAt = fresh.cliAccountSyncedAt
        }
        if let id = activeProfile?.id, let index = profiles.firstIndex(where: { $0.id == id }) {
            activeProfile = profiles[index]
        }
    }

    /// Records the shared Claude Code login (the main keychain entry) into the
    /// profile it belongs to, as that profile's own main login, so a later
    /// switch back can apply it and the compare-and-swap in `switchMainLogin`
    /// recognises it. Runs every cycle, read-only. The login need not be the
    /// active profile's: after a switch whose keychain write was refused, the
    /// keychain goes on holding the previous account, and Claude Code goes on
    /// rotating it — the stored copy must follow, or it is stale when needed.
    func captureActiveMainLogin() {
        guard !switchingSemaphore else { return }
        ClaudeCodeSyncService.shared.signalSessionsIfKeychainLoginChanged()
        // One keychain read per cycle, shared by every candidate.
        guard let systemJSON = try? ClaudeCodeSyncService.shared.readSystemCredentials() else { return }
        let candidates = ([activeProfile].compactMap { $0 } + profiles)
            .filter { $0.provider.descriptor.capabilities.cliAccountSync }
        for profile in candidates where ClaudeCodeSyncService.shared.captureMainLogin(systemJSON, for: profile.id) {
            reloadStoredCredentialState()
            LoggingService.shared.log("captureActiveMainLogin: saved main login for '\(profile.name)'")
            return
        }
    }

    /// Writes the account chosen for new work to the selection file.
    private func writeSelection(for profile: Profile, by: String) {
        guard !AppEnvironment.isRunningTests else { return }
        if AutoSwitchSelection.forProfile(profile, by: by).write() {
            LoggingService.shared.log("activateProfile: new work goes to '\(profile.name)' (\(AutoSwitchSelection.fileName))")
        }
    }

    /// Acts on the outcome of `switchMainLogin`: clears or keeps the pending
    /// flag and tells the user what Claude Code's shared login is doing.
    private func handleMainLoginSwitch(
        _ outcome: ClaudeCodeSyncService.MainLoginSwitch, for profile: Profile, previousName: String, announceLater: Bool
    ) {
        switch outcome {
        case .applied(let raced):
            pendingMainLoginSwitch = false
            lastKeychainIdentity = ClaudeCodeSyncService.shared.accountIdentity(fromOAuthAccountJSON: profile.oauthAccountJSON) ?? lastKeychainIdentity
            LoggingService.shared.log("✓ Claude Code's shared login is '\(profile.name)' (written; was '\(previousName)')")
            if raced > 0 {
                NotificationManager.shared.sendSharedLoginRaceNotification(
                    profileName: profile.name, previousName: previousName, count: raced, settings: profile.notificationSettings)
            } else if announceLater {
                NotificationManager.shared.sendSwitchAppliedLaterNotification(
                    profileName: profile.name, settings: profile.notificationSettings)
            }
        case .alreadyApplied:
            pendingMainLoginSwitch = false
            lastKeychainIdentity = ClaudeCodeSyncService.shared.accountIdentity(fromOAuthAccountJSON: profile.oauthAccountJSON) ?? lastKeychainIdentity
            LoggingService.shared.log("✓ Claude Code's shared login is already '\(profile.name)'")
        case .refused(let reason):
            LoggingService.shared.log("⚠️ Claude Code's shared login NOT switched to '\(profile.name)': \(reason); it stays on '\(previousName)'; new sessions via cca use '\(profile.name)'")
            let text: String
            switch reason {
            case .sessionsRunning(let count):
                // Stays pending; `applyPendingMainLoginSwitchIfSafe` retries.
                guard !announceLater else { return }   // a retry's refusal is routine; say it once, at the switch
                text = "notification.switch_not_applied.sessions_running".localized(with: count, previousName, profile.name)
            case .unknownKeychainLogin:
                guard !announceLater else { return }
                text = "notification.switch_not_applied.unknown_login".localized(with: previousName)
            case .notTheSharedLoginEntry(let service):
                // Not retryable: the resolved entry will not change by itself.
                pendingMainLoginSwitch = false
                text = "notification.switch_not_applied.not_shared_entry".localized(with: service, previousName)
            }
            NotificationManager.shared.sendSwitchNotAppliedNotification(
                profileName: profile.name, reason: text, settings: profile.notificationSettings)
        }
    }

    /// Retries a shared-login switch that was refused earlier, once the policy
    /// allows it (no `claude` session on the shared login any more, keychain as
    /// last seen). Runs every refresh cycle; a no-op while nothing is pending,
    /// while a retry is already in flight, or during a switch. A switch left
    /// pending longer than `pendingMainLoginSwitchMaxAge` is dropped.
    func applyPendingMainLoginSwitchIfSafe() {
        guard pendingMainLoginSwitch, !switchingSemaphore, !isApplyingPendingSwitch, let active = activeProfile,
              AutoSwitchPolicy.canBeApplied(active) else { return }
        if let since = pendingMainLoginSwitchSince, Date().timeIntervalSince(since) > Self.pendingMainLoginSwitchMaxAge {
            LoggingService.shared.log("applyPendingMainLoginSwitchIfSafe: the switch to '\(active.name)' has been pending for over a day; dropping it (the shared login stays on '\(pendingMainLoginPrevious ?? "the previous account")')")
            pendingMainLoginSwitch = false
            return
        }
        let previousName = pendingMainLoginPrevious ?? "the previous account"
        isApplyingPendingSwitch = true
        Task {
            defer { Task { @MainActor in self.isApplyingPendingSwitch = false } }
            do {
                let outcome = try await cliSyncService.switchMainLogin(to: active.id)
                await MainActor.run {
                    self.reloadStoredCredentialState()
                    if case .applied = outcome { self.lastProfileSwitchAt = Date() }
                    self.handleMainLoginSwitch(outcome, for: active, previousName: previousName, announceLater: true)
                }
            } catch {
                await MainActor.run { self.pendingMainLoginSwitch = false }
                LoggingService.shared.logError("applyPendingMainLoginSwitchIfSafe: giving up on '\(active.name)'", error: error)
            }
        }
    }

    /// The profile an `oauthAccount` belongs to: by stored account identity
    /// first, then by profile name == email (profiles created before
    /// oauthAccount capture only have the name).
    nonisolated static func matchingProfileIndex(in profiles: [Profile], oauthAccountJSON: String) -> Int? {
        let sync = ClaudeCodeSyncService.shared
        guard let identity = sync.accountIdentity(fromOAuthAccountJSON: oauthAccountJSON) else { return nil }
        let email = email(inOAuthAccountJSON: oauthAccountJSON)
        return profiles.firstIndex { profile in
            guard profile.provider.descriptor.capabilities.cliAccountSync else { return false }
            if let stored = sync.accountIdentity(fromOAuthAccountJSON: profile.oauthAccountJSON) {
                return stored == identity
            }
            if let email {
                return profile.name.caseInsensitiveCompare(email) == .orderedSame
            }
            return false
        }
    }

    nonisolated static func email(inOAuthAccountJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["emailAddress"] as? String
    }

    /// Picks up a login made with `claude-usage-login`, which signs in through
    /// a dedicated config dir (`ClaudeCodeSyncService.loginImportDirectory`).
    ///
    /// Why a separate dir: `/login` in Claude Code's main config dir first logs
    /// out the account already there, which revokes that account's refresh
    /// token server-side — so saving accounts by logging in one after another
    /// in the same place killed each previously saved login. A login in the
    /// import dir replaces nothing that is in use.
    ///
    /// The login becomes the profile's own main login. Its keychain entry is
    /// then deleted locally (no logout, so nothing is revoked), leaving the
    /// tracker as the lineage's only holder. If the profile is the active one,
    /// the login is applied to Claude Code right away.
    @discardableResult
    func importPendingLogin() -> Profile? {
        guard !switchingSemaphore else { return nil }
        let sync = ClaudeCodeSyncService.shared
        guard let imported = sync.readImportedLogin() else { return nil }

        guard let index = Self.matchingProfileIndex(in: profiles, oauthAccountJSON: imported.oauthAccount) else {
            LoggingService.shared.log("importPendingLogin: \(Self.email(inOAuthAccountJSON: imported.oauthAccount) ?? "account") is not a known profile; leaving it in place")
            return nil
        }

        var profile = profiles[index]
        profile.cliCredentialsJSON = imported.credentials
        profile.oauthAccountJSON = imported.oauthAccount
        profile.hasOwnMainLogin = true
        profile.cliAccountSyncedAt = Date()
        profiles[index] = profile
        if activeProfile?.id == profile.id { activeProfile = profile }
        profileStore.saveProfiles(profiles)
        sync.clearImportedLogin()
        LoggingService.shared.log("importPendingLogin: saved login for '\(profile.name)'")

        if activeProfile?.id == profile.id {
            // Apply it to Claude Code the same guarded way a switch does.
            lastProfileSwitchAt = Date()
            pendingMainLoginSwitch = true
            pendingMainLoginPrevious = profile.name
            applyPendingMainLoginSwitchIfSafe()
        }
        return profile
    }

    @discardableResult
    func adoptExternalLoginIfNeeded() -> Profile? {
        guard !switchingSemaphore else { return nil }

        // Right after the tracker itself wrote the keychain, the keychain is by
        // definition not a user `/login`. Also covers the failure mode where a
        // switch could NOT be applied (target had no CLI creds): the keychain
        // still holds the old account, and adopting it would silently revert
        // the user's switch — which is exactly the loop observed 2026-09-22.
        if let switched = lastProfileSwitchAt,
           Date().timeIntervalSince(switched) < Self.adoptionGracePeriod {
            return nil
        }

        // Who the keychain login belongs to comes from the login itself; the
        // `oauthAccount` in .claude.json can be a stale copy another session
        // wrote back, and is only used when it matches.
        let sync = ClaudeCodeSyncService.shared
        guard let systemJSON = try? sync.readSystemCredentials() else { return nil }
        let configAccount = sync.readOAuthAccount()
        guard let systemIdentity = sync.loginAccountIdentity(credentials: systemJSON, configOAuthAccount: configAccount) else {
            return nil
        }
        let systemAccount = sync.loginOAuthAccount(credentials: systemJSON, configOAuthAccount: configAccount)

        // Only a CHANGE of the keychain's account is a `/login`. The active
        // profile may legitimately differ from the keychain: a switch whose
        // keychain write was refused (sessions were holding the login) leaves
        // the keychain on the previous account on purpose, and following it
        // back here would undo the switch every cycle.
        let previousIdentity = lastKeychainIdentity
        lastKeychainIdentity = systemIdentity
        guard systemIdentity != previousIdentity else { return nil }

        let activeIdentity = activeProfile.flatMap { sync.accountIdentity(fromOAuthAccountJSON: $0.oauthAccountJSON) }
        guard systemIdentity != activeIdentity else { return nil }

        let accountForMatching = systemAccount ?? #"{"accountUuid":"\#(systemIdentity)"}"#
        guard let index = Self.matchingProfileIndex(in: profiles, oauthAccountJSON: accountForMatching) else {
            LoggingService.shared.log("adoptExternalLogin: keychain account \(Self.email(inOAuthAccountJSON: accountForMatching) ?? systemIdentity) is not a known profile; ignoring")
            return nil
        }

        var adopted = profiles[index]
        adopted.cliCredentialsJSON = systemJSON
        adopted.hasOwnMainLogin = sync.isOwnMainLogin(systemJSON, for: adopted)
        adopted.oauthAccountJSON = systemAccount ?? adopted.oauthAccountJSON
        adopted.cliAccountSyncedAt = Date()
        adopted.lastUsedAt = Date()
        profiles[index] = adopted

        let previous = activeProfile?.name ?? "none"
        activeProfile = adopted
        pendingMainLoginSwitch = false   // the user chose this login; nothing to apply
        profileStore.saveActiveProfileId(adopted.id)
        profileStore.saveProfiles(profiles)
        writeSelection(for: adopted, by: "login")

        LoggingService.shared.log("adoptExternalLogin: Claude Code is logged into '\(adopted.name)' (was '\(previous)'); adopted as active without touching the keychain")
        return adopted
    }

    // MARK: - Credentials

    func loadCredentials(for profileId: UUID) throws -> ProfileCredentials {
        return try profileStore.loadProfileCredentials(profileId)
    }

    func saveCredentials(for profileId: UUID, credentials: ProfileCredentials) throws {
        try profileStore.saveProfileCredentials(profileId, credentials: credentials)

        // Update profile in memory
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].claudeSessionKey = credentials.claudeSessionKey
            profiles[index].organizationId = credentials.organizationId
            profiles[index].apiSessionKey = credentials.apiSessionKey
            profiles[index].apiOrganizationId = credentials.apiOrganizationId
            profiles[index].cliCredentialsJSON = credentials.cliCredentialsJSON

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }
        }
    }

    /// Removes Claude.ai credentials for a profile
    func removeClaudeAICredentials(for profileId: UUID) throws {
        // Load and clear credentials from Keychain
        var creds = try profileStore.loadProfileCredentials(profileId)
        creds.claudeSessionKey = nil
        creds.organizationId = nil
        try profileStore.saveProfileCredentials(profileId, credentials: creds)

        // Update Profile model in memory
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].claudeSessionKey = nil
            profiles[index].organizationId = nil
            profiles[index].claudeUsage = nil  // Clear saved usage data

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }

        LoggingService.shared.log("ProfileManager: Removed Claude.ai credentials for profile \(profileId)")

        // Post single notification for credential change
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    /// Removes API Console credentials for a profile
    func removeAPICredentials(for profileId: UUID) throws {
        // Load and clear credentials from Keychain
        var creds = try profileStore.loadProfileCredentials(profileId)
        creds.apiSessionKey = nil
        creds.apiOrganizationId = nil
        try profileStore.saveProfileCredentials(profileId, credentials: creds)

        // Update Profile model in memory
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].apiSessionKey = nil
            profiles[index].apiOrganizationId = nil
            profiles[index].apiUsage = nil  // Clear saved usage data

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }

        LoggingService.shared.log("ProfileManager: Removed API credentials for profile \(profileId)")

        // Post single notification for credential change
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
    }

    // MARK: - Usage Data

    /// Saves Claude usage data for a specific profile
    func saveClaudeUsage(_ usage: ClaudeUsage, for profileId: UUID) {
        reloadStoredCredentialState()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveClaudeUsage: Profile not found with ID: \(profileId)")
            return
        }

        profiles[index].claudeUsage = usage

        // Update activeProfile reference if it's the same profile
        if activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }

        // Save to persistent storage
        profileStore.saveProfiles(profiles)
        LoggingService.shared.log("Saved Claude usage for profile: \(profiles[index].name)")
    }

    /// Loads Claude usage data for a specific profile
    func loadClaudeUsage(for profileId: UUID) -> ClaudeUsage? {
        return profiles.first(where: { $0.id == profileId })?.claudeUsage
    }

    /// Saves API usage data for a specific profile
    func saveAPIUsage(_ usage: APIUsage, for profileId: UUID) {
        reloadStoredCredentialState()
        guard let index = profiles.firstIndex(where: { $0.id == profileId }) else {
            LoggingService.shared.logError("saveAPIUsage: Profile not found with ID: \(profileId)")
            return
        }

        profiles[index].apiUsage = usage

        // Update activeProfile reference if it's the same profile
        if activeProfile?.id == profileId {
            activeProfile = profiles[index]
        }

        // Save to persistent storage
        profileStore.saveProfiles(profiles)
        LoggingService.shared.log("Saved API usage for profile: \(profiles[index].name)")
    }

    /// Loads API usage data for a specific profile
    func loadAPIUsage(for profileId: UUID) -> APIUsage? {
        return profiles.first(where: { $0.id == profileId })?.apiUsage
    }

    // MARK: - Profile Settings

    /// Updates icon configuration for a profile
    func updateIconConfig(_ config: MenuBarIconConfiguration, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].iconConfig = config

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates refresh interval for a profile
    func updateRefreshInterval(_ interval: TimeInterval, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].refreshInterval = interval

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates auto-start session setting for a profile
    func updateAutoStartSessionEnabled(_ enabled: Bool, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].autoStartSessionEnabled = enabled

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Pauses or resumes a profile (see `Profile.isPaused`)
    func updatePaused(_ paused: Bool, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].isPaused = paused

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates check overage limit setting for a profile
    func updateCheckOverageLimitEnabled(_ enabled: Bool, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].checkOverageLimitEnabled = enabled

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates notification settings for a profile
    func updateNotificationSettings(_ settings: NotificationSettings, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].notificationSettings = settings

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates organization ID for a profile
    func updateOrganizationId(_ orgId: String?, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].organizationId = orgId

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    /// Updates API organization ID for a profile
    func updateAPIOrganizationId(_ orgId: String?, for profileId: UUID) {
        if let index = profiles.firstIndex(where: { $0.id == profileId }) {
            profiles[index].apiOrganizationId = orgId

            if activeProfile?.id == profileId {
                activeProfile = profiles[index]
            }

            profileStore.saveProfiles(profiles)
        }
    }

    // MARK: - Private Helpers

    /// Syncs CLI credentials to default profile on first launch only
    private func syncCLICredentialsToDefaultProfile(_ profileId: UUID) {
        do {
            // Attempt to read credentials from system Keychain
            guard let jsonData = try cliSyncService.readSystemCredentials() else {
                LoggingService.shared.log("ProfileManager: No CLI credentials found in system Keychain")
                return
            }

            // Validate: not expired
            if cliSyncService.isTokenExpired(jsonData) {
                LoggingService.shared.log("ProfileManager: CLI credentials found but expired")
                return
            }

            // Validate: has valid access token
            guard cliSyncService.extractAccessToken(from: jsonData) != nil else {
                LoggingService.shared.log("ProfileManager: CLI credentials found but missing access token")
                return
            }

            // Sync to the newly created default profile
            try cliSyncService.syncToProfile(profileId)

            // Reload the profile to get updated credentials
            profiles = profileStore.loadProfiles()

            LoggingService.shared.log("ProfileManager: ✅ Successfully synced CLI credentials to default profile on first launch")

        } catch {
            LoggingService.shared.logError("ProfileManager: Failed to sync CLI credentials on first launch (non-fatal)", error: error)
            // Non-fatal: profile will be created without credentials
            // User can manually sync in settings
        }
    }

    private func createDefaultProfile() -> Profile {
        Profile(
            name: FunnyNameGenerator.getRandomName(excluding: []),
            iconConfig: .default,
            refreshInterval: 30.0,
            autoStartSessionEnabled: false,
            checkOverageLimitEnabled: true,
            notificationSettings: NotificationSettings()
        )
    }

}

// MARK: - ProfileError

enum ProfileError: LocalizedError {
    case cannotDeleteLastProfile

    var errorDescription: String? {
        switch self {
        case .cannotDeleteLastProfile:
            return "Cannot delete the last profile. At least one profile is required."
        }
    }
}
