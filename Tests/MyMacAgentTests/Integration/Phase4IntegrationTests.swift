import Testing
import Foundation
@testable import MyMacAgent

struct Phase4IntegrationTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V002_AudioTranscripts.migration,
            V003_PerformanceIndexes.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    private func seedTimeline(db: DatabaseManager) throws {
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")])

        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:00:00Z"), .text("2026-04-02T11:00:00Z"),
                      .integer(7200000), .text("normal")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s2"), .integer(2),
                      .text("2026-04-02T11:00:00Z"), .text("2026-04-02T12:00:00Z"),
                      .integer(3600000), .text("degraded")])

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                window_title, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T09:30:00Z"),
                      .text("Cursor"), .text("main.swift"),
                      .text("Implementing Swift concurrency patterns"),
                      .real(0.9), .real(0.1)])
    }

    @Test("Timeline data provider returns sessions and apps")
    func timelineData() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedTimeline(db: db)

        let provider = TimelineDataProvider(db: db, timeZone: utc)
        let sessions = try provider.sessionsForDate("2026-04-02")
        let apps = try provider.appSummaryForDate("2026-04-02")
        let dates = try provider.availableDates()

        #expect(sessions.count == 2)
        #expect(apps.count == 2)
        #expect(apps[0].appName == "Cursor") // longest first
        #expect(dates.contains("2026-04-02"))
    }

    @Test("Search finds context across sessions")
    func searchAcrossSessions() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedTimeline(db: db)

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "concurrency")
        #expect(results.count == 1)
        #expect(results[0].appName == "Cursor")
    }

    @Test("Retention cleans old data without touching recent")
    func retentionCleanup() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])

        // Old data (90 days ago)
        let oldDate = "2026-01-02T10:00:00Z"
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("old-s"), .integer(1), .text(oldDate)])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, retained)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("old-cap"), .text("old-s"), .text(oldDate), .text("window"), .integer(1)])
        try db.execute("""
            INSERT INTO ocr_snapshots (id, session_id, capture_id, timestamp, provider)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("old-ocr"), .text("old-s"), .text("old-cap"), .text(oldDate), .text("vision")])

        // Recent data
        let recentDate = ISO8601DateFormatter().string(from: Date())
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("new-s"), .integer(1), .text(recentDate)])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, retained)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("new-cap"), .text("new-s"), .text(recentDate), .text("window"), .integer(1)])

        let worker = RetentionWorker(db: db, retentionDays: 30)
        try worker.runAll()

        // Old data gone
        let oldCaps = try db.query("SELECT * FROM captures WHERE id = ?", params: [.text("old-cap")])
        #expect(oldCaps.isEmpty)
        let oldOCR = try db.query("SELECT * FROM ocr_snapshots WHERE id = ?", params: [.text("old-ocr")])
        #expect(oldOCR.isEmpty)

        // Recent data preserved
        let newCaps = try db.query("SELECT * FROM captures WHERE id = ?", params: [.text("new-cap")])
        #expect(newCaps.count == 1)
    }

    @Test("AppSettings persist across instances")
    func settingsPersist() {
        let suiteName = "test_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = InMemoryCredentialsStore()

        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.openRouterApiKey = "sk-test-key"
        settings.obsidianVaultPath = "/test/vault"
        settings.retentionDays = 7

        let loaded = AppSettings(defaults: defaults, credentialsStore: store)
        #expect(loaded.openRouterApiKey == "sk-test-key")
        #expect(loaded.obsidianVaultPath == "/test/vault")
        #expect(loaded.retentionDays == 7)
        #expect(loaded.hasApiKey)
    }

    @Test("Experimental audio is reset until user explicitly opts back in")
    func experimentalAudioRequiresExplicitOptIn() {
        let suiteName = "test_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = InMemoryCredentialsStore()

        defaults.set(true, forKey: "microphoneCaptureEnabled")
        defaults.set(true, forKey: "systemAudioCaptureEnabled")

        let migrated = AppSettings(defaults: defaults, credentialsStore: store)
        #expect(!migrated.microphoneCaptureEnabled)
        #expect(!migrated.systemAudioCaptureEnabled)
        #expect(!migrated.experimentalAudioOptInConfirmed)

        var settings = migrated
        settings.microphoneCaptureEnabled = true
        settings.systemAudioCaptureEnabled = true
        settings.experimentalAudioOptInConfirmed = true

        let reloaded = AppSettings(defaults: defaults, credentialsStore: store)
        #expect(reloaded.microphoneCaptureEnabled)
        #expect(reloaded.systemAudioCaptureEnabled)
        #expect(reloaded.experimentalAudioOptInConfirmed)
    }
}
