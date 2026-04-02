import Testing
import Foundation
@testable import MyMacAgent

struct DatabaseManagerTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        return (db, path)
    }

    @Test("Opening DB creates file")
    func openCreatesFile() throws {
        let (_, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("Execute creates table")
    func executeCreateTable() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
    }

    @Test("Insert and query")
    func insertAndQuery() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
        try db.execute("INSERT INTO test (name) VALUES (?)", params: [.text("hello")])
        let rows = try db.query("SELECT id, name FROM test")
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("hello"))
    }

    @Test("Query returns empty for no rows")
    func queryEmpty() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        let rows = try db.query("SELECT * FROM test")
        #expect(rows.isEmpty)
    }

    @Test("Multiple params")
    func multipleParams() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT, score REAL)")
        try db.execute("INSERT INTO test (name, score) VALUES (?, ?)", params: [.text("alice"), .real(9.5)])
        let rows = try db.query("SELECT name, score FROM test")
        #expect(rows.count == 1)
        #expect(rows[0]["name"] == .text("alice"))
        #expect(rows[0]["score"] == .real(9.5))
    }

    @Test("User version read/write")
    func userVersion() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try db.userVersion() == 0)
        try db.setUserVersion(5)
        #expect(try db.userVersion() == 5)
    }

    @Test("Integer param binding")
    func integerParamBinding() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value INTEGER)")
        try db.execute("INSERT INTO test (value) VALUES (?)", params: [.integer(42)])
        let rows = try db.query("SELECT value FROM test WHERE value = ?", params: [.integer(42)])
        #expect(rows.count == 1)
        #expect(rows[0]["value"] == .integer(42))
    }

    @Test("Null param binding")
    func nullParamBinding() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, value TEXT)")
        try db.execute("INSERT INTO test (value) VALUES (?)", params: [.null])
        let rows = try db.query("SELECT value FROM test")
        #expect(rows.count == 1)
        #expect(rows[0]["value"] == .null)
    }

    @Test("Blob param binding")
    func blobParamBinding() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, data BLOB)")
        let blob = Data([0x01, 0x02, 0x03])
        try db.execute("INSERT INTO test (data) VALUES (?)", params: [.blob(blob)])
        let rows = try db.query("SELECT data FROM test")
        #expect(rows.count == 1)
        #expect(rows[0]["data"] == .blob(blob))
    }

    @Test("Multiple rows returned")
    func multipleRows() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)")
        try db.execute("INSERT INTO test (name) VALUES (?)", params: [.text("alpha")])
        try db.execute("INSERT INTO test (name) VALUES (?)", params: [.text("beta")])
        try db.execute("INSERT INTO test (name) VALUES (?)", params: [.text("gamma")])
        let rows = try db.query("SELECT name FROM test ORDER BY name")
        #expect(rows.count == 3)
        #expect(rows[0]["name"] == .text("alpha"))
        #expect(rows[1]["name"] == .text("beta"))
        #expect(rows[2]["name"] == .text("gamma"))
    }

    @Test("Foreign keys enforcement")
    func foreignKeysEnforcement() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try db.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
        try db.execute("CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))")
        #expect(throws: (any Error).self) {
            try db.execute("INSERT INTO child (parent_id) VALUES (999)")
        }
    }

    @Test("SQLiteValue textValue accessor")
    func textValueAccessor() {
        let v = SQLiteValue.text("hello")
        #expect(v.textValue == "hello")
        #expect(SQLiteValue.integer(1).textValue == nil)
    }

    @Test("SQLiteValue intValue accessor")
    func intValueAccessor() {
        let v = SQLiteValue.integer(42)
        #expect(v.intValue == 42)
        #expect(SQLiteValue.text("x").intValue == nil)
    }

    @Test("SQLiteValue realValue accessor")
    func realValueAccessor() {
        let v = SQLiteValue.real(3.14)
        #expect(v.realValue == 3.14)
        #expect(SQLiteValue.null.realValue == nil)
    }
}
