import Testing
import Foundation
@testable import MyMacAgent

struct V001_InitialSchemaTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        return (db, path)
    }

    @Test("Migration creates all 12 tables")
    func createsAllTables() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()

        let expectedTables = [
            "apps", "windows", "sessions", "session_events",
            "captures", "ax_snapshots", "ocr_snapshots",
            "context_snapshots", "daily_summaries",
            "knowledge_notes", "app_rules", "sync_queue"
        ]

        for table in expectedTables {
            let rows = try db.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                params: [.text(table)]
            )
            #expect(rows.count == 1, "Table '\(table)' should exist")
        }
    }

    @Test("Can insert and read app")
    func canInsertApp() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()

        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")]
        )

        let rows = try db.query("SELECT bundle_id, app_name FROM apps")
        #expect(rows.count == 1)
        #expect(rows[0]["bundle_id"]?.textValue == "com.apple.Safari")
    }

    @Test("Can insert session with FK")
    func canInsertSession() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()

        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")]
        )

        try db.execute(
            "INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")]
        )

        let rows = try db.query("SELECT id, app_id FROM sessions")
        #expect(rows.count == 1)
        #expect(rows[0]["id"]?.textValue == "sess-1")
    }
}
