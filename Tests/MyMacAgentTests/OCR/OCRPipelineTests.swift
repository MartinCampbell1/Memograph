import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct MockOCRProvider: OCRProvider {
    let name = "mock"
    let mockText: String
    let mockConfidence: Double
    func recognizeText(in image: NSImage) async throws -> OCRResult {
        OCRResult(rawText: mockText, confidence: mockConfidence, language: "en", processingMs: 10)
    }
}

struct OCRPipelineTests {

    // MARK: - Helpers

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "ocr_pipeline_test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    /// Inserts the minimal app, session, and capture rows required by FK constraints.
    private func insertFixtures(db: DatabaseManager, sessionId: String, captureId: String) throws {
        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test.ocr"), .text("TestApp")]
        )
        try db.execute(
            "INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text(sessionId), .integer(1), .text("2026-04-02T10:00:00Z")]
        )
        try db.execute(
            """
            INSERT INTO captures
                (id, session_id, timestamp, capture_type)
            VALUES (?, ?, ?, ?)
            """,
            params: [
                .text(captureId),
                .text(sessionId),
                .text("2026-04-02T10:00:00Z"),
                .text("screen")
            ]
        )
    }

    private func makeBlankImage() -> NSImage {
        NSImage(size: NSSize(width: 10, height: 10))
    }

    // MARK: - Tests

    @Test("Pipeline returns OCRSnapshotRecord with normalized text")
    func pipelineReturnsRecordWithNormalizedText() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sessionId = UUID().uuidString
        let captureId = UUID().uuidString
        try insertFixtures(db: db, sessionId: sessionId, captureId: captureId)

        let provider = MockOCRProvider(mockText: "  Hello   World  ", mockConfidence: 0.9)
        let pipeline = OCRPipeline(provider: provider, db: db)

        let record = try await pipeline.process(
            image: makeBlankImage(),
            captureId: captureId,
            sessionId: sessionId
        )

        #expect(record.captureId == captureId)
        #expect(record.sessionId == sessionId)
        #expect(record.provider == "mock")
        #expect(record.normalizedText == "Hello World")
        #expect(record.extractionStatus == "success")
        #expect(record.confidence == 0.9)
    }

    @Test("Pipeline persists result to ocr_snapshots table")
    func pipelinePersistsToDatabase() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sessionId = UUID().uuidString
        let captureId = UUID().uuidString
        try insertFixtures(db: db, sessionId: sessionId, captureId: captureId)

        let provider = MockOCRProvider(mockText: "Persisted text", mockConfidence: 0.85)
        let pipeline = OCRPipeline(provider: provider, db: db)

        let record = try await pipeline.process(
            image: makeBlankImage(),
            captureId: captureId,
            sessionId: sessionId
        )

        let rows = try db.query(
            "SELECT * FROM ocr_snapshots WHERE id = ?",
            params: [.text(record.id)]
        )

        #expect(rows.count == 1)
        #expect(rows[0]["id"]?.textValue == record.id)
        #expect(rows[0]["session_id"]?.textValue == sessionId)
        #expect(rows[0]["capture_id"]?.textValue == captureId)
        #expect(rows[0]["normalized_text"]?.textValue == "Persisted text")
        #expect(rows[0]["extraction_status"]?.textValue == "success")
    }

    @Test("Pipeline marks second identical text as duplicate")
    func pipelineMarksDuplicateOnIdenticalText() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let sessionId = UUID().uuidString
        let captureId1 = UUID().uuidString
        let captureId2 = UUID().uuidString
        try insertFixtures(db: db, sessionId: sessionId, captureId: captureId1)

        // Insert second capture row
        try db.execute(
            """
            INSERT INTO captures
                (id, session_id, timestamp, capture_type)
            VALUES (?, ?, ?, ?)
            """,
            params: [
                .text(captureId2),
                .text(sessionId),
                .text("2026-04-02T10:00:01Z"),
                .text("screen")
            ]
        )

        let provider = MockOCRProvider(mockText: "Duplicate content", mockConfidence: 0.95)
        let pipeline = OCRPipeline(provider: provider, db: db)

        let first = try await pipeline.process(
            image: makeBlankImage(),
            captureId: captureId1,
            sessionId: sessionId
        )

        #expect(first.extractionStatus == "success")

        let second = try await pipeline.process(
            image: makeBlankImage(),
            captureId: captureId2,
            sessionId: sessionId,
            previousHash: first.textHash
        )

        #expect(second.extractionStatus == "duplicate")
        #expect(second.textHash == first.textHash)
    }
}
