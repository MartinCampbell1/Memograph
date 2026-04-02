import Testing
import Foundation
@testable import MyMacAgent

struct TextNormalizerTests {

    // 1. Collapses multiple whitespace within a line into a single space
    @Test("Collapses multiple whitespace to single space")
    func collapseMultipleWhitespace() {
        let result = TextNormalizer.normalize("hello   world  foo")
        #expect(result == "hello world foo")
    }

    // 2. Trims leading/trailing whitespace
    @Test("Trims leading and trailing whitespace")
    func trimsLeadingAndTrailingWhitespace() {
        let result = TextNormalizer.normalize("  hello world  ")
        #expect(result == "hello world")
    }

    // 3. Merges consecutive blank lines into a single newline
    @Test("Merges consecutive blank lines")
    func mergesConsecutiveBlankLines() {
        let result = TextNormalizer.normalize("line one\n\n\nline two")
        #expect(result == "line one\nline two")
    }

    // 4. Preserves single newlines between lines
    @Test("Preserves single newlines")
    func preservesSingleNewlines() {
        let result = TextNormalizer.normalize("line one\nline two\nline three")
        #expect(result == "line one\nline two\nline three")
    }

    // 5. Returns nil for empty input
    @Test("Returns nil for empty input")
    func returnsNilForEmptyInput() {
        #expect(TextNormalizer.normalize("") == nil)
    }

    // 5b. Returns nil for whitespace-only input
    @Test("Returns nil for whitespace-only input")
    func returnsNilForWhitespaceOnly() {
        #expect(TextNormalizer.normalize("   \n\n   ") == nil)
    }

    // 6. Computes stable hash — same input produces same output
    @Test("Stable hash: same input produces same hash")
    func stableHash() {
        let hash1 = TextNormalizer.hash("hello world")
        let hash2 = TextNormalizer.hash("hello world")
        #expect(hash1 == hash2)
    }

    // 7. Different text produces different hash
    @Test("Different text produces different hash")
    func differentTextDifferentHash() {
        let hash1 = TextNormalizer.hash("hello world")
        let hash2 = TextNormalizer.hash("goodbye world")
        #expect(hash1 != hash2)
    }

    // 8. isDuplicate detects matching hash
    @Test("isDuplicate detects matching hash")
    func isDuplicateDetectsMatch() {
        let text = "some normalized text"
        let previousHash = TextNormalizer.hash(text)
        #expect(TextNormalizer.isDuplicate(text: text, previousHash: previousHash) == true)
        #expect(TextNormalizer.isDuplicate(text: "different text", previousHash: previousHash) == false)
    }
}
