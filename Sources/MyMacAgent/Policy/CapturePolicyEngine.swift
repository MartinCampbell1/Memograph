import Foundation
import os

struct CaptureDecision {
    let mode: UncertaintyMode
    let shouldCapture: Bool
    let shouldOCR: Bool
    let shouldAX: Bool
    let interval: TimeInterval
}

final class CapturePolicyEngine {
    private let logger = Logger.policy

    func captureInterval(for mode: UncertaintyMode) -> TimeInterval {
        let settings = AppSettings()
        switch mode {
        case .normal: return settings.normalCaptureIntervalSeconds
        case .degraded: return settings.degradedCaptureIntervalSeconds
        case .highUncertainty: return settings.highUncertaintyCaptureIntervalSeconds
        case .recovery: return settings.degradedCaptureIntervalSeconds
        }
    }

    func evaluatePolicy(readability: ReadabilityInput, previousMode: UncertaintyMode) -> CaptureDecision {
        let readabilityScore = ReadabilityScorer.score(readability)
        var newMode = ReadabilityScorer.classifyMode(score: readabilityScore)

        if previousMode == .highUncertainty && newMode == .normal {
            newMode = .recovery
        }
        if previousMode == .recovery && newMode == .highUncertainty {
            newMode = .highUncertainty
        }

        let interval = captureInterval(for: newMode)

        return CaptureDecision(
            mode: newMode,
            shouldCapture: true,
            shouldOCR: newMode != .normal || readability.ocrTextLen == 0,
            shouldAX: true,
            interval: interval
        )
    }

    func shouldRunOCR(visualDiffScore: Double, mode: UncertaintyMode) -> Bool {
        switch mode {
        case .highUncertainty: return true
        case .degraded: return visualDiffScore > 0.05
        case .normal, .recovery: return visualDiffScore > 0.1
        }
    }

    func shouldRetainCapture(visualDiffScore: Double, mode: UncertaintyMode) -> Bool {
        switch mode {
        case .highUncertainty: return true
        case .degraded: return visualDiffScore > 0.05
        case .normal, .recovery: return visualDiffScore > 0.1
        }
    }
}
