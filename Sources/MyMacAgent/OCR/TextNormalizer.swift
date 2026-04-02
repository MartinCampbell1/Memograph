import Foundation
import CryptoKit

enum TextNormalizer {
    static func normalize(_ text: String) -> String? {
        var result = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            }
            .joined(separator: "\n")
        while result.contains("\n\n") {
            result = result.replacingOccurrences(of: "\n\n", with: "\n")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isDuplicate(text: String, previousHash: String) -> Bool {
        hash(text) == previousHash
    }
}
