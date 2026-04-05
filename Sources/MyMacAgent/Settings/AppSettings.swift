import Foundation

enum AppOperatingMode: String, CaseIterable, Identifiable {
    case localOnly = "local_only"
    case hybrid
    case cloudAssisted = "cloud_assisted"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .localOnly: return "Local only"
        case .hybrid: return "Hybrid"
        case .cloudAssisted: return "Cloud-assisted"
        }
    }
}

enum SummaryProvider: String, CaseIterable, Identifiable {
    case disabled
    case local
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .local: return "Local"
        case .external: return "External"
        }
    }
}

enum VisionProvider: String, CaseIterable, Identifiable {
    case disabled
    case ollama
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disabled: return "Disabled"
        case .ollama: return "Local (Ollama)"
        case .external: return "External"
        }
    }
}

enum OCRProviderKind: String, CaseIterable, Identifiable {
    case ollamaWithVisionFallback = "ollama_with_vision_fallback"
    case ollamaOnly = "ollama_only"
    case visionOnly = "vision_only"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ollamaWithVisionFallback: return "Ollama + Vision fallback"
        case .ollamaOnly: return "Ollama only"
        case .visionOnly: return "Vision only"
        }
    }
}

enum AudioTranscriptionProvider: String, CaseIterable, Identifiable {
    case openAI = "openai"
    case localWhisper = "local_whisper"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI: return "Cloud (OpenAI)"
        case .localWhisper: return "Local (Whisper)"
        }
    }
}

enum StorageProfile: String, CaseIterable, Identifiable {
    case raw
    case balanced
    case compact

    var id: String { rawValue }
}

enum CaptureRetentionMode: String, CaseIterable, Identifiable {
    case raw
    case thumbnails
    case textOnly = "text_only"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .raw: return "Keep screenshots"
        case .thumbnails: return "Keep only thumbnails"
        case .textOnly: return "Keep only text"
        }
    }
}

struct AppSettings {
    private let defaults: UserDefaults
    private let credentialsStore: any CredentialsStore
    private let legacyCredentialsStore: any CredentialsStore
    private static let hasExternalAPIKeyKey = "hasExternalAPIKey"
    private static let hasAudioTranscriptionAPIKeyKey = "hasAudioTranscriptionAPIKey"
    private static let experimentalAudioOptInConfirmedKey = "experimentalAudioOptInConfirmed"
    private static let migratedOffKeychainKey = "migratedOffKeychain"

    static let persistentSystemAudioCaptureAvailable = true

    static let sharedLegacyCredentialsStore: any CredentialsStore =
        KeychainCredentialsStore(service: "com.memograph.credentials")

    static let defaultBlacklistedBundleIds = [
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "com.dashlane.Dashlane",
        "com.apple.dt.Xcode", // protects signing and secrets dialogs
    ]

    static let defaultMetadataOnlyBundleIds = [
        "com.apple.MobileSMS",
        "com.tinyspeck.slackmacgap",
        "ru.keepcoder.Telegram",
        "com.apple.mail"
    ]

    static let defaultBlacklistedWindowPatterns = [
        "password",
        "private browsing",
        "incognito",
        "secret",
        "credential",
        "recovery key",
        "seed phrase",
        "wallet"
    ]

    init(
        defaults: UserDefaults = .standard,
        credentialsStore: (any CredentialsStore)? = nil,
        legacyCredentialsStore: (any CredentialsStore)? = nil
    ) {
        self.defaults = defaults
        self.credentialsStore = credentialsStore
            ?? PreferencesCredentialsStore(defaults: defaults)
        self.legacyCredentialsStore = legacyCredentialsStore
            ?? (credentialsStore == nil ? AppSettings.sharedLegacyCredentialsStore : NoOpCredentialsStore())
        migrateLegacyCredentialsIfNeeded()
        migrateAwayFromKeychainIfNeeded()
        migrateExperimentalAudioOptInIfNeeded()
    }

    // MARK: - API

    var externalAPIKey: String {
        get {
            (credentialsStore.string(for: "externalAPIKey") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                credentialsStore.removeValue(for: "externalAPIKey")
                defaults.set(false, forKey: Self.hasExternalAPIKeyKey)
            } else {
                credentialsStore.set(trimmed, for: "externalAPIKey")
                defaults.set(true, forKey: Self.hasExternalAPIKeyKey)
            }
        }
    }

    var openRouterApiKey: String {
        get { externalAPIKey }
        set { externalAPIKey = newValue }
    }

    var hasApiKey: Bool {
        if defaults.object(forKey: Self.hasExternalAPIKeyKey) != nil {
            return defaults.bool(forKey: Self.hasExternalAPIKeyKey)
        }

        let exists = credentialsStore.hasValue(for: "externalAPIKey")
        defaults.set(exists, forKey: Self.hasExternalAPIKeyKey)
        return exists
    }

