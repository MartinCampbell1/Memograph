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

private struct RelationSpec {
    let fromType: KnowledgeEntityType
    let toType: KnowledgeEntityType
    let edgeType: String
    let forwardPredicate: String
    let reversePredicate: String
    let confidence: Double
}

final class ClaimExtractor {
    private let normalizer: EntityNormalizer
    private let dateSupport: LocalDateSupport
    private let graphShaper = GraphShaper()
    private let toolTopicAffinityMap: [String: Set<String>] = [
        "obsidian": ["obsidian knowledge graph", "personal knowledge management"],
        "system settings": [
            "accessibility permissions",
            "accessibility api",
            "full disk access",
            "privacy & security",
            "screen recording",
            "system audio capture"
        ]
    ]
    private let relationStopTokens: Set<String> = [
        "the", "and", "for", "with", "from", "into", "onto", "guide",
        "roadmap", "benchmarks", "benchmark", "analysis", "report", "plan",
        "playbook", "architecture", "strategy", "notes", "knowledge", "base"
    ]

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
            if entity.entityType == .topic {
                claims.append(KnowledgeClaimCandidate(
                    subjectKey: entity.stableKey,
                    predicate: "topic_in_focus",
                    objectText: summary.date,
                    confidence: 0.8,
                    qualifiers: ["window": timeLabel(window: window)],
                    sourceKind: "hourly_summary"
                ))
            }
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
        let relationExtraction = buildSemanticRelations(
            from: allEntities,
            summary: summary,
            sessions: sessions,
            window: window
        )
        claims.append(contentsOf: relationExtraction.claims)
        let durableTopicRelations = buildDurableTopicRelations(
            from: allEntities.filter { $0.entityType == .topic },
            summaryBlocks: summaryBlocks(from: summary.summaryText ?? ""),
            sessions: sessions,
            window: window
        )
        claims.append(contentsOf: durableTopicRelations.claims)

        let fallbackEdges = buildFallbackCoOccurrenceEdges(from: allEntities)
        let edges = relationExtraction.edges + durableTopicRelations.edges + fallbackEdges

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

    private func buildSemanticRelations(
        from entities: [KnowledgeEntityCandidate],
        summary: DailySummaryRecord,
        sessions: [SessionData],
        window: SummaryWindowDescriptor
    ) -> (claims: [KnowledgeClaimCandidate], edges: [KnowledgeEdgeCandidate]) {
        let grouped = Dictionary(grouping: entities, by: \.entityType)
        let summaryBlocks = summaryBlocks(from: summary.summaryText ?? "")
        let relationSpecs: [RelationSpec] = [
            RelationSpec(
                fromType: .project,
                toType: .tool,
                edgeType: "uses_tool",
                forwardPredicate: "uses_tool",
                reversePredicate: "supports_project",
                confidence: 0.9
            ),
            RelationSpec(
                fromType: .project,
                toType: .topic,
                edgeType: "focuses_on_topic",
                forwardPredicate: "focuses_on_topic",
                reversePredicate: "relevant_to_project",
                confidence: 0.84
            ),
            RelationSpec(
                fromType: .project,
                toType: .issue,
                edgeType: "blocked_by_issue",
                forwardPredicate: "blocked_by_issue",
                reversePredicate: "affects_project",
                confidence: 0.82
            ),
            RelationSpec(
                fromType: .project,
                toType: .model,
                edgeType: "uses_model",
                forwardPredicate: "uses_model",
                reversePredicate: "used_in_project",
                confidence: 0.8
            ),
            RelationSpec(
                fromType: .project,
                toType: .lesson,
                edgeType: "generates_lesson",
                forwardPredicate: "generates_lesson",
                reversePredicate: "derived_from_project",
                confidence: 0.76
            ),
            RelationSpec(
                fromType: .tool,
                toType: .topic,
                edgeType: "works_on_topic",
                forwardPredicate: "works_on_topic",
                reversePredicate: "worked_with_tool",
                confidence: 0.74
            ),
            RelationSpec(
                fromType: .lesson,
                toType: .topic,
                edgeType: "explains_topic",
                forwardPredicate: "explains_topic",
                reversePredicate: "documented_in_lesson",
                confidence: 0.72
            )
        ]

        var claims: [KnowledgeClaimCandidate] = []
        var edges: [KnowledgeEdgeCandidate] = []

        for spec in relationSpecs {
            let fromEntities = grouped[spec.fromType] ?? []
            let toEntities = grouped[spec.toType] ?? []
            guard !fromEntities.isEmpty, !toEntities.isEmpty else { continue }

            for from in fromEntities {
                for to in toEntities where from.stableKey != to.stableKey {
                    guard shouldLink(
                        from: from,
                        to: to,
                        relation: spec,
                        summaryBlocks: summaryBlocks,
                        sessions: sessions
                    ) else {
                        continue
                    }
                    claims.append(KnowledgeClaimCandidate(
                        subjectKey: from.stableKey,
                        predicate: spec.forwardPredicate,
                        objectText: to.canonicalName,
                        confidence: spec.confidence,
                        qualifiers: ["window": timeLabel(window: window)],
                        sourceKind: "relation_inference"
                    ))
                    claims.append(KnowledgeClaimCandidate(
                        subjectKey: to.stableKey,
                        predicate: spec.reversePredicate,
                        objectText: from.canonicalName,
                        confidence: max(0.65, spec.confidence - 0.05),
                        qualifiers: ["window": timeLabel(window: window)],
                        sourceKind: "relation_inference"
                    ))
                    edges.append(KnowledgeEdgeCandidate(
                        fromKey: from.stableKey,
                        toKey: to.stableKey,
                        edgeType: spec.edgeType,
                        weight: 1
                    ))
                }
            }
        }

        return (claims, edges)
    }

