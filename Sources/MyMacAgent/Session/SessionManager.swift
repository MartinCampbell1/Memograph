import Foundation
import os

final class SessionManager {
    private let db: DatabaseManager
    private let logger = Logger.session
    private(set) var currentSessionId: String?
    private var sessionStartTime: Date?
    private var idleStartTime: Date?

    init(db: DatabaseManager) {
        self.db = db
    }

    func startSession(appId: Int64, windowId: Int64?) throws -> String {
        let sessionId = UUID().uuidString
        let now = Date()
        let nowStr = ISO8601DateFormatter().string(from: now)
        try db.execute(
            "INSERT INTO sessions (id, app_id, window_id, started_at) VALUES (?, ?, ?, ?)",
            params: [
                .text(sessionId), .integer(appId),
                windowId.map { .integer($0) } ?? .null,
                .text(nowStr)
            ]
        )
        currentSessionId = sessionId
        sessionStartTime = now
        idleStartTime = nil
        return sessionId
    }

    func endSession(_ sessionId: String) throws {
        let now = Date()
        let nowStr = ISO8601DateFormatter().string(from: now)

        var activeDurationMs: Int64 = 0
        if let start = sessionStartTime {
            activeDurationMs = Int64(now.timeIntervalSince(start) * 1000)
        }

        try db.execute(
            "UPDATE sessions SET ended_at = ?, active_duration_ms = active_duration_ms + ? WHERE id = ?",
            params: [.text(nowStr), .integer(activeDurationMs), .text(sessionId)]
        )

        if currentSessionId == sessionId {
            currentSessionId = nil
            sessionStartTime = nil
            idleStartTime = nil
        }
    }

    func switchSession(appId: Int64, windowId: Int64?) throws -> String {
        if let current = currentSessionId { try endSession(current) }
        return try startSession(appId: appId, windowId: windowId)
    }

    func markIdle(sessionId: String) throws {
        idleStartTime = Date()
        try recordEvent(sessionId: sessionId, type: .idleStarted, payload: nil)
    }

    func markActive(sessionId: String) throws {
        if let idleStart = idleStartTime {
            let idleMs = Int64(Date().timeIntervalSince(idleStart) * 1000)
            try db.execute(
                "UPDATE sessions SET idle_duration_ms = idle_duration_ms + ? WHERE id = ?",
                params: [.integer(idleMs), .text(sessionId)]
            )
            idleStartTime = nil
        }
        try recordEvent(sessionId: sessionId, type: .idleEnded, payload: nil)
    }

    func recordEvent(sessionId: String, type: SessionEventType, payload: String?) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute(
            "INSERT INTO session_events (session_id, event_type, timestamp, payload_json) VALUES (?, ?, ?, ?)",
            params: [
                .text(sessionId), .text(type.rawValue), .text(now),
                payload.map { .text($0) } ?? .null
            ]
        )
    }

    func updateUncertaintyMode(sessionId: String, mode: UncertaintyMode) throws {
        try db.execute(
            "UPDATE sessions SET uncertainty_mode = ? WHERE id = ?",
            params: [.text(mode.rawValue), .text(sessionId)]
        )
    }
}
