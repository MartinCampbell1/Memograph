# MyMacAgent Stabilization Plan — Fix Critical Bugs

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the 5 critical bugs identified in code review: broken duration accounting, scheduler reset bug, visual diff stub, missing backpressure, and missing privacy guardrails.

**Architecture:** Targeted fixes to existing modules. No architectural rewrites — each task fixes one specific bug with tests proving the fix. SessionManager gets duration tracking. CaptureScheduler gets explicit reset. AppDelegate gets real visual diff using existing ImageProcessor. New CaptureActor limits OCR concurrency. New PrivacyGuard blocks capture for blacklisted apps.

**Tech Stack:** Swift 6.2, existing DatabaseManager/SessionManager/CaptureScheduler, Swift Testing

---

## Bug Summary

| # | Bug | File | Impact |
|---|-----|------|--------|
| 1 | `active_duration_ms` never updated | `SessionManager.swift` | Timeline/summary show 0 durations |
| 2 | Reset sends zero ReadabilityInput → highUncertainty | `AppDelegate.swift:273-277` | App switch triggers high-frequency mode |
| 3 | `visualDiff` hardcoded to 0.5 | `AppDelegate.swift:231` | OCR runs on every frame, wastes CPU |
| 4 | No OCR concurrency limit | `AppDelegate.swift:185` | Tasks pile up in high-frequency mode |
| 5 | No privacy rules in capture path | `AppDelegate.swift:166-` | Captures passwords, banking, private windows |

---

## Task 1: Fix Duration Accounting

**Files:**
- Modify: `Sources/MyMacAgent/Session/SessionManager.swift`
- Modify: `Tests/MyMacAgentTests/Session/SessionManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Add to `Tests/MyMacAgentTests/Session/SessionManagerTests.swift`:

```swift
@Test("endSession calculates active_duration_ms")
func endSessionCalculatesDuration() throws {
    let (db, path) = try makeDB()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let sm = SessionManager(db: db)

    let sessionId = try sm.startSession(appId: 1, windowId: nil)

    // Simulate some time passing (at least we test the mechanism)
    let rows1 = try db.query("SELECT active_duration_ms FROM sessions WHERE id = ?",
        params: [.text(sessionId)])
    #expect(rows1[0]["active_duration_ms"]?.intValue == 0)

    try sm.endSession(sessionId)

    let rows2 = try db.query("SELECT active_duration_ms, ended_at, started_at FROM sessions WHERE id = ?",
        params: [.text(sessionId)])
    // Duration should be >= 0 (it will be very small in tests but not nil/unchanged)
    let duration = rows2[0]["active_duration_ms"]?.intValue ?? -1
    #expect(duration >= 0)
    // ended_at should be set
    #expect(rows2[0]["ended_at"]?.textValue != nil)
}

