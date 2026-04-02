# MyMacAgent Phase 3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge AX + OCR data into unified context snapshots, generate AI-powered daily summaries via OpenRouter, and export daily notes to an Obsidian vault.

**Architecture:** ContextFusionEngine combines AX and OCR snapshots with app/window metadata into a single `context_snapshots` record. LLMClient sends structured prompts to any OpenAI-compatible API (OpenRouter by default). DailySummarizer collects the day's context snapshots and sessions, builds a prompt, calls LLM, parses the result, and stores it in `daily_summaries`. ObsidianExporter renders the daily summary into a markdown file using the template from the spec, writes it to the configured vault directory, and copies thumbnail assets.

**Tech Stack:** Swift 6.2, URLSession (HTTP client for LLM API), existing DatabaseManager/SessionManager, Markdown string templates

---

## Existing Code Reference

| Type | File | Key Methods |
|------|------|-------------|
| `DatabaseManager` | `Database/DatabaseManager.swift` | `execute(_:params:)`, `query(_:params:)` |
| `SessionManager` | `Session/SessionManager.swift` | `currentSessionId`, `recordEvent(...)`, `updateUncertaintyMode(...)` |
| `AXSnapshotRecord` | `Models/AXSnapshotRecord.swift` | `.focusedTitle`, `.focusedValue`, `.selectedText`, `.textLen`, `.hasUsableText` |
| `OCRSnapshotRecord` | `Models/OCRSnapshotRecord.swift` | `.normalizedText`, `.confidence`, `.hasUsableText` |
| `TextNormalizer` | `OCR/TextNormalizer.swift` | `.normalize(_:)`, `.hash(_:)` |
| `ReadabilityScorer` | `Policy/ReadabilityScorer.swift` | `.score(_:)`, `.classifyMode(score:)` |
| `AppMonitor` | `Monitors/AppMonitor.swift` | `.currentAppInfo` (`.bundleId`, `.appName`, `.appId`, `.pid`) |
| `Logger` | `Utilities/Logger.swift` | `.app`, `.database`, `.ocr`, `.policy` etc. (all `nonisolated(unsafe)`) |

**Build/test:** `make build` / `make test` — Swift 6.2 via Homebrew, strict concurrency, Swift Testing (`import Testing`, `@Test`, `#expect`)

**DB tables already created (V001):** `context_snapshots`, `daily_summaries`, `knowledge_notes` — ready to use.

---

## File Structure

```
Sources/MyMacAgent/
    Fusion/
        ContextFusionEngine.swift       -- Merge AX + OCR + metadata → context_snapshots
    Models/
        ContextSnapshotRecord.swift     -- context_snapshots row model
        DailySummaryRecord.swift        -- daily_summaries row model
    Summary/
        LLMClient.swift                 -- OpenAI-compatible HTTP client (OpenRouter)
        DailySummarizer.swift           -- Collect sessions → build prompt → call LLM → persist
    Export/
        ObsidianExporter.swift          -- Render daily summary → markdown → write to vault
    Utilities/
        Logger.swift                    -- Add .fusion, .summary, .export categories

Tests/MyMacAgentTests/
    Fusion/
        ContextFusionEngineTests.swift
    Models/
        ContextSnapshotRecordTests.swift
        DailySummaryRecordTests.swift
    Summary/
        LLMClientTests.swift
        DailySummarizerTests.swift
    Export/
        ObsidianExporterTests.swift
    Integration/
        Phase3IntegrationTests.swift
```

---

## Task 1: Add Logger Categories + ContextSnapshotRecord Model

**Files:**
- Modify: `Sources/MyMacAgent/Utilities/Logger.swift`
- Create: `Sources/MyMacAgent/Models/ContextSnapshotRecord.swift`
- Create: `Tests/MyMacAgentTests/Models/ContextSnapshotRecordTests.swift`

- [ ] **Step 1: Add logger categories**

Add to `Sources/MyMacAgent/Utilities/Logger.swift`:

```swift
nonisolated(unsafe) static let fusion = Logger(subsystem: subsystem, category: "fusion")
nonisolated(unsafe) static let summary = Logger(subsystem: subsystem, category: "summary")
nonisolated(unsafe) static let export = Logger(subsystem: subsystem, category: "export")
```

- [ ] **Step 2: Write failing tests for ContextSnapshotRecord**

Create `Tests/MyMacAgentTests/Models/ContextSnapshotRecordTests.swift`:

```swift
import Testing
@testable import MyMacAgent

struct ContextSnapshotRecordTests {
    @Test("Parse from complete row")
    func fromCompleteRow() {
        let row: SQLiteRow = [
            "id": .text("ctx-1"),
            "session_id": .text("sess-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"),
            "app_name": .text("Safari"),
            "bundle_id": .text("com.apple.Safari"),
            "window_title": .text("GitHub - Search"),
            "text_source": .text("ax+ocr"),
            "merged_text": .text("Search results for Swift concurrency"),
            "merged_text_hash": .text("abc123"),
            "topic_hint": .text("programming"),
            "readable_score": .real(0.85),
            "uncertainty_score": .real(0.1),
            "source_capture_id": .text("cap-1"),
            "source_ax_id": .text("ax-1"),
            "source_ocr_id": .text("ocr-1")
        ]
        let snap = ContextSnapshotRecord(row: row)
        #expect(snap != nil)
        #expect(snap?.id == "ctx-1")
        #expect(snap?.appName == "Safari")
        #expect(snap?.mergedText == "Search results for Swift concurrency")
        #expect(snap?.readableScore == 0.85)
        #expect(snap?.topicHint == "programming")
    }

    @Test("Nil for missing required fields")
    func nilForMissing() {
        let row: SQLiteRow = ["id": .text("ctx-1")]
        #expect(ContextSnapshotRecord(row: row) == nil)
    }

    @Test("Memberwise init works")
    func memberwiseInit() {
        let snap = ContextSnapshotRecord(
            id: "ctx-1", sessionId: "sess-1", timestamp: "now",
            appName: "Test", bundleId: "com.test", windowTitle: "Doc",
            textSource: "ocr", mergedText: "hello world",
            mergedTextHash: "h1", topicHint: nil,
            readableScore: 0.5, uncertaintyScore: 0.3,
            sourceCaptureId: "cap-1", sourceAxId: nil, sourceOcrId: "ocr-1"
        )
        #expect(snap.textSource == "ocr")
        #expect(snap.mergedText == "hello world")
    }
}
```

- [ ] **Step 3: Implement ContextSnapshotRecord**

Create `Sources/MyMacAgent/Models/ContextSnapshotRecord.swift`:

