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

        let settings2 = AppSettings(defaults: defaults, credentialsStore: store)
        #expect(settings2.obsidianVaultPath == "/Users/test/vault")
        #expect(settings2.openRouterApiKey == "sk-test-123")
        #expect(settings2.retentionDays == 14)
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
