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
