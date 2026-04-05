import Foundation

enum V008_AdvisoryRuns {
    static let migration = Migration(version: 8, name: "advisory_runs") { db in
        try db.execute("""
            CREATE TABLE IF NOT EXISTS advisory_runs (
                id                       TEXT PRIMARY KEY,
                recipe_name              TEXT NOT NULL,
                packet_id                TEXT REFERENCES advisory_packets(id) ON DELETE SET NULL,
                trigger_kind             TEXT,
                runtime_name             TEXT,
                provider_name            TEXT,
                access_level_requested   TEXT,
                access_level_granted     TEXT,
                status                   TEXT NOT NULL,
                output_artifact_ids_json TEXT,
                error_text               TEXT,
                started_at               DATETIME DEFAULT CURRENT_TIMESTAMP,
                finished_at              DATETIME
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS advisory_evidence_requests (
                id                  TEXT PRIMARY KEY,
                run_id              TEXT NOT NULL REFERENCES advisory_runs(id) ON DELETE CASCADE,
                requested_level     TEXT NOT NULL,
                reason              TEXT,
                evidence_kinds_json TEXT,
                granted             INTEGER DEFAULT 0,
                created_at          DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_runs_status_started
            ON advisory_runs(status, started_at DESC)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_runs_packet
            ON advisory_runs(packet_id)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_evidence_requests_run
            ON advisory_evidence_requests(run_id, created_at DESC)
        """)
    }
}
