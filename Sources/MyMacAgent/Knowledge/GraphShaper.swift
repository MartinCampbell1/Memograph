import Foundation

struct KnowledgeEntityMetrics {
    let entity: KnowledgeEntityRecord
    let claimCount: Int
}

final class GraphShaper {
    private let genericTopicNames: Set<String> = [
        "ai",
        "llm",
        "rag",
        "claims",
        "claim layer",
        "knowledge base",
        "knowledge graph",
        "open source",
        "shell",
        "python",
        "wiki-links",
        "daily log",
        "hourly log",
        "topic",
        "topics"
    ]
    private let genericLessonNames: Set<String> = [
        "report generation"
    ]
    private let suppressedToolNames: Set<String> = [
        "coreautha",
        "loginwindow",
        "universalaccessauthwarn",
        "usernotificationcenter"
    ]
    private let suppressedToolFragments: [String] = [
        "вспомогательное приложение",
        "extension helper",
        "helper",
        "authwarn"
    ]
    private let suppressedModelSignals: [String] = [
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
        "audit"
    ]

    private let stopTokens: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "that",
        "this", "how", "what", "why", "raw", "claims", "wiki"
    ]

    func materializedEntityIds(from metrics: [KnowledgeEntityMetrics]) -> Set<String> {
        let index = Dictionary(uniqueKeysWithValues: metrics.map { ($0.entity.id, $0) })
        return Set(metrics.compactMap { metric in
            shouldMaterialize(metric, in: index) ? metric.entity.id : nil
        })
    }

    private func shouldMaterialize(
        _ metric: KnowledgeEntityMetrics,
        in index: [String: KnowledgeEntityMetrics]
    ) -> Bool {
        switch metric.entity.entityType {
        case .project, .tool, .model:
            switch metric.entity.entityType {
            case .project:
                return metric.claimCount >= 1
            case .tool:
                return metric.claimCount >= 1
                    && !isSuppressedTool(metric.entity.canonicalName)
                    && !isVersionedToolVariant(metric, in: index)
                    && isSpecificEnough(metric.entity.canonicalName, minimumTokens: 1, minimumLength: 4)
            case .model:
                return metric.claimCount >= 1 && !isSuppressedModel(metric.entity.canonicalName)
            default:
                return false
            }
        case .issue:
            return metric.claimCount >= 1 && isSpecificEnough(metric.entity.canonicalName, minimumTokens: 2, minimumLength: 10)
        case .lesson:
            guard metric.claimCount >= 1 else { return false }
            guard !isGenericLesson(metric.entity.canonicalName) else { return false }
            guard !hasMoreSpecificSibling(for: metric, in: index) else { return false }
            return isSpecificEnough(metric.entity.canonicalName, minimumTokens: 2, minimumLength: 14)
        case .site, .person:
            return metric.claimCount >= 2 && isSpecificEnough(metric.entity.canonicalName, minimumTokens: 1, minimumLength: 4)
        case .topic:
            guard metric.claimCount >= 2 else { return false }
            guard !isGenericTopic(metric.entity.canonicalName) else { return false }
            guard !hasMoreSpecificSibling(for: metric, in: index) else { return false }
            return isSpecificEnough(metric.entity.canonicalName, minimumTokens: 2, minimumLength: 6)
        }
    }

    private func isGenericTopic(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if genericTopicNames.contains(lowered) {
            return true
        }

        if lowered.count <= 3 {
            return true
        }

        return false
    }

    private func isGenericLesson(_ name: String) -> Bool {
        genericLessonNames.contains(name.lowercased())
    }

    private func isSuppressedTool(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if suppressedToolNames.contains(lowered) {
            return true
        }

        return suppressedToolFragments.contains(where: { lowered.contains($0) })
    }

    private func isSuppressedModel(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered.hasSuffix(".app") {
            return true
        }

        if lowered == "geminicode" {
            return true
        }

        return suppressedModelSignals.contains(where: { lowered.contains($0) })
    }

    private func isVersionedToolVariant(
        _ metric: KnowledgeEntityMetrics,
        in index: [String: KnowledgeEntityMetrics]
    ) -> Bool {
        let name = metric.entity.canonicalName
        guard let baseName = versionlessToolName(from: name) else {
            return false
        }

        return index.values.contains { candidate in
            candidate.entity.id != metric.entity.id
                && candidate.entity.entityType == .tool
                && candidate.entity.canonicalName.caseInsensitiveCompare(baseName) == .orderedSame
        }
    }

    private func hasMoreSpecificSibling(
        for metric: KnowledgeEntityMetrics,
        in index: [String: KnowledgeEntityMetrics]
    ) -> Bool {
        let baseTokens = tokenSet(for: metric.entity.canonicalName)
        guard !baseTokens.isEmpty else { return false }

        for candidate in index.values {
            guard candidate.entity.id != metric.entity.id else { continue }
            guard candidate.claimCount >= metric.claimCount else { continue }

            switch candidate.entity.entityType {
            case .lesson, .issue, .topic:
                break
            default:
                continue
            }

            let candidateTokens = tokenSet(for: candidate.entity.canonicalName)
            guard candidateTokens.count > baseTokens.count else { continue }
            if baseTokens.isSubset(of: candidateTokens) {
                return true
            }
        }

        return false
    }

    private func isSpecificEnough(_ name: String, minimumTokens: Int, minimumLength: Int) -> Bool {
        let tokens = tokenSet(for: name)
        if tokens.count >= minimumTokens {
            return true
        }
        return name.count >= minimumLength
    }

    private func versionlessToolName(from name: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^(.*?)(?:\s+v\d+(?:\.\d+)+)$"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              match.numberOfRanges > 1,
              let baseRange = Range(match.range(at: 1), in: name) else {
            return nil
        }
        let base = String(name[baseRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? nil : base
    }

    private func tokenSet(for name: String) -> Set<String> {
        let lowered = name.lowercased()
        let rawTokens = lowered
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var tokens: Set<String> = []
        for token in rawTokens {
            switch token {
            case "kb":
                tokens.formUnion(["knowledge", "base"])
            default:
                if !stopTokens.contains(token) {
                    tokens.insert(token)
                }
            }
        }
        return tokens
    }
}
