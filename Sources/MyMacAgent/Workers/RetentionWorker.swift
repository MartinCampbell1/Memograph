import Foundation
import os

struct RetentionStats {
    let totalCaptures: Int
    let retainedCaptures: Int
    let totalOCRSnapshots: Int
    let totalContextSnapshots: Int
    let totalSessionEvents: Int
    let totalAudioTranscripts: Int
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
        let cutoff = retentionCutoffISO8601()
        let rows = try db.query(
            "SELECT id, image_path, thumb_path FROM captures WHERE timestamp < ?",
            params: [.text(cutoff)]
        )

        for row in rows {
            deleteArtifacts(paths: [row["image_path"]?.textValue, row["thumb_path"]?.textValue])
        }

        try db.execute("DELETE FROM captures WHERE timestamp < ?",
            params: [.text(cutoff)])

        logger.info("Retention: deleted \(rows.count) old captures (before \(cutoff))")
        return rows.count
    }

    func cleanupOldOCRSnapshots() throws -> Int {
        let cutoff = retentionCutoffISO8601()
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
        let cutoff = retentionCutoffISO8601()
        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM ax_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0

        try db.execute("DELETE FROM ax_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)])

        return Int(count)
    }

    func cleanupOldContextSnapshots() throws -> Int {
        let cutoff = retentionCutoffISO8601()
        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM context_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0

        try db.execute("DELETE FROM context_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)])

        logger.info("Retention: deleted \(count) old context snapshots")
        return Int(count)
    }

    func cleanupOldSessionEvents() throws -> Int {
        let cutoff = retentionCutoffISO8601()
        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM session_events WHERE timestamp < ?",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0

        try db.execute("DELETE FROM session_events WHERE timestamp < ?",
            params: [.text(cutoff)])

        logger.info("Retention: deleted \(count) old session events")
        return Int(count)
    }

    func cleanupOldAudioTranscripts() throws -> Int {
        guard try db.tableExists("audio_transcripts") else {
            return 0
        }

        let cutoff = retentionCutoffISO8601()
        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM audio_transcripts WHERE timestamp < ?",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0

        try db.execute("DELETE FROM audio_transcripts WHERE timestamp < ?",
            params: [.text(cutoff)])

        logger.info("Retention: deleted \(count) old audio transcripts")
        return Int(count)
    }

    func thinHighFrequencyCaptures(keepEveryNth: Int = 3) throws -> Int {
        let cutoff = thinningCutoffISO8601()

        let rows = try db.query("""
            SELECT id, image_path, thumb_path FROM captures
            WHERE sampling_mode = 'high_uncertainty'
              AND timestamp < ?
              AND retained = 1
            ORDER BY timestamp
        """, params: [.text(cutoff)])

        var thinned = 0
        for (index, row) in rows.enumerated() {
            if index % keepEveryNth != 0 {
                if let id = row["id"]?.textValue {
                    deleteArtifacts(paths: [row["image_path"]?.textValue, row["thumb_path"]?.textValue])
                    try db.execute("""
                        UPDATE captures
                        SET retained = 0,
                            image_path = NULL,
                            thumb_path = NULL,
                            file_size_bytes = 0
                        WHERE id = ?
                    """, params: [.text(id)])
                    thinned += 1
                }
            }
        }

        logger.info("Retention: thinned \(thinned) high-frequency captures (kept every \(keepEveryNth)th)")
        return thinned
    }

    func runAll() throws {
        let sessionEvents = try cleanupOldSessionEvents()
        let audioTranscripts = try cleanupOldAudioTranscripts()
        let context = try cleanupOldContextSnapshots()
        let ocr = try cleanupOldOCRSnapshots()
        let ax = try cleanupOldAXSnapshots()
        let captures = try cleanupOldCaptures()
        let thinned = try thinHighFrequencyCaptures()
        let sessions = try cleanupOldSessions()
        let windows = try cleanupOrphanedWindows()

        if sessionEvents + audioTranscripts + context + ocr + ax + captures + thinned + sessions + windows > 0 {
            try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            try? db.execute("PRAGMA optimize")
        }

        logger.info("""
            Retention complete: \(captures) captures, \(context) context, \(sessionEvents) events, \
            \(audioTranscripts) audio, \(ocr) OCR, \(ax) AX deleted, \(thinned) thinned, \
            \(sessions) sessions and \(windows) windows pruned
        """)
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
        let totalEvents = try db.query("SELECT COUNT(*) as c FROM session_events")
            .first?["c"]?.intValue ?? 0
        let totalAudio = try db.tableExists("audio_transcripts")
            ? (try db.query("SELECT COUNT(*) as c FROM audio_transcripts").first?["c"]?.intValue ?? 0)
            : 0
        let oldest = try db.query("SELECT MIN(timestamp) as d FROM captures")
            .first?["d"]?.textValue

        return RetentionStats(
            totalCaptures: Int(totalCaptures),
            retainedCaptures: Int(retainedCaptures),
            totalOCRSnapshots: Int(totalOCR),
            totalContextSnapshots: Int(totalCtx),
            totalSessionEvents: Int(totalEvents),
            totalAudioTranscripts: Int(totalAudio),
            oldestCaptureDate: oldest
        )
    }

    private func cleanupOldSessions() throws -> Int {
        let cutoff = retentionCutoffISO8601()
        let hasAudioTranscripts = try db.tableExists("audio_transcripts")
        var exclusionClauses = [
            "id NOT IN (SELECT DISTINCT session_id FROM captures WHERE session_id IS NOT NULL)",
            "id NOT IN (SELECT DISTINCT session_id FROM context_snapshots WHERE session_id IS NOT NULL)",
            "id NOT IN (SELECT DISTINCT session_id FROM session_events WHERE session_id IS NOT NULL)",
            "id NOT IN (SELECT DISTINCT session_id FROM ax_snapshots WHERE session_id IS NOT NULL)",
            "id NOT IN (SELECT DISTINCT session_id FROM ocr_snapshots WHERE session_id IS NOT NULL)"
        ]
        if hasAudioTranscripts {
            exclusionClauses.append("id NOT IN (SELECT DISTINCT session_id FROM audio_transcripts WHERE session_id IS NOT NULL)")
        }

        let predicate = """
            COALESCE(ended_at, started_at) < ?
              AND \(exclusionClauses.joined(separator: " AND "))
        """
        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM sessions WHERE \(predicate)",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0
        try db.execute("DELETE FROM sessions WHERE \(predicate)", params: [.text(cutoff)])
        return Int(count)
    }

    private func cleanupOrphanedWindows() throws -> Int {
        let cutoff = retentionCutoffISO8601()
        let countRows = try db.query("""
            SELECT COUNT(*) as c
            FROM windows
            WHERE id NOT IN (
                SELECT DISTINCT window_id FROM sessions WHERE window_id IS NOT NULL
            )
              AND COALESCE(last_seen_at, first_seen_at, '1970-01-01T00:00:00Z') < ?
        """, params: [.text(cutoff)])
        let count = countRows.first?["c"]?.intValue ?? 0
        try db.execute("""
            DELETE FROM windows
            WHERE id NOT IN (
                SELECT DISTINCT window_id FROM sessions WHERE window_id IS NOT NULL
            )
              AND COALESCE(last_seen_at, first_seen_at, '1970-01-01T00:00:00Z') < ?
        """, params: [.text(cutoff)])
        return Int(count)
    }

    private func retentionCutoffISO8601() -> String {
        let cutoffDate = Calendar.current.date(
            byAdding: .day,
            value: -retentionDays,
            to: Date()
        ) ?? Date()
        return ISO8601DateFormatter().string(from: cutoffDate)
    }

    private func thinningCutoffISO8601() -> String {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        return ISO8601DateFormatter().string(from: cutoffDate)
    }

    private func deleteArtifacts(paths: [String?]) {
        for path in paths.compactMap({ $0 }) where FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
