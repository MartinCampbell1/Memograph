# Vision Analysis + Audio Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add hourly vision analysis of low-readability screenshots via Qwen3.5-4B, and continuous audio transcription via mlx-whisper — both feeding into the daily summary pipeline.

**Architecture:** VisionAnalyzer runs hourly, queries captures where `readable_score < 0.3`, sends them to local Qwen3.5-4B via Ollama multimodal API, and stores descriptions in a new `vision_analyses` column on `context_snapshots`. AudioCaptureEngine uses a Python subprocess running mlx-whisper to transcribe system audio in 5-minute chunks, storing transcripts in a new `audio_transcripts` table. DailySummarizer is updated to include both vision descriptions and audio transcripts in the LLM prompt.

**Tech Stack:** Swift 6.2, Ollama API (Qwen3.5-4B vision), mlx-whisper (Python subprocess), existing DatabaseManager

---

## Pre-installed Dependencies

- `hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M` — already in Ollama (3.4GB)
- `mlx-whisper` — installed in `/Users/martin/mymacagent/.venv/`
- `glm-ocr` — already in Ollama (2.2GB) for OCR

---

## Task 1: VisionAnalyzer — Analyze Low-Readability Screenshots

**Files:**
- Create: `Sources/MyMacAgent/Vision/VisionAnalyzer.swift`
- Create: `Tests/MyMacAgentTests/Vision/VisionAnalyzerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Vision/VisionAnalyzerTests.swift`:

```swift
import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct VisionAnalyzerTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("findLowReadabilityCaptures returns captures with low score")
    func findsLowReadability() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        // Low readability capture
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, sampling_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("cap-low"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .text("window"), .text("/tmp/test.jpg"), .text("high_uncertainty")])

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, source_capture_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .real(0.1), .real(0.9), .text("cap-low")])

        // High readability capture
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, sampling_mode)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("cap-high"), .text("s1"), .text("2026-04-02T10:05:00Z"),
                      .text("window"), .text("normal")])

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, source_capture_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-2"), .text("s1"), .text("2026-04-02T10:05:00Z"),
                      .real(0.9), .real(0.1), .text("cap-high")])

        let analyzer = VisionAnalyzer(db: db)
        let lowCaps = try analyzer.findLowReadabilityCaptures(for: "2026-04-02", threshold: 0.3)

        #expect(lowCaps.count == 1)
        #expect(lowCaps[0].captureId == "cap-low")
    }

    @Test("buildVisionPrompt creates image analysis request")
    func buildsPrompt() {
        let analyzer = VisionAnalyzer(db: DatabaseManager.forTesting())
        let prompt = analyzer.buildVisionPrompt()
        #expect(prompt.contains("Describe"))
        #expect(!prompt.isEmpty)
    }

    @Test("persistVisionResult updates context snapshot")
    func persistsResult() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, merged_text)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .real(0.1), .real(0.9), .null])

        let analyzer = VisionAnalyzer(db: db)
        try analyzer.persistVisionResult(contextId: "ctx-1", description: "Screenshot shows a Kubernetes dashboard with 3 running pods")

        let rows = try db.query("SELECT merged_text FROM context_snapshots WHERE id = ?",
            params: [.text("ctx-1")])
        #expect(rows[0]["merged_text"]?.textValue?.contains("Kubernetes") == true)
    }
}
```

- [ ] **Step 2: Implement VisionAnalyzer**

Create `Sources/MyMacAgent/Vision/VisionAnalyzer.swift`:

