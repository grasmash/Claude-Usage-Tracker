import SwiftUI

/// Settings for reading INACTIVE profiles' usage from mission control (see
/// `McUsage`). The token is pasted here and stored with the app's settings;
/// it is never shown again, logged, or put in a URL. No token = feature off.
struct MissionControlUsageSettingsView: View {
    @State private var url: String = SharedDataStore.shared.loadMissionControlURL()
    @State private var tokenDraft: String = ""
    @State private var hasToken: Bool = !SharedDataStore.shared.loadMissionControlToken().isEmpty
    @State private var status: String = McUsageClient.shared.lastStatus

    var body: some View {
        SettingsSectionCard(
            title: "mc_usage.title".localized,
            subtitle: "mc_usage.subtitle".localized
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("mc_usage.url".localized)
                    .font(DesignTokens.Typography.caption)
                TextField(SharedDataStore.defaultMissionControlURL, text: $url, onCommit: saveURL)
                    .textFieldStyle(.roundedBorder)

                Text("mc_usage.token".localized)
                    .font(DesignTokens.Typography.caption)
                HStack {
                    SecureField(hasToken ? "mc_usage.token_saved".localized : "mca_…", text: $tokenDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("mc_usage.save".localized) {
                        saveURL()
                        SharedDataStore.shared.saveMissionControlToken(tokenDraft)
                        tokenDraft = ""
                        hasToken = !SharedDataStore.shared.loadMissionControlToken().isEmpty
                    }
                    .disabled(tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasToken {
                        Button("mc_usage.clear".localized) {
                            SharedDataStore.shared.saveMissionControlToken("")
                            hasToken = false
                        }
                    }
                }

                Text("mc_usage.status".localized(with: status))
                    .font(DesignTokens.Typography.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear { status = McUsageClient.shared.lastStatus }
    }

    private func saveURL() {
        SharedDataStore.shared.saveMissionControlURL(url)
    }
}