    var externalBaseURL: String {
        get { defaults.string(forKey: "externalBaseURL") ?? "https://openrouter.ai/api/v1" }
        set { defaults.set(newValue, forKey: "externalBaseURL") }
    }

    var externalProviderName: String {
        get { defaults.string(forKey: "externalProviderName") ?? "OpenRouter-compatible" }
        set { defaults.set(newValue, forKey: "externalProviderName") }
    }

    var operatingMode: AppOperatingMode {
        get { AppOperatingMode(rawValue: defaults.string(forKey: "operatingMode") ?? "") ?? .localOnly }
        set { defaults.set(newValue.rawValue, forKey: "operatingMode") }
    }

    var summaryProvider: SummaryProvider {
        get { SummaryProvider(rawValue: defaults.string(forKey: "summaryProvider") ?? "") ?? .disabled }
        set { defaults.set(newValue.rawValue, forKey: "summaryProvider") }
    }

    var resolvedSummaryProvider: SummaryProvider {
        guard networkAllowed else {
            return summaryProvider == .disabled ? .disabled : .local
        }
        return summaryProvider
    }

    var summaryExternalModel: String {
        get { defaults.string(forKey: "summaryExternalModel") ?? "minimax/minimax-m2.7" }
        set { defaults.set(newValue, forKey: "summaryExternalModel") }
    }

    var summaryLocalModel: String {
        get { defaults.string(forKey: "summaryLocalModel") ?? "hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M" }
        set { defaults.set(newValue, forKey: "summaryLocalModel") }
    }

    var llmModel: String {
        get { summaryExternalModel }
        set { summaryExternalModel = newValue }
    }

    var networkAllowed: Bool { operatingMode != .localOnly }

    // MARK: - Obsidian

    var obsidianVaultPath: String {
        get { defaults.string(forKey: "obsidianVaultPath")
              ?? NSHomeDirectory() + "/Documents/MyMacAgentVault" }
        set { defaults.set(newValue, forKey: "obsidianVaultPath") }
    }

    var dataDirectoryPath: String {
        get { defaults.string(forKey: "dataDirectoryPath") ?? AppPaths.defaultDataDirectoryPath() }
        set { defaults.set(newValue, forKey: "dataDirectoryPath") }
    }

    // MARK: - Capture

    var maxPromptChars: Int {
        get {
            let val = defaults.integer(forKey: "maxPromptChars")
            return val > 0 ? val : 300_000
        }
        set { defaults.set(newValue, forKey: "maxPromptChars") }
    }

    var startPaused: Bool {
        get { defaults.bool(forKey: "startPaused") }
        set { defaults.set(newValue, forKey: "startPaused") }
    }

    var globalPause: Bool {
        get { defaults.bool(forKey: "captureGlobalPause") }
        set { defaults.set(newValue, forKey: "captureGlobalPause") }
    }

    var summaryIntervalMinutes: Int {
        get {
            let val = defaults.integer(forKey: "summaryIntervalMinutes")
            return val > 0 ? val : 60
        }
        set { defaults.set(newValue, forKey: "summaryIntervalMinutes") }
    }

    var retentionDays: Int {
        get {
            let val = defaults.integer(forKey: "retentionDays")
            return val > 0 ? val : 30
        }
        set { defaults.set(newValue, forKey: "retentionDays") }
    }

    var knowledgeMaintenanceIntervalHours: Int {
        get {
            let val = defaults.integer(forKey: "knowledgeMaintenanceIntervalHours")
            return val > 0 ? val : 24
        }
        set { defaults.set(newValue, forKey: "knowledgeMaintenanceIntervalHours") }
    }

    var lastKnowledgeMaintenanceAt: String? {
        get { defaults.string(forKey: "lastKnowledgeMaintenanceAt") }
        set { defaults.set(newValue, forKey: "lastKnowledgeMaintenanceAt") }
    }

    var knowledgeSuppressedEntityIds: [String] {
        get { readList(forKey: "knowledgeSuppressedEntityIds", defaultValue: []) }
        set { writeList(Array(Set(newValue)).sorted(), forKey: "knowledgeSuppressedEntityIds") }
    }

    var knowledgeAppliedActions: [KnowledgeAppliedActionRecord] {
        get { readCodableArray(forKey: "knowledgeAppliedActions") }
        set { writeCodableArray(Array(newValue.suffix(100)), forKey: "knowledgeAppliedActions") }
    }

    var knowledgeMergeOverlays: [KnowledgeMergeOverlayRecord] {
        get { readCodableArray(forKey: "knowledgeMergeOverlays") }
        set { writeCodableArray(Array(newValue.suffix(100)), forKey: "knowledgeMergeOverlays") }
    }