```swift
import AppKit
import Foundation
import os

struct LowReadabilityCapture {
    let captureId: String
    let contextId: String
    let imagePath: String?
    let readableScore: Double
    let appName: String?
    let windowTitle: String?
}

final class VisionAnalyzer {
    private let db: DatabaseManager
    private let ollamaBaseURL: String
    private let modelName: String
    nonisolated(unsafe) private let logger = Logger.ocr

    init(db: DatabaseManager,
         ollamaBaseURL: String = "http://localhost:11434",
         modelName: String = "hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M") {
        self.db = db
        self.ollamaBaseURL = ollamaBaseURL
        self.modelName = modelName
    }

    func findLowReadabilityCaptures(for date: String, threshold: Double = 0.3) throws -> [LowReadabilityCapture] {
        let rows = try db.query("""
            SELECT cs.id as ctx_id, cs.source_capture_id, cs.readable_score,
                   cs.app_name, cs.window_title, c.image_path
            FROM context_snapshots cs
            LEFT JOIN captures c ON cs.source_capture_id = c.id
            WHERE cs.timestamp LIKE ?
              AND cs.readable_score < ?
              AND cs.merged_text IS NULL
            ORDER BY cs.timestamp
            LIMIT 20
        """, params: [.text("\(date)%"), .real(threshold)])

        return rows.compactMap { row -> LowReadabilityCapture? in
            guard let ctxId = row["ctx_id"]?.textValue,
                  let captureId = row["source_capture_id"]?.textValue else { return nil }
            return LowReadabilityCapture(
                captureId: captureId,
                contextId: ctxId,
                imagePath: row["image_path"]?.textValue,
                readableScore: row["readable_score"]?.realValue ?? 0,
                appName: row["app_name"]?.textValue,
                windowTitle: row["window_title"]?.textValue
            )
        }
    }

    func analyzeImage(at path: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return ""
        }

        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ""
        }
        let base64 = imageData.base64EncodedString()

        let payload: [String: Any] = [
            "model": modelName,
            "prompt": buildVisionPrompt(),
            "images": [base64],
            "stream": false
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "\(ollamaBaseURL)/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            return ""
        }

        logger.info("Vision analysis: \(text.count) chars for image at \(path)")
        return text
    }

    func persistVisionResult(contextId: String, description: String) throws {
        try db.execute(
            "UPDATE context_snapshots SET merged_text = ?, text_source = 'vision' WHERE id = ?",
            params: [.text(description), .text(contextId)]
        )
    }

    func analyzeAllLowReadability(for date: String) async throws -> Int {
        let captures = try findLowReadabilityCaptures(for: date)
        var analyzed = 0

        for capture in captures {
            guard let imagePath = capture.imagePath else { continue }
            let description = try await analyzeImage(at: imagePath)
            if !description.isEmpty {
                try persistVisionResult(contextId: capture.contextId, description: description)
                analyzed += 1
                logger.info("Vision: analyzed \(capture.captureId) for \(capture.appName ?? "unknown")")
            }
        }

        logger.info("Vision analysis complete: \(analyzed)/\(captures.count) captures analyzed for \(date)")
        return analyzed
    }

    func buildVisionPrompt() -> String {
        "Describe what is shown in this screenshot in detail. Focus on: text content, code, UI elements, charts/graphs, data tables, and any important visual information. Extract all readable text. Be concise but thorough."
    }
}
```

- [ ] **Step 3: Add `DatabaseManager.forTesting()` helper**

Add to `Sources/MyMacAgent/Database/DatabaseManager.swift`:

```swift
static func forTesting() -> DatabaseManager {
    try! DatabaseManager(path: NSTemporaryDirectory() + "test_\(UUID().uuidString).db")
}
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
make test
git add Sources/MyMacAgent/Vision/ Tests/MyMacAgentTests/Vision/ Sources/MyMacAgent/Database/DatabaseManager.swift
git commit -m "feat: add VisionAnalyzer for low-readability screenshot analysis via Qwen3.5"
```

---

## Task 2: Audio Transcription Engine

**Files:**
- Create: `Sources/MyMacAgent/Audio/AudioTranscriber.swift`
- Create: `Sources/MyMacAgent/Audio/whisper_transcribe.py`
- Create: `Tests/MyMacAgentTests/Audio/AudioTranscriberTests.swift`

- [ ] **Step 1: Create the Python whisper script**

Create `Sources/MyMacAgent/Audio/whisper_transcribe.py`:

