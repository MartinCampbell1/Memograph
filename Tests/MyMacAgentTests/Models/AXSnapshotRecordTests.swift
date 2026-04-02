import Testing
@testable import MyMacAgent

struct AXSnapshotRecordTests {

    @Test("Parse AXSnapshotRecord from complete SQLiteRow")
    func parseFromCompleteRow() {
        let row: SQLiteRow = [
            "id": .text("ax-1"),
            "session_id": .text("sess-1"),
            "capture_id": .text("cap-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"),
            "focused_role": .text("AXTextField"),
            "focused_subrole": .text("AXSearchField"),
            "focused_title": .text("Search"),
            "focused_value": .text("hello"),
            "selected_text": .text("hel"),
            "text_len": .integer(500),
            "extraction_status": .text("ok")
        ]
        let record = AXSnapshotRecord(row: row)
        #expect(record != nil)
        #expect(record?.id == "ax-1")
        #expect(record?.sessionId == "sess-1")
        #expect(record?.captureId == "cap-1")
        #expect(record?.timestamp == "2026-04-02T10:00:00Z")
        #expect(record?.focusedRole == "AXTextField")
        #expect(record?.focusedSubrole == "AXSearchField")
        #expect(record?.focusedTitle == "Search")
        #expect(record?.focusedValue == "hello")
        #expect(record?.selectedText == "hel")
        #expect(record?.textLen == 500)
        #expect(record?.extractionStatus == "ok")
    }

    @Test("Return nil for missing required fields")
    func returnNilForMissingRequiredFields() {
        // Missing id
        let rowMissingId: SQLiteRow = [
            "session_id": .text("sess-1"),
            "timestamp": .text("2026-04-02T10:00:00Z")
        ]
        #expect(AXSnapshotRecord(row: rowMissingId) == nil)

        // Missing session_id
        let rowMissingSession: SQLiteRow = [
            "id": .text("ax-1"),
            "timestamp": .text("2026-04-02T10:00:00Z")
        ]
        #expect(AXSnapshotRecord(row: rowMissingSession) == nil)

        // Missing timestamp
        let rowMissingTimestamp: SQLiteRow = [
            "id": .text("ax-1"),
            "session_id": .text("sess-1")
        ]
        #expect(AXSnapshotRecord(row: rowMissingTimestamp) == nil)
    }

    @Test("totalTextLength returns textLen")
    func totalTextLengthReturnsTextLen() {
        let record = AXSnapshotRecord(
            id: "ax-1", sessionId: "sess-1", captureId: nil,
            timestamp: "2026-04-02T10:00:00Z",
            focusedRole: nil, focusedSubrole: nil, focusedTitle: nil,
            focusedValue: nil, selectedText: nil,
            textLen: 1234, extractionStatus: nil
        )
        #expect(record.totalTextLength == 1234)
    }

    @Test("hasUsableText is true when textLen > 0, false when 0")
    func hasUsableTextReflectsTextLen() {
        let withText = AXSnapshotRecord(
            id: "ax-1", sessionId: "sess-1", captureId: nil,
            timestamp: "2026-04-02T10:00:00Z",
            focusedRole: nil, focusedSubrole: nil, focusedTitle: nil,
            focusedValue: nil, selectedText: nil,
            textLen: 42, extractionStatus: nil
        )
        #expect(withText.hasUsableText == true)

        let withoutText = AXSnapshotRecord(
            id: "ax-2", sessionId: "sess-1", captureId: nil,
            timestamp: "2026-04-02T10:00:00Z",
            focusedRole: nil, focusedSubrole: nil, focusedTitle: nil,
            focusedValue: nil, selectedText: nil,
            textLen: 0, extractionStatus: nil
        )
        #expect(withoutText.hasUsableText == false)
    }
}
