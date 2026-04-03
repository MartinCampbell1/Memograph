import Foundation

struct KnowledgeClaimCandidate {
    let subjectKey: String
    let predicate: String
    let objectText: String?
    let confidence: Double
    let qualifiers: [String: String]
    let sourceKind: String
}

struct KnowledgeEdgeCandidate {
    let fromKey: String
    let toKey: String
    let edgeType: String
    let weight: Double
}

struct KnowledgeExtractionResult {
    let entities: [KnowledgeEntityCandidate]
    let claims: [KnowledgeClaimCandidate]
    let edges: [KnowledgeEdgeCandidate]
}

final class ClaimExtractor {
    private let normalizer: EntityNormalizer
    private let dateSupport: LocalDateSupport

    init(
        normalizer: EntityNormalizer = EntityNormalizer(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.normalizer = normalizer
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func extract(
        summary: DailySummaryRecord,
        window: SummaryWindowDescriptor,
        sessions: [SessionData]
    ) -> KnowledgeExtractionResult {
        let appNames = Set(sessions.map(\.appName))
        var entityMap: [String: KnowledgeEntityCandidate] = [:]
        var claims: [KnowledgeClaimCandidate] = []

        let tools = extractTools(summary: summary, sessions: sessions, knownToolNames: appNames)
        for entity in tools {
            entityMap[entity.stableKey] = merge(entityMap[entity.stableKey], entity)
            claims.append(KnowledgeClaimCandidate(
                subjectKey: entity.stableKey,
                predicate: "used_during_window",
                objectText: "\(window.date) \(timeLabel(window: window))",
                confidence: 0.95,
                qualifiers: ["window": window.date, "source": "sessions"],
                sourceKind: "hourly_summary"
            ))
        }

        let topics = extractTopics(summary: summary, knownToolNames: appNames)
        for entity in topics {
            entityMap[entity.stableKey] = merge(entityMap[entity.stableKey], entity)
            claims.append(KnowledgeClaimCandidate(
                subjectKey: entity.stableKey,
                predicate: "topic_in_focus",
                objectText: summary.date,
                confidence: 0.8,
                qualifiers: ["window": timeLabel(window: window)],
                sourceKind: "hourly_summary"
            ))
        }

        let suggestions = extractSuggestedNotes(summary: summary, knownToolNames: appNames)
        for entity in suggestions {
            entityMap[entity.stableKey] = merge(entityMap[entity.stableKey], entity)
            claims.append(KnowledgeClaimCandidate(
                subjectKey: entity.stableKey,
                predicate: "worth_capturing",
                objectText: summary.date,
                confidence: 0.7,
                qualifiers: ["window": timeLabel(window: window)],
                sourceKind: "summary_suggestion"
            ))
        }

        let issueEntities = topics.filter { $0.entityType == .issue }
        for entity in issueEntities {
            claims.append(KnowledgeClaimCandidate(
                subjectKey: entity.stableKey,
                predicate: "surfaced_in_window",
                objectText: summary.date,
                confidence: 0.75,
                qualifiers: ["window": timeLabel(window: window)],
                sourceKind: "hourly_summary"
            ))
        }

        let projectEntities = topics.filter { $0.entityType == .project }
        for project in projectEntities {
            claims.append(KnowledgeClaimCandidate(
                subjectKey: project.stableKey,
                predicate: "advanced_during_window",
                objectText: summary.date,
                confidence: 0.85,
                qualifiers: ["window": timeLabel(window: window)],
                sourceKind: "hourly_summary"
            ))
        }

        let allEntities = Array(entityMap.values)
        let edges = buildCoOccurrenceEdges(from: allEntities)

        return KnowledgeExtractionResult(
            entities: allEntities.sorted { $0.canonicalName < $1.canonicalName },
            claims: claims,
            edges: edges
        )
    }

    private func extractTools(
        summary: DailySummaryRecord,
        sessions: [SessionData],
        knownToolNames: Set<String>
    ) -> [KnowledgeEntityCandidate] {
        var results: [KnowledgeEntityCandidate] = []

        for appName in sessions.map(\.appName) {
            if let entity = normalizer.normalize(rawName: appName, typeHint: .tool, knownToolNames: knownToolNames) {
                results.append(entity)
            }
        }

        if let appsJson = summary.topAppsJson,
           let data = appsJson.data(using: .utf8),
           let apps = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for app in apps {
                if let name = app["name"] as? String,
                   let entity = normalizer.normalize(rawName: name, typeHint: .tool, knownToolNames: knownToolNames) {
                    results.append(entity)
                }
            }
        }

        return dedupe(results)
    }

    private func extractTopics(summary: DailySummaryRecord, knownToolNames: Set<String>) -> [KnowledgeEntityCandidate] {
        var results: [KnowledgeEntityCandidate] = []

        if let topicsJson = summary.topTopicsJson,
           let data = topicsJson.data(using: .utf8),
           let topics = try? JSONSerialization.jsonObject(with: data) as? [String] {
            for topic in topics {
                if let entity = normalizer.normalize(rawName: topic, knownToolNames: knownToolNames) {
                    results.append(entity)
                }
            }
        }

        for link in normalizer.extractWikiLinks(from: summary.summaryText) {
            if let entity = normalizer.normalize(rawName: link, knownToolNames: knownToolNames) {
                results.append(entity)
            }
        }

        return dedupe(results)
    }

    private func extractSuggestedNotes(summary: DailySummaryRecord, knownToolNames: Set<String>) -> [KnowledgeEntityCandidate] {
        guard let notesJson = summary.suggestedNotesJson,
              let data = notesJson.data(using: .utf8),
              let notes = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }

        return dedupe(notes.compactMap { note in
            normalizer.normalize(rawName: note, typeHint: .lesson, knownToolNames: knownToolNames)
        })
    }

    private func buildCoOccurrenceEdges(from entities: [KnowledgeEntityCandidate]) -> [KnowledgeEdgeCandidate] {
        let sorted = entities.sorted { $0.stableKey < $1.stableKey }
        guard sorted.count > 1 else { return [] }

        var edges: [KnowledgeEdgeCandidate] = []
        for leftIndex in 0..<(sorted.count - 1) {
            for rightIndex in (leftIndex + 1)..<sorted.count {
                edges.append(KnowledgeEdgeCandidate(
                    fromKey: sorted[leftIndex].stableKey,
                    toKey: sorted[rightIndex].stableKey,
                    edgeType: "co_occurs_with",
                    weight: 1
                ))
            }
        }
        return edges
    }

    private func merge(_ existing: KnowledgeEntityCandidate?, _ incoming: KnowledgeEntityCandidate) -> KnowledgeEntityCandidate {
        guard let existing else { return incoming }
        return KnowledgeEntityCandidate(
            canonicalName: existing.canonicalName,
            entityType: existing.entityType,
            aliases: existing.aliases.union(incoming.aliases)
        )
    }

    private func dedupe(_ entities: [KnowledgeEntityCandidate]) -> [KnowledgeEntityCandidate] {
        var map: [String: KnowledgeEntityCandidate] = [:]
        for entity in entities {
            map[entity.stableKey] = merge(map[entity.stableKey], entity)
        }
        return Array(map.values)
    }

    private func timeLabel(window: SummaryWindowDescriptor) -> String {
        "\(dateSupport.localTimeString(from: window.start))-\(dateSupport.localTimeString(from: window.end))"
    }
}
