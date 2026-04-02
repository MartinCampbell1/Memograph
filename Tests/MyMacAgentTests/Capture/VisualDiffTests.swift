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
