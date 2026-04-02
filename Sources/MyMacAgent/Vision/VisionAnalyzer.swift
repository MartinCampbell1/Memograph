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

final class VisionAnalyzer {
    private let db: DatabaseManager
    private let apiKey: String
    private let model: String
    private let baseURL: String
    nonisolated(unsafe) private let logger = Logger.ocr

    init(db: DatabaseManager, apiKey: String = "", model: String = "", baseURL: String = "") {
        self.db = db
        let settings = AppSettings()
        self.apiKey = apiKey.isEmpty ? settings.openRouterApiKey : apiKey
        self.model = model.isEmpty ? settings.llmModel : model
        self.baseURL = baseURL.isEmpty ? "https://openrouter.ai/api/v1" : baseURL
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

        let base64 = imageData.base64EncodedString()
        let dataURI = "data:image/jpeg;base64,\(base64)"

        // Use OpenRouter multimodal API (Gemini supports images)
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": [
                    ["type": "image_url", "image_url": ["url": dataURI]],
                    ["type": "text", "text": buildVisionPrompt()]
                ]]
            ],
            "max_tokens": 1000
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

        logger.info("Vision analysis (Gemini): \(text.count) chars for \(path)")
        return text
    }

    func persistVisionResult(contextId: String, description: String) throws {
        try db.execute(
            "UPDATE context_snapshots SET merged_text = ?, text_source = 'vision' WHERE id = ?",
            params: [.text(description), .text(contextId)]
        )
    }

    func analyzeAllLowReadability(for date: String) async throws -> Int {
        guard !apiKey.isEmpty else {
            logger.info("Vision: skipping — no API key")
            return 0
        }

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

        logger.info("Vision: \(analyzed)/\(captures.count) low-readability captures analyzed via \(self.model)")
        return analyzed
    }

    func buildVisionPrompt() -> String {
        """
        Describe this screenshot in detail with [[wiki-links]] for Obsidian. \
        Focus on: text content, code, UI elements, charts/graphs, data. \
        Extract all readable text. Identify the app, task, and context. \
        Wrap every tool/project/technology in [[double brackets]].
        """
    }
}
