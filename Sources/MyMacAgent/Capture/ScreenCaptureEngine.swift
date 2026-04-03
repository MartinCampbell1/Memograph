import AppKit
import CoreGraphics
import Foundation
import os

struct CaptureResult: @unchecked Sendable {
    let image: NSImage
    let width: Int
    let height: Int
    let timestamp: Date
}

final class ScreenCaptureEngine: Sendable {
    private let logger = Logger.capture

    func captureWindow(pid: pid_t) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureError.windowNotFound
        }
        guard let window = frontmostWindow(for: pid) else {
            throw CaptureError.windowNotFound
        }
        let result = try captureViaScreencapture(arguments: ["-x", "-o", "-l", String(window.windowID)])

        return CaptureResult(
            image: result.image,
            width: result.width,
            height: result.height,
            timestamp: Date()
        )
    }

    func captureScreen() async throws -> CaptureResult {
        let result = try captureViaScreencapture(arguments: ["-x"])

        return CaptureResult(
            image: result.image,
            width: result.width,
            height: result.height,
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

    private func frontmostWindow(for pid: pid_t) -> (windowID: CGWindowID, bounds: CGRect)? {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else {
            return nil
        }

        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let windowNumber = info[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 1,
                  bounds.height > 1 else {
                continue
            }

            return (CGWindowID(windowNumber), bounds)
        }

        logger.info("Capture: no suitable on-screen window found for pid \(pid)")
        return nil
    }

    private func captureViaScreencapture(arguments: [String]) throws -> (image: NSImage, width: Int, height: Int) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments + [outputURL.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw CaptureError.windowNotFound
        }

        guard process.terminationStatus == 0,
              let image = NSImage(contentsOf: outputURL) else {
            try? FileManager.default.removeItem(at: outputURL)
            throw CaptureError.windowNotFound
        }

        defer { try? FileManager.default.removeItem(at: outputURL) }

        let width = Int(image.size.width)
        let height = Int(image.size.height)
        return (image, width, height)
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
