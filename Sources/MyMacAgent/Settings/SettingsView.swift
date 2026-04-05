import AppKit
import SwiftUI

extension Notification.Name {
    static let settingsSwitchToTab = Notification.Name("settingsSwitchToTab")
}

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
    let audioTranscriptionProvider: AudioTranscriptionProvider
    let audioTranscriptionBaseURL: String
    let audioTranscriptionAPIKey: String
    let audioMicrophoneModel: String
    let audioSystemModel: String
    let audioPythonCommand: String
    let audioModelName: String
    let audioRuntimeStatus: String
    let advisoryBridgeMode: AdvisoryBridgeMode
    let advisoryAllowMCPEnrichment: Bool
    let advisoryEnrichmentPhase: AdvisoryEnrichmentPhase
    let advisoryCalendarEnrichmentEnabled: Bool
    let advisoryRemindersEnrichmentEnabled: Bool
    let advisoryWebResearchEnrichmentEnabled: Bool
    let advisoryWearableEnrichmentEnabled: Bool
    let advisoryEnrichmentMaxItemsPerSource: String
    let advisoryCalendarLookaheadHours: String
    let advisoryReminderHorizonDays: String
    let advisoryWebResearchLookbackDays: String
    let advisoryPreferredLanguage: String
    let advisoryWritingStyle: String
    let advisoryTwitterVoiceExamples: String
    let advisoryPreferredAngles: String
    let advisoryAvoidTopics: String
    let advisoryContentPersonaDescription: String
    let advisoryAllowProvocation: Bool
    let advisorySidecarAutoStart: Bool
    let advisorySidecarSocketPath: String
    let advisorySidecarTimeoutSeconds: String
    let advisorySidecarHealthCheckIntervalSeconds: String
    let advisorySidecarMaxConsecutiveFailures: String
    let advisorySidecarProviderOrder: String
    let advisorySidecarProviderProbeTimeoutSeconds: String
    let advisorySidecarRetryAttempts: String
    let advisorySidecarProviderCooldownSeconds: String
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
        audioTranscriptionProvider: .openAI,
        audioTranscriptionBaseURL: "https://api.openai.com/v1",
        audioTranscriptionAPIKey: "sk-proj-demo****************",
        audioMicrophoneModel: "gpt-4o-transcribe",
        audioSystemModel: "gpt-4o-mini-transcribe",
        audioPythonCommand: ".venv/bin/python",
        audioModelName: "mlx-community/whisper-large-v3-turbo",
        audioRuntimeStatus: "Готово (облако: mic gpt-4o-transcribe, system gpt-4o-mini-transcribe)",
        advisoryBridgeMode: .preferSidecar,
        advisoryAllowMCPEnrichment: true,
        advisoryEnrichmentPhase: .phase2ReadOnly,
        advisoryCalendarEnrichmentEnabled: true,
        advisoryRemindersEnrichmentEnabled: true,
        advisoryWebResearchEnrichmentEnabled: true,
        advisoryWearableEnrichmentEnabled: true,
        advisoryEnrichmentMaxItemsPerSource: "3",
        advisoryCalendarLookaheadHours: "18",
        advisoryReminderHorizonDays: "7",
        advisoryWebResearchLookbackDays: "3",
        advisoryPreferredLanguage: "ru",
        advisoryWritingStyle: "concise_reflective",
        advisoryTwitterVoiceExamples: "Short grounded post\nBuilder note with one sharp line",
        advisoryPreferredAngles: "observation\nquestion\nlesson_learned\nmini_framework",
        advisoryAvoidTopics: "hot takes for the sake of it",
        advisoryContentPersonaDescription: "Grounded builder voice. Specific, observant, compact, and evidence-led.",
        advisoryAllowProvocation: false,
        advisorySidecarAutoStart: true,
        advisorySidecarSocketPath: "~/Library/Application Support/MyMacAgent/advisory/memograph-advisor.sock",
        advisorySidecarTimeoutSeconds: "20",
        advisorySidecarHealthCheckIntervalSeconds: "30",
        advisorySidecarMaxConsecutiveFailures: "3",
        advisorySidecarProviderOrder: "claude\ngemini\ncodex",
        advisorySidecarProviderProbeTimeoutSeconds: "6",
        advisorySidecarRetryAttempts: "2",
        advisorySidecarProviderCooldownSeconds: "60",
        systemPrompt: AppSettings.defaultSystemPrompt,
        userPromptSuffix: AppSettings.defaultUserPromptSuffix,
        screenRecordingGranted: true,
        accessibilityGranted: true,
        microphoneGranted: false
    )
}

struct SettingsView: View {
    @StateObject private var permissionsManager = PermissionsManager()
    @ObservedObject private var audioHealthMonitor = AudioHealthMonitor.shared
    @ObservedObject private var advisoryHealthMonitor = AdvisoryHealthMonitor.shared
    private let previewState: SettingsPreviewState?

    @State private var selectedTab = 0
    @State private var saved = false
    @State private var showDeleteDataAlert = false
    @State private var advisoryAccountsSnapshot = AdvisoryProviderAccountsSnapshot.empty
    @State private var advisoryAccountsBusyKey = ""
    @State private var advisoryAccountGlobalFeedback = ""
    @State private var pendingTerminalProvider = ""
    @State private var pendingTerminalAccountName: String?
    @State private var isRefreshingAccounts = false
    @State private var advisoryAccountLabelDrafts: [String: String] = [:]
    @State private var advisoryAccountActionFeedback: [String: String] = [:]
    @State private var providerAuthVerifications: [String: (verified: Bool, verifiedAt: Date)] = [:]
    @State private var providerAuthCheckInFlight: Set<String> = []
    @State private var advisoryCLIProfilesPath = ""
    @State private var advisoryProviderProfiles: [String: [AdvisoryCLIAccountProfile]] = [:]
    @State private var pendingProfilesPathPersistWorkItem: DispatchWorkItem?

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
    @State private var audioTranscriptionProvider: AudioTranscriptionProvider = .openAI
    @State private var audioTranscriptionBaseURL = ""
    @State private var audioTranscriptionAPIKey = ""
    @State private var showAudioTranscriptionAPIKey = false
    @State private var audioMicrophoneModel = ""
    @State private var audioSystemModel = ""
    @State private var audioPythonCommand = ""
    @State private var audioModelName = ""
    @State private var audioRuntimeStatus = ""
    @State private var advisoryBridgeMode: AdvisoryBridgeMode = .preferSidecar
    @State private var advisoryAllowMCPEnrichment = false
    @State private var advisoryEnrichmentPhase: AdvisoryEnrichmentPhase = .phase1Memograph
    @State private var advisoryCalendarEnrichmentEnabled = true
    @State private var advisoryRemindersEnrichmentEnabled = true
    @State private var advisoryWebResearchEnrichmentEnabled = true
    @State private var advisoryWearableEnrichmentEnabled = true
    @State private var advisoryEnrichmentMaxItemsPerSource = ""
    @State private var advisoryCalendarLookaheadHours = ""
    @State private var advisoryReminderHorizonDays = ""
    @State private var advisoryWebResearchLookbackDays = ""
    @State private var advisoryPreferredLanguage = ""
    @State private var advisoryWritingStyle = ""
    @State private var advisoryTwitterVoiceExamples = ""
    @State private var advisoryPreferredAngles = ""
    @State private var advisoryAvoidTopics = ""
    @State private var advisoryContentPersonaDescription = ""
    @State private var advisoryAllowProvocation = false
    @State private var advisorySidecarAutoStart = true
    @State private var advisorySidecarSocketPath = ""
    @State private var advisorySidecarTimeoutSeconds = ""
    @State private var advisorySidecarHealthCheckIntervalSeconds = ""
    @State private var advisorySidecarMaxConsecutiveFailures = ""
    @State private var advisorySidecarProviderOrder = ""
    @State private var advisorySidecarProviderProbeTimeoutSeconds = ""
    @State private var advisorySidecarRetryAttempts = ""
    @State private var advisorySidecarProviderCooldownSeconds = ""

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