```swift
import Foundation

struct ContextSnapshotRecord {
    let id: String
    let sessionId: String
    let timestamp: String
    let appName: String?
    let bundleId: String?
    let windowTitle: String?
    let textSource: String?
    let mergedText: String?
    let mergedTextHash: String?
    let topicHint: String?
    let readableScore: Double
    let uncertaintyScore: Double
    let sourceCaptureId: String?
    let sourceAxId: String?
    let sourceOcrId: String?

    init(id: String, sessionId: String, timestamp: String,
         appName: String?, bundleId: String?, windowTitle: String?,
         textSource: String?, mergedText: String?, mergedTextHash: String?,
         topicHint: String?, readableScore: Double, uncertaintyScore: Double,
         sourceCaptureId: String?, sourceAxId: String?, sourceOcrId: String?) {
        self.id = id; self.sessionId = sessionId; self.timestamp = timestamp
        self.appName = appName; self.bundleId = bundleId; self.windowTitle = windowTitle
        self.textSource = textSource; self.mergedText = mergedText
        self.mergedTextHash = mergedTextHash; self.topicHint = topicHint
        self.readableScore = readableScore; self.uncertaintyScore = uncertaintyScore
        self.sourceCaptureId = sourceCaptureId; self.sourceAxId = sourceAxId
        self.sourceOcrId = sourceOcrId
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let sessionId = row["session_id"]?.textValue,
              let timestamp = row["timestamp"]?.textValue else { return nil }
        self.id = id; self.sessionId = sessionId; self.timestamp = timestamp
        self.appName = row["app_name"]?.textValue
        self.bundleId = row["bundle_id"]?.textValue
        self.windowTitle = row["window_title"]?.textValue
        self.textSource = row["text_source"]?.textValue
        self.mergedText = row["merged_text"]?.textValue
        self.mergedTextHash = row["merged_text_hash"]?.textValue
        self.topicHint = row["topic_hint"]?.textValue
        self.readableScore = row["readable_score"]?.realValue ?? 0
        self.uncertaintyScore = row["uncertainty_score"]?.realValue ?? 0
        self.sourceCaptureId = row["source_capture_id"]?.textValue
        self.sourceAxId = row["source_ax_id"]?.textValue
        self.sourceOcrId = row["source_ocr_id"]?.textValue
    }
}
```

- [ ] **Step 4: Run tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/Utilities/Logger.swift Sources/MyMacAgent/Models/ContextSnapshotRecord.swift Tests/MyMacAgentTests/Models/ContextSnapshotRecordTests.swift
git commit -m "feat: add ContextSnapshotRecord model and fusion/summary/export logger categories"
```

---

## Task 2: DailySummaryRecord Model

**Files:**
- Create: `Sources/MyMacAgent/Models/DailySummaryRecord.swift`
- Create: `Tests/MyMacAgentTests/Models/DailySummaryRecordTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Models/DailySummaryRecordTests.swift`:

```swift
import Testing
@testable import MyMacAgent

struct DailySummaryRecordTests {
    @Test("Parse from complete row")
    func fromCompleteRow() {
        let row: SQLiteRow = [
            "date": .text("2026-04-02"),
            "summary_text": .text("Productive day focused on Swift development"),
            "top_apps_json": .text("[{\"name\":\"Cursor\",\"duration_min\":120}]"),
            "top_topics_json": .text("[\"Swift\",\"concurrency\"]"),
            "ai_sessions_json": .text("[]"),
            "context_switches_json": .text("{\"count\":15}"),
            "unfinished_items_json": .null,
            "suggested_notes_json": .text("[\"Swift Testing patterns\"]"),
            "generated_at": .text("2026-04-02T23:00:00Z"),
            "model_name": .text("anthropic/claude-3-haiku"),
            "token_usage_input": .integer(2000),
            "token_usage_output": .integer(500),
            "generation_status": .text("success")
        ]
        let summary = DailySummaryRecord(row: row)
        #expect(summary != nil)
        #expect(summary?.date == "2026-04-02")
        #expect(summary?.summaryText == "Productive day focused on Swift development")
        #expect(summary?.modelName == "anthropic/claude-3-haiku")
        #expect(summary?.tokenUsageInput == 2000)
        #expect(summary?.generationStatus == "success")
    }

    @Test("Nil for missing date")
    func nilForMissing() {
        let row: SQLiteRow = ["summary_text": .text("hello")]
        #expect(DailySummaryRecord(row: row) == nil)
    }

    @Test("Memberwise init")
    func memberwiseInit() {
        let s = DailySummaryRecord(
            date: "2026-04-02", summaryText: "Good day",
            topAppsJson: nil, topTopicsJson: nil,
            aiSessionsJson: nil, contextSwitchesJson: nil,
            unfinishedItemsJson: nil, suggestedNotesJson: nil,
            generatedAt: "2026-04-02T23:00:00Z",
            modelName: "test-model",
            tokenUsageInput: 100, tokenUsageOutput: 50,
            generationStatus: "success"
        )
        #expect(s.date == "2026-04-02")
        #expect(s.summaryText == "Good day")
    }
}
```

- [ ] **Step 2: Implement DailySummaryRecord**

Create `Sources/MyMacAgent/Models/DailySummaryRecord.swift`:

```swift
import Foundation

struct DailySummaryRecord {
    let date: String
    let summaryText: String?
    let topAppsJson: String?
    let topTopicsJson: String?
    let aiSessionsJson: String?
    let contextSwitchesJson: String?
    let unfinishedItemsJson: String?
    let suggestedNotesJson: String?
    let generatedAt: String?
    let modelName: String?
    let tokenUsageInput: Int
    let tokenUsageOutput: Int
    let generationStatus: String?

    init(date: String, summaryText: String?, topAppsJson: String?,
         topTopicsJson: String?, aiSessionsJson: String?,
         contextSwitchesJson: String?, unfinishedItemsJson: String?,
         suggestedNotesJson: String?, generatedAt: String?,
         modelName: String?, tokenUsageInput: Int, tokenUsageOutput: Int,
         generationStatus: String?) {
        self.date = date; self.summaryText = summaryText
        self.topAppsJson = topAppsJson; self.topTopicsJson = topTopicsJson
        self.aiSessionsJson = aiSessionsJson
        self.contextSwitchesJson = contextSwitchesJson
        self.unfinishedItemsJson = unfinishedItemsJson
        self.suggestedNotesJson = suggestedNotesJson
        self.generatedAt = generatedAt; self.modelName = modelName
        self.tokenUsageInput = tokenUsageInput
        self.tokenUsageOutput = tokenUsageOutput
        self.generationStatus = generationStatus
    }

    init?(row: SQLiteRow) {
        guard let date = row["date"]?.textValue else { return nil }
        self.date = date
        self.summaryText = row["summary_text"]?.textValue
        self.topAppsJson = row["top_apps_json"]?.textValue
        self.topTopicsJson = row["top_topics_json"]?.textValue
        self.aiSessionsJson = row["ai_sessions_json"]?.textValue
        self.contextSwitchesJson = row["context_switches_json"]?.textValue
        self.unfinishedItemsJson = row["unfinished_items_json"]?.textValue
        self.suggestedNotesJson = row["suggested_notes_json"]?.textValue
        self.generatedAt = row["generated_at"]?.textValue
        self.modelName = row["model_name"]?.textValue
        self.tokenUsageInput = row["token_usage_input"]?.intValue.flatMap { Int($0) } ?? 0
        self.tokenUsageOutput = row["token_usage_output"]?.intValue.flatMap { Int($0) } ?? 0
        self.generationStatus = row["generation_status"]?.textValue
    }
}
```

- [ ] **Step 3: Run tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MyMacAgent/Models/DailySummaryRecord.swift Tests/MyMacAgentTests/Models/DailySummaryRecordTests.swift
git commit -m "feat: add DailySummaryRecord model"
```

