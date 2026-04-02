# MyMacAgent Phase 4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Timeline UI for reviewing daily activity, a retention system to prevent disk bloat, enhanced settings for configuration, and search across captured context.

**Architecture:** TimelineDataProvider queries sessions/contexts grouped by date for the UI layer. SearchEngine provides full-text search across context_snapshots. RetentionWorker periodically cleans old captures, thinning high-frequency frames and deleting stale OCR blobs. SwiftUI views (TimelineView, SessionDetailView, DailySummaryView) present the data. SettingsView allows configuring API key, vault path, and retention policy.

**Tech Stack:** Swift 6.2, SwiftUI, existing DatabaseManager, existing models

---

## Existing Code Reference

| Type | File | Key Methods |
|------|------|-------------|
| `DatabaseManager` | `Database/DatabaseManager.swift` | `execute(_:params:)`, `query(_:params:)` |
| `SessionManager` | `Session/SessionManager.swift` | `currentSessionId`, `recordEvent(...)` |
| `DailySummarizer` | `Summary/DailySummarizer.swift` | `summarize(for:using:)`, `collectSessionData(for:)` |
| `ObsidianExporter` | `Export/ObsidianExporter.swift` | `exportDailyNote(summary:)`, `formatDuration(minutes:)` |
| `LLMClient` | `Summary/LLMClient.swift` | `complete(systemPrompt:userPrompt:)`, `defaultClient(apiKey:)` |
| `AppDelegate` | `App/AppDelegate.swift` | `@MainActor`, has all Phase 1-3 components wired |

**Build/test:** `make build` / `make test` — Swift 6.2, strict concurrency, Swift Testing

---

## File Structure

```
Sources/MyMacAgent/
    Data/
        TimelineDataProvider.swift      -- Query sessions/apps/contexts grouped by date
        SearchEngine.swift              -- Full-text search across context_snapshots
    Workers/
        RetentionWorker.swift           -- Cleanup old captures, OCR, thin frames
    Views/
        TimelineView.swift              -- Main timeline UI
        SessionDetailView.swift         -- Session drill-down
        DailySummaryView.swift          -- View/regenerate daily summary
    Settings/
        SettingsView.swift              -- Modify existing: add API key, vault path, retention
        AppSettings.swift               -- UserDefaults-backed settings model

Tests/MyMacAgentTests/
    Data/
        TimelineDataProviderTests.swift
        SearchEngineTests.swift
    Workers/
        RetentionWorkerTests.swift
    Integration/
        Phase4IntegrationTests.swift
```

---

## Task 1: AppSettings Model

**Files:**
- Create: `Sources/MyMacAgent/Settings/AppSettings.swift`
- Create: `Tests/MyMacAgentTests/Settings/AppSettingsTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Settings/AppSettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct AppSettingsTests {
    @Test("Default values")
    func defaults() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "test_\(UUID().uuidString)")!)
        #expect(settings.obsidianVaultPath.contains("MyMacAgentVault"))
        #expect(settings.openRouterApiKey.isEmpty)
        #expect(settings.llmModel == "anthropic/claude-3-haiku")
        #expect(settings.retentionDays == 30)
        #expect(settings.maxCapturesPerSession == 500)
    }

    @Test("Set and get values")
    func setAndGet() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults)
        settings.obsidianVaultPath = "/Users/test/vault"
        settings.openRouterApiKey = "sk-test-123"
        settings.retentionDays = 14

        let settings2 = AppSettings(defaults: defaults)
        #expect(settings2.obsidianVaultPath == "/Users/test/vault")
        #expect(settings2.openRouterApiKey == "sk-test-123")
        #expect(settings2.retentionDays == 14)
    }

    @Test("hasApiKey returns true when key is set")
    func hasApiKey() {
        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults)
        #expect(!settings.hasApiKey)
        settings.openRouterApiKey = "sk-test"
        #expect(settings.hasApiKey)
    }
}
```

- [ ] **Step 2: Implement AppSettings**

Create `Sources/MyMacAgent/Settings/AppSettings.swift`:

```swift
import Foundation

struct AppSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var obsidianVaultPath: String {
        get { defaults.string(forKey: "obsidianVaultPath")
              ?? NSHomeDirectory() + "/Documents/MyMacAgentVault" }
        set { defaults.set(newValue, forKey: "obsidianVaultPath") }
    }

    var openRouterApiKey: String {
        get { defaults.string(forKey: "openRouterApiKey") ?? "" }
        set { defaults.set(newValue, forKey: "openRouterApiKey") }
    }

    var llmModel: String {
        get { defaults.string(forKey: "llmModel") ?? "anthropic/claude-3-haiku" }
        set { defaults.set(newValue, forKey: "llmModel") }
    }

    var retentionDays: Int {
        get {
            let val = defaults.integer(forKey: "retentionDays")
            return val > 0 ? val : 30
        }
        set { defaults.set(newValue, forKey: "retentionDays") }
    }

    var maxCapturesPerSession: Int {
        get {
            let val = defaults.integer(forKey: "maxCapturesPerSession")
            return val > 0 ? val : 500
        }
        set { defaults.set(newValue, forKey: "maxCapturesPerSession") }
    }

    var hasApiKey: Bool { !openRouterApiKey.isEmpty }
}
```

