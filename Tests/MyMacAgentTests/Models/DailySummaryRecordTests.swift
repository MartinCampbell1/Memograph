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