    private func shouldLink(
        from: KnowledgeEntityCandidate,
        to: KnowledgeEntityCandidate,
        relation: RelationSpec,
        summaryBlocks: [String],
        sessions: [SessionData]
    ) -> Bool {
        switch relation.edgeType {
        case "uses_tool", "focuses_on_topic", "blocked_by_issue", "uses_model", "generates_lesson":
            return hasProjectRelationEvidence(
                project: from,
                target: to,
                relation: relation,
                summaryBlocks: summaryBlocks,
                sessions: sessions
            )
        case "works_on_topic":
            return hasToolTopicEvidence(
                tool: from,
                topic: to,
                summaryBlocks: summaryBlocks,
                sessions: sessions
            )
        case "explains_topic":
            return hasSemanticNameOverlap(lhs: from.canonicalName, rhs: to.canonicalName)
        default:
            return true
        }
    }

    private func hasProjectRelationEvidence(
        project: KnowledgeEntityCandidate,
        target: KnowledgeEntityCandidate,
        relation: RelationSpec,
        summaryBlocks: [String],
        sessions: [SessionData]
    ) -> Bool {
        guard relation.fromType == .project else { return true }
        if relation.edgeType == "focuses_on_topic",
           !graphShaper.isMeaningfulProjectRelationTopic(target.canonicalName) {
            return false
        }

        let relevantBlocks = summaryBlocks.filter { blockContainsEntity($0, entity: project) }
        if relevantBlocks.contains(where: { blockContainsEntity($0, entity: target) }) {
            return true
        }
        if relation.edgeType == "generates_lesson",
           relevantBlocks.contains(where: { hasSemanticNameOverlap(lhs: $0, rhs: target.canonicalName) }) {
            return true
        }

        let projectSessions = sessions.filter { sessionMentionsEntity($0, entity: project) }
        guard !projectSessions.isEmpty else {
            return false
        }

        switch relation.edgeType {
        case "uses_tool":
            return projectSessions.contains { sessionUsesTool($0, tool: target) }
        case "focuses_on_topic", "blocked_by_issue":
            return projectSessions.contains { sessionMentionsEntity($0, entity: target) }
        default:
            return false
        }
    }

