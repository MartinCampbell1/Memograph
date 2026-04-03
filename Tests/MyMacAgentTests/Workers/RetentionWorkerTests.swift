import Testing
import Foundation
@testable import MyMacAgent

struct RetentionWorkerTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V002_AudioTranscripts.migration,
            V003_PerformanceIndexes.migration,
            V004_AudioTranscriptDurability.migration
        ])
        try runner.runPending()
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        return (db, path)
    }

    @Test("Deletes captures older than retention days")
    func deletesOldCaptures() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Create old session + capture (60 days ago)
        let oldDate = "2026-02-01T10:00:00Z"
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("old-s"), .integer(1), .text(oldDate)])

        let tmpDir = NSTemporaryDirectory() + "retention_test_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let imagePath = (tmpDir as NSString).appendingPathComponent("old_capture.jpg")
        try Data("fake image".utf8).write(to: URL(fileURLWithPath: imagePath))

        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, retained)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("old-cap"), .text("old-s"), .text(oldDate),
                      .text("window"), .text(imagePath), .integer(1)])

        // Create recent capture
        let recentDate = ISO8601DateFormatter().string(from: Date())
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("new-s"), .integer(1), .text(recentDate)])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, retained)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("new-cap"), .text("new-s"), .text(recentDate),
                      .text("window"), .integer(1)])

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let deleted = try worker.cleanupOldCaptures()

        #expect(deleted == 1)
        // Old capture should be gone from DB
        let rows = try db.query("SELECT * FROM captures WHERE id = ?",
            params: [.text("old-cap")])
        #expect(rows.isEmpty)
        // Recent capture should remain
        let recent = try db.query("SELECT * FROM captures WHERE id = ?",
            params: [.text("new-cap")])
        #expect(recent.count == 1)
        // File should be deleted
        #expect(!FileManager.default.fileExists(atPath: imagePath))
    }

    @Test("Deletes old OCR snapshots")
    func deletesOldOCR() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let oldDate = "2026-02-01T10:00:00Z"
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("old-s"), .integer(1), .text(oldDate)])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type) VALUES (?, ?, ?, ?)
        """, params: [.text("old-cap"), .text("old-s"), .text(oldDate), .text("window")])
        try db.execute("""
            INSERT INTO ocr_snapshots (id, session_id, capture_id, timestamp, provider)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("old-ocr"), .text("old-s"), .text("old-cap"), .text(oldDate), .text("vision")])

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let deleted = try worker.cleanupOldOCRSnapshots()
        #expect(deleted >= 1)
    }

    @Test("Thins high-frequency captures keeping every Nth frame")
    func thinsHighFrequency() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO sessions (id, app_id, started_at, uncertainty_mode) VALUES (?, ?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-01-01T10:00:00Z"), .text("high_uncertainty")])

        let tmpDir = NSTemporaryDirectory() + "retention_thin_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        // Insert 10 captures for high-uncertainty session (clearly older than 1 day)
        for i in 0..<10 {
            let imagePath = (tmpDir as NSString).appendingPathComponent("cap-\(i).jpg")
            try Data("frame-\(i)".utf8).write(to: URL(fileURLWithPath: imagePath))
            try db.execute("""
                INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, file_size_bytes, sampling_mode, retained)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, params: [.text("cap-\(i)"), .text("s1"),
                          .text("2026-01-01T10:00:\(String(format: "%02d", i * 3))Z"),
                          .text("window"), .text(imagePath), .integer(7), .text("high_uncertainty"), .integer(1)])
        }

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let thinned = try worker.thinHighFrequencyCaptures(keepEveryNth: 3)

        // Should keep frames 0, 3, 6, 9 (4 kept) and mark 6 as not retained
        #expect(thinned > 0)
        let retained = try db.query("SELECT COUNT(*) as c FROM captures WHERE retained = 1")
        let retainedCount = retained[0]["c"]?.intValue ?? 0
        #expect(retainedCount < 10) // Some should be thinned

        let thinnedRow = try db.query("SELECT image_path, file_size_bytes FROM captures WHERE id = ?", params: [.text("cap-1")])
        #expect(thinnedRow.first?["image_path"]?.textValue == nil)
        #expect(thinnedRow.first?["file_size_bytes"]?.intValue == 0)
        #expect(!FileManager.default.fileExists(atPath: (tmpDir as NSString).appendingPathComponent("cap-1.jpg")))
    }

    @Test("runAll clears old context snapshots, session events and audio transcripts")
    func cleansExtendedRawTables() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let oldDate = "2026-02-01T10:00:00Z"
        try db.execute("INSERT INTO sessions (id, app_id, started_at, ended_at) VALUES (?, ?, ?, ?)",
            params: [.text("old-s"), .integer(1), .text(oldDate), .text("2026-02-01T11:00:00Z")])
        try db.execute("""
            INSERT INTO session_events (session_id, event_type, timestamp, payload_json)
            VALUES (?, ?, ?, ?)
        """, params: [.text("old-s"), .text("windowChanged"), .text(oldDate), .text("{}")])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-old"), .text("old-s"), .text(oldDate), .text("Test"), .text("old text"), .real(0.8), .real(0.2)])
        try db.execute("""
            INSERT INTO audio_transcripts (id, session_id, timestamp, duration_seconds, transcript, source)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("audio-old"), .text("old-s"), .text(oldDate), .real(12), .text("old transcript"), .text("system")])

        let worker = RetentionWorker(db: db, retentionDays: 30)
        try worker.runAll()

        #expect(try db.query("SELECT * FROM session_events WHERE session_id = ?", params: [.text("old-s")]).isEmpty)
        #expect(try db.query("SELECT * FROM context_snapshots WHERE session_id = ?", params: [.text("old-s")]).isEmpty)
        #expect(try db.query("SELECT * FROM audio_transcripts WHERE session_id = ?", params: [.text("old-s")]).isEmpty)
        #expect(try db.query("SELECT * FROM sessions WHERE id = ?", params: [.text("old-s")]).isEmpty)
    }

    @Test("Stats returns cleanup statistics")
    func stats() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let stats = try worker.stats()
        #expect(stats.totalCaptures >= 0)
        #expect(stats.totalOCRSnapshots >= 0)
        #expect(stats.totalSessionEvents >= 0)
        #expect(stats.totalAudioTranscripts >= 0)
    }

    @Test("runAll prunes stale sync queue history")
    func prunesStaleSyncQueueRows() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO sync_queue (job_type, entity_id, status, finished_at)
            VALUES (?, ?, 'done', ?)
        """, params: [
            .text("obsidian_export_summary"),
            .text("old-sync-row"),
            .text("2026-03-01T00:00:00Z")
        ])

        let worker = RetentionWorker(db: db, retentionDays: 30)
        try worker.runAll()

        let rows = try db.query("SELECT * FROM sync_queue WHERE entity_id = ?", params: [.text("old-sync-row")])
        #expect(rows.isEmpty)
    }
}
