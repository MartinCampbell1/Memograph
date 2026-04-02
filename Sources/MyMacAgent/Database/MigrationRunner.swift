import Foundation
import os

struct Migration: @unchecked Sendable {
    let version: Int
    let name: String
    let migrate: (DatabaseManager) throws -> Void
}

struct MigrationRunner {
    private let db: DatabaseManager
    private let migrations: [Migration]
    private let logger = Logger.database

    init(db: DatabaseManager, migrations: [Migration]) {
        self.db = db
        self.migrations = migrations.sorted { $0.version < $1.version }
    }

    func runPending() throws {
        let currentVersion = try db.userVersion()
        let pending = migrations.filter { $0.version > currentVersion }

        for migration in pending {
            logger.info("Running migration v\(migration.version): \(migration.name)")
            try migration.migrate(db)
            try db.setUserVersion(migration.version)
            logger.info("Migration v\(migration.version) complete")
        }

        if pending.isEmpty {
            logger.info("No pending migrations (current: v\(currentVersion))")
        }
    }
}
