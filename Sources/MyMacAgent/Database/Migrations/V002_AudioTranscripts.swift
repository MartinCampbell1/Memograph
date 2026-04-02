import Foundation

enum V002_AudioTranscripts {
    static let migration = Migration(version: 2, name: "audio_transcripts") { db in
        try db.execute("""
            CREATE TABLE IF NOT EXISTS audio_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                timestamp TEXT NOT NULL,
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("CREATE INDEX IF NOT EXISTS idx_audio_transcripts_timestamp ON audio_transcripts(timestamp)")
    }
}