- [ ] **Step 3: Run tests, commit**

```bash
make test
git add Sources/MyMacAgent/Settings/AppSettings.swift Tests/MyMacAgentTests/Settings/AppSettingsTests.swift
git commit -m "feat: add AppSettings model with UserDefaults-backed configuration"
```

---

## Task 2: TimelineDataProvider

**Files:**
- Create: `Sources/MyMacAgent/Data/TimelineDataProvider.swift`
- Create: `Tests/MyMacAgentTests/Data/TimelineDataProviderTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Data/TimelineDataProviderTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct TimelineDataProviderTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    private func seedData(db: DatabaseManager) throws {
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:00:00Z"), .text("2026-04-02T10:30:00Z"),
                      .integer(5400000), .text("normal")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s2"), .integer(2),
                      .text("2026-04-02T10:30:00Z"), .text("2026-04-02T11:00:00Z"),
                      .integer(1800000), .text("degraded")])
    }

    @Test("sessionsForDate returns ordered sessions")
    func sessionsForDate() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedData(db: db)

        let provider = TimelineDataProvider(db: db)
        let sessions = try provider.sessionsForDate("2026-04-02")

        #expect(sessions.count == 2)
        #expect(sessions[0].appName == "Cursor")
        #expect(sessions[0].durationMinutes == 90)
        #expect(sessions[1].appName == "Safari")
    }

    @Test("appSummaryForDate returns aggregated app usage")
    func appSummaryForDate() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedData(db: db)

        let provider = TimelineDataProvider(db: db)
        let apps = try provider.appSummaryForDate("2026-04-02")

        #expect(apps.count == 2)
        // Cursor should be first (longer duration)
        #expect(apps[0].appName == "Cursor")
        #expect(apps[0].totalMinutes == 90)
    }

    @Test("availableDates returns unique dates")
    func availableDates() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedData(db: db)

        let provider = TimelineDataProvider(db: db)
        let dates = try provider.availableDates()

        #expect(dates.contains("2026-04-02"))
    }

    @Test("contextSnapshotsForSession returns ordered snapshots")
    func contextSnapshotsForSession() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedData(db: db)

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T09:10:00Z"),
                      .text("Cursor"), .text("main.swift"), .text("ax+ocr"),
                      .text("Swift code here"), .real(0.9), .real(0.1)])

        let provider = TimelineDataProvider(db: db)
        let contexts = try provider.contextSnapshotsForSession("s1")

        #expect(contexts.count == 1)
        #expect(contexts[0].mergedText == "Swift code here")
    }
}
```

- [ ] **Step 2: Implement TimelineDataProvider**

Create `Sources/MyMacAgent/Data/TimelineDataProvider.swift`:

```swift
import Foundation
import os

struct TimelineSession {
    let sessionId: String
    let appName: String
    let bundleId: String
    let startedAt: String
    let endedAt: String?
    let durationMinutes: Int
    let uncertaintyMode: String
}

struct AppUsageSummary {
    let appName: String
    let bundleId: String
    let totalMinutes: Int
    let sessionCount: Int
}

final class TimelineDataProvider {
    private let db: DatabaseManager
    private let logger = Logger.app

    init(db: DatabaseManager) {
        self.db = db
    }

    func sessionsForDate(_ date: String) throws -> [TimelineSession] {
        let rows = try db.query("""
            SELECT s.id, a.app_name, a.bundle_id, s.started_at, s.ended_at,
                   s.active_duration_ms, s.uncertainty_mode
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at LIKE ?
            ORDER BY s.started_at
        """, params: [.text("\(date)%")])

        return rows.compactMap { row -> TimelineSession? in
            guard let id = row["id"]?.textValue,
                  let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue,
                  let startedAt = row["started_at"]?.textValue else { return nil }
            let durationMs = row["active_duration_ms"]?.intValue ?? 0
            return TimelineSession(
                sessionId: id, appName: appName, bundleId: bundleId,
                startedAt: startedAt, endedAt: row["ended_at"]?.textValue,
                durationMinutes: Int(durationMs / 60000),
                uncertaintyMode: row["uncertainty_mode"]?.textValue ?? "normal"
            )
        }
    }

    func appSummaryForDate(_ date: String) throws -> [AppUsageSummary] {
        let rows = try db.query("""
            SELECT a.app_name, a.bundle_id,
                   SUM(s.active_duration_ms) as total_ms,
                   COUNT(s.id) as session_count
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at LIKE ?
            GROUP BY a.bundle_id
            ORDER BY total_ms DESC
        """, params: [.text("\(date)%")])

        return rows.compactMap { row -> AppUsageSummary? in
            guard let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue else { return nil }
            let totalMs = row["total_ms"]?.intValue ?? 0
            let sessionCount = row["session_count"]?.intValue ?? 0
            return AppUsageSummary(
                appName: appName, bundleId: bundleId,
                totalMinutes: Int(totalMs / 60000),
                sessionCount: Int(sessionCount)
            )
        }
    }

    func availableDates() throws -> [String] {
        let rows = try db.query("""
            SELECT DISTINCT SUBSTR(started_at, 1, 10) as date
            FROM sessions
            ORDER BY date DESC
            LIMIT 90
        """)
        return rows.compactMap { $0["date"]?.textValue }
    }

    func contextSnapshotsForSession(_ sessionId: String) throws -> [ContextSnapshotRecord] {
        let rows = try db.query("""
            SELECT * FROM context_snapshots
            WHERE session_id = ?
            ORDER BY timestamp
        """, params: [.text(sessionId)])
        return rows.compactMap { ContextSnapshotRecord(row: $0) }
    }

    func dailySummary(for date: String) throws -> DailySummaryRecord? {
        let rows = try db.query(
            "SELECT * FROM daily_summaries WHERE date = ?",
            params: [.text(date)]
        )
        return rows.first.flatMap { DailySummaryRecord(row: $0) }
    }
}
```

