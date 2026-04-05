import Foundation

enum V009_AttentionMarketMetadata {
    static let migration = Migration(version: 9, name: "attention_market_metadata") { db in
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_artifacts",
            columnName: "domain",
            definition: "TEXT NOT NULL DEFAULT 'continuity'"
        )
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_artifacts",
            columnName: "attention_vector_json",
            definition: "TEXT"
        )
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_artifacts",
            columnName: "market_context_json",
            definition: "TEXT"
        )
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_runs",
            columnName: "recipe_domain",
            definition: "TEXT"
        )

        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_artifacts_domain_status
            ON advisory_artifacts(domain, status, created_at DESC)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_advisory_runs_domain_status
            ON advisory_runs(recipe_domain, status, started_at DESC)
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
