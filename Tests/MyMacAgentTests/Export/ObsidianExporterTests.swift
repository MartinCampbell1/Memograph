import Testing
import Foundation
@testable import MyMacAgent

struct ObsidianExporterTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let makassar = TimeZone(secondsFromGMT: 8 * 3600)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("Renders daily note markdown")
    func rendersDailyNote() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Seed sessions for app duration calculation
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1), .text("2026-04-02T09:00:00Z"),
                      .text("2026-04-02T11:14:00Z"), .integer(8040000)])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s2"), .integer(2), .text("2026-04-02T11:14:00Z"),
                      .text("2026-04-02T12:22:00Z"), .integer(4080000)])

        let summary = DailySummaryRecord(
            date: "2026-04-02",
            summaryText: "Productive day focused on Swift development and testing.",
            topAppsJson: "[{\"name\":\"Cursor\",\"duration_min\":134},{\"name\":\"Safari\",\"duration_min\":68}]",
            topTopicsJson: "[\"Swift concurrency\",\"Testing\"]",
            aiSessionsJson: nil, contextSwitchesJson: "{\"count\":5}",
            unfinishedItemsJson: nil,
            suggestedNotesJson: "[\"Swift Testing patterns\"]",
            generatedAt: "2026-04-02T23:00:00Z", modelName: "claude-3-haiku",
            tokenUsageInput: 1000, tokenUsageOutput: 300,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let markdown = try exporter.renderDailyNote(summary: summary)

        #expect(markdown.contains("# Daily Log — 2026-04-02"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("Productive day"))
        #expect(markdown.contains("## Main apps"))
        #expect(markdown.contains("Cursor"))
        #expect(markdown.contains("## Main topics"))
        #expect(markdown.contains("Swift concurrency"))
        #expect(markdown.contains("## Suggested notes"))
        #expect(markdown.contains("[[Swift Testing patterns]]"))
    }

    @Test("Writes daily note to vault directory")
    func writesToVault() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_vault_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let summary = DailySummaryRecord(
            date: "2026-04-02", summaryText: "Good day.",
            topAppsJson: nil, topTopicsJson: nil,
            aiSessionsJson: nil, contextSwitchesJson: nil,
            unfinishedItemsJson: nil, suggestedNotesJson: nil,
            generatedAt: nil, modelName: nil,
            tokenUsageInput: 0, tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let filePath = try exporter.exportDailyNote(summary: summary)

        #expect(FileManager.default.fileExists(atPath: filePath))
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("# Daily Log — 2026-04-02"))
    }

    @Test("Generates timeline from sessions")
    func generatesTimeline() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:10:00Z"), .text("2026-04-02T09:32:00Z"),
                      .integer(1320000)])

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let timeline = try exporter.buildTimeline(for: "2026-04-02")

        #expect(timeline.contains("09:10"))
        #expect(timeline.contains("09:32"))
        #expect(timeline.contains("TestApp"))
    }

    @Test("Generates timeline using local times for the selected day")
    func generatesTimelineForLocalDay() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s-local"), .integer(1),
                      .text("2026-04-02T16:10:00Z"), .text("2026-04-02T16:32:00Z"),
                      .integer(1320000)])

        let exporter = ObsidianExporter(db: db, timeZone: makassar)
        let timeline = try exporter.buildTimeline(for: "2026-04-03")

        #expect(timeline.contains("00:10"))
        #expect(timeline.contains("00:32"))
        #expect(timeline.contains("TestApp"))
    }

    @Test("formatDuration formats minutes to hours and minutes")
    func formatDuration() {
        #expect(ObsidianExporter.formatDuration(minutes: 134) == "2h 14m")
        #expect(ObsidianExporter.formatDuration(minutes: 45) == "45m")
        #expect(ObsidianExporter.formatDuration(minutes: 60) == "1h 00m")
        #expect(ObsidianExporter.formatDuration(minutes: 0) == "0m")
    }
}
