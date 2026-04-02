import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var apiKey: String = ""
    @State private var vaultPath: String = ""
    @State private var retentionDays: String = ""
    @State private var llmModel: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("OpenRouter API") {
                SecureField("API Key", text: $apiKey)
                TextField("Model", text: $llmModel)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Obsidian") {
                TextField("Vault Path", text: $vaultPath)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Retention") {
                TextField("Days to keep", text: $retentionDays)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                if saved {
                    Text("Saved!").foregroundStyle(.green)
                }
                Button("Save") { Task { await saveSettings() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450, height: 350)
        .onAppear { loadSettings() }
    }

    private func loadSettings() {
        apiKey = settings.openRouterApiKey
        vaultPath = settings.obsidianVaultPath
        retentionDays = String(settings.retentionDays)
        llmModel = settings.llmModel
    }

    @MainActor
    private func saveSettings() async {
        settings.openRouterApiKey = apiKey
        settings.obsidianVaultPath = vaultPath
        settings.retentionDays = Int(retentionDays) ?? 30
        settings.llmModel = llmModel
        saved = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        saved = false
    }
}
