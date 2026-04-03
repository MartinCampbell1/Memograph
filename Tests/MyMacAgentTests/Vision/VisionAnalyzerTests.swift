import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct VisionAnalyzerTests {
    private let makassar = TimeZone(secondsFromGMT: 8 * 3600)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("findLowReadabilityCaptures returns captures with low score")
    func findsLowReadability() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        // Low readability capture
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, sampling_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("cap-low"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .text("window"), .text("/tmp/test.jpg"), .text("high_uncertainty")])

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, source_capture_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .real(0.1), .real(0.9), .text("cap-low")])

        // High readability capture
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, sampling_mode)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("cap-high"), .text("s1"), .text("2026-04-02T10:05:00Z"),
                      .text("window"), .text("normal")])

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, source_capture_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-2"), .text("s1"), .text("2026-04-02T10:05:00Z"),
                      .real(0.9), .real(0.1), .text("cap-high")])

        let analyzer = VisionAnalyzer(db: db)
        let lowCaps = try analyzer.findLowReadabilityCaptures(for: "2026-04-02", threshold: 0.3)

        #expect(lowCaps.count == 1)
        #expect(lowCaps[0].captureId == "cap-low")
    }

    @Test("buildVisionPrompt creates image analysis request")
    func buildsPrompt() {
        let analyzer = VisionAnalyzer(db: DatabaseManager.forTesting())
        let prompt = analyzer.buildVisionPrompt()
        #expect(prompt.contains("Describe"))
        #expect(!prompt.isEmpty)
    }

    @Test("persistVisionResult updates context snapshot")
    func persistsResult() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, merged_text)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .real(0.1), .real(0.9), .null])

        let analyzer = VisionAnalyzer(db: db)
        try analyzer.persistVisionResult(contextId: "ctx-1", description: "Screenshot shows a Kubernetes dashboard with 3 running pods")

        let rows = try db.query("SELECT merged_text FROM context_snapshots WHERE id = ?",
            params: [.text("ctx-1")])
        #expect(rows[0]["merged_text"]?.textValue?.contains("Kubernetes") == true)
    }

    @Test("findLowReadabilityCaptures uses local day boundaries")
    func findsLowReadabilityForLocalDay() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s-local"), .integer(1), .text("2026-04-02T16:10:00Z")])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, sampling_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("cap-local"), .text("s-local"), .text("2026-04-02T16:10:00Z"),
                      .text("window"), .text("/tmp/local.jpg"), .text("high_uncertainty")])
        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, source_capture_id)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-local"), .text("s-local"), .text("2026-04-02T16:10:00Z"),
                      .real(0.2), .real(0.8), .text("cap-local")])

        let analyzer = VisionAnalyzer(db: db, timeZone: makassar)
        let captures = try analyzer.findLowReadabilityCaptures(for: "2026-04-03", threshold: 0.3)

        #expect(captures.count == 1)
        #expect(captures[0].captureId == "cap-local")
    }

    @Test("analyzeAllLowReadability continues after one capture fails")
    func continuesAfterSingleCaptureFailure() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        for index in 1...2 {
            try db.execute("""
                INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, sampling_mode)
                VALUES (?, ?, ?, ?, ?, ?)
            """, params: [
                .text("cap-\(index)"),
                .text("s1"),
                .text("2026-04-02T10:0\(index):00Z"),
                .text("window"),
                .text("/tmp/cap-\(index).jpg"),
                .text("high_uncertainty")
            ])
            try db.execute("""
                INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, source_capture_id)
                VALUES (?, ?, ?, ?, ?, ?)
            """, params: [
                .text("ctx-\(index)"),
                .text("s1"),
                .text("2026-04-02T10:0\(index):00Z"),
                .real(0.1),
                .real(0.9),
                .text("cap-\(index)")
            ])
        }

        let analyzer = VisionAnalyzer(
            db: db,
            analyzeImageOverride: { path in
                if path.contains("cap-1") {
                    struct ExpectedFailure: Error {}
                    throw ExpectedFailure()
                }
                return "Recovered screenshot text"
            }
        )

        let analyzedCount = try await analyzer.analyzeAllLowReadability(for: "2026-04-02")
        let rows = try db.query(
            "SELECT merged_text FROM context_snapshots WHERE id = ?",
            params: [.text("ctx-2")]
        )

        #expect(analyzedCount == 1)
        #expect(rows.first?["merged_text"]?.textValue == "Recovered screenshot text")
    }

    @Test("window-scoped low-readability lookup only returns captures inside the summary window")
    func findsLowReadabilityInsideWindowOnly() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s-window"), .integer(1), .text("2026-04-03T09:00:00Z")])

        for (captureId, timestamp) in [("cap-before", "2026-04-03T09:05:00Z"), ("cap-inside", "2026-04-03T10:05:00Z")] {
            try db.execute("""
                INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, sampling_mode)
                VALUES (?, ?, ?, ?, ?, ?)
            """, params: [.text(captureId), .text("s-window"), .text(timestamp),
                          .text("window"), .text("/tmp/\(captureId).jpg"), .text("high_uncertainty")])
            try db.execute("""
                INSERT INTO context_snapshots (id, session_id, timestamp, readable_score, uncertainty_score, source_capture_id)
                VALUES (?, ?, ?, ?, ?, ?)
            """, params: [.text("ctx-\(captureId)"), .text("s-window"), .text(timestamp),
                          .real(0.1), .real(0.9), .text(captureId)])
        }

        let analyzer = VisionAnalyzer(db: db)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        let captures = try analyzer.findLowReadabilityCaptures(in: window)
        #expect(captures.count == 1)
        #expect(captures[0].captureId == "cap-inside")
    }
}
