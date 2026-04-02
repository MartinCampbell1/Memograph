import AppKit
import os

protocol WindowMonitorDelegate: AnyObject {
    func windowMonitor(_ monitor: WindowMonitor, didSwitchTo windowId: Int64, title: String?)
}

final class WindowMonitor {
    weak var delegate: WindowMonitorDelegate?
    private let db: DatabaseManager
    private let logger = Logger.monitor
    private var pollTimer: Timer?
    private(set) var currentWindowTitle: String?
    private var currentWindowId: Int64?
    private var currentAppId: Int64?

    init(db: DatabaseManager) {
        self.db = db
    }

    func start(appId: Int64, pid: pid_t) {
        currentAppId = appId
        pollWindowTitle(pid: pid)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollWindowTitle(pid: pid)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        currentWindowTitle = nil
        currentWindowId = nil
    }

    func updateApp(appId: Int64, pid: pid_t) {
        stop()
        start(appId: appId, pid: pid)
    }

    func handleWindowChange(appId: Int64, title: String?, role: String? = "AXWindow") throws {
        guard title != currentWindowTitle else { return }
        let windowId = try recordWindow(appId: appId, title: title, role: role)
        currentWindowTitle = title
        currentWindowId = windowId
        delegate?.windowMonitor(self, didSwitchTo: windowId, title: title)
    }

    func recordWindow(appId: Int64, title: String?, role: String?) throws -> Int64 {
        let safeTitle = title ?? ""
        let existing = try db.query(
            "SELECT id FROM windows WHERE app_id = ? AND window_title = ?",
            params: [.integer(appId), .text(safeTitle)]
        )

        if let row = existing.first, let id = row["id"]?.intValue {
            let now = ISO8601DateFormatter().string(from: Date())
            try db.execute("UPDATE windows SET last_seen_at = ? WHERE id = ?",
                params: [.text(now), .integer(id)])
            return id
        }

        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute("""
            INSERT INTO windows (app_id, window_title, window_role, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?, ?)
        """, params: [
            .integer(appId), .text(safeTitle),
            role.map { .text($0) } ?? .null,
            .text(now), .text(now)
        ])

        let rows = try db.query("SELECT last_insert_rowid() as id")
        guard let id = rows.first?["id"]?.intValue else {
            throw DatabaseError.executeFailed("Could not retrieve inserted window ID")
        }
        return id
    }

    private func pollWindowTitle(pid: pid_t) {
        guard let appId = currentAppId else { return }
        let appRef = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success, let window = focusedWindow else { return }
        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        let title = titleValue as? String
        if title != currentWindowTitle {
            try? handleWindowChange(appId: appId, title: title)
        }
    }
}
