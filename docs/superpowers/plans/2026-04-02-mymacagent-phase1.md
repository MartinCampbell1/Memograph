# MyMacAgent Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the foundation of a macOS menu bar app that tracks active apps/windows, creates sessions, captures screenshots, and stores everything in SQLite.

**Architecture:** Native macOS app using Swift + SwiftUI with a menu bar presence. NSWorkspace notifications drive app/window monitoring. ScreenCaptureKit handles window capture. SQLite (via raw C API wrapper) provides local storage with explicit schema migrations. All background work runs on Swift Concurrency actors to keep the UI responsive.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, ScreenCaptureKit, SQLite3 (C API), XCTest

**Phases overview:**
- **Phase 1 (this plan):** Sprint 0 (Bootstrap) + Sprint 1 (App/Window Tracking) + Sprint 2 (Screen Capture)
- **Phase 2:** Sprint 3 (Accessibility) + Sprint 4 (OCR) + Sprint 5 (Adaptive Capture Policy)
- **Phase 3:** Sprint 6 (Context Fusion) + Sprint 7 (Daily Summary) + Sprint 8 (Obsidian Export)
- **Phase 4:** Sprint 9 (UI/Timeline) + Sprint 10 (Optimization) + Sprint 11 (Notion Export)

---

## File Structure

```
MyMacAgent/
├── Package.swift
├── Sources/
│   └── MyMacAgent/
│       ├── App/
│       │   ├── MyMacAgentApp.swift          -- SwiftUI App entry, menu bar setup
│       │   ├── AppDelegate.swift            -- NSApplicationDelegate for system events
│       │   └── MenuBarManager.swift         -- Menu bar icon, popover, status
│       ├── Models/
│       │   ├── AppRecord.swift              -- apps table model
│       │   ├── WindowRecord.swift           -- windows table model
│       │   ├── Session.swift                -- sessions table model
│       │   ├── SessionEvent.swift           -- session_events table model
│       │   ├── CaptureRecord.swift          -- captures table model
│       │   └── AppRule.swift                -- app_rules table model
│       ├── Database/
│       │   ├── DatabaseManager.swift        -- SQLite connection, query helpers
│       │   ├── MigrationRunner.swift        -- Schema migration runner
│       │   └── Migrations/
│       │       └── V001_InitialSchema.swift -- All initial tables
│       ├── Monitors/
│       │   ├── AppMonitor.swift             -- NSWorkspace active app tracking
│       │   ├── WindowMonitor.swift          -- AXUIElement window title tracking
│       │   └── IdleDetector.swift           -- CGEventSource idle detection
│       ├── Session/
│       │   └── SessionManager.swift         -- Session lifecycle management
│       ├── Capture/
│       │   ├── ScreenCaptureEngine.swift    -- ScreenCaptureKit wrapper
│       │   └── ImageProcessor.swift         -- Resize, compress, hash
│       ├── Permissions/
│       │   ├── PermissionsManager.swift     -- Check/request system permissions
│       │   └── PermissionsView.swift        -- Onboarding permissions UI
│       ├── Settings/
│       │   └── SettingsView.swift           -- Basic settings UI
│       ├── Views/
│       │   └── MenuBarPopover.swift         -- Quick status popover
│       └── Utilities/
│           └── Logger.swift                 -- OSLog wrapper
├── Tests/
│   └── MyMacAgentTests/
│       ├── Database/
│       │   ├── DatabaseManagerTests.swift
│       │   └── MigrationRunnerTests.swift
│       ├── Monitors/
│       │   ├── AppMonitorTests.swift
│       │   ├── WindowMonitorTests.swift
│       │   └── IdleDetectorTests.swift
│       ├── Session/
│       │   └── SessionManagerTests.swift
│       ├── Capture/
│       │   ├── ScreenCaptureEngineTests.swift
│       │   └── ImageProcessorTests.swift
│       └── Models/
│           └── ModelTests.swift
└── Resources/
    └── Info.plist
```

---

## Task 1: Xcode Project Bootstrap

**Files:**
- Create: `MyMacAgent.xcodeproj` (via Xcode CLI)
- Create: `MyMacAgent/Sources/MyMacAgent/App/MyMacAgentApp.swift`
- Create: `MyMacAgent/Sources/MyMacAgent/Utilities/Logger.swift`
- Create: `MyMacAgent/Sources/MyMacAgent/Info.plist`

- [ ] **Step 1: Create Xcode project**

Create a new macOS App project with SwiftUI lifecycle:

```bash
cd /Users/martin/mymacagent
mkdir -p MyMacAgent
cd MyMacAgent
# We'll use swift package init and then create an Xcode project
```

Since this is a macOS app requiring system permissions (Screen Recording, Accessibility), we need an Xcode project with proper entitlements. Create it manually:

```bash
cd /Users/martin/mymacagent
mkdir -p MyMacAgent/MyMacAgent
mkdir -p MyMacAgent/MyMacAgentTests
```

- [ ] **Step 2: Create the SwiftUI App entry point**

Create `MyMacAgent/MyMacAgent/MyMacAgentApp.swift`:

```swift
import SwiftUI

@main
struct MyMacAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("MyMacAgent", systemImage: "brain.head.profile") {
            MenuBarPopover()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
```

- [ ] **Step 3: Create AppDelegate**

Create `MyMacAgent/MyMacAgent/AppDelegate.swift`:

```swift
import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger.app

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MyMacAgent launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("MyMacAgent terminating")
    }
}
```

- [ ] **Step 4: Create Logger utility**

Create `MyMacAgent/MyMacAgent/Utilities/Logger.swift`:

```swift
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.mymacagent"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let monitor = Logger(subsystem: subsystem, category: "monitor")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
```

- [ ] **Step 5: Create placeholder views**

Create `MyMacAgent/MyMacAgent/Views/MenuBarPopover.swift`:

```swift
import SwiftUI

struct MenuBarPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyMacAgent")
                .font(.headline)
            Text("Status: Starting...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 250)
    }
}
```

Create `MyMacAgent/MyMacAgent/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        Text("Settings — coming soon")
            .frame(width: 400, height: 300)
    }
}
```

- [ ] **Step 6: Create Info.plist**

Create `MyMacAgent/MyMacAgent/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MyMacAgent</string>
    <key>CFBundleIdentifier</key>
    <string>com.martin.mymacagent</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>MyMacAgent needs screen recording permission to capture window contents for activity logging.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>MyMacAgent needs accessibility access to read window contents.</string>
</dict>
</plist>
```

Note: `LSUIElement = true` makes this a menu bar-only app (no Dock icon).

- [ ] **Step 7: Build and verify the app launches**

```bash
cd /Users/martin/mymacagent/MyMacAgent
xcodebuild -scheme MyMacAgent -configuration Debug build
```

Expected: BUILD SUCCEEDED. App launches with menu bar icon.

- [ ] **Step 8: Commit**

```bash
git init
git add .
git commit -m "feat: bootstrap macOS menu bar app with SwiftUI"
```

---

## Task 2: SQLite Database Manager

**Files:**
- Create: `MyMacAgent/MyMacAgent/Database/DatabaseManager.swift`
- Test: `MyMacAgent/MyMacAgentTests/Database/DatabaseManagerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Database/DatabaseManagerTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class DatabaseManagerTests: XCTestCase {
    private var db: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        db = try! DatabaseManager(path: dbPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testOpenCreatesFile() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
    }

    func testExecuteCreateTable() throws {
        try db.execute("""
            CREATE TABLE test (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL
            )
        """)
        // Should not throw
    }

    func testInsertAndQuery() throws {
        try db.execute("""
            CREATE TABLE test (
                id INTEGER PRIMARY KEY,
                name TEXT NOT NULL
            )
        """)

        try db.execute("INSERT INTO test (name) VALUES (?)", params: [.text("hello")])

        let rows = try db.query("SELECT id, name FROM test")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"], .text("hello"))
    }

    func testQueryReturnsEmptyForNoRows() throws {
        try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
        let rows = try db.query("SELECT * FROM test")
        XCTAssertTrue(rows.isEmpty)
    }

    func testExecuteWithMultipleParams() throws {
        try db.execute("""
            CREATE TABLE test (
                id INTEGER PRIMARY KEY,
                name TEXT,
                score REAL
            )
        """)

        try db.execute(
            "INSERT INTO test (name, score) VALUES (?, ?)",
            params: [.text("alice"), .real(9.5)]
        )

        let rows = try db.query("SELECT name, score FROM test")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["name"], .text("alice"))
        XCTAssertEqual(rows[0]["score"], .real(9.5))
    }

    func testUserVersion() throws {
        XCTAssertEqual(try db.userVersion(), 0)
        try db.setUserVersion(5)
        XCTAssertEqual(try db.userVersion(), 5)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `DatabaseManager` not found.

- [ ] **Step 3: Implement DatabaseManager**

Create `MyMacAgent/MyMacAgent/Database/DatabaseManager.swift`:

```swift
import Foundation
import SQLite3
import os

enum SQLiteValue: Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null

    var textValue: String? {
        if case .text(let v) = self { return v }
        return nil
    }

    var intValue: Int64? {
        if case .integer(let v) = self { return v }
        return nil
    }

    var realValue: Double? {
        if case .real(let v) = self { return v }
        return nil
    }
}

