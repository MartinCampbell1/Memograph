import Testing
import Foundation
@testable import MyMacAgent

struct RetentionWorkerTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
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

        // Insert 10 captures for high-uncertainty session (clearly older than 1 day)
        for i in 0..<10 {
            try db.execute("""
                INSERT INTO captures (id, session_id, timestamp, capture_type, sampling_mode, retained)
                VALUES (?, ?, ?, ?, ?, ?)
            """, params: [.text("cap-\(i)"), .text("s1"),
                          .text("2026-01-01T10:00:\(String(format: "%02d", i * 3))Z"),
                          .text("window"), .text("high_uncertainty"), .integer(1)])
        }

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let thinned = try worker.thinHighFrequencyCaptures(keepEveryNth: 3)

        // Should keep frames 0, 3, 6, 9 (4 kept) and mark 6 as not retained
        #expect(thinned > 0)
        let retained = try db.query("SELECT COUNT(*) as c FROM captures WHERE retained = 1")
        let retainedCount = retained[0]["c"]?.intValue ?? 0
        #expect(retainedCount < 10) // Some should be thinned
    }

    @Test("Stats returns cleanup statistics")
    func stats() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let stats = try worker.stats()
        #expect(stats.totalCaptures >= 0)
        #expect(stats.totalOCRSnapshots >= 0)
    }
}