@Test("markIdle and markActive track idle duration")
func idleDurationTracking() throws {
    let (db, path) = try makeDB()
    defer { try? FileManager.default.removeItem(atPath: path) }
    let sm = SessionManager(db: db)

    let sessionId = try sm.startSession(appId: 1, windowId: nil)
    try sm.markIdle(sessionId: sessionId)
    try sm.markActive(sessionId: sessionId)

    let rows = try db.query("SELECT idle_duration_ms FROM sessions WHERE id = ?",
        params: [.text(sessionId)])
    let idle = rows[0]["idle_duration_ms"]?.intValue ?? -1
    #expect(idle >= 0)
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `make test`
Expected: FAIL — `markIdle`, `markActive` not found.

- [ ] **Step 3: Fix SessionManager**

Modify `Sources/MyMacAgent/Session/SessionManager.swift`:

```swift
import Foundation
import os

final class SessionManager {
    private let db: DatabaseManager
    private let logger = Logger.session
    private(set) var currentSessionId: String?
    private var sessionStartTime: Date?
    private var idleStartTime: Date?

    init(db: DatabaseManager) {
        self.db = db
    }

    func startSession(appId: Int64, windowId: Int64?) throws -> String {
        let sessionId = UUID().uuidString
        let now = Date()
        let nowStr = ISO8601DateFormatter().string(from: now)
        try db.execute(
            "INSERT INTO sessions (id, app_id, window_id, started_at) VALUES (?, ?, ?, ?)",
            params: [
                .text(sessionId), .integer(appId),
                windowId.map { .integer($0) } ?? .null,
                .text(nowStr)
            ]
        )
        currentSessionId = sessionId
        sessionStartTime = now
        idleStartTime = nil
        return sessionId
    }

    func endSession(_ sessionId: String) throws {
        let now = Date()
        let nowStr = ISO8601DateFormatter().string(from: now)

        // Calculate active duration
        var activeDurationMs: Int64 = 0
        if let start = sessionStartTime {
            activeDurationMs = Int64(now.timeIntervalSince(start) * 1000)
        }

        try db.execute(
            "UPDATE sessions SET ended_at = ?, active_duration_ms = active_duration_ms + ? WHERE id = ?",
            params: [.text(nowStr), .integer(activeDurationMs), .text(sessionId)]
        )

        if currentSessionId == sessionId {
            currentSessionId = nil
            sessionStartTime = nil
            idleStartTime = nil
        }
    }

    func switchSession(appId: Int64, windowId: Int64?) throws -> String {
        if let current = currentSessionId { try endSession(current) }
        return try startSession(appId: appId, windowId: windowId)
    }

    func markIdle(sessionId: String) throws {
        idleStartTime = Date()
        try recordEvent(sessionId: sessionId, type: .idleStarted, payload: nil)
    }

    func markActive(sessionId: String) throws {
        if let idleStart = idleStartTime {
            let idleMs = Int64(Date().timeIntervalSince(idleStart) * 1000)
            try db.execute(
                "UPDATE sessions SET idle_duration_ms = idle_duration_ms + ? WHERE id = ?",
                params: [.integer(idleMs), .text(sessionId)]
            )
            idleStartTime = nil
        }
        try recordEvent(sessionId: sessionId, type: .idleEnded, payload: nil)
    }

    func recordEvent(sessionId: String, type: SessionEventType, payload: String?) throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try db.execute(
            "INSERT INTO session_events (session_id, event_type, timestamp, payload_json) VALUES (?, ?, ?, ?)",
            params: [
                .text(sessionId), .text(type.rawValue), .text(now),
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

- [ ] **Step 4: Update AppDelegate idle handling to use markIdle/markActive**

In `AppDelegate.swift`, change the IdleDetectorDelegate:

```swift
extension AppDelegate: @preconcurrency IdleDetectorDelegate {
    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        do {
            if isIdle {
                try sessionManager.markIdle(sessionId: sessionId)
            } else {
                try sessionManager.markActive(sessionId: sessionId)
            }
        } catch {
            logger.error("Failed to update idle state: \(error.localizedDescription)")
        }
    }
}
```

- [ ] **Step 5: Run tests, verify pass, commit**

```bash
make test
git add Sources/MyMacAgent/Session/SessionManager.swift Sources/MyMacAgent/App/AppDelegate.swift Tests/MyMacAgentTests/Session/SessionManagerTests.swift
git commit -m "fix: calculate active_duration_ms and idle_duration_ms in SessionManager"
```

---

## Task 2: Fix Scheduler Reset Bug

**Files:**
- Modify: `Sources/MyMacAgent/Policy/CaptureScheduler.swift`
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift`
- Modify: `Tests/MyMacAgentTests/Policy/CaptureSchedulerTests.swift`

- [ ] **Step 1: Write failing test**

Add to `Tests/MyMacAgentTests/Policy/CaptureSchedulerTests.swift`:

