import AppKit
import Vision
import os

struct OCRResult {
    let rawText: String
    let confidence: Double
    let language: String?
    let processingMs: Int
}

protocol OCRProvider {
    var name: String { get }
    func recognizeText(in image: NSImage) async throws -> OCRResult
}

final class VisionOCRProvider: OCRProvider {
    let name = "vision"
    nonisolated(unsafe) private let logger = Logger.ocr

    func recognizeText(in image: NSImage) async throws -> OCRResult {
        let startTime = DispatchTime.now()

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return OCRResult(rawText: "", confidence: 0, language: nil, processingMs: 0)
        }

        // Perform all Vision work inside the detached task so that
        // VNImageRequestHandler and VNRecognizeTextRequest never cross
        // isolation boundaries — we only send back the final value type.
        let result: OCRResult = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en", "ru"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            guard let observations = request.results else {
                let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)
                return OCRResult(rawText: "", confidence: 0, language: nil, processingMs: elapsed)
            }

            var lines: [String] = []
            var totalConfidence: Double = 0

            for observation in observations {
                guard let candidate = observation.topCandidates(1).first else { continue }
                lines.append(candidate.string)
                totalConfidence += Double(observation.confidence)
            }

            let rawText = lines.joined(separator: "\n")
            let avgConfidence = observations.isEmpty ? 0 : totalConfidence / Double(observations.count)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000)

            return OCRResult(rawText: rawText, confidence: avgConfidence, language: nil, processingMs: elapsed)
        }.value

        return result
    }
}
