import Testing
@testable import MyMacAgent

struct ReadabilityScorerTests {

    // 1. High score (>0.7) when AX + OCR both good
    @Test("High score when AX and OCR both good")
    func highScoreWithGoodAXAndOCR() {
        let input = ReadabilityInput(
            axTextLen: 100,
            ocrConfidence: 0.95,
            ocrTextLen: 80,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        let result = ReadabilityScorer.score(input)
        #expect(result > 0.7)
    }

    // 2. Low score (<0.3) when no text, canvas-like
    @Test("Low score when no text and canvas-like")
    func lowScoreWithNoTextAndCanvasLike() {
        let input = ReadabilityInput(
            axTextLen: 0,
            ocrConfidence: 0.0,
            ocrTextLen: 0,
            visualChangeScore: 0.0,
            isCanvasLike: true
        )
        let result = ReadabilityScorer.score(input)
        #expect(result < 0.3)
    }

    // 3. Medium score (0.3-0.7) AX only
    @Test("Medium score with AX text only")
    func mediumScoreWithAXOnly() {
        let input = ReadabilityInput(
            axTextLen: 30,
            ocrConfidence: 0.0,
            ocrTextLen: 0,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        let result = ReadabilityScorer.score(input)
        #expect(result >= 0.3)
        #expect(result <= 0.7)
    }

    // 4. Medium score (0.3-0.7) OCR only
    @Test("Medium score with OCR only")
    func mediumScoreWithOCROnly() {
        let input = ReadabilityInput(
            axTextLen: 0,
            ocrConfidence: 0.75,
            ocrTextLen: 40,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        let result = ReadabilityScorer.score(input)
        #expect(result >= 0.3)
        #expect(result <= 0.7)
    }

    // 5. Canvas reduces score
    @Test("Canvas-like flag reduces score")
    func canvasReducesScore() {
        let base = ReadabilityInput(
            axTextLen: 50,
            ocrConfidence: 0.8,
            ocrTextLen: 50,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        let canvas = ReadabilityInput(
            axTextLen: 50,
            ocrConfidence: 0.8,
            ocrTextLen: 50,
            visualChangeScore: 0.0,
            isCanvasLike: true
        )
        let baseScore = ReadabilityScorer.score(base)
        let canvasScore = ReadabilityScorer.score(canvas)
        #expect(canvasScore < baseScore)
    }

    // 6. Frequent visual changes reduce score
    @Test("High visual change score reduces readability score")
    func visualChangesReduceScore() {
        let stable = ReadabilityInput(
            axTextLen: 50,
            ocrConfidence: 0.8,
            ocrTextLen: 50,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        let volatile = ReadabilityInput(
            axTextLen: 50,
            ocrConfidence: 0.8,
            ocrTextLen: 50,
            visualChangeScore: 0.9,
            isCanvasLike: false
        )
        let stableScore = ReadabilityScorer.score(stable)
        let volatileScore = ReadabilityScorer.score(volatile)
        #expect(volatileScore < stableScore)
    }

    // 7. Score clamped to 0.0-1.0
    @Test("Score is always clamped between 0.0 and 1.0")
    func scoreIsClamped() {
        // Try to push score below 0
        let veryLow = ReadabilityInput(
            axTextLen: 0,
            ocrConfidence: 0.0,
            ocrTextLen: 0,
            visualChangeScore: 1.0,
            isCanvasLike: true
        )
        // Try to push score above 1
        let veryHigh = ReadabilityInput(
            axTextLen: 1000,
            ocrConfidence: 1.0,
            ocrTextLen: 1000,
            visualChangeScore: 0.0,
            isCanvasLike: false
        )
        let low = ReadabilityScorer.score(veryLow)
        let high = ReadabilityScorer.score(veryHigh)
        #expect(low >= 0.0)
        #expect(high <= 1.0)
    }

    // 8. classifyMode returns correct UncertaintyMode
    @Test("classifyMode returns correct mode for score ranges")
    func classifyModeReturnsCorrectMode() {
        #expect(ReadabilityScorer.classifyMode(score: 0.8) == .normal)
        #expect(ReadabilityScorer.classifyMode(score: 0.71) == .normal)
        #expect(ReadabilityScorer.classifyMode(score: 0.5) == .degraded)
        #expect(ReadabilityScorer.classifyMode(score: 0.3) == .degraded)
        #expect(ReadabilityScorer.classifyMode(score: 0.2) == .highUncertainty)
        #expect(ReadabilityScorer.classifyMode(score: 0.0) == .highUncertainty)
    }
}
