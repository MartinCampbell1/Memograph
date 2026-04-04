import Testing
import Foundation
@testable import MyMacAgent

struct Phase3IntegrationTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V002_AudioTranscripts.migration,
            V004_AudioTranscriptDurability.migration
        ])
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

        let summarizer = DailySummarizer(db: db, timeZone: utc)
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

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let filePath = try exporter.exportDailyNote(summary: summary)

        #expect(FileManager.default.fileExists(atPath: filePath))

        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("# Дневной лог — 2026-04-02"))
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
        let summarizer = DailySummarizer(db: db, timeZone: utc)
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
        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let filePath = try exporter.exportDailyNote(summary: summary)
        #expect(FileManager.default.fileExists(atPath: filePath))

        // Verify everything is in DB
        let ctxRows = try db.query("SELECT * FROM context_snapshots")
        let sumRows = try db.query("SELECT * FROM daily_summaries")
        #expect(ctxRows.count == 1)
        #expect(sumRows.count == 1)
    }
}
