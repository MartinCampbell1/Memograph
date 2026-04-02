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
