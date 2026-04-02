import AppKit
import SwiftUI

struct SettingsView: View {
    @StateObject private var permissionsManager = PermissionsManager()

    @State private var selectedTab = 0
    @State private var saved = false
    @State private var showDeleteDataAlert = false

    @State private var operatingMode: AppOperatingMode = .localOnly
    @State private var externalProviderName = ""
    @State private var externalBaseURL = ""
    @State private var externalAPIKey = ""
    @State private var summaryProvider: SummaryProvider = .disabled
    @State private var summaryExternalModel = ""
    @State private var summaryLocalModel = ""
    @State private var visionProvider: VisionProvider = .ollama
    @State private var visionModel = ""
    @State private var visionExternalModel = ""
    @State private var ocrProvider: OCRProviderKind = .ollamaWithVisionFallback
    @State private var ollamaModel = ""
    @State private var ollamaBaseURL = ""

    @State private var vaultPath = ""
    @State private var dataDirectoryPath = ""
    @State private var startPaused = false
    @State private var globalPause = false
    @State private var retentionDays = ""
    @State private var summaryInterval = ""
    @State private var maxPromptChars = ""
    @State private var maxCapturesPerSession = ""
    @State private var normalCaptureInterval = ""
    @State private var degradedCaptureInterval = ""
    @State private var highUncertaintyCaptureInterval = ""
    @State private var storageProfile: StorageProfile = .balanced
    @State private var captureRetentionMode: CaptureRetentionMode = .raw

    @State private var blacklistedBundleIds = ""
    @State private var metadataOnlyBundleIds = ""
    @State private var blacklistedWindowPatterns = ""

    @State private var microphoneCaptureEnabled = false
    @State private var systemAudioCaptureEnabled = false
    @State private var audioPythonCommand = ""
    @State private var audioModelName = ""
    @State private var audioRuntimeStatus = ""

    @State private var systemPrompt = ""
    @State private var userPromptSuffix = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            providersTab
                .tabItem { Label("Providers", systemImage: "network") }
                .tag(1)

            captureTab
                .tabItem { Label("Capture", systemImage: "camera") }
                .tag(2)

            privacyTab
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(3)

            audioTab
                .tabItem { Label("Audio", systemImage: "waveform") }
                .tag(4)