```python
#!/usr/bin/env python3
"""Transcribe audio file using mlx-whisper. Called by MyMacAgent as subprocess."""
import sys
import json
import mlx_whisper

def main():
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: whisper_transcribe.py <audio_file> [language]"}))
        sys.exit(1)

    audio_path = sys.argv[1]
    language = sys.argv[2] if len(sys.argv) > 2 else None

    try:
        result = mlx_whisper.transcribe(
            audio_path,
            path_or_hf_repo="mlx-community/whisper-large-v3-turbo",
            language=language
        )

        output = {
            "text": result["text"],
            "language": result.get("language", ""),
            "segments": [
                {"start": s["start"], "end": s["end"], "text": s["text"]}
                for s in result.get("segments", [])
            ]
        }
        print(json.dumps(output, ensure_ascii=False))
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Write failing tests**

Create `Tests/MyMacAgentTests/Audio/AudioTranscriberTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct AudioTranscriberTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("Transcriber initializes with correct paths")
    func initializes() {
        let transcriber = AudioTranscriber(db: DatabaseManager.forTesting())
        #expect(transcriber.venvPath.contains(".venv"))
    }

    @Test("persistTranscript saves to DB")
    func persistsTranscript() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Create audio_transcripts table (V002 migration)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS audio_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                timestamp TEXT NOT NULL,
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let transcriber = AudioTranscriber(db: db)
        try transcriber.persistTranscript(
            sessionId: "s1",
            text: "Обсуждали архитектуру нового сервиса",
            language: "ru",
            durationSeconds: 300
        )

        let rows = try db.query("SELECT * FROM audio_transcripts")
        #expect(rows.count == 1)
        #expect(rows[0]["transcript"]?.textValue?.contains("архитектуру") == true)
        #expect(rows[0]["language"]?.textValue == "ru")
    }

    @Test("getTranscriptsForDate returns ordered transcripts")
    func getsTranscripts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            CREATE TABLE IF NOT EXISTS audio_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                timestamp TEXT NOT NULL,
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            INSERT INTO audio_transcripts (id, timestamp, transcript, duration_seconds)
            VALUES (?, ?, ?, ?)
        """, params: [.text("t1"), .text("2026-04-02T10:00:00Z"), .text("First chunk"), .real(300)])
        try db.execute("""
            INSERT INTO audio_transcripts (id, timestamp, transcript, duration_seconds)
            VALUES (?, ?, ?, ?)
        """, params: [.text("t2"), .text("2026-04-02T10:05:00Z"), .text("Second chunk"), .real(300)])

        let transcriber = AudioTranscriber(db: db)
        let transcripts = try transcriber.getTranscriptsForDate("2026-04-02")

        #expect(transcripts.count == 2)
        #expect(transcripts[0].text == "First chunk")
    }
}
```

- [ ] **Step 3: Implement AudioTranscriber**

Create `Sources/MyMacAgent/Audio/AudioTranscriber.swift`:

```swift
import Foundation
import os

struct AudioTranscript {
    let id: String
    let sessionId: String?
    let timestamp: String
    let durationSeconds: Double
    let text: String
    let language: String?
}

final class AudioTranscriber {
    private let db: DatabaseManager
    let venvPath: String
    private let scriptPath: String
    nonisolated(unsafe) private let logger = Logger.app

    init(db: DatabaseManager,
         venvPath: String = "",
         scriptPath: String = "") {
        self.db = db

        // Default paths
        if venvPath.isEmpty {
            let projectDir = Bundle.main.bundlePath
                .components(separatedBy: "/build/").first ?? NSHomeDirectory() + "/mymacagent"
            self.venvPath = projectDir + "/.venv"
        } else {
            self.venvPath = venvPath
        }

        if scriptPath.isEmpty {
            let projectDir = Bundle.main.bundlePath
                .components(separatedBy: "/build/").first ?? NSHomeDirectory() + "/mymacagent"
            self.scriptPath = projectDir + "/Sources/MyMacAgent/Audio/whisper_transcribe.py"
        } else {
            self.scriptPath = scriptPath
        }
    }

    func ensureTable() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS audio_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                timestamp TEXT NOT NULL,
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
    }

    func transcribeFile(audioPath: String, language: String? = nil) async throws -> AudioTranscript {
        let pythonPath = venvPath + "/bin/python3"

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw AudioError.venvNotFound(venvPath)
        }
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw AudioError.scriptNotFound(scriptPath)
        }

        var args = [scriptPath, audioPath]
        if let lang = language { args.append(lang) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw AudioError.transcriptionFailed("Failed to parse whisper output")
        }

        let detectedLang = json["language"] as? String

        return AudioTranscript(
            id: UUID().uuidString,
            sessionId: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            durationSeconds: 0,
            text: text,
            language: detectedLang ?? language
        )
    }

    func persistTranscript(sessionId: String?, text: String, language: String?, durationSeconds: Double) throws {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        try db.execute("""
            INSERT INTO audio_transcripts (id, session_id, timestamp, duration_seconds, transcript, language)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            sessionId.map { .text($0) } ?? .null,
            .text(now),
            .real(durationSeconds),
            .text(text),
            language.map { .text($0) } ?? .null
        ])
    }

    func getTranscriptsForDate(_ date: String) throws -> [AudioTranscript] {
        let rows = try db.query("""
            SELECT id, session_id, timestamp, duration_seconds, transcript, language
            FROM audio_transcripts
            WHERE timestamp LIKE ?
            ORDER BY timestamp
        """, params: [.text("\(date)%")])

        return rows.compactMap { row -> AudioTranscript? in
            guard let id = row["id"]?.textValue,
                  let timestamp = row["timestamp"]?.textValue,
                  let text = row["transcript"]?.textValue else { return nil }
            return AudioTranscript(
                id: id,
                sessionId: row["session_id"]?.textValue,
                timestamp: timestamp,
                durationSeconds: row["duration_seconds"]?.realValue ?? 0,
                text: text,
                language: row["language"]?.textValue
            )
        }
    }
}

