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
    private let dateSupport: LocalDateSupport
    private let now: () -> Date

    init(
        db: DatabaseManager,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.now = now
    }

    func sessionsForDate(_ date: String) throws -> [TimelineSession] {
        guard let range = dateSupport.utcRange(forLocalDate: date),
              let rangeStart = dateSupport.parseDateTime(range.start),
              let rangeEnd = dateSupport.parseDateTime(range.end) else {
            logger.error("Invalid local date requested for timeline sessions: \(date)")
            return []
        }

        return try sessionRows(for: date).compactMap { row -> TimelineSession? in
            guard let id = row["id"]?.textValue,
                  let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue,
                  let startedAt = row["started_at"]?.textValue else { return nil }
            let durationMs = dateSupport.overlapDurationMs(
                startedAt: startedAt,
                endedAt: row["ended_at"]?.textValue,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                now: now()
            )
            return TimelineSession(
                sessionId: id, appName: appName, bundleId: bundleId,
                startedAt: startedAt, endedAt: row["ended_at"]?.textValue,
                durationMinutes: Int(durationMs / 60000),
                uncertaintyMode: row["uncertainty_mode"]?.textValue ?? "normal"
            )
        }
    }

    func appSummaryForDate(_ date: String) throws -> [AppUsageSummary] {
        guard let range = dateSupport.utcRange(forLocalDate: date),
              let rangeStart = dateSupport.parseDateTime(range.start),
              let rangeEnd = dateSupport.parseDateTime(range.end) else {
            logger.error("Invalid local date requested for app summary: \(date)")
            return []
        }

        let rows = try sessionRows(for: date)
        let grouped = rows.reduce(into: [String: (appName: String, bundleId: String, totalMs: Int64, sessionCount: Int)]()) {
            partialResult, row in
            guard let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue,
                  let startedAt = row["started_at"]?.textValue else { return }
            let effectiveDurationMs = dateSupport.overlapDurationMs(
                startedAt: startedAt,
                endedAt: row["ended_at"]?.textValue,
                rangeStart: rangeStart,
                rangeEnd: rangeEnd,
                now: now()
            )
            let existing = partialResult[bundleId] ?? (appName, bundleId, 0, 0)
            partialResult[bundleId] = (
                appName: existing.appName,
                bundleId: existing.bundleId,
                totalMs: existing.totalMs + effectiveDurationMs,
                sessionCount: existing.sessionCount + 1
            )
        }

        return grouped.values
            .sorted {
                if $0.totalMs == $1.totalMs {
                    return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
                }
                return $0.totalMs > $1.totalMs
            }
            .map { summary in
                AppUsageSummary(
                    appName: summary.appName,
                    bundleId: summary.bundleId,
                    totalMinutes: Int(summary.totalMs / 60000),
                    sessionCount: summary.sessionCount
                )
            }
    }

    func availableDates() throws -> [String] {
        let rows = try db.query("""
            SELECT started_at, ended_at
            FROM sessions
            ORDER BY COALESCE(ended_at, started_at) DESC, started_at DESC
            LIMIT 50000
        """)

        var seen = Set<String>()
        var dates: [String] = []
        for row in rows {
            guard let startedAt = row["started_at"]?.textValue else { continue }
            let coveredDates = dateSupport.localDateStringsSpannedBy(
                startedAt: startedAt,
                endedAt: row["ended_at"]?.textValue,
                now: now()
            )

            for localDate in coveredDates.reversed() {
                if seen.insert(localDate).inserted {
                    dates.append(localDate)
                    if dates.count == 90 {
                        return dates
                    }
                }
            }
        }
        return dates
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

    private func sessionRows(for date: String) throws -> [SQLiteRow] {
        guard let range = dateSupport.utcRange(forLocalDate: date) else {
            logger.error("Invalid local date requested for timeline: \(date)")
            return []
        }

        return try db.query("""
            SELECT s.id, a.app_name, a.bundle_id, s.started_at, s.ended_at,
                   s.active_duration_ms, s.uncertainty_mode
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at < ?
              AND COALESCE(s.ended_at, ?) > ?
            ORDER BY s.started_at
        """, params: [.text(range.end), .text(range.end), .text(range.start)])
    }
}
