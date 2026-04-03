import Testing
import Foundation
@testable import MyMacAgent

struct TimelineDataProviderTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let makassar = TimeZone(secondsFromGMT: 8 * 3600)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V003_PerformanceIndexes.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    private func seedData(db: DatabaseManager) throws {
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:00:00Z"), .text("2026-04-02T10:30:00Z"),
                      .integer(5400000), .text("normal")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s2"), .integer(2),
                      .text("2026-04-02T10:30:00Z"), .text("2026-04-02T11:00:00Z"),
                      .integer(1800000), .text("degraded")])
    }

    @Test("sessionsForDate returns ordered sessions")
    func sessionsForDate() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedData(db: db)

        let provider = TimelineDataProvider(db: db, timeZone: utc)
        let sessions = try provider.sessionsForDate("2026-04-02")

        #expect(sessions.count == 2)
        #expect(sessions[0].appName == "Cursor")
        #expect(sessions[0].durationMinutes == 90)
        #expect(sessions[1].appName == "Safari")
    }

    @Test("appSummaryForDate returns aggregated app usage")
    func appSummaryForDate() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedData(db: db)

        let provider = TimelineDataProvider(db: db, timeZone: utc)
        let apps = try provider.appSummaryForDate("2026-04-02")

        #expect(apps.count == 2)
        // Cursor should be first (longer duration)
        #expect(apps[0].appName == "Cursor")
        #expect(apps[0].totalMinutes == 90)
    }

    @Test("availableDates returns unique dates")
    func availableDates() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedData(db: db)

        let provider = TimelineDataProvider(db: db, timeZone: utc)
        let dates = try provider.availableDates()

        #expect(dates.contains("2026-04-02"))
    }

    @Test("contextSnapshotsForSession returns ordered snapshots")
    func contextSnapshotsForSession() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedData(db: db)

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T09:10:00Z"),
                      .text("Cursor"), .text("main.swift"), .text("ax+ocr"),
                      .text("Swift code here"), .real(0.9), .real(0.1)])

        let provider = TimelineDataProvider(db: db, timeZone: utc)
        let contexts = try provider.contextSnapshotsForSession("s1")

        #expect(contexts.count == 1)
        #expect(contexts[0].mergedText == "Swift code here")
    }

    @Test("sessionsForDate uses local day boundaries and computes ongoing duration")
    func sessionsForLocalDayBoundary() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s-local"), .integer(1),
                      .text("2026-04-02T16:30:00Z"), .null,
                      .integer(0), .text("normal")])

        let fixedNow = ISO8601DateFormatter().date(from: "2026-04-02T18:00:00Z")!
        let provider = TimelineDataProvider(db: db, timeZone: makassar, now: { fixedNow })

        let sessions = try provider.sessionsForDate("2026-04-03")
        let dates = try provider.availableDates()

        #expect(sessions.count == 1)
        #expect(sessions[0].appName == "Cursor")
        #expect(sessions[0].durationMinutes == 90)
        #expect(dates.first == "2026-04-03")
    }

    @Test("sessionsForDate includes overlap from sessions started before the local day")
    func sessionsForDateIncludesSpanningSession() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("s-span"),
            .integer(1),
            .text("2026-04-02T15:30:00Z"),
            .text("2026-04-02T16:45:00Z"),
            .integer(4500000),
            .text("normal")
        ])

        let provider = TimelineDataProvider(db: db, timeZone: makassar)
        let sessions = try provider.sessionsForDate("2026-04-03")
        let apps = try provider.appSummaryForDate("2026-04-03")

        #expect(sessions.count == 1)
        #expect(sessions[0].durationMinutes == 45)
        #expect(apps.first?.totalMinutes == 45)
    }
}
