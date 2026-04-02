import AppKit
import os

protocol AppMonitorDelegate: AnyObject {
    func appMonitor(_ monitor: AppMonitor, didSwitchTo bundleId: String, appName: String, appId: Int64)
}

struct AppInfo {
    let bundleId: String
    let appName: String
    let appId: Int64
    let pid: pid_t
}

final class AppMonitor {
    weak var delegate: AppMonitorDelegate?
    private let db: DatabaseManager
    private let logger = Logger.monitor
    private var observation: NSObjectProtocol?
    private(set) var currentAppInfo: AppInfo?

    init(db: DatabaseManager) {
        self.db = db
    }

    func start() {
        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier,
                  let appName = app.localizedName else { return }
            self.handleAppChange(bundleId: bundleId, appName: appName, pid: app.processIdentifier)
        }

        // Record current frontmost app
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           let appName = frontmost.localizedName {
            handleAppChange(bundleId: bundleId, appName: appName, pid: frontmost.processIdentifier)
        }
    }

    func stop() {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
            self.observation = nil
        }
    }

    func handleAppChange(bundleId: String, appName: String, pid: pid_t = 0) {
        guard bundleId != currentAppInfo?.bundleId else { return }
        do {
            let appId = try recordApp(bundleId: bundleId, appName: appName)
            currentAppInfo = AppInfo(bundleId: bundleId, appName: appName, appId: appId, pid: pid)
            delegate?.appMonitor(self, didSwitchTo: bundleId, appName: appName, appId: appId)
        } catch {
            logger.error("Failed to record app: \(error.localizedDescription)")
        }
    }

    func recordApp(bundleId: String, appName: String) throws -> Int64 {
        let existing = try db.query(
            "SELECT id FROM apps WHERE bundle_id = ?",
            params: [.text(bundleId)]
        )
        if let row = existing.first, let id = row["id"]?.intValue { return id }

        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text(bundleId), .text(appName)]
        )
        let rows = try db.query("SELECT id FROM apps WHERE bundle_id = ?", params: [.text(bundleId)])
        guard let id = rows.first?["id"]?.intValue else {
            throw DatabaseError.executeFailed("Could not retrieve inserted app ID")
        }
        return id
    }
}
