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
    private let ollamaBaseURL: String
    private let modelName: String
    nonisolated(unsafe) private let logger = Logger.ocr

    init(db: DatabaseManager,
         ollamaBaseURL: String = "http://localhost:11434",
         modelName: String = "hf.co/unsloth/Qwen3.5-4B-GGUF:Q4_K_M") {
        self.db = db
        self.ollamaBaseURL = ollamaBaseURL
        self.modelName = modelName
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
        guard FileManager.default.fileExists(atPath: path) else {
            return ""
        }

        guard let imageData = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return ""
        }
        let base64 = imageData.base64EncodedString()

        let payload: [String: Any] = [
            "model": modelName,
            "prompt": buildVisionPrompt(),
            "images": [base64],
            "stream": false
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var request = URLRequest(url: URL(string: "\(ollamaBaseURL)/api/generate")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["response"] as? String else {
            return ""
        }

        logger.info("Vision analysis: \(text.count) chars for image at \(path)")
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
                logger.info("Vision: analyzed \(capture.captureId) for \(capture.appName ?? "unknown")")
            }
        }

        logger.info("Vision analysis complete: \(analyzed)/\(captures.count) captures analyzed for \(date)")
        return analyzed
    }

    func buildVisionPrompt() -> String {
        "Describe what is shown in this screenshot in detail. Focus on: text content, code, UI elements, charts/graphs, data tables, and any important visual information. Extract all readable text. Be concise but thorough."
    }
}
