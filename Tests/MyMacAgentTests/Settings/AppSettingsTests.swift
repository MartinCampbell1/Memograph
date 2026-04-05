import Testing
import Foundation
@testable import MyMacAgent

struct AppSettingsTests {
    @Test("Default values")
    func defaults() {
        let store = InMemoryCredentialsStore()
        let settings = AppSettings(
            defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!,
            credentialsStore: store
        )
        #expect(settings.obsidianVaultPath.contains("MyMacAgentVault"))
        #expect(settings.openRouterApiKey.isEmpty)
        #expect(settings.llmModel == "minimax/minimax-m2.7")
        #expect(settings.retentionDays == 30)
        #expect(settings.knowledgeMaintenanceIntervalHours == 24)
        #expect(settings.lastKnowledgeMaintenanceAt == nil)
        #expect(settings.knowledgeSuppressedEntityIds.isEmpty)
        #expect(settings.knowledgeAppliedActions.isEmpty)
        #expect(settings.knowledgeMergeOverlays.isEmpty)
        #expect(settings.knowledgeAliasOverrides.isEmpty)
        #expect(settings.knowledgeReviewDecisions.isEmpty)
        #expect(settings.audioTranscriptionProvider == .localWhisper)
        #expect(settings.audioTranscriptionBaseURL == "https://api.openai.com/v1")
        #expect(settings.audioMicrophoneModel == "gpt-4o-transcribe")
        #expect(settings.audioSystemModel == "gpt-4o-mini-transcribe")
        #expect(settings.audioTranscriptionAPIKey.isEmpty)
        #expect(settings.maxCapturesPerSession == 500)
        #expect(settings.advisoryEnabled)
        #expect(settings.advisoryAccessProfile == .deepContext)
        #expect(settings.advisoryProactivityMode == .ambient)
        #expect(settings.advisoryBridgeMode == .preferSidecar)
        #expect(settings.advisorySidecarAutoStart)
        #expect(settings.advisorySidecarSocketPath.contains("memograph-advisor.sock"))
        #expect(settings.advisorySidecarTimeoutSeconds == 20)
        #expect(settings.advisorySidecarHealthCheckIntervalSeconds == 30)
        #expect(settings.advisorySidecarMaxConsecutiveFailures == 3)
        #expect(settings.advisorySidecarProviderOrder == ["claude", "gemini", "codex"])
        #expect(settings.advisorySidecarProviderProbeTimeoutSeconds == 6)
        #expect(settings.advisorySidecarRetryAttempts == 2)
        #expect(settings.advisorySidecarProviderCooldownSeconds == 60)
        #expect(settings.advisoryCLIProfilesPath.contains(".cli-profiles"))
        #expect(settings.advisorySelectedClaudeAccount.isEmpty)
        #expect(settings.advisorySelectedGeminiAccount.isEmpty)
        #expect(settings.advisorySelectedCodexAccount.isEmpty)
        #expect(settings.advisoryDailyAttentionBudget == 6)
        #expect(settings.advisoryMinGapMinutes == 45)
        #expect(settings.advisoryPerThreadCooldownHours == 6)
        #expect(settings.advisoryEnrichmentPhase == .phase1Memograph)
        #expect(settings.advisoryCalendarEnrichmentEnabled)
        #expect(settings.advisoryRemindersEnrichmentEnabled)
        #expect(settings.advisoryWebResearchEnrichmentEnabled)
        #expect(settings.advisoryWearableEnrichmentEnabled)
        #expect(settings.advisoryEnrichmentMaxItemsPerSource == 3)
        #expect(settings.advisoryCalendarLookaheadHours == 18)
        #expect(settings.advisoryReminderHorizonDays == 7)
        #expect(settings.advisoryWebResearchLookbackDays == 3)
        #expect(settings.advisoryPreferredLanguage == "ru")
        #expect(settings.advisoryWritingStyle == "concise_reflective")
        #expect(settings.advisoryTwitterVoiceExamples.isEmpty)
        #expect(settings.advisoryAvoidTopics.isEmpty)
        #expect(settings.advisoryContentPersonaDescription.contains("Grounded builder voice"))
        #expect(settings.advisoryEnabledDomains == AdvisoryDomain.allCases)
        #expect(settings.guidanceProfile.enabledDomains == AdvisoryDomain.allCases)
        #expect(settings.guidanceProfile.enrichmentPhase == .phase1Memograph)
        #expect(settings.guidanceProfile.enabledEnrichmentSources == [.notes])
        #expect(settings.guidanceProfile.attentionMarketMode == "multi_polar_attention_market")
        #expect(settings.guidanceProfile.preferredAngles == ["observation", "question", "lesson_learned", "mini_framework"])
        #expect(settings.guidanceProfile.contentPersonaDescription.contains("Grounded builder voice"))
        #expect(!settings.guidanceProfile.allowProvocation)
    }

