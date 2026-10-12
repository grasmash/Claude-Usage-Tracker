//
//  AnthropicUsageProvider.swift
//  Claude Usage
//
//  Created by Claude Code on 2026-07-15.
//
//  Wraps the pre-existing Anthropic fetch chain behind UsageProviderService.
//  The bodies below were MOVED VERBATIM from MenuBarManager (multi-profile
//  path) and its single-profile refresh path — behavior must stay identical.
//

import Foundation

final class AnthropicUsageProvider: UsageProviderService {
    static let shared = AnthropicUsageProvider()

    let provider: Provider = .anthropic

    // Concrete type: the per-profile fetch overloads (sessionKey/oauthAccessToken)
    // are not part of APIServiceProtocol.
    private let apiService: ClaudeAPIService

    /// Seams for tests (defaults are the live behaviour): the shared keychain
    /// login read, whether a profile is the tracker's active one, and the
    /// OAuth usage fetch itself.
    let readSystemLogin: () -> String?
    let isActiveProfile: (Profile) -> Bool
    let fetchWithOAuth: (String) async throws -> ClaudeUsage

    init(
        apiService: ClaudeAPIService = ClaudeAPIService(),
        readSystemLogin: (() -> String?)? = nil,
        isActiveProfile: ((Profile) -> Bool)? = nil,
        fetchWithOAuth: ((String) async throws -> ClaudeUsage)? = nil
    ) {
        self.apiService = apiService
        self.readSystemLogin = readSystemLogin ?? { try? ClaudeCodeSyncService.shared.readSystemCredentials() }
        self.isActiveProfile = isActiveProfile ?? { $0.id == ProfileManager.shared.activeProfile?.id }
        self.fetchWithOAuth = fetchWithOAuth ?? { try await apiService.fetchUsageData(oauthAccessToken: $0) }
    }

    /// Profile credentials plus the system-keychain CLI fallback that
    /// `ClaudeAPIService.getAuthentication()` can discover during the actual
    /// API call (mirrors the old `MenuBarManager.hasAnyAvailableCredentials`).
    func hasCredentials(for profile: Profile) -> Bool {
        profile.hasUsageCredentials
            || ClaudeCodeSyncService.shared.hasUsableSystemCredentials()
    }

    /// Fetches usage data for a specific profile using its credentials.
    /// (Moved verbatim from `MenuBarManager.fetchUsageForProfile(_:)`.)
    func fetchUsage(for profile: Profile) async throws -> ClaudeUsage {
        // Priority 1: claude.ai session key (cookie-based)
        if let sessionKey = profile.claudeSessionKey,
           let orgId = profile.organizationId {
            do {
                return try await apiService.fetchUsageData(sessionKey: sessionKey, organizationId: orgId)
            } catch let error as AppError where error.code == .apiUnauthorized {
                // The session key is dead (they expire). If this profile also has
                // CLI OAuth credentials, fall through to them instead of freezing
                // the profile on its last snapshot. This is what makes "Re-sync"
                // on a profile with an expired session key actually rescue it.
                guard profile.cliCredentialsJSON != nil || profile.customKeychainServiceName != nil else {
                    throw error
                }
                LoggingService.shared.log("AnthropicUsageProvider: session key rejected for '\(profile.name)'; falling back to CLI OAuth credentials")
            }
        }

        // Priority 2: CLI OAuth credentials.
        // `ensureFreshCredentials` picks the source automatically:
        //   - If `profile.customKeychainServiceName` is set → pull fresh from that keychain entry
        //     (which Claude Code rotates during normal CLI use). No network refresh needed when
        //     the token there is still valid; otherwise transparently refresh via the
        //     refresh_token grant and write back to both keychain and profile cache.
        //   - Otherwise → use the profile's cached `cliCredentialsJSON`, refreshing if expired.
        // If `ensureFreshCredentials` returns nil (e.g. network failure during refresh), fall
        // back to the stored cliCredentialsJSON so a still-valid cached token isn't wasted.
        if profile.cliCredentialsJSON != nil || profile.customKeychainServiceName != nil {
            let usableJSON = await ClaudeCodeSyncService.shared.ensureFreshCredentials(for: profile.id)
                ?? profile.cliCredentialsJSON
            if let usableJSON = usableJSON,
               !ClaudeCodeSyncService.shared.isTokenExpired(usableJSON),
               let accessToken = ClaudeCodeSyncService.shared.extractAccessToken(from: usableJSON) {
                return try await fetchWithOAuth(accessToken)
            }
        }

        // Priority 3: the shared keychain login (Claude Code's), for the active
        // profile ONLY when that login is PROVEN to be this profile's account
        // (`loginIsProvenToBelong`: same refresh lineage as the stored login, or
        // a resolved account lookup naming this account). "Active" is not
        // proof: after a refused swap the tracker's active profile and the
        // keychain's login disagree, and on 2026-10-12 this fetch then saved
        // madmatter's usage under littlewing for ten hours. An unproven login
        // yields the cached reading below, never another account's numbers.
        if isActiveProfile(profile),
           let systemCredentials = readSystemLogin(),
           let accessToken = ClaudeCodeSyncService.shared.usageAccessToken(fromSharedLogin: systemCredentials, for: profile) {
            return try await fetchWithOAuth(accessToken)
        }

        // No usable live credential (e.g. a non-active profile whose CLI token expired and
        // must not be refreshed independently — that would rotate a token another tool such as
        // `cux` owns). Rather than surfacing a blocking "session key not found" dialog on every
        // profile switch, fall back to the profile's last-known usage snapshot. Per-model weekly
        // quotas change slowly, so a slightly stale reading is far better UX than an error
        // popup — and the active profile still refreshes live every cycle. (#290)
        if let cached = profile.claudeUsage {
            LoggingService.shared.log("AnthropicUsageProvider: no live credential for '\(profile.name)'; showing last-known cached usage")
            return cached
        }

        throw AppError(
            code: .sessionKeyNotFound,
            message: "Missing credentials for profile '\(profile.name)'",
            isRecoverable: false
        )
    }

    /// The single-profile refresh path historically used the no-arg
    /// `fetchUsageData()`, whose internal `getAuthentication()` chain covers
    /// the active profile plus system-level fallbacks. Keep that exact path.
    func fetchUsageForActiveProfile(_ profile: Profile) async throws -> ClaudeUsage {
        try await apiService.fetchUsageData()
    }
}
