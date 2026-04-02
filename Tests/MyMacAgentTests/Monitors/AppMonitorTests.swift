import Testing
import Foundation
@testable import MyMacAgent

final class MockAppMonitorDelegate: AppMonitorDelegate {
    var lastBundleId: String?
    var lastAppName: String?
    var lastAppId: Int64?

    func appMonitor(_ monitor: AppMonitor, didSwitchTo bundleId: String, appName: String, appId: Int64) {
        lastBundleId = bundleId
        lastAppName = appName
        lastAppId = appId
    }
}

struct AppMonitorTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        // Need to create the apps table
        try db.execute("CREATE TABLE apps (id INTEGER PRIMARY KEY AUTOINCREMENT, bundle_id TEXT UNIQUE, app_name TEXT NOT NULL, category TEXT, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)")
        return (db, path)
    }

    @Test("recordApp inserts new app")
    func recordAppInserts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = AppMonitor(db: db)

        let appId = try monitor.recordApp(bundleId: "com.test.app", appName: "TestApp")
        #expect(appId > 0)

        let rows = try db.query("SELECT * FROM apps WHERE bundle_id = ?", params: [.text("com.test.app")])
        #expect(rows.count == 1)
        #expect(rows[0]["app_name"]?.textValue == "TestApp")
    }

    @Test("recordApp returns same ID for existing app")
    func recordAppIdempotent() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = AppMonitor(db: db)

        let id1 = try monitor.recordApp(bundleId: "com.test.app", appName: "TestApp")
        let id2 = try monitor.recordApp(bundleId: "com.test.app", appName: "TestApp")
        #expect(id1 == id2)
    }

    @Test("currentAppInfo is nil before start")
    func currentAppInfoNil() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = AppMonitor(db: db)
        #expect(monitor.currentAppInfo == nil)
    }

    @Test("Delegate called on app change")
    func delegateCalled() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = AppMonitor(db: db)
        let delegate = MockAppMonitorDelegate()
        monitor.delegate = delegate

        monitor.handleAppChange(bundleId: "com.test.app", appName: "TestApp")

        #expect(delegate.lastBundleId == "com.test.app")
        #expect(delegate.lastAppName == "TestApp")
        #expect(delegate.lastAppId != nil)
    }

    @Test("Duplicate app change is ignored")
    func duplicateIgnored() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = AppMonitor(db: db)
        let delegate = MockAppMonitorDelegate()
        monitor.delegate = delegate

        monitor.handleAppChange(bundleId: "com.test.app", appName: "TestApp")
        delegate.lastBundleId = nil // reset
        monitor.handleAppChange(bundleId: "com.test.app", appName: "TestApp") // same app

        #expect(delegate.lastBundleId == nil) // should not fire again
    }
}