- [ ] **Step 3: Run tests, commit**

```bash
make test
git add Sources/MyMacAgent/Data/TimelineDataProvider.swift Tests/MyMacAgentTests/Data/TimelineDataProviderTests.swift
git commit -m "feat: add TimelineDataProvider for session/app/context queries"
```

---

## Task 3: SearchEngine

**Files:**
- Create: `Sources/MyMacAgent/Data/SearchEngine.swift`
- Create: `Tests/MyMacAgentTests/Data/SearchEngineTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Data/SearchEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct SearchEngineTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])
        return (db, path)
    }

    @Test("Search finds matching context snapshots")
    func findsMatches() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                window_title, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .text("TestApp"), .text("main.swift"),
                      .text("Swift concurrency patterns with async await"), .real(0.9), .real(0.1)])

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "concurrency")

        #expect(results.count == 1)
        #expect(results[0].mergedText?.contains("concurrency") == true)
    }

    @Test("Search returns empty for no matches")
    func noMatches() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "nonexistent_term_xyz")
        #expect(results.isEmpty)
    }

    @Test("Search matches window title")
    func matchesWindowTitle() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                window_title, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T10:00:00Z"),
                      .text("TestApp"), .text("Kubernetes Dashboard"),
                      .text("some text"), .real(0.9), .real(0.1)])

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "Kubernetes")

        #expect(results.count == 1)
    }

    @Test("Search limits results")
    func limitsResults() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        for i in 0..<20 {
            try db.execute("""
                INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                    merged_text, readable_score, uncertainty_score)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, params: [.text("ctx-\(i)"), .text("s1"),
                          .text("2026-04-02T10:\(String(format: "%02d", i)):00Z"),
                          .text("TestApp"), .text("matching term here"),
                          .real(0.9), .real(0.1)])
        }

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "matching", limit: 5)

        #expect(results.count == 5)
    }
}
```

- [ ] **Step 2: Implement SearchEngine**

Create `Sources/MyMacAgent/Data/SearchEngine.swift`:

```swift
import Foundation
import os

struct SearchResult {
    let snapshot: ContextSnapshotRecord
    let sessionId: String
    let appName: String?
    let windowTitle: String?
    let mergedText: String?
    let timestamp: String
}

final class SearchEngine {
    private let db: DatabaseManager
    private let logger = Logger.app

    init(db: DatabaseManager) {
        self.db = db
    }

    func search(query: String, limit: Int = 50) throws -> [ContextSnapshotRecord] {
        let likePattern = "%\(query)%"
        let rows = try db.query("""
            SELECT * FROM context_snapshots
            WHERE merged_text LIKE ? OR window_title LIKE ? OR app_name LIKE ?
            ORDER BY timestamp DESC
            LIMIT ?
        """, params: [.text(likePattern), .text(likePattern), .text(likePattern),
                      .integer(Int64(limit))])

        return rows.compactMap { ContextSnapshotRecord(row: $0) }
    }

    func searchByDate(query: String, date: String, limit: Int = 50) throws -> [ContextSnapshotRecord] {
        let likePattern = "%\(query)%"
        let rows = try db.query("""
            SELECT * FROM context_snapshots
            WHERE (merged_text LIKE ? OR window_title LIKE ? OR app_name LIKE ?)
              AND timestamp LIKE ?
            ORDER BY timestamp DESC
            LIMIT ?
        """, params: [.text(likePattern), .text(likePattern), .text(likePattern),
                      .text("\(date)%"), .integer(Int64(limit))])

        return rows.compactMap { ContextSnapshotRecord(row: $0) }
    }
}
```

- [ ] **Step 3: Run tests, commit**