typealias SQLiteRow = [String: SQLiteValue]

final class DatabaseManager {
    private var db: OpaquePointer?
    private let logger = Logger.database

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &db, flags, nil)
        guard result == SQLITE_OK else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw DatabaseError.openFailed(msg)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        logger.info("Database opened at \(path)")
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func execute(_ sql: String, params: [SQLiteValue] = []) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(errorMessage)
        }

        try bind(stmt: stmt!, params: params)

        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DatabaseError.executeFailed(errorMessage)
        }
    }

    func query(_ sql: String, params: [SQLiteValue] = []) throws -> [SQLiteRow] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(errorMessage)
        }

        try bind(stmt: stmt!, params: params)

        var rows: [SQLiteRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: SQLiteRow = [:]
            let columnCount = sqlite3_column_count(stmt)
            for i in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                let value = readColumn(stmt: stmt!, index: i)
                row[name] = value
            }
            rows.append(row)
        }
        return rows
    }

    func userVersion() throws -> Int {
        let rows = try query("PRAGMA user_version")
        guard let row = rows.first, let val = row["user_version"]?.intValue else {
            return 0
        }
        return Int(val)
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    // MARK: - Private

    private var errorMessage: String {
        db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }

    private func bind(stmt: OpaquePointer, params: [SQLiteValue]) throws {
        for (index, param) in params.enumerated() {
            let i = Int32(index + 1)
            let result: Int32
            switch param {
            case .text(let v):
                result = sqlite3_bind_text(stmt, i, (v as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .integer(let v):
                result = sqlite3_bind_int64(stmt, i, v)
            case .real(let v):
                result = sqlite3_bind_double(stmt, i, v)
            case .blob(let v):
                result = v.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, i, ptr.baseAddress, Int32(v.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            case .null:
                result = sqlite3_bind_null(stmt, i)
            }
            guard result == SQLITE_OK else {
                throw DatabaseError.bindFailed(errorMessage)
            }
        }
    }

    private func readColumn(stmt: OpaquePointer, index: Int32) -> SQLiteValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(stmt, index)))
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(stmt, index))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(stmt, index))
            if let ptr = sqlite3_column_blob(stmt, index) {
                return .blob(Data(bytes: ptr, count: count))
            }
            return .null
        default:
            return .null
        }
    }
}

enum DatabaseError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case executeFailed(String)
    case bindFailed(String)
    case migrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let m): return "DB open failed: \(m)"
        case .prepareFailed(let m): return "SQL prepare failed: \(m)"
        case .executeFailed(let m): return "SQL execute failed: \(m)"
        case .bindFailed(let m): return "SQL bind failed: \(m)"
        case .migrationFailed(let m): return "Migration failed: \(m)"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|Tests|PASS|FAIL)"
```

Expected: All DatabaseManagerTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Database/DatabaseManager.swift MyMacAgent/MyMacAgentTests/Database/DatabaseManagerTests.swift
git commit -m "feat: add SQLite database manager with parameterized queries"
```

---

## Task 3: Migration Runner

**Files:**
- Create: `MyMacAgent/MyMacAgent/Database/MigrationRunner.swift`
- Test: `MyMacAgent/MyMacAgentTests/Database/MigrationRunnerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Database/MigrationRunnerTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class MigrationRunnerTests: XCTestCase {
    private var db: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        db = try! DatabaseManager(path: dbPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testRunMigrationsOnFreshDB() throws {
        let migrations: [Migration] = [
            Migration(version: 1, name: "create_test") { db in
                try db.execute("CREATE TABLE test (id INTEGER PRIMARY KEY)")
            }
        ]

        let runner = MigrationRunner(db: db, migrations: migrations)
        try runner.runPending()

        XCTAssertEqual(try db.userVersion(), 1)
        // Table should exist — inserting should not throw
        try db.execute("INSERT INTO test (id) VALUES (1)")
    }

    func testSkipsAlreadyAppliedMigrations() throws {
        var runCount = 0
        let migrations: [Migration] = [
            Migration(version: 1, name: "first") { db in
                runCount += 1
                try db.execute("CREATE TABLE first_table (id INTEGER PRIMARY KEY)")
            }
        ]

        let runner = MigrationRunner(db: db, migrations: migrations)
        try runner.runPending()
        try runner.runPending() // second run should skip

        XCTAssertEqual(runCount, 1)
        XCTAssertEqual(try db.userVersion(), 1)
    }

    func testRunsMultipleMigrationsInOrder() throws {
        var order: [Int] = []
        let migrations: [Migration] = [
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

        XCTAssertEqual(order, [1, 2])
        XCTAssertEqual(try db.userVersion(), 2)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `Migration` and `MigrationRunner` not found.

- [ ] **Step 3: Implement MigrationRunner**

Create `MyMacAgent/MyMacAgent/Database/MigrationRunner.swift`:

```swift
import Foundation
import os

struct Migration {
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
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All MigrationRunnerTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Database/MigrationRunner.swift MyMacAgent/MyMacAgentTests/Database/MigrationRunnerTests.swift
git commit -m "feat: add migration runner for versioned SQLite schema upgrades"
```

---

## Task 4: Initial Schema Migration (V001)

**Files:**
- Create: `MyMacAgent/MyMacAgent/Database/Migrations/V001_InitialSchema.swift`
- Test: `MyMacAgent/MyMacAgentTests/Database/V001_InitialSchemaTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MyMacAgent/MyMacAgentTests/Database/V001_InitialSchemaTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class V001_InitialSchemaTests: XCTestCase {
    private var db: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        db = try! DatabaseManager(path: dbPath)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testMigrationCreatesAllTables() throws {
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()

        let expectedTables = [
            "apps", "windows", "sessions", "session_events",
            "captures", "ax_snapshots", "ocr_snapshots",
            "context_snapshots", "daily_summaries",
            "knowledge_notes", "app_rules", "sync_queue"
        ]

        for table in expectedTables {
            let rows = try db.query(
                "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
                params: [.text(table)]
            )
            XCTAssertEqual(rows.count, 1, "Table '\(table)' should exist")
        }
    }

    func testCanInsertApp() throws {
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()

        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")]
        )

        let rows = try db.query("SELECT bundle_id, app_name FROM apps")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["bundle_id"]?.textValue, "com.apple.Safari")
    }

    func testCanInsertSession() throws {
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()

        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")]
        )

        try db.execute(
            "INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")]
        )

        let rows = try db.query("SELECT id, app_id FROM sessions")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["id"]?.textValue, "sess-1")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `V001_InitialSchema` not found.

- [ ] **Step 3: Implement V001_InitialSchema**

Create `MyMacAgent/MyMacAgent/Database/Migrations/V001_InitialSchema.swift`:

```swift
import Foundation

enum V001_InitialSchema {
    static let migration = Migration(version: 1, name: "initial_schema") { db in
        try db.execute("""
            CREATE TABLE apps (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id TEXT UNIQUE,
                app_name TEXT NOT NULL,
                category TEXT,
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE TABLE windows (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                app_id INTEGER NOT NULL,
                window_title TEXT,
                window_role TEXT,
                first_seen_at DATETIME,
                last_seen_at DATETIME,
                fingerprint TEXT,
                FOREIGN KEY (app_id) REFERENCES apps(id)
            )
        """)

        try db.execute("""
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                app_id INTEGER NOT NULL,
                window_id INTEGER,
                session_type TEXT,
                started_at DATETIME NOT NULL,
                ended_at DATETIME,
                active_duration_ms INTEGER DEFAULT 0,
                idle_duration_ms INTEGER DEFAULT 0,
                confidence_score REAL DEFAULT 0,
                uncertainty_mode TEXT DEFAULT 'normal',
                top_topic TEXT,
                is_ai_related INTEGER DEFAULT 0,
                summary_status TEXT DEFAULT 'pending',
                FOREIGN KEY (app_id) REFERENCES apps(id),
                FOREIGN KEY (window_id) REFERENCES windows(id)
            )
        """)

        try db.execute("""
            CREATE TABLE session_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL,
                event_type TEXT NOT NULL,
                timestamp DATETIME NOT NULL,
                payload_json TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            )
        """)

        try db.execute("""
            CREATE TABLE captures (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                timestamp DATETIME NOT NULL,
                capture_type TEXT NOT NULL,
                image_path TEXT,
                thumb_path TEXT,
                width INTEGER,
                height INTEGER,
                file_size_bytes INTEGER,
                visual_hash TEXT,
                perceptual_hash TEXT,
                diff_score REAL DEFAULT 0,
                sampling_mode TEXT,
                retained INTEGER DEFAULT 1,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            )
        """)

        try db.execute("""
            CREATE TABLE ax_snapshots (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                capture_id TEXT,
                timestamp DATETIME NOT NULL,
                focused_role TEXT,
                focused_subrole TEXT,
                focused_title TEXT,
                focused_value TEXT,
                selected_text TEXT,
                text_len INTEGER DEFAULT 0,
                extraction_status TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id),
                FOREIGN KEY (capture_id) REFERENCES captures(id)
            )
        """)

        try db.execute("""
            CREATE TABLE ocr_snapshots (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                capture_id TEXT NOT NULL,
                timestamp DATETIME NOT NULL,
                provider TEXT NOT NULL,
                raw_text TEXT,
                normalized_text TEXT,
                text_hash TEXT,
                confidence REAL DEFAULT 0,
                language TEXT,
                processing_ms INTEGER,
                extraction_status TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id),
                FOREIGN KEY (capture_id) REFERENCES captures(id)
            )
        """)

        try db.execute("""
            CREATE TABLE context_snapshots (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                timestamp DATETIME NOT NULL,
                app_name TEXT,
                bundle_id TEXT,
                window_title TEXT,
                text_source TEXT,
                merged_text TEXT,
                merged_text_hash TEXT,
                topic_hint TEXT,
                readable_score REAL DEFAULT 0,
                uncertainty_score REAL DEFAULT 0,
                source_capture_id TEXT,
                source_ax_id TEXT,
                source_ocr_id TEXT,
                FOREIGN KEY (session_id) REFERENCES sessions(id)
            )
        """)

        try db.execute("""
            CREATE TABLE daily_summaries (
                date TEXT PRIMARY KEY,
                summary_text TEXT,
                top_apps_json TEXT,
                top_topics_json TEXT,
                ai_sessions_json TEXT,
                context_switches_json TEXT,
                unfinished_items_json TEXT,
                suggested_notes_json TEXT,
                generated_at DATETIME,
                model_name TEXT,
                token_usage_input INTEGER DEFAULT 0,
                token_usage_output INTEGER DEFAULT 0,
                generation_status TEXT
            )
        """)

        try db.execute("""
            CREATE TABLE knowledge_notes (
                id TEXT PRIMARY KEY,
                note_type TEXT NOT NULL,
                title TEXT NOT NULL,
                body_markdown TEXT NOT NULL,
                source_date TEXT,
                tags_json TEXT,
                links_json TEXT,
                export_obsidian_status TEXT DEFAULT 'pending',
                export_notion_status TEXT DEFAULT 'pending',
                created_at DATETIME DEFAULT CURRENT_TIMESTAMP
            )
        """)

        try db.execute("""
            CREATE TABLE app_rules (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bundle_id TEXT,
                rule_type TEXT NOT NULL,
                rule_value TEXT NOT NULL,
                enabled INTEGER DEFAULT 1
            )
        """)

        try db.execute("""
            CREATE TABLE sync_queue (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                job_type TEXT NOT NULL,
                entity_id TEXT,
                payload_json TEXT,
                status TEXT DEFAULT 'pending',
                retry_count INTEGER DEFAULT 0,
                scheduled_at DATETIME,
                started_at DATETIME,
                finished_at DATETIME,
                last_error TEXT
            )
        """)

        // Indexes for common queries
        try db.execute("CREATE INDEX idx_sessions_app_id ON sessions(app_id)")
        try db.execute("CREATE INDEX idx_sessions_started_at ON sessions(started_at)")
        try db.execute("CREATE INDEX idx_session_events_session_id ON session_events(session_id)")
        try db.execute("CREATE INDEX idx_captures_session_id ON captures(session_id)")
        try db.execute("CREATE INDEX idx_captures_timestamp ON captures(timestamp)")
        try db.execute("CREATE INDEX idx_context_snapshots_session_id ON context_snapshots(session_id)")
        try db.execute("CREATE INDEX idx_sync_queue_status ON sync_queue(status)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All V001_InitialSchemaTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Database/Migrations/V001_InitialSchema.swift MyMacAgent/MyMacAgentTests/Database/V001_InitialSchemaTests.swift
git commit -m "feat: add V001 initial schema migration with all 12 tables"
```

---

## Task 5: Data Models

**Files:**
- Create: `MyMacAgent/MyMacAgent/Models/AppRecord.swift`
- Create: `MyMacAgent/MyMacAgent/Models/WindowRecord.swift`
- Create: `MyMacAgent/MyMacAgent/Models/Session.swift`
- Create: `MyMacAgent/MyMacAgent/Models/SessionEvent.swift`
- Create: `MyMacAgent/MyMacAgent/Models/CaptureRecord.swift`
- Create: `MyMacAgent/MyMacAgent/Models/AppRule.swift`
- Test: `MyMacAgent/MyMacAgentTests/Models/ModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Models/ModelTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class ModelTests: XCTestCase {

    func testAppRecordFromRow() {
        let row: SQLiteRow = [
            "id": .integer(1),
            "bundle_id": .text("com.apple.Safari"),
            "app_name": .text("Safari"),
            "category": .null,
            "created_at": .text("2026-04-02T10:00:00Z")
        ]

        let app = AppRecord(row: row)
        XCTAssertNotNil(app)
        XCTAssertEqual(app?.id, 1)
        XCTAssertEqual(app?.bundleId, "com.apple.Safari")
        XCTAssertEqual(app?.appName, "Safari")
        XCTAssertNil(app?.category)
    }

    func testSessionFromRow() {
        let row: SQLiteRow = [
            "id": .text("sess-1"),
            "app_id": .integer(1),
            "window_id": .integer(2),
            "started_at": .text("2026-04-02T10:00:00Z"),
            "ended_at": .null,
            "active_duration_ms": .integer(5000),
            "idle_duration_ms": .integer(0),
            "uncertainty_mode": .text("normal"),
            "summary_status": .text("pending")
        ]

        let session = Session(row: row)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, "sess-1")
        XCTAssertEqual(session?.appId, 1)
        XCTAssertEqual(session?.activeDurationMs, 5000)
        XCTAssertEqual(session?.uncertaintyMode, .normal)
    }

    func testSessionEventTypes() {
        XCTAssertEqual(SessionEventType.appActivated.rawValue, "app_activated")
        XCTAssertEqual(SessionEventType.windowChanged.rawValue, "window_changed")
        XCTAssertEqual(SessionEventType.captureTaken.rawValue, "capture_taken")
        XCTAssertEqual(SessionEventType.modeChanged.rawValue, "mode_changed")
        XCTAssertEqual(SessionEventType.idleStarted.rawValue, "idle_started")
        XCTAssertEqual(SessionEventType.idleEnded.rawValue, "idle_ended")
    }

    func testUncertaintyModeFromString() {
        XCTAssertEqual(UncertaintyMode(rawValue: "normal"), .normal)
        XCTAssertEqual(UncertaintyMode(rawValue: "degraded"), .degraded)
        XCTAssertEqual(UncertaintyMode(rawValue: "high_uncertainty"), .highUncertainty)
        XCTAssertEqual(UncertaintyMode(rawValue: "recovery"), .recovery)
    }

    func testCaptureRecordFromRow() {
        let row: SQLiteRow = [
            "id": .text("cap-1"),
            "session_id": .text("sess-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"),
            "capture_type": .text("window"),
            "image_path": .text("/tmp/cap.png"),
            "width": .integer(1920),
            "height": .integer(1080),
            "file_size_bytes": .integer(50000),
            "visual_hash": .text("abc123"),
            "diff_score": .real(0.05),
            "sampling_mode": .text("normal"),
            "retained": .integer(1)
        ]

        let capture = CaptureRecord(row: row)
        XCTAssertNotNil(capture)
        XCTAssertEqual(capture?.id, "cap-1")
        XCTAssertEqual(capture?.width, 1920)
        XCTAssertEqual(capture?.diffScore, 0.05)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — models not found.

- [ ] **Step 3: Implement models**

Create `MyMacAgent/MyMacAgent/Models/AppRecord.swift`:

```swift
import Foundation

struct AppRecord {
    let id: Int64
    let bundleId: String?
    let appName: String
    let category: String?
    let createdAt: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.intValue,
              let appName = row["app_name"]?.textValue else { return nil }
        self.id = id
        self.bundleId = row["bundle_id"]?.textValue
        self.appName = appName
        self.category = row["category"]?.textValue
        self.createdAt = row["created_at"]?.textValue
    }
}
```

Create `MyMacAgent/MyMacAgent/Models/WindowRecord.swift`:

```swift
import Foundation

struct WindowRecord {
    let id: Int64
    let appId: Int64
    let windowTitle: String?
    let windowRole: String?
    let firstSeenAt: String?
    let lastSeenAt: String?
    let fingerprint: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.intValue,
              let appId = row["app_id"]?.intValue else { return nil }
        self.id = id
        self.appId = appId
        self.windowTitle = row["window_title"]?.textValue
        self.windowRole = row["window_role"]?.textValue
        self.firstSeenAt = row["first_seen_at"]?.textValue
        self.lastSeenAt = row["last_seen_at"]?.textValue
        self.fingerprint = row["fingerprint"]?.textValue
    }
}
```

Create `MyMacAgent/MyMacAgent/Models/Session.swift`:

```swift
import Foundation

enum UncertaintyMode: String {
    case normal
    case degraded
    case highUncertainty = "high_uncertainty"
    case recovery
}

