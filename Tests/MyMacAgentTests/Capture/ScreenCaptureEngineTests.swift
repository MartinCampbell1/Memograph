import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct ScreenCaptureEngineTests {
    @Test("CaptureResult has expected properties")
    func captureResultProperties() {
        let result = CaptureResult(
            image: NSImage(size: NSSize(width: 100, height: 100)),
            width: 100,
            height: 100,
            timestamp: Date()
        )
        #expect(result.width == 100)
        #expect(result.height == 100)
    }

    @Test("Save capture to disk creates file")
    func saveToDisk() throws {
        let tmpDir = NSTemporaryDirectory() + "capture_test_\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }

        let engine = ScreenCaptureEngine()

        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.red.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 100, height: 100))
        image.unlockFocus()

        let result = CaptureResult(image: image, width: 100, height: 100, timestamp: Date())
        let path = try engine.saveToDisk(result: result, directory: tmpDir, quality: 0.7)

        #expect(FileManager.default.fileExists(atPath: path))
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count > 0)
    }
}
