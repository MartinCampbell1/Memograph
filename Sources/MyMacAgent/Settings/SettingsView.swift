import SwiftUI

struct SettingsView: View {
    @State private var apiKey = ""
    @State private var llmModel = ""
    @State private var vaultPath = ""
    @State private var retentionDays = ""
    @State private var summaryInterval = ""
    @State private var maxPromptChars = ""
    @State private var ollamaModel = ""
    @State private var visionModel = ""
    @State private var visionProvider = ""
    @State private var systemPrompt = ""
    @State private var userPromptSuffix = ""
    @State private var selectedTab = 0
    @State private var saved = false

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gear") }
                .tag(0)

            promptsTab
                .tabItem { Label("Prompts", systemImage: "text.bubble") }
                .tag(1)

            captureTab
                .tabItem { Label("Capture", systemImage: "camera") }
                .tag(2)
        }
        .padding()
        .frame(minWidth: 550, minHeight: 500)
        .onAppear { loadSettings() }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("OpenRouter API") {
                SecureField("API Key", text: $apiKey)
                TextField("Model", text: $llmModel)
                Text("e.g. minimax/minimax-m2.7, anthropic/claude-3-haiku")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section("Obsidian") {
                HStack {
                    TextField("Vault Path", text: $vaultPath)
                    Button("Browse") { browseFolder() }
                }
            }

            Section("OCR (Ollama)") {
                TextField("OCR Model", text: $ollamaModel)
                Text("e.g. glm-ocr, minicpm-v, llava")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section("Screenshot Analysis") {
                Picker("Provider", selection: $visionProvider) {
                    Text("Local (Ollama) — private").tag("ollama")
                    Text("Cloud (Gemini) — better quality").tag("cloud")
                }
                .pickerStyle(.segmented)
                TextField("Vision Model", text: $visionModel)
                Text("Local: qwen3.5:4b | Cloud: uses Summary model above")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section("Retention") {
                HStack {
                    Text("Keep data for")
                    TextField("", text: $retentionDays).frame(width: 50)
                    Text("days")
                }
            }

            saveButton
        }
    }

    // MARK: - Prompts

    private var promptsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Prompt")
                .font(.headline)
            Text("Instructions for the LLM about how to analyze your activity")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .border(Color.gray.opacity(0.3))

            Divider()

            Text("Summary Format")
                .font(.headline)
            Text("Template that tells the LLM what sections to generate")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $userPromptSuffix)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .border(Color.gray.opacity(0.3))

            HStack {
                Button("Reset to Defaults") { resetPrompts() }
                    .foregroundStyle(.red)
                Spacer()
                saveButton
            }
        }
        .padding()
    }

    // MARK: - Capture

    private var captureTab: some View {
        Form {
            Section("Auto-Summary") {
                HStack {
                    Text("Generate summary every")
                    TextField("", text: $summaryInterval).frame(width: 50)
                    Text("minutes")
                }
                Text("Summary is generated only when you are active (not idle)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            Section("Context Budget") {
                HStack {
                    Text("Max prompt size")
                    TextField("", text: $maxPromptChars).frame(width: 80)
                    Text("characters")
                }
                Text("How much OCR text to send to the LLM per summary (~4 chars = 1 token)")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            saveButton
        }
    }

    // MARK: - Actions

    private var saveButton: some View {
        HStack {
            Spacer()
            if saved {
                Text("Saved!").foregroundStyle(.green)
            }
            Button("Save") { saveSettings() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func loadSettings() {
        let s = AppSettings()
        apiKey = s.openRouterApiKey
        llmModel = s.llmModel
        vaultPath = s.obsidianVaultPath
        retentionDays = String(s.retentionDays)
        summaryInterval = String(s.summaryIntervalMinutes)
        maxPromptChars = String(s.maxPromptChars)
        ollamaModel = s.ollamaModelName
        visionModel = s.visionModel
        visionProvider = s.visionProvider
        systemPrompt = s.systemPrompt
        userPromptSuffix = s.userPromptSuffix
    }

    private func saveSettings() {
        var s = AppSettings()
        s.openRouterApiKey = apiKey
        s.llmModel = llmModel
        s.obsidianVaultPath = vaultPath
        s.retentionDays = Int(retentionDays) ?? 30
        s.summaryIntervalMinutes = Int(summaryInterval) ?? 60
        s.maxPromptChars = Int(maxPromptChars) ?? 300_000
        s.ollamaModelName = ollamaModel
        s.visionModel = visionModel
        s.visionProvider = visionProvider
        s.systemPrompt = systemPrompt
        s.userPromptSuffix = userPromptSuffix
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }

    private func resetPrompts() {
        systemPrompt = AppSettings.defaultSystemPrompt
        userPromptSuffix = AppSettings.defaultUserPromptSuffix
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose your Obsidian vault folder"
        if panel.runModal() == .OK, let url = panel.url {
            vaultPath = url.path
        }
    }
}
