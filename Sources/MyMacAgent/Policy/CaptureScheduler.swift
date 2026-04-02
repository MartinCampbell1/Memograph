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
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func updateReadability(_ input: ReadabilityInput) {
        let decision = policyEngine.evaluatePolicy(readability: input, previousMode: currentMode)
        if decision.mode != currentMode {
            currentMode = decision.mode
            delegate?.captureScheduler(self, didChangeMode: currentMode)
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
