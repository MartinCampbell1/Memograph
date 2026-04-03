import Testing
import Foundation
@testable import MyMacAgent

struct DailySummarizerTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let makassar = TimeZone(secondsFromGMT: 8 * 3600)!

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

    private func seedTestData(db: DatabaseManager, date: String = "2026-04-02") throws {
        // Apps
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

        let summarizer = DailySummarizer(db: db, timeZone: utc)
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

        let summarizer = DailySummarizer(db: db, timeZone: utc)
        let data = try summarizer.collectSessionData(for: "2026-04-02")

        #expect(data.count == 2)
        #expect(data[0].appName == "Cursor")
        #expect(data[0].contextTexts.count >= 1)
    }

    @Test("persistSummary saves to daily_summaries")
    func persistSummary() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summarizer = DailySummarizer(db: db, timeZone: utc)
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

    @Test("buildPrompt uses local day boundaries and local times")
    func buildPromptForLocalDay() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-local"), .integer(1),
            .text("2026-04-02T16:30:00Z"), .text("2026-04-02T17:00:00Z"),
            .integer(1800000), .text("normal")
        ])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name, bundle_id,
                window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-local"), .text("sess-local"), .text("2026-04-02T16:40:00Z"),
            .text("Cursor"), .text("com.cursor"),
            .text("night.swift"), .text("ax+ocr"),
            .text("Debugging a timezone edge case"),
            .real(0.95), .real(0.05)
        ])

        let summarizer = DailySummarizer(db: db, timeZone: makassar)
        let prompt = try summarizer.buildDailyPrompt(for: "2026-04-03")

        #expect(prompt.contains("Cursor"))
        #expect(prompt.contains("00:30"))
        #expect(prompt.contains("01:00"))
        #expect(!prompt.contains("16:30"))
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

        ## Продолжить далее
        - Finish implementing the capture scheduler
        """

        let parsed = DailySummarizer.parseSummaryResponse(response)
        #expect(parsed.summaryText.contains("productive day"))
        #expect(parsed.topics.contains("Swift concurrency"))
        #expect(parsed.suggestedNotes.count == 2)
        #expect(parsed.continueTomorrow != nil)
    }

    @Test("buildFallbackSummary creates local report when LLM fails")
    func buildFallbackSummary() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedTestData(db: db)

        let summarizer = DailySummarizer(db: db, timeZone: utc)
        let summary = try summarizer.buildFallbackSummary(
            for: "2026-04-02",
            failureReason: "HTTP 500"
        )

        #expect(summary.generationStatus == "fallback")
        #expect(summary.modelName == "local-fallback")
        #expect(summary.summaryText?.contains("HTTP 500") == true)
    }

    @Test("shouldGenerateSummary skips previous day when summary already exists")
    func shouldGenerateSummaryForPreviousDay() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedTestData(db: db)

        let summarizer = DailySummarizer(db: db, timeZone: utc)
        try summarizer.persistSummary(
            DailySummaryRecord(
                date: "2026-04-02",
                summaryText: "Done",
                topAppsJson: nil,
                topTopicsJson: nil,
                aiSessionsJson: nil,
                contextSwitchesJson: nil,
                unfinishedItemsJson: nil,
                suggestedNotesJson: nil,
                generatedAt: "2026-04-02T23:00:00Z",
                modelName: "test",
                tokenUsageInput: 0,
                tokenUsageOutput: 0,
                generationStatus: "success"
            )
        )

        let shouldGenerate = try summarizer.shouldGenerateSummary(
            for: "2026-04-02",
            currentLocalDate: "2026-04-03",
            minimumIntervalMinutes: 60
        )

        #expect(!shouldGenerate)
    }

    @Test("pendingSummaryWindows advance from covered window end instead of generated_at")
    func pendingSummaryWindowsUseCoveredWindowEnd() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summarizer = DailySummarizer(
            db: db,
            timeZone: makassar,
            now: { ISO8601DateFormatter().date(from: "2026-04-03T04:05:00Z")! }
        )

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-window"), .integer(1),
            .text("2026-04-03T02:10:00Z"), .text("2026-04-03T03:40:00Z"),
            .integer(5400000), .text("normal")
        ])

        try summarizer.persistSummary(
            DailySummaryRecord(
                date: "2026-04-03",
                summaryText: "Earlier hour",
                topAppsJson: nil,
                topTopicsJson: nil,
                aiSessionsJson: nil,
                contextSwitchesJson: """
                {"window_start":"2026-04-03T02:01:55Z","window_end":"2026-04-03T03:01:55Z","mode":"hourly"}
                """,
                unfinishedItemsJson: nil,
                suggestedNotesJson: nil,
                generatedAt: "2026-04-03T03:09:55Z",
                modelName: "test",
                tokenUsageInput: 0,
                tokenUsageOutput: 0,
                generationStatus: "success"
            )
        )

        let windows = try summarizer.pendingSummaryWindows(
            for: "2026-04-03",
            currentLocalDate: "2026-04-03",
            minimumIntervalMinutes: 60
        )
        let activeWindow = try summarizer.summaryWindow(for: "2026-04-03")

        #expect(windows.count == 1)
        #expect(activeWindow?.start == ISO8601DateFormatter().date(from: "2026-04-03T03:01:55Z"))
        #expect(windows.first?.start == ISO8601DateFormatter().date(from: "2026-04-03T03:01:55Z"))
        #expect(windows.first?.end == ISO8601DateFormatter().date(from: "2026-04-03T04:01:55Z"))
    }

    @Test("collectSessionData includes overlapping sessions and filters context to the report window")
    func collectSessionDataUsesWindowOverlap() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-overlap"), .integer(1),
            .text("2026-04-03T01:50:00Z"), .null,
            .integer(0), .text("normal")
        ])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name, bundle_id,
                window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-before"), .text("sess-overlap"), .text("2026-04-03T01:55:00Z"),
            .text("Cursor"), .text("com.cursor"),
            .text("before.swift"), .text("ax+ocr"),
            .text("Context before the window"),
            .real(0.9), .real(0.05)
        ])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name, bundle_id,
                window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-inside"), .text("sess-overlap"), .text("2026-04-03T02:15:00Z"),
            .text("Cursor"), .text("com.cursor"),
            .text("inside.swift"), .text("ax+ocr"),
            .text("Context inside the window"),
            .real(0.9), .real(0.05)
        ])

        let summarizer = DailySummarizer(
            db: db,
            timeZone: utc,
            now: { ISO8601DateFormatter().date(from: "2026-04-03T03:00:00Z")! }
        )
        let window = summarizer.summaryWindow(
            for: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T02:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T03:00:00Z")!
        )

        let sessions = try summarizer.collectSessionData(for: window)

        #expect(sessions.count == 1)
        #expect(sessions[0].contextTexts == ["Context inside the window"])
        #expect(sessions[0].windowTitles == ["inside.swift"])
        #expect(sessions[0].durationMs == 3_600_000)
    }
}
