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

    // MARK: - Prompts (editable by user)

    static let defaultSystemPrompt = """
    You are an expert personal knowledge management analyst creating EXTREMELY detailed \
    daily reports with extensive [[wiki-links]] for Obsidian knowledge graph. \
    Every project, tool, technology, person, AI model, concept MUST be wrapped in [[double brackets]]. \
    The more [[wiki-links]] the better — the knowledge graph must grow with every report. \
    Be specific and evidence-based. Quote actual screen content. \
    Write in the user's language (Russian if content is in Russian).
    """

    var systemPrompt: String {
        get { defaults.string(forKey: "systemPrompt") ?? Self.defaultSystemPrompt }
        set { defaults.set(newValue, forKey: "systemPrompt") }
    }

    static let defaultUserPromptSuffix = """
    CRITICAL: Wrap EVERY mention of projects, tools, technologies, people, AI models in [[wiki-links]].

    ## Summary
    (5-7 detailed sentences with [[wiki-links]], specifically WHAT was done, what code, what settings)

    ## Детальный таймлайн
    (every 10-20 min block, with [[wiki-links]], quote screen content)

    ## Проекты и код
    (each project separately, what was done, files, commands, with [[wiki-links]])

    ## Инструменты и технологии
    (full list of everything used, each as [[wiki-link]])

    ## Что изучал / читал
    (specific topics, sites, docs, with [[wiki-links]])

    ## AI-взаимодействие
    (which AI models, which tasks, with [[wiki-links]])

    ## Граф связей
    (how topics/projects/tools are connected: [[A]] → [[B]] → [[C]])

    ## Предлагаемые заметки
    - [[Topic]] — specific reason to create a note
    (minimum 10 notes)

    ## Продолжить завтра
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
}