    private func hasToolTopicEvidence(
        tool: KnowledgeEntityCandidate,
        topic: KnowledgeEntityCandidate,
        summaryBlocks: [String],
        sessions: [SessionData]
    ) -> Bool {
        guard tool.entityType == .tool, topic.entityType == .topic else { return false }
        guard graphShaper.isMeaningfulProjectRelationTopic(topic.canonicalName) else { return false }

        let toolSessions = sessions.filter { sessionUsesTool($0, tool: tool) }
        if toolSessions.contains(where: { sessionMentionsEntity($0, entity: topic) }) {
            return true
        }

        guard hasToolTopicAffinity(tool: tool, topic: topic) else { return false }
        let relevantBlocks = summaryBlocks.filter { blockContainsEntity($0, entity: tool) }
        return relevantBlocks.contains(where: { blockContainsEntity($0, entity: topic) })
    }

    private func buildDurableTopicRelations(
        from topics: [KnowledgeEntityCandidate],
        summaryBlocks: [String],
        sessions: [SessionData],
        window: SummaryWindowDescriptor
    ) -> (claims: [KnowledgeClaimCandidate], edges: [KnowledgeEdgeCandidate]) {
        let sortedTopics = topics.sorted { $0.stableKey < $1.stableKey }
        guard sortedTopics.count > 1 else {
            return ([], [])
        }

        var claims: [KnowledgeClaimCandidate] = []
        var edges: [KnowledgeEdgeCandidate] = []

        for leftIndex in 0..<(sortedTopics.count - 1) {
            for rightIndex in (leftIndex + 1)..<sortedTopics.count {
                let lhs = sortedTopics[leftIndex]
                let rhs = sortedTopics[rightIndex]
                guard shouldRelateDurableTopics(
                    lhs,
                    rhs,
                    summaryBlocks: summaryBlocks,
                    sessions: sessions
                ) else {
                    continue
                }

                claims.append(KnowledgeClaimCandidate(
                    subjectKey: lhs.stableKey,
                    predicate: "related_topic",
                    objectText: rhs.canonicalName,
                    confidence: 0.72,
                    qualifiers: ["window": timeLabel(window: window)],
                    sourceKind: "relation_inference"
                ))
                claims.append(KnowledgeClaimCandidate(
                    subjectKey: rhs.stableKey,
                    predicate: "related_topic",
                    objectText: lhs.canonicalName,
                    confidence: 0.72,
                    qualifiers: ["window": timeLabel(window: window)],
                    sourceKind: "relation_inference"
                ))
                edges.append(KnowledgeEdgeCandidate(
                    fromKey: lhs.stableKey,
                    toKey: rhs.stableKey,
                    edgeType: "related_topic",
                    weight: 1
                ))
            }
        }

        return (claims, edges)
    }

    private func shouldRelateDurableTopics(
        _ lhs: KnowledgeEntityCandidate,
        _ rhs: KnowledgeEntityCandidate,
        summaryBlocks: [String],
        sessions: [SessionData]
    ) -> Bool {
        guard lhs.entityType == .topic, rhs.entityType == .topic else { return false }
        guard graphShaper.isMeaningfulProjectRelationTopic(lhs.canonicalName) else { return false }
        guard graphShaper.isMeaningfulProjectRelationTopic(rhs.canonicalName) else { return false }
        guard topicFamilyKey(for: lhs.canonicalName) == topicFamilyKey(for: rhs.canonicalName) else {
            return false
        }

        if summaryBlocks.contains(where: { blockContainsEntity($0, entity: lhs) && blockContainsEntity($0, entity: rhs) }) {
            return true
        }

        return sessions.contains { session in
            sessionMentionsEntity(session, entity: lhs) && sessionMentionsEntity(session, entity: rhs)
        }
    }

    private func hasToolTopicAffinity(tool: KnowledgeEntityCandidate, topic: KnowledgeEntityCandidate) -> Bool {
        let toolKey = normalizedKey(tool.canonicalName)
        let topicKey = normalizedKey(topic.canonicalName)
        if hasSemanticNameOverlap(lhs: tool.canonicalName, rhs: topic.canonicalName) {
            return true
        }
        return toolTopicAffinityMap[toolKey]?.contains(topicKey) == true
    }

