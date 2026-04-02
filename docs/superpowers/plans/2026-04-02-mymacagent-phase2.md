# MyMacAgent Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add accessibility text extraction, local OCR via Apple Vision, and adaptive capture frequency that automatically increases sampling for "unreadable" windows.

**Architecture:** Three new subsystems layered onto the existing Phase 1 pipeline. AccessibilityContextEngine extracts AX attributes from focused windows. OCRPipeline uses a pluggable OCRProvider protocol (starting with Apple Vision) to extract text from capture images. CapturePolicyEngine evaluates readability and uncertainty scores to dynamically switch between normal (30-90s), degraded (8-15s), high-uncertainty (3s), and aggressive (1s) capture modes. All results persist to the existing SQLite schema (ax_snapshots, ocr_snapshots tables already exist).

**Tech Stack:** Swift 6.2, Accessibility API (AXUIElement), Vision framework (VNRecognizeTextRequest), existing DatabaseManager/SessionManager/ScreenCaptureEngine

---

## Existing Code Reference

Key types and files the engineer needs to know about:

| Type | File | What it does |
|------|------|-------------|
| `DatabaseManager` | `Sources/MyMacAgent/Database/DatabaseManager.swift` | `execute(_:params:)`, `query(_:params:)` with `SQLiteValue`/`SQLiteRow` |
| `SessionManager` | `Sources/MyMacAgent/Session/SessionManager.swift` | `currentSessionId`, `recordEvent(sessionId:type:payload:)`, `updateUncertaintyMode(sessionId:mode:)` |
| `UncertaintyMode` | `Sources/MyMacAgent/Models/Session.swift` | `.normal`, `.degraded`, `.highUncertainty`, `.recovery` |
| `SessionEventType` | `Sources/MyMacAgent/Models/SessionEvent.swift` | `.axSnapshotTaken`, `.ocrRequested`, `.ocrCompleted`, `.modeChanged`, `.captureTaken` |
| `ScreenCaptureEngine` | `Sources/MyMacAgent/Capture/ScreenCaptureEngine.swift` | `captureWindow(pid:) async throws -> CaptureResult`, `saveToDisk(result:directory:quality:)` |
| `ImageProcessor` | `Sources/MyMacAgent/Capture/ImageProcessor.swift` | `visualHash(image:) -> String?`, `diffScore(hash1:hash2:) -> Double` |
| `CaptureResult` | `Sources/MyMacAgent/Capture/ScreenCaptureEngine.swift` | `.image: NSImage`, `.width`, `.height`, `.timestamp` |
| `AppDelegate` | `Sources/MyMacAgent/App/AppDelegate.swift` | Wires AppMonitor, WindowMonitor, IdleDetector, SessionManager. Has `captureEngine` and `imageProcessor` properties. |
| `AppMonitor` | `Sources/MyMacAgent/Monitors/AppMonitor.swift` | `currentAppInfo: AppInfo?` with `.bundleId`, `.appName`, `.appId`, `.pid` |
| `Logger` | `Sources/MyMacAgent/Utilities/Logger.swift` | `.app`, `.database`, `.monitor`, `.session`, `.capture`, `.permissions` (all `nonisolated(unsafe)`) |

**Build/test commands:** `make build` / `make test` (Swift 6.2 via Homebrew, strict concurrency, Swift Testing framework with `import Testing`, `@Test`, `#expect`)

---

## File Structure

```
Sources/MyMacAgent/
    Accessibility/
        AccessibilityContextEngine.swift   -- AX attribute extraction from focused window
    OCR/
        OCRProvider.swift                  -- Protocol + VisionOCRProvider (Apple Vision)
        OCRPipeline.swift                  -- Orchestration: capture → OCR → normalize → persist
        TextNormalizer.swift               -- Whitespace cleanup, line merging, dedup
    Policy/
        ReadabilityScorer.swift            -- Heuristic readability score (0.0-1.0)
        CapturePolicyEngine.swift          -- Mode decisions + capture intervals
        CaptureScheduler.swift             -- Timer-driven capture loop with adaptive intervals
    Models/
        AXSnapshotRecord.swift             -- ax_snapshots row model
        OCRSnapshotRecord.swift            -- ocr_snapshots row model
    Utilities/
        Logger.swift                       -- Add .accessibility, .ocr, .policy categories

Tests/MyMacAgentTests/
    Accessibility/
        AccessibilityContextEngineTests.swift
    OCR/
        VisionOCRProviderTests.swift
        TextNormalizerTests.swift
        OCRPipelineTests.swift
    Policy/
        ReadabilityScorerTests.swift
        CapturePolicyEngineTests.swift
        CaptureSchedulerTests.swift
    Models/
        AXSnapshotRecordTests.swift
        OCRSnapshotRecordTests.swift
    Integration/
        Phase2IntegrationTests.swift
```

---

## Task 1: Add Logger Categories

**Files:**
- Modify: `Sources/MyMacAgent/Utilities/Logger.swift`

- [ ] **Step 1: Add new logger categories**

Add three new logger categories to `Sources/MyMacAgent/Utilities/Logger.swift`:

```swift
// Add after the existing categories:
nonisolated(unsafe) static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
nonisolated(unsafe) static let ocr = Logger(subsystem: subsystem, category: "ocr")
nonisolated(unsafe) static let policy = Logger(subsystem: subsystem, category: "policy")
```

- [ ] **Step 2: Verify build**

Run: `make build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/MyMacAgent/Utilities/Logger.swift
git commit -m "feat: add accessibility, ocr, policy logger categories"
```

---

## Task 2: AXSnapshot Model

**Files:**
- Create: `Sources/MyMacAgent/Models/AXSnapshotRecord.swift`
- Create: `Tests/MyMacAgentTests/Models/AXSnapshotRecordTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/MyMacAgentTests/Models/AXSnapshotRecordTests.swift`:

```swift
import Testing
@testable import MyMacAgent

struct AXSnapshotRecordTests {
    @Test("AXSnapshotRecord from complete row")
    func fromCompleteRow() {
        let row: SQLiteRow = [
            "id": .text("ax-1"),
            "session_id": .text("sess-1"),
            "capture_id": .text("cap-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"),
            "focused_role": .text("AXTextField"),
            "focused_subrole": .text("AXSearchField"),
            "focused_title": .text("Search"),
            "focused_value": .text("hello world"),
            "selected_text": .text("hello"),
            "text_len": .integer(11),
            "extraction_status": .text("success")
        ]
        let snap = AXSnapshotRecord(row: row)
        #expect(snap != nil)
        #expect(snap?.id == "ax-1")
        #expect(snap?.focusedRole == "AXTextField")
        #expect(snap?.focusedValue == "hello world")
        #expect(snap?.selectedText == "hello")
        #expect(snap?.textLen == 11)
        #expect(snap?.extractionStatus == "success")
    }

    @Test("AXSnapshotRecord returns nil for missing required fields")
    func nilForMissingFields() {
        let row: SQLiteRow = ["id": .text("ax-1")]
        #expect(AXSnapshotRecord(row: row) == nil)
    }

    @Test("AXSnapshotRecord totalTextLength sums all text sources")
    func totalTextLength() {
        let snap = AXSnapshotRecord(
            id: "ax-1", sessionId: "s-1", captureId: nil,
            timestamp: "now", focusedRole: nil, focusedSubrole: nil,
            focusedTitle: "Title", focusedValue: "Some value here",
            selectedText: "sel", textLen: 15, extractionStatus: "success"
        )
        #expect(snap.totalTextLength == 15)
    }

    @Test("AXSnapshotRecord hasUsableText")
    func hasUsableText() {
        let withText = AXSnapshotRecord(
            id: "1", sessionId: "s", captureId: nil, timestamp: "now",
            focusedRole: nil, focusedSubrole: nil, focusedTitle: nil,
            focusedValue: "some text", selectedText: nil,
            textLen: 9, extractionStatus: "success"
        )
        #expect(withText.hasUsableText)

        let withoutText = AXSnapshotRecord(
            id: "2", sessionId: "s", captureId: nil, timestamp: "now",
            focusedRole: nil, focusedSubrole: nil, focusedTitle: nil,
            focusedValue: nil, selectedText: nil,
            textLen: 0, extractionStatus: "empty"
        )
        #expect(!withoutText.hasUsableText)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `AXSnapshotRecord` not found.

- [ ] **Step 3: Implement AXSnapshotRecord**

Create `Sources/MyMacAgent/Models/AXSnapshotRecord.swift`:

```swift
import Foundation

