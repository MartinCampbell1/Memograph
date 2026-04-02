import Testing
import Foundation
@testable import MyMacAgent

struct AccessibilityContextEngineTests {
    private var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] == "true"
    }

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("extractFromPid does not crash and returns optional record")
    func extractFromPid() {
        guard !isCI else { return }
        let engine = AccessibilityContextEngine()
        // Current process should have some AX attributes.
        // May or may not return data depending on permissions, but must not crash.
        let snapshot = engine.extract(pid: ProcessInfo.processInfo.processIdentifier)
        if let snapshot {
            #expect(!snapshot.id.isEmpty)
            // sessionId defaults to "" when called without one — just verify the record is valid
            _ = snapshot.sessionId
        }
    }

    @Test("persistSnapshot saves row to ax_snapshots table")
    func persistSnapshot() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")]
        )
        try db.execute(
            "INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")]
        )

        let engine = AccessibilityContextEngine()
        let snapshot = AXSnapshotRecord(
            id: UUID().uuidString, sessionId: "sess-1", captureId: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            focusedRole: "AXTextField", focusedSubrole: nil,
            focusedTitle: "Search", focusedValue: "test query",
            selectedText: nil, textLen: 10, extractionStatus: "success"
        )

        try engine.persist(snapshot: snapshot, db: db)

        let rows = try db.query(
            "SELECT * FROM ax_snapshots WHERE session_id = ?",
            params: [.text("sess-1")]
        )
        #expect(rows.count == 1)
        #expect(rows[0]["focused_role"]?.textValue == "AXTextField")
        #expect(rows[0]["focused_value"]?.textValue == "test query")
        #expect(rows[0]["text_len"]?.intValue == 10)
    }

    @Test("extractAttributes does not crash")
    func extractAttributes() {
        guard !isCI else { return }
        let engine = AccessibilityContextEngine()
        // Should return a dictionary (may be nil without accessibility permissions).
        let attrs = engine.extractAttributes(from: ProcessInfo.processInfo.processIdentifier)
        // Just verify it doesn't crash — result depends on runtime permissions.
        _ = attrs
    }
}