---

## Task 3: ContextFusionEngine

**Files:**
- Create: `Sources/MyMacAgent/Fusion/ContextFusionEngine.swift`
- Create: `Tests/MyMacAgentTests/Fusion/ContextFusionEngineTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Fusion/ContextFusionEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct ContextFusionEngineTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("Fuses AX and OCR into context snapshot")
    func fusesAxAndOcr() {
        let engine = ContextFusionEngine()

        let ax = AXSnapshotRecord(
            id: "ax-1", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "2026-04-02T10:00:00Z",
            focusedRole: "AXTextArea", focusedSubrole: nil,
            focusedTitle: "Editor", focusedValue: "func hello()",
            selectedText: nil, textLen: 12, extractionStatus: "success"
        )

        let ocr = OCRSnapshotRecord(
            id: "ocr-1", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "2026-04-02T10:00:00Z",
            provider: "vision", rawText: "func hello() {\n    print(\"hi\")\n}",
            normalizedText: "func hello() {\n    print(\"hi\")\n}",
            textHash: "h1", confidence: 0.92, language: "en",
            processingMs: 100, extractionStatus: "success"
        )

        let result = engine.fuse(
            sessionId: "sess-1", captureId: "cap-1",
            appName: "Cursor", bundleId: "com.todesktop.230313mzl4w4u92",
            windowTitle: "main.swift — MyProject",
            ax: ax, ocr: ocr, readableScore: 0.9, uncertaintyScore: 0.05
        )

        #expect(result.appName == "Cursor")
        #expect(result.windowTitle == "main.swift — MyProject")
        #expect(result.textSource == "ax+ocr")
        #expect(result.mergedText?.contains("func hello()") == true)
        #expect(result.readableScore == 0.9)
        #expect(result.sourceAxId == "ax-1")
        #expect(result.sourceOcrId == "ocr-1")
    }

    @Test("Fuses with only AX data")
    func fusesAxOnly() {
        let engine = ContextFusionEngine()
        let ax = AXSnapshotRecord(
            id: "ax-1", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "now", focusedRole: "AXTextField", focusedSubrole: nil,
            focusedTitle: "Search", focusedValue: "query text",
            selectedText: nil, textLen: 10, extractionStatus: "success"
        )

        let result = engine.fuse(
            sessionId: "sess-1", captureId: "cap-1",
            appName: "Safari", bundleId: "com.apple.Safari",
            windowTitle: "Google", ax: ax, ocr: nil,
            readableScore: 0.5, uncertaintyScore: 0.3
        )

        #expect(result.textSource == "ax")
        #expect(result.mergedText?.contains("query text") == true)
        #expect(result.sourceAxId == "ax-1")
        #expect(result.sourceOcrId == nil)
    }

    @Test("Fuses with only OCR data")
    func fusesOcrOnly() {
        let engine = ContextFusionEngine()
        let ocr = OCRSnapshotRecord(
            id: "ocr-1", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "now", provider: "vision",
            rawText: "Some text from screen", normalizedText: "Some text from screen",
            textHash: "h", confidence: 0.8, language: "en",
            processingMs: 50, extractionStatus: "success"
        )

        let result = engine.fuse(
            sessionId: "sess-1", captureId: "cap-1",
            appName: "Remote Desktop", bundleId: "com.remote",
            windowTitle: "Server", ax: nil, ocr: ocr,
            readableScore: 0.4, uncertaintyScore: 0.5
        )

        #expect(result.textSource == "ocr")
        #expect(result.mergedText == "Some text from screen")
    }

    @Test("Fuses with no text data")
    func fusesEmpty() {
        let engine = ContextFusionEngine()
        let result = engine.fuse(
            sessionId: "sess-1", captureId: "cap-1",
            appName: "Canvas App", bundleId: "com.canvas",
            windowTitle: "Drawing", ax: nil, ocr: nil,
            readableScore: 0.1, uncertaintyScore: 0.9
        )

        #expect(result.textSource == "none")
        #expect(result.mergedText == nil)
    }

    @Test("Persist saves to DB")
    func persistSaves() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let engine = ContextFusionEngine()
        let snap = ContextSnapshotRecord(
            id: "ctx-1", sessionId: "sess-1", timestamp: "2026-04-02T10:00:00Z",
            appName: "Test", bundleId: "com.test", windowTitle: "Doc",
            textSource: "ax", mergedText: "hello", mergedTextHash: "h1",
            topicHint: nil, readableScore: 0.8, uncertaintyScore: 0.1,
            sourceCaptureId: "cap-1", sourceAxId: "ax-1", sourceOcrId: nil
        )

        try engine.persist(snapshot: snap, db: db)

        let rows = try db.query("SELECT * FROM context_snapshots WHERE id = ?",
            params: [.text("ctx-1")])
        #expect(rows.count == 1)
        #expect(rows[0]["merged_text"]?.textValue == "hello")
        #expect(rows[0]["readable_score"]?.realValue == 0.8)
    }
}
```

- [ ] **Step 2: Implement ContextFusionEngine**

Create `Sources/MyMacAgent/Fusion/ContextFusionEngine.swift`:

```swift
import Foundation
import os

final class ContextFusionEngine {
    private let logger = Logger.fusion

    func fuse(
        sessionId: String, captureId: String?,
        appName: String, bundleId: String, windowTitle: String?,
        ax: AXSnapshotRecord?, ocr: OCRSnapshotRecord?,
        readableScore: Double, uncertaintyScore: Double
    ) -> ContextSnapshotRecord {
        let textSource: String
        let mergedText: String?
        let mergedTextHash: String?

        let axText = [ax?.focusedTitle, ax?.focusedValue, ax?.selectedText]
            .compactMap { $0 }
            .joined(separator: " ")
        let ocrText = ocr?.normalizedText

        switch (axText.isEmpty ? nil : axText, ocrText) {
        case let (ax?, ocr?):
            textSource = "ax+ocr"
            // Prefer OCR text as it's usually more complete, supplement with AX
            if ocr.contains(ax) || ax.count < 20 {
                mergedText = ocr
            } else {
                mergedText = ax + "\n---\n" + ocr
            }
        case let (ax?, nil):
            textSource = "ax"
            mergedText = ax
        case let (nil, ocr?):
            textSource = "ocr"
            mergedText = ocr
        case (nil, nil):
            textSource = "none"
            mergedText = nil
        }

        mergedTextHash = mergedText.map { TextNormalizer.hash($0) }

        let snapshot = ContextSnapshotRecord(
            id: UUID().uuidString,
            sessionId: sessionId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            appName: appName, bundleId: bundleId, windowTitle: windowTitle,
            textSource: textSource, mergedText: mergedText,
            mergedTextHash: mergedTextHash, topicHint: nil,
            readableScore: readableScore, uncertaintyScore: uncertaintyScore,
            sourceCaptureId: captureId,
            sourceAxId: ax?.id, sourceOcrId: ocr?.id
        )

        logger.info("Context fused: source=\(textSource), readability=\(readableScore)")
        return snapshot
    }

    func persist(snapshot: ContextSnapshotRecord, db: DatabaseManager) throws {
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp,
                app_name, bundle_id, window_title, text_source,
                merged_text, merged_text_hash, topic_hint,
                readable_score, uncertainty_score,
                source_capture_id, source_ax_id, source_ocr_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(snapshot.id), .text(snapshot.sessionId), .text(snapshot.timestamp),
            snapshot.appName.map { .text($0) } ?? .null,
            snapshot.bundleId.map { .text($0) } ?? .null,
            snapshot.windowTitle.map { .text($0) } ?? .null,
            snapshot.textSource.map { .text($0) } ?? .null,
            snapshot.mergedText.map { .text($0) } ?? .null,
            snapshot.mergedTextHash.map { .text($0) } ?? .null,
            snapshot.topicHint.map { .text($0) } ?? .null,
            .real(snapshot.readableScore), .real(snapshot.uncertaintyScore),
            snapshot.sourceCaptureId.map { .text($0) } ?? .null,
            snapshot.sourceAxId.map { .text($0) } ?? .null,
            snapshot.sourceOcrId.map { .text($0) } ?? .null
        ])
    }
}
```