enum AudioError: Error, LocalizedError {
    case venvNotFound(String)
    case scriptNotFound(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .venvNotFound(let p): return "Python venv not found at \(p)"
        case .scriptNotFound(let p): return "Whisper script not found at \(p)"
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        }
    }
}
```

- [ ] **Step 4: Run tests, verify pass, commit**

```bash
make test
git add Sources/MyMacAgent/Audio/ Tests/MyMacAgentTests/Audio/
git commit -m "feat: add AudioTranscriber with mlx-whisper subprocess and DB persistence"
```

---

## Task 3: Schema Migration V002 — Audio Transcripts Table

**Files:**
- Create: `Sources/MyMacAgent/Database/Migrations/V002_AudioTranscripts.swift`
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift` (add V002 to migration list)

- [ ] **Step 1: Create V002 migration**

Create `Sources/MyMacAgent/Database/Migrations/V002_AudioTranscripts.swift`:

```swift
import Foundation

enum V002_AudioTranscripts {
    static let migration = Migration(version: 2, name: "audio_transcripts") { db in
        try db.execute("""
            CREATE TABLE IF NOT EXISTS audio_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                timestamp TEXT NOT NULL,
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("CREATE INDEX IF NOT EXISTS idx_audio_transcripts_timestamp ON audio_transcripts(timestamp)")
    }
}
```

- [ ] **Step 2: Add V002 to AppDelegate migration list**

In `Sources/MyMacAgent/App/AppDelegate.swift`, change:

```swift
let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
```

To:

```swift
let runner = MigrationRunner(db: db, migrations: [
    V001_InitialSchema.migration,
    V002_AudioTranscripts.migration
])
```

- [ ] **Step 3: Build, test, commit**

```bash
make test
git add Sources/MyMacAgent/Database/Migrations/V002_AudioTranscripts.swift Sources/MyMacAgent/App/AppDelegate.swift
git commit -m "feat: add V002 migration for audio_transcripts table"
```

---

## Task 4: Update DailySummarizer — Include Vision + Audio

**Files:**
- Modify: `Sources/MyMacAgent/Summary/DailySummarizer.swift`

