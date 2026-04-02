import Testing
@testable import MyMacAgent

struct OCRSnapshotRecordTests {

    @Test("Parse OCRSnapshotRecord from complete SQLiteRow")
    func parseFromCompleteRow() {
        let row: SQLiteRow = [
            "id": .text("ocr-1"),
            "session_id": .text("sess-1"),
            "capture_id": .text("cap-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"),
            "provider": .text("vision"),
            "raw_text": .text("Hello World"),
            "normalized_text": .text("hello world"),
            "text_hash": .text("abc123"),
            "confidence": .real(0.95),
            "language": .text("en"),
            "processing_ms": .integer(42),
            "extraction_status": .text("ok")
        ]
        let record = OCRSnapshotRecord(row: row)
        #expect(record != nil)
        #expect(record?.id == "ocr-1")
        #expect(record?.sessionId == "sess-1")
        #expect(record?.captureId == "cap-1")
        #expect(record?.timestamp == "2026-04-02T10:00:00Z")
        #expect(record?.provider == "vision")
        #expect(record?.rawText == "Hello World")
        #expect(record?.normalizedText == "hello world")
        #expect(record?.textHash == "abc123")
        #expect(record?.confidence == 0.95)
        #expect(record?.language == "en")
        #expect(record?.processingMs == 42)
        #expect(record?.extractionStatus == "ok")
    }

    @Test("Return nil for missing required fields")
    func returnNilForMissingRequiredFields() {
        // Missing id
        let rowMissingId: SQLiteRow = [
            "session_id": .text("sess-1"),
            "capture_id": .text("cap-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"),
            "provider": .text("vision")
        ]
        #expect(OCRSnapshotRecord(row: rowMissingId) == nil)

        // Missing capture_id
        let rowMissingCaptureId: SQLiteRow = [
            "id": .text("ocr-1"),
            "session_id": .text("sess-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"),
            "provider": .text("vision")
        ]
        #expect(OCRSnapshotRecord(row: rowMissingCaptureId) == nil)

        // Missing provider
        let rowMissingProvider: SQLiteRow = [
            "id": .text("ocr-1"),
            "session_id": .text("sess-1"),
            "capture_id": .text("cap-1"),
            "timestamp": .text("2026-04-02T10:00:00Z")
        ]
        #expect(OCRSnapshotRecord(row: rowMissingProvider) == nil)
    }

    @Test("hasUsableText reflects confidence and normalizedText")
    func hasUsableTextReflectsConfidenceAndText() {
        // True: confidence >= 0.3 and normalizedText is non-empty
        let usable = OCRSnapshotRecord(
            id: "ocr-1", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "2026-04-02T10:00:00Z", provider: "vision",
            rawText: nil, normalizedText: "hello world",
            textHash: nil, confidence: 0.3, language: nil,
            processingMs: nil, extractionStatus: nil
        )
        #expect(usable.hasUsableText == true)

        // False: confidence < 0.3 even with non-empty normalizedText
        let lowConfidence = OCRSnapshotRecord(
            id: "ocr-2", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "2026-04-02T10:00:00Z", provider: "vision",
            rawText: nil, normalizedText: "hello world",
            textHash: nil, confidence: 0.29, language: nil,
            processingMs: nil, extractionStatus: nil
        )
        #expect(lowConfidence.hasUsableText == false)

        // False: confidence >= 0.3 but normalizedText is empty
        let emptyText = OCRSnapshotRecord(
            id: "ocr-3", sessionId: "sess-1", captureId: "cap-1",
            timestamp: "2026-04-02T10:00:00Z", provider: "vision",
            rawText: nil, normalizedText: nil,
            textHash: nil, confidence: 0.9, language: nil,
            processingMs: nil, extractionStatus: nil
        )
        #expect(emptyText.hasUsableText == false)
    }
}
