import Foundation
import os

final class SessionManager {
    private let db: DatabaseManager
    private let logger = Logger.session
    private(set) var currentSessionId: String?

    init(db: DatabaseManager) {
        self.db = db
    }

    func startSession(appId: Int64, windowId: Int64?) throws -> String {
        let sessionId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute(
            "INSERT INTO sessions (id, app_id, window_id, started_at) VALUES (?, ?, ?, ?)",
            params: [
                .text(sessionId), .integer(appId),
                windowId.map { .integer($0) } ?? .null,
                .text(now)
            ]
        )
        currentSessionId = sessionId
        return sessionId
    }

    func endSession(_ sessionId: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute(
            "UPDATE sessions SET ended_at = ? WHERE id = ?",
            params: [.text(now), .text(sessionId)]
        )
        if currentSessionId == sessionId { currentSessionId = nil }
    }

    func switchSession(appId: Int64, windowId: Int64?) throws -> String {
        if let current = currentSessionId { try endSession(current) }
        return try startSession(appId: appId, windowId: windowId)
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