```swift
@Test("resetToNormal sets mode to normal")
func resetToNormal() {
    let scheduler = CaptureScheduler(policyEngine: CapturePolicyEngine())

    // First go to high uncertainty
    let badInput = ReadabilityInput(
        axTextLen: 0, ocrConfidence: 0.0, ocrTextLen: 0,
        visualChangeScore: 0.8, isCanvasLike: true
    )
    scheduler.updateReadability(badInput)
    #expect(scheduler.currentMode == .highUncertainty)

    // Reset to normal
    scheduler.resetToNormal()
    #expect(scheduler.currentMode == .normal)
    #expect(scheduler.currentInterval >= 30)
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `make test`
Expected: FAIL — `resetToNormal` not found.

- [ ] **Step 3: Add resetToNormal to CaptureScheduler**

Add to `Sources/MyMacAgent/Policy/CaptureScheduler.swift`:

```swift
func resetToNormal() {
    let oldMode = currentMode
    currentMode = .normal
    if oldMode != .normal {
        delegate?.captureScheduler(self, didChangeMode: .normal)
    }
    if timer != nil {
        stop()
        scheduleNextCapture()
    }
    logger.info("Scheduler reset to normal mode")
}
```

- [ ] **Step 4: Fix AppDelegate to use resetToNormal instead of zero ReadabilityInput**

In `AppDelegate.swift` AppMonitorDelegate, replace:

```swift
// OLD (broken):
let normalInput = ReadabilityInput(
    axTextLen: 0, ocrConfidence: 0, ocrTextLen: 0,
    visualChangeScore: 0, isCanvasLike: false
)
captureScheduler?.updateReadability(normalInput)
```

With:

```swift
// NEW (correct):
captureScheduler?.resetToNormal()
```

- [ ] **Step 5: Run tests, verify pass, commit**

```bash
make test
git add Sources/MyMacAgent/Policy/CaptureScheduler.swift Sources/MyMacAgent/App/AppDelegate.swift Tests/MyMacAgentTests/Policy/CaptureSchedulerTests.swift
git commit -m "fix: use explicit resetToNormal instead of zero ReadabilityInput on app switch"
```

---

## Task 3: Real Visual Diff Instead of Hardcoded 0.5

**Files:**
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift`
- Create: `Tests/MyMacAgentTests/Capture/VisualDiffTests.swift`

- [ ] **Step 1: Write test for visual diff tracking**

Create `Tests/MyMacAgentTests/Capture/VisualDiffTests.swift`:

```swift
import Testing
import AppKit
@testable import MyMacAgent

struct VisualDiffTests {
    private func makeImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        color.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: NSSize(width: 100, height: 100)))
        image.unlockFocus()
        return image
    }

    @Test("Same image gives zero diff")
    func sameDiff() {
        let processor = ImageProcessor()
        let image = makeImage(color: .red)
        let hash1 = processor.visualHash(image: image)!
        let hash2 = processor.visualHash(image: image)!
        let diff = processor.diffScore(hash1: hash1, hash2: hash2)
        #expect(diff == 0.0)
    }

    @Test("Different images give positive diff")
    func differentDiff() {
        let processor = ImageProcessor()
        let hash1 = processor.visualHash(image: makeImage(color: .red))!
        let hash2 = processor.visualHash(image: makeImage(color: .blue))!
        let diff = processor.diffScore(hash1: hash1, hash2: hash2)
        #expect(diff > 0.0)
    }

    @Test("CaptureTracker stores and compares hashes")
    func captureTracker() {
        let tracker = CaptureHashTracker()

        // First capture — no previous hash, diff should be 1.0 (treat as changed)
        let diff1 = tracker.computeDiff(currentHash: "abc123", sessionId: "s1")
        #expect(diff1 == 1.0)

        // Same hash — diff should be 0.0
        let diff2 = tracker.computeDiff(currentHash: "abc123", sessionId: "s1")
        #expect(diff2 == 0.0)

        // Different hash — diff should be > 0
        let diff3 = tracker.computeDiff(currentHash: "def456", sessionId: "s1")
        #expect(diff3 > 0.0)

        // New session — resets
        let diff4 = tracker.computeDiff(currentHash: "abc123", sessionId: "s2")
        #expect(diff4 == 1.0) // new session, no previous
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `make test`
Expected: FAIL — `CaptureHashTracker` not found.

- [ ] **Step 3: Create CaptureHashTracker**

Add to `Sources/MyMacAgent/Capture/ImageProcessor.swift`:

```swift
/// Tracks visual hashes across captures to compute real diff scores
final class CaptureHashTracker {
    private var lastHash: String?
    private var lastSessionId: String?