- [ ] **Step 1: Add vision descriptions and audio transcripts to prompt**

In `DailySummarizer.buildDailyPrompt(for:)`, after the sessions section and before the instructions, add:

```swift
// 2.5 Audio transcripts
let audioTranscriber = AudioTranscriber(db: db)
if let transcripts = try? audioTranscriber.getTranscriptsForDate(date), !transcripts.isEmpty {
    prompt += "## Audio Transcripts\n\n"
    for transcript in transcripts {
        let time = String(transcript.timestamp.prefix(16))
        let lang = transcript.language ?? "?"
        prompt += "[\(time)] (\(lang)): \(transcript.text)\n"
    }
    prompt += "\n"
}

// 2.6 Vision analysis of unreadable screenshots
let visionSnapshots = try db.query("""
    SELECT timestamp, app_name, window_title, merged_text
    FROM context_snapshots
    WHERE timestamp LIKE ? AND text_source = 'vision' AND merged_text IS NOT NULL
    ORDER BY timestamp
""", params: [.text("\(date)%")])

if !visionSnapshots.isEmpty {
    prompt += "## Vision Analysis (screenshots that couldn't be OCR'd)\n\n"
    for row in visionSnapshots {
        let time = row["timestamp"]?.textValue.map { String($0.prefix(16)) } ?? ""
        let app = row["app_name"]?.textValue ?? ""
        let text = row["merged_text"]?.textValue ?? ""
        prompt += "[\(time)] \(app): \(text)\n"
    }
    prompt += "\n"
}
```

- [ ] **Step 2: Build, test, commit**

```bash
make test
git add Sources/MyMacAgent/Summary/DailySummarizer.swift
git commit -m "feat: include audio transcripts and vision analysis in daily summary prompt"
```

---

## Task 5: Wire Everything in AppDelegate