    var knowledgeAliasOverrides: [KnowledgeAliasOverrideRecord] {
        get { readCodableArray(forKey: "knowledgeAliasOverrides") }
        set { writeCodableArray(Array(newValue.suffix(300)), forKey: "knowledgeAliasOverrides") }
    }

    var knowledgeReviewDecisions: [KnowledgeReviewDecisionRecord] {
        get { readCodableArray(forKey: "knowledgeReviewDecisions") }
        set { writeCodableArray(Array(newValue.suffix(300)), forKey: "knowledgeReviewDecisions") }
    }

    var maxCapturesPerSession: Int {
        get {
            let val = defaults.integer(forKey: "maxCapturesPerSession")
            return val > 0 ? val : 500
        }
        set { defaults.set(newValue, forKey: "maxCapturesPerSession") }
    }

    var normalCaptureIntervalSeconds: Double {
        get { nonZeroDouble(forKey: "normalCaptureIntervalSeconds", defaultValue: 60) }
        set { defaults.set(newValue, forKey: "normalCaptureIntervalSeconds") }
    }

    var degradedCaptureIntervalSeconds: Double {
        get { nonZeroDouble(forKey: "degradedCaptureIntervalSeconds", defaultValue: 10) }
        set { defaults.set(newValue, forKey: "degradedCaptureIntervalSeconds") }
    }

    var highUncertaintyCaptureIntervalSeconds: Double {
        get { nonZeroDouble(forKey: "highUncertaintyCaptureIntervalSeconds", defaultValue: 3) }
        set { defaults.set(newValue, forKey: "highUncertaintyCaptureIntervalSeconds") }
    }

    var storageProfile: StorageProfile {
        get { StorageProfile(rawValue: defaults.string(forKey: "storageProfile") ?? "") ?? .balanced }
        set { defaults.set(newValue.rawValue, forKey: "storageProfile") }
    }

    var captureRetentionMode: CaptureRetentionMode {
        get { CaptureRetentionMode(rawValue: defaults.string(forKey: "captureRetentionMode") ?? "") ?? .raw }
        set { defaults.set(newValue.rawValue, forKey: "captureRetentionMode") }
    }

    // MARK: - OCR

    var ocrProvider: OCRProviderKind {
        get { OCRProviderKind(rawValue: defaults.string(forKey: "ocrProvider") ?? "") ?? .ollamaWithVisionFallback }
        set { defaults.set(newValue.rawValue, forKey: "ocrProvider") }
    }

    var ollamaModelName: String {
        get { defaults.string(forKey: "ollamaModelName") ?? "glm-ocr" }
        set { defaults.set(newValue, forKey: "ollamaModelName") }
    }

