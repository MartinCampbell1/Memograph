import AppKit
import Foundation
import os

final class OllamaOCRProvider: OCRProvider {
    let name = "ollama"
    private let modelName: String
    private let baseURL: String
    private let logger = Logger.ocr

    init(modelName: String = "glm-ocr", baseURL: String = "http://localhost:11434") {
        self.modelName = modelName
        self.baseURL = baseURL
    }

    func recognizeText(in image: NSImage) async throws -> OCRResult {
        let startTime = DispatchTime.now()

        guard let base64Image = imageToBase64(image) else {
            return OCRResult(rawText: "", confidence: 0, language: nil, processingMs: 0)
        }

        let payload: [String: Any] = [
            "model": modelName,
            "prompt": "Extract ALL text visible in this image. Include code, labels, numbers, UI elements, and any other text. Output the raw text only, no descriptions or commentary.",
            "images": [base64Image],
            "stream": false
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)

        guard let endpointURL = URL(string: "\(baseURL)/api/generate") else {
            let elapsed = elapsed(from: startTime)
            logger.error("Ollama OCR: invalid base URL '\(self.baseURL)'")
            return OCRResult(rawText: "", confidence: 0, language: nil, processingMs: elapsed)
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let elapsed = elapsed(from: startTime)
            logger.error("Ollama OCR failed: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            return OCRResult(rawText: "", confidence: 0, language: nil, processingMs: elapsed)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseText = json["response"] as? String else {
            let elapsed = elapsed(from: startTime)
            return OCRResult(rawText: "", confidence: 0, language: nil, processingMs: elapsed)
        }

        let elapsedMs = elapsed(from: startTime)

        // Estimate confidence based on response length
        let confidence: Double = responseText.count > 10 ? 0.8 : (responseText.isEmpty ? 0.0 : 0.3)

        logger.info("Ollama OCR: model=\(self.modelName), \(responseText.count) chars, \(elapsedMs)ms")

        return OCRResult(
            rawText: responseText,
            confidence: confidence,
            language: nil,
            processingMs: elapsedMs
        )
    }

    /// Check if Ollama is running and the configured model is available.
    func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let models = json["models"] as? [[String: Any]] {
                return models.contains { ($0["name"] as? String)?.hasPrefix(modelName) == true }
            }
            return false
        } catch {
            return false
        }
    }

    // MARK: - Private

    private func imageToBase64(_ image: NSImage) -> String? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            return nil
        }
        return jpegData.base64EncodedString()
    }

    private func elapsed(from start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }
}
