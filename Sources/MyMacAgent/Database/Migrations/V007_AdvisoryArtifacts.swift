import Foundation

enum V007_AdvisoryArtifacts {
    static let migration = Migration(version: 7, name: "advisory_artifacts") { db in
        try db.execute("""
            CREATE TABLE IF NOT EXISTS advisory_packets (
                id                   TEXT PRIMARY KEY,
                packet_version       TEXT NOT NULL,
                kind                 TEXT NOT NULL,
                trigger_kind         TEXT,
                window_started_at    DATETIME,
                window_ended_at      DATETIME,
                payload_json         TEXT NOT NULL,
                language             TEXT,
                access_level_granted TEXT,
                created_at           DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS advisory_artifacts (
                id               TEXT PRIMARY KEY,
                kind             TEXT NOT NULL,
                title            TEXT NOT NULL,
                body             TEXT NOT NULL,
                thread_id        TEXT REFERENCES advisory_threads(id) ON DELETE SET NULL,
                source_packet_id TEXT REFERENCES advisory_packets(id) ON DELETE SET NULL,
                source_recipe    TEXT,
                confidence       REAL DEFAULT 0,
                why_now          TEXT,
                evidence_json    TEXT,
                language         TEXT DEFAULT 'ru',
                status           TEXT NOT NULL,
                market_score     REAL DEFAULT 0,
                created_at       DATETIME DEFAULT CURRENT_TIMESTAMP,
                surfaced_at      DATETIME,
                expires_at       DATETIME
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS advisory_artifact_feedback (
                id            TEXT PRIMARY KEY,
                artifact_id   TEXT NOT NULL REFERENCES advisory_artifacts(id) ON DELETE CASCADE,
                feedback_kind TEXT NOT NULL,
                notes         TEXT,
                created_at    DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_packets_kind_created
            ON advisory_packets(kind, created_at DESC)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_artifacts_status_created
            ON advisory_artifacts(status, created_at DESC)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_artifacts_thread_kind
            ON advisory_artifacts(thread_id, kind, status)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_artifact_feedback_artifact
            ON advisory_artifact_feedback(artifact_id, created_at DESC)
        """)
    }
}