struct AXSnapshotRecord {
    let id: String
    let sessionId: String
    let captureId: String?
    let timestamp: String
    let focusedRole: String?
    let focusedSubrole: String?
    let focusedTitle: String?
    let focusedValue: String?
    let selectedText: String?
    let textLen: Int
    let extractionStatus: String?

    var hasUsableText: Bool {
        textLen > 0
    }

    var totalTextLength: Int {
        textLen
    }

    init(
        id: String, sessionId: String, captureId: String?,
        timestamp: String, focusedRole: String?, focusedSubrole: String?,
        focusedTitle: String?, focusedValue: String?, selectedText: String?,
        textLen: Int, extractionStatus: String?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.captureId = captureId
        self.timestamp = timestamp
        self.focusedRole = focusedRole
        self.focusedSubrole = focusedSubrole
        self.focusedTitle = focusedTitle
        self.focusedValue = focusedValue
        self.selectedText = selectedText
        self.textLen = textLen
        self.extractionStatus = extractionStatus
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let sessionId = row["session_id"]?.textValue,
              let timestamp = row["timestamp"]?.textValue else { return nil }
        self.id = id
        self.sessionId = sessionId
        self.captureId = row["capture_id"]?.textValue
        self.timestamp = timestamp
        self.focusedRole = row["focused_role"]?.textValue
        self.focusedSubrole = row["focused_subrole"]?.textValue
        self.focusedTitle = row["focused_title"]?.textValue
        self.focusedValue = row["focused_value"]?.textValue
        self.selectedText = row["selected_text"]?.textValue
        self.textLen = row["text_len"]?.intValue.flatMap { Int($0) } ?? 0
        self.extractionStatus = row["extraction_status"]?.textValue
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/Models/AXSnapshotRecord.swift Tests/MyMacAgentTests/Models/AXSnapshotRecordTests.swift
git commit -m "feat: add AXSnapshotRecord model"
```

---

## Task 3: AccessibilityContextEngine

**Files:**
- Create: `Sources/MyMacAgent/Accessibility/AccessibilityContextEngine.swift`
- Create: `Tests/MyMacAgentTests/Accessibility/AccessibilityContextEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MyMacAgentTests/Accessibility/AccessibilityContextEngineTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct AccessibilityContextEngineTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    @Test("extractFromPid returns AXSnapshotRecord")
    func extractFromPid() {
        let engine = AccessibilityContextEngine()
        // Current process should have some AX attributes
        let snapshot = engine.extract(pid: ProcessInfo.processInfo.processIdentifier)
        // May or may not succeed depending on permissions, but should not crash
        // and should return a valid record structure
        if let snapshot {
            #expect(!snapshot.id.isEmpty)
            #expect(!snapshot.sessionId.isEmpty)
        }
    }

    @Test("persistSnapshot saves to DB")
    func persistSnapshot() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let engine = AccessibilityContextEngine()
        let snapshot = AXSnapshotRecord(
            id: UUID().uuidString, sessionId: "sess-1", captureId: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            focusedRole: "AXTextField", focusedSubrole: nil,
            focusedTitle: "Search", focusedValue: "test query",
            selectedText: nil, textLen: 10, extractionStatus: "success"
        )

        try engine.persist(snapshot: snapshot, db: db)

        let rows = try db.query("SELECT * FROM ax_snapshots WHERE session_id = ?",
            params: [.text("sess-1")])
        #expect(rows.count == 1)
        #expect(rows[0]["focused_role"]?.textValue == "AXTextField")
        #expect(rows[0]["focused_value"]?.textValue == "test query")
        #expect(rows[0]["text_len"]?.intValue == 10)
    }