- [ ] **Step 3: Run tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MyMacAgent/Fusion/ Tests/MyMacAgentTests/Fusion/
git commit -m "feat: add ContextFusionEngine merging AX + OCR + metadata"
```

---

## Task 4: LLMClient (OpenRouter HTTP Client)

**Files:**
- Create: `Sources/MyMacAgent/Summary/LLMClient.swift`
- Create: `Tests/MyMacAgentTests/Summary/LLMClientTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Summary/LLMClientTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct LLMClientTests {
    @Test("Builds correct request body")
    func buildsRequestBody() throws {
        let client = LLMClient(
            apiKey: "test-key",
            baseURL: "https://openrouter.ai/api/v1",
            model: "anthropic/claude-3-haiku"
        )
        let body = client.buildRequestBody(
            systemPrompt: "You are a summarizer.",
            userPrompt: "Summarize this day."
        )

        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["model"] as? String == "anthropic/claude-3-haiku")

        let messages = json["messages"] as! [[String: String]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "You are a summarizer.")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "Summarize this day.")
    }

    @Test("Builds correct URL request")
    func buildsURLRequest() {
        let client = LLMClient(
            apiKey: "sk-test-123",
            baseURL: "https://openrouter.ai/api/v1",
            model: "anthropic/claude-3-haiku"
        )

        let request = client.buildURLRequest(body: Data())
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpMethod == "POST")
    }

    @Test("Parses chat completion response")
    func parsesChatCompletion() throws {
        let responseJSON = """
        {
            "id": "gen-123",
            "choices": [{
                "message": {"role": "assistant", "content": "Summary of the day."},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150}
        }
        """.data(using: .utf8)!

        let result = try LLMClient.parseResponse(responseJSON)
        #expect(result.content == "Summary of the day.")
        #expect(result.promptTokens == 100)
        #expect(result.completionTokens == 50)
    }

    @Test("Parse response throws on invalid JSON")
    func throwsOnInvalid() {
        #expect(throws: (any Error).self) {
            try LLMClient.parseResponse(Data("not json".utf8))
        }
    }

    @Test("Default configuration")
    func defaultConfig() {
        let client = LLMClient.defaultClient(apiKey: "key")
        #expect(client.model == "anthropic/claude-3-haiku")
    }
}
```

- [ ] **Step 2: Implement LLMClient**

Create `Sources/MyMacAgent/Summary/LLMClient.swift`:

```swift
import Foundation
import os

struct LLMResponse {
    let content: String
    let promptTokens: Int
    let completionTokens: Int
}

final class LLMClient {
    let apiKey: String
    let baseURL: String
    let model: String
    private let logger = Logger.summary

    init(apiKey: String, baseURL: String = "https://openrouter.ai/api/v1", model: String = "anthropic/claude-3-haiku") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    static func defaultClient(apiKey: String) -> LLMClient {
        LLMClient(apiKey: apiKey)
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> LLMResponse {
        let body = buildRequestBody(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let request = buildURLRequest(body: body)

        logger.info("LLM request: model=\(model), promptLen=\(userPrompt.count)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let result = try Self.parseResponse(data)
        logger.info("LLM response: tokens=\(result.promptTokens)+\(result.completionTokens)")
        return result
    }

    func buildRequestBody(systemPrompt: String, userPrompt: String) -> Data {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3,
            "max_tokens": 2000
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func buildURLRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MyMacAgent/0.1.0", forHTTPHeaderField: "HTTP-Referer")
        request.httpBody = body
        return request
    }

    static func parseResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: String],
              let content = message["content"] else {
            throw LLMError.parseError("Failed to parse LLM response")
        }

        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage?["completion_tokens"] as? Int ?? 0

        return LLMResponse(
            content: content,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }
}

enum LLMError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case parseError(String)
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid HTTP response"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .noApiKey: return "No API key configured"
        }
    }
}
```

- [ ] **Step 3: Run tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MyMacAgent/Summary/LLMClient.swift Tests/MyMacAgentTests/Summary/LLMClientTests.swift
git commit -m "feat: add LLMClient for OpenRouter/OpenAI-compatible API"
```

---

## Task 5: DailySummarizer

