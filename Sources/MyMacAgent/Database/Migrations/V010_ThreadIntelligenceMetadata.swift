import Foundation

enum V010_ThreadIntelligenceMetadata {
    static let migration = Migration(version: 10, name: "thread_intelligence_metadata") { db in
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_threads",
            columnName: "user_pinned",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_threads",
            columnName: "user_title_override",
            definition: "TEXT"
        )
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_threads",
            columnName: "parent_thread_id",
            definition: "TEXT REFERENCES advisory_threads(id) ON DELETE SET NULL"
        )
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_threads",
            columnName: "total_active_minutes",
            definition: "INTEGER NOT NULL DEFAULT 0"
        )
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_threads",
            columnName: "last_artifact_at",
            definition: "DATETIME"
        )
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_threads",
            columnName: "importance_score",
            definition: "REAL NOT NULL DEFAULT 0"
        )

        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_threads_parent
            ON advisory_threads(parent_thread_id)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_threads_pinned_importance
            ON advisory_threads(user_pinned, importance_score DESC, last_active_at DESC)
        """)
    }

    private static func addColumnIfMissing(
        db: DatabaseManager,
        tableName: String,
        columnName: String,
        definition: String
    ) throws {
        let rows = try db.query("PRAGMA table_info(\(tableName))")
        let exists = rows.contains { $0["name"]?.textValue == columnName }
        guard !exists else { return }
        try db.execute("ALTER TABLE \(tableName) ADD COLUMN \(columnName) \(definition)")
    }
}
