import Foundation

struct ReadabilityInput {
    let axTextLen: Int
    let ocrConfidence: Double
    let ocrTextLen: Int
    let visualChangeScore: Double
    let isCanvasLike: Bool
}

enum ReadabilityScorer {
    static func score(_ input: ReadabilityInput) -> Double {
        var score = 0.0
        if input.axTextLen > 0 {
            let axFactor = min(Double(input.axTextLen) / 50.0, 1.0)
            score += 0.4 * axFactor
        }
        if input.ocrConfidence > 0.3 {
            score += 0.4 * input.ocrConfidence
        }
        let totalTextLen = input.axTextLen + input.ocrTextLen
        if totalTextLen > 20 {
            let textFactor = min(Double(totalTextLen) / 100.0, 1.0)
            score += 0.2 * textFactor
        }
        if input.visualChangeScore > 0.3 {
            score -= 0.3 * input.visualChangeScore
        }
        if input.isCanvasLike {
            score -= 0.2
        }
        return max(0.0, min(1.0, score))
    }

    static func classifyMode(score: Double) -> UncertaintyMode {
        if score > 0.7 { return .normal }
        else if score >= 0.3 { return .degraded }
        else { return .highUncertainty }
    }
}
