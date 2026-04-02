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

    // MARK: - Prompts (editable by user)

    static let defaultSystemPrompt = """
    You are a personal knowledge management assistant analyzing computer activity logs.
    You receive timestamped sessions with full OCR text extracted from screenshots,
    window titles, and app metadata.

    Your job:
    1. Understand what the user actually DID based on the content (code, documents, chats)
    2. Extract topics and knowledge worth preserving
    3. Identify patterns (focus blocks, distractions, AI usage)
    4. Build on previous context — don't repeat what was already summarized
    5. Create useful [[wiki-links]] that connect to concepts, not just app names

    Be specific and evidence-based. Quote actual content when relevant.
    Write in the user's language (Russian if their content is in Russian).
    """

    var systemPrompt: String {
        get { defaults.string(forKey: "systemPrompt") ?? Self.defaultSystemPrompt }
        set { defaults.set(newValue, forKey: "systemPrompt") }
    }

    static let defaultUserPromptSuffix = """
    Based on ALL the data above (app names, window titles, full OCR text, code, documents):

    ## Summary
    Write 2-4 sentences about what the user accomplished today. Be specific — mention actual code, documents, topics they worked on.

    ## Main topics
    - List every distinct topic/project/task (bullet list)
    - Include programming languages, frameworks, tools used
    - Note if the user was in AI chats (ChatGPT, Claude, etc.)

    ## AI sessions
    - List any AI assistant interactions detected
    - What were they asking about?

    ## Distractions
    - Note any context-switching patterns
    - Social media or messaging breaks

    ## Suggested notes
    - [[Wiki Link Name]] for each topic worth creating a note about

    ## Continue tomorrow
    - What was the user working on when the day ended?
    - Any unfinished tasks visible in the content?
    """

    var userPromptSuffix: String {
        get { defaults.string(forKey: "userPromptSuffix") ?? Self.defaultUserPromptSuffix }
        set { defaults.set(newValue, forKey: "userPromptSuffix") }
    }
}
