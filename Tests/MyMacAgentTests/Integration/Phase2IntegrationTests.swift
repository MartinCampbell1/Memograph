import Testing
import AppKit
import Foundation
@testable import MyMacAgent

// Local mock provider to avoid dependency on OCRPipelineTests visibility
struct Phase2MockOCRProvider: OCRProvider {
    let name = "mock"
    let mockText: String
    let mockConfidence: Double
    func recognizeText(in image: NSImage) async throws -> OCRResult {
        OCRResult(rawText: mockText, confidence: mockConfidence, language: "en", processingMs: 10)
    }
}

struct Phase2IntegrationTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    private func makeTextImage(text: String) -> NSImage {
        let size = NSSize(width: 400, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: 40), withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    @Test("AX snapshot persists to database")
    func axSnapshotPersists() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let engine = AccessibilityContextEngine()
        let snapshot = AXSnapshotRecord(
            id: "ax-1", sessionId: "sess-1", captureId: nil,
            timestamp: "2026-04-02T10:00:00Z",
            focusedRole: "AXTextArea", focusedSubrole: nil,
            focusedTitle: "Editor", focusedValue: "Hello from test",
            selectedText: nil, textLen: 15, extractionStatus: "success"
        )
        try engine.persist(snapshot: snapshot, db: db)

        let rows = try db.query("SELECT * FROM ax_snapshots WHERE id = ?", params: [.text("ax-1")])
        #expect(rows.count == 1)
        #expect(rows[0]["focused_value"]?.textValue == "Hello from test")
    }

    @Test("OCR pipeline end-to-end with mock provider")
    func ocrPipelineE2E() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])
        try db.execute("INSERT INTO captures (id, session_id, timestamp, capture_type) VALUES (?, ?, ?, ?)",
            params: [.text("cap-1"), .text("sess-1"), .text("2026-04-02T10:00:00Z"), .text("window")])

        let provider = Phase2MockOCRProvider(mockText: "Test document text here", mockConfidence: 0.92)
        let pipeline = OCRPipeline(provider: provider, db: db)
        let result = try await pipeline.process(
            image: makeTextImage(text: "Test"),
            captureId: "cap-1",
            sessionId: "sess-1"
        )

        #expect(result.confidence == 0.92)
        #expect(result.normalizedText == "Test document text here")
        #expect(result.extractionStatus == "success")

        let rows = try db.query("SELECT * FROM ocr_snapshots")
        #expect(rows.count == 1)
    }

    @Test("Readability scorer drives mode transitions")
    func readabilityScorerModeTransitions() {
        let scheduler = CaptureScheduler(policyEngine: CapturePolicyEngine())

        // Start normal
        #expect(scheduler.currentMode == .normal)

        // Simulate unreadable content — canvas-like, no text, high visual change
        scheduler.updateReadability(ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0, ocrTextLen: 0,
            visualChangeScore: 0.9, isCanvasLike: true
        ))
        #expect(scheduler.currentMode == .highUncertainty)
        #expect(scheduler.currentInterval == 3)

        // Simulate readability recovery — good text from both AX and OCR
        scheduler.updateReadability(ReadabilityInput(
            axTextLen: 50, ocrConfidence: 0.9, ocrTextLen: 100,
            visualChangeScore: 0.05, isCanvasLike: false
        ))
        #expect(scheduler.currentMode == .recovery)

        // Continue good readability → back to normal
        scheduler.updateReadability(ReadabilityInput(
            axTextLen: 50, ocrConfidence: 0.9, ocrTextLen: 100,
            visualChangeScore: 0.05, isCanvasLike: false
        ))
        #expect(scheduler.currentMode == .normal)
        #expect(scheduler.currentInterval >= 30)
    }

    @Test("Full capture-to-readability flow")
    func fullCaptureFlow() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Setup
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        // Simulate AX extraction — use enough text to drive a high readability score
        let axTextContent = "let x = 42 // this is a code editor with plenty of text content"
        let axEngine = AccessibilityContextEngine()
        let axSnap = AXSnapshotRecord(
            id: UUID().uuidString, sessionId: "sess-1", captureId: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            focusedRole: "AXTextArea", focusedSubrole: nil,
            focusedTitle: "Code", focusedValue: axTextContent,
            selectedText: nil, textLen: axTextContent.count, extractionStatus: "success"
        )
        try axEngine.persist(snapshot: axSnap, db: db)

        // Simulate OCR
        try db.execute("INSERT INTO captures (id, session_id, timestamp, capture_type) VALUES (?, ?, ?, ?)",
            params: [.text("cap-1"), .text("sess-1"), .text("2026-04-02T10:00:00Z"), .text("window")])

        let ocrTextContent = "let x = 42 // recognized by OCR with high confidence"
        let mockOCR = Phase2MockOCRProvider(mockText: ocrTextContent, mockConfidence: 0.95)
        let pipeline = OCRPipeline(provider: mockOCR, db: db)
        let ocrResult = try await pipeline.process(
            image: makeTextImage(text: "code"),
            captureId: "cap-1",
            sessionId: "sess-1"
        )

        // Compute readability
        let readabilityInput = ReadabilityInput(
            axTextLen: axSnap.textLen,
            ocrConfidence: ocrResult.confidence,
            ocrTextLen: ocrResult.normalizedText?.count ?? 0,
            visualChangeScore: 0.05,
            isCanvasLike: false
        )
        let score = ReadabilityScorer.score(readabilityInput)
        let mode = ReadabilityScorer.classifyMode(score: score)

        // Good text from both sources → should be readable/normal
        #expect(score > 0.7)
        #expect(mode == .normal)

        // Verify DB has both records
        let axRows = try db.query("SELECT * FROM ax_snapshots")
        let ocrRows = try db.query("SELECT * FROM ocr_snapshots")
        #expect(axRows.count == 1)
        #expect(ocrRows.count == 1)
    }
}