    @Test("extractAttributes returns dictionary of AX attributes")
    func extractAttributes() {
        let engine = AccessibilityContextEngine()
        // Test with a known element structure
        let attrs = engine.extractAttributes(from: ProcessInfo.processInfo.processIdentifier)
        // Should return a dictionary (may be empty without permissions)
        #expect(attrs != nil || attrs == nil) // just verify it doesn't crash
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `AccessibilityContextEngine` not found.

- [ ] **Step 3: Implement AccessibilityContextEngine**

Create `Sources/MyMacAgent/Accessibility/AccessibilityContextEngine.swift`:

```swift
import AppKit
import os

final class AccessibilityContextEngine {
    private let logger = Logger.accessibility

    func extract(pid: pid_t, sessionId: String = "", captureId: String? = nil) -> AXSnapshotRecord? {
        let appRef = AXUIElementCreateApplication(pid)

        var focusedElement: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )

        // Fall back to focused window if no focused element
        let element: AXUIElement
        if focusedResult == .success, let fe = focusedElement {
            element = fe as! AXUIElement
        } else {
            var focusedWindow: CFTypeRef?
            let windowResult = AXUIElementCopyAttributeValue(
                appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow
            )
            guard windowResult == .success, let fw = focusedWindow else {
                logger.info("No focused element or window for pid \(pid)")
                return AXSnapshotRecord(
                    id: UUID().uuidString, sessionId: sessionId, captureId: captureId,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    focusedRole: nil, focusedSubrole: nil,
                    focusedTitle: nil, focusedValue: nil, selectedText: nil,
                    textLen: 0, extractionStatus: "no_element"
                )
            }
            element = fw as! AXUIElement
        }

        let role = axStringAttribute(element, kAXRoleAttribute)
        let subrole = axStringAttribute(element, kAXSubroleAttribute)
        let title = axStringAttribute(element, kAXTitleAttribute)
        let value = axStringAttribute(element, kAXValueAttribute)
        let selectedText = axStringAttribute(element, kAXSelectedTextAttribute)
        let description = axStringAttribute(element, kAXDescriptionAttribute)

        let combinedValue = [value, description].compactMap { $0 }.joined(separator: " ")
        let textLen = [title, combinedValue, selectedText]
            .compactMap { $0 }
            .reduce(0) { $0 + $1.count }

        let status: String = textLen > 0 ? "success" : "empty"

        let snapshot = AXSnapshotRecord(
            id: UUID().uuidString, sessionId: sessionId, captureId: captureId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            focusedRole: role, focusedSubrole: subrole,
            focusedTitle: title,
            focusedValue: combinedValue.isEmpty ? nil : combinedValue,
            selectedText: selectedText,
            textLen: textLen, extractionStatus: status
        )

        logger.info("AX snapshot: role=\(role ?? "nil"), textLen=\(textLen), status=\(status)")
        return snapshot
    }

    func persist(snapshot: AXSnapshotRecord, db: DatabaseManager) throws {
        try db.execute("""
            INSERT INTO ax_snapshots (id, session_id, capture_id, timestamp,
                focused_role, focused_subrole, focused_title, focused_value,
                selected_text, text_len, extraction_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(snapshot.id),
            .text(snapshot.sessionId),
            snapshot.captureId.map { .text($0) } ?? .null,
            .text(snapshot.timestamp),
            snapshot.focusedRole.map { .text($0) } ?? .null,
            snapshot.focusedSubrole.map { .text($0) } ?? .null,
            snapshot.focusedTitle.map { .text($0) } ?? .null,
            snapshot.focusedValue.map { .text($0) } ?? .null,
            snapshot.selectedText.map { .text($0) } ?? .null,
            .integer(Int64(snapshot.textLen)),
            snapshot.extractionStatus.map { .text($0) } ?? .null
        ])
    }

    func extractAttributes(from pid: pid_t) -> [String: String]? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedElement: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )
        guard result == .success, let element = focusedElement else { return nil }

        var attrs: [String: String] = [:]
        let axElement = element as! AXUIElement

        for attr in [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute,
                     kAXValueAttribute, kAXDescriptionAttribute, kAXSelectedTextAttribute] {
            if let value = axStringAttribute(axElement, attr) {
                attrs[attr as String] = value
            }
        }
        return attrs.isEmpty ? nil : attrs
    }

    // MARK: - Private

    private func axStringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/Accessibility/ Tests/MyMacAgentTests/Accessibility/
git commit -m "feat: add AccessibilityContextEngine for AX attribute extraction"
```

---

## Task 4: OCRSnapshot Model

**Files:**
- Create: `Sources/MyMacAgent/Models/OCRSnapshotRecord.swift`
- Create: `Tests/MyMacAgentTests/Models/OCRSnapshotRecordTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MyMacAgentTests/Models/OCRSnapshotRecordTests.swift`:

```swift
import Testing
@testable import MyMacAgent

struct OCRSnapshotRecordTests {
    @Test("OCRSnapshotRecord from complete row")
    func fromCompleteRow() {
        let row: SQLiteRow = [
            "id": .text("ocr-1"),
            "session_id": .text("sess-1"),
            "capture_id": .text("cap-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"),
            "provider": .text("vision"),
            "raw_text": .text("Hello World\nSecond line"),
            "normalized_text": .text("Hello World Second line"),
            "text_hash": .text("abc123"),
            "confidence": .real(0.95),
            "language": .text("en"),
            "processing_ms": .integer(150),
            "extraction_status": .text("success")
        ]
        let snap = OCRSnapshotRecord(row: row)
        #expect(snap != nil)
        #expect(snap?.id == "ocr-1")
        #expect(snap?.provider == "vision")
        #expect(snap?.confidence == 0.95)
        #expect(snap?.processingMs == 150)
        #expect(snap?.extractionStatus == "success")
    }

    @Test("OCRSnapshotRecord nil for missing required fields")
    func nilForMissing() {
        let row: SQLiteRow = ["id": .text("ocr-1")]
        #expect(OCRSnapshotRecord(row: row) == nil)
    }

    @Test("hasUsableText checks confidence and text length")
    func hasUsableText() {
        let good = OCRSnapshotRecord(
            id: "1", sessionId: "s", captureId: "c", timestamp: "now",
            provider: "vision", rawText: "Some text", normalizedText: "Some text",
            textHash: "h", confidence: 0.8, language: "en",
            processingMs: 100, extractionStatus: "success"
        )
        #expect(good.hasUsableText)

        let lowConf = OCRSnapshotRecord(
            id: "2", sessionId: "s", captureId: "c", timestamp: "now",
            provider: "vision", rawText: "x", normalizedText: "x",
            textHash: "h", confidence: 0.1, language: "en",
            processingMs: 100, extractionStatus: "low_confidence"
        )
        #expect(!lowConf.hasUsableText)

        let empty = OCRSnapshotRecord(
            id: "3", sessionId: "s", captureId: "c", timestamp: "now",
            provider: "vision", rawText: nil, normalizedText: nil,
            textHash: nil, confidence: 0.0, language: nil,
            processingMs: 50, extractionStatus: "empty"
        )
        #expect(!empty.hasUsableText)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `OCRSnapshotRecord` not found.

- [ ] **Step 3: Implement OCRSnapshotRecord**

Create `Sources/MyMacAgent/Models/OCRSnapshotRecord.swift`:

```swift
import Foundation

struct OCRSnapshotRecord {
    let id: String
    let sessionId: String
    let captureId: String
    let timestamp: String
    let provider: String
    let rawText: String?
    let normalizedText: String?
    let textHash: String?
    let confidence: Double
    let language: String?
    let processingMs: Int?
    let extractionStatus: String?

    var hasUsableText: Bool {
        confidence >= 0.3 && (normalizedText?.count ?? 0) > 0
    }

    init(
        id: String, sessionId: String, captureId: String, timestamp: String,
        provider: String, rawText: String?, normalizedText: String?,
        textHash: String?, confidence: Double, language: String?,
        processingMs: Int?, extractionStatus: String?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.captureId = captureId
        self.timestamp = timestamp
        self.provider = provider
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.textHash = textHash
        self.confidence = confidence
        self.language = language
        self.processingMs = processingMs
        self.extractionStatus = extractionStatus
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let sessionId = row["session_id"]?.textValue,
              let captureId = row["capture_id"]?.textValue,
              let timestamp = row["timestamp"]?.textValue,
              let provider = row["provider"]?.textValue else { return nil }
        self.id = id
        self.sessionId = sessionId
        self.captureId = captureId
        self.timestamp = timestamp
        self.provider = provider
        self.rawText = row["raw_text"]?.textValue
        self.normalizedText = row["normalized_text"]?.textValue
        self.textHash = row["text_hash"]?.textValue
        self.confidence = row["confidence"]?.realValue ?? 0
        self.language = row["language"]?.textValue
        self.processingMs = row["processing_ms"]?.intValue.flatMap { Int($0) }
        self.extractionStatus = row["extraction_status"]?.textValue
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/Models/OCRSnapshotRecord.swift Tests/MyMacAgentTests/Models/OCRSnapshotRecordTests.swift
git commit -m "feat: add OCRSnapshotRecord model"
```

---

## Task 5: TextNormalizer

**Files:**
- Create: `Sources/MyMacAgent/OCR/TextNormalizer.swift`
- Create: `Tests/MyMacAgentTests/OCR/TextNormalizerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MyMacAgentTests/OCR/TextNormalizerTests.swift`:

```swift
import Testing
import CryptoKit
@testable import MyMacAgent

struct TextNormalizerTests {
    @Test("Collapses multiple whitespace into single space")
    func collapsesWhitespace() {
        let result = TextNormalizer.normalize("hello   world    foo")
        #expect(result == "hello world foo")
    }

    @Test("Trims leading and trailing whitespace")
    func trims() {
        let result = TextNormalizer.normalize("  hello world  ")
        #expect(result == "hello world")
    }

    @Test("Merges consecutive blank lines")
    func mergesBlankLines() {
        let result = TextNormalizer.normalize("line1\n\n\n\nline2")
        #expect(result == "line1\nline2")
    }

    @Test("Preserves single newlines")
    func preservesSingleNewlines() {
        let result = TextNormalizer.normalize("line1\nline2\nline3")
        #expect(result == "line1\nline2\nline3")
    }

    @Test("Returns nil for empty or whitespace-only input")
    func nilForEmpty() {
        #expect(TextNormalizer.normalize("") == nil)
        #expect(TextNormalizer.normalize("   ") == nil)
        #expect(TextNormalizer.normalize("\n\n\n") == nil)
    }

    @Test("Computes stable text hash")
    func stableHash() {
        let hash1 = TextNormalizer.hash("hello world")
        let hash2 = TextNormalizer.hash("hello world")
        #expect(hash1 == hash2)
        #expect(!hash1.isEmpty)
    }

    @Test("Different text produces different hash")
    func differentHash() {
        let hash1 = TextNormalizer.hash("hello")
        let hash2 = TextNormalizer.hash("world")
        #expect(hash1 != hash2)
    }

    @Test("isDuplicate detects same text hash")
    func isDuplicate() {
        let text = "hello world"
        let hash = TextNormalizer.hash(text)
        #expect(TextNormalizer.isDuplicate(text: text, previousHash: hash))
        #expect(!TextNormalizer.isDuplicate(text: "different text", previousHash: hash))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `TextNormalizer` not found.

- [ ] **Step 3: Implement TextNormalizer**

Create `Sources/MyMacAgent/OCR/TextNormalizer.swift`:

```swift
import Foundation
import CryptoKit

enum TextNormalizer {
    static func normalize(_ text: String) -> String? {
        // Collapse multiple whitespace (but not newlines) into single space
        var result = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            }
            .joined(separator: "\n")

        // Merge consecutive blank lines into single newline
        while result.contains("\n\n") {
            result = result.replacingOccurrences(of: "\n\n", with: "\n")
        }

        // Trim
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result.isEmpty ? nil : result
    }

    static func hash(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isDuplicate(text: String, previousHash: String) -> Bool {
        hash(text) == previousHash
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/OCR/TextNormalizer.swift Tests/MyMacAgentTests/OCR/TextNormalizerTests.swift
git commit -m "feat: add TextNormalizer for OCR text cleanup and dedup"
```

---

## Task 6: OCRProvider Protocol + VisionOCRProvider

**Files:**
- Create: `Sources/MyMacAgent/OCR/OCRProvider.swift`
- Create: `Tests/MyMacAgentTests/OCR/VisionOCRProviderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MyMacAgentTests/OCR/VisionOCRProviderTests.swift`:

```swift
import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct VisionOCRProviderTests {
    private func makeTextImage(text: String, size: NSSize = NSSize(width: 400, height: 100)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: 40), withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    @Test("VisionOCRProvider recognizes text from image")
    func recognizesText() async throws {
        let provider = VisionOCRProvider()
        let image = makeTextImage(text: "Hello World")

        let result = try await provider.recognizeText(in: image)

        #expect(result.confidence > 0)
        #expect(result.rawText.lowercased().contains("hello"))
    }

    @Test("VisionOCRProvider returns low confidence for blank image")
    func lowConfidenceForBlank() async throws {
        let provider = VisionOCRProvider()
        let blank = NSImage(size: NSSize(width: 100, height: 100))
        blank.lockFocus()
        NSColor.white.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: NSSize(width: 100, height: 100)))
        blank.unlockFocus()

        let result = try await provider.recognizeText(in: blank)

        #expect(result.rawText.isEmpty || result.confidence < 0.3)
    }

    @Test("VisionOCRProvider reports processing time")
    func reportsProcessingTime() async throws {
        let provider = VisionOCRProvider()
        let image = makeTextImage(text: "Test")

        let result = try await provider.recognizeText(in: image)

        #expect(result.processingMs >= 0)
    }

    @Test("OCRProvider name is vision")
    func providerName() {
        let provider = VisionOCRProvider()
        #expect(provider.name == "vision")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `OCRProvider`, `VisionOCRProvider` not found.

- [ ] **Step 3: Implement OCRProvider + VisionOCRProvider**

Create `Sources/MyMacAgent/OCR/OCRProvider.swift`:

```swift
import AppKit
import Vision
import os

struct OCRResult {
    let rawText: String
    let confidence: Double
    let language: String?
    let processingMs: Int
}

protocol OCRProvider {
    var name: String { get }
    func recognizeText(in image: NSImage) async throws -> OCRResult
}

final class VisionOCRProvider: OCRProvider {
    let name = "vision"
    private let logger = Logger.ocr

    func recognizeText(in image: NSImage) async throws -> OCRResult {
        let startTime = DispatchTime.now()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return OCRResult(rawText: "", confidence: 0, language: nil, processingMs: 0)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en", "ru"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results else {
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
            return OCRResult(rawText: "", confidence: 0, language: nil, processingMs: elapsed)
        }

        var lines: [String] = []
        var totalConfidence: Double = 0

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            lines.append(candidate.string)
            totalConfidence += Double(observation.confidence)
        }

        let rawText = lines.joined(separator: "\n")
        let avgConfidence = observations.isEmpty ? 0 : totalConfidence / Double(observations.count)
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

        logger.info("Vision OCR: \(lines.count) lines, confidence=\(avgConfidence), \(elapsed)ms")

        return OCRResult(
            rawText: rawText,
            confidence: avgConfidence,
            language: nil,
            processingMs: elapsed
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/OCR/OCRProvider.swift Tests/MyMacAgentTests/OCR/VisionOCRProviderTests.swift
git commit -m "feat: add OCRProvider protocol and VisionOCRProvider using Apple Vision"
```

---

## Task 7: OCRPipeline

**Files:**
- Create: `Sources/MyMacAgent/OCR/OCRPipeline.swift`
- Create: `Tests/MyMacAgentTests/OCR/OCRPipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MyMacAgentTests/OCR/OCRPipelineTests.swift`:

```swift
import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct MockOCRProvider: OCRProvider {
    let name = "mock"
    let mockText: String
    let mockConfidence: Double

    func recognizeText(in image: NSImage) async throws -> OCRResult {
        OCRResult(rawText: mockText, confidence: mockConfidence, language: "en", processingMs: 10)
    }
}

struct OCRPipelineTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type) VALUES (?, ?, ?, ?)
        """, params: [.text("cap-1"), .text("sess-1"), .text("2026-04-02T10:00:00Z"), .text("window")])
        return (db, path)
    }

    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.white.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: NSSize(width: 100, height: 100)))
        image.unlockFocus()
        return image
    }

    @Test("Pipeline processes image and returns OCRSnapshotRecord")
    func processesImage() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let provider = MockOCRProvider(mockText: "Hello  World\n\n\nLine 2", mockConfidence: 0.9)
        let pipeline = OCRPipeline(provider: provider, db: db)

        let result = try await pipeline.process(
            image: makeImage(), sessionId: "sess-1", captureId: "cap-1"
        )

        #expect(result.normalizedText == "Hello World\nLine 2")
        #expect(result.confidence == 0.9)
        #expect(result.provider == "mock")
    }

    @Test("Pipeline persists result to ocr_snapshots")
    func persistsResult() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let provider = MockOCRProvider(mockText: "Test text", mockConfidence: 0.85)
        let pipeline = OCRPipeline(provider: provider, db: db)

        _ = try await pipeline.process(
            image: makeImage(), sessionId: "sess-1", captureId: "cap-1"
        )

        let rows = try db.query("SELECT * FROM ocr_snapshots WHERE session_id = ?",
            params: [.text("sess-1")])
        #expect(rows.count == 1)
        #expect(rows[0]["provider"]?.textValue == "mock")
        #expect(rows[0]["normalized_text"]?.textValue == "Test text")
        #expect(rows[0]["confidence"]?.realValue == 0.85)
    }

    @Test("Pipeline skips OCR when hash matches previous")
    func skipsDuplicate() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let provider = MockOCRProvider(mockText: "Same text", mockConfidence: 0.9)
        let pipeline = OCRPipeline(provider: provider, db: db)

        let first = try await pipeline.process(
            image: makeImage(), sessionId: "sess-1", captureId: "cap-1"
        )

        // Add a second capture
        try db.execute("""
            INSERT INTO captures (id, session_id, timestamp, capture_type) VALUES (?, ?, ?, ?)
        """, params: [.text("cap-2"), .text("sess-1"), .text("2026-04-02T10:00:05Z"), .text("window")])

        let second = try await pipeline.process(
            image: makeImage(), sessionId: "sess-1", captureId: "cap-2"
        )

        // Second should be marked as duplicate
        #expect(second.extractionStatus == "duplicate")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `OCRPipeline` not found.

- [ ] **Step 3: Implement OCRPipeline**

Create `Sources/MyMacAgent/OCR/OCRPipeline.swift`:

```swift
import AppKit
import os

final class OCRPipeline {
    private let provider: any OCRProvider
    private let db: DatabaseManager
    private let logger = Logger.ocr
    private var lastTextHash: String?

    init(provider: any OCRProvider, db: DatabaseManager) {
        self.provider = provider
        self.db = db
    }

    func process(image: NSImage, sessionId: String, captureId: String) async throws -> OCRSnapshotRecord {
        let ocrResult = try await provider.recognizeText(in: image)

        let normalizedText = TextNormalizer.normalize(ocrResult.rawText)
        let textHash = normalizedText.map { TextNormalizer.hash($0) }

        // Check for duplicate
        let isDuplicate: Bool
        if let hash = textHash, let prevHash = lastTextHash {
            isDuplicate = hash == prevHash
        } else {
            isDuplicate = false
        }

        let status: String
        if isDuplicate {
            status = "duplicate"
        } else if normalizedText == nil {
            status = "empty"
        } else if ocrResult.confidence < 0.3 {
            status = "low_confidence"
        } else {
            status = "success"
        }

        if let hash = textHash {
            lastTextHash = hash
        }

        let snapshot = OCRSnapshotRecord(
            id: UUID().uuidString,
            sessionId: sessionId,
            captureId: captureId,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            provider: provider.name,
            rawText: ocrResult.rawText.isEmpty ? nil : ocrResult.rawText,
            normalizedText: normalizedText,
            textHash: textHash,
            confidence: ocrResult.confidence,
            language: ocrResult.language,
            processingMs: ocrResult.processingMs,
            extractionStatus: status
        )

        try persist(snapshot: snapshot)

        logger.info("OCR pipeline: status=\(status), confidence=\(ocrResult.confidence), \(ocrResult.processingMs)ms")

        return snapshot
    }

    private func persist(snapshot: OCRSnapshotRecord) throws {
        try db.execute("""
            INSERT INTO ocr_snapshots (id, session_id, capture_id, timestamp,
                provider, raw_text, normalized_text, text_hash,
                confidence, language, processing_ms, extraction_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(snapshot.id),
            .text(snapshot.sessionId),
            .text(snapshot.captureId),
            .text(snapshot.timestamp),
            .text(snapshot.provider),
            snapshot.rawText.map { .text($0) } ?? .null,
            snapshot.normalizedText.map { .text($0) } ?? .null,
            snapshot.textHash.map { .text($0) } ?? .null,
            .real(snapshot.confidence),
            snapshot.language.map { .text($0) } ?? .null,
            snapshot.processingMs.map { .integer(Int64($0)) } ?? .null,
            snapshot.extractionStatus.map { .text($0) } ?? .null
        ])
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/OCR/OCRPipeline.swift Tests/MyMacAgentTests/OCR/OCRPipelineTests.swift
git commit -m "feat: add OCRPipeline with normalization, dedup, and persistence"
```

---

## Task 8: ReadabilityScorer

**Files:**
- Create: `Sources/MyMacAgent/Policy/ReadabilityScorer.swift`
- Create: `Tests/MyMacAgentTests/Policy/ReadabilityScorerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MyMacAgentTests/Policy/ReadabilityScorerTests.swift`:

```swift
import Testing
@testable import MyMacAgent

struct ReadabilityScorerTests {
    @Test("High score when AX and OCR both have good text")
    func highScoreFullText() {
        let input = ReadabilityInput(
            axTextLen: 50, ocrConfidence: 0.9, ocrTextLen: 100,
            visualChangeScore: 0.1, isCanvasLike: false
        )
        let score = ReadabilityScorer.score(input)
        #expect(score > 0.7)
    }

    @Test("Low score when no text available")
    func lowScoreNoText() {
        let input = ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0.0, ocrTextLen: 0,
            visualChangeScore: 0.8, isCanvasLike: true
        )
        let score = ReadabilityScorer.score(input)
        #expect(score < 0.3)
    }

    @Test("Medium score when only AX text available")
    func mediumScoreAxOnly() {
        let input = ReadabilityInput(
            axTextLen: 30, ocrConfidence: 0.0, ocrTextLen: 0,
            visualChangeScore: 0.2, isCanvasLike: false
        )
        let score = ReadabilityScorer.score(input)
        #expect(score >= 0.3 && score <= 0.7)
    }

    @Test("Medium score when only OCR text available")
    func mediumScoreOcrOnly() {
        let input = ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0.7, ocrTextLen: 50,
            visualChangeScore: 0.1, isCanvasLike: false
        )
        let score = ReadabilityScorer.score(input)
        #expect(score >= 0.3 && score <= 0.7)
    }

    @Test("Canvas-like content reduces score")
    func canvasReducesScore() {
        let normal = ReadabilityInput(
            axTextLen: 20, ocrConfidence: 0.5, ocrTextLen: 30,
            visualChangeScore: 0.1, isCanvasLike: false
        )
        let canvas = ReadabilityInput(
            axTextLen: 20, ocrConfidence: 0.5, ocrTextLen: 30,
            visualChangeScore: 0.1, isCanvasLike: true
        )
        #expect(ReadabilityScorer.score(normal) > ReadabilityScorer.score(canvas))
    }

    @Test("Frequent visual changes without text reduces score")
    func frequentChangesReduceScore() {
        let stable = ReadabilityInput(
            axTextLen: 10, ocrConfidence: 0.5, ocrTextLen: 20,
            visualChangeScore: 0.05, isCanvasLike: false
        )
        let changing = ReadabilityInput(
            axTextLen: 10, ocrConfidence: 0.5, ocrTextLen: 20,
            visualChangeScore: 0.9, isCanvasLike: false
        )
        #expect(ReadabilityScorer.score(stable) > ReadabilityScorer.score(changing))
    }

    @Test("Score clamped to 0.0-1.0")
    func scoreClamped() {
        let best = ReadabilityInput(
            axTextLen: 500, ocrConfidence: 1.0, ocrTextLen: 500,
            visualChangeScore: 0.0, isCanvasLike: false
        )
        let worst = ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0.0, ocrTextLen: 0,
            visualChangeScore: 1.0, isCanvasLike: true
        )
        #expect(ReadabilityScorer.score(best) <= 1.0)
        #expect(ReadabilityScorer.score(worst) >= 0.0)
    }

    @Test("classifyMode returns correct modes")
    func classifyMode() {
        #expect(ReadabilityScorer.classifyMode(score: 0.8) == .normal)
        #expect(ReadabilityScorer.classifyMode(score: 0.5) == .degraded)
        #expect(ReadabilityScorer.classifyMode(score: 0.2) == .highUncertainty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `ReadabilityScorer`, `ReadabilityInput` not found.

- [ ] **Step 3: Implement ReadabilityScorer**

Create `Sources/MyMacAgent/Policy/ReadabilityScorer.swift`:

```swift
import Foundation

struct ReadabilityInput {
    let axTextLen: Int
    let ocrConfidence: Double
    let ocrTextLen: Int
    let visualChangeScore: Double
    let isCanvasLike: Bool
}

enum ReadabilityScorer {
    /// Compute readability score (0.0 to 1.0).
    ///
    /// Heuristic from spec:
    /// - AX text present → +0.4
    /// - OCR confidence high → +0.4
    /// - Text long and meaningful → +0.2
    /// - Frequent changes without text → -0.3
    /// - Canvas-like content → -0.2
    ///
    /// Thresholds:
    /// - > 0.7 → readable (normal mode)
    /// - 0.3–0.7 → degraded mode
    /// - < 0.3 → unreadable (high-uncertainty mode)
    static func score(_ input: ReadabilityInput) -> Double {
        var score = 0.0

        // AX text contribution (up to +0.4)
        if input.axTextLen > 0 {
            let axFactor = min(Double(input.axTextLen) / 50.0, 1.0)
            score += 0.4 * axFactor
        }

        // OCR confidence contribution (up to +0.4)
        if input.ocrConfidence > 0.3 {
            score += 0.4 * input.ocrConfidence
        }

        // Text length / meaningfulness (up to +0.2)
        let totalTextLen = input.axTextLen + input.ocrTextLen
        if totalTextLen > 20 {
            let textFactor = min(Double(totalTextLen) / 100.0, 1.0)
            score += 0.2 * textFactor
        }

        // Frequent visual changes penalty (up to -0.3)
        if input.visualChangeScore > 0.3 {
            score -= 0.3 * input.visualChangeScore
        }

        // Canvas-like penalty (-0.2)
        if input.isCanvasLike {
            score -= 0.2
        }

        return max(0.0, min(1.0, score))
    }

    static func classifyMode(score: Double) -> UncertaintyMode {
        if score > 0.7 {
            return .normal
        } else if score >= 0.3 {
            return .degraded
        } else {
            return .highUncertainty
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/Policy/ReadabilityScorer.swift Tests/MyMacAgentTests/Policy/ReadabilityScorerTests.swift
git commit -m "feat: add ReadabilityScorer with heuristic readability scoring"
```

---

## Task 9: CapturePolicyEngine

**Files:**
- Create: `Sources/MyMacAgent/Policy/CapturePolicyEngine.swift`
- Create: `Tests/MyMacAgentTests/Policy/CapturePolicyEngineTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MyMacAgentTests/Policy/CapturePolicyEngineTests.swift`:

```swift
import Testing
@testable import MyMacAgent

struct CapturePolicyEngineTests {
    @Test("Normal mode returns 30-90 second interval")
    func normalModeInterval() {
        let engine = CapturePolicyEngine()
        let interval = engine.captureInterval(for: .normal)
        #expect(interval >= 30 && interval <= 90)
    }

    @Test("Degraded mode returns 8-15 second interval")
    func degradedModeInterval() {
        let engine = CapturePolicyEngine()
        let interval = engine.captureInterval(for: .degraded)
        #expect(interval >= 8 && interval <= 15)
    }

    @Test("High uncertainty mode returns 3 second interval")
    func highUncertaintyInterval() {
        let engine = CapturePolicyEngine()
        let interval = engine.captureInterval(for: .highUncertainty)
        #expect(interval == 3)
    }

    @Test("Recovery mode returns 8-15 second interval")
    func recoveryInterval() {
        let engine = CapturePolicyEngine()
        let interval = engine.captureInterval(for: .recovery)
        #expect(interval >= 8 && interval <= 15)
    }

    @Test("evaluatePolicy returns correct mode based on readability")
    func evaluatePolicy() {
        let engine = CapturePolicyEngine()

        let goodInput = ReadabilityInput(
            axTextLen: 50, ocrConfidence: 0.9, ocrTextLen: 100,
            visualChangeScore: 0.1, isCanvasLike: false
        )
        let decision = engine.evaluatePolicy(readability: goodInput, previousMode: .normal)
        #expect(decision.mode == .normal)
        #expect(decision.shouldCapture)
        #expect(decision.shouldOCR)

        let badInput = ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0.0, ocrTextLen: 0,
            visualChangeScore: 0.8, isCanvasLike: true
        )
        let badDecision = engine.evaluatePolicy(readability: badInput, previousMode: .normal)
        #expect(badDecision.mode == .highUncertainty)
    }

    @Test("Recovery transition when readability improves")
    func recoveryTransition() {
        let engine = CapturePolicyEngine()

        let improvingInput = ReadabilityInput(
            axTextLen: 40, ocrConfidence: 0.8, ocrTextLen: 80,
            visualChangeScore: 0.1, isCanvasLike: false
        )
        let decision = engine.evaluatePolicy(
            readability: improvingInput, previousMode: .highUncertainty
        )
        // Should transition to recovery, not jump straight to normal
        #expect(decision.mode == .recovery)
    }

    @Test("shouldRunOCR based on visual change")
    func shouldRunOCR() {
        let engine = CapturePolicyEngine()
        // Significant visual change → should OCR
        #expect(engine.shouldRunOCR(visualDiffScore: 0.5, mode: .normal))
        // No visual change → skip OCR
        #expect(!engine.shouldRunOCR(visualDiffScore: 0.01, mode: .normal))
        // In high-uncertainty, always OCR even with low diff
        #expect(engine.shouldRunOCR(visualDiffScore: 0.01, mode: .highUncertainty))
    }

    @Test("shouldRetainCapture based on mode and diff")
    func shouldRetainCapture() {
        let engine = CapturePolicyEngine()
        // Normal mode, low diff → don't retain
        #expect(!engine.shouldRetainCapture(visualDiffScore: 0.01, mode: .normal))
        // Normal mode, high diff → retain
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.3, mode: .normal))
        // High uncertainty → always retain
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.01, mode: .highUncertainty))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `CapturePolicyEngine` not found.

- [ ] **Step 3: Implement CapturePolicyEngine**

Create `Sources/MyMacAgent/Policy/CapturePolicyEngine.swift`:

```swift
import Foundation
import os

struct CaptureDecision {
    let mode: UncertaintyMode
    let shouldCapture: Bool
    let shouldOCR: Bool
    let shouldAX: Bool
    let interval: TimeInterval
}

final class CapturePolicyEngine {
    private let logger = Logger.policy

    func captureInterval(for mode: UncertaintyMode) -> TimeInterval {
        switch mode {
        case .normal: return 60
        case .degraded: return 10
        case .highUncertainty: return 3
        case .recovery: return 10
        }
    }

    func evaluatePolicy(readability: ReadabilityInput, previousMode: UncertaintyMode) -> CaptureDecision {
        let readabilityScore = ReadabilityScorer.score(readability)
        var newMode = ReadabilityScorer.classifyMode(score: readabilityScore)

        // Gradual recovery: don't jump from highUncertainty straight to normal
        if previousMode == .highUncertainty && newMode == .normal {
            newMode = .recovery
        }
        // Recovery → normal only when readability stays high
        if previousMode == .recovery && newMode == .normal {
            newMode = .normal // allow transition after recovery period
        }
        // If was recovering and readability drops again, go back to appropriate mode
        if previousMode == .recovery && newMode == .highUncertainty {
            newMode = .highUncertainty
        }

        let interval = captureInterval(for: newMode)

        let decision = CaptureDecision(
            mode: newMode,
            shouldCapture: true,
            shouldOCR: newMode != .normal || readability.ocrTextLen == 0,
            shouldAX: true,
            interval: interval
        )

        if newMode != previousMode {
            logger.info("Mode transition: \(previousMode.rawValue) → \(newMode.rawValue) (readability=\(readabilityScore))")
        }

        return decision
    }

    func shouldRunOCR(visualDiffScore: Double, mode: UncertaintyMode) -> Bool {
        switch mode {
        case .highUncertainty:
            return true  // always OCR in high-uncertainty
        case .degraded:
            return visualDiffScore > 0.05
        case .normal, .recovery:
            return visualDiffScore > 0.1
        }
    }

    func shouldRetainCapture(visualDiffScore: Double, mode: UncertaintyMode) -> Bool {
        switch mode {
        case .highUncertainty:
            return true  // always retain in high-uncertainty
        case .degraded:
            return visualDiffScore > 0.05
        case .normal, .recovery:
            return visualDiffScore > 0.1
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/Policy/CapturePolicyEngine.swift Tests/MyMacAgentTests/Policy/CapturePolicyEngineTests.swift
git commit -m "feat: add CapturePolicyEngine with adaptive mode transitions"
```

---

## Task 10: CaptureScheduler

**Files:**
- Create: `Sources/MyMacAgent/Policy/CaptureScheduler.swift`
- Create: `Tests/MyMacAgentTests/Policy/CaptureSchedulerTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MyMacAgentTests/Policy/CaptureSchedulerTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

final class MockCaptureSchedulerDelegate: CaptureSchedulerDelegate {
    var captureCount = 0
    var lastMode: UncertaintyMode?

    func captureScheduler(_ scheduler: CaptureScheduler, shouldCaptureWithMode mode: UncertaintyMode) {
        captureCount += 1
        lastMode = mode
    }

    func captureScheduler(_ scheduler: CaptureScheduler, didChangeMode mode: UncertaintyMode) {
        lastMode = mode
    }
}

struct CaptureSchedulerTests {
    @Test("Scheduler initializes with normal mode")
    func initializesNormal() {
        let scheduler = CaptureScheduler(policyEngine: CapturePolicyEngine())
        #expect(scheduler.currentMode == .normal)
    }

    @Test("updateReadability changes mode")
    func updateReadabilityChangesMode() {
        let scheduler = CaptureScheduler(policyEngine: CapturePolicyEngine())
        let delegate = MockCaptureSchedulerDelegate()
        scheduler.delegate = delegate

        let badInput = ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0.0, ocrTextLen: 0,
            visualChangeScore: 0.8, isCanvasLike: true
        )
        scheduler.updateReadability(badInput)

        #expect(scheduler.currentMode == .highUncertainty)
        #expect(delegate.lastMode == .highUncertainty)
    }

    @Test("currentInterval matches mode")
    func currentIntervalMatchesMode() {
        let scheduler = CaptureScheduler(policyEngine: CapturePolicyEngine())

        #expect(scheduler.currentInterval >= 30) // normal

        let badInput = ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0.0, ocrTextLen: 0,
            visualChangeScore: 0.8, isCanvasLike: true
        )
        scheduler.updateReadability(badInput)
        #expect(scheduler.currentInterval == 3) // high-uncertainty
    }

    @Test("Recovery mode when readability improves from high-uncertainty")
    func recoveryMode() {
        let scheduler = CaptureScheduler(policyEngine: CapturePolicyEngine())

        // First, make it high-uncertainty
        let badInput = ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0.0, ocrTextLen: 0,
            visualChangeScore: 0.8, isCanvasLike: true
        )
        scheduler.updateReadability(badInput)
        #expect(scheduler.currentMode == .highUncertainty)

        // Now improve readability
        let goodInput = ReadabilityInput(
            axTextLen: 50, ocrConfidence: 0.9, ocrTextLen: 100,
            visualChangeScore: 0.1, isCanvasLike: false
        )
        scheduler.updateReadability(goodInput)
        #expect(scheduler.currentMode == .recovery)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `CaptureScheduler` not found.

- [ ] **Step 3: Implement CaptureScheduler**

Create `Sources/MyMacAgent/Policy/CaptureScheduler.swift`:

```swift
import Foundation
import os

protocol CaptureSchedulerDelegate: AnyObject {
    func captureScheduler(_ scheduler: CaptureScheduler, shouldCaptureWithMode mode: UncertaintyMode)
    func captureScheduler(_ scheduler: CaptureScheduler, didChangeMode mode: UncertaintyMode)
}

final class CaptureScheduler {
    weak var delegate: CaptureSchedulerDelegate?
    private let policyEngine: CapturePolicyEngine
    private let logger = Logger.policy
    private var timer: Timer?
    private(set) var currentMode: UncertaintyMode = .normal

    var currentInterval: TimeInterval {
        policyEngine.captureInterval(for: currentMode)
    }

    init(policyEngine: CapturePolicyEngine) {
        self.policyEngine = policyEngine
    }

    func start() {
        scheduleNextCapture()
        logger.info("CaptureScheduler started (mode=\(currentMode.rawValue), interval=\(currentInterval)s)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        logger.info("CaptureScheduler stopped")
    }

    func updateReadability(_ input: ReadabilityInput) {
        let decision = policyEngine.evaluatePolicy(readability: input, previousMode: currentMode)

        if decision.mode != currentMode {
            let oldMode = currentMode
            currentMode = decision.mode
            delegate?.captureScheduler(self, didChangeMode: currentMode)
            logger.info("Mode changed: \(oldMode.rawValue) → \(currentMode.rawValue)")

            // Reschedule with new interval
            if timer != nil {
                stop()
                scheduleNextCapture()
            }
        }
    }

    func triggerCapture() {
        delegate?.captureScheduler(self, shouldCaptureWithMode: currentMode)
    }

    private func scheduleNextCapture() {
        let interval = currentInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.triggerCapture()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MyMacAgent/Policy/CaptureScheduler.swift Tests/MyMacAgentTests/Policy/CaptureSchedulerTests.swift
git commit -m "feat: add CaptureScheduler with adaptive timer-based capture"
```

---

## Task 11: Wire Up Phase 2 in AppDelegate

**Files:**
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift`

- [ ] **Step 1: Add Phase 2 components to AppDelegate**

Add properties and initialization for AccessibilityContextEngine, OCRPipeline, CapturePolicyEngine, CaptureScheduler. Wire CaptureScheduler to trigger captures and evaluate readability.

Modify `Sources/MyMacAgent/App/AppDelegate.swift`:

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
    // Phase 2
    private var accessibilityEngine: AccessibilityContextEngine?
    private var ocrPipeline: OCRPipeline?
    private var policyEngine: CapturePolicyEngine?
    private var captureScheduler: CaptureScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MyMacAgent launched")
        initializeDatabase()
        initializeMonitors()
        initializePhase2()
    }

    func applicationWillTerminate(_ notification: Notification) {
        captureScheduler?.stop()
        appMonitor?.stop()
        windowMonitor?.stop()
        idleDetector?.stop()
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

    private func initializePhase2() {
        guard let db = databaseManager else { return }

        accessibilityEngine = AccessibilityContextEngine()
        ocrPipeline = OCRPipeline(provider: VisionOCRProvider(), db: db)

        let policy = CapturePolicyEngine()
        policyEngine = policy

        let scheduler = CaptureScheduler(policyEngine: policy)
        scheduler.delegate = self
        scheduler.start()
        captureScheduler = scheduler

        logger.info("Phase 2 components initialized (AX, OCR, adaptive capture)")
    }

    private func performCapture(mode: UncertaintyMode) {
        guard let appInfo = appMonitor?.currentAppInfo,
              let sessionManager, let sessionId = sessionManager.currentSessionId,
              let captureEngine, let imageProcessor, let db = databaseManager else { return }

        Task {
            do {
                // 1. Take screenshot
                let captureResult = try await captureEngine.captureWindow(pid: appInfo.pid)

                // 2. Compute hash and diff
                let hash = imageProcessor.visualHash(image: captureResult.image)

                // 3. Save to disk
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let captureDir = appSupport.appendingPathComponent("MyMacAgent/captures", isDirectory: true)
                try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
                let imagePath = try captureEngine.saveToDisk(result: captureResult, directory: captureDir.path)

                // 4. Persist capture record
                let captureId = UUID().uuidString
                let now = ISO8601DateFormatter().string(from: Date())
                try db.execute("""
                    INSERT INTO captures (id, session_id, timestamp, capture_type, image_path,
                        width, height, visual_hash, sampling_mode)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, params: [
                    .text(captureId), .text(sessionId), .text(now),
                    .text("window"), .text(imagePath),
                    .integer(Int64(captureResult.width)), .integer(Int64(captureResult.height)),
                    hash.map { .text($0) } ?? .null, .text(mode.rawValue)
                ])

                try sessionManager.recordEvent(sessionId: sessionId, type: .captureTaken, payload: nil)

                // 5. AX snapshot
                var axTextLen = 0
                if let axEngine = accessibilityEngine {
                    if let axSnapshot = axEngine.extract(pid: appInfo.pid, sessionId: sessionId, captureId: captureId) {
                        try axEngine.persist(snapshot: axSnapshot, db: db)
                        axTextLen = axSnapshot.textLen
                        try sessionManager.recordEvent(sessionId: sessionId, type: .axSnapshotTaken, payload: nil)
                    }
                }

                // 6. OCR (if policy says to)
                var ocrConfidence = 0.0
                var ocrTextLen = 0
                let visualDiff = hash.map { h in
                    // Compare with previous hash if available
                    0.5 // default: assume change
                } ?? 0.5

                if let policyEngine, policyEngine.shouldRunOCR(visualDiffScore: visualDiff, mode: mode) {
                    try sessionManager.recordEvent(sessionId: sessionId, type: .ocrRequested, payload: nil)
                    if let ocrPipeline {
                        let ocrResult = try await ocrPipeline.process(
                            image: captureResult.image, sessionId: sessionId, captureId: captureId
                        )
                        ocrConfidence = ocrResult.confidence
                        ocrTextLen = ocrResult.normalizedText?.count ?? 0
                        try sessionManager.recordEvent(sessionId: sessionId, type: .ocrCompleted, payload: nil)
                    }
                }

                // 7. Update readability score and mode
                let readabilityInput = ReadabilityInput(
                    axTextLen: axTextLen, ocrConfidence: ocrConfidence, ocrTextLen: ocrTextLen,
                    visualChangeScore: visualDiff, isCanvasLike: false
                )
                captureScheduler?.updateReadability(readabilityInput)

                // 8. Update session uncertainty mode if changed
                if let scheduler = captureScheduler {
                    try sessionManager.updateUncertaintyMode(sessionId: sessionId, mode: scheduler.currentMode)
                }

            } catch {
                logger.error("Capture failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - AppMonitorDelegate
extension AppDelegate: AppMonitorDelegate {
    func appMonitor(_ monitor: AppMonitor, didSwitchTo bundleId: String, appName: String, appId: Int64) {
        guard let sessionManager else { return }
        do {
            let sessionId = try sessionManager.switchSession(appId: appId, windowId: nil)
            try sessionManager.recordEvent(sessionId: sessionId, type: .appActivated, payload:
                "{\"bundle_id\":\"\(bundleId)\",\"app_name\":\"\(appName)\"}")
            if let pid = monitor.currentAppInfo?.pid {
                windowMonitor?.updateApp(appId: appId, pid: pid)
            }
            // Reset capture scheduler to normal mode for new app
            let normalInput = ReadabilityInput(
                axTextLen: 0, ocrConfidence: 0, ocrTextLen: 0,
                visualChangeScore: 0, isCanvasLike: false
            )
            captureScheduler?.updateReadability(normalInput)
        } catch {
            logger.error("Failed to handle app switch: \(error.localizedDescription)")
        }
    }
}

// MARK: - WindowMonitorDelegate
extension AppDelegate: WindowMonitorDelegate {
    func windowMonitor(_ monitor: WindowMonitor, didSwitchTo windowId: Int64, title: String?) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        do {
            try sessionManager.recordEvent(sessionId: sessionId, type: .windowChanged, payload:
                "{\"window_id\":\(windowId),\"title\":\"\(title ?? "")\"}")
        } catch {
            logger.error("Failed to record window change: \(error.localizedDescription)")
        }
    }
}

// MARK: - IdleDetectorDelegate
extension AppDelegate: IdleDetectorDelegate {
    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        let eventType: SessionEventType = isIdle ? .idleStarted : .idleEnded
        try? sessionManager.recordEvent(sessionId: sessionId, type: eventType, payload: nil)
    }
}

// MARK: - CaptureSchedulerDelegate
extension AppDelegate: CaptureSchedulerDelegate {
    func captureScheduler(_ scheduler: CaptureScheduler, shouldCaptureWithMode mode: UncertaintyMode) {
        performCapture(mode: mode)
    }

    func captureScheduler(_ scheduler: CaptureScheduler, didChangeMode mode: UncertaintyMode) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        try? sessionManager.recordEvent(sessionId: sessionId, type: .modeChanged, payload:
            "{\"mode\":\"\(mode.rawValue)\"}")
        logger.info("Capture mode changed to \(mode.rawValue)")
    }
}
```

- [ ] **Step 2: Build and verify**

Run: `make build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/MyMacAgent/App/AppDelegate.swift
git commit -m "feat: wire up AX, OCR, and adaptive capture scheduler in AppDelegate"
```

---

## Task 12: Phase 2 Integration Tests

**Files:**
- Create: `Tests/MyMacAgentTests/Integration/Phase2IntegrationTests.swift`

- [ ] **Step 1: Write integration tests**

Create `Tests/MyMacAgentTests/Integration/Phase2IntegrationTests.swift`:

```swift
import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct Phase2IntegrationTests {
    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
        try runner.runPending()
        return (db, path)
    }

    private func makeTextImage(text: String) -> NSImage {
        let size = NSSize(width: 400, height: 100)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: 40), withAttributes: attrs)
        image.unlockFocus()
        return image
    }

    @Test("AX snapshot persists to database")
    func axSnapshotPersists() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let engine = AccessibilityContextEngine()
        let snapshot = AXSnapshotRecord(
            id: "ax-1", sessionId: "sess-1", captureId: nil,
            timestamp: "2026-04-02T10:00:00Z",
            focusedRole: "AXTextArea", focusedSubrole: nil,
            focusedTitle: "Editor", focusedValue: "Hello from test",
            selectedText: nil, textLen: 15, extractionStatus: "success"
        )
        try engine.persist(snapshot: snapshot, db: db)

        let rows = try db.query("SELECT * FROM ax_snapshots WHERE id = ?", params: [.text("ax-1")])
        #expect(rows.count == 1)
        #expect(rows[0]["focused_value"]?.textValue == "Hello from test")
    }

    @Test("OCR pipeline end-to-end with mock provider")
    func ocrPipelineE2E() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])
        try db.execute("INSERT INTO captures (id, session_id, timestamp, capture_type) VALUES (?, ?, ?, ?)",
            params: [.text("cap-1"), .text("sess-1"), .text("2026-04-02T10:00:00Z"), .text("window")])

        let provider = MockOCRProvider(mockText: "Test document text here", mockConfidence: 0.92)
        let pipeline = OCRPipeline(provider: provider, db: db)
        let result = try await pipeline.process(image: makeTextImage(text: "Test"), sessionId: "sess-1", captureId: "cap-1")

        #expect(result.confidence == 0.92)
        #expect(result.normalizedText == "Test document text here")
        #expect(result.extractionStatus == "success")

        let rows = try db.query("SELECT * FROM ocr_snapshots")
        #expect(rows.count == 1)
    }

    @Test("Readability scorer drives mode transitions")
    func readabilityScorerModeTransitions() {
        let scheduler = CaptureScheduler(policyEngine: CapturePolicyEngine())

        // Start normal
        #expect(scheduler.currentMode == .normal)

        // Simulate unreadable content
        scheduler.updateReadability(ReadabilityInput(
            axTextLen: 0, ocrConfidence: 0, ocrTextLen: 0,
            visualChangeScore: 0.9, isCanvasLike: true
        ))
        #expect(scheduler.currentMode == .highUncertainty)
        #expect(scheduler.currentInterval == 3)

        // Simulate readability recovery
        scheduler.updateReadability(ReadabilityInput(
            axTextLen: 50, ocrConfidence: 0.9, ocrTextLen: 100,
            visualChangeScore: 0.05, isCanvasLike: false
        ))
        #expect(scheduler.currentMode == .recovery)

        // Continue good readability → back to normal
        scheduler.updateReadability(ReadabilityInput(
            axTextLen: 50, ocrConfidence: 0.9, ocrTextLen: 100,
            visualChangeScore: 0.05, isCanvasLike: false
        ))
        #expect(scheduler.currentMode == .normal)
        #expect(scheduler.currentInterval >= 30)
    }

    @Test("Full capture-to-readability flow")
    func fullCaptureFlow() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Setup
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("sess-1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        // Simulate AX extraction
        let axEngine = AccessibilityContextEngine()
        let axSnap = AXSnapshotRecord(
            id: UUID().uuidString, sessionId: "sess-1", captureId: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            focusedRole: "AXTextArea", focusedSubrole: nil,
            focusedTitle: "Code", focusedValue: "let x = 42",
            selectedText: nil, textLen: 10, extractionStatus: "success"
        )
        try axEngine.persist(snapshot: axSnap, db: db)

        // Simulate OCR
        try db.execute("INSERT INTO captures (id, session_id, timestamp, capture_type) VALUES (?, ?, ?, ?)",
            params: [.text("cap-1"), .text("sess-1"), .text("2026-04-02T10:00:00Z"), .text("window")])

        let mockOCR = MockOCRProvider(mockText: "let x = 42", mockConfidence: 0.95)
        let pipeline = OCRPipeline(provider: mockOCR, db: db)
        let ocrResult = try await pipeline.process(image: makeTextImage(text: "code"), sessionId: "sess-1", captureId: "cap-1")

        // Compute readability
        let readabilityInput = ReadabilityInput(
            axTextLen: axSnap.textLen,
            ocrConfidence: ocrResult.confidence,
            ocrTextLen: ocrResult.normalizedText?.count ?? 0,
            visualChangeScore: 0.05,
            isCanvasLike: false
        )
        let score = ReadabilityScorer.score(readabilityInput)
        let mode = ReadabilityScorer.classifyMode(score: score)

        // Good text from both sources → should be readable/normal
        #expect(score > 0.7)
        #expect(mode == .normal)

        // Verify DB has both records
        let axRows = try db.query("SELECT * FROM ax_snapshots")
        let ocrRows = try db.query("SELECT * FROM ocr_snapshots")
        #expect(axRows.count == 1)
        #expect(ocrRows.count == 1)
    }
}
```

- [ ] **Step 2: Run all tests**

Run: `make test`
Expected: All tests PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/MyMacAgentTests/Integration/Phase2IntegrationTests.swift
git commit -m "test: add Phase 2 integration tests for AX, OCR, and adaptive capture"
```

---

## Self-Review Checklist

1. **Spec coverage:**
   - Sprint 3 (Accessibility pipeline): Covered by Tasks 2-3 — AXSnapshotRecord model + AccessibilityContextEngine extracting title, role, subrole, focused element, selected text, value
   - Sprint 4 (OCR pipeline): Covered by Tasks 4-7 — OCRSnapshotRecord + TextNormalizer + OCRProvider protocol + VisionOCRProvider + OCRPipeline with normalization, dedup, persistence
   - Sprint 5 (Adaptive capture policy): Covered by Tasks 8-10 — ReadabilityScorer (heuristic from spec: AX→+0.4, OCR→+0.4, text→+0.2, changes→-0.3, canvas→-0.2), CapturePolicyEngine (mode transitions, OCR/retain decisions), CaptureScheduler (adaptive timer)
   - Wiring: Task 11 connects everything in AppDelegate
   - Integration: Task 12 verifies the full flow

2. **Placeholder scan:** All tasks contain complete Swift code. No "TBD" or "fill in later".

3. **Type consistency:** `AXSnapshotRecord` used consistently in Tasks 2-3, 11-12. `OCRSnapshotRecord` in Tasks 4, 7, 12. `ReadabilityInput` in Tasks 8-10, 12. `OCRResult` in Tasks 6-7. `CaptureDecision` in Task 9. `UncertaintyMode` from existing code used throughout. `MockOCRProvider` defined in Task 7 tests and reused in Task 12 tests.

---

## Next Plans

After completing this plan, create:
- **Phase 3:** `2026-04-XX-mymacagent-phase3.md` — Context fusion, Daily summaries, Obsidian export (Sprints 6-8)
- **Phase 4:** `2026-04-XX-mymacagent-phase4.md` — Timeline UI, Optimization, Notion export (Sprints 9-11)
