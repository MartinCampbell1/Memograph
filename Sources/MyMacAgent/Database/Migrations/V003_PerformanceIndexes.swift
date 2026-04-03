import Foundation

enum V003_PerformanceIndexes {
    static let migration = Migration(version: 3, name: "performance_indexes") { db in
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_sessions_started_ended
            ON sessions(started_at, ended_at)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_context_snapshots_timestamp
            ON context_snapshots(timestamp)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_context_snapshots_timestamp_session_id
            ON context_snapshots(timestamp, session_id)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_context_snapshots_bundle_timestamp
            ON context_snapshots(bundle_id, timestamp)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_session_events_timestamp_type
            ON session_events(timestamp, event_type)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_sync_queue_status_scheduled
            ON sync_queue(status, scheduled_at)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_daily_summaries_generated_at
            ON daily_summaries(generated_at)
        """)

        if try db.tableExists("audio_transcripts") {
            try db.execute("""
                CREATE INDEX IF NOT EXISTS idx_audio_transcripts_session_timestamp
                ON audio_transcripts(session_id, timestamp)
            """)
        }
    }
}
