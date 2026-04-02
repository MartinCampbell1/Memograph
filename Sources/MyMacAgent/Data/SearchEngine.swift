import Foundation
import os

final class SearchEngine {
    private let db: DatabaseManager
    private let logger = Logger.app

    init(db: DatabaseManager) {
        self.db = db
    }

    func search(query: String, limit: Int = 50) throws -> [ContextSnapshotRecord] {
        let likePattern = "%\(query)%"
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
        let likePattern = "%\(query)%"
        let rows = try db.query("""
            SELECT * FROM context_snapshots
            WHERE (merged_text LIKE ? OR window_title LIKE ? OR app_name LIKE ?)
              AND timestamp LIKE ?
            ORDER BY timestamp DESC
            LIMIT ?
        """, params: [.text(likePattern), .text(likePattern), .text(likePattern),
                      .text("\(date)%"), .integer(Int64(limit))])

        return rows.compactMap { ContextSnapshotRecord(row: $0) }
    }
}
