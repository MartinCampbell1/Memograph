import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct PipelineIntegrationTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("Full app switch flow with sessions and events")
    func fullAppSwitchFlow() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let appMonitor = AppMonitor(db: db)
        let sessionManager = SessionManager(db: db)

        // First app
        appMonitor.handleAppChange(bundleId: "com.app.one", appName: "AppOne")
        guard let appInfo1 = appMonitor.currentAppInfo else {
            Issue.record("App info should be set")
            return
        }

        let session1 = try sessionManager.startSession(appId: appInfo1.appId, windowId: nil)
        try sessionManager.recordEvent(sessionId: session1, type: .appActivated, payload: nil)

        // Switch to second app
        appMonitor.handleAppChange(bundleId: "com.app.two", appName: "AppTwo")
        guard let appInfo2 = appMonitor.currentAppInfo else {
            Issue.record("App info should be set")
            return
        }

        let session2 = try sessionManager.switchSession(appId: appInfo2.appId, windowId: nil)
        try sessionManager.recordEvent(sessionId: session2, type: .appActivated, payload: nil)

        // Verify apps
        let apps = try db.query("SELECT * FROM apps ORDER BY id")
        #expect(apps.count == 2)
        #expect(apps[0]["app_name"]?.textValue == "AppOne")
        #expect(apps[1]["app_name"]?.textValue == "AppTwo")

        // Verify sessions
        let sessions = try db.query("SELECT * FROM sessions ORDER BY started_at")
        #expect(sessions.count == 2)
        #expect(sessions[0]["ended_at"]?.textValue != nil) // first ended
        #expect(sessions[1]["ended_at"] == .null) // second still open

        // Verify events
        let events = try db.query("SELECT * FROM session_events ORDER BY id")
        #expect(events.count == 2)
    }

    @Test("Window tracking with sessions")
    func windowTrackingWithSessions() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let appMonitor = AppMonitor(db: db)
        let windowMonitor = WindowMonitor(db: db)
        let sessionManager = SessionManager(db: db)

        // Set up app
        appMonitor.handleAppChange(bundleId: "com.test", appName: "TestApp")
        let appInfo = appMonitor.currentAppInfo!
        let sessionId = try sessionManager.startSession(appId: appInfo.appId, windowId: nil)

        // Simulate window changes
        try windowMonitor.handleWindowChange(appId: appInfo.appId, title: "Document1.txt")
        try windowMonitor.handleWindowChange(appId: appInfo.appId, title: "Document2.txt")

        // Verify windows
        let windows = try db.query("SELECT * FROM windows WHERE app_id = ? ORDER BY id", params: [.integer(appInfo.appId)])
        #expect(windows.count == 2)
        #expect(windows[0]["window_title"]?.textValue == "Document1.txt")
        #expect(windows[1]["window_title"]?.textValue == "Document2.txt")

        // Verify session still active
        #expect(sessionManager.currentSessionId == sessionId)
    }

    @Test("Capture and hash flow")
    func captureAndHashFlow() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let processor = ImageProcessor()

        // Create test image
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.green.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 200, height: 200))
        image.unlockFocus()

        // Hash
        let hash = processor.visualHash(image: image)
        #expect(hash != nil)

        // Thumbnail
        let thumb = processor.createThumbnail(image: image, maxDimension: 50)
        #expect(thumb != nil)
        #expect(thumb!.size.width <= 50)

        // Save
        let tmpDir = NSTemporaryDirectory() + "capture_integration_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let captureEngine = ScreenCaptureEngine()
        let result = CaptureResult(image: image, width: 200, height: 200, timestamp: Date())
        let capturePath = try captureEngine.saveToDisk(result: result, directory: tmpDir)
        #expect(FileManager.default.fileExists(atPath: capturePath))

        // Record in DB
        let appMonitor = AppMonitor(db: db)
        appMonitor.handleAppChange(bundleId: "com.test", appName: "Test")
        let appId = appMonitor.currentAppInfo!.appId
        let sessionManager = SessionManager(db: db)
        let sessionId = try sessionManager.startSession(appId: appId, windowId: nil)

        let captureId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, width, height, visual_hash, sampling_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(captureId), .text(sessionId), .text(now),
            .text("window"), .text(capturePath),
            .integer(200), .integer(200),
            .text(hash!), .text("normal")
        ])

        let captures = try db.query("SELECT * FROM captures WHERE session_id = ?", params: [.text(sessionId)])
        #expect(captures.count == 1)
        #expect(captures[0]["visual_hash"]?.textValue == hash)
    }

    @Test("Session events are ordered correctly")
    func sessionEventsOrdered() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let appMonitor = AppMonitor(db: db)
        let sessionManager = SessionManager(db: db)

        appMonitor.handleAppChange(bundleId: "com.test", appName: "Test")
        let appId = appMonitor.currentAppInfo!.appId
        let sessionId = try sessionManager.startSession(appId: appId, windowId: nil)

        try sessionManager.recordEvent(sessionId: sessionId, type: .appActivated, payload: nil)
        try sessionManager.recordEvent(sessionId: sessionId, type: .windowChanged, payload: nil)
        try sessionManager.recordEvent(sessionId: sessionId, type: .idleStarted, payload: nil)
        try sessionManager.recordEvent(sessionId: sessionId, type: .idleEnded, payload: nil)

        let events = try db.query("SELECT event_type FROM session_events WHERE session_id = ? ORDER BY id", params: [.text(sessionId)])
        #expect(events.count == 4)
        #expect(events[0]["event_type"]?.textValue == "app_activated")
        #expect(events[1]["event_type"]?.textValue == "window_changed")
        #expect(events[2]["event_type"]?.textValue == "idle_started")
        #expect(events[3]["event_type"]?.textValue == "idle_ended")
    }

    @Test("Multiple app switches maintain timeline")
    func multipleAppSwitches() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let appMonitor = AppMonitor(db: db)
        let sessionManager = SessionManager(db: db)

        // Switch through 5 apps
        let apps = [
            ("com.app.a", "AppA"), ("com.app.b", "AppB"),
            ("com.app.c", "AppC"), ("com.app.a", "AppA"),  // back to A
            ("com.app.b", "AppB")  // back to B
        ]

        for (bundleId, name) in apps {
            appMonitor.handleAppChange(bundleId: bundleId, appName: name)
            let appId = appMonitor.currentAppInfo!.appId
            _ = try sessionManager.switchSession(appId: appId, windowId: nil)
        }

        // Should have 3 unique apps
        let uniqueApps = try db.query("SELECT * FROM apps")
        #expect(uniqueApps.count == 3)

        // Should have 5 sessions (4 ended + 1 current)
        let sessions = try db.query("SELECT * FROM sessions")
        #expect(sessions.count == 5)

        let openSessions = try db.query("SELECT * FROM sessions WHERE ended_at IS NULL")
        #expect(openSessions.count == 1)
    }
}
