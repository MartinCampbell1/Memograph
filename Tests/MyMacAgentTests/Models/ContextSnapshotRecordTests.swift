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