```bash
make test
git add Sources/MyMacAgent/Data/SearchEngine.swift Tests/MyMacAgentTests/Data/SearchEngineTests.swift
git commit -m "feat: add SearchEngine for full-text search across context snapshots"
```

---

## Task 4: RetentionWorker

**Files:**
- Create: `Sources/MyMacAgent/Workers/RetentionWorker.swift`
- Create: `Tests/MyMacAgentTests/Workers/RetentionWorkerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Workers/RetentionWorkerTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct RetentionWorkerTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        return (db, path)
    }

    @Test("Deletes captures older than retention days")
    func deletesOldCaptures() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Create old session + capture (60 days ago)
        let oldDate = "2026-02-01T10:00:00Z"
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("old-s"), .integer(1), .text(oldDate)])

        let tmpDir = NSTemporaryDirectory() + "retention_test_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let imagePath = (tmpDir as NSString).appendingPathComponent("old_capture.jpg")
        try Data("fake image".utf8).write(to: URL(fileURLWithPath: imagePath))

        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, image_path, retained)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("old-cap"), .text("old-s"), .text(oldDate),
                      .text("window"), .text(imagePath), .integer(1)])

        // Create recent capture
        let recentDate = ISO8601DateFormatter().string(from: Date())
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("new-s"), .integer(1), .text(recentDate)])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, retained)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("new-cap"), .text("new-s"), .text(recentDate),
                      .text("window"), .integer(1)])

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let deleted = try worker.cleanupOldCaptures()

        #expect(deleted == 1)
        // Old capture should be gone from DB
        let rows = try db.query("SELECT * FROM captures WHERE id = ?",
            params: [.text("old-cap")])
        #expect(rows.isEmpty)
        // Recent capture should remain
        let recent = try db.query("SELECT * FROM captures WHERE id = ?",
            params: [.text("new-cap")])
        #expect(recent.count == 1)
        // File should be deleted
        #expect(!FileManager.default.fileExists(atPath: imagePath))
    }

    @Test("Deletes old OCR snapshots")
    func deletesOldOCR() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let oldDate = "2026-02-01T10:00:00Z"
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("old-s"), .integer(1), .text(oldDate)])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type) VALUES (?, ?, ?, ?)
        """, params: [.text("old-cap"), .text("old-s"), .text(oldDate), .text("window")])
        try db.execute("""
            INSERT INTO ocr_snapshots (id, session_id, capture_id, timestamp, provider)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("old-ocr"), .text("old-s"), .text("old-cap"), .text(oldDate), .text("vision")])

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let deleted = try worker.cleanupOldOCRSnapshots()
        #expect(deleted >= 1)
    }

    @Test("Thins high-frequency captures keeping every Nth frame")
    func thinsHighFrequency() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO sessions (id, app_id, started_at, uncertainty_mode) VALUES (?, ?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-01T10:00:00Z"), .text("high_uncertainty")])

        // Insert 10 captures for high-uncertainty session
        for i in 0..<10 {
            try db.execute("""
                INSERT INTO captures (id, session_id, timestamp, capture_type, sampling_mode, retained)
                VALUES (?, ?, ?, ?, ?, ?)
            """, params: [.text("cap-\(i)"), .text("s1"),
                          .text("2026-04-01T10:00:\(String(format: "%02d", i * 3))Z"),
                          .text("window"), .text("high_uncertainty"), .integer(1)])
        }

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let thinned = try worker.thinHighFrequencyCaptures(keepEveryNth: 3)

        // Should keep frames 0, 3, 6, 9 (4 kept) and mark 6 as not retained
        #expect(thinned > 0)
        let retained = try db.query("SELECT COUNT(*) as c FROM captures WHERE retained = 1")
        let retainedCount = retained[0]["c"]?.intValue ?? 0
        #expect(retainedCount < 10) // Some should be thinned
    }

    @Test("Stats returns cleanup statistics")
    func stats() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let worker = RetentionWorker(db: db, retentionDays: 30)
        let stats = try worker.stats()
        #expect(stats.totalCaptures >= 0)
        #expect(stats.totalOCRSnapshots >= 0)
    }
}
```

- [ ] **Step 2: Implement RetentionWorker**

Create `Sources/MyMacAgent/Workers/RetentionWorker.swift`:

