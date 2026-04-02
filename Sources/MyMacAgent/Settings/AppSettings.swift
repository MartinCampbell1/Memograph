import Foundation

struct AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - API

    var openRouterApiKey: String {
        get { defaults.string(forKey: "openRouterApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "openRouterApiKey") }
    }

    var llmModel: String {
        get { defaults.string(forKey: "llmModel") ?? "minimax/minimax-m2.7" }
        set { defaults.set(newValue, forKey: "llmModel") }
    }

    var hasApiKey: Bool { !openRouterApiKey.isEmpty }

    // MARK: - Obsidian

    var obsidianVaultPath: String {
        get { defaults.string(forKey: "obsidianVaultPath")
              ?? NSHomeDirectory() + "/Documents/MyMacAgentVault" }
        set { defaults.set(newValue, forKey: "obsidianVaultPath") }
    }

    // MARK: - Capture

    var maxPromptChars: Int {
        get {
            let val = defaults.integer(forKey: "maxPromptChars")
            return val > 0 ? val : 300_000
        }
        set { defaults.set(newValue, forKey: "maxPromptChars") }
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

    // MARK: - OCR

    var ollamaModelName: String {
        get { defaults.string(forKey: "ollamaModelName") ?? "glm-ocr" }
        set { defaults.set(newValue, forKey: "ollamaModelName") }
    }

    var ollamaBaseURL: String {
        get { defaults.string(forKey: "ollamaBaseURL") ?? "http://localhost:11434" }
        set { defaults.set(newValue, forKey: "ollamaBaseURL") }
    }

    // MARK: - Vision (screenshot analysis — local by default for privacy)

    var visionModel: String {
        get { defaults.string(forKey: "visionModel") ?? "qwen3.5:4b" }
        set { defaults.set(newValue, forKey: "visionModel") }
    }

    var visionProvider: String {
        get { defaults.string(forKey: "visionProvider") ?? "ollama" }
        set { defaults.set(newValue, forKey: "visionProvider") }
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
}
