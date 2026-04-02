import Testing
@testable import MyMacAgent

struct CapturePolicyEngineTests {

    // 1. Normal mode interval is 60 (within 30-90)
    @Test("Normal mode interval is 60")
    func normalModeInterval() {
        let engine = CapturePolicyEngine()
        let interval = engine.captureInterval(for: .normal)
        #expect(interval >= 30)
        #expect(interval <= 90)
        #expect(interval == 60)
    }

    // 2. Degraded mode interval is 10 (within 8-15)
    @Test("Degraded mode interval is 10")
    func degradedModeInterval() {
        let engine = CapturePolicyEngine()
        let interval = engine.captureInterval(for: .degraded)
        #expect(interval >= 8)
        #expect(interval <= 15)
        #expect(interval == 10)
    }

    // 3. High uncertainty interval == 3
    @Test("High uncertainty mode interval is 3")
    func highUncertaintyInterval() {
        let engine = CapturePolicyEngine()
        let interval = engine.captureInterval(for: .highUncertainty)
        #expect(interval == 3)
    }

    // 4. Recovery interval is 10 (within 8-15)
    @Test("Recovery mode interval is 10")
    func recoveryModeInterval() {
        let engine = CapturePolicyEngine()
        let interval = engine.captureInterval(for: .recovery)
        #expect(interval >= 8)
        #expect(interval <= 15)
        #expect(interval == 10)
    }

    // 5. evaluatePolicy returns correct mode based on readability
    @Test("evaluatePolicy returns correct mode based on readability score")
    func evaluatePolicyReturnsCorrectMode() {
        let engine = CapturePolicyEngine()

        // High readability → normal mode
        let highReadability = ReadabilityInput(
            axTextLen: 100,
            ocrConfidence: 0.95,
            ocrTextLen: 80,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        let normalDecision = engine.evaluatePolicy(readability: highReadability, previousMode: .normal)
        #expect(normalDecision.mode == .normal)
        #expect(normalDecision.shouldCapture == true)
        #expect(normalDecision.shouldAX == true)
        #expect(normalDecision.interval == 60)

        // Low readability → highUncertainty mode
        let lowReadability = ReadabilityInput(
            axTextLen: 0,
            ocrConfidence: 0.0,
            ocrTextLen: 0,
            visualChangeScore: 0.0,
            isCanvasLike: true
        )
        let highUncertaintyDecision = engine.evaluatePolicy(readability: lowReadability, previousMode: .normal)
        #expect(highUncertaintyDecision.mode == .highUncertainty)
        #expect(highUncertaintyDecision.interval == 3)
    }

    // 6. Recovery transition when readability improves from highUncertainty
    @Test("Recovery transition when readability improves from highUncertainty")
    func recoveryTransitionFromHighUncertainty() {
        let engine = CapturePolicyEngine()

        // Good readability but coming from highUncertainty → should become recovery, not normal
        let goodReadability = ReadabilityInput(
            axTextLen: 100,
            ocrConfidence: 0.95,
            ocrTextLen: 80,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        let decision = engine.evaluatePolicy(readability: goodReadability, previousMode: .highUncertainty)
        #expect(decision.mode == .recovery)
        #expect(decision.interval == 10)
    }

    // 7. shouldRunOCR: true for high diff or high-uncertainty mode, false for low diff + normal mode
    @Test("shouldRunOCR returns true for high diff or high-uncertainty, false for low diff + normal")
    func shouldRunOCRLogic() {
        let engine = CapturePolicyEngine()

        // High uncertainty always true regardless of diff
        #expect(engine.shouldRunOCR(visualDiffScore: 0.0, mode: .highUncertainty) == true)
        #expect(engine.shouldRunOCR(visualDiffScore: 0.01, mode: .highUncertainty) == true)

        // Degraded: threshold 0.05
        #expect(engine.shouldRunOCR(visualDiffScore: 0.06, mode: .degraded) == true)
        #expect(engine.shouldRunOCR(visualDiffScore: 0.04, mode: .degraded) == false)

        // Normal: threshold 0.1
        #expect(engine.shouldRunOCR(visualDiffScore: 0.15, mode: .normal) == true)
        #expect(engine.shouldRunOCR(visualDiffScore: 0.05, mode: .normal) == false)

        // Recovery: threshold 0.1
        #expect(engine.shouldRunOCR(visualDiffScore: 0.15, mode: .recovery) == true)
        #expect(engine.shouldRunOCR(visualDiffScore: 0.05, mode: .recovery) == false)
    }

    // 8. shouldRetainCapture: similar logic to shouldRunOCR
    @Test("shouldRetainCapture returns true for high diff or high-uncertainty, false for low diff + normal")
    func shouldRetainCaptureLogic() {
        let engine = CapturePolicyEngine()

        // High uncertainty always true regardless of diff
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.0, mode: .highUncertainty) == true)
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.01, mode: .highUncertainty) == true)

        // Degraded: threshold 0.05
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.06, mode: .degraded) == true)
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.04, mode: .degraded) == false)

        // Normal: threshold 0.1
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.15, mode: .normal) == true)
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.05, mode: .normal) == false)

        // Recovery: threshold 0.1
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.15, mode: .recovery) == true)
        #expect(engine.shouldRetainCapture(visualDiffScore: 0.05, mode: .recovery) == false)
    }
}
