import Foundation

enum V006_AdvisoryThreads {
    static let migration = Migration(version: 6, name: "advisory_threads") { db in
        try db.execute("""
            CREATE TABLE IF NOT EXISTS advisory_threads (
                id             TEXT PRIMARY KEY,
                title          TEXT NOT NULL,
                slug           TEXT NOT NULL UNIQUE,
                kind           TEXT NOT NULL,
                status         TEXT NOT NULL,
                confidence     REAL DEFAULT 0,
                first_seen_at  DATETIME,
                last_active_at DATETIME,
                source         TEXT,
                summary        TEXT,
                created_at     DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at     DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS advisory_thread_evidence (
                id            TEXT PRIMARY KEY,
                thread_id     TEXT NOT NULL REFERENCES advisory_threads(id) ON DELETE CASCADE,
                evidence_kind TEXT NOT NULL,
                evidence_ref  TEXT NOT NULL,
                weight        REAL DEFAULT 1,
                created_at    DATETIME DEFAULT CURRENT_TIMESTAMP,
                UNIQUE(thread_id, evidence_kind, evidence_ref)
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS continuity_items (
                id               TEXT PRIMARY KEY,
                thread_id        TEXT REFERENCES advisory_threads(id) ON DELETE SET NULL,
                kind             TEXT NOT NULL,
                title            TEXT NOT NULL,
                body             TEXT,
                status           TEXT NOT NULL,
                confidence       REAL DEFAULT 0,
                source_packet_id TEXT,
                created_at       DATETIME DEFAULT CURRENT_TIMESTAMP,
                updated_at       DATETIME DEFAULT CURRENT_TIMESTAMP,
                resolved_at      DATETIME
            )
        """)

        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_threads_last_active
            ON advisory_threads(last_active_at)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_threads_status
            ON advisory_threads(status, confidence DESC)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_thread_evidence_thread
            ON advisory_thread_evidence(thread_id)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_continuity_items_status
            ON continuity_items(status, updated_at DESC)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_continuity_items_thread
            ON continuity_items(thread_id, status)
        """)
    }
}
