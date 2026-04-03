import Foundation

enum V005_KnowledgeGraph {
    static let migration = Migration(version: 5, name: "knowledge_graph") { db in
        try db.execute("""
            CREATE TABLE IF NOT EXISTS knowledge_entities (
                id             TEXT PRIMARY KEY,
                canonical_name TEXT NOT NULL,
                slug           TEXT NOT NULL,
                entity_type    TEXT NOT NULL,
                aliases_json   TEXT,
                first_seen_at  DATETIME,
                last_seen_at   DATETIME,
                created_at     DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS knowledge_claims (
                id                        TEXT PRIMARY KEY,
                window_start              DATETIME,
                window_end                DATETIME,
                source_summary_date       TEXT,
                source_summary_generated_at DATETIME,
                subject_entity_id         TEXT NOT NULL REFERENCES knowledge_entities(id),
                predicate                 TEXT NOT NULL,
                object_text               TEXT,
                confidence                REAL DEFAULT 0.5,
                qualifiers_json           TEXT,
                source_kind               TEXT,
                created_at                DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE TABLE IF NOT EXISTS knowledge_edges (
                id                        TEXT PRIMARY KEY,
                from_entity_id            TEXT NOT NULL REFERENCES knowledge_entities(id),
                to_entity_id              TEXT NOT NULL REFERENCES knowledge_entities(id),
                edge_type                 TEXT NOT NULL,
                weight                    REAL DEFAULT 1,
                supporting_claim_ids_json TEXT,
                updated_at                DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_entities_type_name
            ON knowledge_entities(entity_type, canonical_name)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_knowledge_entities_last_seen
            ON knowledge_entities(last_seen_at)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_knowledge_claims_window
            ON knowledge_claims(window_start, window_end)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_knowledge_claims_subject
            ON knowledge_claims(subject_entity_id)
        """)
        try db.execute("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_knowledge_edges_unique
            ON knowledge_edges(from_entity_id, to_entity_id, edge_type)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_knowledge_notes_type_title
            ON knowledge_notes(note_type, title)
        """)
    }
}
