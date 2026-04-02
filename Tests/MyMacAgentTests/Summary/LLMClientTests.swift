import Testing
import Foundation
@testable import MyMacAgent

struct LLMClientTests {
    @Test("Builds correct request body")
    func buildsRequestBody() throws {
        let client = LLMClient(
            apiKey: "test-key",
            baseURL: "https://openrouter.ai/api/v1",
            model: "anthropic/claude-3-haiku"
        )
        let body = client.buildRequestBody(
            systemPrompt: "You are a summarizer.",
            userPrompt: "Summarize this day."
        )

        let json = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        #expect(json["model"] as? String == "anthropic/claude-3-haiku")

        let messages = json["messages"] as! [[String: String]]
        #expect(messages.count == 2)
        #expect(messages[0]["role"] == "system")
        #expect(messages[0]["content"] == "You are a summarizer.")
        #expect(messages[1]["role"] == "user")
        #expect(messages[1]["content"] == "Summarize this day.")
    }

    @Test("Builds correct URL request")
    func buildsURLRequest() {
        let client = LLMClient(
            apiKey: "sk-test-123",
            baseURL: "https://openrouter.ai/api/v1",
            model: "anthropic/claude-3-haiku"
        )

        let request = client.buildURLRequest(body: Data())
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpMethod == "POST")
    }

    @Test("Parses chat completion response")
    func parsesChatCompletion() throws {
        let responseJSON = """
        {
            "id": "gen-123",
            "choices": [{
                "message": {"role": "assistant", "content": "Summary of the day."},
                "finish_reason": "stop"
            }],
            "usage": {"prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150}
        }
        """.data(using: .utf8)!

        let result = try LLMClient.parseResponse(responseJSON)
        #expect(result.content == "Summary of the day.")
        #expect(result.promptTokens == 100)
        #expect(result.completionTokens == 50)
    }

    @Test("Parse response throws on invalid JSON")
    func throwsOnInvalid() {
        #expect(throws: (any Error).self) {
            try LLMClient.parseResponse(Data("not json".utf8))
        }
    }

    @Test("Default configuration")
    func defaultConfig() {
        let client = LLMClient.defaultClient(apiKey: "key")
        #expect(client.model == "anthropic/claude-3-haiku")
    }
}
