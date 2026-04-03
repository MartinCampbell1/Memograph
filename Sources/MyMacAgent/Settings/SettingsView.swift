import AppKit
import SwiftUI

struct SettingsPreviewState {
    let operatingMode: AppOperatingMode
    let externalProviderName: String
    let externalBaseURL: String
    let externalAPIKey: String
    let summaryProvider: SummaryProvider
    let summaryExternalModel: String
    let summaryLocalModel: String
    let visionProvider: VisionProvider
    let visionModel: String
    let visionExternalModel: String
    let ocrProvider: OCRProviderKind
    let ollamaModel: String
    let ollamaBaseURL: String
    let vaultPath: String
    let dataDirectoryPath: String
    let startPaused: Bool
    let globalPause: Bool
    let retentionDays: String
    let summaryInterval: String
    let maxPromptChars: String
    let maxCapturesPerSession: String
    let normalCaptureInterval: String
    let degradedCaptureInterval: String
    let highUncertaintyCaptureInterval: String
    let storageProfile: StorageProfile
    let captureRetentionMode: CaptureRetentionMode
    let blacklistedBundleIds: String
    let metadataOnlyBundleIds: String
    let blacklistedWindowPatterns: String
    let microphoneCaptureEnabled: Bool
    let systemAudioCaptureEnabled: Bool
    let audioPythonCommand: String
    let audioModelName: String
    let audioRuntimeStatus: String
    let systemPrompt: String
    let userPromptSuffix: String
    let screenRecordingGranted: Bool
    let accessibilityGranted: Bool
    let microphoneGranted: Bool

    static let marketing = SettingsPreviewState(
        operatingMode: .hybrid,
        externalProviderName: "OpenRouter-compatible",
        externalBaseURL: "https://openrouter.ai/api/v1",
        externalAPIKey: "sk-or-demo****************",
        summaryProvider: .external,
        summaryExternalModel: "google/gemini-2.5-flash-preview",
        summaryLocalModel: "hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M",
        visionProvider: .ollama,
        visionModel: "qwen3.5:4b",
        visionExternalModel: "google/gemini-2.5-flash-preview",
        ocrProvider: .ollamaWithVisionFallback,
        ollamaModel: "glm-ocr",
        ollamaBaseURL: "http://localhost:11434",
        vaultPath: "~/Documents/Obsidian/Vault",
        dataDirectoryPath: "~/Library/Application Support/MyMacAgent",
        startPaused: false,
        globalPause: false,
        retentionDays: "30",
        summaryInterval: "60",
        maxPromptChars: "300000",
        maxCapturesPerSession: "500",
        normalCaptureInterval: "60",
        degradedCaptureInterval: "10",
        highUncertaintyCaptureInterval: "3",
        storageProfile: .balanced,
        captureRetentionMode: .thumbnails,
        blacklistedBundleIds: "com.apple.keychainaccess\ncom.1password.1password\ncom.bitwarden.desktop",
        metadataOnlyBundleIds: "com.apple.MobileSMS\ncom.apple.mail\nru.keepcoder.Telegram",
        blacklistedWindowPatterns: "password\nincognito\nseed phrase\nwallet",
        microphoneCaptureEnabled: false,
        systemAudioCaptureEnabled: false,
        audioPythonCommand: ".venv/bin/python",
        audioModelName: "mlx-community/whisper-large-v3-turbo",
        audioRuntimeStatus: "ready (demo)",
        systemPrompt: AppSettings.defaultSystemPrompt,
        userPromptSuffix: AppSettings.defaultUserPromptSuffix,
        screenRecordingGranted: true,
        accessibilityGranted: true,
        microphoneGranted: false
    )
}

struct SettingsView: View {
    @StateObject private var permissionsManager = PermissionsManager()
    private let previewState: SettingsPreviewState?

    @State private var selectedTab = 0
    @State private var saved = false
    @State private var showDeleteDataAlert = false

    @State private var operatingMode: AppOperatingMode = .localOnly
    @State private var externalProviderName = ""
    @State private var externalBaseURL = ""
    @State private var externalAPIKey = ""
    @State private var showExternalAPIKey = false
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

    init(initialTab: Int = 0, previewState: SettingsPreviewState? = nil) {
        _selectedTab = State(initialValue: initialTab)
        self.previewState = previewState
    }

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
        .padding(20)
        .frame(minWidth: 700, minHeight: 680)
        .onAppear {
            if let previewState {
                applyPreviewState(previewState)
            } else {
                loadSettings()
                permissionsManager.checkAll()
            }
        }
        .alert("Delete all local data?", isPresented: $showDeleteDataAlert) {
            Button("Delete", role: .destructive) { deleteAllData() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the local database, screenshots and audio cache from the app data folder.")
        }
    }

