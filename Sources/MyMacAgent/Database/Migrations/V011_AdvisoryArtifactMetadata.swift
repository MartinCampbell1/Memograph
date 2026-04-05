import Foundation

enum V011_AdvisoryArtifactMetadata {
    static let migration = Migration(version: 11, name: "advisory_artifact_metadata") { db in
        try addColumnIfMissing(
            db: db,
            tableName: "advisory_artifacts",
            columnName: "metadata_json",
            definition: "TEXT"
        )
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
