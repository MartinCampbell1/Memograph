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
        #expect(settings.maxCapturesPerSession == 500)
    }

    @Test("Set and get values")
    func setAndGet() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.obsidianVaultPath = "/Users/test/vault"
        settings.openRouterApiKey = "sk-test-123"
        settings.retentionDays = 14
        settings.knowledgeMaintenanceIntervalHours = 12
        settings.lastKnowledgeMaintenanceAt = "2026-04-03T12:00:00Z"
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
        #expect(settings2.knowledgeMaintenanceIntervalHours == 12)
        #expect(settings2.lastKnowledgeMaintenanceAt == "2026-04-03T12:00:00Z")
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