    private func topicFamilyKey(for topicName: String) -> String? {
        let key = normalizedKey(topicName)
        switch key {
        case "accessibility api",
             "accessibility permissions",
             "full disk access",
             "privacy & security",
             "privacy-focused ocr",
             "screen recording",
             "screencap",
             "screencapturekit",
             "system audio capture",
             "ocr":
            return "capture-stack"
        case "hardware for ai",
             "local llm",
             "q4 quantization",
             "vram":
            return "local-ai"
        case "obsidian knowledge graph",
             "personal knowledge management":
            return "knowledge"
        default:
            return nil
        }
    }

    private func hasSemanticNameOverlap(lhs: String, rhs: String) -> Bool {
        let lhsKey = normalizedKey(lhs)
        let rhsKey = normalizedKey(rhs)
        if lhsKey == rhsKey {
            return true
        }
        if lhsKey.contains(rhsKey) || rhsKey.contains(lhsKey) {
            return true
        }

        let lhsTokens = tokenSet(for: lhs)
        let rhsTokens = tokenSet(for: rhs)
        let overlap = lhsTokens.intersection(rhsTokens)
        if overlap.count >= 2 {
            return true
        }

        if rhsTokens.count <= 2,
           overlap.contains(where: { $0.count >= 5 }) {
            return true
        }

        if lhsTokens.count <= 2,
           overlap.contains(where: { $0.count >= 5 }) {
            return true
        }

        return false
    }

    private func buildFallbackCoOccurrenceEdges(from entities: [KnowledgeEntityCandidate]) -> [KnowledgeEdgeCandidate] {
        let grouped = Dictionary(grouping: entities, by: \.entityType)
        var edges: [KnowledgeEdgeCandidate] = []
        for sameTypeEntities in grouped.values {
            edges.append(contentsOf: buildCoOccurrenceEdges(within: sameTypeEntities))
        }
        return edges
    }

    private func buildCoOccurrenceEdges(within entities: [KnowledgeEntityCandidate]) -> [KnowledgeEdgeCandidate] {
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

    private func summaryBlocks(from markdown: String) -> [String] {
        var blocks: [String] = []
        var currentLines: [String] = []
        var currentSubheading: String?

        func flush() {
            guard !currentLines.isEmpty else { return }
            blocks.append(currentLines.joined(separator: "\n"))
            currentLines.removeAll(keepingCapacity: true)
        }

        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty {
                flush()
                currentSubheading = nil
                continue
            }

            if line.hasPrefix("### ") {
                flush()
                currentSubheading = line
                continue
            }

            if line.hasPrefix("## ") {
                flush()
                currentSubheading = nil
                currentLines.append(line)
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                if let currentSubheading {
                    blocks.append([currentSubheading, line].joined(separator: "\n"))
                } else {
                    blocks.append(line)
                }
                continue
            }

            currentLines.append(line)
        }

        flush()
        return blocks
    }

    private func blockContainsEntity(_ text: String, entity: KnowledgeEntityCandidate) -> Bool {
        let normalizedText = normalizedKey(text)
        return entityTerms(for: entity).contains { term in
            normalizedText.contains(term)
        }
    }

    private func sessionMentionsEntity(_ session: SessionData, entity: KnowledgeEntityCandidate) -> Bool {
        let text = ([session.appName] + session.windowTitles + session.contextTexts).joined(separator: "\n")
        return blockContainsEntity(text, entity: entity)
    }

    private func sessionUsesTool(_ session: SessionData, tool: KnowledgeEntityCandidate) -> Bool {
        guard tool.entityType == .tool,
              let sessionTool = normalizer.normalize(rawName: session.appName, typeHint: .tool) else {
            return false
        }
        return sessionTool.stableKey == tool.stableKey
    }

    private func normalizedKey(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func tokenSet(for text: String) -> Set<String> {
        Set(
            normalizedKey(text)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { token in
                    !token.isEmpty &&
                    token.count >= 2 &&
                    !relationStopTokens.contains(token)
                }
        )
    }

    private func entityTerms(for entity: KnowledgeEntityCandidate) -> Set<String> {
        Set(([entity.canonicalName] + entity.aliases)
            .map(normalizedKey)
            .filter { !$0.isEmpty })
    }
}
