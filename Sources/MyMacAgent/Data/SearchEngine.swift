import Foundation
import os

final class SearchEngine {
    private let db: DatabaseManager
    private let logger = Logger.app
    private let dateSupport: LocalDateSupport

    init(db: DatabaseManager, timeZone: TimeZone = .autoupdatingCurrent) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func search(query: String, limit: Int = 50) throws -> [ContextSnapshotRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let likePattern = "%\(trimmedQuery)%"
        let rows = try db.query("""
            SELECT * FROM context_snapshots
            WHERE merged_text LIKE ? OR window_title LIKE ? OR app_name LIKE ?
            ORDER BY timestamp DESC
            LIMIT ?
        """, params: [.text(likePattern), .text(likePattern), .text(likePattern),
                      .integer(Int64(limit))])

        return rows.compactMap { ContextSnapshotRecord(row: $0) }
    }

    func searchByDate(query: String, date: String, limit: Int = 50) throws -> [ContextSnapshotRecord] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }
        guard let range = dateSupport.utcRange(forLocalDate: date) else {
            logger.error("Invalid local date requested for search: \(date)")
            return []
        }

        let likePattern = "%\(trimmedQuery)%"
        let rows = try db.query("""
            SELECT * FROM context_snapshots
            WHERE (merged_text LIKE ? OR window_title LIKE ? OR app_name LIKE ?)
              AND timestamp >= ? AND timestamp < ?
            ORDER BY timestamp DESC
            LIMIT ?
        """, params: [
            .text(likePattern),
            .text(likePattern),
            .text(likePattern),
            .text(range.start),
            .text(range.end),
            .integer(Int64(limit))
        ])

        return rows.compactMap { ContextSnapshotRecord(row: $0) }
    }
}
