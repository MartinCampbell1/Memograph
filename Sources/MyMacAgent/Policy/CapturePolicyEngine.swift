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
        switch mode {
        case .normal: return 60
        case .degraded: return 10
        case .highUncertainty: return 3
        case .recovery: return 10
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