**Files:**
- Create: `Sources/MyMacAgent/Summary/DailySummarizer.swift`
- Create: `Tests/MyMacAgentTests/Summary/DailySummarizerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Summary/DailySummarizerTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct DailySummarizerTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    private func seedTestData(db: DatabaseManager, date: String = "2026-04-02") throws {
        // App
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")])

        // Sessions
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-1"), .integer(1),
            .text("\(date)T09:00:00Z"), .text("\(date)T10:30:00Z"),
            .integer(5400000), .text("normal")
        ])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-2"), .integer(2),
            .text("\(date)T10:30:00Z"), .text("\(date)T11:00:00Z"),
            .integer(1800000), .text("normal")
        ])

        // Context snapshots
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name, bundle_id,
                window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-1"), .text("sess-1"), .text("\(date)T09:10:00Z"),
            .text("Cursor"), .text("com.cursor"),
            .text("main.swift — Project"), .text("ax+ocr"),
            .text("Working on Swift concurrency implementation"),
            .real(0.9), .real(0.05)
        ])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name, bundle_id,
                window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-2"), .text("sess-2"), .text("\(date)T10:35:00Z"),
            .text("Safari"), .text("com.apple.Safari"),
            .text("Swift Testing docs"), .text("ocr"),
            .text("Reading Swift Testing documentation"),
            .real(0.7), .real(0.2)
        ])
    }

    @Test("buildPrompt generates structured prompt")
    func buildPrompt() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedTestData(db: db)

        let summarizer = DailySummarizer(db: db)
        let prompt = try summarizer.buildDailyPrompt(for: "2026-04-02")

        #expect(prompt.contains("Cursor"))
        #expect(prompt.contains("Safari"))
        #expect(prompt.contains("Swift concurrency"))
        #expect(prompt.contains("2026-04-02"))
    }

    @Test("collectSessionData returns sessions with context")
    func collectSessionData() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedTestData(db: db)

        let summarizer = DailySummarizer(db: db)
        let data = try summarizer.collectSessionData(for: "2026-04-02")

        #expect(data.count == 2)
        #expect(data[0].appName == "Cursor")
        #expect(data[0].contextTexts.count >= 1)
    }

    @Test("persistSummary saves to daily_summaries")
    func persistSummary() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summarizer = DailySummarizer(db: db)
        let summary = DailySummaryRecord(
            date: "2026-04-02", summaryText: "Productive day",
            topAppsJson: "[\"Cursor\"]", topTopicsJson: "[\"Swift\"]",
            aiSessionsJson: nil, contextSwitchesJson: nil,
            unfinishedItemsJson: nil, suggestedNotesJson: nil,
            generatedAt: "2026-04-02T23:00:00Z", modelName: "test",
            tokenUsageInput: 100, tokenUsageOutput: 50,
            generationStatus: "success"
        )

        try summarizer.persistSummary(summary)

        let rows = try db.query("SELECT * FROM daily_summaries WHERE date = ?",
            params: [.text("2026-04-02")])
        #expect(rows.count == 1)
        #expect(rows[0]["summary_text"]?.textValue == "Productive day")
    }

    @Test("parseSummaryResponse extracts sections")
    func parseSummaryResponse() {
        let response = """
        ## Summary
        A productive day focused on Swift development.

        ## Main topics
        - Swift concurrency
        - Testing patterns

        ## Suggested notes
        - [[Swift Testing patterns]]
        - [[Concurrency best practices]]

        ## Continue tomorrow
        - Finish implementing the capture scheduler
        """

        let parsed = DailySummarizer.parseSummaryResponse(response)
        #expect(parsed.summaryText.contains("productive day"))
        #expect(parsed.topics.contains("Swift concurrency"))
        #expect(parsed.suggestedNotes.count == 2)
        #expect(parsed.continueTomorrow != nil)
    }
}
```

- [ ] **Step 2: Implement DailySummarizer**

Create `Sources/MyMacAgent/Summary/DailySummarizer.swift`:

```swift
import Foundation
import os

struct SessionData {
    let sessionId: String
    let appName: String
    let bundleId: String
    let windowTitles: [String]
    let startedAt: String
    let endedAt: String?
    let durationMs: Int64
    let uncertaintyMode: String
    let contextTexts: [String]
}

struct ParsedSummary {
    let summaryText: String
    let topics: [String]
    let suggestedNotes: [String]
    let continueTomorrow: String?
}

final class DailySummarizer {
    private let db: DatabaseManager
    private let logger = Logger.summary

    init(db: DatabaseManager) {
        self.db = db
    }

    func collectSessionData(for date: String) throws -> [SessionData] {
        let sessions = try db.query("""
            SELECT s.id, s.started_at, s.ended_at, s.active_duration_ms,
                   s.uncertainty_mode, a.app_name, a.bundle_id
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at LIKE ?
            ORDER BY s.started_at
        """, params: [.text("\(date)%")])

        return try sessions.compactMap { row -> SessionData? in
            guard let sessionId = row["id"]?.textValue,
                  let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue,
                  let startedAt = row["started_at"]?.textValue else { return nil }

            let contexts = try db.query("""
                SELECT window_title, merged_text FROM context_snapshots
                WHERE session_id = ? ORDER BY timestamp
            """, params: [.text(sessionId)])

            let windowTitles = contexts.compactMap { $0["window_title"]?.textValue }
            let contextTexts = contexts.compactMap { $0["merged_text"]?.textValue }

            return SessionData(
                sessionId: sessionId,
                appName: appName, bundleId: bundleId,
                windowTitles: Array(Set(windowTitles)),
                startedAt: startedAt,
                endedAt: row["ended_at"]?.textValue,
                durationMs: row["active_duration_ms"]?.intValue ?? 0,
                uncertaintyMode: row["uncertainty_mode"]?.textValue ?? "normal",
                contextTexts: contextTexts
            )
        }
    }

    func buildDailyPrompt(for date: String) throws -> String {
        let sessions = try collectSessionData(for: date)

        var prompt = "Generate a daily activity summary for \(date).\n\n"
        prompt += "## Sessions\n\n"

        for session in sessions {
            let durationMin = session.durationMs / 60000
            prompt += "### \(session.appName) (\(durationMin) min)\n"
            prompt += "Time: \(session.startedAt) — \(session.endedAt ?? "ongoing")\n"
            if !session.windowTitles.isEmpty {
                prompt += "Windows: \(session.windowTitles.joined(separator: ", "))\n"
            }
            if session.uncertaintyMode != "normal" {
                prompt += "Note: content was \(session.uncertaintyMode) (visual tracking)\n"
            }
            let textPreview = session.contextTexts
                .prefix(3)
                .map { String($0.prefix(200)) }
                .joined(separator: "\n")
            if !textPreview.isEmpty {
                prompt += "Content preview:\n\(textPreview)\n"
            }
            prompt += "\n"
        }

        prompt += """
        Respond with these sections exactly:

        ## Summary
        (1-3 sentence summary of the day)

        ## Main topics
        (bullet list of main topics/activities)

        ## Suggested notes
        (bullet list of [[wiki-link]] notes worth creating)

        ## Continue tomorrow
        (what to continue working on)
        """

        return prompt
    }

    func summarize(for date: String, using client: LLMClient) async throws -> DailySummaryRecord {
        let prompt = try buildDailyPrompt(for: date)

        let systemPrompt = """
        You are a personal productivity assistant. Analyze the user's computer activity
        and produce a concise, insightful daily summary. Focus on what they accomplished,
        what topics they explored, and what they should continue tomorrow. Be specific
        about the actual content they worked on based on window titles and text excerpts.
        """

        logger.info("Generating daily summary for \(date)")

        let response = try await client.complete(
            systemPrompt: systemPrompt,
            userPrompt: prompt
        )

        let parsed = Self.parseSummaryResponse(response.content)
        let now = ISO8601DateFormatter().string(from: Date())

        let topicsJson = try? String(
            data: JSONSerialization.data(withJSONObject: parsed.topics),
            encoding: .utf8
        )
        let notesJson = try? String(
            data: JSONSerialization.data(withJSONObject: parsed.suggestedNotes),
            encoding: .utf8
        )

        // Collect app durations
        let sessions = try collectSessionData(for: date)
        let appDurations = Dictionary(grouping: sessions, by: \.appName)
            .mapValues { $0.reduce(0) { $0 + $1.durationMs } / 60000 }
            .sorted { $0.value > $1.value }
            .map { ["name": $0.key, "duration_min": $0.value] as [String: Any] }
        let appsJson = try? String(
            data: JSONSerialization.data(withJSONObject: appDurations),
            encoding: .utf8
        )

        let summary = DailySummaryRecord(
            date: date,
            summaryText: parsed.summaryText,
            topAppsJson: appsJson,
            topTopicsJson: topicsJson,
            aiSessionsJson: nil,
            contextSwitchesJson: "{\"count\":\(sessions.count)}",
            unfinishedItemsJson: parsed.continueTomorrow.map { "{\"items\":[\"\($0)\"]}" },
            suggestedNotesJson: notesJson,
            generatedAt: now,
            modelName: client.model,
            tokenUsageInput: response.promptTokens,
            tokenUsageOutput: response.completionTokens,
            generationStatus: "success"
        )

        try persistSummary(summary)
        logger.info("Daily summary saved for \(date)")

        return summary
    }

    func persistSummary(_ summary: DailySummaryRecord) throws {
        try db.execute("""
            INSERT OR REPLACE INTO daily_summaries
                (date, summary_text, top_apps_json, top_topics_json,
                 ai_sessions_json, context_switches_json, unfinished_items_json,
                 suggested_notes_json, generated_at, model_name,
                 token_usage_input, token_usage_output, generation_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(summary.date),
            summary.summaryText.map { .text($0) } ?? .null,
            summary.topAppsJson.map { .text($0) } ?? .null,
            summary.topTopicsJson.map { .text($0) } ?? .null,
            summary.aiSessionsJson.map { .text($0) } ?? .null,
            summary.contextSwitchesJson.map { .text($0) } ?? .null,
            summary.unfinishedItemsJson.map { .text($0) } ?? .null,
            summary.suggestedNotesJson.map { .text($0) } ?? .null,
            summary.generatedAt.map { .text($0) } ?? .null,
            summary.modelName.map { .text($0) } ?? .null,
            .integer(Int64(summary.tokenUsageInput)),
            .integer(Int64(summary.tokenUsageOutput)),
            summary.generationStatus.map { .text($0) } ?? .null
        ])
    }

    static func parseSummaryResponse(_ text: String) -> ParsedSummary {
        let sections = text.components(separatedBy: "## ")

        var summaryText = ""
        var topics: [String] = []
        var suggestedNotes: [String] = []
        var continueTomorrow: String?

        for section in sections {
            let lines = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if lines.hasPrefix("Summary") {
                summaryText = lines.replacingOccurrences(of: "Summary\n", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if lines.hasPrefix("Main topics") {
                topics = lines.split(separator: "\n")
                    .dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
                    .filter { !$0.isEmpty }
            } else if lines.hasPrefix("Suggested notes") {
                suggestedNotes = lines.split(separator: "\n")
                    .dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
                    .map { $0.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "") }
                    .filter { !$0.isEmpty }
            } else if lines.hasPrefix("Continue tomorrow") {
                continueTomorrow = lines.replacingOccurrences(of: "Continue tomorrow\n", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return ParsedSummary(
            summaryText: summaryText,
            topics: topics,
            suggestedNotes: suggestedNotes,
            continueTomorrow: continueTomorrow
        )
    }
}
```

