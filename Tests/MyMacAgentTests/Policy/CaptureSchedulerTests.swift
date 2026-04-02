import Testing
@testable import MyMacAgent

// MARK: - Mock

final class MockCaptureSchedulerDelegate: CaptureSchedulerDelegate {
    private(set) var capturedModes: [UncertaintyMode] = []
    private(set) var changedModes: [UncertaintyMode] = []

    func captureScheduler(_ scheduler: CaptureScheduler, shouldCaptureWithMode mode: UncertaintyMode) {
        capturedModes.append(mode)
    }

    func captureScheduler(_ scheduler: CaptureScheduler, didChangeMode mode: UncertaintyMode) {
        changedModes.append(mode)
    }
}

// MARK: - Tests

struct CaptureSchedulerTests {

    // 1. Initializes with normal mode
    @Test("Initializes with normal mode")
    func initializesWithNormalMode() {
        let engine = CapturePolicyEngine()
        let scheduler = CaptureScheduler(policyEngine: engine)
        #expect(scheduler.currentMode == .normal)
    }

    // 2. updateReadability changes mode (bad input → highUncertainty)
    @Test("updateReadability changes mode on bad readability input")
    func updateReadabilityChangesModeToHighUncertainty() {
        let engine = CapturePolicyEngine()
        let scheduler = CaptureScheduler(policyEngine: engine)
        let delegate = MockCaptureSchedulerDelegate()
        scheduler.delegate = delegate

        // Bad input: no text, canvas-like, high visual change → score < 0.3 → highUncertainty
        let badInput = ReadabilityInput(
            axTextLen: 0,
            ocrConfidence: 0.0,
            ocrTextLen: 0,
            visualChangeScore: 1.0,
            isCanvasLike: true
        )
        scheduler.updateReadability(badInput)

        #expect(scheduler.currentMode == .highUncertainty)
        #expect(delegate.changedModes.contains(.highUncertainty))
    }

    // 3. currentInterval matches mode (normal → >=30, highUncertainty → 3)
    @Test("currentInterval reflects current mode")
    func currentIntervalMatchesMode() {
        let engine = CapturePolicyEngine()
        let scheduler = CaptureScheduler(policyEngine: engine)

        // Normal mode interval should be >= 30
        #expect(scheduler.currentMode == .normal)
        #expect(scheduler.currentInterval >= 30)

        // Switch to highUncertainty
        let badInput = ReadabilityInput(
            axTextLen: 0,
            ocrConfidence: 0.0,
            ocrTextLen: 0,
            visualChangeScore: 1.0,
            isCanvasLike: true
        )
        scheduler.updateReadability(badInput)

        #expect(scheduler.currentMode == .highUncertainty)
        #expect(scheduler.currentInterval == 3)
    }

    // 4. Recovery mode when readability improves from highUncertainty
    @Test("Recovery mode when readability improves from highUncertainty")
    func recoveryModeWhenReadabilityImproves() {
        let engine = CapturePolicyEngine()
        let scheduler = CaptureScheduler(policyEngine: engine)
        let delegate = MockCaptureSchedulerDelegate()
        scheduler.delegate = delegate

        // First, push to highUncertainty
        let badInput = ReadabilityInput(
            axTextLen: 0,
            ocrConfidence: 0.0,
            ocrTextLen: 0,
            visualChangeScore: 1.0,
            isCanvasLike: true
        )
        scheduler.updateReadability(badInput)
        #expect(scheduler.currentMode == .highUncertainty)

        // Now improve readability — score > 0.7 → normally .normal,
        // but since previousMode == .highUncertainty, engine maps it to .recovery
        let goodInput = ReadabilityInput(
            axTextLen: 100,
            ocrConfidence: 0.95,
            ocrTextLen: 80,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        scheduler.updateReadability(goodInput)

        #expect(scheduler.currentMode == .recovery)
        #expect(delegate.changedModes.contains(.recovery))
    }
}
