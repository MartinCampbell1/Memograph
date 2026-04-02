import AppKit
@preconcurrency import ScreenCaptureKit
import os

struct CaptureResult: @unchecked Sendable {
    let image: NSImage
    let width: Int
    let height: Int
    let timestamp: Date
}

final class ScreenCaptureEngine: Sendable {
    nonisolated(unsafe) private let logger = Logger.capture

    func captureWindow(pid: pid_t) async throws -> CaptureResult {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let window = content.windows.first(where: {
            $0.owningApplication?.processID == pid && $0.isOnScreen
        }) else {
            throw CaptureError.windowNotFound
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2
        config.height = Int(window.frame.height) * 2
        config.showsCursor = false

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let width = Int(window.frame.width)
        let height = Int(window.frame.height)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))

        return CaptureResult(
            image: nsImage,
            width: width,
            height: height,
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

        let width = Int(display.width)
        let height = Int(display.height)
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))

        return CaptureResult(
            image: nsImage,
            width: width,
            height: height,
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