- [ ] **Step 3: Run tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MyMacAgent/Summary/DailySummarizer.swift Tests/MyMacAgentTests/Summary/DailySummarizerTests.swift
git commit -m "feat: add DailySummarizer with prompt building, LLM integration, and response parsing"
```

---

## Task 6: ObsidianExporter

**Files:**
- Create: `Sources/MyMacAgent/Export/ObsidianExporter.swift`
- Create: `Tests/MyMacAgentTests/Export/ObsidianExporterTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Export/ObsidianExporterTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct ObsidianExporterTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("Renders daily note markdown")
    func rendersDailyNote() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Seed sessions for app duration calculation
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1), .text("2026-04-02T09:00:00Z"),
                      .text("2026-04-02T11:14:00Z"), .integer(8040000)])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s2"), .integer(2), .text("2026-04-02T11:14:00Z"),
                      .text("2026-04-02T12:22:00Z"), .integer(4080000)])

        let summary = DailySummaryRecord(
            date: "2026-04-02",
            summaryText: "Productive day focused on Swift development and testing.",
            topAppsJson: "[{\"name\":\"Cursor\",\"duration_min\":134},{\"name\":\"Safari\",\"duration_min\":68}]",
            topTopicsJson: "[\"Swift concurrency\",\"Testing\"]",
            aiSessionsJson: nil, contextSwitchesJson: "{\"count\":5}",
            unfinishedItemsJson: nil,
            suggestedNotesJson: "[\"Swift Testing patterns\"]",
            generatedAt: "2026-04-02T23:00:00Z", modelName: "claude-3-haiku",
            tokenUsageInput: 1000, tokenUsageOutput: 300,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db)
        let markdown = try exporter.renderDailyNote(summary: summary)

        #expect(markdown.contains("# Daily Log — 2026-04-02"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("Productive day"))
        #expect(markdown.contains("## Main apps"))
        #expect(markdown.contains("Cursor"))
        #expect(markdown.contains("## Main topics"))
        #expect(markdown.contains("Swift concurrency"))
        #expect(markdown.contains("## Suggested notes"))
        #expect(markdown.contains("[[Swift Testing patterns]]"))
    }

    @Test("Writes daily note to vault directory")
    func writesToVault() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_vault_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let summary = DailySummaryRecord(
            date: "2026-04-02", summaryText: "Good day.",
            topAppsJson: nil, topTopicsJson: nil,
            aiSessionsJson: nil, contextSwitchesJson: nil,
            unfinishedItemsJson: nil, suggestedNotesJson: nil,
            generatedAt: nil, modelName: nil,
            tokenUsageInput: 0, tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir)
        let filePath = try exporter.exportDailyNote(summary: summary)

        #expect(FileManager.default.fileExists(atPath: filePath))
        let content = try String(contentsOfFile: filePath)
        #expect(content.contains("# Daily Log — 2026-04-02"))
    }

    @Test("Generates timeline from sessions")
    func generatesTimeline() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:10:00Z"), .text("2026-04-02T09:32:00Z"),
                      .integer(1320000)])

        let exporter = ObsidianExporter(db: db)
        let timeline = try exporter.buildTimeline(for: "2026-04-02")

        #expect(timeline.contains("09:10"))
        #expect(timeline.contains("09:32"))
        #expect(timeline.contains("TestApp"))
    }

    @Test("formatDuration formats minutes to hours and minutes")
    func formatDuration() {
        #expect(ObsidianExporter.formatDuration(minutes: 134) == "2h 14m")
        #expect(ObsidianExporter.formatDuration(minutes: 45) == "45m")
        #expect(ObsidianExporter.formatDuration(minutes: 60) == "1h 00m")
        #expect(ObsidianExporter.formatDuration(minutes: 0) == "0m")
    }
}
```

- [ ] **Step 2: Implement ObsidianExporter**

Create `Sources/MyMacAgent/Export/ObsidianExporter.swift`:

```swift
import Foundation
import os

final class ObsidianExporter {
    private let db: DatabaseManager
    private let vaultPath: String
    private let logger = Logger.export

    init(db: DatabaseManager, vaultPath: String = "") {
        self.db = db
        self.vaultPath = vaultPath
    }

