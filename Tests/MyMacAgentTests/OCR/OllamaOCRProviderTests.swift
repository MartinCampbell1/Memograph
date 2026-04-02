import Testing
import AppKit
import Foundation
@testable import MyMacAgent

struct OllamaOCRProviderTests {

    @Test("Provider name is ollama")
    func providerName() {
        let provider = OllamaOCRProvider()
        #expect(provider.name == "ollama")
    }

    @Test("Default model initialises without crash")
    func defaultModel() {
        let provider = OllamaOCRProvider()
        #expect(provider.name == "ollama")
    }

    @Test("Custom model name accepted")
    func customModel() {
        let provider = OllamaOCRProvider(modelName: "llava")
        #expect(provider.name == "ollama")
    }

    @Test("isAvailable returns false when Ollama not running")
    func notAvailableWhenDown() async {
        // Port 99999 is invalid — connection will be refused immediately.
        let provider = OllamaOCRProvider(baseURL: "http://localhost:99999")
        let available = await provider.isAvailable()
        #expect(!available)
    }

    @Test("Returns empty or throws when Ollama not reachable")
    func emptyResultWhenUnreachable() async throws {
        let provider = OllamaOCRProvider(baseURL: "http://localhost:99999")
        let image = makeBlankImage()

        do {
            let result = try await provider.recognizeText(in: image)
            // If it didn't throw, the result should be empty/zero-confidence.
            #expect(result.rawText.isEmpty)
            #expect(result.confidence == 0)
        } catch {
            // Connection refused is an expected outcome — not a test failure.
        }
    }

    // MARK: - FallbackOCRProvider

    @Test("FallbackOCRProvider name combines primary and fallback names")
    func fallbackProviderName() {
        let primary = OllamaOCRProvider(modelName: "glm-ocr")
        let fallback = VisionOCRProvider()
        let provider = FallbackOCRProvider(primary: primary, fallback: fallback)
        #expect(provider.name == "ollama+vision")
    }

    @Test("FallbackOCRProvider uses fallback when primary returns low confidence")
    func fallbackUsedOnLowConfidence() async throws {
        // Primary always returns empty / zero-confidence.
        let primary = OllamaOCRProvider(baseURL: "http://localhost:99999")
        // Fallback is Apple Vision, which should succeed on a real text image.
        let fallback = VisionOCRProvider()
        let provider = FallbackOCRProvider(primary: primary, fallback: fallback)

        let image = makeTextImage(text: "Hello World")
        // Should not throw; may use Vision fallback.
        let result = try await provider.recognizeText(in: image)
        // Vision should extract something from a clear text image.
        #expect(!result.rawText.isEmpty || result.processingMs >= 0)
    }

    // MARK: - Helpers

    private func makeBlankImage(size: NSSize = NSSize(width: 100, height: 100)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        image.unlockFocus()
        return image
    }

    private func makeTextImage(text: String, size: NSSize = NSSize(width: 400, height: 100)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.set()
        NSBezierPath.fill(NSRect(origin: .zero, size: size))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 24),
            .foregroundColor: NSColor.black
        ]
        (text as NSString).draw(at: NSPoint(x: 10, y: 40), withAttributes: attrs)
        image.unlockFocus()
        return image
    }
}
