import Foundation

enum V001_InitialSchema {
    static let migration = Migration(version: 1, name: "initial_schema") { db in
        // 1. apps
        try db.execute("""
            CREATE TABLE apps (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id TEXT UNIQUE,
                app_name  TEXT NOT NULL,
                category  TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)

        // 2. windows
        try db.execute("""
            CREATE TABLE windows (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id      INTEGER NOT NULL REFERENCES apps(id),
                window_title TEXT,
                window_role  TEXT,
                first_seen_at DATETIME,
                last_seen_at  DATETIME,
                fingerprint   TEXT
            )
            """)

        // 3. sessions
        try db.execute("""
            CREATE TABLE sessions (
                id                TEXT PRIMARY KEY,
                app_id            INTEGER NOT NULL REFERENCES apps(id),
                window_id         INTEGER REFERENCES windows(id),
                session_type      TEXT,
                started_at        DATETIME NOT NULL,
                ended_at          DATETIME,
                active_duration_ms INTEGER DEFAULT 0,
                idle_duration_ms   INTEGER DEFAULT 0,
                confidence_score   REAL DEFAULT 0,
                uncertainty_mode   TEXT DEFAULT 'normal',
                top_topic          TEXT,
                is_ai_related      INTEGER DEFAULT 0,
                summary_status     TEXT DEFAULT 'pending'
            )
            """)

        // 4. session_events
        try db.execute("""
            CREATE TABLE session_events (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id   TEXT NOT NULL REFERENCES sessions(id),
                event_type   TEXT NOT NULL,
                timestamp    DATETIME NOT NULL,
                payload_json TEXT
            )
            """)

        // 5. captures
        try db.execute("""
            CREATE TABLE captures (
                id              TEXT PRIMARY KEY,
                session_id      TEXT NOT NULL REFERENCES sessions(id),
                timestamp       DATETIME NOT NULL,
                capture_type    TEXT NOT NULL,
                image_path      TEXT,
                thumb_path      TEXT,
                width           INTEGER,
                height          INTEGER,
                file_size_bytes INTEGER,
                visual_hash     TEXT,
                perceptual_hash TEXT,
                diff_score      REAL DEFAULT 0,
                sampling_mode   TEXT,
                retained        INTEGER DEFAULT 1
            )
            """)

        // 6. ax_snapshots
        try db.execute("""
            CREATE TABLE ax_snapshots (
                id                TEXT PRIMARY KEY,
                session_id        TEXT NOT NULL REFERENCES sessions(id),
                capture_id        TEXT REFERENCES captures(id),
                timestamp         DATETIME NOT NULL,
                focused_role      TEXT,
                focused_subrole   TEXT,
                focused_title     TEXT,
                focused_value     TEXT,
                selected_text     TEXT,
                text_len          INTEGER DEFAULT 0,
                extraction_status TEXT
            )
            """)

        // 7. ocr_snapshots
        try db.execute("""
            CREATE TABLE ocr_snapshots (
                id                TEXT PRIMARY KEY,
                session_id        TEXT NOT NULL REFERENCES sessions(id),
                capture_id        TEXT NOT NULL REFERENCES captures(id),
                timestamp         DATETIME NOT NULL,
                provider          TEXT NOT NULL,
                raw_text          TEXT,
                normalized_text   TEXT,
                text_hash         TEXT,
                confidence        REAL DEFAULT 0,
                language          TEXT,
                processing_ms     INTEGER,
                extraction_status TEXT
            )
            """)

        // 8. context_snapshots
        try db.execute("""
            CREATE TABLE context_snapshots (
                id                TEXT PRIMARY KEY,
                session_id        TEXT NOT NULL REFERENCES sessions(id),
                timestamp         DATETIME NOT NULL,
                app_name          TEXT,
                bundle_id         TEXT,
                window_title      TEXT,
                text_source       TEXT,
                merged_text       TEXT,
                merged_text_hash  TEXT,
                topic_hint        TEXT,
                readable_score    REAL DEFAULT 0,
                uncertainty_score REAL DEFAULT 0,
                source_capture_id TEXT,
                source_ax_id      TEXT,
                source_ocr_id     TEXT
            )
            """)

        // 9. daily_summaries
        try db.execute("""
            CREATE TABLE daily_summaries (
                date                    TEXT PRIMARY KEY,
                summary_text            TEXT,
                top_apps_json           TEXT,
                top_topics_json         TEXT,
                ai_sessions_json        TEXT,
                context_switches_json   TEXT,
                unfinished_items_json   TEXT,
                suggested_notes_json    TEXT,
                generated_at            DATETIME,
                model_name              TEXT,
                token_usage_input       INTEGER DEFAULT 0,
                token_usage_output      INTEGER DEFAULT 0,
                generation_status       TEXT
            )
            """)

        // 10. knowledge_notes
        try db.execute("""
            CREATE TABLE knowledge_notes (
                id                     TEXT PRIMARY KEY,
                note_type              TEXT NOT NULL,
                title                  TEXT NOT NULL,
                body_markdown          TEXT NOT NULL,
                source_date            TEXT,
                tags_json              TEXT,
                links_json             TEXT,
                export_obsidian_status TEXT DEFAULT 'pending',
                export_notion_status   TEXT DEFAULT 'pending',
                created_at             DATETIME DEFAULT CURRENT_TIMESTAMP
            )
            """)

        // 11. app_rules
        try db.execute("""
            CREATE TABLE app_rules (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id  TEXT,
                rule_type  TEXT NOT NULL,
                rule_value TEXT NOT NULL,
                enabled    INTEGER DEFAULT 1
            )
            """)

        // 12. sync_queue
        try db.execute("""
            CREATE TABLE sync_queue (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                job_type     TEXT NOT NULL,
                entity_id    TEXT,
                payload_json TEXT,
                status       TEXT DEFAULT 'pending',
                retry_count  INTEGER DEFAULT 0,
                scheduled_at DATETIME,
                started_at   DATETIME,
                finished_at  DATETIME,
                last_error   TEXT
            )
            """)

        // Indexes
        try db.execute("CREATE INDEX idx_sessions_app_id ON sessions(app_id)")
        try db.execute("CREATE INDEX idx_sessions_started_at ON sessions(started_at)")
        try db.execute("CREATE INDEX idx_session_events_session_id ON session_events(session_id)")
        try db.execute("CREATE INDEX idx_captures_session_id ON captures(session_id)")
        try db.execute("CREATE INDEX idx_captures_timestamp ON captures(timestamp)")
        try db.execute("CREATE INDEX idx_context_snapshots_session_id ON context_snapshots(session_id)")
        try db.execute("CREATE INDEX idx_sync_queue_status ON sync_queue(status)")
    }
}
