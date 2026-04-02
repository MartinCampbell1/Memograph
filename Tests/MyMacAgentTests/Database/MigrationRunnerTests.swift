import Testing
import Foundation
@testable import MyMacAgent

struct MigrationRunnerTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        return (db, path)
    }

    @Test("Runs migration on fresh DB")
    func runMigrationsOnFreshDB() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let migrations = [
            Migration(version: 1, name: "create_test") { db in
                try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
            }
        ]

        let runner = MigrationRunner(db: db, migrations: migrations)
        try runner.runPending()

        #expect(try db.userVersion() == 1)
        try db.execute("INSERT INTO test (id) VALUES (1)")
    }

    @Test("Skips already applied migrations")
    func skipsApplied() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var runCount = 0
        let migrations = [
            Migration(version: 1, name: "first") { db in
                runCount += 1
                try db.execute("CREATE TABLE first_table (id INTEGER PRIMARY KEY)")
            }
        ]

        let runner = MigrationRunner(db: db, migrations: migrations)
        try runner.runPending()
        try runner.runPending()

        #expect(runCount == 1)
        #expect(try db.userVersion() == 1)
    }

    @Test("Runs multiple migrations in order")
    func multipleInOrder() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var order: [Int] = []
        let migrations = [
            Migration(version: 1, name: "first") { db in
                order.append(1)
                try db.execute("CREATE TABLE t1 (id INTEGER PRIMARY KEY)")
            },
            Migration(version: 2, name: "second") { db in
                order.append(2)
                try db.execute("CREATE TABLE t2 (id INTEGER PRIMARY KEY)")
            }
        ]

        let runner = MigrationRunner(db: db, migrations: migrations)
        try runner.runPending()

        #expect(order == [1, 2])
        #expect(try db.userVersion() == 2)
    }
}
