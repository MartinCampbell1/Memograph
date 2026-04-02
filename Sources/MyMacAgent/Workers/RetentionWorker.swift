import Foundation
import os

struct RetentionStats {
    let totalCaptures: Int
    let retainedCaptures: Int
    let totalOCRSnapshots: Int
    let totalContextSnapshots: Int
    let oldestCaptureDate: String?
}

final class RetentionWorker {
    private let db: DatabaseManager
    private let retentionDays: Int
    private let logger = Logger.app

    init(db: DatabaseManager, retentionDays: Int = 30) {
        self.db = db
        self.retentionDays = retentionDays
    }

    func cleanupOldCaptures() throws -> Int {
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()
        )!
        let cutoff = ISO8601DateFormatter().string(from: cutoffDate)

        // Get files to delete
        let rows = try db.query(
            "SELECT id, image_path, thumb_path FROM captures WHERE timestamp < ?",
            params: [.text(cutoff)]
        )

        // Delete files
        for row in rows {
            if let imagePath = row["image_path"]?.textValue {
                try? FileManager.default.removeItem(atPath: imagePath)
            }
            if let thumbPath = row["thumb_path"]?.textValue {
                try? FileManager.default.removeItem(atPath: thumbPath)
            }
        }

        // Delete from DB
        try db.execute("DELETE FROM captures WHERE timestamp < ?",
            params: [.text(cutoff)])

        logger.info("Retention: deleted \(rows.count) old captures (before \(cutoff))")
        return rows.count
    }

    func cleanupOldOCRSnapshots() throws -> Int {
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()
        )!
        let cutoff = ISO8601DateFormatter().string(from: cutoffDate)

        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM ocr_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0

        try db.execute("DELETE FROM ocr_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)])

        logger.info("Retention: deleted \(count) old OCR snapshots")
        return Int(count)
    }

    func cleanupOldAXSnapshots() throws -> Int {
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()
        )!
        let cutoff = ISO8601DateFormatter().string(from: cutoffDate)

        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM ax_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0

        try db.execute("DELETE FROM ax_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)])

        return Int(count)
    }

    func thinHighFrequencyCaptures(keepEveryNth: Int = 3) throws -> Int {
        // Find high-frequency captures (sampling_mode = 'high_uncertainty')
        // that are older than 1 day, and mark every non-Nth as not retained
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let cutoff = ISO8601DateFormatter().string(from: yesterday)

        let rows = try db.query("""
            SELECT id FROM captures
            WHERE sampling_mode = 'high_uncertainty'
              AND timestamp < ?
              AND retained = 1
            ORDER BY timestamp
        """, params: [.text(cutoff)])

        var thinned = 0
        for (index, row) in rows.enumerated() {
            if index % keepEveryNth != 0 {
                if let id = row["id"]?.textValue {
                    try db.execute("UPDATE captures SET retained = 0 WHERE id = ?",
                        params: [.text(id)])
                    thinned += 1
                }
            }
        }

        logger.info("Retention: thinned \(thinned) high-frequency captures (kept every \(keepEveryNth)th)")
        return thinned
    }

    func runAll() throws {
        let captures = try cleanupOldCaptures()
        let ocr = try cleanupOldOCRSnapshots()
        let ax = try cleanupOldAXSnapshots()
        let thinned = try thinHighFrequencyCaptures()
        logger.info("Retention complete: \(captures) captures, \(ocr) OCR, \(ax) AX deleted, \(thinned) thinned")
    }

    func stats() throws -> RetentionStats {
        let totalCaptures = try db.query("SELECT COUNT(*) as c FROM captures")
            .first?["c"]?.intValue ?? 0
        let retainedCaptures = try db.query("SELECT COUNT(*) as c FROM captures WHERE retained = 1")
            .first?["c"]?.intValue ?? 0
        let totalOCR = try db.query("SELECT COUNT(*) as c FROM ocr_snapshots")
            .first?["c"]?.intValue ?? 0
        let totalCtx = try db.query("SELECT COUNT(*) as c FROM context_snapshots")
            .first?["c"]?.intValue ?? 0
        let oldest = try db.query("SELECT MIN(timestamp) as d FROM captures")
            .first?["d"]?.textValue

        return RetentionStats(
            totalCaptures: Int(totalCaptures),
            retainedCaptures: Int(retainedCaptures),
            totalOCRSnapshots: Int(totalOCR),
            totalContextSnapshots: Int(totalCtx),
            oldestCaptureDate: oldest
        )
    }
}