    @Test("Set and get values")
    func setAndGet() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.obsidianVaultPath = "/Users/test/vault"
        settings.openRouterApiKey = "sk-test-123"
        settings.retentionDays = 14
        settings.audioTranscriptionProvider = .localWhisper
        settings.audioTranscriptionBaseURL = "https://api.openai.com/v1"
        settings.audioTranscriptionAPIKey = "sk-audio-123"
        settings.audioMicrophoneModel = "gpt-4o-transcribe"
        settings.audioSystemModel = "gpt-4o-mini-transcribe"
        settings.knowledgeMaintenanceIntervalHours = 12
        settings.lastKnowledgeMaintenanceAt = "2026-04-03T12:00:00Z"
        settings.advisoryEnabled = false
        settings.advisoryAccessProfile = .balanced
        settings.advisoryProactivityMode = .manualOnly
        settings.advisoryBridgeMode = .requireSidecar
        settings.advisorySidecarAutoStart = false
        settings.advisorySidecarSocketPath = "/tmp/memograph-test.sock"
        settings.advisorySidecarTimeoutSeconds = 12
        settings.advisorySidecarHealthCheckIntervalSeconds = 15
        settings.advisorySidecarMaxConsecutiveFailures = 5
        settings.advisorySidecarProviderOrder = ["gemini", "codex"]
        settings.advisorySidecarProviderProbeTimeoutSeconds = 9
        settings.advisorySidecarRetryAttempts = 4
        settings.advisorySidecarProviderCooldownSeconds = 90
        settings.advisoryCLIProfilesPath = "/Users/test/.cli-profiles"
        settings.advisorySelectedClaudeAccount = "acc2"
        settings.advisorySelectedGeminiAccount = "acc3"
        settings.advisorySelectedCodexAccount = "acc1"
        settings.advisoryDailyAttentionBudget = 4
        settings.advisoryMinGapMinutes = 30
        settings.advisoryPerThreadCooldownHours = 8
        settings.advisoryAllowScreenshotEscalation = false
        settings.advisoryAllowMCPEnrichment = true
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryCalendarEnrichmentEnabled = false
        settings.advisoryRemindersEnrichmentEnabled = true
        settings.advisoryWebResearchEnrichmentEnabled = false
        settings.advisoryWearableEnrichmentEnabled = false
        settings.advisoryEnrichmentMaxItemsPerSource = 5
        settings.advisoryCalendarLookaheadHours = 12
        settings.advisoryReminderHorizonDays = 4
        settings.advisoryWebResearchLookbackDays = 2
        settings.advisoryEnabledDomains = [.continuity, .research, .decisions]
        settings.advisoryPreferredLanguage = "ru"
        settings.advisoryWritingStyle = "compressed"
        settings.advisoryTwitterVoiceExamples = ["Short grounded post", "Concrete observation thread"]
        settings.advisoryPreferredAngles = ["contrarian_take", "mini_framework"]
        settings.advisoryAvoidTopics = ["growth hacks"]
        settings.advisoryContentPersonaDescription = "Builder with sharp angles."
        settings.advisoryAllowProvocation = true
        settings.knowledgeSuppressedEntityIds = ["entity-2", "entity-1", "entity-1"]
        settings.knowledgeAppliedActions = [
            KnowledgeAppliedActionRecord(
                appliedAt: "2026-04-04T10:33:00Z",
                kind: .lessonPromotion,
                title: "Codex Workflow for AI Founders",
                sourceEntityId: "entity-1",
                applyTargetRelativePath: "Lessons/codex-workflow-for-ai-founders.md",
                appliedPath: "/Users/test/vault/Knowledge/Lessons/codex-workflow-for-ai-founders.md"
            )
        ]
        settings.knowledgeMergeOverlays = [
            KnowledgeMergeOverlayRecord(
                appliedAt: "2026-04-04T10:33:00Z",
                sourceEntityId: "topic-ocr-accuracy",
                sourceTitle: "OCR Accuracy in Memograph",
                sourceAliases: ["OCR Accuracy in Memograph"],
                sourceOverview: "Narrow OCR tuning context.",
                preservedSignals: ["Focused in 1 summary window."],
                targetEntityId: "topic-ocr",
                targetTitle: "OCR",
                targetRelativePath: "Topics/ocr.md"
            )
        ]
        settings.knowledgeAliasOverrides = [
            KnowledgeAliasOverrideRecord(
                sourceName: "OCR Accuracy in Memograph",
                canonicalName: "OCR",
                entityType: .topic,
                reason: "mergeOverlay",
                appliedAt: "2026-04-04T10:33:00Z"
            )
        ]
        settings.knowledgeReviewDecisions = [
            KnowledgeReviewDecisionRecord(
                key: "reclassify:topic-1",
                kind: .promoteToLesson,
                status: .dismiss,
                title: "Review Packet — Reclassify SQLite Optimization for Memograph",
                path: "/Users/test/vault/Knowledge/_drafts/Review/reclassify-sqlite-optimization-for-memograph.md",
                recordedAt: "2026-04-04T11:00:00Z"
            )
        ]