```swift
import Foundation
import os

struct RetentionStats {
    let totalCaptures: Int
    let retainedCaptures: Int
    let totalOCRSnapshots: Int
    let totalContextSnapshots: Int
    let oldestCaptureDate: String?
}

final class RetentionWorker {
    private let db: DatabaseManager
    private let retentionDays: Int
    private let logger = Logger.app

    init(db: DatabaseManager, retentionDays: Int = 30) {
        self.db = db
        self.retentionDays = retentionDays
    }

    func cleanupOldCaptures() throws -> Int {
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()
        )!
        let cutoff = ISO8601DateFormatter().string(from: cutoffDate)

        // Get files to delete
        let rows = try db.query(
            "SELECT id, image_path, thumb_path FROM captures WHERE timestamp < ?",
            params: [.text(cutoff)]
        )

        // Delete files
        for row in rows {
            if let imagePath = row["image_path"]?.textValue {
                try? FileManager.default.removeItem(atPath: imagePath)
            }
            if let thumbPath = row["thumb_path"]?.textValue {
                try? FileManager.default.removeItem(atPath: thumbPath)
            }
        }

        // Delete from DB
        try db.execute("DELETE FROM captures WHERE timestamp < ?",
            params: [.text(cutoff)])

        logger.info("Retention: deleted \(rows.count) old captures (before \(cutoff))")
        return rows.count
    }

    func cleanupOldOCRSnapshots() throws -> Int {
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()
        )!
        let cutoff = ISO8601DateFormatter().string(from: cutoffDate)

        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM ocr_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0

        try db.execute("DELETE FROM ocr_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)])

        logger.info("Retention: deleted \(count) old OCR snapshots")
        return Int(count)
    }

    func cleanupOldAXSnapshots() throws -> Int {
        let cutoffDate = Calendar.current.date(
            byAdding: .day, value: -retentionDays, to: Date()
        )!
        let cutoff = ISO8601DateFormatter().string(from: cutoffDate)

        let countRows = try db.query(
            "SELECT COUNT(*) as c FROM ax_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)]
        )
        let count = countRows.first?["c"]?.intValue ?? 0

        try db.execute("DELETE FROM ax_snapshots WHERE timestamp < ?",
            params: [.text(cutoff)])

        return Int(count)
    }

    func thinHighFrequencyCaptures(keepEveryNth: Int = 3) throws -> Int {
        // Find high-frequency captures (sampling_mode = 'high_uncertainty')
        // that are older than 1 day, and mark every non-Nth as not retained
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let cutoff = ISO8601DateFormatter().string(from: yesterday)

        let rows = try db.query("""
            SELECT id FROM captures
            WHERE sampling_mode = 'high_uncertainty'
              AND timestamp < ?
              AND retained = 1
            ORDER BY timestamp
        """, params: [.text(cutoff)])

        var thinned = 0
        for (index, row) in rows.enumerated() {
            if index % keepEveryNth != 0 {
                if let id = row["id"]?.textValue {
                    try db.execute("UPDATE captures SET retained = 0 WHERE id = ?",
                        params: [.text(id)])
                    thinned += 1
                }
            }
        }

        logger.info("Retention: thinned \(thinned) high-frequency captures (kept every \(keepEveryNth)th)")
        return thinned
    }

    func runAll() throws {
        let captures = try cleanupOldCaptures()
        let ocr = try cleanupOldOCRSnapshots()
        let ax = try cleanupOldAXSnapshots()
        let thinned = try thinHighFrequencyCaptures()
        logger.info("Retention complete: \(captures) captures, \(ocr) OCR, \(ax) AX deleted, \(thinned) thinned")
    }

    func stats() throws -> RetentionStats {
        let totalCaptures = try db.query("SELECT COUNT(*) as c FROM captures")
            .first?["c"]?.intValue ?? 0
        let retainedCaptures = try db.query("SELECT COUNT(*) as c FROM captures WHERE retained = 1")
            .first?["c"]?.intValue ?? 0
        let totalOCR = try db.query("SELECT COUNT(*) as c FROM ocr_snapshots")
            .first?["c"]?.intValue ?? 0
        let totalCtx = try db.query("SELECT COUNT(*) as c FROM context_snapshots")
            .first?["c"]?.intValue ?? 0
        let oldest = try db.query("SELECT MIN(timestamp) as d FROM captures")
            .first?["d"]?.textValue

        return RetentionStats(
            totalCaptures: Int(totalCaptures),
            retainedCaptures: Int(retainedCaptures),
            totalOCRSnapshots: Int(totalOCR),
            totalContextSnapshots: Int(totalCtx),
            oldestCaptureDate: oldest
        )
    }
}
```

- [ ] **Step 3: Run tests, commit**

```bash
make test
git add Sources/MyMacAgent/Workers/RetentionWorker.swift Tests/MyMacAgentTests/Workers/RetentionWorkerTests.swift
git commit -m "feat: add RetentionWorker for cleanup of old captures, OCR, and frame thinning"
```

---

## Task 5: SwiftUI Views (Timeline, Session Detail, Summary, Settings)

**Files:**
- Modify: `Sources/MyMacAgent/Views/MenuBarPopover.swift`
- Create: `Sources/MyMacAgent/Views/TimelineView.swift`
- Create: `Sources/MyMacAgent/Views/SessionDetailView.swift`
- Create: `Sources/MyMacAgent/Views/DailySummaryView.swift`
- Modify: `Sources/MyMacAgent/Settings/SettingsView.swift`

- [ ] **Step 1: Create TimelineView**

Create `Sources/MyMacAgent/Views/TimelineView.swift`:

```swift
import SwiftUI

struct TimelineView: View {
    let db: DatabaseManager
    @State private var selectedDate: String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }()
    @State private var sessions: [TimelineSession] = []
    @State private var apps: [AppUsageSummary] = []
    @State private var dates: [String] = []
    @State private var searchText = ""
    @State private var searchResults: [ContextSnapshotRecord] = []

    var body: some View {
        HSplitView {
            // Left: date list
            List(dates, id: \.self, selection: $selectedDate) { date in
                Text(date)
            }
            .frame(minWidth: 120, maxWidth: 160)

            // Right: timeline content
            VStack(alignment: .leading, spacing: 12) {
                Text("Timeline — \(selectedDate)")
                    .font(.title2).fontWeight(.semibold)

                // Search bar
                TextField("Search context...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { performSearch() }

                if !searchResults.isEmpty {
                    searchResultsView
                } else {
                    timelineContentView
                }
            }
            .padding()
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear { loadData() }
        .onChange(of: selectedDate) { loadData() }
    }

    private var timelineContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // App summary
                if !apps.isEmpty {
                    Text("Apps").font(.headline)
                    ForEach(apps, id: \.bundleId) { app in
                        HStack {
                            Text(app.appName).fontWeight(.medium)
                            Spacer()
                            Text(ObsidianExporter.formatDuration(minutes: app.totalMinutes))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }

                // Sessions
                Text("Sessions").font(.headline)
                ForEach(sessions, id: \.sessionId) { session in
                    SessionRowView(session: session)
                }
            }
        }
    }

    private var searchResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Search results for \"\(searchText)\"").font(.headline)
                ForEach(searchResults, id: \.id) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.appName ?? "Unknown").fontWeight(.medium)
                            Text(result.windowTitle ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Text(String(result.timestamp.prefix(16)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let text = result.mergedText {
                            Text(String(text.prefix(200)))
                                .font(.caption)
                                .lineLimit(3)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }
        }
    }

    private func loadData() {
        let provider = TimelineDataProvider(db: db)
        dates = (try? provider.availableDates()) ?? []
        sessions = (try? provider.sessionsForDate(selectedDate)) ?? []
        apps = (try? provider.appSummaryForDate(selectedDate)) ?? []
        searchResults = []
        searchText = ""
    }

    private func performSearch() {
        guard !searchText.isEmpty else { searchResults = []; return }
        let engine = SearchEngine(db: db)
        searchResults = (try? engine.search(query: searchText)) ?? []
    }
}

struct SessionRowView: View {
    let session: TimelineSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.appName).fontWeight(.medium)
                    if session.uncertaintyMode != "normal" {
                        Text("(\(session.uncertaintyMode))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(formatTime(session.startedAt))–\(session.endedAt.map { formatTime($0) } ?? "ongoing")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ObsidianExporter.formatDuration(minutes: session.durationMinutes))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ iso: String) -> String {
        guard iso.count >= 16 else { return iso }
        let start = iso.index(iso.startIndex, offsetBy: 11)
        let end = iso.index(start, offsetBy: 5)
        return String(iso[start..<end])
    }
}
```

- [ ] **Step 2: Create DailySummaryView**

Create `Sources/MyMacAgent/Views/DailySummaryView.swift`:

```swift
import SwiftUI

struct DailySummaryView: View {
    let db: DatabaseManager
    let date: String
    @State private var summary: DailySummaryRecord?
    @State private var isGenerating = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Daily Summary — \(date)")
                        .font(.title2).fontWeight(.semibold)
                    Spacer()
                    Button(isGenerating ? "Generating..." : "Regenerate") {
                        regenerateSummary()
                    }
                    .disabled(isGenerating)
                }

                if let error {
                    Text(error).foregroundStyle(.red).font(.caption)
                }

                if let summary {
                    if let text = summary.summaryText {
                        Text("Summary").font(.headline)
                        Text(text)
                    }

                    if let model = summary.modelName {
                        Text("Generated by \(model)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                } else {
                    Text("No summary generated yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear { loadSummary() }
    }

    private func loadSummary() {
        let provider = TimelineDataProvider(db: db)
        summary = try? provider.dailySummary(for: date)
    }

    private func regenerateSummary() {
        let settings = AppSettings()
        guard settings.hasApiKey else {
            error = "No API key configured. Set it in Settings."
            return
        }
        isGenerating = true
        error = nil

        Task {
            do {
                let client = LLMClient(apiKey: settings.openRouterApiKey, model: settings.llmModel)
                let summarizer = DailySummarizer(db: db)
                summary = try await summarizer.summarize(for: date, using: client)
            } catch {
                self.error = error.localizedDescription
            }
            isGenerating = false
        }
    }
}
```

- [ ] **Step 3: Create SessionDetailView**

Create `Sources/MyMacAgent/Views/SessionDetailView.swift`:

