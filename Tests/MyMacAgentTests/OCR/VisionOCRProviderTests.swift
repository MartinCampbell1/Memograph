import Testing
import AppKit
@testable import MyMacAgent

struct VisionOCRProviderTests {

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

    @Test("Provider name is 'vision'")
    func providerName() {
        let provider = VisionOCRProvider()
        #expect(provider.name == "vision")
    }

    @Test("Recognizes text in image")
    func recognizesText() async throws {
        let provider = VisionOCRProvider()
        let image = makeTextImage(text: "Hello World")
        let result = try await provider.recognizeText(in: image)
        #expect(result.rawText.lowercased().contains("hello"))
        #expect(result.confidence > 0)
    }

    @Test("Low confidence for blank image")
    func lowConfidenceForBlank() async throws {
        let provider = VisionOCRProvider()
        let image = makeTextImage(text: "", size: NSSize(width: 400, height: 100))
        let result = try await provider.recognizeText(in: image)
        #expect(result.rawText.isEmpty || result.confidence < 0.3)
    }

    @Test("Reports non-negative processing time")
    func reportsProcessingTime() async throws {
        let provider = VisionOCRProvider()
        let image = makeTextImage(text: "Hello World")
        let result = try await provider.recognizeText(in: image)
        #expect(result.processingMs >= 0)
    }
}
