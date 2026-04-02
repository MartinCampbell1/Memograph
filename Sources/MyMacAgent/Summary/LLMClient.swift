import Foundation
import os

struct LLMResponse {
    let content: String
    let promptTokens: Int
    let completionTokens: Int
}

final class LLMClient {
    let apiKey: String
    let baseURL: String
    let model: String
    private let logger = Logger.summary

    init(apiKey: String, baseURL: String = "https://openrouter.ai/api/v1", model: String = "anthropic/claude-3-haiku") {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
    }

    static func defaultClient(apiKey: String) -> LLMClient {
        LLMClient(apiKey: apiKey)
    }

    static func client(for settings: AppSettings, apiKeyOverride: String? = nil) -> LLMClient? {
        switch settings.resolvedSummaryProvider {
        case .disabled:
            return nil
        case .local:
            return LLMClient(
                apiKey: "",
                baseURL: "http://localhost:11434/v1",
                model: settings.summaryLocalModel
            )
        case .external:
            let key = apiKeyOverride ?? settings.externalAPIKey
            guard !key.isEmpty else { return nil }
            return LLMClient(
                apiKey: key,
                baseURL: settings.externalBaseURL,
                model: settings.summaryExternalModel
            )
        }
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> LLMResponse {
        let body = buildRequestBody(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let request = buildURLRequest(body: body)

        logger.info("LLM request: model=\(self.model), promptLen=\(userPrompt.count)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let result = try Self.parseResponse(data)
        logger.info("LLM response: tokens=\(result.promptTokens)+\(result.completionTokens)")
        return result
    }

    func buildRequestBody(systemPrompt: String, userPrompt: String) -> Data {
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3,
            "max_tokens": 2000
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }

    func buildURLRequest(body: Data) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Memograph/0.1.0", forHTTPHeaderField: "HTTP-Referer")
        request.httpBody = body
        return request
    }

    static func parseResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: String],
              let content = message["content"] else {
            throw LLMError.parseError("Failed to parse LLM response")
        }

        let usage = json["usage"] as? [String: Any]
        let promptTokens = usage?["prompt_tokens"] as? Int ?? 0
        let completionTokens = usage?["completion_tokens"] as? Int ?? 0

        return LLMResponse(
            content: content,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }
}

enum LLMError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String)
    case parseError(String)
    case noApiKey

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid HTTP response"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .noApiKey: return "No API key configured"
        }
    }
}
