import Foundation

enum V004_AudioTranscriptDurability {
    static let migration = Migration(version: 4, name: "audio_transcript_durability") { db in
        guard try db.tableExists("audio_transcripts") else {
            return
        }

        let rows = try db.query("PRAGMA table_info(audio_transcripts)")
        let existingColumns = Set(rows.compactMap { $0["name"]?.textValue })

        if !existingColumns.contains("segment_started_at") {
            try db.execute("ALTER TABLE audio_transcripts ADD COLUMN segment_started_at TEXT")
        }
        if !existingColumns.contains("segment_ended_at") {
            try db.execute("ALTER TABLE audio_transcripts ADD COLUMN segment_ended_at TEXT")
        }
        if !existingColumns.contains("persisted_at") {
            try db.execute("ALTER TABLE audio_transcripts ADD COLUMN persisted_at TEXT")
        }

        try db.execute("""
            UPDATE audio_transcripts
            SET segment_started_at = COALESCE(segment_started_at, timestamp),
                segment_ended_at = COALESCE(
                    segment_ended_at,
                    CASE
                        WHEN duration_seconds > 0 THEN datetime(timestamp, '+' || CAST(duration_seconds AS INTEGER) || ' seconds')
                        ELSE timestamp
                    END
                ),
                persisted_at = COALESCE(persisted_at, timestamp)
        """)

        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_audio_transcripts_segment_window
            ON audio_transcripts(segment_started_at, segment_ended_at)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_sync_queue_job_status_scheduled
            ON sync_queue(job_type, status, scheduled_at)
        """)
    }
}