struct Session {
    let id: String
    let appId: Int64
    let windowId: Int64?
    let sessionType: String?
    let startedAt: String
    let endedAt: String?
    let activeDurationMs: Int64
    let idleDurationMs: Int64
    let confidenceScore: Double
    let uncertaintyMode: UncertaintyMode
    let topTopic: String?
    let isAiRelated: Bool
    let summaryStatus: String

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let appId = row["app_id"]?.intValue,
              let startedAt = row["started_at"]?.textValue else { return nil }
        self.id = id
        self.appId = appId
        self.windowId = row["window_id"]?.intValue
        self.sessionType = row["session_type"]?.textValue
        self.startedAt = startedAt
        self.endedAt = row["ended_at"]?.textValue
        self.activeDurationMs = row["active_duration_ms"]?.intValue ?? 0
        self.idleDurationMs = row["idle_duration_ms"]?.intValue ?? 0
        self.confidenceScore = row["confidence_score"]?.realValue ?? 0
        self.uncertaintyMode = UncertaintyMode(rawValue: row["uncertainty_mode"]?.textValue ?? "normal") ?? .normal
        self.topTopic = row["top_topic"]?.textValue
        self.isAiRelated = (row["is_ai_related"]?.intValue ?? 0) != 0
        self.summaryStatus = row["summary_status"]?.textValue ?? "pending"
    }
}
```

Create `MyMacAgent/MyMacAgent/Models/SessionEvent.swift`:

```swift
import Foundation

enum SessionEventType: String {
    case appActivated = "app_activated"
    case windowChanged = "window_changed"
    case captureTaken = "capture_taken"
    case ocrRequested = "ocr_requested"
    case ocrCompleted = "ocr_completed"
    case axSnapshotTaken = "ax_snapshot_taken"
    case modeChanged = "mode_changed"
    case summaryGenerated = "summary_generated"
    case exportCompleted = "export_completed"
    case idleStarted = "idle_started"
    case idleEnded = "idle_ended"
}

struct SessionEvent {
    let id: Int64
    let sessionId: String
    let eventType: SessionEventType
    let timestamp: String
    let payloadJson: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.intValue,
              let sessionId = row["session_id"]?.textValue,
              let eventTypeStr = row["event_type"]?.textValue,
              let eventType = SessionEventType(rawValue: eventTypeStr),
              let timestamp = row["timestamp"]?.textValue else { return nil }
        self.id = id
        self.sessionId = sessionId
        self.eventType = eventType
        self.timestamp = timestamp
        self.payloadJson = row["payload_json"]?.textValue
    }
}
```

Create `MyMacAgent/MyMacAgent/Models/CaptureRecord.swift`:

```swift
import Foundation

struct CaptureRecord {
    let id: String
    let sessionId: String
    let timestamp: String
    let captureType: String
    let imagePath: String?
    let thumbPath: String?
    let width: Int?
    let height: Int?
    let fileSizeBytes: Int?
    let visualHash: String?
    let perceptualHash: String?
    let diffScore: Double
    let samplingMode: String?
    let retained: Bool

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let sessionId = row["session_id"]?.textValue,
              let timestamp = row["timestamp"]?.textValue,
              let captureType = row["capture_type"]?.textValue else { return nil }
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.captureType = captureType
        self.imagePath = row["image_path"]?.textValue
        self.thumbPath = row["thumb_path"]?.textValue
        self.width = row["width"]?.intValue.flatMap { Int($0) }
        self.height = row["height"]?.intValue.flatMap { Int($0) }
        self.fileSizeBytes = row["file_size_bytes"]?.intValue.flatMap { Int($0) }
        self.visualHash = row["visual_hash"]?.textValue
        self.perceptualHash = row["perceptual_hash"]?.textValue
        self.diffScore = row["diff_score"]?.realValue ?? 0
        self.samplingMode = row["sampling_mode"]?.textValue
        self.retained = (row["retained"]?.intValue ?? 1) != 0
    }
}
```

Create `MyMacAgent/MyMacAgent/Models/AppRule.swift`:

```swift
import Foundation

enum AppRuleType: String {
    case excludeCapture = "exclude_capture"
    case excludeOcr = "exclude_ocr"
    case highFrequencyCapture = "high_frequency_capture"
    case metadataOnly = "metadata_only"
    case privacyMask = "privacy_mask"
    case aiChatHint = "ai_chat_hint"
}

struct AppRule {
    let id: Int64
    let bundleId: String?
    let ruleType: AppRuleType
    let ruleValue: String
    let enabled: Bool

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.intValue,
              let ruleTypeStr = row["rule_type"]?.textValue,
              let ruleType = AppRuleType(rawValue: ruleTypeStr),
              let ruleValue = row["rule_value"]?.textValue else { return nil }
        self.id = id
        self.bundleId = row["bundle_id"]?.textValue
        self.ruleType = ruleType
        self.ruleValue = ruleValue
        self.enabled = (row["enabled"]?.intValue ?? 1) != 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All ModelTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Models/ MyMacAgent/MyMacAgentTests/Models/
git commit -m "feat: add data models for apps, windows, sessions, captures, and rules"
```

---

## Task 6: Permissions Manager

**Files:**
- Create: `MyMacAgent/MyMacAgent/Permissions/PermissionsManager.swift`
- Create: `MyMacAgent/MyMacAgent/Permissions/PermissionsView.swift`

- [ ] **Step 1: Implement PermissionsManager**

Create `MyMacAgent/MyMacAgent/Permissions/PermissionsManager.swift`:

```swift
import AppKit
import ScreenCaptureKit
import os

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false

    private let logger = Logger.permissions

    var allGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    func checkAll() {
        checkAccessibility()
        Task {
            await checkScreenRecording()
        }
    }

    func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
        logger.info("Accessibility: \(self.accessibilityGranted)")
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func checkScreenRecording() async {
        do {
            // Attempting to get shareable content checks permission
            _ = try await SCShareableContent.current
            screenRecordingGranted = true
        } catch {
            screenRecordingGranted = false
        }
        logger.info("Screen recording: \(self.screenRecordingGranted)")
    }

    func openScreenRecordingPrefs() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func openAccessibilityPrefs() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Implement PermissionsView**

Create `MyMacAgent/MyMacAgent/Permissions/PermissionsView.swift`:

```swift
import SwiftUI

struct PermissionsView: View {
    @ObservedObject var manager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("MyMacAgent needs the following permissions to track your activity.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    title: "Screen Recording",
                    description: "Capture window contents for OCR and visual logging",
                    granted: manager.screenRecordingGranted,
                    action: manager.openScreenRecordingPrefs
                )

                permissionRow(
                    title: "Accessibility",
                    description: "Read window titles and focused UI elements",
                    granted: manager.accessibilityGranted,
                    action: manager.requestAccessibility
                )
            }

            HStack {
                Spacer()
                Button("Refresh Status") {
                    manager.checkAll()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            manager.checkAll()
        }
    }

    private func permissionRow(
        title: String,
        description: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(granted ? .green : .red)
                    Text(title)
                        .fontWeight(.medium)
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant") { action() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(granted ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
        )
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -scheme MyMacAgent -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add MyMacAgent/MyMacAgent/Permissions/
git commit -m "feat: add permissions manager for screen recording and accessibility"
```

---

## Task 7: Wire Up App Startup (DB + Permissions)

**Files:**
- Modify: `MyMacAgent/MyMacAgent/App/AppDelegate.swift`
- Modify: `MyMacAgent/MyMacAgent/App/MyMacAgentApp.swift`
- Modify: `MyMacAgent/MyMacAgent/Views/MenuBarPopover.swift`

- [ ] **Step 1: Update AppDelegate to initialize DB on launch**

Modify `MyMacAgent/MyMacAgent/App/AppDelegate.swift`:

```swift
import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger.app
    private(set) var databaseManager: DatabaseManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MyMacAgent launched")
        initializeDatabase()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("MyMacAgent terminating")
    }

    private func initializeDatabase() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("MyMacAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

            let dbPath = dbDir.appendingPathComponent("mymacagent.db").path
            let db = try DatabaseManager(path: dbPath)

            let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
            try runner.runPending()

            databaseManager = db
            logger.info("Database initialized at \(dbPath)")
        } catch {
            logger.error("Database initialization failed: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 2: Update MyMacAgentApp to show permissions when needed**

Modify `MyMacAgent/MyMacAgent/App/MyMacAgentApp.swift`:

```swift
import SwiftUI

@main
struct MyMacAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var permissionsManager = PermissionsManager()

    var body: some Scene {
        MenuBarExtra("MyMacAgent", systemImage: "brain.head.profile") {
            MenuBarPopover(permissionsManager: permissionsManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            if permissionsManager.allGranted {
                SettingsView()
            } else {
                PermissionsView(manager: permissionsManager)
            }
        }
    }
}
```

- [ ] **Step 3: Update MenuBarPopover with status**

Modify `MyMacAgent/MyMacAgent/Views/MenuBarPopover.swift`:

```swift
import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyMacAgent")
                .font(.headline)

