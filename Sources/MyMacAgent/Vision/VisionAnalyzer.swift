import AppKit
import Foundation
import os

struct LowReadabilityCapture {
    let captureId: String
    let contextId: String
    let imagePath: String?
    let readableScore: Double
    let appName: String?
    let windowTitle: String?
}

/// Analyzes screenshots that OCR couldn't read well.
/// Uses local Ollama (default, private) or cloud API (configurable in Settings).
final class VisionAnalyzer: @unchecked Sendable {
    private let db: DatabaseManager
    private let logger = Logger.ocr

    init(db: DatabaseManager) {
        self.db = db
    }

    func findLowReadabilityCaptures(for date: String, threshold: Double = 0.3) throws -> [LowReadabilityCapture] {
        let rows = try db.query("""
            SELECT cs.id as ctx_id, cs.source_capture_id, cs.readable_score,
                   cs.app_name, cs.window_title, c.image_path
            FROM context_snapshots cs
            LEFT JOIN captures c ON cs.source_capture_id = c.id
            WHERE cs.timestamp LIKE ?
              AND cs.readable_score < ?
              AND cs.merged_text IS NULL
            ORDER BY cs.timestamp
            LIMIT 20
        """, params: [.text("\(date)%"), .real(threshold)])

        return rows.compactMap { row -> LowReadabilityCapture? in
            guard let ctxId = row["ctx_id"]?.textValue,
                  let captureId = row["source_capture_id"]?.textValue else { return nil }
            return LowReadabilityCapture(
                captureId: captureId,
                contextId: ctxId,
                imagePath: row["image_path"]?.textValue,
                readableScore: row["readable_score"]?.realValue ?? 0,
                appName: row["app_name"]?.textValue,
                windowTitle: row["window_title"]?.textValue
            )
        }
    }

    func analyzeImage(at path: String) async throws -> String {
        guard FileManager.default.fileExists(atPath: path),
              let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ""
        }

        let settings = AppSettings()
        let base64 = imageData.base64EncodedString()

        switch settings.resolvedVisionProvider {
        case .disabled:
            return ""
        case .ollama:
            return try await analyzeViaOllama(base64: base64, settings: settings)
        case .external:
            return try await analyzeViaCloud(base64: base64, settings: settings)
        }
    }

    // MARK: - Local Ollama (private, no data leaves machine)

    private func analyzeViaOllama(base64: String, settings: AppSettings) async throws -> String {
        let payload: [String: Any] = [
            "model": settings.visionModel,
            "prompt": buildVisionPrompt(),
            "images": [base64],
            "stream": false
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "\(settings.ollamaBaseURL)/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            return ""
        }

        logger.info("Vision (local \(settings.visionModel)): \(text.count) chars")
        return text
    }

    // MARK: - Cloud API (OpenRouter/Gemini)

    private func analyzeViaCloud(base64: String, settings: AppSettings) async throws -> String {
        guard settings.networkAllowed, settings.hasApiKey else { return "" }

        let dataURI = "data:image/jpeg;base64,\(base64)"
        let payload: [String: Any] = [
            "model": settings.visionExternalModel,
            "messages": [
                ["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": dataURI]],
                    ["type": "text", "text": buildVisionPrompt()]
                ]]
            ],
            "max_tokens": 1000
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "\(settings.externalBaseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(settings.externalAPIKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            return ""
        }

        logger.info("Vision (cloud \(settings.visionExternalModel)): \(text.count) chars")
        return text
    }

    func persistVisionResult(contextId: String, description: String) throws {
        try db.execute(
            "UPDATE context_snapshots SET merged_text = ?, text_source = 'vision' WHERE id = ?",
            params: [.text(description), .text(contextId)]
        )
    }

    func analyzeAllLowReadability(for date: String) async throws -> Int {
        let captures = try findLowReadabilityCaptures(for: date)
        var analyzed = 0

        for capture in captures {
            guard let imagePath = capture.imagePath else { continue }
            let description = try await analyzeImage(at: imagePath)
            if !description.isEmpty {
                try persistVisionResult(contextId: capture.contextId, description: description)
                analyzed += 1
            }
        }

        let provider = AppSettings().resolvedVisionProvider.rawValue
        logger.info("Vision: \(analyzed)/\(captures.count) analyzed (\(provider))")
        return analyzed
    }

    func buildVisionPrompt() -> String {
        """
        Describe this screenshot in detail. Focus on: text content, code, \
        UI elements, charts/graphs, data. Extract all readable text. \
        Identify the app and what the user is doing.
        """
    }
}
