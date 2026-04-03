import Testing
import Foundation
@testable import MyMacAgent

struct AudioTranscriberTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let makassar = TimeZone(secondsFromGMT: 8 * 3600)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V002_AudioTranscripts.migration,
            V004_AudioTranscriptDurability.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    @Test("Transcriber initializes with correct paths")
    func initializes() {
        let transcriber = AudioTranscriber(db: DatabaseManager.forTesting(), timeZone: utc)
        #expect(transcriber.venvPath.contains(".venv"))
    }

    @Test("persistTranscript saves to DB")
    func persistsTranscript() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let transcriber = AudioTranscriber(db: db, timeZone: utc)
        try transcriber.persistTranscript(
            sessionId: "s1",
            text: "Обсуждали архитектуру нового сервиса",
            language: "ru",
            durationSeconds: 300,
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z"),
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:05:00Z")
        )

        let rows = try db.query("SELECT * FROM audio_transcripts")
        #expect(rows.count == 1)
        #expect(rows[0]["transcript"]?.textValue?.contains("архитектуру") == true)
        #expect(rows[0]["language"]?.textValue == "ru")
        #expect(rows[0]["segment_started_at"]?.textValue == "2026-04-02T10:00:00Z")
        #expect(rows[0]["segment_ended_at"]?.textValue == "2026-04-02T10:05:00Z")
    }

    @Test("getTranscriptsForDate returns ordered transcripts")
    func getsTranscripts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO audio_transcripts
                (id, timestamp, segment_started_at, segment_ended_at, persisted_at, transcript, duration_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("t1"),
            .text("2026-04-02T10:00:00Z"),
            .text("2026-04-02T10:00:00Z"),
            .text("2026-04-02T10:05:00Z"),
            .text("2026-04-02T10:05:05Z"),
            .text("First chunk"),
            .real(300)
        ])
        try db.execute("""
            INSERT INTO audio_transcripts
                (id, timestamp, segment_started_at, segment_ended_at, persisted_at, transcript, duration_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("t2"),
            .text("2026-04-02T10:05:00Z"),
            .text("2026-04-02T10:05:00Z"),
            .text("2026-04-02T10:10:00Z"),
            .text("2026-04-02T10:10:03Z"),
            .text("Second chunk"),
            .real(300)
        ])

        let transcriber = AudioTranscriber(db: db, timeZone: utc)
        let transcripts = try transcriber.getTranscriptsForDate("2026-04-02")

        #expect(transcripts.count == 2)
        #expect(transcripts[0].text == "First chunk")
    }

    @Test("getTranscriptsForDate uses local day boundaries")
    func getsTranscriptsForLocalDay() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO audio_transcripts
                (id, timestamp, segment_started_at, segment_ended_at, persisted_at, transcript, duration_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("t-local"),
            .text("2026-04-02T16:05:00Z"),
            .text("2026-04-02T16:05:00Z"),
            .text("2026-04-02T16:06:00Z"),
            .text("2026-04-02T16:06:01Z"),
            .text("Late-night note"),
            .real(60)
        ])

        let transcriber = AudioTranscriber(db: db, timeZone: makassar)
        let transcripts = try transcriber.getTranscriptsForDate("2026-04-03")

        #expect(transcripts.count == 1)
        #expect(transcripts[0].text == "Late-night note")
    }

    @Test("Queued transcription retries without deleting the source file on failure")
    func queuedTranscriptionRetries() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("queued-audio-\(UUID().uuidString).wav")
        try Data("fake audio".utf8).write(to: URL(fileURLWithPath: audioPath))
        defer { try? FileManager.default.removeItem(atPath: audioPath) }

        let transcriber = AudioTranscriber(
            db: db,
            venvPath: "/missing",
            scriptPath: "/missing",
            runtimeStatus: .missingPython("/missing"),
            timeZone: utc
        )
        try transcriber.enqueueTranscriptionJob(
            path: audioPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:01:00Z")!
        )

        let drained = try await transcriber.drainQueuedTranscriptions(limit: 1)
        #expect(drained == 0)
        #expect(FileManager.default.fileExists(atPath: audioPath))

        let rows = try db.query("""
            SELECT status, retry_count
            FROM sync_queue
            WHERE job_type = ?
        """, params: [.text("audio_transcription")])
        #expect(rows.count == 1)
        #expect(rows[0]["status"]?.textValue == "failed")
        #expect(rows[0]["retry_count"]?.intValue == 1)
    }
}
