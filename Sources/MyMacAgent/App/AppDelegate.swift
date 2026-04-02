import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger.app
    private(set) var databaseManager: DatabaseManager?
    private var appMonitor: AppMonitor?
    private var windowMonitor: WindowMonitor?
    private var idleDetector: IdleDetector?
    private var sessionManager: SessionManager?
    private var captureEngine: ScreenCaptureEngine?
    private var imageProcessor: ImageProcessor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MyMacAgent launched")
        initializeDatabase()
        initializeMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appMonitor?.stop()
        windowMonitor?.stop()
        idleDetector?.stop()
        if let sessionId = sessionManager?.currentSessionId {
            try? sessionManager?.endSession(sessionId)
        }
        logger.info("MyMacAgent terminating")
    }

    private func initializeDatabase() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("MyMacAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let dbPath = dbDir.appendingPathComponent("mymacagent.db").path
            let db = try DatabaseManager(path: dbPath)
            let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
            try runner.runPending()
            databaseManager = db
            logger.info("Database initialized at \(dbPath)")
        } catch {
            logger.error("Database initialization failed: \(error.localizedDescription)")
        }
    }

    private func initializeMonitors() {
        guard let db = databaseManager else {
            logger.error("Cannot initialize monitors: database not ready")
            return
        }

        sessionManager = SessionManager(db: db)
        captureEngine = ScreenCaptureEngine()
        imageProcessor = ImageProcessor()

        let appMon = AppMonitor(db: db)
        appMon.delegate = self
        appMon.start()
        appMonitor = appMon

        let winMon = WindowMonitor(db: db)
        winMon.delegate = self
        windowMonitor = winMon

        let idle = IdleDetector()
        idle.delegate = self
        idle.start()
        idleDetector = idle

        logger.info("Monitors initialized")
    }
}

extension AppDelegate: AppMonitorDelegate {
    func appMonitor(_ monitor: AppMonitor, didSwitchTo bundleId: String, appName: String, appId: Int64) {
        guard let sessionManager else { return }
        do {
            let sessionId = try sessionManager.switchSession(appId: appId, windowId: nil)
            try sessionManager.recordEvent(sessionId: sessionId, type: .appActivated, payload:
                "{\"bundle_id\":\"\(bundleId)\",\"app_name\":\"\(appName)\"}")
            if let pid = monitor.currentAppInfo?.pid {
                windowMonitor?.updateApp(appId: appId, pid: pid)
            }
        } catch {
            logger.error("Failed to handle app switch: \(error.localizedDescription)")
        }
    }
}

extension AppDelegate: WindowMonitorDelegate {
    func windowMonitor(_ monitor: WindowMonitor, didSwitchTo windowId: Int64, title: String?) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        do {
            try sessionManager.recordEvent(sessionId: sessionId, type: .windowChanged, payload:
                "{\"window_id\":\(windowId),\"title\":\"\(title ?? "")\"}")
        } catch {
            logger.error("Failed to record window change: \(error.localizedDescription)")
        }
    }
}

extension AppDelegate: IdleDetectorDelegate {
    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        let eventType: SessionEventType = isIdle ? .idleStarted : .idleEnded
        try? sessionManager.recordEvent(sessionId: sessionId, type: eventType, payload: nil)
    }
}