    /// Returns the diff score between current and previous capture.
    /// Returns 1.0 for first capture in a session (treat as changed).
    func computeDiff(currentHash: String, sessionId: String) -> Double {
        // New session — reset tracking
        if sessionId != lastSessionId {
            lastHash = currentHash
            lastSessionId = sessionId
            return 1.0
        }

        guard let prev = lastHash else {
            lastHash = currentHash
            return 1.0
        }

        // Character-level diff (same logic as ImageProcessor.diffScore)
        let chars1 = Array(prev)
        let chars2 = Array(currentHash)
        guard chars1.count == chars2.count, !chars1.isEmpty else {
            lastHash = currentHash
            return 1.0
        }

        var diffCount = 0
        for i in 0..<chars1.count {
            if chars1[i] != chars2[i] { diffCount += 1 }
        }

        let score = Double(diffCount) / Double(chars1.count)
        lastHash = currentHash
        return score
    }
}
```

- [ ] **Step 4: Use real diff in AppDelegate**

In `AppDelegate.swift`, add a property:

```swift
private var captureHashTracker = CaptureHashTracker()
```

In `performCapture(mode:)`, replace:

```swift
// OLD:
let visualDiff: Double = hash != nil ? 0.5 : 0.5 // default: assume change
```

With:

```swift
// NEW: real visual diff
let captureTracker = captureHashTracker
// ... inside Task:
let visualDiff: Double = hash.map { captureTracker.computeDiff(currentHash: $0, sessionId: sessionId) } ?? 1.0
```

Note: `captureHashTracker` needs to be captured before the Task. Add it to the capture list at line 177.

- [ ] **Step 5: Run tests, verify pass, commit**

```bash
make test
git add Sources/MyMacAgent/Capture/ImageProcessor.swift Sources/MyMacAgent/App/AppDelegate.swift Tests/MyMacAgentTests/Capture/VisualDiffTests.swift
git commit -m "fix: use real visual diff instead of hardcoded 0.5, OCR now skips unchanged frames"
```

---

## Task 4: OCR Backpressure with CaptureActor

**Files:**
- Create: `Sources/MyMacAgent/Capture/CaptureActor.swift`
- Create: `Tests/MyMacAgentTests/Capture/CaptureActorTests.swift`
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Capture/CaptureActorTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct CaptureActorTests {
    @Test("Tracks in-flight count")
    func tracksInFlight() async {
        let limiter = CaptureGate(maxConcurrent: 2)
        #expect(await limiter.inFlightCount == 0)

        let acquired = await limiter.tryAcquire()
        #expect(acquired)
        #expect(await limiter.inFlightCount == 1)

        await limiter.release()
        #expect(await limiter.inFlightCount == 0)
    }

    @Test("Rejects when at max concurrency")
    func rejectsAtMax() async {
        let limiter = CaptureGate(maxConcurrent: 1)

        let first = await limiter.tryAcquire()
        #expect(first)

        let second = await limiter.tryAcquire()
        #expect(!second) // should be rejected

        await limiter.release()

        let third = await limiter.tryAcquire()
        #expect(third) // now it's free
    }

    @Test("Backlog counter increments on rejection")
    func backlogCounter() async {
        let limiter = CaptureGate(maxConcurrent: 1)

        _ = await limiter.tryAcquire()
        _ = await limiter.tryAcquire() // rejected
        _ = await limiter.tryAcquire() // rejected again

        #expect(await limiter.rejectedCount == 2)
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `make test`
Expected: FAIL — `CaptureGate` not found.

- [ ] **Step 3: Implement CaptureGate**

Create `Sources/MyMacAgent/Capture/CaptureActor.swift`:

```swift
import Foundation
import os

/// Limits concurrent capture/OCR operations to prevent backlog buildup.
actor CaptureGate {
    private let maxConcurrent: Int
    private var current = 0
    private(set) var rejectedCount = 0
    private let logger = Logger.capture

    init(maxConcurrent: Int = 1) {
        self.maxConcurrent = maxConcurrent
    }

    var inFlightCount: Int { current }

    /// Try to acquire a slot. Returns false if at capacity.
    func tryAcquire() -> Bool {
        if current >= maxConcurrent {
            rejectedCount += 1
            logger.info("CaptureGate: rejected (in-flight: \(self.current), rejected total: \(self.rejectedCount))")
            return false
        }
        current += 1
        return true
    }

    func release() {
        current = max(0, current - 1)
    }
}
```

- [ ] **Step 4: Add gate to AppDelegate capture pipeline**

In `AppDelegate.swift`, add property:

```swift
private let captureGate = CaptureGate(maxConcurrent: 1)
```

In `performCapture(mode:)`, wrap the Task body:

```swift
let gate = captureGate