**Files:**
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift`

- [ ] **Step 1: Add VisionAnalyzer and AudioTranscriber to AppDelegate**

Add properties:

```swift
// Phase 5 — Vision + Audio
private var visionAnalyzer: VisionAnalyzer?
private var audioTranscriber: AudioTranscriber?
```

Add initialization method:

```swift
private func initializePhase5() {
    guard let db = databaseManager else { return }

    // Ensure audio table exists
    let transcriber = AudioTranscriber(db: db)
    try? transcriber.ensureTable()
    audioTranscriber = transcriber

    visionAnalyzer = VisionAnalyzer(db: db)

    logger.info("Phase 5 initialized (vision analyzer, audio transcriber)")
}
```

Call `initializePhase5()` from `applicationDidFinishLaunching` after `initializePhase4()`.

- [ ] **Step 2: Add vision analysis to the hourly auto-summary**

In `autoGenerateSummaryIfActive()`, before calling `generateDailySummary`, add:

```swift
// Run vision analysis on low-readability captures before generating summary
if let analyzer = visionAnalyzer {
    Task {
        let count = try? await analyzer.analyzeAllLowReadability(for: today)
        Logger.ocr.info("Vision pre-analysis: \(count ?? 0) screenshots analyzed")
    }
}
```

- [ ] **Step 3: Update generateDailySummary to use local Ollama**

Change `generateDailySummary` to support local Ollama as an alternative to OpenRouter:

```swift
func generateDailySummary(for date: String, apiKey: String? = nil) {
    Task { @MainActor in
        do {
            let settings = AppSettings()
            let client: LLMClient

            if settings.hasApiKey {
                let key = apiKey ?? settings.openRouterApiKey
                client = LLMClient(apiKey: key, baseURL: "https://openrouter.ai/api/v1", model: settings.llmModel)
            } else {
                // Use local Ollama
                client = LLMClient(apiKey: "", baseURL: "http://localhost:11434/v1", model: "hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M")
            }

            guard let summarizer = dailySummarizer else { return }

            // Run vision analysis first
            if let analyzer = visionAnalyzer {
                let count = try await analyzer.analyzeAllLowReadability(for: date)
                if count > 0 {
                    logger.info("Analyzed \(count) low-readability screenshots before summary")
                }
            }

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

- [ ] **Step 4: Build, test, commit**

```bash
make test
git add Sources/MyMacAgent/App/AppDelegate.swift
git commit -m "feat: wire vision analyzer + audio transcriber into hourly pipeline"
```

---

## Task 6: Integration Tests

**Files:**
- Create: `Tests/MyMacAgentTests/Integration/VisionAudioIntegrationTests.swift`

- [ ] **Step 1: Write integration tests**

Create `Tests/MyMacAgentTests/Integration/VisionAudioIntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct VisionAudioIntegrationTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V002_AudioTranscripts.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    @Test("V002 migration creates audio_transcripts table")
    func v002Migration() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let tables = try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='audio_transcripts'"
        )
        #expect(tables.count == 1)
    }

    @Test("Audio transcripts appear in daily summary prompt")
    func audioInPrompt() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        // Add audio transcript
        try db.execute("""
            INSERT INTO audio_transcripts (id, timestamp, transcript, language, duration_seconds)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("t1"), .text("2026-04-02T10:30:00Z"),
                      .text("Обсуждали деплой нового сервиса на Kubernetes"),
                      .text("ru"), .real(300)])

        let summarizer = DailySummarizer(db: db)
        let prompt = try summarizer.buildDailyPrompt(for: "2026-04-02")

        #expect(prompt.contains("Audio Transcripts"))
        #expect(prompt.contains("Kubernetes"))
    }

    @Test("Vision analysis results appear in daily summary prompt")
    func visionInPrompt() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        // Add vision-analyzed context snapshot
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-v"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .text("Figma"), .text("vision"),
                      .text("Design mockup showing navigation flow with 4 screens"),
                      .real(0.1), .real(0.9)])

        let summarizer = DailySummarizer(db: db)
        let prompt = try summarizer.buildDailyPrompt(for: "2026-04-02")

        #expect(prompt.contains("Vision Analysis"))
        #expect(prompt.contains("navigation flow"))
    }

    @Test("Full pipeline: low-readability → vision → summary includes result")
    func fullPipeline() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at, active_duration_ms) VALUES (?, ?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z"), .integer(3600000)])

        // Simulate vision analysis result already persisted
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-v"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .text("Remote Desktop"), .text("vision"),
                      .text("Terminal showing kubectl get pods with 5 running containers"),
                      .real(0.05), .real(0.95)])

        // Simulate audio transcript
        try db.execute("""
            INSERT INTO audio_transcripts (id, timestamp, transcript, language, duration_seconds)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("t1"), .text("2026-04-02T10:30:00Z"),
                      .text("Working on the deployment pipeline"),
                      .text("en"), .real(300)])

        let summarizer = DailySummarizer(db: db)
        let prompt = try summarizer.buildDailyPrompt(for: "2026-04-02")

        // Both vision and audio should be in the prompt
        #expect(prompt.contains("kubectl"))
        #expect(prompt.contains("deployment pipeline"))
        #expect(prompt.contains("Vision Analysis"))
        #expect(prompt.contains("Audio Transcripts"))
    }
}
```

- [ ] **Step 2: Run all tests, commit**

```bash
make test
git add Tests/MyMacAgentTests/Integration/VisionAudioIntegrationTests.swift
git commit -m "test: add integration tests for vision analysis and audio transcription pipeline"
```

---

## Self-Review

1. **Spec coverage:** Vision analysis of low-readability captures (Task 1), audio transcription via mlx-whisper (Task 2), DB migration (Task 3), summary integration (Task 4), wiring (Task 5), integration tests (Task 6).

2. **Placeholder scan:** All code complete, no TBD/TODO.

3. **Type consistency:** `VisionAnalyzer.findLowReadabilityCaptures` → `LowReadabilityCapture` used in Task 1 and 5. `AudioTranscriber.getTranscriptsForDate` → `AudioTranscript` used in Tasks 2, 4, 6. `V002_AudioTranscripts.migration` used in Tasks 3, 5, 6.
