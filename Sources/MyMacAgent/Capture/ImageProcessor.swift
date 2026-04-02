import AppKit
import CryptoKit
import os

enum ImageProcessorError: Error {
    case thumbnailFailed
    case compressionFailed
}

final class ImageProcessor {
    private let logger = Logger.capture

    func createThumbnail(image: NSImage, maxDimension: CGFloat = 200) -> NSImage? {
        let originalSize = image.size
        let scale: CGFloat = if originalSize.width > originalSize.height {
            maxDimension / originalSize.width
        } else {
            maxDimension / originalSize.height
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
            throw ImageProcessorError.compressionFailed
        }

        let path = (directory as NSString).appendingPathComponent("thumb_" + filename)
        try jpegData.write(to: URL(fileURLWithPath: path))
        return path
    }
}

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