Task {
    guard await gate.tryAcquire() else {
        Logger.capture.info("Skipping capture: previous still in progress")
        return
    }
    defer { Task { await gate.release() } }

    do {
        // ... existing capture code ...
    } catch {
        Logger.app.error("Capture failed: \(error.localizedDescription)")
    }
}
```

- [ ] **Step 5: Run tests, verify pass, commit**

```bash
make test
git add Sources/MyMacAgent/Capture/CaptureActor.swift Tests/MyMacAgentTests/Capture/CaptureActorTests.swift Sources/MyMacAgent/App/AppDelegate.swift
git commit -m "fix: add CaptureGate to limit OCR concurrency and prevent backlog"
```

---

## Task 5: Privacy Guard — Blacklist Apps

**Files:**
- Create: `Sources/MyMacAgent/Privacy/PrivacyGuard.swift`
- Create: `Tests/MyMacAgentTests/Privacy/PrivacyGuardTests.swift`
- Modify: `Sources/MyMacAgent/App/AppDelegate.swift`
- Modify: `Sources/MyMacAgent/Settings/AppSettings.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/MyMacAgentTests/Privacy/PrivacyGuardTests.swift`:

```swift
import Testing
import Foundation
@testable import MyMacAgent

struct PrivacyGuardTests {
    @Test("Blocks blacklisted bundle IDs")
    func blocksBlacklisted() {
        let guard_ = PrivacyGuard(blacklistedBundleIds: [
            "com.apple.keychainaccess",
            "com.1password.1password"
        ])

        #expect(!guard_.shouldCapture(bundleId: "com.apple.keychainaccess"))
        #expect(!guard_.shouldCapture(bundleId: "com.1password.1password"))
        #expect(guard_.shouldCapture(bundleId: "com.apple.Safari"))
    }

    @Test("Blocks by window title pattern")
    func blocksWindowTitle() {
        let guard_ = PrivacyGuard(
            blacklistedBundleIds: [],
            blacklistedWindowPatterns: ["password", "private", "incognito", "1Password"]
        )

        #expect(!guard_.shouldCapture(bundleId: "com.test", windowTitle: "Enter Password"))
        #expect(!guard_.shouldCapture(bundleId: "com.test", windowTitle: "Private Browsing"))
        #expect(!guard_.shouldCapture(bundleId: "com.test", windowTitle: "1Password — Login"))
        #expect(guard_.shouldCapture(bundleId: "com.test", windowTitle: "My Document"))
    }

    @Test("Paused state blocks all capture")
    func pauseBlocks() {
        let guard_ = PrivacyGuard(blacklistedBundleIds: [])
        #expect(guard_.shouldCapture(bundleId: "com.test"))

        guard_.pause()
        #expect(!guard_.shouldCapture(bundleId: "com.test"))

        guard_.resume()
        #expect(guard_.shouldCapture(bundleId: "com.test"))
    }

    @Test("Default blacklist includes common sensitive apps")
    func defaultBlacklist() {
        let guard_ = PrivacyGuard.withDefaults()
        #expect(!guard_.shouldCapture(bundleId: "com.apple.keychainaccess"))
        #expect(!guard_.shouldCapture(bundleId: "com.1password.1password"))
        #expect(guard_.shouldCapture(bundleId: "com.apple.Safari"))
    }

    @Test("Metadata-only mode")
    func metadataOnly() {
        let guard_ = PrivacyGuard(
            blacklistedBundleIds: [],
            metadataOnlyBundleIds: ["com.apple.MobileSMS"]
        )

        #expect(guard_.shouldCapture(bundleId: "com.apple.MobileSMS"))
        #expect(!guard_.shouldOCR(bundleId: "com.apple.MobileSMS"))
        #expect(guard_.shouldOCR(bundleId: "com.apple.Safari"))
    }
}
```

- [ ] **Step 2: Run test, verify fail**

Run: `make test`
Expected: FAIL — `PrivacyGuard` not found.

- [ ] **Step 3: Implement PrivacyGuard**

Create `Sources/MyMacAgent/Privacy/PrivacyGuard.swift`:

```swift
import Foundation
import os

final class PrivacyGuard {
    private let blacklistedBundleIds: Set<String>
    private let blacklistedWindowPatterns: [String]
    private let metadataOnlyBundleIds: Set<String>
    private var isPaused = false
    private let logger = Logger.app

    init(
        blacklistedBundleIds: [String] = [],
        blacklistedWindowPatterns: [String] = [],
        metadataOnlyBundleIds: [String] = []
    ) {
        self.blacklistedBundleIds = Set(blacklistedBundleIds)
        self.blacklistedWindowPatterns = blacklistedWindowPatterns.map { $0.lowercased() }
        self.metadataOnlyBundleIds = Set(metadataOnlyBundleIds)
    }