    private var generalTab: some View {
        settingsScroll {
            settingsCard("Product Mode", subtitle: modeDescription) {
                Picker("Operating mode", selection: $operatingMode) {
                    ForEach(AppOperatingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            settingsCard("Data & Storage") {
                settingRow("Data folder", help: "SQLite database, captures, and transcripts live here.") {
                    HStack(spacing: 8) {
                        TextField("Data folder", text: $dataDirectoryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse") { browseFolder(binding: $dataDirectoryPath) }
                        Button("Open") { openFolder(path: dataDirectoryPath) }
                    }
                }

                settingRow("Obsidian vault", help: "Daily notes can be exported here.") {
                    HStack(spacing: 8) {
                        TextField("Obsidian vault", text: $vaultPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse") { browseFolder(binding: $vaultPath) }
                    }
                }
            }

            settingsCard("Runtime") {
                toggleRow("Start paused", help: "Launch in paused mode and wait for explicit resume.", isOn: $startPaused)
                toggleRow("Pause capture now", help: "Stops tracking immediately without quitting the app.", isOn: $globalPause)

                settingRow("Retention", help: "Delete old local data after N days.") {
                    inlineNumberField("30", text: $retentionDays, suffix: "days")
                }

                settingRow("Auto-summary", help: "How often Memograph should build a day summary.") {
                    inlineNumberField("60", text: $summaryInterval, suffix: "minutes")
                }
            }

            settingsCard("Diagnostics") {
                diagnosticsRow("Current mode", value: operatingMode.label)
                diagnosticsRow("Data folder", value: dataDirectoryPath)
                diagnosticsRow("Summary provider", value: summaryProvider.label)
                diagnosticsRow("Vision provider", value: visionProvider.label)
            }

            settingsCard("Danger Zone") {
                HStack(spacing: 8) {
                    Button("Delete all local data") {
                        showDeleteDataAlert = true
                    }
                    .foregroundStyle(.red)
                }
            }

            saveButton
        }
    }

    private var providersTab: some View {
        settingsScroll {
            settingsCard("External Provider", subtitle: "Used only when you choose external summary or vision providers.") {
                settingRow("Provider label") {
                    TextField("OpenRouter-compatible", text: $externalProviderName)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("Base URL") {
                    TextField("https://openrouter.ai/api/v1", text: $externalBaseURL)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("API key", help: "Used only when you enable external summary or vision providers.") {
                    HStack(spacing: 8) {
                        Group {
                            if showExternalAPIKey {
                                TextField("API key", text: $externalAPIKey)
                            } else {
                                SecureField("API key", text: $externalAPIKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)

                        Button(showExternalAPIKey ? "Hide" : "Reveal") {
                            showExternalAPIKey.toggle()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            settingsCard("Summaries") {
                settingRow("Provider") {
                    Picker("Summary provider", selection: $summaryProvider) {
                        ForEach(SummaryProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                settingRow("External model") {
                    TextField("google/gemini-2.5-flash-preview", text: $summaryExternalModel)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("Local model") {
                    TextField("hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M", text: $summaryLocalModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            settingsCard("Vision") {
                settingRow("Provider") {
                    Picker("Vision provider", selection: $visionProvider) {
                        ForEach(VisionProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                settingRow("Local model") {
                    TextField("qwen3.5:4b", text: $visionModel)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("External model") {
                    TextField("google/gemini-2.5-flash-preview", text: $visionExternalModel)
                        .textFieldStyle(.roundedBorder)
                }
            }

            settingsCard("OCR") {
                settingRow("Provider") {
                    Picker("OCR provider", selection: $ocrProvider) {
                        ForEach(OCRProviderKind.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                settingRow("Ollama OCR model") {
                    TextField("glm-ocr", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("Ollama base URL") {
                    TextField("http://localhost:11434", text: $ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
            }

            saveButton
        }
    }

    private var captureTab: some View {
        settingsScroll {
            settingsCard("Capture Cadence", subtitle: "Memograph captures more aggressively when readability drops.") {
                settingRow("Normal", help: "Default cadence when OCR and AX extraction are healthy.") {
                    inlineNumberField("60", text: $normalCaptureInterval, suffix: "sec")
                }

                settingRow("Limited mode", help: "Used when context quality drops but recovery is still possible.") {
                    inlineNumberField("10", text: $degradedCaptureInterval, suffix: "sec")
                }

                settingRow("High uncertainty", help: "Burst cadence for difficult screens that need more context.") {
                    inlineNumberField("3", text: $highUncertaintyCaptureInterval, suffix: "sec")
                }
            }

            settingsCard("Budgets") {
                settingRow("Max prompt chars", help: "Hard cap for summary context passed into the LLM.") {
                    inlineNumberField("300000", text: $maxPromptChars)
                }

                settingRow("Max captures per session", help: "Safety cap for long work sessions.") {
                    inlineNumberField("500", text: $maxCapturesPerSession)
                }
            }

            settingsCard("Storage") {
                settingRow("Storage profile", help: "Overall disk strategy for capture artifacts.") {
                    Picker("Storage profile", selection: $storageProfile) {
                        ForEach(StorageProfile.allCases) { profile in
                            Text(profile.rawValue.capitalized).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                settingRow("Capture retention", help: "How much image data to keep after extraction.") {
                    Picker("Capture retention", selection: $captureRetentionMode) {
                        ForEach(CaptureRetentionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            saveButton
        }
    }

    private var privacyTab: some View {
        settingsScroll {
            settingsCard("Permissions", subtitle: "Memograph works in limited mode when optional permissions are missing.") {
                PermissionsView(manager: permissionsManager, autoRefresh: previewState == nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            settingsCard("Blacklisted Bundle IDs", subtitle: "These apps are never captured.") {
                listEditor(text: $blacklistedBundleIds)
            }

            settingsCard("Metadata-only Apps", subtitle: "Capture app activity without storing screenshot content.") {
                listEditor(text: $metadataOnlyBundleIds)
            }

            settingsCard("Blocked Window Title Patterns", subtitle: "Window titles matching these patterns are skipped.") {
                listEditor(text: $blacklistedWindowPatterns)
            }

            saveButton
        }
    }

    private var audioTab: some View {
        settingsScroll {
            settingsCard("Experimental Capture", subtitle: "Audio stays off by default. Turn it on only if you explicitly want transcripts.") {
                toggleRow("Microphone transcription", help: "Starts recording only when another app is actively using the microphone.", isOn: $microphoneCaptureEnabled)
                toggleRow("System audio transcription", help: "Captures speaker output with ScreenCaptureKit when supported.", isOn: $systemAudioCaptureEnabled)
            }

            settingsCard("Runtime") {
                settingRow("Python command", help: "Absolute path or command name for the Whisper runtime.") {
                    TextField("python3", text: $audioPythonCommand)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("Whisper model") {
                    TextField("mlx-community/whisper-large-v3-turbo", text: $audioModelName)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("Runtime status") {
                    Text(audioRuntimeStatus)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            settingsCard("How It Works") {
                Text("Audio support is still experimental. It depends on an external Python runtime plus Whisper dependencies, and it is intentionally opt-in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            saveButton
        }
    }

    private var promptsTab: some View {
        settingsScroll {
            settingsCard("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.2))
                    )
            }

            settingsCard("Summary Template") {
                TextEditor(text: $userPromptSuffix)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 260)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.gray.opacity(0.2))
                    )
            }

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
        showExternalAPIKey = false
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

    private func applyPreviewState(_ preview: SettingsPreviewState) {
        operatingMode = preview.operatingMode
        externalProviderName = preview.externalProviderName
        externalBaseURL = preview.externalBaseURL
        externalAPIKey = preview.externalAPIKey
        showExternalAPIKey = false
        summaryProvider = preview.summaryProvider
        summaryExternalModel = preview.summaryExternalModel
        summaryLocalModel = preview.summaryLocalModel
        visionProvider = preview.visionProvider
        visionModel = preview.visionModel
        visionExternalModel = preview.visionExternalModel
        ocrProvider = preview.ocrProvider
        ollamaModel = preview.ollamaModel
        ollamaBaseURL = preview.ollamaBaseURL
        vaultPath = preview.vaultPath
        dataDirectoryPath = preview.dataDirectoryPath
        startPaused = preview.startPaused
        globalPause = preview.globalPause
        retentionDays = preview.retentionDays
        summaryInterval = preview.summaryInterval
        maxPromptChars = preview.maxPromptChars
        maxCapturesPerSession = preview.maxCapturesPerSession
        normalCaptureInterval = preview.normalCaptureInterval
        degradedCaptureInterval = preview.degradedCaptureInterval
        highUncertaintyCaptureInterval = preview.highUncertaintyCaptureInterval
        storageProfile = preview.storageProfile
        captureRetentionMode = preview.captureRetentionMode
        blacklistedBundleIds = preview.blacklistedBundleIds
        metadataOnlyBundleIds = preview.metadataOnlyBundleIds
        blacklistedWindowPatterns = preview.blacklistedWindowPatterns
        microphoneCaptureEnabled = preview.microphoneCaptureEnabled
        systemAudioCaptureEnabled = preview.systemAudioCaptureEnabled
        audioPythonCommand = preview.audioPythonCommand
        audioModelName = preview.audioModelName
        audioRuntimeStatus = preview.audioRuntimeStatus
        systemPrompt = preview.systemPrompt
        userPromptSuffix = preview.userPromptSuffix
        permissionsManager.setPreviewStatus(
            screenRecordingGranted: preview.screenRecordingGranted,
            accessibilityGranted: preview.accessibilityGranted,
            microphoneGranted: preview.microphoneGranted
        )
    }

    private func saveSettings() {
        var settings = AppSettings()
        settings.operatingMode = operatingMode
        settings.externalProviderName = externalProviderName
        settings.externalBaseURL = externalBaseURL
        let trimmedAPIKey = externalAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.externalAPIKey = trimmedAPIKey
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
        settings.experimentalAudioOptInConfirmed =
            microphoneCaptureEnabled || systemAudioCaptureEnabled
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

    private func settingsScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private func settingsCard<Content: View>(
        _ title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func settingRow<Content: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                if let help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 220, alignment: .leading)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleRow(_ title: String, help: String, isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(title, isOn: isOn)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }

    private func inlineNumberField(_ placeholder: String, text: Binding<String>, suffix: String? = nil) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
            if let suffix {
                Text(suffix)
                    .foregroundStyle(.secondary)
            }
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
