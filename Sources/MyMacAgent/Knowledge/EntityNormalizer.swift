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
    private static let rawAliasMap: [String: (canonicalName: String, entityType: KnowledgeEntityType)] = [
        "twitter": ("X", .site),
        "x": ("X", .site),
        "app store": ("App Store", .tool),
        "app store": ("App Store", .tool),
        "google chrome": ("Google Chrome", .tool),
        "chrome": ("Google Chrome", .tool),
        "safari": ("Safari", .tool),
        "obsidian": ("Obsidian", .tool),
        "codex": ("Codex", .tool),
        "chatgpt": ("ChatGPT", .tool),
        "заметки": ("Notes", .tool),
        "календарь": ("Calendar", .tool),
        "почта": ("Mail", .tool),
        "просмотр": ("Preview", .tool),
        "системные настройки": ("System Settings", .tool),
        "claude": ("Claude", .tool),
        "claude.app": ("Claude", .tool),
        "claude platform": ("Claude Platform", .site),
        "claude code": ("Claude Code", .tool),
        "terminal": ("Terminal", .tool),
        "terminal.app": ("Terminal", .tool),
        "терминал": ("Terminal", .tool),
        "lm studio.app": ("LM Studio", .tool),
        "nordvpn.app": ("NordVPN", .tool),
        "vmware fusion.app": ("VMware Fusion", .tool),
        "whatsapp": ("WhatsApp", .tool),
        "google ai studio": ("Google AI Studio", .site),
        "openrouter": ("OpenRouter", .site),
        "универсальный доступ": ("Accessibility Permissions", .topic),
        "доступ к диску": ("Full Disk Access", .topic),
        "конфиденциальность и безопасность": ("Privacy & Security", .topic),
        "memograph": ("Memograph", .project),
        "mymacagent": ("Memograph", .project),
        "geminicode": ("geminicode", .project),
        "autopilot": ("autopilot", .project),
        "founderos": ("FounderOS", .project)
    ]
    private lazy var aliasMap: [String: (canonicalName: String, entityType: KnowledgeEntityType)] = {
        Self.rawAliasMap.reduce(into: [String: (canonicalName: String, entityType: KnowledgeEntityType)]()) { partial, entry in
            partial[Self.lookupKey(entry.key)] = entry.value
        }
    }()
    private static let rawCanonicalPhraseMap: [String: String] = [
        "claim extraction methodology": "Claim Extraction Methodology",
        "dpi vs white-listing in moscow": "DPI vs White-listing in Moscow",
        "flywheel effect in agentic ai": "Flywheel Effect in Agentic AI",
        "founderos v8 merge report": "FounderOS v8 Merge Report",
        "graphrag noise reduction": "GraphRAG Noise Reduction",
        "memograph kb graph v1 plan": "Memograph KB Graph v1 Plan",
        "nginx websocket origin conflict fix": "Nginx WebSocket Origin Conflict Fix",
        "three-layer kb": "Three-Layer Knowledge Base Architecture",
        "three-layer knowledge base": "Three-Layer Knowledge Base Architecture",
        "three-layer knowledge base architecture": "Three-Layer Knowledge Base Architecture",
        "tinytroupe for business validation": "TinyTroupe for Business Validation",
        "sshpass for remote sysadmin": "sshpass for Remote Sysadmin"
    ]
    private lazy var canonicalPhraseMap: [String: String] = {
        Self.rawCanonicalPhraseMap.reduce(into: [String: String]()) { partial, entry in
            partial[Self.lookupKey(entry.key)] = entry.value
        }
    }()

    private static let rawStopPhrases: Set<String> = [
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
    private lazy var stopPhrases: Set<String> = Set(Self.rawStopPhrases.map(Self.lookupKey))
    private let lessonSignals: [String] = [
        "benchmark",
        "benchmarks",
        "roadmap",
        "guide",
        "expansion",
        "requirements",
        "methodology",
        "conflict",
        "conflicts",
        "technology",
        "plan",
        "report",
        "audit",
        "playbook",
        "strategy",
        "pattern"
    ]
    private let knownProjects: Set<String> = [
        "memograph",
        "mymacagent",
        "geminicode",
        "autopilot",
        "founderos"
    ]

    func normalize(
        rawName: String,
        typeHint: KnowledgeEntityType? = nil,
        knownToolNames: Set<String> = []
    ) -> KnowledgeEntityCandidate? {
        let cleaned = clean(rawName)
        guard !cleaned.isEmpty else { return nil }

        let lower = Self.lookupKey(cleaned)
        let normalizedKnownToolNames = Set(knownToolNames.map(Self.lookupKey))
        guard !stopPhrases.contains(lower) else { return nil }
        guard cleaned.count >= 2 else { return nil }

        if let alias = aliasMap[lower] {
            return KnowledgeEntityCandidate(
                canonicalName: alias.canonicalName,
                entityType: alias.entityType,
                aliases: [cleaned]
            )
        }

        if normalizedKnownToolNames.contains(lower) {
            let canonicalName = canonicalize(cleaned, type: .tool)
            return KnowledgeEntityCandidate(
                canonicalName: canonicalName,
                entityType: .tool,
                aliases: [cleaned]
            )
        }

        let inferredType = typeHint ?? classify(cleaned)
        guard let inferredType else { return nil }

        let canonicalName = canonicalize(cleaned, type: inferredType)

        return KnowledgeEntityCandidate(
            canonicalName: canonicalName,
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
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
            .replacingOccurrences(of: "\u{202A}", with: "")
            .replacingOccurrences(of: "\u{202B}", with: "")
            .replacingOccurrences(of: "\u{202C}", with: "")
            .replacingOccurrences(of: "\u{2066}", with: "")
            .replacingOccurrences(of: "\u{2067}", with: "")
            .replacingOccurrences(of: "\u{2068}", with: "")
            .replacingOccurrences(of: "\u{2069}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private func canonicalize(_ text: String, type: KnowledgeEntityType) -> String {
        let stripped = stripExplanatorySuffixIfNeeded(from: text, type: type)
        let normalizedWhitespace = stripped
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lower = Self.lookupKey(normalizedWhitespace)
        if let mapped = canonicalPhraseMap[lower] {
            return mapped
        }

        if type == .tool, lower.hasSuffix(".app") {
            let base = normalizedWhitespace.dropLast(4).trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty {
                return base
            }
        }

        if normalizedWhitespace == normalizedWhitespace.uppercased(),
           normalizedWhitespace.count <= 6 {
            return normalizedWhitespace
        }

        return normalizedWhitespace
    }

    private static func lookupKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func stripExplanatorySuffixIfNeeded(from text: String, type: KnowledgeEntityType) -> String {
        switch type {
        case .lesson, .topic, .issue:
            break
        default:
            return text
        }

        let separators = [" — ", " – ", ": "]
        for separator in separators {
            guard let range = text.range(of: separator) else { continue }
            let head = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.count >= 4, tail.count >= 8 else { continue }

            let tokenCount = head
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .count
            if tokenCount >= 2 {
                return head
            }
        }

        return text
    }

    private func classify(_ text: String) -> KnowledgeEntityType? {
        let lower = text.lowercased()

        if knownProjects.contains(lower) {
            return .project
        }

        if lower.hasSuffix(".app") || lower.contains(" app") {
            return .tool
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

        if lessonSignals.contains(where: { lower.contains($0) }) || lower.contains("lesson") {
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

        if lower.contains("claude code v") {
            return .tool
        }

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

        if text.first?.isUppercase == true {
            return .topic
        }

        return nil
    }
}