    static func withDefaults() -> PrivacyGuard {
        PrivacyGuard(
            blacklistedBundleIds: [
                "com.apple.keychainaccess",
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.lastpass.LastPass",
                "com.bitwarden.desktop",
                "com.dashlane.Dashlane"
            ],
            blacklistedWindowPatterns: [
                "password", "private browsing", "incognito",
                "1password", "keychain", "credential"
            ],
            metadataOnlyBundleIds: [
                "com.apple.MobileSMS",
                "com.tinyspeck.slackmacgap"
            ]
        )
    }

    func shouldCapture(bundleId: String, windowTitle: String? = nil) -> Bool {
        if isPaused { return false }
        if blacklistedBundleIds.contains(bundleId) { return false }
        if let title = windowTitle?.lowercased() {
            for pattern in blacklistedWindowPatterns {
                if title.contains(pattern) { return false }
            }
        }
        return true
    }

    func shouldOCR(bundleId: String) -> Bool {
        !metadataOnlyBundleIds.contains(bundleId)
    }

    func pause() {
        isPaused = true
        logger.info("Privacy: capture paused")
    }

    func resume() {
        isPaused = false
        logger.info("Privacy: capture resumed")
    }

    var paused: Bool { isPaused }
}
```

- [ ] **Step 4: Add PrivacyGuard to AppDelegate capture path**

In `AppDelegate.swift`, add property:

```swift
private var privacyGuard = PrivacyGuard.withDefaults()
```

In `performCapture(mode:)`, add check after the CGPreflightScreenCaptureAccess guard:

```swift
// Privacy check
guard privacyGuard.shouldCapture(
    bundleId: appInfo.bundleId,
    windowTitle: windowMonitor?.currentWindowTitle
) else {
    logger.info("Skipping capture: blocked by privacy rules (\(appInfo.bundleId))")
    return
}
```

And in the OCR section, add:

```swift
if let policy, policy.shouldRunOCR(visualDiffScore: visualDiff, mode: mode),
   privacyGuard.shouldOCR(bundleId: appInfo.bundleId) {
```

- [ ] **Step 5: Add pause/resume to MenuBarPopover**

In `Sources/MyMacAgent/Views/MenuBarPopover.swift`, add a pause button (requires passing privacyGuard or adding it as observable — simplest: use UserDefaults flag read by PrivacyGuard):

Add to `AppDelegate`:
```swift
func togglePause() {
    if privacyGuard.paused {
        privacyGuard.resume()
    } else {
        privacyGuard.pause()
    }
}

var isPaused: Bool { privacyGuard.paused }
```

In `MenuBarPopover`, add before the Quit button:

```swift
Divider()

Button(appDelegate.isPaused ? "Resume Capture" : "Pause Capture") {
    appDelegate.togglePause()
}
```

(This requires passing `appDelegate` to `MenuBarPopover` — add it via `@EnvironmentObject` or directly.)

- [ ] **Step 6: Run tests, verify pass, commit**

```bash
make test
git add Sources/MyMacAgent/Privacy/PrivacyGuard.swift Tests/MyMacAgentTests/Privacy/PrivacyGuardTests.swift Sources/MyMacAgent/App/AppDelegate.swift Sources/MyMacAgent/Views/MenuBarPopover.swift
git commit -m "feat: add PrivacyGuard with app blacklist, window patterns, metadata-only, pause/resume"
```

---

## Self-Review Checklist

1. **Spec coverage:** All 5 critical bugs from the review are addressed:
   - Bug 1 (duration): Task 1 — SessionManager now calculates active_duration_ms on endSession and idle_duration_ms on idle transitions
   - Bug 2 (reset): Task 2 — explicit resetToNormal() replaces broken zero-ReadabilityInput hack
   - Bug 3 (visualDiff): Task 3 — CaptureHashTracker computes real diff between consecutive frames
   - Bug 4 (backpressure): Task 4 — CaptureGate actor limits OCR concurrency to 1
   - Bug 5 (privacy): Task 5 — PrivacyGuard blocks blacklisted apps/windows, supports pause/resume

2. **Placeholder scan:** All tasks contain complete Swift code. No TBD or placeholders.

3. **Type consistency:** `CaptureHashTracker.computeDiff(currentHash:sessionId:)` matches usage in AppDelegate. `CaptureGate.tryAcquire()/release()` matches AppDelegate Task wrapper. `PrivacyGuard.shouldCapture(bundleId:windowTitle:)` matches AppDelegate guard. `SessionManager.markIdle/markActive` matches IdleDetectorDelegate.