    var ollamaBaseURL: String {
        get { defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434" }
        set { defaults.set(newValue, forKey: "ollamaBaseURL") }
    }

    // MARK: - Vision

    var visionModel: String {
        get { defaults.string(forKey: "visionModel") ?? "qwen3.5:4b" }
        set { defaults.set(newValue, forKey: "visionModel") }
    }

    var visionExternalModel: String {
        get { defaults.string(forKey: "visionExternalModel") ?? summaryExternalModel }
        set { defaults.set(newValue, forKey: "visionExternalModel") }
    }

    var visionProvider: VisionProvider {
        get { VisionProvider(rawValue: defaults.string(forKey: "visionProvider") ?? "") ?? .ollama }
        set { defaults.set(newValue.rawValue, forKey: "visionProvider") }
    }

    var resolvedVisionProvider: VisionProvider {
        guard networkAllowed else {
            return visionProvider == .external ? .ollama : visionProvider
        }
        return visionProvider
    }

    // MARK: - Privacy

    var blacklistedBundleIds: [String] {
        get { readList(forKey: "blacklistedBundleIds", defaultValue: Self.defaultBlacklistedBundleIds) }
        set { writeList(newValue, forKey: "blacklistedBundleIds") }
    }

    var metadataOnlyBundleIds: [String] {
        get { readList(forKey: "metadataOnlyBundleIds", defaultValue: Self.defaultMetadataOnlyBundleIds) }
        set { writeList(newValue, forKey: "metadataOnlyBundleIds") }
    }

    var blacklistedWindowPatterns: [String] {
        get { readList(forKey: "blacklistedWindowPatterns", defaultValue: Self.defaultBlacklistedWindowPatterns) }
        set { writeList(newValue, forKey: "blacklistedWindowPatterns") }
    }

    // MARK: - Audio

    var microphoneCaptureEnabled: Bool {
        get { defaults.bool(forKey: "microphoneCaptureEnabled") }
        set { defaults.set(newValue, forKey: "microphoneCaptureEnabled") }
    }

    var systemAudioCaptureEnabled: Bool {
        get { defaults.bool(forKey: "systemAudioCaptureEnabled") }
        set { defaults.set(newValue, forKey: "systemAudioCaptureEnabled") }
    }

    var resolvedSystemAudioCaptureEnabled: Bool {
        Self.persistentSystemAudioCaptureAvailable && systemAudioCaptureEnabled
    }

    var audioTranscriptionProvider: AudioTranscriptionProvider {
        get {
            AudioTranscriptionProvider(
                rawValue: defaults.string(forKey: "audioTranscriptionProvider") ?? ""
            ) ?? .localWhisper
        }
        set { defaults.set(newValue.rawValue, forKey: "audioTranscriptionProvider") }
    }

    var audioTranscriptionBaseURL: String {
        get { defaults.string(forKey: "audioTranscriptionBaseURL") ?? "https://api.openai.com/v1" }
        set { defaults.set(newValue, forKey: "audioTranscriptionBaseURL") }
    }

    var audioTranscriptionAPIKey: String {
        get {
            (credentialsStore.string(for: "audioTranscriptionAPIKey") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                credentialsStore.removeValue(for: "audioTranscriptionAPIKey")
                defaults.set(false, forKey: Self.hasAudioTranscriptionAPIKeyKey)
            } else {
                credentialsStore.set(trimmed, for: "audioTranscriptionAPIKey")
                defaults.set(true, forKey: Self.hasAudioTranscriptionAPIKeyKey)
            }
        }
    }

    var resolvedAudioTranscriptionAPIKey: String {
        let directKey = audioTranscriptionAPIKey
        if !directKey.isEmpty {
            return directKey
        }

        let trimmedExternalKey = externalAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAudioBase = audioTranscriptionBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedExternalBase = externalBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !trimmedExternalKey.isEmpty, normalizedAudioBase == normalizedExternalBase {
            return trimmedExternalKey
        }

        return ""
    }

    var hasAudioTranscriptionApiKey: Bool {
        if defaults.object(forKey: Self.hasAudioTranscriptionAPIKeyKey) != nil {
            return defaults.bool(forKey: Self.hasAudioTranscriptionAPIKeyKey)
                || (!resolvedAudioTranscriptionAPIKey.isEmpty && !audioTranscriptionAPIKey.isEmpty)
        }

        let exists = credentialsStore.hasValue(for: "audioTranscriptionAPIKey")
        defaults.set(exists, forKey: Self.hasAudioTranscriptionAPIKeyKey)
        return exists
    }

    var audioMicrophoneModel: String {
        get { defaults.string(forKey: "audioMicrophoneModel") ?? "gpt-4o-transcribe" }
        set { defaults.set(newValue, forKey: "audioMicrophoneModel") }
    }

    var audioSystemModel: String {
        get { defaults.string(forKey: "audioSystemModel") ?? "gpt-4o-mini-transcribe" }
        set { defaults.set(newValue, forKey: "audioSystemModel") }
    }

    var audioPythonCommand: String {
        get { defaults.string(forKey: "audioPythonCommand") ?? "" }
        set { defaults.set(newValue, forKey: "audioPythonCommand") }
    }

    var audioModelName: String {
        get { defaults.string(forKey: "audioModelName") ?? "mlx-community/whisper-large-v3-turbo" }
        set { defaults.set(newValue, forKey: "audioModelName") }
    }

    var experimentalAudioOptInConfirmed: Bool {
        get { defaults.bool(forKey: Self.experimentalAudioOptInConfirmedKey) }
        set { defaults.set(newValue, forKey: Self.experimentalAudioOptInConfirmedKey) }
    }

    // MARK: - Advisory

    var advisoryEnabled: Bool {
        get {
            if defaults.object(forKey: "advisoryEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "advisoryEnabled")
        }
        set { defaults.set(newValue, forKey: "advisoryEnabled") }
    }

    var advisoryAccessProfile: AdvisoryAccessProfile {
        get {
            AdvisoryAccessProfile(
                rawValue: defaults.string(forKey: "advisoryAccessProfile") ?? ""
            ) ?? .deepContext
        }
        set { defaults.set(newValue.rawValue, forKey: "advisoryAccessProfile") }
    }

    var advisoryProactivityMode: AdvisoryProactivityMode {
        get {
            AdvisoryProactivityMode(
                rawValue: defaults.string(forKey: "advisoryProactivityMode") ?? ""
            ) ?? .ambient
        }
        set { defaults.set(newValue.rawValue, forKey: "advisoryProactivityMode") }
    }

    var advisoryBridgeMode: AdvisoryBridgeMode {
        get {
            AdvisoryBridgeMode(
                rawValue: defaults.string(forKey: "advisoryBridgeMode") ?? ""
            ) ?? .preferSidecar
        }
        set { defaults.set(newValue.rawValue, forKey: "advisoryBridgeMode") }
    }

    var advisorySidecarAutoStart: Bool {
        get {
            if defaults.object(forKey: "advisorySidecarAutoStart") == nil {
                return true
            }
            return defaults.bool(forKey: "advisorySidecarAutoStart")
        }
        set { defaults.set(newValue, forKey: "advisorySidecarAutoStart") }
    }

    var advisorySidecarSocketPath: String {
        get {
            defaults.string(forKey: "advisorySidecarSocketPath")
                ?? ((dataDirectoryPath as NSString).appendingPathComponent("advisory/memograph-advisor.sock"))
        }
        set { defaults.set(newValue, forKey: "advisorySidecarSocketPath") }
    }

    var advisorySidecarTimeoutSeconds: Int {
        get {
            let value = defaults.integer(forKey: "advisorySidecarTimeoutSeconds")
            return value > 0 ? value : 20
        }
        set { defaults.set(newValue, forKey: "advisorySidecarTimeoutSeconds") }
    }

    var advisorySidecarHealthCheckIntervalSeconds: Int {
        get {
            let value = defaults.integer(forKey: "advisorySidecarHealthCheckIntervalSeconds")
            return value > 0 ? value : 30
        }
        set { defaults.set(newValue, forKey: "advisorySidecarHealthCheckIntervalSeconds") }
    }

    var advisorySidecarMaxConsecutiveFailures: Int {
        get {
            let value = defaults.integer(forKey: "advisorySidecarMaxConsecutiveFailures")
            return value > 0 ? value : 50
        }
        set { defaults.set(newValue, forKey: "advisorySidecarMaxConsecutiveFailures") }
    }

    var advisorySidecarProviderOrder: [String] {
        get { readList(forKey: "advisorySidecarProviderOrder", defaultValue: ["claude", "gemini", "codex"]) }
        set { writeList(newValue, forKey: "advisorySidecarProviderOrder") }
    }

    var advisorySidecarProviderProbeTimeoutSeconds: Int {
        get {
            let value = defaults.integer(forKey: "advisorySidecarProviderProbeTimeoutSeconds")
            return value > 0 ? value : 20
        }
        set { defaults.set(newValue, forKey: "advisorySidecarProviderProbeTimeoutSeconds") }
    }

    var advisorySidecarRetryAttempts: Int {
        get {
            let value = defaults.integer(forKey: "advisorySidecarRetryAttempts")
            return value > 0 ? value : 2
        }
        set { defaults.set(newValue, forKey: "advisorySidecarRetryAttempts") }
    }

    var advisorySidecarProviderCooldownSeconds: Int {
        get {
            let value = defaults.integer(forKey: "advisorySidecarProviderCooldownSeconds")
            return value > 0 ? value : 60
        }
        set { defaults.set(newValue, forKey: "advisorySidecarProviderCooldownSeconds") }
    }

    var advisoryCLIProfilesPath: String {
        get {
            defaults.string(forKey: "advisoryCLIProfilesPath")
                ?? ((NSHomeDirectory() as NSString).appendingPathComponent(".cli-profiles"))
        }
        set { defaults.set(newValue, forKey: "advisoryCLIProfilesPath") }
    }

    var advisorySelectedClaudeAccount: String {
        get { defaults.string(forKey: "advisorySelectedClaudeAccount") ?? "" }
        set { defaults.set(newValue, forKey: "advisorySelectedClaudeAccount") }
    }

    var advisorySelectedGeminiAccount: String {
        get { defaults.string(forKey: "advisorySelectedGeminiAccount") ?? "" }
        set { defaults.set(newValue, forKey: "advisorySelectedGeminiAccount") }
    }

    var advisorySelectedCodexAccount: String {
        get { defaults.string(forKey: "advisorySelectedCodexAccount") ?? "" }
        set { defaults.set(newValue, forKey: "advisorySelectedCodexAccount") }
    }

    var advisoryDailyAttentionBudget: Int {
        get {
            let value = defaults.integer(forKey: "advisoryDailyAttentionBudget")
            return value > 0 ? value : 2
        }
        set { defaults.set(newValue, forKey: "advisoryDailyAttentionBudget") }
    }

    var advisoryMinGapMinutes: Int {
        get {
            let value = defaults.integer(forKey: "advisoryMinGapMinutes")
            return value > 0 ? value : 90
        }
        set { defaults.set(newValue, forKey: "advisoryMinGapMinutes") }
    }

    var advisoryPerThreadCooldownHours: Int {
        get {
            let value = defaults.integer(forKey: "advisoryPerThreadCooldownHours")
            return value > 0 ? value : 12
        }
        set { defaults.set(newValue, forKey: "advisoryPerThreadCooldownHours") }
    }

    var advisoryAllowScreenshotEscalation: Bool {
        get {
            if defaults.object(forKey: "advisoryAllowScreenshotEscalation") == nil {
                return true
            }
            return defaults.bool(forKey: "advisoryAllowScreenshotEscalation")
        }
        set { defaults.set(newValue, forKey: "advisoryAllowScreenshotEscalation") }
    }

    var advisoryAllowMCPEnrichment: Bool {
        get { defaults.bool(forKey: "advisoryAllowMCPEnrichment") }
        set { defaults.set(newValue, forKey: "advisoryAllowMCPEnrichment") }
    }

    var advisoryEnrichmentPhase: AdvisoryEnrichmentPhase {
        get {
            AdvisoryEnrichmentPhase(
                rawValue: defaults.string(forKey: "advisoryEnrichmentPhase") ?? ""
            ) ?? .phase1Memograph
        }
        set { defaults.set(newValue.rawValue, forKey: "advisoryEnrichmentPhase") }
    }

    var advisoryCalendarEnrichmentEnabled: Bool {
        get {
            if defaults.object(forKey: "advisoryCalendarEnrichmentEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "advisoryCalendarEnrichmentEnabled")
        }
        set { defaults.set(newValue, forKey: "advisoryCalendarEnrichmentEnabled") }
    }

    var advisoryRemindersEnrichmentEnabled: Bool {
        get {
            if defaults.object(forKey: "advisoryRemindersEnrichmentEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "advisoryRemindersEnrichmentEnabled")
        }
        set { defaults.set(newValue, forKey: "advisoryRemindersEnrichmentEnabled") }
    }

    var advisoryWebResearchEnrichmentEnabled: Bool {
        get {
            if defaults.object(forKey: "advisoryWebResearchEnrichmentEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "advisoryWebResearchEnrichmentEnabled")
        }
        set { defaults.set(newValue, forKey: "advisoryWebResearchEnrichmentEnabled") }
    }

    var advisoryWearableEnrichmentEnabled: Bool {
        get {
            if defaults.object(forKey: "advisoryWearableEnrichmentEnabled") == nil {
                return true
            }
            return defaults.bool(forKey: "advisoryWearableEnrichmentEnabled")
        }
        set { defaults.set(newValue, forKey: "advisoryWearableEnrichmentEnabled") }
    }

    var advisoryEnrichmentMaxItemsPerSource: Int {
        get {
            let value = defaults.integer(forKey: "advisoryEnrichmentMaxItemsPerSource")
            return value > 0 ? value : 3
        }
        set { defaults.set(newValue, forKey: "advisoryEnrichmentMaxItemsPerSource") }
    }

    var advisoryCalendarLookaheadHours: Int {
        get {
            let value = defaults.integer(forKey: "advisoryCalendarLookaheadHours")
            return value > 0 ? value : 18
        }
        set { defaults.set(newValue, forKey: "advisoryCalendarLookaheadHours") }
    }

    var advisoryReminderHorizonDays: Int {
        get {
            let value = defaults.integer(forKey: "advisoryReminderHorizonDays")
            return value > 0 ? value : 7
        }
        set { defaults.set(newValue, forKey: "advisoryReminderHorizonDays") }
    }

    var advisoryWebResearchLookbackDays: Int {
        get {
            let value = defaults.integer(forKey: "advisoryWebResearchLookbackDays")
            return value > 0 ? value : 3
        }
        set { defaults.set(newValue, forKey: "advisoryWebResearchLookbackDays") }
    }

    var advisoryEnabledDomains: [AdvisoryDomain] {
        get {
            let v1DefaultDomains: [AdvisoryDomain] = [.continuity, .writingExpression]
            let stored = readList(forKey: "advisoryEnabledDomains", defaultValue: v1DefaultDomains.map(\.rawValue))
            let domains = stored.compactMap(AdvisoryDomain.init(rawValue:))
            return domains.isEmpty ? v1DefaultDomains : domains
        }
        set {
            let rawValues = newValue.isEmpty ? AdvisoryDomain.allCases.map(\.rawValue) : newValue.map(\.rawValue)
            writeList(rawValues, forKey: "advisoryEnabledDomains")
        }
    }

    var advisoryPreferredLanguage: String {
        get { defaults.string(forKey: "advisoryPreferredLanguage") ?? "ru" }
        set { defaults.set(newValue, forKey: "advisoryPreferredLanguage") }
    }

    var advisoryWritingStyle: String {
        get { defaults.string(forKey: "advisoryWritingStyle") ?? "concise_reflective" }
        set { defaults.set(newValue, forKey: "advisoryWritingStyle") }
    }

    var advisoryTwitterVoiceExamples: [String] {
        get { readList(forKey: "advisoryTwitterVoiceExamples", defaultValue: []) }
        set { writeList(newValue, forKey: "advisoryTwitterVoiceExamples") }
    }

    var advisoryPreferredAngles: [String] {
        get { readList(forKey: "advisoryPreferredAngles", defaultValue: ["observation", "question", "lesson_learned", "mini_framework"]) }
        set { writeList(newValue, forKey: "advisoryPreferredAngles") }
    }

    var advisoryAvoidTopics: [String] {
        get { readList(forKey: "advisoryAvoidTopics", defaultValue: []) }
        set { writeList(newValue, forKey: "advisoryAvoidTopics") }
    }

    var advisoryContentPersonaDescription: String {
        get {
            defaults.string(forKey: "advisoryContentPersonaDescription")
                ?? "Grounded builder voice. Specific, observant, compact, and evidence-led."
        }
        set { defaults.set(newValue, forKey: "advisoryContentPersonaDescription") }
    }

    var advisoryAllowProvocation: Bool {
        get { defaults.bool(forKey: "advisoryAllowProvocation") }
        set { defaults.set(newValue, forKey: "advisoryAllowProvocation") }
    }

    var guidanceProfile: GuidanceProfile {
        GuidanceProfile(
            language: advisoryPreferredLanguage,
            toneMode: "non_directive",
            assertivenessLevel: 0.35,
            allowProactiveAdvice: advisoryEnabled && advisoryProactivityMode == .ambient,
            proactivityMode: advisoryProactivityMode,
            dailyAttentionBudget: advisoryDailyAttentionBudget,
            hardDailyCap: 4,
            minGapMinutes: advisoryMinGapMinutes,
            perThreadCooldownHours: advisoryPerThreadCooldownHours,
            perKindFatigueCooldownHours: 3,
            writingStyle: advisoryWritingStyle,
            allowScreenshotEscalation: advisoryAllowScreenshotEscalation,
            allowExternalCLIProviders: networkAllowed,
            allowMCPEnrichment: advisoryAllowMCPEnrichment,
            enrichmentPhase: advisoryEnrichmentPhase,
            enabledEnrichmentSources: advisoryEnabledEnrichmentSources(
                phase: advisoryEnrichmentPhase,
                allowMCP: advisoryAllowMCPEnrichment
            ),
            enabledDomains: advisoryEnabledDomains,
            attentionMarketMode: "multi_polar_attention_market",
            twitterVoiceExamples: advisoryTwitterVoiceExamples,
            preferredAngles: advisoryPreferredAngles,
            avoidTopics: advisoryAvoidTopics,
            contentPersonaDescription: advisoryContentPersonaDescription,
            allowProvocation: advisoryAllowProvocation
        )
    }

    private func advisoryEnabledEnrichmentSources(
        phase: AdvisoryEnrichmentPhase,
        allowMCP: Bool
    ) -> [AdvisoryEnrichmentSource] {
        AdvisoryEnrichmentSource.allCases.filter {
            advisoryEnrichmentSourceEnabled($0, phase: phase, allowMCP: allowMCP)
        }
    }

    func advisoryEnrichmentSourceEnabled(
        _ source: AdvisoryEnrichmentSource,
        phase: AdvisoryEnrichmentPhase? = nil,
        allowMCP: Bool? = nil
    ) -> Bool {
        if source == .notes {
            return true
        }
        let effectiveAllowMCP = allowMCP ?? advisoryAllowMCPEnrichment
        guard effectiveAllowMCP else {
            return false
        }
        let effectivePhase = phase ?? advisoryEnrichmentPhase
        guard effectivePhase.supports(source) else {
            return false
        }
        switch source {
        case .notes:
            return true
        case .calendar:
            return advisoryCalendarEnrichmentEnabled
        case .reminders:
            return advisoryRemindersEnrichmentEnabled
        case .webResearch:
            return advisoryWebResearchEnrichmentEnabled
        case .wearable:
            return advisoryWearableEnrichmentEnabled
        }
    }

    // MARK: - Prompts (editable by user)

    static let defaultSystemPrompt = """
    You are an expert personal knowledge management analyst creating detailed activity reports \
    for Obsidian. Use [[wiki-links]] only for durable entities that should persist in the knowledge base: \
    projects, tools, people, AI models, recurring issues, lessons, and important topics. \
    Do not link every noun or generic phrase. Prefer precise, evidence-based links over volume. \
    Quote actual screen content when useful. \
    Write in the user's language (Russian if content is in Russian).
    """

    var systemPrompt: String {
        get { defaults.string(forKey: "systemPrompt") ?? Self.defaultSystemPrompt }
        set { defaults.set(newValue, forKey: "systemPrompt") }
    }

    static let defaultUserPromptSuffix = """
    CRITICAL: Use [[wiki-links]] only for durable entities worth keeping in the knowledge graph.
    Avoid linking generic words, duplicate aliases, and one-off noise.

    ## Summary
    (5-7 detailed sentences, specifically WHAT was done, what code, what settings)

    ## Детальный таймлайн
    (every 10-20 min block, quote screen content when helpful)

    ## Проекты и код
    (each project separately, what was done, files, commands, use [[wiki-links]] only for stable entities)

    ## Инструменты и технологии
    (list the important tools and technologies that actually mattered in this window)

    ## Что изучал / читал
    (specific topics, sites, docs, link only the meaningful recurring entities)

    ## AI-взаимодействие
    (which AI models, which tasks, use [[wiki-links]] for the models and platforms)

    ## Граф связей
    (how topics/projects/tools are connected: [[A]] → [[B]] → [[C]])

    ## Предлагаемые заметки
    - [[Topic]] — specific reason to create a note
    (only notes that are worth keeping long-term)

    ## Продолжить далее
    (unfinished tasks with [[wiki-links]])
    """

    var userPromptSuffix: String {
        get { defaults.string(forKey: "userPromptSuffix") ?? Self.defaultUserPromptSuffix }
        set { defaults.set(newValue, forKey: "userPromptSuffix") }
    }

    func forgetCredentials() {
        credentialsStore.removeValue(for: "externalAPIKey")
        legacyCredentialsStore.removeValue(for: "externalAPIKey")
        defaults.set(false, forKey: Self.hasExternalAPIKeyKey)
    }

    private func migrateLegacyCredentialsIfNeeded() {
        guard let legacyKey = defaults.string(forKey: "openRouterApiKey"),
              !legacyKey.isEmpty else {
            return
        }

        if !credentialsStore.hasValue(for: "externalAPIKey") {
            credentialsStore.set(legacyKey, for: "externalAPIKey")
        }
        defaults.set(true, forKey: Self.hasExternalAPIKeyKey)
        defaults.removeObject(forKey: "openRouterApiKey")
    }

    private func migrateAwayFromKeychainIfNeeded() {
        guard !defaults.bool(forKey: Self.migratedOffKeychainKey) else {
            return
        }

        let storedLocalValue = credentialsStore
            .string(for: "externalAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if storedLocalValue.isEmpty,
           let legacyValue = legacyCredentialsStore
            .string(for: "externalAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !legacyValue.isEmpty {
            credentialsStore.set(legacyValue, for: "externalAPIKey")
            defaults.set(true, forKey: Self.hasExternalAPIKeyKey)
        } else if storedLocalValue.isEmpty {
            defaults.set(false, forKey: Self.hasExternalAPIKeyKey)
        }

        legacyCredentialsStore.removeValue(for: "externalAPIKey")
        defaults.set(true, forKey: Self.migratedOffKeychainKey)
    }

    private func migrateExperimentalAudioOptInIfNeeded() {
        guard defaults.object(forKey: Self.experimentalAudioOptInConfirmedKey) == nil else {
            return
        }

        let hadExperimentalAudioEnabled =
            defaults.bool(forKey: "microphoneCaptureEnabled")
            || defaults.bool(forKey: "systemAudioCaptureEnabled")

        if hadExperimentalAudioEnabled {
            defaults.set(false, forKey: "microphoneCaptureEnabled")
            defaults.set(false, forKey: "systemAudioCaptureEnabled")
        }

        defaults.set(false, forKey: Self.experimentalAudioOptInConfirmedKey)
    }
    private func nonZeroDouble(forKey key: String, defaultValue: Double) -> Double {
        let value = defaults.double(forKey: key)
        return value > 0 ? value : defaultValue
    }

    private func readList(forKey key: String, defaultValue: [String]) -> [String] {
        guard let stored = defaults.string(forKey: key),
              !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultValue
        }

        return stored
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func writeList(_ values: [String], forKey key: String) {
        defaults.set(values.joined(separator: "\n"), forKey: key)
    }

    private func readCodableArray<T: Decodable>(forKey key: String) -> [T] {
        guard let stored = defaults.string(forKey: key),
              let data = stored.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([T].self, from: data) else {
            return []
        }
        return decoded
    }

    private func writeCodableArray<T: Encodable>(_ values: [T], forKey key: String) {
        guard let data = try? JSONEncoder().encode(values),
              let string = String(data: data, encoding: .utf8) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(string, forKey: key)
    }
}
