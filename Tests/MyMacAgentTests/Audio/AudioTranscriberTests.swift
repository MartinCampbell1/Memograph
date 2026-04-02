import Testing
import Foundation
@testable import MyMacAgent

struct AudioTranscriberTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("Transcriber initializes with correct paths")
    func initializes() {
        let transcriber = AudioTranscriber(db: DatabaseManager.forTesting())
        #expect(transcriber.venvPath.contains(".venv"))
    }

    @Test("persistTranscript saves to DB")
    func persistsTranscript() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Create audio_transcripts table (V002 migration)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS audio_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                timestamp TEXT NOT NULL,
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let transcriber = AudioTranscriber(db: db)
        try transcriber.persistTranscript(
            sessionId: "s1",
            text: "Обсуждали архитектуру нового сервиса",
            language: "ru",
            durationSeconds: 300
        )

        let rows = try db.query("SELECT * FROM audio_transcripts")
        #expect(rows.count == 1)
        #expect(rows[0]["transcript"]?.textValue?.contains("архитектуру") == true)
        #expect(rows[0]["language"]?.textValue == "ru")
    }

    @Test("getTranscriptsForDate returns ordered transcripts")
    func getsTranscripts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            CREATE TABLE IF NOT EXISTS audio_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                timestamp TEXT NOT NULL,
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            INSERT INTO audio_transcripts (id, timestamp, transcript, duration_seconds)
            VALUES (?, ?, ?, ?)
        """, params: [.text("t1"), .text("2026-04-02T10:00:00Z"), .text("First chunk"), .real(300)])
        try db.execute("""
            INSERT INTO audio_transcripts (id, timestamp, transcript, duration_seconds)
            VALUES (?, ?, ?, ?)
        """, params: [.text("t2"), .text("2026-04-02T10:05:00Z"), .text("Second chunk"), .real(300)])

        let transcriber = AudioTranscriber(db: db)
        let transcripts = try transcriber.getTranscriptsForDate("2026-04-02")

        #expect(transcripts.count == 2)
        #expect(transcripts[0].text == "First chunk")
    }
}
