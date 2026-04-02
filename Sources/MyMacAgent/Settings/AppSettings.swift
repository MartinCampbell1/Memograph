import Foundation

struct AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var obsidianVaultPath: String {
        get { defaults.string(forKey: "obsidianVaultPath")
              ?? NSHomeDirectory() + "/Documents/MyMacAgentVault" }
        set { defaults.set(newValue, forKey: "obsidianVaultPath") }
    }

    var openRouterApiKey: String {
        get { defaults.string(forKey: "openRouterApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "openRouterApiKey") }
    }

    var llmModel: String {
        get { defaults.string(forKey: "llmModel") ?? "anthropic/claude-3-haiku" }
        set { defaults.set(newValue, forKey: "llmModel") }
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

    var hasApiKey: Bool { !openRouterApiKey.isEmpty }
}
