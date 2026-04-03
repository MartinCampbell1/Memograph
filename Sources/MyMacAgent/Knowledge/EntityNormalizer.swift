import Foundation

struct KnowledgeEntityCandidate: Hashable {
    let canonicalName: String
    let entityType: KnowledgeEntityType
    let aliases: Set<String>

    var stableKey: String {
        "\(entityType.rawValue)|\(canonicalName)"
    }
}

final class EntityNormalizer {
    private let aliasMap: [String: (canonicalName: String, entityType: KnowledgeEntityType)] = [
        "twitter": ("X", .site),
        "x": ("X", .site),
        "google chrome": ("Google Chrome", .tool),
        "chrome": ("Google Chrome", .tool),
        "safari": ("Safari", .tool),
        "obsidian": ("Obsidian", .tool),
        "codex": ("Codex", .tool),
        "chatgpt": ("ChatGPT", .tool),
        "claude": ("Claude", .tool),
        "claude code": ("Claude Code", .tool),
        "google ai studio": ("Google AI Studio", .site),
        "openrouter": ("OpenRouter", .site),
        "memograph": ("Memograph", .project),
        "mymacagent": ("Memograph", .project)
    ]

    private let stopPhrases: Set<String> = [
        "summary",
        "main topics",
        "suggested notes",
        "timeline",
        "daily log",
        "hourly log",
        "daily",
        "hourly",
        "vision analysis",
        "audio transcripts",
        "continue tomorrow",
        "continue next",
        "continue later"
    ]

    func normalize(
        rawName: String,
        typeHint: KnowledgeEntityType? = nil,
        knownToolNames: Set<String> = []
    ) -> KnowledgeEntityCandidate? {
        let cleaned = clean(rawName)
        guard !cleaned.isEmpty else { return nil }

        let lower = cleaned.lowercased()
        guard !stopPhrases.contains(lower) else { return nil }
        guard cleaned.count >= 2 else { return nil }

        if let alias = aliasMap[lower] {
            return KnowledgeEntityCandidate(
                canonicalName: alias.canonicalName,
                entityType: alias.entityType,
                aliases: [cleaned]
            )
        }

        if knownToolNames.contains(cleaned) {
            return KnowledgeEntityCandidate(
                canonicalName: cleaned,
                entityType: .tool,
                aliases: [cleaned]
            )
        }

        let inferredType = typeHint ?? classify(cleaned)
        guard let inferredType else { return nil }

        return KnowledgeEntityCandidate(
            canonicalName: canonicalize(cleaned),
            entityType: inferredType,
            aliases: [cleaned]
        )
    }

    func extractWikiLinks(from text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        let pattern = #"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        return matches.compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            return nsText.substring(with: match.range(at: 1))
        }
    }

    func slug(for canonicalName: String) -> String {
        let lowered = canonicalName.lowercased()
        let allowed = lowered.map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return "-"
        }
        let collapsed = String(allowed)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "note" : collapsed
    }

    private func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func canonicalize(_ text: String) -> String {
        if text == text.uppercased(), text.count <= 6 {
            return text
        }
        return text
    }

    private func classify(_ text: String) -> KnowledgeEntityType? {
        let lower = text.lowercased()

        if lower.contains("gpt")
            || lower.contains("claude")
            || lower.contains("gemini")
            || lower.contains("qwen")
            || lower.contains("deepseek")
            || lower.contains("glm")
            || lower.contains("minimax")
            || lower.contains("opus")
            || lower.contains("haiku")
            || lower.contains("sonnet") {
            return .model
        }

        if lower.contains("error")
            || lower.contains("bug")
            || lower.contains("failure")
            || lower.contains("failed")
            || lower.contains("permission")
            || lower.contains("blink")
            || lower.contains("crash")
            || lower.contains("degraded")
            || lower.contains("retry") {
            return .issue
        }

        if lower.contains("lesson")
            || lower.contains("pattern")
            || lower.contains("playbook")
            || lower.contains("strategy") {
            return .lesson
        }

        if lower.contains("github")
            || lower.contains("reddit")
            || lower.contains("hn")
            || lower.contains("google ai studio")
            || lower.contains("guest list now")
            || lower.contains("artificial analysis")
            || lower.contains("x.com") {
            return .site
        }

        if lower == "memograph" || lower == "mymacagent" {
            return .project
        }

        if text.first?.isUppercase == true {
            return .topic
        }

        return nil
    }
}