```swift
import SwiftUI

struct SessionDetailView: View {
    let db: DatabaseManager
    let session: TimelineSession
    @State private var contexts: [ContextSnapshotRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Text(session.appName).font(.title2).fontWeight(.semibold)
                    if session.uncertaintyMode != "normal" {
                        Text(session.uncertaintyMode)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.orange.opacity(0.2)))
                    }
                }

                Text("Duration: \(ObsidianExporter.formatDuration(minutes: session.durationMinutes))")
                    .foregroundStyle(.secondary)

                Divider()

                // Context snapshots
                Text("Context Snapshots (\(contexts.count))").font(.headline)

                ForEach(contexts, id: \.id) { ctx in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ctx.windowTitle ?? "Untitled").fontWeight(.medium)
                            Spacer()
                            Text(ctx.textSource ?? "")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let text = ctx.mergedText {
                            Text(String(text.prefix(500)))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(8)
                        }
                        HStack {
                            Text("Readability: \(String(format: "%.0f%%", ctx.readableScore * 100))")
                            Text("Uncertainty: \(String(format: "%.0f%%", ctx.uncertaintyScore * 100))")
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { loadContexts() }
    }

    private func loadContexts() {
        let provider = TimelineDataProvider(db: db)
        contexts = (try? provider.contextSnapshotsForSession(session.sessionId)) ?? []
    }
}
```

- [ ] **Step 4: Update SettingsView**

Replace `Sources/MyMacAgent/Settings/SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @State private var settings = AppSettings()
    @State private var apiKey: String = ""
    @State private var vaultPath: String = ""
    @State private var retentionDays: String = ""
    @State private var llmModel: String = ""
    @State private var saved = false

    var body: some View {
        Form {
            Section("OpenRouter API") {
                SecureField("API Key", text: $apiKey)
                TextField("Model", text: $llmModel)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Obsidian") {
                TextField("Vault Path", text: $vaultPath)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Retention") {
                TextField("Days to keep", text: $retentionDays)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                if saved {
                    Text("Saved!").foregroundStyle(.green)
                }
                Button("Save") { saveSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 450, height: 350)
        .onAppear { loadSettings() }
    }

    private func loadSettings() {
        apiKey = settings.openRouterApiKey
        vaultPath = settings.obsidianVaultPath
        retentionDays = String(settings.retentionDays)
        llmModel = settings.llmModel
    }

    private func saveSettings() {
        settings.openRouterApiKey = apiKey
        settings.obsidianVaultPath = vaultPath
        settings.retentionDays = Int(retentionDays) ?? 30
        settings.llmModel = llmModel
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
```

- [ ] **Step 5: Build and verify**

Run: `make build`
Expected: Build complete.

- [ ] **Step 6: Commit**

```bash
git add Sources/MyMacAgent/Views/ Sources/MyMacAgent/Settings/SettingsView.swift
git commit -m "feat: add TimelineView, SessionDetailView, DailySummaryView, and enhanced SettingsView"
```

---

## Task 6: Wire Up Phase 4 + Final AppDelegate

**Files:**
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift`
- Modify: `Sources/MyMacAgent/App/MyMacAgentApp.swift`

- [ ] **Step 1: Update AppDelegate with RetentionWorker + settings**

Add Phase 4 properties and initialization:

```swift
// Phase 4
private var retentionWorker: RetentionWorker?
private var retentionTimer: Timer?
```

Add `initializePhase4()`:

```swift
private func initializePhase4() {
    guard let db = databaseManager else { return }

    let settings = AppSettings()
    retentionWorker = RetentionWorker(db: db, retentionDays: settings.retentionDays)

    // Run retention daily
    retentionTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
        try? self?.retentionWorker?.runAll()
    }

    // Run once on startup
    try? retentionWorker?.runAll()

    logger.info("Phase 4 initialized (retention, UI data)")
}
```

Call from `applicationDidFinishLaunching` after `initializePhase3()`.

- [ ] **Step 2: Update MyMacAgentApp to add Timeline window**

Update `Sources/MyMacAgent/App/MyMacAgentApp.swift`:

```swift
import SwiftUI