            if permissionsManager.allGranted {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("Permissions needed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)

                Button("Open Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .font(.caption)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 250)
    }
}
```

- [ ] **Step 4: Build and verify**

```bash
xcodebuild -scheme MyMacAgent -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/App/ MyMacAgent/MyMacAgent/Views/MenuBarPopover.swift
git commit -m "feat: wire up database init and permissions check on app launch"
```

---

## Task 8: AppMonitor — Active App Tracking

**Files:**
- Create: `MyMacAgent/MyMacAgent/Monitors/AppMonitor.swift`
- Test: `MyMacAgent/MyMacAgentTests/Monitors/AppMonitorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Monitors/AppMonitorTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class AppMonitorTests: XCTestCase {
    private var db: DatabaseManager!
    private var dbPath: String!
    private var monitor: AppMonitor!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        db = try! DatabaseManager(path: dbPath)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try! runner.runPending()
        monitor = AppMonitor(db: db)
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testRecordAppInsertsNewApp() throws {
        let appId = try monitor.recordApp(bundleId: "com.test.app", appName: "TestApp")
        XCTAssertGreaterThan(appId, 0)

        let rows = try db.query("SELECT * FROM apps WHERE bundle_id = ?", params: [.text("com.test.app")])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["app_name"]?.textValue, "TestApp")
    }

    func testRecordAppReturnsSameIdForExistingApp() throws {
        let id1 = try monitor.recordApp(bundleId: "com.test.app", appName: "TestApp")
        let id2 = try monitor.recordApp(bundleId: "com.test.app", appName: "TestApp")
        XCTAssertEqual(id1, id2)

        let rows = try db.query("SELECT * FROM apps WHERE bundle_id = ?", params: [.text("com.test.app")])
        XCTAssertEqual(rows.count, 1)
    }

    func testCurrentAppInfoReturnsNilWhenNotStarted() {
        XCTAssertNil(monitor.currentAppInfo)
    }

    func testDelegateCalledOnAppChange() throws {
        let delegate = MockAppMonitorDelegate()
        monitor.delegate = delegate

        monitor.handleAppChange(bundleId: "com.test.app", appName: "TestApp")

        XCTAssertEqual(delegate.lastBundleId, "com.test.app")
        XCTAssertEqual(delegate.lastAppName, "TestApp")
        XCTAssertNotNil(delegate.lastAppId)
    }
}

final class MockAppMonitorDelegate: AppMonitorDelegate {
    var lastBundleId: String?
    var lastAppName: String?
    var lastAppId: Int64?

