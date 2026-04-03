import Testing
import Foundation
@testable import MyMacAgent

struct SearchEngineTests {
    private let makassar = TimeZone(secondsFromGMT: 8 * 3600)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V003_PerformanceIndexes.migration
        ])
        try runner.runPending()
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])
        return (db, path)
    }

    @Test("Search finds matching context snapshots")
    func findsMatches() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                window_title, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .text("TestApp"), .text("main.swift"),
                      .text("Swift concurrency patterns with async await"), .real(0.9), .real(0.1)])

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "concurrency")

        #expect(results.count == 1)
        #expect(results[0].mergedText?.contains("concurrency") == true)
    }

    @Test("Search returns empty for no matches")
    func noMatches() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "nonexistent_term_xyz")
        #expect(results.isEmpty)
    }

    @Test("Search matches window title")
    func matchesWindowTitle() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                window_title, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .text("TestApp"), .text("Kubernetes Dashboard"),
                      .text("some text"), .real(0.9), .real(0.1)])

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "Kubernetes")

        #expect(results.count == 1)
    }

    @Test("Search limits results")
    func limitsResults() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        for i in 0..<20 {
            try db.execute("""
                INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                    merged_text, readable_score, uncertainty_score)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, params: [.text("ctx-\(i)"), .text("s1"),
                          .text("2026-04-02T10:\(String(format: "%02d", i)):00Z"),
                          .text("TestApp"), .text("matching term here"),
                          .real(0.9), .real(0.1)])
        }

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "matching", limit: 5)

        #expect(results.count == 5)
    }

    @Test("searchByDate respects local day boundaries instead of UTC prefix matching")
    func searchByDateUsesLocalRange() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-local"),
            .text("s1"),
            .text("2026-04-02T16:15:00Z"),
            .text("TestApp"),
            .text("late night research"),
            .real(0.9),
            .real(0.1)
        ])

        let engine = SearchEngine(db: db, timeZone: makassar)
        let results = try engine.searchByDate(query: "research", date: "2026-04-03")

        #expect(results.count == 1)
        #expect(results[0].id == "ctx-local")
    }
}