@MainActor
@main
struct MyMacAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var permissionsManager = PermissionsManager()

    var body: some Scene {
        MenuBarExtra("MyMacAgent", systemImage: "brain.head.profile") {
            MenuBarPopover(permissionsManager: permissionsManager)
        }
        .menuBarExtraStyle(.window)

        Window("Timeline", id: "timeline") {
            if let db = appDelegate.databaseManager {
                TimelineView(db: db)
            } else {
                Text("Database not ready")
            }
        }

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

- [ ] **Step 3: Update MenuBarPopover with links**

Update `Sources/MyMacAgent/Views/MenuBarPopover.swift` to add Timeline and Summary buttons:

```swift
import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow

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

            Button("Open Timeline") {
                openWindow(id: "timeline")
            }

            Button("Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
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

Run: `make build`
Expected: Build complete.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/App/ Sources/MyMacAgent/Views/MenuBarPopover.swift
git commit -m "feat: wire up Phase 4 — retention, timeline window, enhanced menu bar"
```

---

## Task 7: Phase 4 Integration Tests

**Files:**
- Create: `Tests/MyMacAgentTests/Integration/Phase4IntegrationTests.swift`

- [ ] **Step 1: Write integration tests**

Create `Tests/MyMacAgentTests/Integration/Phase4IntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct Phase4IntegrationTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    private func seedTimeline(db: DatabaseManager) throws {
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")])

        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:00:00Z"), .text("2026-04-02T11:00:00Z"),
                      .integer(7200000), .text("normal")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [.text("s2"), .integer(2),
                      .text("2026-04-02T11:00:00Z"), .text("2026-04-02T12:00:00Z"),
                      .integer(3600000), .text("degraded")])

        try db.execute("""
            INSERT INTO context_snapshots (id, session_id, timestamp, app_name,
                window_title, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [.text("ctx-1"), .text("s1"), .text("2026-04-02T09:30:00Z"),
                      .text("Cursor"), .text("main.swift"),
                      .text("Implementing Swift concurrency patterns"),
                      .real(0.9), .real(0.1)])
    }

    @Test("Timeline data provider returns sessions and apps")
    func timelineData() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedTimeline(db: db)

        let provider = TimelineDataProvider(db: db)
        let sessions = try provider.sessionsForDate("2026-04-02")
        let apps = try provider.appSummaryForDate("2026-04-02")
        let dates = try provider.availableDates()

        #expect(sessions.count == 2)
        #expect(apps.count == 2)
        #expect(apps[0].appName == "Cursor") // longest first
        #expect(dates.contains("2026-04-02"))
    }

    @Test("Search finds context across sessions")
    func searchAcrossSessions() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedTimeline(db: db)

        let engine = SearchEngine(db: db)
        let results = try engine.search(query: "concurrency")
        #expect(results.count == 1)
        #expect(results[0].appName == "Cursor")
    }

    @Test("Retention cleans old data without touching recent")
    func retentionCleanup() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])

        // Old data (90 days ago)
        let oldDate = "2026-01-02T10:00:00Z"
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("old-s"), .integer(1), .text(oldDate)])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, retained)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("old-cap"), .text("old-s"), .text(oldDate), .text("window"), .integer(1)])
        try db.execute("""
            INSERT INTO ocr_snapshots (id, session_id, capture_id, timestamp, provider)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("old-ocr"), .text("old-s"), .text("old-cap"), .text(oldDate), .text("vision")])

        // Recent data
        let recentDate = ISO8601DateFormatter().string(from: Date())
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("new-s"), .integer(1), .text(recentDate)])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type, retained)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("new-cap"), .text("new-s"), .text(recentDate), .text("window"), .integer(1)])

        let worker = RetentionWorker(db: db, retentionDays: 30)
        try worker.runAll()

        // Old data gone
        let oldCaps = try db.query("SELECT * FROM captures WHERE id = ?", params: [.text("old-cap")])
        #expect(oldCaps.isEmpty)
        let oldOCR = try db.query("SELECT * FROM ocr_snapshots WHERE id = ?", params: [.text("old-ocr")])
        #expect(oldOCR.isEmpty)

        // Recent data preserved
        let newCaps = try db.query("SELECT * FROM captures WHERE id = ?", params: [.text("new-cap")])
        #expect(newCaps.count == 1)
    }

    @Test("AppSettings persist across instances")
    func settingsPersist() {
        let suiteName = "test_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        var settings = AppSettings(defaults: defaults)
        settings.openRouterApiKey = "sk-test-key"
        settings.obsidianVaultPath = "/test/vault"
        settings.retentionDays = 7

        let loaded = AppSettings(defaults: defaults)
        #expect(loaded.openRouterApiKey == "sk-test-key")
        #expect(loaded.obsidianVaultPath == "/test/vault")
        #expect(loaded.retentionDays == 7)
        #expect(loaded.hasApiKey)
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/MyMacAgentTests/Integration/Phase4IntegrationTests.swift
git commit -m "test: add Phase 4 integration tests for timeline, search, retention, settings"
```

---

## Self-Review Checklist

1. **Spec coverage:**
   - Sprint 9 (UI/Timeline): Tasks 2, 3, 5 — TimelineDataProvider queries, SearchEngine, TimelineView, SessionDetailView, DailySummaryView with regenerate button, enhanced SettingsView
   - Sprint 10 (Optimization): Tasks 1, 4, 6 — AppSettings, RetentionWorker (old capture cleanup, OCR cleanup, high-frequency thinning), wire up with daily retention timer
   - Sprint 11 (Notion): Deferred as spec marks it optional

2. **Placeholder scan:** All tasks contain complete Swift code.

3. **Type consistency:** `TimelineSession` and `AppUsageSummary` used consistently in Tasks 2, 5. `SearchEngine` in Tasks 3, 5. `RetentionWorker`/`RetentionStats` in Tasks 4, 6, 7. `AppSettings` in Tasks 1, 5, 6, 7. `ObsidianExporter.formatDuration(minutes:)` reused from Phase 3.
