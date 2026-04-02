import Foundation
import os

struct TimelineSession {
    let sessionId: String
    let appName: String
    let bundleId: String
    let startedAt: String
    let endedAt: String?
    let durationMinutes: Int
    let uncertaintyMode: String
}

struct AppUsageSummary {
    let appName: String
    let bundleId: String
    let totalMinutes: Int
    let sessionCount: Int
}

final class TimelineDataProvider {
    private let db: DatabaseManager
    private let logger = Logger.app

    init(db: DatabaseManager) {
        self.db = db
    }

    func sessionsForDate(_ date: String) throws -> [TimelineSession] {
        let rows = try db.query("""
            SELECT s.id, a.app_name, a.bundle_id, s.started_at, s.ended_at,
                   s.active_duration_ms, s.uncertainty_mode
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at LIKE ?
            ORDER BY s.started_at
        """, params: [.text("\(date)%")])

        return rows.compactMap { row -> TimelineSession? in
            guard let id = row["id"]?.textValue,
                  let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue,
                  let startedAt = row["started_at"]?.textValue else { return nil }
            let durationMs = row["active_duration_ms"]?.intValue ?? 0
            return TimelineSession(
                sessionId: id, appName: appName, bundleId: bundleId,
                startedAt: startedAt, endedAt: row["ended_at"]?.textValue,
                durationMinutes: Int(durationMs / 60000),
                uncertaintyMode: row["uncertainty_mode"]?.textValue ?? "normal"
            )
        }
    }

    func appSummaryForDate(_ date: String) throws -> [AppUsageSummary] {
        let rows = try db.query("""
            SELECT a.app_name, a.bundle_id,
                   SUM(s.active_duration_ms) as total_ms,
                   COUNT(s.id) as session_count
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at LIKE ?
            GROUP BY a.bundle_id
            ORDER BY total_ms DESC
        """, params: [.text("\(date)%")])

        return rows.compactMap { row -> AppUsageSummary? in
            guard let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue else { return nil }
            let totalMs = row["total_ms"]?.intValue ?? 0
            let sessionCount = row["session_count"]?.intValue ?? 0
            return AppUsageSummary(
                appName: appName, bundleId: bundleId,
                totalMinutes: Int(totalMs / 60000),
                sessionCount: Int(sessionCount)
            )
        }
    }

    func availableDates() throws -> [String] {
        let rows = try db.query("""
            SELECT DISTINCT SUBSTR(started_at, 1, 10) as date
            FROM sessions
            ORDER BY date DESC
            LIMIT 90
        """)
        return rows.compactMap { $0["date"]?.textValue }
    }

    func contextSnapshotsForSession(_ sessionId: String) throws -> [ContextSnapshotRecord] {
        let rows = try db.query("""
            SELECT * FROM context_snapshots
            WHERE session_id = ?
            ORDER BY timestamp
        """, params: [.text(sessionId)])
        return rows.compactMap { ContextSnapshotRecord(row: $0) }
    }

    func dailySummary(for date: String) throws -> DailySummaryRecord? {
        let rows = try db.query(
            "SELECT * FROM daily_summaries WHERE date = ?",
            params: [.text(date)]
        )
        return rows.first.flatMap { DailySummaryRecord(row: $0) }
    }
}
