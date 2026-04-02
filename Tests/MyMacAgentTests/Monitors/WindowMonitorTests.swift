import Testing
import Foundation
@testable import MyMacAgent

final class MockWindowMonitorDelegate: WindowMonitorDelegate {
    var lastWindowId: Int64?
    var lastTitle: String?
    func windowMonitor(_ monitor: WindowMonitor, didSwitchTo windowId: Int64, title: String?) {
        lastWindowId = windowId
        lastTitle = title
    }
}

struct WindowMonitorTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        try db.execute("CREATE TABLE apps (id INTEGER PRIMARY KEY AUTOINCREMENT, bundle_id TEXT UNIQUE, app_name TEXT NOT NULL)")
        try db.execute("CREATE TABLE windows (id INTEGER PRIMARY KEY AUTOINCREMENT, app_id INTEGER NOT NULL, window_title TEXT, window_role TEXT, first_seen_at DATETIME, last_seen_at DATETIME, fingerprint TEXT, FOREIGN KEY (app_id) REFERENCES apps(id))")
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)", params: [.text("com.test"), .text("Test")])
        return (db, path)
    }

    @Test("recordWindow inserts new window")
    func recordWindowInserts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = WindowMonitor(db: db)
        let windowId = try monitor.recordWindow(appId: 1, title: "Document.txt", role: "AXWindow")
        #expect(windowId > 0)
        let rows = try db.query("SELECT * FROM windows WHERE id = ?", params: [.integer(windowId)])
        #expect(rows.count == 1)
        #expect(rows[0]["window_title"]?.textValue == "Document.txt")
    }

    @Test("recordWindow returns same ID for same title")
    func recordWindowIdempotent() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = WindowMonitor(db: db)
        let id1 = try monitor.recordWindow(appId: 1, title: "Doc.txt", role: "AXWindow")
        let id2 = try monitor.recordWindow(appId: 1, title: "Doc.txt", role: "AXWindow")
        #expect(id1 == id2)
    }

    @Test("Delegate called on window change")
    func delegateCalled() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = WindowMonitor(db: db)
        let delegate = MockWindowMonitorDelegate()
        monitor.delegate = delegate
        try monitor.handleWindowChange(appId: 1, title: "My Window", role: "AXWindow")
        #expect(delegate.lastTitle == "My Window")
        #expect(delegate.lastWindowId != nil)
    }

    @Test("currentWindowTitle nil before start")
    func titleNilBeforeStart() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = WindowMonitor(db: db)
        #expect(monitor.currentWindowTitle == nil)
    }
}