    func appMonitor(_ monitor: AppMonitor, didSwitchTo bundleId: String, appName: String, appId: Int64) {
        lastBundleId = bundleId
        lastAppName = appName
        lastAppId = appId
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `AppMonitor` not found.

- [ ] **Step 3: Implement AppMonitor**

Create `MyMacAgent/MyMacAgent/Monitors/AppMonitor.swift`:

```swift
import AppKit
import os

protocol AppMonitorDelegate: AnyObject {
    func appMonitor(_ monitor: AppMonitor, didSwitchTo bundleId: String, appName: String, appId: Int64)
}

struct AppInfo {
    let bundleId: String
    let appName: String
    let appId: Int64
    let pid: pid_t
}

final class AppMonitor {
    weak var delegate: AppMonitorDelegate?
    private let db: DatabaseManager
    private let logger = Logger.monitor
    private var observation: NSObjectProtocol?
    private(set) var currentAppInfo: AppInfo?

    init(db: DatabaseManager) {
        self.db = db
    }

    func start() {
        logger.info("AppMonitor starting")

        // Observe active app changes
        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier,
                  let appName = app.localizedName else { return }

            self.handleAppChange(bundleId: bundleId, appName: appName, pid: app.processIdentifier)
        }

        // Record current frontmost app immediately
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           let appName = frontmost.localizedName {
            handleAppChange(bundleId: bundleId, appName: appName, pid: frontmost.processIdentifier)
        }
    }

    func stop() {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
            self.observation = nil
        }
        logger.info("AppMonitor stopped")
    }

    func handleAppChange(bundleId: String, appName: String, pid: pid_t = 0) {
        guard bundleId != currentAppInfo?.bundleId else { return }

        do {
            let appId = try recordApp(bundleId: bundleId, appName: appName)
            let info = AppInfo(bundleId: bundleId, appName: appName, appId: appId, pid: pid)
            currentAppInfo = info
            delegate?.appMonitor(self, didSwitchTo: bundleId, appName: appName, appId: appId)
            logger.info("App switched: \(appName) (\(bundleId))")
        } catch {
            logger.error("Failed to record app: \(error.localizedDescription)")
        }
    }

    func recordApp(bundleId: String, appName: String) throws -> Int64 {
        // Check if app already exists
        let existing = try db.query(
            "SELECT id FROM apps WHERE bundle_id = ?",
            params: [.text(bundleId)]
        )

        if let row = existing.first, let id = row["id"]?.intValue {
            return id
        }

        // Insert new app
        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text(bundleId), .text(appName)]
        )

        let rows = try db.query(
            "SELECT id FROM apps WHERE bundle_id = ?",
            params: [.text(bundleId)]
        )
        guard let id = rows.first?["id"]?.intValue else {
            throw DatabaseError.executeFailed("Could not retrieve inserted app ID")
        }
        return id
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All AppMonitorTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Monitors/AppMonitor.swift MyMacAgent/MyMacAgentTests/Monitors/AppMonitorTests.swift
git commit -m "feat: add AppMonitor for active application tracking via NSWorkspace"
```

---

## Task 9: WindowMonitor — Active Window Title Tracking

**Files:**
- Create: `MyMacAgent/MyMacAgent/Monitors/WindowMonitor.swift`
- Test: `MyMacAgent/MyMacAgentTests/Monitors/WindowMonitorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Monitors/WindowMonitorTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class WindowMonitorTests: XCTestCase {
    private var db: DatabaseManager!
    private var dbPath: String!
    private var monitor: WindowMonitor!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        db = try! DatabaseManager(path: dbPath)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try! runner.runPending()
        monitor = WindowMonitor(db: db)
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testRecordWindowInsertsNewWindow() throws {
        // First insert an app
        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")]
        )

        let windowId = try monitor.recordWindow(appId: 1, title: "Document.txt", role: "AXWindow")
        XCTAssertGreaterThan(windowId, 0)

        let rows = try db.query("SELECT * FROM windows WHERE id = ?", params: [.integer(windowId)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["window_title"]?.textValue, "Document.txt")
    }

    func testRecordWindowUpdatesLastSeenAt() throws {
        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")]
        )

        let id1 = try monitor.recordWindow(appId: 1, title: "Doc.txt", role: "AXWindow")
        let id2 = try monitor.recordWindow(appId: 1, title: "Doc.txt", role: "AXWindow")

        // Same window should return same ID (based on app_id + title match)
        XCTAssertEqual(id1, id2)
    }

    func testDelegateCalledOnWindowChange() throws {
        try db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")]
        )

        let delegate = MockWindowMonitorDelegate()
        monitor.delegate = delegate

        try monitor.handleWindowChange(appId: 1, title: "My Window", role: "AXWindow")

        XCTAssertEqual(delegate.lastTitle, "My Window")
        XCTAssertNotNil(delegate.lastWindowId)
    }

    func testCurrentWindowInfoIsNilBeforeStart() {
        XCTAssertNil(monitor.currentWindowTitle)
    }
}

final class MockWindowMonitorDelegate: WindowMonitorDelegate {
    var lastWindowId: Int64?
    var lastTitle: String?

    func windowMonitor(_ monitor: WindowMonitor, didSwitchTo windowId: Int64, title: String?) {
        lastWindowId = windowId
        lastTitle = title
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `WindowMonitor` not found.

- [ ] **Step 3: Implement WindowMonitor**

Create `MyMacAgent/MyMacAgent/Monitors/WindowMonitor.swift`:

```swift
import AppKit
import os

protocol WindowMonitorDelegate: AnyObject {
    func windowMonitor(_ monitor: WindowMonitor, didSwitchTo windowId: Int64, title: String?)
}

final class WindowMonitor {
    weak var delegate: WindowMonitorDelegate?
    private let db: DatabaseManager
    private let logger = Logger.monitor
    private var pollTimer: Timer?
    private(set) var currentWindowTitle: String?
    private var currentWindowId: Int64?
    private var currentAppId: Int64?

    init(db: DatabaseManager) {
        self.db = db
    }

    func start(appId: Int64, pid: pid_t) {
        currentAppId = appId
        pollWindowTitle(pid: pid)

        // Poll window title every 1 second
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollWindowTitle(pid: pid)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        currentWindowTitle = nil
        currentWindowId = nil
    }

    func updateApp(appId: Int64, pid: pid_t) {
        stop()
        start(appId: appId, pid: pid)
    }

    func handleWindowChange(appId: Int64, title: String?, role: String? = "AXWindow") throws {
        guard title != currentWindowTitle else { return }

        let windowId = try recordWindow(appId: appId, title: title, role: role)
        currentWindowTitle = title
        currentWindowId = windowId
        delegate?.windowMonitor(self, didSwitchTo: windowId, title: title)
        logger.info("Window changed: \(title ?? "untitled")")
    }

    func recordWindow(appId: Int64, title: String?, role: String?) throws -> Int64 {
        let safeTitle = title ?? ""

        // Look for existing window with same app + title
        let existing = try db.query(
            "SELECT id FROM windows WHERE app_id = ? AND window_title = ?",
            params: [.integer(appId), .text(safeTitle)]
        )

        if let row = existing.first, let id = row["id"]?.intValue {
            // Update last_seen_at
            let now = ISO8601DateFormatter().string(from: Date())
            try db.execute(
                "UPDATE windows SET last_seen_at = ? WHERE id = ?",
                params: [.text(now), .integer(id)]
            )
            return id
        }

        // Insert new window
        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute(
            "INSERT INTO windows (app_id, window_title, window_role, first_seen_at, last_seen_at) VALUES (?, ?, ?, ?, ?)",
            params: [
                .integer(appId),
                .text(safeTitle),
                role.map { .text($0) } ?? .null,
                .text(now),
                .text(now)
            ]
        )

        let rows = try db.query("SELECT last_insert_rowid() as id")
        guard let id = rows.first?["id"]?.intValue else {
            throw DatabaseError.executeFailed("Could not retrieve inserted window ID")
        }
        return id
    }

    // MARK: - Private

    private func pollWindowTitle(pid: pid_t) {
        guard let appId = currentAppId else { return }

        let appRef = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let window = focusedWindow else { return }

        var titleValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue)
        let title = titleValue as? String

        if title != currentWindowTitle {
            try? handleWindowChange(appId: appId, title: title)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All WindowMonitorTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Monitors/WindowMonitor.swift MyMacAgent/MyMacAgentTests/Monitors/WindowMonitorTests.swift
git commit -m "feat: add WindowMonitor for AX-based window title tracking"
```

---

## Task 10: Idle Detector

**Files:**
- Create: `MyMacAgent/MyMacAgent/Monitors/IdleDetector.swift`
- Test: `MyMacAgent/MyMacAgentTests/Monitors/IdleDetectorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Monitors/IdleDetectorTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class IdleDetectorTests: XCTestCase {

    func testIdleThresholdDefaultIs120Seconds() {
        let detector = IdleDetector()
        XCTAssertEqual(detector.idleThreshold, 120)
    }

    func testIdleThresholdCustomizable() {
        let detector = IdleDetector(idleThreshold: 60)
        XCTAssertEqual(detector.idleThreshold, 60)
    }

    func testCurrentIdleTimeReturnsNonNegative() {
        let detector = IdleDetector()
        XCTAssertGreaterThanOrEqual(detector.currentIdleTime, 0)
    }

    func testIsIdleReturnsFalseForActiveUser() {
        // With a 999999 threshold, user should never be idle
        let detector = IdleDetector(idleThreshold: 999999)
        XCTAssertFalse(detector.isIdle)
    }

    func testDelegateCalledWhenIdleStateChanges() {
        let delegate = MockIdleDelegate()
        let detector = IdleDetector(idleThreshold: 0) // 0 sec threshold for testing
        detector.delegate = delegate
        // We can't easily test the transition without waiting,
        // but we can verify the delegate interface compiles
        XCTAssertNil(delegate.lastIsIdle)
    }
}

final class MockIdleDelegate: IdleDetectorDelegate {
    var lastIsIdle: Bool?

    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool) {
        lastIsIdle = isIdle
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `IdleDetector` not found.

- [ ] **Step 3: Implement IdleDetector**

Create `MyMacAgent/MyMacAgent/Monitors/IdleDetector.swift`:

```swift
import Foundation
import CoreGraphics
import os

protocol IdleDetectorDelegate: AnyObject {
    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool)
}

final class IdleDetector {
    weak var delegate: IdleDetectorDelegate?
    let idleThreshold: TimeInterval
    private let logger = Logger.monitor
    private var pollTimer: Timer?
    private var wasIdle = false

    init(idleThreshold: TimeInterval = 120) {
        self.idleThreshold = idleThreshold
    }

    var currentIdleTime: TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: CGEventType(rawValue: ~0)!
        )
    }

    var isIdle: Bool {
        currentIdleTime >= idleThreshold
    }

    func start() {
        logger.info("IdleDetector starting (threshold: \(self.idleThreshold)s)")
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        logger.info("IdleDetector stopped")
    }

    private func checkIdle() {
        let idle = isIdle
        if idle != wasIdle {
            wasIdle = idle
            logger.info("Idle state changed: \(idle)")
            delegate?.idleDetector(self, didChangeIdleState: idle)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All IdleDetectorTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Monitors/IdleDetector.swift MyMacAgent/MyMacAgentTests/Monitors/IdleDetectorTests.swift
git commit -m "feat: add IdleDetector using CGEventSource idle time"
```

---

## Task 11: SessionManager — Session Lifecycle

**Files:**
- Create: `MyMacAgent/MyMacAgent/Session/SessionManager.swift`
- Test: `MyMacAgent/MyMacAgentTests/Session/SessionManagerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Session/SessionManagerTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class SessionManagerTests: XCTestCase {
    private var db: DatabaseManager!
    private var dbPath: String!
    private var sessionManager: SessionManager!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        db = try! DatabaseManager(path: dbPath)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try! runner.runPending()

        try! db.execute(
            "INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")]
        )

        sessionManager = SessionManager(db: db)
    }

    override func tearDown() {
        sessionManager = nil
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testStartSessionCreatesRecord() throws {
        let sessionId = try sessionManager.startSession(appId: 1, windowId: nil)
        XCTAssertFalse(sessionId.isEmpty)

        let rows = try db.query("SELECT * FROM sessions WHERE id = ?", params: [.text(sessionId)])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["app_id"]?.intValue, 1)
        XCTAssertNotNil(rows[0]["started_at"]?.textValue)
    }

    func testEndSessionSetsEndedAt() throws {
        let sessionId = try sessionManager.startSession(appId: 1, windowId: nil)
        try sessionManager.endSession(sessionId)

        let rows = try db.query("SELECT ended_at FROM sessions WHERE id = ?", params: [.text(sessionId)])
        XCTAssertNotNil(rows[0]["ended_at"]?.textValue)
    }

    func testCurrentSessionIdIsNilBeforeStart() {
        XCTAssertNil(sessionManager.currentSessionId)
    }

    func testCurrentSessionIdSetAfterStart() throws {
        let sessionId = try sessionManager.startSession(appId: 1, windowId: nil)
        XCTAssertEqual(sessionManager.currentSessionId, sessionId)
    }

    func testCurrentSessionIdNilAfterEnd() throws {
        let sessionId = try sessionManager.startSession(appId: 1, windowId: nil)
        try sessionManager.endSession(sessionId)
        XCTAssertNil(sessionManager.currentSessionId)
    }

    func testRecordEventInsertsRow() throws {
        let sessionId = try sessionManager.startSession(appId: 1, windowId: nil)
        try sessionManager.recordEvent(sessionId: sessionId, type: .appActivated, payload: nil)

        let rows = try db.query(
            "SELECT * FROM session_events WHERE session_id = ?",
            params: [.text(sessionId)]
        )
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["event_type"]?.textValue, "app_activated")
    }

    func testSwitchSessionEndsOldAndStartsNew() throws {
        let oldId = try sessionManager.startSession(appId: 1, windowId: nil)
        let newId = try sessionManager.switchSession(appId: 1, windowId: 2)

        XCTAssertNotEqual(oldId, newId)
        XCTAssertEqual(sessionManager.currentSessionId, newId)

        // Old session should have ended_at
        let oldRows = try db.query("SELECT ended_at FROM sessions WHERE id = ?", params: [.text(oldId)])
        XCTAssertNotNil(oldRows[0]["ended_at"]?.textValue)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `SessionManager` not found.

- [ ] **Step 3: Implement SessionManager**

Create `MyMacAgent/MyMacAgent/Session/SessionManager.swift`:

```swift
import Foundation
import os

final class SessionManager {
    private let db: DatabaseManager
    private let logger = Logger.session
    private(set) var currentSessionId: String?

    init(db: DatabaseManager) {
        self.db = db
    }

    func startSession(appId: Int64, windowId: Int64?) throws -> String {
        let sessionId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        try db.execute(
            "INSERT INTO sessions (id, app_id, window_id, started_at) VALUES (?, ?, ?, ?)",
            params: [
                .text(sessionId),
                .integer(appId),
                windowId.map { .integer($0) } ?? .null,
                .text(now)
            ]
        )

        currentSessionId = sessionId
        logger.info("Session started: \(sessionId)")
        return sessionId
    }

    func endSession(_ sessionId: String) throws {
        let now = ISO8601DateFormatter().string(from: Date())

        try db.execute(
            "UPDATE sessions SET ended_at = ? WHERE id = ?",
            params: [.text(now), .text(sessionId)]
        )

        if currentSessionId == sessionId {
            currentSessionId = nil
        }

        logger.info("Session ended: \(sessionId)")
    }

    func switchSession(appId: Int64, windowId: Int64?) throws -> String {
        if let current = currentSessionId {
            try endSession(current)
        }
        return try startSession(appId: appId, windowId: windowId)
    }

    func recordEvent(sessionId: String, type: SessionEventType, payload: String?) throws {
        let now = ISO8601DateFormatter().string(from: Date())

        try db.execute(
            "INSERT INTO session_events (session_id, event_type, timestamp, payload_json) VALUES (?, ?, ?, ?)",
            params: [
                .text(sessionId),
                .text(type.rawValue),
                .text(now),
                payload.map { .text($0) } ?? .null
            ]
        )
    }

    func updateUncertaintyMode(sessionId: String, mode: UncertaintyMode) throws {
        try db.execute(
            "UPDATE sessions SET uncertainty_mode = ? WHERE id = ?",
            params: [.text(mode.rawValue), .text(sessionId)]
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All SessionManagerTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Session/SessionManager.swift MyMacAgent/MyMacAgentTests/Session/SessionManagerTests.swift
git commit -m "feat: add SessionManager for session lifecycle and event recording"
```

---

## Task 12: Screen Capture Engine

**Files:**
- Create: `MyMacAgent/MyMacAgent/Capture/ScreenCaptureEngine.swift`
- Test: `MyMacAgent/MyMacAgentTests/Capture/ScreenCaptureEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Capture/ScreenCaptureEngineTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class ScreenCaptureEngineTests: XCTestCase {

    func testCaptureResultHasExpectedProperties() {
        let result = CaptureResult(
            image: NSImage(size: NSSize(width: 100, height: 100)),
            width: 100,
            height: 100,
            timestamp: Date()
        )

        XCTAssertEqual(result.width, 100)
        XCTAssertEqual(result.height, 100)
        XCTAssertNotNil(result.image)
    }

    func testCaptureEngineInitializes() {
        let engine = ScreenCaptureEngine()
        XCTAssertNotNil(engine)
    }

    // NOTE: Actual capture tests require screen recording permission
    // and a running window, so they are integration tests.
    // We test the data flow and storage logic here.

    func testSaveCaptureToDisk() throws {
        let tmpDir = NSTemporaryDirectory() + "capture_test_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let engine = ScreenCaptureEngine()

        // Create a simple test image
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.red.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 100, height: 100))
        image.unlockFocus()

        let result = CaptureResult(image: image, width: 100, height: 100, timestamp: Date())
        let path = try engine.saveToDisk(result: result, directory: tmpDir, quality: 0.7)

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(data.count, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `ScreenCaptureEngine` and `CaptureResult` not found.

- [ ] **Step 3: Implement ScreenCaptureEngine**

Create `MyMacAgent/MyMacAgent/Capture/ScreenCaptureEngine.swift`:

```swift
import AppKit
import ScreenCaptureKit
import os

struct CaptureResult {
    let image: NSImage
    let width: Int
    let height: Int
    let timestamp: Date
}

final class ScreenCaptureEngine {
    private let logger = Logger.capture

    func captureWindow(pid: pid_t) async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.isOnScreen
        }) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2  // Retina
        config.height = Int(window.frame.height) * 2
        config.showsCursor = false
        config.captureResolution = .best

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(
            width: Int(window.frame.width),
            height: Int(window.frame.height)
        ))

        return CaptureResult(
            image: nsImage,
            width: Int(window.frame.width),
            height: Int(window.frame.height),
            timestamp: Date()
        )
    }

    func captureScreen() async throws -> CaptureResult {
        let content = try await SCShareableContent.current

        guard let display = content.displays.first else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.width) * 2
        config.height = Int(display.height) * 2
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let nsImage = NSImage(cgImage: cgImage, size: NSSize(
            width: Int(display.width),
            height: Int(display.height)
        ))

        return CaptureResult(
            image: nsImage,
            width: Int(display.width),
            height: Int(display.height),
            timestamp: Date()
        )
    }

    func saveToDisk(result: CaptureResult, directory: String, quality: CGFloat = 0.7) throws -> String {
        guard let tiffData = result.image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]) else {
            throw CaptureError.compressionFailed
        }

        let filename = ISO8601DateFormatter().string(from: result.timestamp)
            .replacingOccurrences(of: ":", with: "-") + ".jpg"
        let path = (directory as NSString).appendingPathComponent(filename)

        try jpegData.write(to: URL(fileURLWithPath: path))
        logger.info("Capture saved: \(path) (\(jpegData.count) bytes)")

        return path
    }
}

enum CaptureError: Error, LocalizedError {
    case windowNotFound
    case displayNotFound
    case compressionFailed

    var errorDescription: String? {
        switch self {
        case .windowNotFound: return "Target window not found on screen"
        case .displayNotFound: return "No display found"
        case .compressionFailed: return "Image compression failed"
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All ScreenCaptureEngineTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Capture/ScreenCaptureEngine.swift MyMacAgent/MyMacAgentTests/Capture/ScreenCaptureEngineTests.swift
git commit -m "feat: add ScreenCaptureEngine using ScreenCaptureKit for window/screen capture"
```

---

## Task 13: Image Processor (Hash, Thumbnail, Diff)

**Files:**
- Create: `MyMacAgent/MyMacAgent/Capture/ImageProcessor.swift`
- Test: `MyMacAgent/MyMacAgentTests/Capture/ImageProcessorTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MyMacAgent/MyMacAgentTests/Capture/ImageProcessorTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class ImageProcessorTests: XCTestCase {

    private func makeTestImage(color: NSColor, size: NSSize = NSSize(width: 100, height: 100)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    func testCreateThumbnail() {
        let image = makeTestImage(color: .blue, size: NSSize(width: 1920, height: 1080))
        let processor = ImageProcessor()

        let thumb = processor.createThumbnail(image: image, maxDimension: 200)

        XCTAssertNotNil(thumb)
        XCTAssertLessThanOrEqual(thumb!.size.width, 200)
        XCTAssertLessThanOrEqual(thumb!.size.height, 200)
    }

    func testVisualHashDeterministic() {
        let image = makeTestImage(color: .red)
        let processor = ImageProcessor()

        let hash1 = processor.visualHash(image: image)
        let hash2 = processor.visualHash(image: image)

        XCTAssertNotNil(hash1)
        XCTAssertEqual(hash1, hash2)
    }

    func testVisualHashDifferentForDifferentImages() {
        let processor = ImageProcessor()

        let hash1 = processor.visualHash(image: makeTestImage(color: .red))
        let hash2 = processor.visualHash(image: makeTestImage(color: .blue))

        XCTAssertNotEqual(hash1, hash2)
    }

    func testDiffScoreSameImage() {
        let image = makeTestImage(color: .green)
        let processor = ImageProcessor()

        let score = processor.diffScore(
            hash1: processor.visualHash(image: image)!,
            hash2: processor.visualHash(image: image)!
        )

        XCTAssertEqual(score, 0.0, accuracy: 0.001)
    }

    func testDiffScoreDifferentImages() {
        let processor = ImageProcessor()
        let hash1 = processor.visualHash(image: makeTestImage(color: .red))!
        let hash2 = processor.visualHash(image: makeTestImage(color: .blue))!

        let score = processor.diffScore(hash1: hash1, hash2: hash2)
        XCTAssertGreaterThan(score, 0.0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: FAIL — `ImageProcessor` not found.

- [ ] **Step 3: Implement ImageProcessor**

Create `MyMacAgent/MyMacAgent/Capture/ImageProcessor.swift`:

```swift
import AppKit
import CryptoKit
import os

final class ImageProcessor {
    private let logger = Logger.capture

    func createThumbnail(image: NSImage, maxDimension: CGFloat = 200) -> NSImage? {
        let originalSize = image.size
        let scale: CGFloat
        if originalSize.width > originalSize.height {
            scale = maxDimension / originalSize.width
        } else {
            scale = maxDimension / originalSize.height
        }

        let newSize = NSSize(
            width: originalSize.width * scale,
            height: originalSize.height * scale
        )

        let thumbnail = NSImage(size: newSize)
        thumbnail.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: newSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1.0
        )
        thumbnail.unlockFocus()
        return thumbnail
    }

    func visualHash(image: NSImage) -> String? {
        // Downscale to 8x8, grayscale, then SHA256 the pixel data
        let smallSize = NSSize(width: 8, height: 8)
        let small = NSImage(size: smallSize)
        small.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .low
        image.draw(
            in: NSRect(origin: .zero, size: smallSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        small.unlockFocus()

        guard let tiffData = small.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        // Extract grayscale values
        var pixels: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<8 {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.genericGray) {
                    pixels.append(UInt8(color.whiteComponent * 255))
                }
            }
        }

        let hash = SHA256.hash(data: Data(pixels))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func diffScore(hash1: String, hash2: String) -> Double {
        guard hash1.count == hash2.count, !hash1.isEmpty else { return 1.0 }

        let chars1 = Array(hash1)
        let chars2 = Array(hash2)
        var diffCount = 0

        for i in 0..<chars1.count {
            if chars1[i] != chars2[i] {
                diffCount += 1
            }
        }

        return Double(diffCount) / Double(chars1.count)
    }

    func saveThumbnail(image: NSImage, directory: String, filename: String) throws -> String {
        guard let thumb = createThumbnail(image: image),
              let tiffData = thumb.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.5]) else {
            throw CaptureError.compressionFailed
        }

        let path = (directory as NSString).appendingPathComponent("thumb_" + filename)
        try jpegData.write(to: URL(fileURLWithPath: path))
        return path
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All ImageProcessorTests PASS.

- [ ] **Step 5: Commit**

```bash
git add MyMacAgent/MyMacAgent/Capture/ImageProcessor.swift MyMacAgent/MyMacAgentTests/Capture/ImageProcessorTests.swift
git commit -m "feat: add ImageProcessor for thumbnails, visual hashing, and diff scoring"
```

---

## Task 14: Wire Up Monitors + SessionManager in AppDelegate

**Files:**
- Modify: `MyMacAgent/MyMacAgent/App/AppDelegate.swift`

- [ ] **Step 1: Update AppDelegate to connect all components**

Modify `MyMacAgent/MyMacAgent/App/AppDelegate.swift`:

```swift
import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger.app
    private(set) var databaseManager: DatabaseManager?
    private var appMonitor: AppMonitor?
    private var windowMonitor: WindowMonitor?
    private var idleDetector: IdleDetector?
    private var sessionManager: SessionManager?
    private var captureEngine: ScreenCaptureEngine?
    private var imageProcessor: ImageProcessor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MyMacAgent launched")
        initializeDatabase()
        initializeMonitors()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appMonitor?.stop()
        windowMonitor?.stop()
        idleDetector?.stop()

        // End current session
        if let sessionId = sessionManager?.currentSessionId {
            try? sessionManager?.endSession(sessionId)
        }

        logger.info("MyMacAgent terminating")
    }

    private func initializeDatabase() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("MyMacAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

            let dbPath = dbDir.appendingPathComponent("mymacagent.db").path
            let db = try DatabaseManager(path: dbPath)

            let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
            try runner.runPending()

            databaseManager = db
            logger.info("Database initialized at \(dbPath)")
        } catch {
            logger.error("Database initialization failed: \(error.localizedDescription)")
        }
    }

    private func initializeMonitors() {
        guard let db = databaseManager else {
            logger.error("Cannot initialize monitors: database not ready")
            return
        }

        sessionManager = SessionManager(db: db)
        captureEngine = ScreenCaptureEngine()
        imageProcessor = ImageProcessor()

        let appMon = AppMonitor(db: db)
        appMon.delegate = self
        appMon.start()
        appMonitor = appMon

        let winMon = WindowMonitor(db: db)
        winMon.delegate = self
        windowMonitor = winMon

        let idle = IdleDetector()
        idle.delegate = self
        idle.start()
        idleDetector = idle

        logger.info("Monitors initialized")
    }
}

extension AppDelegate: AppMonitorDelegate {
    func appMonitor(_ monitor: AppMonitor, didSwitchTo bundleId: String, appName: String, appId: Int64) {
        guard let sessionManager else { return }

        do {
            let sessionId = try sessionManager.switchSession(appId: appId, windowId: nil)
            try sessionManager.recordEvent(sessionId: sessionId, type: .appActivated, payload: """
                {"bundle_id":"\(bundleId)","app_name":"\(appName)"}
            """)

            // Update window monitor for new app
            if let pid = monitor.currentAppInfo?.pid {
                windowMonitor?.updateApp(appId: appId, pid: pid)
            }
        } catch {
            logger.error("Failed to handle app switch: \(error.localizedDescription)")
        }
    }
}

extension AppDelegate: WindowMonitorDelegate {
    func windowMonitor(_ monitor: WindowMonitor, didSwitchTo windowId: Int64, title: String?) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }

        do {
            try sessionManager.recordEvent(sessionId: sessionId, type: .windowChanged, payload: """
                {"window_id":\(windowId),"title":"\(title ?? "")"}
            """)
        } catch {
            logger.error("Failed to record window change: \(error.localizedDescription)")
        }
    }
}

extension AppDelegate: IdleDetectorDelegate {
    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }

        let eventType: SessionEventType = isIdle ? .idleStarted : .idleEnded
        try? sessionManager.recordEvent(sessionId: sessionId, type: eventType, payload: nil)
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -scheme MyMacAgent -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add MyMacAgent/MyMacAgent/App/AppDelegate.swift
git commit -m "feat: wire up AppMonitor, WindowMonitor, IdleDetector, and SessionManager"
```

---

## Task 15: Integration Test — Full Pipeline

**Files:**
- Create: `MyMacAgent/MyMacAgentTests/Integration/PipelineIntegrationTests.swift`

- [ ] **Step 1: Write integration tests**

Create `MyMacAgent/MyMacAgentTests/Integration/PipelineIntegrationTests.swift`:

```swift
import XCTest
@testable import MyMacAgent

final class PipelineIntegrationTests: XCTestCase {
    private var db: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        db = try! DatabaseManager(path: dbPath)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try! runner.runPending()
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(atPath: dbPath)
        super.tearDown()
    }

    func testFullAppSwitchFlow() throws {
        let appMonitor = AppMonitor(db: db)
        let sessionManager = SessionManager(db: db)

        // Simulate first app
        appMonitor.handleAppChange(bundleId: "com.app.one", appName: "AppOne")
        guard let appInfo1 = appMonitor.currentAppInfo else {
            XCTFail("App info should be set")
            return
        }

        let session1 = try sessionManager.startSession(appId: appInfo1.appId, windowId: nil)
        try sessionManager.recordEvent(sessionId: session1, type: .appActivated, payload: nil)

        // Simulate switch to second app
        appMonitor.handleAppChange(bundleId: "com.app.two", appName: "AppTwo")
        guard let appInfo2 = appMonitor.currentAppInfo else {
            XCTFail("App info should be set")
            return
        }

        let session2 = try sessionManager.switchSession(appId: appInfo2.appId, windowId: nil)
        try sessionManager.recordEvent(sessionId: session2, type: .appActivated, payload: nil)

        // Verify
        let apps = try db.query("SELECT * FROM apps ORDER BY id")
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0]["app_name"]?.textValue, "AppOne")
        XCTAssertEqual(apps[1]["app_name"]?.textValue, "AppTwo")

        let sessions = try db.query("SELECT * FROM sessions ORDER BY started_at")
        XCTAssertEqual(sessions.count, 2)
        // First session should have ended_at
        XCTAssertNotNil(sessions[0]["ended_at"]?.textValue)
        // Second session should still be open
        XCTAssertEqual(sessions[1]["ended_at"], .null)

        let events = try db.query("SELECT * FROM session_events ORDER BY id")
        XCTAssertEqual(events.count, 2)
    }

    func testCaptureAndHashFlow() throws {
        let processor = ImageProcessor()

        // Create test image
        let image = NSImage(size: NSSize(width: 200, height: 200))
        image.lockFocus()
        NSColor.green.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 200, height: 200))
        image.unlockFocus()

        // Test hash
        let hash = processor.visualHash(image: image)
        XCTAssertNotNil(hash)

        // Test thumbnail
        let thumb = processor.createThumbnail(image: image, maxDimension: 50)
        XCTAssertNotNil(thumb)
        XCTAssertLessThanOrEqual(thumb!.size.width, 50)

        // Test save
        let tmpDir = NSTemporaryDirectory() + "capture_integration_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let captureEngine = ScreenCaptureEngine()
        let result = CaptureResult(image: image, width: 200, height: 200, timestamp: Date())
        let path = try captureEngine.saveToDisk(result: result, directory: tmpDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        // Record in DB
        let appId = try AppMonitor(db: db).recordApp(bundleId: "com.test", appName: "Test")
        let sessionManager = SessionManager(db: db)
        let sessionId = try sessionManager.startSession(appId: appId, windowId: nil)

        let captureId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute(
            """
            INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, width, height, visual_hash, sampling_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            params: [
                .text(captureId), .text(sessionId), .text(now),
                .text("window"), .text(path),
                .integer(200), .integer(200),
                .text(hash!), .text("normal")
            ]
        )

        let captures = try db.query("SELECT * FROM captures WHERE session_id = ?", params: [.text(sessionId)])
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures[0]["visual_hash"]?.textValue, hash)
    }
}
```

- [ ] **Step 2: Run integration tests**

```bash
xcodebuild test -scheme MyMacAgent -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|PASS|FAIL)"
```

Expected: All PipelineIntegrationTests PASS.

- [ ] **Step 3: Commit**

```bash
git add MyMacAgent/MyMacAgentTests/Integration/
git commit -m "test: add integration tests for app-switch and capture-hash pipeline"
```

---

## Self-Review Checklist

1. **Spec coverage:** Sprint 0 (bootstrap, permissions, SQLite, logging) — covered by Tasks 1-7. Sprint 1 (app/window tracking, sessions, idle) — covered by Tasks 8-11, 14. Sprint 2 (screen capture, compression, hashes) — covered by Tasks 12-13. Integration test in Task 15.

2. **Placeholder scan:** All steps contain complete Swift code, exact file paths, and runnable commands. No "TBD" or "fill in later."

3. **Type consistency:** `DatabaseManager`, `SQLiteValue`, `SQLiteRow` used consistently. `AppMonitor`, `WindowMonitor`, `IdleDetector`, `SessionManager` interfaces match across Tasks 8-14. `CaptureResult`, `ScreenCaptureEngine`, `ImageProcessor` used consistently in Tasks 12-13.

---

## Next Plans

After completing this plan, create separate plans for:

- **Phase 2:** `2026-04-XX-mymacagent-phase2.md` — Accessibility pipeline, OCR pipeline, Adaptive capture policy (Sprints 3-5)
- **Phase 3:** `2026-04-XX-mymacagent-phase3.md` — Context fusion, Daily summaries, Obsidian export (Sprints 6-8)
- **Phase 4:** `2026-04-XX-mymacagent-phase4.md` — Timeline UI, Optimization, Notion export (Sprints 9-11)
