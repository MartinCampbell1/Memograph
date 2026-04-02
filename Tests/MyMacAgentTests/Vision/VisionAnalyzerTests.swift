import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct VisionAnalyzerTests {
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
}
