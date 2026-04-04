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
            aiSessionsJson: nil, contextSwitchesJson: "{\"count\":5,\"window_start\":\"2026-04-02T09:00:00Z\",\"window_end\":\"2026-04-02T12:22:00Z\",\"mode\":\"hourly\"}",
            unfinishedItemsJson: nil,
            suggestedNotesJson: "[\"Swift Testing patterns\"]",
            generatedAt: "2026-04-02T23:00:00Z", modelName: "claude-3-haiku",
            tokenUsageInput: 1000, tokenUsageOutput: 300,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let markdown = try exporter.renderDailyNote(summary: summary)

        #expect(markdown.contains("# Hourly Log — 2026-04-02 09:00–12:22"))
        #expect(markdown.contains("## Summary"))
        #expect(markdown.contains("Productive day"))
        #expect(markdown.contains("## Main apps"))
        #expect(markdown.contains("Cursor"))
        #expect(markdown.contains("## Main topics"))
        #expect(markdown.contains("Swift concurrency"))
        #expect(markdown.contains("## Suggested notes"))
        #expect(markdown.contains("[[Swift Testing patterns]]"))
    }

    @Test("Renders rich structured markdown without flattening it")
    func rendersRichStructuredMarkdown() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Rich body.

            ## Детальный таймлайн
            - Block 1

            ## Проекты и код
            - Project
            """,
            topAppsJson: nil,
            topTopicsJson: nil,
            aiSessionsJson: nil,
            contextSwitchesJson: nil,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: nil,
            modelName: nil,
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let markdown = try exporter.renderDailyNote(summary: summary)

        #expect(markdown.contains("# Daily Log — 2026-04-03"))
        #expect(markdown.contains("## Детальный таймлайн"))
        #expect(markdown.contains("## Проекты и код"))
        #expect(!markdown.contains("## Main apps"))
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
        #expect(filePath.contains("/Daily/2026-04-02_"))
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

    @Test("Generates hourly timeline using overlap semantics")
    func generatesHourlyTimelineUsingWindowOverlap() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s-hourly"), .integer(1),
                      .text("2026-04-03T10:50:00Z"), .text("2026-04-03T11:20:00Z"),
                      .integer(1_800_000)])

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T12:00:00Z")!
        )
        let timeline = try exporter.buildTimeline(for: window)

        #expect(timeline.contains("11:00"))
        #expect(timeline.contains("11:20"))
        #expect(!timeline.contains("10:50"))
    }

    @Test("formatDuration formats minutes to hours and minutes")
    func formatDuration() {
        #expect(ObsidianExporter.formatDuration(minutes: 134) == "2h 14m")
        #expect(ObsidianExporter.formatDuration(minutes: 45) == "45m")
        #expect(ObsidianExporter.formatDuration(minutes: 60) == "1h 00m")
        #expect(ObsidianExporter.formatDuration(minutes: 0) == "0m")
    }

    @Test("Queues failed exports and drains them later")
    func queuesAndDrainsExports() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_vault_queue_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: "Queued note body.",
            topAppsJson: nil,
            topTopicsJson: nil,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T03:01:55Z","window_end":"2026-04-03T04:01:55Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T04:02:10Z",
            modelName: "test",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        try exporter.enqueueSummaryExport(summary, lastError: "simulated failure")

        let queued = try db.query("""
            SELECT status, last_error
            FROM sync_queue
            WHERE job_type = ?
        """, params: [.text("obsidian_export_summary")])
        #expect(queued.count == 1)
        #expect(queued[0]["status"]?.textValue == "pending")
        #expect(queued[0]["last_error"]?.textValue == "simulated failure")

        let drained = try exporter.drainQueuedExports()
        #expect(drained == 1)

        let filePath = (vaultDir as NSString).appendingPathComponent("Daily/2026-04-03_03-01-04-01.md")
        #expect(FileManager.default.fileExists(atPath: filePath))

        let finished = try db.query("""
            SELECT status
            FROM sync_queue
            WHERE job_type = ?
        """, params: [.text("obsidian_export_summary")])
        #expect(finished.first?["status"]?.textValue == "done")
    }

    @Test("cleanupSyncQueueHistory prunes stale completed rows")
    func cleanupSyncQueueHistoryPrunesStaleRows() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO sync_queue (job_type, entity_id, status, finished_at)
            VALUES (?, ?, 'done', ?)
        """, params: [
            .text("obsidian_export_summary"),
            .text("old-done"),
            .text("2026-03-01T00:00:00Z")
        ])
        try db.execute("""
            INSERT INTO sync_queue (job_type, entity_id, status, finished_at)
            VALUES (?, ?, 'failed', ?)
        """, params: [
            .text("audio_transcription"),
            .text("old-failed"),
            .text("2026-02-01T00:00:00Z")
        ])
        try db.execute("""
            INSERT INTO sync_queue (job_type, entity_id, status, finished_at)
            VALUES (?, ?, 'done', ?)
        """, params: [
            .text("obsidian_export_summary"),
            .text("recent-done"),
            .text(ISO8601DateFormatter().string(from: Date()))
        ])

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let deleted = try exporter.cleanupSyncQueueHistory(doneOlderThanDays: 7, failedOlderThanDays: 30)
        let remaining = try db.query("SELECT entity_id FROM sync_queue ORDER BY entity_id")

        #expect(deleted == 2)
        #expect(remaining.count == 1)
        #expect(remaining.first?["entity_id"]?.textValue == "recent-done")
    }

    @Test("Syncs knowledge maintenance draft artifacts and prunes stale files")
    func syncsKnowledgeMaintenanceDraftArtifacts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_drafts_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)

        let firstBatch = [
            KnowledgeDraftArtifact(
                fileName: "lesson-promotion-sqlite.md",
                title: "Draft Lesson Promotion — SQLite",
                markdown: "# Draft Lesson Promotion — SQLite\n"
            ),
            KnowledgeDraftArtifact(
                fileName: "consolidate-ocr-accuracy-into-ocr.md",
                title: "Draft Consolidation — OCR Accuracy into OCR",
                markdown: "# Draft Consolidation — OCR Accuracy into OCR\n"
            )
        ]

        let written = try exporter.syncKnowledgeDraftArtifacts(firstBatch)
        #expect(written.count == 2)

        let draftsDir = (vaultDir as NSString).appendingPathComponent("Knowledge/_drafts/Maintenance")
        let firstFile = (draftsDir as NSString).appendingPathComponent("lesson-promotion-sqlite.md")
        let secondFile = (draftsDir as NSString).appendingPathComponent("consolidate-ocr-accuracy-into-ocr.md")
        #expect(FileManager.default.fileExists(atPath: firstFile))
        #expect(FileManager.default.fileExists(atPath: secondFile))

        let secondBatch = [
            KnowledgeDraftArtifact(
                fileName: "lesson-promotion-sqlite.md",
                title: "Draft Lesson Promotion — SQLite",
                markdown: "# Updated Draft\n"
            )
        ]

        _ = try exporter.syncKnowledgeDraftArtifacts(secondBatch)
        #expect(FileManager.default.fileExists(atPath: firstFile))
        #expect(!FileManager.default.fileExists(atPath: secondFile))
        let updated = try String(contentsOfFile: firstFile, encoding: .utf8)
        #expect(updated.contains("# Updated Draft"))
    }
}