            accountsTab
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(6)

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
            advisoryHealthMonitor.startIfNeeded()
            advisoryHealthMonitor.refresh()
            if let previewState {
                applyPreviewState(previewState)
            } else {
                loadSettings()
                permissionsManager.checkAll()
            }
            refreshAdvisoryProviderProfiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsSwitchToTab)) { notification in
            if let tab = notification.userInfo?["tab"] as? Int {
                selectedTab = tab
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
            settingsCard("External Provider", subtitle: "Used only when you explicitly choose external summary or vision providers. Screenshots stay local; only processed text prompts leave the Mac.") {
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

            settingsCard("Advisory Sidecar", subtitle: "Runs a local sidecar that may call logged-in Claude, Gemini, or Codex CLIs. Runtime health is tracked separately from account inventory stored on disk.") {
                settingRow("Bridge mode") {
                    Picker("Advisory bridge mode", selection: $advisoryBridgeMode) {
                        ForEach(AdvisoryBridgeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                toggleRow("Read-only external enrichment", help: "Allows advisory to read staged calendar, reminders, and browser-derived research fragments when available. Raw screenshots and SQLite rows are not sent directly.", isOn: $advisoryAllowMCPEnrichment)

                settingRow("Enrichment phase", help: "Phase 1 keeps advisory on Memograph-derived notes only. Phase 2 and 3 prepare staged external enrichers.") {
                    Picker("Advisory enrichment phase", selection: $advisoryEnrichmentPhase) {
                        ForEach(AdvisoryEnrichmentPhase.allCases) { phase in
                            Text(enrichmentPhaseLabel(phase)).tag(phase)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("External enrichment sources")
                        .font(.subheadline.weight(.semibold))
                    ForEach(AdvisoryEnrichmentSource.allCases.filter { $0 != .notes }) { source in
                        toggleRow(
                            source.label,
                            help: "\(source.rolloutDescription) Starts in \(source.minimumPhase.label).",
                            isOn: enrichmentSourceBinding(for: source)
                        )
                    }
                }

                settingRow("Items per source", help: "Upper bound for embedded enrichment fragments from each source.") {
                    inlineNumberField("3", text: $advisoryEnrichmentMaxItemsPerSource)
                }

                settingRow("Calendar lookahead", help: "How far ahead advisory may look in local calendar context.") {
                    inlineNumberField("18", text: $advisoryCalendarLookaheadHours, suffix: "hours")
                }

                settingRow("Reminder horizon", help: "How far ahead advisory may look for active reminders.") {
                    inlineNumberField("7", text: $advisoryReminderHorizonDays, suffix: "days")
                }

                settingRow("Web lookback", help: "How many days of browser context can seed staged web enrichment.") {
                    inlineNumberField("3", text: $advisoryWebResearchLookbackDays, suffix: "days")
                }

                toggleRow("Auto-start sidecar", help: "Memograph may try to launch memograph-advisor when the socket is missing.", isOn: $advisorySidecarAutoStart)

                settingRow("Socket path") {
                    TextField("/path/to/memograph-advisor.sock", text: $advisorySidecarSocketPath)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("Request timeout") {
                    inlineNumberField("20", text: $advisorySidecarTimeoutSeconds, suffix: "sec")
                }

                settingRow("Health check") {
                    inlineNumberField("30", text: $advisorySidecarHealthCheckIntervalSeconds, suffix: "sec")
                }

                settingRow("Failure budget") {
                    inlineNumberField("3", text: $advisorySidecarMaxConsecutiveFailures)
                }

                settingRow("Provider probe timeout") {
                    inlineNumberField("6", text: $advisorySidecarProviderProbeTimeoutSeconds, suffix: "sec")
                }

                settingRow("Recipe retries", help: "How many primary sidecar attempts Memograph will allow before falling back or surfacing failure.") {
                    inlineNumberField("2", text: $advisorySidecarRetryAttempts)
                }

                settingRow("Provider cooldown", help: "How long a provider stays out of rotation after transient sidecar/provider failures.") {
                    inlineNumberField("60", text: $advisorySidecarProviderCooldownSeconds, suffix: "sec")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Provider order")
                        .font(.subheadline.weight(.semibold))
                    listEditor(text: $advisorySidecarProviderOrder)
                        .frame(minHeight: 90)
                    Text("One provider per line. This controls sidecar probe/routing preference for Claude, Gemini, Codex.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                settingRow("Runtime status") {
                    advisoryControlPlaneStatusView(runtimeSnapshot: advisoryHealthMonitor.snapshot.runtimeSnapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.providerStatuses.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Provider diagnostics")
                            .font(.subheadline.weight(.semibold))
                        AdvisoryProviderDiagnosticsView(
                            providerStatuses: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.providerStatuses,
                            activeProviderName: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.activeProviderName,
                            checkedAt: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.checkedAt
                        )
                    }
                }

                HStack(spacing: 8) {
                    Button("Refresh status") {
                        advisoryHealthMonitor.refresh()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Restart sidecar") {
                        advisoryHealthMonitor.restartSidecar()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Stop sidecar") {
                        advisoryHealthMonitor.stopSidecar()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            settingsCard("Writing Persona", subtitle: "Tweet and note seeds stay grounded in your own style instead of sounding like generic AI copy.") {
                settingRow("Language", help: "Default language for advisory artifacts. Canonical product and model names stay in English.") {
                    TextField("ru", text: $advisoryPreferredLanguage)
                        .textFieldStyle(.roundedBorder)
                }

                settingRow("Writing style", help: "High-level bias for writing seeds and social nudges.") {
                    TextField("concise_reflective", text: $advisoryWritingStyle)
                        .textFieldStyle(.roundedBorder)
                }

                toggleRow("Allow provocation", help: "Keeps sharper takes available for writing seeds when explicitly wanted.", isOn: $advisoryAllowProvocation)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Persona description")
                        .font(.subheadline.weight(.semibold))
                    TextEditor(text: $advisoryContentPersonaDescription)
                        .frame(minHeight: 90)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.2))
                        )
                    Text("Опиши voice коротко: grounded, compact, non-performative, evidence-led.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Preferred angles")
                        .font(.subheadline.weight(.semibold))
                    listEditor(text: $advisoryPreferredAngles)
                    Text("One per line: observation, contrarian_take, question, mini_framework, lesson_learned, provocation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Voice examples")
                        .font(.subheadline.weight(.semibold))
                    listEditor(text: $advisoryTwitterVoiceExamples)
                    Text("Short examples of writing you want seeds to echo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Avoid topics")
                        .font(.subheadline.weight(.semibold))
                    listEditor(text: $advisoryAvoidTopics)
                    Text("Topics or postures advisory should actively avoid in writing suggestions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            saveButton
        }
    }

    private var accountsTab: some View {
        settingsScroll {
            if !pendingTerminalProvider.isEmpty {
                pendingTerminalBanner
            }

            settingsCard(
                "Accounts & Sessions",
                subtitle: "Control plane for advisory CLI providers. Profiles are stored in the same isolated account tree used by multi-agent."
            ) {
                let runtimeSnapshot = advisoryHealthMonitor.snapshot.runtimeSnapshot

                settingRow("Profiles dir", help: "Shared CLI profile store reused from multi-agent.") {
                    HStack(spacing: 8) {
                        TextField("~/.cli-profiles", text: $advisoryCLIProfilesPath)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit {
                                persistProfilesPath(restartSidecar: true)
                            }
                            .onChange(of: advisoryCLIProfilesPath) { _, _ in
                                debouncedPersistProfilesPath()
                            }
                        Button("Open") {
                            openFolder(path: advisoryCLIProfilesPath)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                advisoryControlPlaneStatusView(runtimeSnapshot: advisoryHealthMonitor.snapshot.runtimeSnapshot)

                HStack(spacing: 8) {
                    Button {
                        runFullAuthCheck()
                    } label: {
                        HStack(spacing: 4) {
                            if isRefreshingAccounts {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.7)
                            }
                            Text("Run full auth check")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshingAccounts)

                    Button("Restart sidecar") {
                        advisoryHealthMonitor.restartSidecar()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Stop sidecar") {
                        advisoryHealthMonitor.stopSidecar()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Reload profiles") {
                        refreshAdvisoryProviderProfiles()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Provider cards: show from sidecar diagnostics when available,
                // otherwise show static cards from filesystem profiles so accounts
                // are ALWAYS visible regardless of sidecar state.
                if !runtimeSnapshot.bridgeHealth.providerStatuses.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(runtimeSnapshot.bridgeHealth.providerStatuses.sorted { $0.priority < $1.priority }) { diagnostic in
                            providerSessionCard(
                                diagnostic,
                                activeProviderName: runtimeSnapshot.bridgeHealth.activeProviderName,
                                checkedAt: diagnostic.lastCheckedAt ?? runtimeSnapshot.bridgeHealth.checkedAt
                            )
                        }
                    }
                } else {
                    // Sidecar offline — show filesystem-based account cards
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(["claude", "gemini", "codex"], id: \.self) { provider in
                            let profiles = advisoryProviderProfiles[provider] ?? []
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(provider.capitalized)
                                        .font(.headline)
                                    Spacer()
                                    Text(profiles.isEmpty ? "no accounts" : "\(profiles.count) account(s)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if profiles.isEmpty {
                                    HStack(spacing: 8) {
                                        Button("Import current session") {
                                            handleImportProviderSession(provider)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        Button("Add account") {
                                            handleAddProviderAccount(provider)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                } else {
                                    ForEach(profiles) { profile in
                                        providerAccountRow(profile)
                                    }
                                    HStack(spacing: 8) {
                                        Button("Import current session") {
                                            handleImportProviderSession(provider)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        Button("Add account") {
                                            handleAddProviderAccount(provider)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    }
                                }
                                if let feedback = advisoryAccountActionFeedback[provider], !feedback.isEmpty {
                                    HStack(spacing: 6) {
                                        Image(systemName: "info.circle")
                                            .foregroundStyle(.blue)
                                        Text(feedback)
                                            .font(.caption)
                                        Spacer()
                                        Button { advisoryAccountActionFeedback[provider] = nil } label: {
                                            Image(systemName: "xmark")
                                                .font(.caption2)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(8)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.06)))
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                    }
                    Text("Sidecar is offline. Accounts above are from the filesystem. Start sidecar for full diagnostics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var pendingTerminalBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Action opened in Terminal")
                    .font(.subheadline.weight(.semibold))
                Text("Complete the flow in Terminal for \(pendingTerminalTargetDescription()). Status will refresh automatically when the session is detected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                let provider = pendingTerminalProvider
                let accountName = pendingTerminalAccountName
                isRefreshingAccounts = true
                providerAuthCheckInFlight.insert(provider)
                advisoryHealthMonitor.recoverAfterRelogin(provider: provider, accountName: accountName) { verified, verifiedAt in
                    providerAuthVerifications[provider] = (verified: verified, verifiedAt: verifiedAt)
                    providerAuthCheckInFlight.remove(provider)
                    isRefreshingAccounts = false
                    refreshAdvisoryProviderProfiles()
                    let target = authCheckTargetLabel(provider: provider, accountName: accountName)
                    let outcome = verified ? "Auth verified for \(target)." : "Session still expired for \(target). Try re-login again."
                    advisoryAccountActionFeedback[provider] = outcome
                    clearPendingTerminalRecovery()
                }
            } label: {
                HStack(spacing: 4) {
                    if isRefreshingAccounts {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                    }
                    Text("Run auth check")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(isRefreshingAccounts)

            Button("Dismiss") {
                clearPendingTerminalRecovery()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.blue.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.blue.opacity(0.18), lineWidth: 1)
        )
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

            settingsCard("External Execution", subtitle: "Networked providers stay opt-in.") {
                Text("Summary and vision vendors run only after you explicitly choose an external provider. Advisory sidecar execution stays local, but logged-in provider CLIs may receive thread summaries, continuity notes, and staged enrichment text. Raw screenshots and direct SQLite dumps are not sent to advisory providers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            settingsCard("Audio Capture", subtitle: "Микрофон и системный звук можно транскрибировать либо в облаке, либо локально.") {
                toggleRow("Microphone transcription", help: "Starts recording only when another app is actively using the microphone.", isOn: $microphoneCaptureEnabled)
                toggleRow("System audio transcription", help: "Starts only while another app is actively sending audio to the default output device.", isOn: $systemAudioCaptureEnabled)
            }

            settingsCard("Transcription Provider", subtitle: "Для тебя основной путь можно держать облачным, а локальный Whisper оставить как privacy-first опцию.") {
                settingRow("Provider") {
                    Picker("Audio transcription provider", selection: $audioTranscriptionProvider) {
                        ForEach(AudioTranscriptionProvider.allCases) { provider in
                            Text(provider.label).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                if audioTranscriptionProvider == .openAI {
                    settingRow("Base URL", help: "По умолчанию это OpenAI audio transcription endpoint.") {
                        TextField("https://api.openai.com/v1", text: $audioTranscriptionBaseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingRow("API key", help: "Отдельный ключ для аудио. Если Base URL совпадает с внешним провайдером, можно переиспользовать внешний ключ.") {
                        HStack(spacing: 8) {
                            Group {
                                if showAudioTranscriptionAPIKey {
                                    TextField("Audio API key", text: $audioTranscriptionAPIKey)
                                } else {
                                    SecureField("Audio API key", text: $audioTranscriptionAPIKey)
                                }
                            }
                            .textFieldStyle(.roundedBorder)

                            Button(showAudioTranscriptionAPIKey ? "Hide" : "Reveal") {
                                showAudioTranscriptionAPIKey.toggle()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    settingRow("Microphone model", help: "Лучшее качество для твоей речи.") {
                        TextField("gpt-4o-transcribe", text: $audioMicrophoneModel)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingRow("System audio model", help: "Более дешёвый путь для видео и всего, что играет из колонок.") {
                        TextField("gpt-4o-mini-transcribe", text: $audioSystemModel)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    settingRow("Python command", help: "Absolute path or command name for the Whisper runtime.") {
                        TextField("python3", text: $audioPythonCommand)
                            .textFieldStyle(.roundedBorder)
                    }

                    settingRow("Whisper model") {
                        TextField("mlx-community/whisper-large-v3-turbo", text: $audioModelName)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                settingRow("Runtime status") {
                    Text(audioRuntimeStatus)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            settingsCard("Runtime Health", subtitle: "Очередь, задержки и throttling помогают быстро понять, почему аудио сейчас отстаёт.") {
                ForEach(audioHealthMonitor.snapshot.statusLines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            settingsCard("How It Works") {
                Text(audioTranscriptionProvider == .openAI
                     ? "Микрофон уходит в более качественную модель, а системный звук можно отправлять в более дешёвую. Это снимает нагрузку с твоего Mac, но требует сетевого API-ключа."
                     : "Локальный Whisper остаётся доступным как privacy-first режим. Он полезен для пользователей, которые не хотят отправлять аудио наружу, но сильнее грузит машину.")
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
        systemAudioCaptureEnabled = settings.resolvedSystemAudioCaptureEnabled
        audioTranscriptionProvider = settings.audioTranscriptionProvider
        audioTranscriptionBaseURL = settings.audioTranscriptionBaseURL
        audioTranscriptionAPIKey = settings.audioTranscriptionAPIKey
        showAudioTranscriptionAPIKey = false
        audioMicrophoneModel = settings.audioMicrophoneModel
        audioSystemModel = settings.audioSystemModel
        audioPythonCommand = settings.audioPythonCommand
        audioModelName = settings.audioModelName
        audioRuntimeStatus = AudioRuntimeResolver.resolve(settings: settings).description
        advisoryBridgeMode = settings.advisoryBridgeMode
        advisoryAllowMCPEnrichment = settings.advisoryAllowMCPEnrichment
        advisoryEnrichmentPhase = settings.advisoryEnrichmentPhase
        advisoryCalendarEnrichmentEnabled = settings.advisoryCalendarEnrichmentEnabled
        advisoryRemindersEnrichmentEnabled = settings.advisoryRemindersEnrichmentEnabled
        advisoryWebResearchEnrichmentEnabled = settings.advisoryWebResearchEnrichmentEnabled
        advisoryWearableEnrichmentEnabled = settings.advisoryWearableEnrichmentEnabled
        advisoryEnrichmentMaxItemsPerSource = String(settings.advisoryEnrichmentMaxItemsPerSource)
        advisoryCalendarLookaheadHours = String(settings.advisoryCalendarLookaheadHours)
        advisoryReminderHorizonDays = String(settings.advisoryReminderHorizonDays)
        advisoryWebResearchLookbackDays = String(settings.advisoryWebResearchLookbackDays)
        advisoryPreferredLanguage = settings.advisoryPreferredLanguage
        advisoryWritingStyle = settings.advisoryWritingStyle
        advisoryTwitterVoiceExamples = settings.advisoryTwitterVoiceExamples.joined(separator: "\n")
        advisoryPreferredAngles = settings.advisoryPreferredAngles.joined(separator: "\n")
        advisoryAvoidTopics = settings.advisoryAvoidTopics.joined(separator: "\n")
        advisoryContentPersonaDescription = settings.advisoryContentPersonaDescription
        advisoryAllowProvocation = settings.advisoryAllowProvocation
        advisorySidecarAutoStart = settings.advisorySidecarAutoStart
        advisorySidecarSocketPath = settings.advisorySidecarSocketPath
        advisorySidecarTimeoutSeconds = String(settings.advisorySidecarTimeoutSeconds)
        advisorySidecarHealthCheckIntervalSeconds = String(settings.advisorySidecarHealthCheckIntervalSeconds)
        advisorySidecarMaxConsecutiveFailures = String(settings.advisorySidecarMaxConsecutiveFailures)
        advisorySidecarProviderOrder = settings.advisorySidecarProviderOrder.joined(separator: "\n")
        advisorySidecarProviderProbeTimeoutSeconds = String(settings.advisorySidecarProviderProbeTimeoutSeconds)
        advisorySidecarRetryAttempts = String(settings.advisorySidecarRetryAttempts)
        advisorySidecarProviderCooldownSeconds = String(settings.advisorySidecarProviderCooldownSeconds)
        advisoryCLIProfilesPath = settings.advisoryCLIProfilesPath

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
        systemAudioCaptureEnabled = AppSettings.persistentSystemAudioCaptureAvailable && preview.systemAudioCaptureEnabled
        audioTranscriptionProvider = preview.audioTranscriptionProvider
        audioTranscriptionBaseURL = preview.audioTranscriptionBaseURL
        audioTranscriptionAPIKey = preview.audioTranscriptionAPIKey
        showAudioTranscriptionAPIKey = false
        audioMicrophoneModel = preview.audioMicrophoneModel
        audioSystemModel = preview.audioSystemModel
        audioPythonCommand = preview.audioPythonCommand
        audioModelName = preview.audioModelName
        audioRuntimeStatus = preview.audioRuntimeStatus
        advisoryBridgeMode = preview.advisoryBridgeMode
        advisoryAllowMCPEnrichment = preview.advisoryAllowMCPEnrichment
        advisoryEnrichmentPhase = preview.advisoryEnrichmentPhase
        advisoryCalendarEnrichmentEnabled = preview.advisoryCalendarEnrichmentEnabled
        advisoryRemindersEnrichmentEnabled = preview.advisoryRemindersEnrichmentEnabled
        advisoryWebResearchEnrichmentEnabled = preview.advisoryWebResearchEnrichmentEnabled
        advisoryWearableEnrichmentEnabled = preview.advisoryWearableEnrichmentEnabled
        advisoryEnrichmentMaxItemsPerSource = preview.advisoryEnrichmentMaxItemsPerSource
        advisoryCalendarLookaheadHours = preview.advisoryCalendarLookaheadHours
        advisoryReminderHorizonDays = preview.advisoryReminderHorizonDays
        advisoryWebResearchLookbackDays = preview.advisoryWebResearchLookbackDays
        advisoryPreferredLanguage = preview.advisoryPreferredLanguage
        advisoryWritingStyle = preview.advisoryWritingStyle
        advisoryTwitterVoiceExamples = preview.advisoryTwitterVoiceExamples
        advisoryPreferredAngles = preview.advisoryPreferredAngles
        advisoryAvoidTopics = preview.advisoryAvoidTopics
        advisoryContentPersonaDescription = preview.advisoryContentPersonaDescription
        advisoryAllowProvocation = preview.advisoryAllowProvocation
        advisorySidecarAutoStart = preview.advisorySidecarAutoStart
        advisorySidecarSocketPath = preview.advisorySidecarSocketPath
        advisorySidecarTimeoutSeconds = preview.advisorySidecarTimeoutSeconds
        advisorySidecarHealthCheckIntervalSeconds = preview.advisorySidecarHealthCheckIntervalSeconds
        advisorySidecarMaxConsecutiveFailures = preview.advisorySidecarMaxConsecutiveFailures
        advisorySidecarProviderOrder = preview.advisorySidecarProviderOrder
        advisorySidecarProviderProbeTimeoutSeconds = preview.advisorySidecarProviderProbeTimeoutSeconds
        advisorySidecarRetryAttempts = preview.advisorySidecarRetryAttempts
        advisorySidecarProviderCooldownSeconds = preview.advisorySidecarProviderCooldownSeconds
        advisoryCLIProfilesPath = AdvisoryCLIProfilesStore.defaultProfilesPath
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
        settings.systemAudioCaptureEnabled = AppSettings.persistentSystemAudioCaptureAvailable && systemAudioCaptureEnabled
        settings.experimentalAudioOptInConfirmed =
            microphoneCaptureEnabled || (AppSettings.persistentSystemAudioCaptureAvailable && systemAudioCaptureEnabled)
        settings.audioTranscriptionProvider = audioTranscriptionProvider
        settings.audioTranscriptionBaseURL = audioTranscriptionBaseURL
        settings.audioTranscriptionAPIKey = audioTranscriptionAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.audioMicrophoneModel = audioMicrophoneModel
        settings.audioSystemModel = audioSystemModel
        settings.audioPythonCommand = audioPythonCommand
        settings.audioModelName = audioModelName
        settings.advisoryBridgeMode = advisoryBridgeMode
        settings.advisoryAllowMCPEnrichment = advisoryAllowMCPEnrichment
        settings.advisoryEnrichmentPhase = advisoryEnrichmentPhase
        settings.advisoryCalendarEnrichmentEnabled = advisoryCalendarEnrichmentEnabled
        settings.advisoryRemindersEnrichmentEnabled = advisoryRemindersEnrichmentEnabled
        settings.advisoryWebResearchEnrichmentEnabled = advisoryWebResearchEnrichmentEnabled
        settings.advisoryWearableEnrichmentEnabled = advisoryWearableEnrichmentEnabled
        settings.advisoryEnrichmentMaxItemsPerSource = Int(advisoryEnrichmentMaxItemsPerSource) ?? 3
        settings.advisoryCalendarLookaheadHours = Int(advisoryCalendarLookaheadHours) ?? 18
        settings.advisoryReminderHorizonDays = Int(advisoryReminderHorizonDays) ?? 7
        settings.advisoryWebResearchLookbackDays = Int(advisoryWebResearchLookbackDays) ?? 3
        settings.advisoryPreferredLanguage = advisoryPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "ru"
            : advisoryPreferredLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.advisoryWritingStyle = advisoryWritingStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "concise_reflective"
            : advisoryWritingStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.advisoryTwitterVoiceExamples = splitLines(advisoryTwitterVoiceExamples)
        settings.advisoryPreferredAngles = splitLines(advisoryPreferredAngles)
        settings.advisoryAvoidTopics = splitLines(advisoryAvoidTopics)
        settings.advisoryContentPersonaDescription = advisoryContentPersonaDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Grounded builder voice. Specific, observant, compact, and evidence-led."
            : advisoryContentPersonaDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.advisoryAllowProvocation = advisoryAllowProvocation
        settings.advisorySidecarAutoStart = advisorySidecarAutoStart
        settings.advisorySidecarSocketPath = advisorySidecarSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.advisorySidecarTimeoutSeconds = Int(advisorySidecarTimeoutSeconds) ?? 20
        settings.advisorySidecarHealthCheckIntervalSeconds = Int(advisorySidecarHealthCheckIntervalSeconds) ?? 30
        settings.advisorySidecarMaxConsecutiveFailures = Int(advisorySidecarMaxConsecutiveFailures) ?? 3
        settings.advisorySidecarProviderOrder = splitLines(advisorySidecarProviderOrder)
        settings.advisorySidecarProviderProbeTimeoutSeconds = Int(advisorySidecarProviderProbeTimeoutSeconds) ?? 6
        settings.advisorySidecarRetryAttempts = Int(advisorySidecarRetryAttempts) ?? 2
        settings.advisorySidecarProviderCooldownSeconds = Int(advisorySidecarProviderCooldownSeconds) ?? 60
        settings.advisoryCLIProfilesPath = advisoryCLIProfilesPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AdvisoryCLIProfilesStore.defaultProfilesPath
            : advisoryCLIProfilesPath.trimmingCharacters(in: .whitespacesAndNewlines)

        settings.systemPrompt = systemPrompt
        settings.userPromptSuffix = userPromptSuffix

        audioRuntimeStatus = AudioRuntimeResolver.resolve(settings: settings).description
        advisoryHealthMonitor.refresh()
        refreshAdvisoryProviderProfiles()
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)

        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saved = false
        }
    }

    private func enrichmentPhaseLabel(_ phase: AdvisoryEnrichmentPhase) -> String {
        switch phase {
        case .phase1Memograph:
            return "Phase 1: Memograph"
        case .phase2ReadOnly:
            return "Phase 2: Read-only"
        case .phase3Expanded:
            return "Phase 3: Expanded"
        }
    }

    private func enrichmentSourceBinding(
        for source: AdvisoryEnrichmentSource
    ) -> Binding<Bool> {
        switch source {
        case .notes:
            return .constant(true)
        case .calendar:
            return $advisoryCalendarEnrichmentEnabled
        case .reminders:
            return $advisoryRemindersEnrichmentEnabled
        case .webResearch:
            return $advisoryWebResearchEnrichmentEnabled
        case .wearable:
            return $advisoryWearableEnrichmentEnabled
        }
    }

    private func advisoryControlPlaneStatusView(runtimeSnapshot: AdvisoryBridgeRuntimeSnapshot) -> some View {
        let inventoryCount = advisoryProviderProfiles.values.reduce(0) { $0 + $1.count }
        let providerDiagnostics = runtimeSnapshot.bridgeHealth.providerStatuses.count

        return VStack(alignment: .leading, spacing: 4) {
            Text(runtimeSnapshot.runtimeStatusSummary)
                .foregroundStyle(runtimeSnapshot.isDegraded ? .orange : .secondary)

            Text(inventoryCount == 0
                 ? "Inventory on disk: no imported accounts"
                 : "Inventory on disk: \(inventoryCount) account\(inventoryCount == 1 ? "" : "s") available for runtime selection")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(verificationSummary(for: runtimeSnapshot, providerDiagnosticsCount: providerDiagnostics))
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Runtime execution and on-disk inventory are reported separately so a degraded sidecar does not hide saved accounts.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func verificationSummary(
        for runtimeSnapshot: AdvisoryBridgeRuntimeSnapshot,
        providerDiagnosticsCount: Int
    ) -> String {
        guard providerDiagnosticsCount > 0 else {
            return "Runtime probe: unavailable"
        }

        let checkedAt = runtimeSnapshot.bridgeHealth.checkedAt ?? "unknown time"
        if let activeProvider = runtimeSnapshot.bridgeHealth.activeProviderName, !activeProvider.isEmpty {
            return "Runtime probe: \(activeProvider.capitalized) is the current active provider at \(checkedAt)"
        }
        return "Runtime probe: last sidecar check at \(checkedAt)"
    }

    private func providerSessionCard(
        _ diagnostic: AdvisoryProviderDiagnostic,
        activeProviderName: String?,
        checkedAt: String?
    ) -> some View {
        let profiles = advisoryProviderProfiles[diagnostic.providerName.lowercased()] ?? []

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(diagnostic.displayName)
                            .font(.headline)
                        if activeProviderName == diagnostic.providerName {
                            Text("Active runtime")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.green.opacity(0.14)))
                        }
                    }
                    Text(providerIdentityLine(for: diagnostic))
                        .font(.subheadline.weight(.medium))
                    if let accountDetail = diagnostic.accountDetail, !accountDetail.isEmpty {
                        Text(accountDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(diagnostic.statusLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(providerStatusColor(for: diagnostic))
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 120), spacing: 12, alignment: .leading),
                    GridItem(.flexible(minimum: 120), spacing: 12, alignment: .leading)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                providerMetric("Runtime health", value: diagnostic.statusLabel)
                providerMetric("Last probe", value: checkedAt ?? "Not checked yet")
                providerMetric("Binary", value: diagnostic.binaryPresent ? "Present" : "Missing")
                providerMetric("Inventory", value: diagnostic.sessionDetected ? "Present on disk" : "Missing on disk")
                providerMetric(
                    "Cooldown",
                    value: diagnostic.cooldownRemainingSeconds.map { "\($0)s" } ?? "None"
                )
                providerMetric(
                    "Runnable",
                    value: diagnostic.runnable == true ? "Yes" : "No"
                )
                providerMetric(
                    "Failures",
                    value: diagnostic.failureCount.map(String.init) ?? "0"
                )
                providerMetric(
                    "Config dir",
                    value: diagnostic.configDirectory ?? "Unknown"
                )
                if let authResult = providerAuthVerifications[diagnostic.providerName] {
                    providerMetric(
                        "Auth verified",
                        value: authResult.verified ? "Verified \(formatVerifiedAt(authResult.verifiedAt))" : "Expired \(formatVerifiedAt(authResult.verifiedAt))"
                    )
                }
            }

            if let selectedProfile = profiles.first(where: { $0.isSelected }) {
                providerMetric("Selected account", value: "\(selectedProfile.accountName) · \(selectedProfile.displayName)")
            }

            if let detail = diagnostic.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                Button {
                    handleRunAuthCheck(for: diagnostic)
                } label: {
                    HStack(spacing: 4) {
                        if providerAuthCheckInFlight.contains(diagnostic.providerName) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        }
                        Text("Run auth check")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(providerAuthCheckInFlight.contains(diagnostic.providerName))

                if diagnostic.supports(.openConfigDir) {
                    Button("Open config dir") {
                        handleProviderSessionAction(.openConfigDir, diagnostic: diagnostic)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button("Import current session") {
                    handleImportProviderSession(diagnostic.providerName)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Add account") {
                    handleAddProviderAccount(diagnostic.providerName)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                let primaryAction = AdvisoryProviderSessionControl.preferredInteractiveAction(for: diagnostic)

                if let primaryAction {
                    Button(primaryAction.label) {
                        handleProviderSessionAction(primaryAction, diagnostic: diagnostic)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if diagnostic.supports(.logout) {
                    Button("Logout") {
                        handleProviderSessionAction(.logout, diagnostic: diagnostic)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if diagnostic.supports(.openCLI), primaryAction != .openCLI {
                    Button("Open CLI") {
                        handleProviderSessionAction(.openCLI, diagnostic: diagnostic)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if profiles.isEmpty {
                Text("No isolated accounts yet. Import your current CLI session or add a fresh account profile for \(diagnostic.displayName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Saved accounts")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Inventory on disk. Runtime execution can still be degraded even when these profiles are present.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(profiles) { profile in
                        providerAccountRow(profile)
                    }
                }
            }

            if let feedback = advisoryAccountActionFeedback[diagnostic.providerName], !feedback.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        advisoryAccountActionFeedback[diagnostic.providerName] = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.blue.opacity(0.06))
                )
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func providerAccountRow(_ profile: AdvisoryCLIAccountProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(profile.accountName)
                            .font(.caption.weight(.semibold))
                        if profile.isSelected {
                            Text("In use")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        }
                    }
                    Text(profile.displayName)
                        .font(.caption)
                    if !profile.identityHint.isEmpty, profile.identityHint != profile.displayName {
                        Text(profile.identityHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(profile.sessionDetected ? "inventory present" : "inventory missing")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(profile.sessionDetected ? .green : .orange)
            }

            HStack(spacing: 8) {
                if profile.isSelected {
                    Button("Selected") {}
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(true)
                } else {
                    Button("Use this account") {
                        handleSwitchProviderAccount(profile)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button("Re-login") {
                    handleReauthorizeProviderAccount(profile)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Open folder") {
                    openFolder(path: profile.path)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }

    private func providerMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerIdentityLine(for diagnostic: AdvisoryProviderDiagnostic) -> String {
        if let identity = diagnostic.accountIdentity, !identity.isEmpty {
            return identity
        }
        if diagnostic.sessionDetected {
            return diagnostic.status == "ok"
                ? "Session active. This CLI does not expose email/user identity."
                : "Session detected. This CLI does not expose email/user identity."
        }
        return "Runtime does not see an imported session."
    }

    private func providerStatusColor(for diagnostic: AdvisoryProviderDiagnostic) -> Color {
        switch diagnostic.status {
        case "ok":
            return .green
        case "session_expired", "session_missing", "cooldown":
            return .orange
        case "timeout":
            return .yellow
        default:
            return .secondary
        }
    }

    private func handleRunAuthCheck(for diagnostic: AdvisoryProviderDiagnostic) {
        let provider = diagnostic.providerName
        guard !providerAuthCheckInFlight.contains(provider) else { return }
        let accountName = selectedAdvisoryAccountName(for: provider)
        providerAuthCheckInFlight.insert(provider)
        advisoryAccountActionFeedback[provider] = "Running auth check for \(authCheckTargetLabel(provider: provider, accountName: accountName))…"
        advisoryHealthMonitor.checkProviderAuth(provider: provider, accountName: accountName) { verified, verifiedAt in
            providerAuthVerifications[provider] = (verified: verified, verifiedAt: verifiedAt)
            providerAuthCheckInFlight.remove(provider)
            let target = authCheckTargetLabel(provider: provider, accountName: accountName)
            let outcome = verified
                ? "Auth check passed — \(target) session is active."
                : "Auth check failed — \(target) session appears expired. Try re-login."
            advisoryAccountActionFeedback[provider] = outcome
        }
    }

    private func formatVerifiedAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "at \(formatter.string(from: date))"
    }

    private func handleProviderSessionAction(
        _ action: AdvisoryProviderSessionAction,
        diagnostic: AdvisoryProviderDiagnostic
    ) {
        guard let plan = AdvisoryProviderSessionControl.plan(for: diagnostic, action: action) else {
            advisoryAccountActionFeedback[diagnostic.providerName] = "This action is not supported by the current \(diagnostic.displayName) CLI."
            return
        }

        switch plan.kind {
        case .refreshOnly:
            advisoryAccountActionFeedback[diagnostic.providerName] = plan.guidance
            isRefreshingAccounts = true
            advisoryHealthMonitor.refresh(forceRefresh: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                isRefreshingAccounts = false
            }
        case .openDirectory:
            do {
                try AdvisoryProviderSessionControl.launch(plan)
                advisoryAccountActionFeedback[diagnostic.providerName] = plan.guidance
            } catch {
                advisoryAccountActionFeedback[diagnostic.providerName] = error.localizedDescription
            }
        case .terminalCommand:
            let providerName = diagnostic.providerName
            pendingTerminalProvider = providerName
            pendingTerminalAccountName = plan.accountName
            advisoryAccountActionFeedback[providerName] = plan.guidance

            let bridge = AdvisoryBridgeClient(settings: AppSettings())
            AdvisoryProviderSessionControl.launchAndMonitorRecovery(
                plan,
                bridge: bridge
            ) { recovered in
                DispatchQueue.main.async {
                    clearPendingTerminalRecovery()
                    if recovered {
                        advisoryAccountActionFeedback[providerName] = "\(diagnostic.displayName) session recovered successfully."
                    } else {
                        advisoryAccountActionFeedback[providerName] = "Recovery timed out for \(diagnostic.displayName). Try running a full auth check."
                    }
                    refreshAdvisoryProviderProfiles()
                    advisoryHealthMonitor.refresh(forceRefresh: true)
                }
            }
        }
    }

    private func refreshAdvisoryProviderProfiles() {
        advisoryCLIProfilesPath = normalizedProfilesPath()
        advisoryProviderProfiles = AdvisoryCLIProfilesStore.discoverProfiles(
            profilesPath: advisoryCLIProfilesPath,
            selectedAccounts: AdvisoryCLIProfilesStore.selectedAccounts()
        )
    }

    private func handleImportProviderSession(_ providerName: String) {
        do {
            persistProfilesPath()
            let imported = try AdvisoryCLIProfilesStore.importCurrentSession(
                provider: providerName,
                profilesPath: advisoryCLIProfilesPath
            )
            persistSelectedAccount(imported.accountName, providerName: providerName)
            refreshAdvisoryProviderProfiles()
            advisoryAccountActionFeedback[providerName] = "Imported current \(providerName.capitalized) session as \(imported.accountName). Verifying runtime path for this account…"
            advisoryHealthMonitor.recoverAfterRelogin(provider: providerName, accountName: imported.accountName) { verified, verifiedAt in
                providerAuthVerifications[providerName] = (verified, verifiedAt)
                refreshAdvisoryProviderProfiles()
                if verified {
                    advisoryAccountActionFeedback[providerName] = "Imported \(providerName.capitalized) \(imported.accountName) and verified the runtime path."
                } else {
                    advisoryAccountActionFeedback[providerName] = "Imported \(providerName.capitalized) \(imported.accountName), but runtime verification is still pending. Run a full auth check if it does not recover."
                }
            }
        } catch {
            advisoryAccountActionFeedback[providerName] = error.localizedDescription
        }
    }

    private func handleAddProviderAccount(_ providerName: String) {
        do {
            persistProfilesPath()
            let profile = try AdvisoryCLIProfilesStore.createNextProfile(
                provider: providerName,
                profilesPath: advisoryCLIProfilesPath
            )
            persistSelectedAccount(profile.accountName, providerName: providerName)
            let action: AdvisoryProviderSessionAction = providerName == "gemini" ? .openCLI : .login
            guard let command = AdvisoryProviderSessionControl.command(forProvider: providerName, action: action) else {
                advisoryAccountActionFeedback[providerName] = "No interactive login command is available for \(providerName.capitalized)."
                return
            }

            let plan = AdvisoryProviderSessionActionPlan(
                providerName: providerName,
                accountName: profile.accountName,
                action: action,
                kind: .terminalCommand(command),
                guidance: "Login in progress for \(providerName.capitalized) \(profile.accountName)…",
                environment: AdvisoryCLIProfilesStore.loginEnvironment(
                    provider: providerName,
                    profilePath: profile.path
                )
            )

            pendingTerminalProvider = providerName
            pendingTerminalAccountName = profile.accountName
            refreshAdvisoryProviderProfiles()
            advisoryAccountActionFeedback[providerName] = plan.guidance

            let bridge = AdvisoryBridgeClient(settings: AppSettings())
            AdvisoryProviderSessionControl.launchAndMonitorRecovery(
                plan,
                bridge: bridge
            ) { recovered in
                DispatchQueue.main.async {
                    clearPendingTerminalRecovery()
                    if recovered {
                        advisoryAccountActionFeedback[providerName] = "\(providerName.capitalized) \(profile.accountName) session established successfully."
                    } else {
                        advisoryAccountActionFeedback[providerName] = "Login monitoring timed out for \(providerName.capitalized) \(profile.accountName). Try running a full auth check."
                    }
                    refreshAdvisoryProviderProfiles()
                    advisoryHealthMonitor.refresh(forceRefresh: true)
                }
            }
        } catch {
            advisoryAccountActionFeedback[providerName] = error.localizedDescription
        }
    }

    private func handleSwitchProviderAccount(_ profile: AdvisoryCLIAccountProfile) {
        persistProfilesPath()
        persistSelectedAccount(profile.accountName, providerName: profile.providerName)
        refreshAdvisoryProviderProfiles()
        advisoryAccountActionFeedback[profile.providerName] = "Switched \(profile.providerName.capitalized) to \(profile.accountName). Verifying runtime path for the selected account…"
        advisoryHealthMonitor.checkProviderAuth(provider: profile.providerName, accountName: profile.accountName) { verified, verifiedAt in
            providerAuthVerifications[profile.providerName] = (verified, verifiedAt)
            refreshAdvisoryProviderProfiles()
            if verified {
                advisoryAccountActionFeedback[profile.providerName] = "Switched \(profile.providerName.capitalized) to \(profile.accountName) and verified the runtime path."
            } else {
                advisoryAccountActionFeedback[profile.providerName] = "Switched \(profile.providerName.capitalized) to \(profile.accountName). Inventory is updated, but runtime verification is still pending."
            }
        }
    }

    private func handleReauthorizeProviderAccount(_ profile: AdvisoryCLIAccountProfile) {
        let providerName = profile.providerName
        let action: AdvisoryProviderSessionAction = providerName == "gemini" ? .openCLI : .relogin
        guard let command = AdvisoryProviderSessionControl.command(forProvider: providerName, action: action) else {
            advisoryAccountActionFeedback[providerName] = "No re-login flow is available for \(providerName.capitalized)."
            return
        }

        let plan = AdvisoryProviderSessionActionPlan(
            providerName: providerName,
            accountName: profile.accountName,
            action: action,
            kind: .terminalCommand(command),
            guidance: "Re-login in progress for \(providerName.capitalized) \(profile.accountName)…",
            environment: AdvisoryCLIProfilesStore.loginEnvironment(
                provider: providerName,
                profilePath: profile.path
            )
        )

        pendingTerminalProvider = providerName
        pendingTerminalAccountName = profile.accountName
        advisoryAccountActionFeedback[providerName] = plan.guidance

        let bridge = AdvisoryBridgeClient(settings: AppSettings())
        AdvisoryProviderSessionControl.launchAndMonitorRecovery(
            plan,
            bridge: bridge
        ) { recovered in
            DispatchQueue.main.async {
                clearPendingTerminalRecovery()
                if recovered {
                    advisoryAccountActionFeedback[providerName] = "\(providerName.capitalized) \(profile.accountName) session recovered successfully."
                } else {
                    advisoryAccountActionFeedback[providerName] = "Recovery timed out for \(providerName.capitalized) \(profile.accountName). Try running a full auth check."
                }
                refreshAdvisoryProviderProfiles()
                advisoryHealthMonitor.refresh(forceRefresh: true)
            }
        }
    }

    private func persistSelectedAccount(_ accountName: String, providerName: String) {
        var settings = AppSettings()
        switch providerName.lowercased() {
        case "claude":
            settings.advisorySelectedClaudeAccount = accountName
        case "gemini":
            settings.advisorySelectedGeminiAccount = accountName
        case "codex":
            settings.advisorySelectedCodexAccount = accountName
        default:
            break
        }
        try? AdvisoryCLIProfilesStore.setPreferredAccount(
            provider: providerName,
            accountName: accountName,
            profilesPath: normalizedProfilesPath()
        )
    }

    private func persistProfilesPath() {
        persistProfilesPath(restartSidecar: false)
    }

    private func persistProfilesPath(restartSidecar: Bool) {
        let normalized = normalizedProfilesPath()
        advisoryCLIProfilesPath = normalized
        var settings = AppSettings()
        let pathChanged = settings.advisoryCLIProfilesPath != normalized
        settings.advisoryCLIProfilesPath = normalized
        refreshAdvisoryProviderProfiles()
        if restartSidecar, pathChanged {
            advisoryHealthMonitor.restartSidecar()
        } else if pathChanged {
            advisoryHealthMonitor.refresh(forceRefresh: false)
        }
        if pathChanged {
            NotificationCenter.default.post(name: .settingsDidChange, object: nil)
        }
    }

    private func debouncedPersistProfilesPath() {
        pendingProfilesPathPersistWorkItem?.cancel()
        let workItem = DispatchWorkItem { [advisoryCLIProfilesPath] in
            guard self.advisoryCLIProfilesPath == advisoryCLIProfilesPath else { return }
            self.persistProfilesPath(restartSidecar: true)
        }
        pendingProfilesPathPersistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func clearPendingTerminalRecovery() {
        pendingTerminalProvider = ""
        pendingTerminalAccountName = nil
    }

    private func selectedAdvisoryAccountName(for provider: String) -> String? {
        advisoryProviderProfiles[provider.lowercased()]?.first(where: { $0.isSelected })?.accountName
    }

    private func authCheckTargetLabel(provider: String, accountName: String?) -> String {
        if let accountName, !accountName.isEmpty {
            return "\(provider.capitalized) \(accountName)"
        }
        return provider.capitalized
    }

    private func pendingTerminalTargetDescription() -> String {
        authCheckTargetLabel(provider: pendingTerminalProvider, accountName: pendingTerminalAccountName)
    }

    private func runFullAuthCheck() {
        guard !isRefreshingAccounts else { return }
        isRefreshingAccounts = true
        persistProfilesPath()
        refreshAdvisoryProviderProfiles()
        let selectedAccounts = Dictionary(
            uniqueKeysWithValues: advisoryProviderProfiles.map { provider, profiles in
                (provider, profiles.first(where: { $0.isSelected })?.accountName)
            }
        )

        DispatchQueue.global(qos: .utility).async {
            let bridge = AdvisoryBridgeClient(settings: AppSettings())
            var verifications: [String: (verified: Bool, verifiedAt: Date)] = [:]
            for provider in ["claude", "gemini", "codex"] {
                let result = bridge.checkProviderAuth(
                    provider: provider,
                    accountName: selectedAccounts[provider] ?? nil,
                    forceRefresh: true
                )
                verifications[provider] = (verified: result.verified, verifiedAt: result.lastVerifiedAt)
            }

            let runtimeSnapshot = bridge.runtimeSnapshot(forceRefresh: true)
            let runtimeNeedsRestart = ["socket_missing", "transport_failure", "unavailable", "hung_start"].contains(
                runtimeSnapshot.effectiveStatus
            )

            DispatchQueue.main.async {
                for (provider, verification) in verifications {
                    providerAuthVerifications[provider] = verification
                }
                refreshAdvisoryProviderProfiles()
                if runtimeNeedsRestart {
                    advisoryHealthMonitor.restartSidecar()
                } else {
                    advisoryHealthMonitor.refresh(forceRefresh: false)
                }
                isRefreshingAccounts = false
            }
        }
    }

    private func normalizedProfilesPath() -> String {
        let trimmed = advisoryCLIProfilesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AdvisoryCLIProfilesStore.defaultProfilesPath : trimmed
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
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
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