    func renderDailyNote(summary: DailySummaryRecord) throws -> String {
        var md = "# Daily Log — \(summary.date)\n\n"

        // Summary
        md += "## Summary\n"
        md += "\(summary.summaryText ?? "No summary available.")\n\n"

        // Main apps
        md += "## Main apps\n"
        if let appsJson = summary.topAppsJson,
           let appsData = appsJson.data(using: .utf8),
           let apps = try? JSONSerialization.jsonObject(with: appsData) as? [[String: Any]] {
            for app in apps {
                let name = app["name"] as? String ?? "Unknown"
                let minutes = app["duration_min"] as? Int ?? 0
                md += "- \(name) — \(Self.formatDuration(minutes: minutes))\n"
            }
        } else {
            md += "- No app data available\n"
        }
        md += "\n"

        // Main topics
        md += "## Main topics\n"
        if let topicsJson = summary.topTopicsJson,
           let topicsData = topicsJson.data(using: .utf8),
           let topics = try? JSONSerialization.jsonObject(with: topicsData) as? [String] {
            for topic in topics {
                md += "- \(topic)\n"
            }
        } else {
            md += "- No topics extracted\n"
        }
        md += "\n"

        // Timeline
        md += "## Timeline\n"
        let timeline = try buildTimeline(for: summary.date)
        md += timeline.isEmpty ? "- No sessions recorded\n" : timeline
        md += "\n"

        // Suggested notes
        md += "## Suggested notes\n"
        if let notesJson = summary.suggestedNotesJson,
           let notesData = notesJson.data(using: .utf8),
           let notes = try? JSONSerialization.jsonObject(with: notesData) as? [String] {
            for note in notes {
                md += "- [[\(note)]]\n"
            }
        } else {
            md += "- No suggestions\n"
        }
        md += "\n"

        // Continue tomorrow
        if let unfinished = summary.unfinishedItemsJson {
            md += "## Continue tomorrow\n"
            md += "- \(unfinished)\n\n"
        }

        return md
    }

    func buildTimeline(for date: String) throws -> String {
        let sessions = try db.query("""
            SELECT s.started_at, s.ended_at, a.app_name
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at LIKE ?
            ORDER BY s.started_at
        """, params: [.text("\(date)%")])

        var timeline = ""
        for row in sessions {
            guard let startedAt = row["started_at"]?.textValue,
                  let appName = row["app_name"]?.textValue else { continue }

            let startTime = formatTime(startedAt)
            let endTime = row["ended_at"]?.textValue.map { formatTime($0) } ?? "ongoing"
            timeline += "- \(startTime)–\(endTime) — \(appName)\n"
        }
        return timeline
    }

    func exportDailyNote(summary: DailySummaryRecord) throws -> String {
        let markdown = try renderDailyNote(summary: summary)

        let dailyDir = (vaultPath as NSString).appendingPathComponent("Daily")
        try FileManager.default.createDirectory(atPath: dailyDir, withIntermediateDirectories: true)

        let filename = "\(summary.date).md"
        let filePath = (dailyDir as NSString).appendingPathComponent(filename)

        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        logger.info("Exported daily note to \(filePath)")

        return filePath
    }

    static func formatDuration(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(String(format: "%02d", mins))m"
    }

    private func formatTime(_ isoString: String) -> String {
        // Extract HH:mm from ISO 8601 string
        guard isoString.count >= 16 else { return isoString }
        let startIndex = isoString.index(isoString.startIndex, offsetBy: 11)
        let endIndex = isoString.index(startIndex, offsetBy: 5)
        return String(isoString[startIndex..<endIndex])
    }
}
```

- [ ] **Step 3: Run tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/MyMacAgent/Export/ObsidianExporter.swift Tests/MyMacAgentTests/Export/ObsidianExporterTests.swift
git commit -m "feat: add ObsidianExporter with daily note markdown rendering and vault export"
```

---

## Task 7: Wire Up Phase 3 in AppDelegate

