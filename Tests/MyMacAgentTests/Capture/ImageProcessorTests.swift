import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct ImageProcessorTests {
    private func makeTestImage(color: NSColor, size: NSSize = NSSize(width: 100, height: 100)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    @Test("Creates thumbnail within max dimension")
    func createThumbnail() {
        let image = makeTestImage(color: .blue, size: NSSize(width: 1920, height: 1080))
        let processor = ImageProcessor()

        let thumb = processor.createThumbnail(image: image, maxDimension: 200)

        #expect(thumb != nil)
        #expect(thumb!.size.width <= 200)
        #expect(thumb!.size.height <= 200)
    }

    @Test("Visual hash is deterministic")
    func visualHashDeterministic() {
        let image = makeTestImage(color: .red)
        let processor = ImageProcessor()

        let hash1 = processor.visualHash(image: image)
        let hash2 = processor.visualHash(image: image)

        #expect(hash1 != nil)
        #expect(hash1 == hash2)
    }

    @Test("Visual hash differs for different images")
    func visualHashDiffers() {
        let processor = ImageProcessor()

        let hash1 = processor.visualHash(image: makeTestImage(color: .red))
        let hash2 = processor.visualHash(image: makeTestImage(color: .blue))

        #expect(hash1 != hash2)
    }

    @Test("Diff score is zero for same image")
    func diffScoreSame() {
        let image = makeTestImage(color: .green)
        let processor = ImageProcessor()

        let hash = processor.visualHash(image: image)!
        let score = processor.diffScore(hash1: hash, hash2: hash)

        #expect(score == 0.0)
    }

    @Test("Diff score is positive for different images")
    func diffScoreDifferent() {
        let processor = ImageProcessor()
        let hash1 = processor.visualHash(image: makeTestImage(color: .red))!
        let hash2 = processor.visualHash(image: makeTestImage(color: .blue))!

        let score = processor.diffScore(hash1: hash1, hash2: hash2)
        #expect(score > 0.0)
    }
}