        let settings2 = AppSettings(defaults: defaults, credentialsStore: store)
        #expect(settings2.obsidianVaultPath == "/Users/test/vault")
        #expect(settings2.openRouterApiKey == "sk-test-123")
        #expect(settings2.retentionDays == 14)
        #expect(settings2.audioTranscriptionProvider == .localWhisper)
        #expect(settings2.audioTranscriptionBaseURL == "https://api.openai.com/v1")
        #expect(settings2.audioTranscriptionAPIKey == "sk-audio-123")
        #expect(settings2.audioMicrophoneModel == "gpt-4o-transcribe")
        #expect(settings2.audioSystemModel == "gpt-4o-mini-transcribe")
        #expect(settings2.knowledgeMaintenanceIntervalHours == 12)
        #expect(settings2.lastKnowledgeMaintenanceAt == "2026-04-03T12:00:00Z")
        #expect(!settings2.advisoryEnabled)
        #expect(settings2.advisoryAccessProfile == .balanced)
        #expect(settings2.advisoryProactivityMode == .manualOnly)
        #expect(settings2.advisoryBridgeMode == .requireSidecar)
        #expect(!settings2.advisorySidecarAutoStart)
        #expect(settings2.advisorySidecarSocketPath == "/tmp/memograph-test.sock")
        #expect(settings2.advisorySidecarTimeoutSeconds == 12)
        #expect(settings2.advisorySidecarHealthCheckIntervalSeconds == 15)
        #expect(settings2.advisorySidecarMaxConsecutiveFailures == 5)
        #expect(settings2.advisorySidecarProviderOrder == ["gemini", "codex"])
        #expect(settings2.advisorySidecarProviderProbeTimeoutSeconds == 9)
        #expect(settings2.advisorySidecarRetryAttempts == 4)
        #expect(settings2.advisorySidecarProviderCooldownSeconds == 90)
        #expect(settings2.advisoryCLIProfilesPath == "/Users/test/.cli-profiles")
        #expect(settings2.advisorySelectedClaudeAccount == "acc2")
        #expect(settings2.advisorySelectedGeminiAccount == "acc3")
        #expect(settings2.advisorySelectedCodexAccount == "acc1")
        #expect(settings2.advisoryDailyAttentionBudget == 4)
        #expect(settings2.advisoryMinGapMinutes == 30)
        #expect(settings2.advisoryPerThreadCooldownHours == 8)
        #expect(!settings2.advisoryAllowScreenshotEscalation)
        #expect(settings2.advisoryAllowMCPEnrichment)
        #expect(settings2.advisoryEnrichmentPhase == .phase2ReadOnly)
        #expect(!settings2.advisoryCalendarEnrichmentEnabled)
        #expect(settings2.advisoryRemindersEnrichmentEnabled)
        #expect(!settings2.advisoryWebResearchEnrichmentEnabled)
        #expect(!settings2.advisoryWearableEnrichmentEnabled)
        #expect(settings2.advisoryEnrichmentMaxItemsPerSource == 5)
        #expect(settings2.advisoryCalendarLookaheadHours == 12)
        #expect(settings2.advisoryReminderHorizonDays == 4)
        #expect(settings2.advisoryWebResearchLookbackDays == 2)
        #expect(settings2.advisoryEnabledDomains == [.continuity, .research, .decisions])
        #expect(settings2.guidanceProfile.enabledEnrichmentSources == [.notes, .reminders])
        #expect(settings2.advisoryWritingStyle == "compressed")
        #expect(settings2.advisoryTwitterVoiceExamples == ["Short grounded post", "Concrete observation thread"])
        #expect(settings2.advisoryPreferredAngles == ["contrarian_take", "mini_framework"])
        #expect(settings2.advisoryAvoidTopics == ["growth hacks"])
        #expect(settings2.advisoryContentPersonaDescription == "Builder with sharp angles.")
        #expect(settings2.advisoryAllowProvocation)
        #expect(settings2.knowledgeSuppressedEntityIds == ["entity-1", "entity-2"])
        #expect(settings2.knowledgeAppliedActions.count == 1)
        #expect(settings2.knowledgeAppliedActions.first?.kind == .lessonPromotion)
        #expect(settings2.knowledgeAppliedActions.first?.title == "Codex Workflow for AI Founders")
        #expect(settings2.knowledgeMergeOverlays.count == 1)
        #expect(settings2.knowledgeMergeOverlays.first?.targetTitle == "OCR")
        #expect(settings2.knowledgeAliasOverrides.count == 1)
        #expect(settings2.knowledgeAliasOverrides.first?.canonicalName == "OCR")
        #expect(settings2.knowledgeReviewDecisions.count == 1)
        #expect(settings2.knowledgeReviewDecisions.first?.status == .dismiss)
        #expect(settings2.knowledgeReviewDecisions.first?.recordedAt == "2026-04-04T11:00:00Z")
    }

    @Test("Default credentials storage persists locally without Keychain")
    func persistsInLocalSettingsStore() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let legacyStore = InMemoryCredentialsStore()

        var settings = AppSettings(defaults: defaults, legacyCredentialsStore: legacyStore)
        settings.openRouterApiKey = "sk-local-123"

        let settings2 = AppSettings(defaults: defaults, legacyCredentialsStore: legacyStore)
        #expect(settings2.openRouterApiKey == "sk-local-123")
        #expect(settings2.hasApiKey)
    }

    @Test("hasApiKey returns true when key is set")
    func hasApiKey() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        #expect(!settings.hasApiKey)
        settings.openRouterApiKey = "sk-test"
        #expect(settings.hasApiKey)
    }

    @Test("hasApiKey detects stored credentials without reading the secret")
    func hasApiKeyWithoutRead() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let store = InMemoryCredentialsStore()
        store.set("sk-test", for: "externalAPIKey")

        let settings = AppSettings(defaults: defaults, credentialsStore: store)

        #expect(settings.hasApiKey)
        #expect(defaults.bool(forKey: "hasExternalAPIKey"))
    }

    @Test("Audio transcription key persists separately from summary provider key")
    func audioTranscriptionApiKeyPersistsSeparately() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.openRouterApiKey = "sk-summary"
        settings.audioTranscriptionAPIKey = "sk-audio"

        let loaded = AppSettings(defaults: defaults, credentialsStore: store)
        #expect(loaded.openRouterApiKey == "sk-summary")
        #expect(loaded.audioTranscriptionAPIKey == "sk-audio")
        #expect(loaded.resolvedAudioTranscriptionAPIKey == "sk-audio")
    }

    @Test("Legacy Keychain value migrates into local settings store")
    func migratesLegacyKeychainValue() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let legacyStore = InMemoryCredentialsStore()
        legacyStore.set("sk-legacy", for: "externalAPIKey")

        let settings = AppSettings(defaults: defaults, legacyCredentialsStore: legacyStore)

        #expect(settings.openRouterApiKey == "sk-legacy")
        #expect(settings.hasApiKey)
        #expect(!legacyStore.hasValue(for: "externalAPIKey"))
    }
}