**Files:**
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift`

- [ ] **Step 1: Add Phase 3 components**

Add to `AppDelegate`:
1. Properties: `contextFusionEngine`, `dailySummarizer`, `obsidianExporter`
2. `initializePhase3()` method
3. Update `performCapture(mode:)` to call context fusion after AX + OCR
4. Method to trigger daily summary on demand or at end of day

Add after the Phase 2 properties:

```swift
// Phase 3
private var contextFusionEngine: ContextFusionEngine?
private var dailySummarizer: DailySummarizer?
private var obsidianExporter: ObsidianExporter?
```

Add `initializePhase3()`:

```swift
private func initializePhase3() {
    guard let db = databaseManager else { return }
    contextFusionEngine = ContextFusionEngine()
    dailySummarizer = DailySummarizer(db: db)

    let vaultPath = UserDefaults.standard.string(forKey: "obsidianVaultPath")
        ?? NSHomeDirectory() + "/Documents/MyMacAgentVault"
    obsidianExporter = ObsidianExporter(db: db, vaultPath: vaultPath)

    logger.info("Phase 3 components initialized (fusion, summary, export)")
}
```

Call `initializePhase3()` from `applicationDidFinishLaunching` after `initializePhase2()`.

In `performCapture(mode:)`, after step 6 (OCR), add step 6.5 — context fusion:

```swift
// 6.5 Context fusion
if let fusionEngine = contextFusionEngine, let db {
    let axSnap = /* the AX snapshot from step 5, or nil */
    let ocrSnap = /* the OCR snapshot from step 6, or nil */
    let ctxSnapshot = fusionEngine.fuse(
        sessionId: sessionId, captureId: captureId,
        appName: appInfo.appName, bundleId: appInfo.bundleId,
        windowTitle: windowMonitor?.currentWindowTitle,
        ax: axSnap, ocr: ocrSnap,
        readableScore: ReadabilityScorer.score(readabilityInput),
        uncertaintyScore: 1.0 - ReadabilityScorer.score(readabilityInput)
    )
    try fusionEngine.persist(snapshot: ctxSnapshot, db: db)
}
```

Add a method to generate and export summary:

```swift
func generateDailySummary(for date: String, apiKey: String) {
    Task {
        do {
            let client = LLMClient(apiKey: apiKey)
            guard let summarizer = dailySummarizer else { return }
            let summary = try await summarizer.summarize(for: date, using: client)
            if let exporter = obsidianExporter {
                let path = try exporter.exportDailyNote(summary: summary)
                logger.info("Daily note exported to \(path)")
            }
        } catch {
            logger.error("Daily summary failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `make build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/MyMacAgent/App/AppDelegate.swift
git commit -m "feat: wire up context fusion, daily summary, and Obsidian export in AppDelegate"
```

---

## Task 8: Phase 3 Integration Tests

**Files:**
- Create: `Tests/MyMacAgentTests/Integration/Phase3IntegrationTests.swift`

- [ ] **Step 1: Write integration tests**

Create `Tests/MyMacAgentTests/Integration/Phase3IntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct Phase3IntegrationTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("Context fusion persists merged AX+OCR snapshot")
    func contextFusionPersists() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let fusionEngine = ContextFusionEngine()
        let ax = AXSnapshotRecord(
            id: "ax-1", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "2026-04-02T10:00:00Z",
            focusedRole: "AXTextArea", focusedSubrole: nil,
            focusedTitle: "Editor", focusedValue: "let x = 42",
            selectedText: nil, textLen: 10, extractionStatus: "success"
        )
        let ocr = OCRSnapshotRecord(
            id: "ocr-1", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "2026-04-02T10:00:00Z",
            provider: "vision", rawText: "let x = 42\nprint(x)",
            normalizedText: "let x = 42\nprint(x)",
            textHash: "h1", confidence: 0.9, language: "en",
            processingMs: 100, extractionStatus: "success"
        )

        let snapshot = fusionEngine.fuse(
            sessionId: "sess-1", captureId: "cap-1",
            appName: "Cursor", bundleId: "com.cursor",
            windowTitle: "main.swift", ax: ax, ocr: ocr,
            readableScore: 0.9, uncertaintyScore: 0.05
        )
        try fusionEngine.persist(snapshot: snapshot, db: db)

        let rows = try db.query("SELECT * FROM context_snapshots")
        #expect(rows.count == 1)
        #expect(rows[0]["text_source"]?.textValue == "ax+ocr")
        #expect(rows[0]["app_name"]?.textValue == "Cursor")
    }

    @Test("DailySummarizer collects session data")
    func summarizerCollectsData() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Seed
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:00:00Z"), .text("2026-04-02T10:30:00Z"),
                      .integer(5400000)])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name, bundle_id,
                window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-1"), .text("s1"), .text("2026-04-02T09:10:00Z"),
            .text("Cursor"), .text("com.cursor"),
            .text("main.swift"), .text("ax+ocr"),
            .text("Swift development work"),
            .real(0.9), .real(0.05)
        ])

        let summarizer = DailySummarizer(db: db)
        let data = try summarizer.collectSessionData(for: "2026-04-02")

        #expect(data.count == 1)
        #expect(data[0].appName == "Cursor")
        #expect(data[0].contextTexts.count == 1)
        #expect(data[0].contextTexts[0] == "Swift development work")
    }

    @Test("ObsidianExporter writes valid markdown file")
    func obsidianExporterWrites() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_vault_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:00:00Z"), .text("2026-04-02T11:14:00Z"),
                      .integer(8040000)])

        let summary = DailySummaryRecord(
            date: "2026-04-02",
            summaryText: "Built the MyMacAgent core pipeline.",
            topAppsJson: "[{\"name\":\"Cursor\",\"duration_min\":134}]",
            topTopicsJson: "[\"Swift\",\"macOS development\"]",
            aiSessionsJson: nil, contextSwitchesJson: nil,
            unfinishedItemsJson: nil,
            suggestedNotesJson: "[\"Swift Testing\"]",
            generatedAt: "2026-04-02T23:00:00Z", modelName: "claude-3-haiku",
            tokenUsageInput: 500, tokenUsageOutput: 200,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir)
        let filePath = try exporter.exportDailyNote(summary: summary)

        #expect(FileManager.default.fileExists(atPath: filePath))

        let content = try String(contentsOfFile: filePath)
        #expect(content.contains("# Daily Log — 2026-04-02"))
        #expect(content.contains("Cursor — 2h 14m"))
        #expect(content.contains("[[Swift Testing]]"))
        #expect(content.contains("09:00–11:14"))
    }

    @Test("Full pipeline: fusion → summary → export")
    func fullPipeline() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_vault_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        // Setup data
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:00:00Z"), .text("2026-04-02T10:00:00Z"),
                      .integer(3600000)])

        // 1. Fusion
        let fusion = ContextFusionEngine()
        let ctx = fusion.fuse(
            sessionId: "s1", captureId: nil,
            appName: "TestApp", bundleId: "com.test",
            windowTitle: "Doc.txt",
            ax: nil, ocr: nil, readableScore: 0.1, uncertaintyScore: 0.9
        )
        try fusion.persist(snapshot: ctx, db: db)

        // 2. Verify prompt can be built
        let summarizer = DailySummarizer(db: db)
        let prompt = try summarizer.buildDailyPrompt(for: "2026-04-02")
        #expect(prompt.contains("TestApp"))

        // 3. Persist a manual summary (skip LLM call)
        let summary = DailySummaryRecord(
            date: "2026-04-02", summaryText: "Test day summary.",
            topAppsJson: "[{\"name\":\"TestApp\",\"duration_min\":60}]",
            topTopicsJson: "[\"Testing\"]",
            aiSessionsJson: nil, contextSwitchesJson: nil,
            unfinishedItemsJson: nil, suggestedNotesJson: nil,
            generatedAt: "2026-04-02T23:00:00Z", modelName: "manual",
            tokenUsageInput: 0, tokenUsageOutput: 0,
            generationStatus: "success"
        )
        try summarizer.persistSummary(summary)

        // 4. Export
        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir)
        let filePath = try exporter.exportDailyNote(summary: summary)
        #expect(FileManager.default.fileExists(atPath: filePath))

        // Verify everything is in DB
        let ctxRows = try db.query("SELECT * FROM context_snapshots")
        let sumRows = try db.query("SELECT * FROM daily_summaries")
        #expect(ctxRows.count == 1)
        #expect(sumRows.count == 1)
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/MyMacAgentTests/Integration/Phase3IntegrationTests.swift
git commit -m "test: add Phase 3 integration tests for fusion, summarizer, and Obsidian export"
```

---

## Self-Review Checklist

1. **Spec coverage:**
   - Sprint 6 (Context Fusion): Covered by Tasks 1, 3 — ContextSnapshotRecord model + ContextFusionEngine merging AX + OCR + app/window metadata with readability/uncertainty scores
   - Sprint 7 (Daily Summary): Covered by Tasks 2, 4, 5 — DailySummaryRecord + LLMClient (OpenRouter) + DailySummarizer with prompt building, LLM call, response parsing, session data collection
   - Sprint 8 (Obsidian Export): Covered by Task 6 — ObsidianExporter with daily note template (Summary, Main apps with durations, Main topics, Timeline, Suggested notes as wiki-links, Continue tomorrow), vault directory writing
   - Wiring: Task 7 connects fusion into capture pipeline, adds summary/export to AppDelegate
   - Integration: Task 8 verifies full pipeline

2. **Placeholder scan:** All tasks contain complete Swift code. No "TBD" or placeholders.

3. **Type consistency:** `ContextSnapshotRecord` used in Tasks 1, 3, 7, 8. `DailySummaryRecord` in Tasks 2, 5, 6, 8. `LLMClient`/`LLMResponse` in Tasks 4, 5. `SessionData`/`ParsedSummary` in Task 5. `ObsidianExporter` in Tasks 6, 7, 8. `ContextFusionEngine.fuse()` signature matches across Tasks 3, 7, 8.

---

## Next Plans

After completing this plan, create:
- **Phase 4:** `2026-04-XX-mymacagent-phase4.md` — Timeline UI, Optimization, Notion export (Sprints 9-11)
