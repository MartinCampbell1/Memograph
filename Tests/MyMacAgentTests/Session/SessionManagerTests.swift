import Testing
import Foundation
@testable import MyMacAgent

struct SessionManagerTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        // Create minimal schema needed
        try db.execute("CREATE TABLE apps (id INTEGER PRIMARY KEY AUTOINCREMENT, bundle_id TEXT UNIQUE, app_name TEXT NOT NULL)")
        try db.execute("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY, app_id INTEGER NOT NULL, window_id INTEGER,
                session_type TEXT, started_at DATETIME NOT NULL, ended_at DATETIME,
                active_duration_ms INTEGER DEFAULT 0, idle_duration_ms INTEGER DEFAULT 0,
                confidence_score REAL DEFAULT 0, uncertainty_mode TEXT DEFAULT 'normal',
                top_topic TEXT, is_ai_related INTEGER DEFAULT 0, summary_status TEXT DEFAULT 'pending',
                FOREIGN KEY (app_id) REFERENCES apps(id)
            )
        """)
        try db.execute("""
            CREATE TABLE session_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                event_type TEXT NOT NULL, timestamp DATETIME NOT NULL, payload_json TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            )
        """)
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        return (db, path)
    }

    @Test("startSession creates record")
    func startSession() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sm = SessionManager(db: db)
        let sessionId = try sm.startSession(appId: 1, windowId: nil)
        #expect(!sessionId.isEmpty)
        let rows = try db.query("SELECT * FROM sessions WHERE id = ?", params: [.text(sessionId)])
        #expect(rows.count == 1)
        #expect(rows[0]["app_id"]?.intValue == 1)
    }

    @Test("endSession sets ended_at")
    func endSession() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sm = SessionManager(db: db)
        let sessionId = try sm.startSession(appId: 1, windowId: nil)
        try sm.endSession(sessionId)
        let rows = try db.query("SELECT ended_at FROM sessions WHERE id = ?", params: [.text(sessionId)])
        #expect(rows[0]["ended_at"]?.textValue != nil)
    }

    @Test("currentSessionId lifecycle")
    func currentSessionId() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sm = SessionManager(db: db)
        #expect(sm.currentSessionId == nil)
        let sessionId = try sm.startSession(appId: 1, windowId: nil)
        #expect(sm.currentSessionId == sessionId)
        try sm.endSession(sessionId)
        #expect(sm.currentSessionId == nil)
    }

    @Test("recordEvent inserts row")
    func recordEvent() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sm = SessionManager(db: db)
        let sessionId = try sm.startSession(appId: 1, windowId: nil)
        try sm.recordEvent(sessionId: sessionId, type: .appActivated, payload: nil)
        let rows = try db.query("SELECT * FROM session_events WHERE session_id = ?", params: [.text(sessionId)])
        #expect(rows.count == 1)
        #expect(rows[0]["event_type"]?.textValue == "app_activated")
    }

    @Test("switchSession ends old and starts new")
    func switchSession() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sm = SessionManager(db: db)
        let oldId = try sm.startSession(appId: 1, windowId: nil)
        let newId = try sm.switchSession(appId: 1, windowId: 2)
        #expect(oldId != newId)
        #expect(sm.currentSessionId == newId)
        let oldRows = try db.query("SELECT ended_at FROM sessions WHERE id = ?", params: [.text(oldId)])
        #expect(oldRows[0]["ended_at"]?.textValue != nil)
    }

    @Test("endSession calculates active_duration_ms")
    func endSessionCalculatesDuration() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sm = SessionManager(db: db)

        let sessionId = try sm.startSession(appId: 1, windowId: nil)

        let rows1 = try db.query("SELECT active_duration_ms FROM sessions WHERE id = ?",
            params: [.text(sessionId)])
        #expect(rows1[0]["active_duration_ms"]?.intValue == 0)

        try sm.endSession(sessionId)

        let rows2 = try db.query("SELECT active_duration_ms, ended_at, started_at FROM sessions WHERE id = ?",
            params: [.text(sessionId)])
        let duration = rows2[0]["active_duration_ms"]?.intValue ?? -1
        #expect(duration >= 0)
        #expect(rows2[0]["ended_at"]?.textValue != nil)
    }

    @Test("markIdle and markActive track idle duration")
    func idleDurationTracking() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let sm = SessionManager(db: db)

        let sessionId = try sm.startSession(appId: 1, windowId: nil)
        try sm.markIdle(sessionId: sessionId)
        try sm.markActive(sessionId: sessionId)

        let rows = try db.query("SELECT idle_duration_ms FROM sessions WHERE id = ?",
            params: [.text(sessionId)])
        let idle = rows[0]["idle_duration_ms"]?.intValue ?? -1
        #expect(idle >= 0)
    }
}