            promptsTab
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
                .tag(5)
        }
        .padding()
        .frame(minWidth: 760, minHeight: 660)
        .onAppear {
            loadSettings()
            permissionsManager.checkAll()
        }
        .alert("Delete all local data?", isPresented: $showDeleteDataAlert) {
            Button("Delete", role: .destructive) { deleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local database, screenshots and audio cache from the app data folder.")
        }
    }

    private var generalTab: some View {
        Form {
            Section("Product Mode") {
                Picker("Operating mode", selection: $operatingMode) {
                    ForEach(AppOperatingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Text(modeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data") {
                HStack {
                    TextField("Data folder", text: $dataDirectoryPath)
                    Button("Browse") { browseFolder(binding: $dataDirectoryPath) }
                    Button("Open") { openFolder(path: dataDirectoryPath) }
                }

                HStack {
                    TextField("Obsidian vault", text: $vaultPath)
                    Button("Browse") { browseFolder(binding: $vaultPath) }
                }
            }

            Section("Runtime") {
                Toggle("Start paused", isOn: $startPaused)
                Toggle("Pause capture now", isOn: $globalPause)

                HStack {
                    Text("Retention")
                    TextField("30", text: $retentionDays)
                        .frame(width: 70)
                    Text("days")
                }

                HStack {
                    Text("Auto-summary every")
                    TextField("60", text: $summaryInterval)
                        .frame(width: 70)
                    Text("minutes")
                }
            }

            Section("Diagnostics") {
                diagnosticsRow("Current mode", value: operatingMode.label)
                diagnosticsRow("Data folder", value: dataDirectoryPath)
                diagnosticsRow("Summary provider", value: summaryProvider.label)
                diagnosticsRow("Vision provider", value: visionProvider.label)
            }

            Section("Danger Zone") {
                Button("Forget external credentials") {
                    externalAPIKey = ""
                    let settings = AppSettings()
                    settings.forgetCredentials()
                }
                .foregroundStyle(.orange)

                Button("Delete all local data") {
                    showDeleteDataAlert = true
                }
                .foregroundStyle(.red)
            }

            saveButton
        }
    }

    private var providersTab: some View {
        Form {
            Section("External Provider") {
                TextField("Provider label", text: $externalProviderName)
                TextField("Base URL", text: $externalBaseURL)
                SecureField("API key", text: $externalAPIKey)
            }

            Section("Summary") {
                Picker("Provider", selection: $summaryProvider) {
                    ForEach(SummaryProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                TextField("External model", text: $summaryExternalModel)
                TextField("Local model", text: $summaryLocalModel)
            }

            Section("Vision") {
                Picker("Provider", selection: $visionProvider) {
                    ForEach(VisionProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                TextField("Local model", text: $visionModel)
                TextField("External model", text: $visionExternalModel)
            }

            Section("OCR") {
                Picker("Provider", selection: $ocrProvider) {
                    ForEach(OCRProviderKind.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.menu)

                TextField("Ollama OCR model", text: $ollamaModel)
                TextField("Ollama base URL", text: $ollamaBaseURL)
            }

            saveButton
        }
    }

    private var captureTab: some View {
        Form {
            Section("Cadence") {
                intervalRow("Normal", value: $normalCaptureInterval)
                intervalRow("Degraded", value: $degradedCaptureInterval)
                intervalRow("High uncertainty", value: $highUncertaintyCaptureInterval)
            }

            Section("Budgets") {
                numericRow("Max prompt chars", value: $maxPromptChars)
                numericRow("Max captures per session", value: $maxCapturesPerSession)
            }

            Section("Storage") {
                Picker("Storage profile", selection: $storageProfile) {
                    ForEach(StorageProfile.allCases) { profile in
                        Text(profile.rawValue.capitalized).tag(profile)
                    }
                }
                .pickerStyle(.menu)

                Picker("Capture retention", selection: $captureRetentionMode) {
                    ForEach(CaptureRetentionMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            saveButton
        }
    }

    private var privacyTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PermissionsView(manager: permissionsManager)

                GroupBox("Blacklisted bundle IDs") {
                    listEditor(text: $blacklistedBundleIds)
                }

                GroupBox("Metadata-only apps") {
                    listEditor(text: $metadataOnlyBundleIds)
                }

                GroupBox("Blocked window title patterns") {
                    listEditor(text: $blacklistedWindowPatterns)
                }

                saveButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var audioTab: some View {
        Form {
            Section("Experimental Toggles") {
                Toggle("Enable microphone transcription", isOn: $microphoneCaptureEnabled)
                Toggle("Enable system audio transcription", isOn: $systemAudioCaptureEnabled)
            }

            Section("Runtime") {
                TextField("Python command or absolute path", text: $audioPythonCommand)
                TextField("Whisper model", text: $audioModelName)
                diagnosticsRow("Runtime status", value: audioRuntimeStatus)
            }

            Section("Notes") {
                Text("Audio is experimental, off by default, and depends on an external Python runtime plus Whisper dependencies.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            saveButton
        }
    }

    private var promptsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Prompt")
                .font(.headline)
            TextEditor(text: $systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .border(Color.gray.opacity(0.2))

            Text("Summary Template")
                .font(.headline)
            TextEditor(text: $userPromptSuffix)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 220)
                .border(Color.gray.opacity(0.2))

            HStack {
                Button("Reset to Defaults") {
                    systemPrompt = AppSettings.defaultSystemPrompt
                    userPromptSuffix = AppSettings.defaultUserPromptSuffix
                }
                .foregroundStyle(.red)
                Spacer()
                saveButton
            }
        }
        .padding(.top, 8)
    }

    private var saveButton: some View {
        HStack {
            Spacer()
            if saved {
                Text("Saved")
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            Button("Save") { saveSettings() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var modeDescription: String {
        switch operatingMode {
        case .localOnly:
            return "No network providers are used. External provider selections are ignored in runtime."
        case .hybrid:
            return "Capture and OCR stay local. External summaries are allowed if configured."
        case .cloudAssisted:
            return "External providers are allowed for summaries and screenshot analysis."
        }
    }

    private func loadSettings() {
        let settings = AppSettings()
        operatingMode = settings.operatingMode
        externalProviderName = settings.externalProviderName
        externalBaseURL = settings.externalBaseURL
        externalAPIKey = settings.externalAPIKey
        summaryProvider = settings.summaryProvider
        summaryExternalModel = settings.summaryExternalModel
        summaryLocalModel = settings.summaryLocalModel
        visionProvider = settings.visionProvider
        visionModel = settings.visionModel
        visionExternalModel = settings.visionExternalModel
        ocrProvider = settings.ocrProvider
        ollamaModel = settings.ollamaModelName
        ollamaBaseURL = settings.ollamaBaseURL

        vaultPath = settings.obsidianVaultPath
        dataDirectoryPath = settings.dataDirectoryPath
        startPaused = settings.startPaused
        globalPause = settings.globalPause
        retentionDays = String(settings.retentionDays)
        summaryInterval = String(settings.summaryIntervalMinutes)
        maxPromptChars = String(settings.maxPromptChars)
        maxCapturesPerSession = String(settings.maxCapturesPerSession)
        normalCaptureInterval = String(Int(settings.normalCaptureIntervalSeconds))
        degradedCaptureInterval = String(Int(settings.degradedCaptureIntervalSeconds))
        highUncertaintyCaptureInterval = String(Int(settings.highUncertaintyCaptureIntervalSeconds))
        storageProfile = settings.storageProfile
        captureRetentionMode = settings.captureRetentionMode

        blacklistedBundleIds = settings.blacklistedBundleIds.joined(separator: "\n")
        metadataOnlyBundleIds = settings.metadataOnlyBundleIds.joined(separator: "\n")
        blacklistedWindowPatterns = settings.blacklistedWindowPatterns.joined(separator: "\n")

        microphoneCaptureEnabled = settings.microphoneCaptureEnabled
        systemAudioCaptureEnabled = settings.systemAudioCaptureEnabled
        audioPythonCommand = settings.audioPythonCommand
        audioModelName = settings.audioModelName
        audioRuntimeStatus = AudioRuntimeResolver.resolve(settings: settings).description

        systemPrompt = settings.systemPrompt
        userPromptSuffix = settings.userPromptSuffix
    }

    private func saveSettings() {
        var settings = AppSettings()
        settings.operatingMode = operatingMode
        settings.externalProviderName = externalProviderName
        settings.externalBaseURL = externalBaseURL
        settings.externalAPIKey = externalAPIKey
        settings.summaryProvider = summaryProvider
        settings.summaryExternalModel = summaryExternalModel
        settings.summaryLocalModel = summaryLocalModel
        settings.visionProvider = visionProvider
        settings.visionModel = visionModel
        settings.visionExternalModel = visionExternalModel
        settings.ocrProvider = ocrProvider
        settings.ollamaModelName = ollamaModel
        settings.ollamaBaseURL = ollamaBaseURL

        settings.obsidianVaultPath = vaultPath
        settings.dataDirectoryPath = dataDirectoryPath
        settings.startPaused = startPaused
        settings.globalPause = globalPause
        settings.retentionDays = Int(retentionDays) ?? 30
        settings.summaryIntervalMinutes = Int(summaryInterval) ?? 60
        settings.maxPromptChars = Int(maxPromptChars) ?? 300_000
        settings.maxCapturesPerSession = Int(maxCapturesPerSession) ?? 500
        settings.normalCaptureIntervalSeconds = Double(normalCaptureInterval) ?? 60
        settings.degradedCaptureIntervalSeconds = Double(degradedCaptureInterval) ?? 10
        settings.highUncertaintyCaptureIntervalSeconds = Double(highUncertaintyCaptureInterval) ?? 3
        settings.storageProfile = storageProfile
        settings.captureRetentionMode = captureRetentionMode

        settings.blacklistedBundleIds = splitLines(blacklistedBundleIds)
        settings.metadataOnlyBundleIds = splitLines(metadataOnlyBundleIds)
        settings.blacklistedWindowPatterns = splitLines(blacklistedWindowPatterns)

        settings.microphoneCaptureEnabled = microphoneCaptureEnabled
        settings.systemAudioCaptureEnabled = systemAudioCaptureEnabled
        settings.audioPythonCommand = audioPythonCommand
        settings.audioModelName = audioModelName

        settings.systemPrompt = systemPrompt
        settings.userPromptSuffix = userPromptSuffix

        audioRuntimeStatus = AudioRuntimeResolver.resolve(settings: settings).description
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)

        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }
    }

    private func browseFolder(binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
        }
    }

    private func openFolder(path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func deleteAllData() {
        NotificationCenter.default.post(name: .deleteAllLocalDataRequested, object: nil)
    }

    private func diagnosticsRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func intervalRow(_ label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: value)
                .frame(width: 80)
            Text("sec")
        }
    }

    private func numericRow(_ label: String, value: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("0", text: value)
                .frame(width: 120)
        }
    }

    private func listEditor(text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 120)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.2))
            )
    }

    private func splitLines(_ text: String) -> [String] {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
