import Foundation
import CoreGraphics
import os

protocol IdleDetectorDelegate: AnyObject {
    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool)
}

final class IdleDetector {
    weak var delegate: IdleDetectorDelegate?
    let idleThreshold: TimeInterval
    private let logger = Logger.monitor
    private var pollTimer: Timer?
    private var wasIdle = false

    init(idleThreshold: TimeInterval = 120) {
        self.idleThreshold = idleThreshold
    }

    var currentIdleTime: TimeInterval {
        CGEventSource.secondsSinceLastEventType(
            .hidSystemState,
            eventType: CGEventType(rawValue: UInt32.max)!
        )
    }

    var isIdle: Bool {
        currentIdleTime >= idleThreshold
    }

    func start() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkIdle()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func checkIdle() {
        let idle = isIdle
        if idle != wasIdle {
            wasIdle = idle
            delegate?.idleDetector(self, didChangeIdleState: idle)
        }
    }
}
