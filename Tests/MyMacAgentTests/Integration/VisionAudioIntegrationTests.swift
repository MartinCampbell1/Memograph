import Testing
import Foundation
@testable import MyMacAgent

struct VisionAudioIntegrationTests {
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

    // V001: seed a minimal session so DailySummarizer has something to query
    private func seedMinimalSession(db: DatabaseManager, date: String) throws {
        try db.execute("INSERT OR IGNORE INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-va"), .integer(1),
            .text("\(date)T09:00:00Z"), .text("\(date)T10:00:00Z"),
            .integer(3600000), .text("normal")
        ])
    }

    @Test("V002 migration creates audio_transcripts table")
    func v002MigrationCreatesTable() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Verify the table was created by the migration
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='audio_transcripts'",
            params: []
        )
        #expect(rows.count == 1)
        #expect(rows[0]["name"]?.textValue == "audio_transcripts")
    }

    @Test("Audio transcripts appear in daily summary prompt")
    func audioTranscriptsInPrompt() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let date = "2026-04-02"
        try seedMinimalSession(db: db, date: date)

        // Insert a transcript containing a distinctive keyword
        let transcriber = AudioTranscriber(db: db)
        try transcriber.persistTranscript(
            sessionId: "sess-va",
            text: "Today we discussed Kubernetes deployment strategies",
            language: "en",
            durationSeconds: 120
        )

        let summarizer = DailySummarizer(db: db)
        let prompt = try summarizer.buildDailyPrompt(for: date)

        #expect(prompt.contains("Kubernetes"))
        #expect(prompt.contains("Audio Transcripts"))
    }

    @Test("Vision analysis results appear in daily summary prompt")
    func visionSnapshotsInPrompt() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let date = "2026-04-02"
        try seedMinimalSession(db: db, date: date)

        // Insert a context_snapshot with text_source='vision'
        try db.execute("""
            INSERT INTO context_snapshots
                (id, session_id, timestamp, app_name, bundle_id,
                 window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-vision-1"),
            .text("sess-va"),
            .text("\(date)T09:15:00Z"),
            .text("Figma"),
            .text("com.figma.Desktop"),
            .text("Design System"),
            .text("vision"),
            .text("A Figma artboard showing a color palette with hex codes #FF5733 and #4A90E2"),
            .real(0.1),
            .real(0.9)
        ])

        let summarizer = DailySummarizer(db: db)
        let prompt = try summarizer.buildDailyPrompt(for: date)

        #expect(prompt.contains("Vision Analysis"))
        #expect(prompt.contains("Figma"))
        #expect(prompt.contains("#FF5733"))
    }

    @Test("Full pipeline: both vision and audio appear in prompt")
    func fullPipelineBothInPrompt() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let date = "2026-04-02"
        try seedMinimalSession(db: db, date: date)

        // Insert audio transcript
        let transcriber = AudioTranscriber(db: db)
        try transcriber.persistTranscript(
            sessionId: "sess-va",
            text: "Meeting about the new API architecture",
            language: "en",
            durationSeconds: 300
        )

        // Insert vision snapshot
        try db.execute("""
            INSERT INTO context_snapshots
                (id, session_id, timestamp, app_name, bundle_id,
                 window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-vision-2"),
            .text("sess-va"),
            .text("\(date)T09:30:00Z"),
            .text("Sketch"),
            .text("com.bohemiancoding.sketch3"),
            .text("Architecture Diagram"),
            .text("vision"),
            .text("A system architecture diagram showing microservices connected via message queue"),
            .real(0.15),
            .real(0.85)
        ])

        let summarizer = DailySummarizer(db: db)
        let prompt = try summarizer.buildDailyPrompt(for: date)

        // Both sections present
        #expect(prompt.contains("Audio Transcripts"))
        #expect(prompt.contains("Meeting about the new API architecture"))
        #expect(prompt.contains("Vision Analysis"))
        #expect(prompt.contains("microservices"))
    }
}
