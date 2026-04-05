import CryptoKit
import Foundation

enum AdvisorySupport {
    static func stableIdentifier(prefix: String, components: [String]) -> String {
        let input = components.joined(separator: "|")
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)_\(hex.prefix(16))"
    }

    static func slug(for value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let replaced = folded.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        return replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func encodeJSONString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json,
              let data = json.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func decodeStringArray(from json: String?) -> [String] {
        if let decoded: [String] = decode([String].self, from: json) {
            return dedupe(decoded)
        }
        return looseStringList(from: json)
    }

    static func looseStringList(from raw: String?) -> [String] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return []
        }

        if let dict: [String: String] = decode([String: String].self, from: raw) {
            return dedupe(dict.values.map { cleanedSnippet($0, maxLength: 240) })
        }

        if let dict: [String: [String]] = decode([String: [String]].self, from: raw) {
            return dedupe(dict.values.flatMap { $0 }.map { cleanedSnippet($0, maxLength: 240) })
        }

        return dedupe(
            raw
                .components(separatedBy: CharacterSet.newlines)
                .flatMap { line in line.components(separatedBy: "•") }
                .map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "-* \t"))
                }
                .filter { !$0.isEmpty }
        )
    }

    static func referencedEntities(in text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let pattern = #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        let values = matches.compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let entityRange = Range(match.range(at: 1), in: text) else {
                return nil
            }
            return String(text[entityRange])
        }
        return dedupe(values)
    }

    static func cleanedSnippet(_ text: String, maxLength: Int = 180) -> String {
        let squashed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard squashed.count > maxLength else { return squashed }
        let index = squashed.index(squashed.startIndex, offsetBy: maxLength)
        return "\(squashed[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)…"
    }

    static func bestSnippet(containing term: String, in texts: [String], maxLength: Int = 180) -> String? {
        let normalizedTerm = term.lowercased()
        if let exact = texts.first(where: { $0.lowercased().contains(normalizedTerm) }) {
            return cleanedSnippet(exact, maxLength: maxLength)
        }
        return texts.first.map { cleanedSnippet($0, maxLength: maxLength) }
    }

    static func dedupe(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = slug(for: trimmed)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}
