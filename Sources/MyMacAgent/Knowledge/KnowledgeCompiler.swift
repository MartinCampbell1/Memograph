import Foundation

private enum RelationshipDirection {
    case outgoing
    case incoming
    case undirected
}

private struct RelatedKnowledgeReference {
    let entity: KnowledgeEntityRecord
    let edgeType: String
    let direction: RelationshipDirection
    let weight: Double
}

private struct PredicateSignalSummary {
    let predicate: String
    let evidenceCount: Int
    let objectCount: Int
    let examples: [String]
    let latest: String?
}

final class KnowledgeCompiler {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport
    private let normalizer: EntityNormalizer
    private let settings: AppSettings
    private let graphShaper = GraphShaper()

    init(
        db: DatabaseManager,
        timeZone: TimeZone = .autoupdatingCurrent,
        normalizer: EntityNormalizer = EntityNormalizer(),
        settings: AppSettings = AppSettings()
    ) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.normalizer = normalizer
        self.settings = settings
    }

    func compileNote(for entityId: String, sourceDate: String?) throws -> KnowledgeNoteRecord? {
        try compileNote(for: entityId, sourceDate: sourceDate, allowedEntityIds: nil)
    }

    func compileNote(
        for entityId: String,
        sourceDate: String?,
        allowedEntityIds: Set<String>?
    ) throws -> KnowledgeNoteRecord? {
        let entityRows = try db.query(
            "SELECT * FROM knowledge_entities WHERE id = ? LIMIT 1",
            params: [.text(entityId)]
        )
        guard let entity = entityRows.first.flatMap(KnowledgeEntityRecord.init(row:)) else {
            return nil
        }

        let claims = try db.query("""
            SELECT * FROM knowledge_claims
            WHERE subject_entity_id = ?
            ORDER BY COALESCE(window_end, created_at) DESC
            LIMIT 20
        """, params: [.text(entityId)]).compactMap(KnowledgeClaimRecord.init(row:))

        let edges = try db.query("""
            SELECT * FROM knowledge_edges
            WHERE from_entity_id = ? OR to_entity_id = ?
            ORDER BY weight DESC, updated_at DESC
            LIMIT 12
        """, params: [.text(entityId), .text(entityId)]).compactMap(KnowledgeEdgeRecord.init(row:))

        let relatedReferences = try fetchRelatedReferences(for: entityId, edges: edges)
            .filter { allowedEntityIds?.contains($0.entity.id) ?? true }
        let mergeOverlays = mergeOverlays(for: entity.id)
        let aliases = aliases(for: entity, mergeOverlays: mergeOverlays)
        let windowContexts = try buildWindowContextSnippets(
            for: entity,
            aliases: aliases,
            claims: claims
        )
        let markdown = renderMarkdown(
            entity: entity,
            claims: claims,
            relatedReferences: relatedReferences,
            aliases: aliases,
            mergeOverlays: mergeOverlays,
            windowContexts: windowContexts
        )
        let links = relatedReferences.map { linkTarget(for: $0.entity) }
        let tags = [entity.entityType.rawValue, "memograph-kb-v1"]
        let effectiveSourceDate = sourceDate ?? claims.first?.sourceSummaryDate

        return KnowledgeNoteRecord(
            id: "knowledge:\(entity.id)",
            noteType: entity.entityType.rawValue,
            title: entity.canonicalName,
            bodyMarkdown: markdown,
            sourceDate: effectiveSourceDate,
            tagsJson: jsonString(tags),
            linksJson: jsonString(links)
        )
    }

    func persist(note: KnowledgeNoteRecord) throws {
        try db.execute("""
            INSERT OR REPLACE INTO knowledge_notes
                (id, note_type, title, body_markdown, source_date, tags_json, links_json,
                 export_obsidian_status, export_notion_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 'pending')
        """, params: [
            .text(note.id),
            .text(note.noteType),
            .text(note.title),
            .text(note.bodyMarkdown),
            note.sourceDate.map(SQLiteValue.text) ?? .null,
            note.tagsJson.map(SQLiteValue.text) ?? .null,
            note.linksJson.map(SQLiteValue.text) ?? .null
        ])
    }

    func buildIndexMarkdown() throws -> String {
        let rows = try db.query("""
            SELECT note_type, title
            FROM knowledge_notes
            ORDER BY note_type, title
        """)

        var grouped: [String: [String]] = [:]
        for row in rows {
            guard let noteType = row["note_type"]?.textValue,
                  let title = row["title"]?.textValue else {
                continue
            }
            grouped[noteType, default: []].append(title)
        }

        var markdown = "# Memograph Knowledge Index\n\n"
        markdown += "_Compiled from hourly summaries and normalized knowledge claims._\n\n"

        for type in KnowledgeEntityType.allCases {
            let titles = grouped[type.rawValue, default: []]
            guard !titles.isEmpty else { continue }
            markdown += "## \(type.folderName)\n"
            for title in titles.sorted() {
                let slug = normalizer.slug(for: title)
                markdown += "- [[Knowledge/\(type.folderName)/\(slug)|\(title)]]\n"
            }
            markdown += "\n"
        }

        return markdown
    }

    private func fetchRelatedReferences(
        for entityId: String,
        edges: [KnowledgeEdgeRecord]
    ) throws -> [RelatedKnowledgeReference] {
        let relatedIds = Set(edges.map { $0.fromEntityId == entityId ? $0.toEntityId : $0.fromEntityId })
        guard !relatedIds.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: relatedIds.count).joined(separator: ",")
        let params = relatedIds.sorted().map(SQLiteValue.text)
        let rows = try db.query(
            "SELECT * FROM knowledge_entities WHERE id IN (\(placeholders))",
            params: params
        )
        let entities = rows.compactMap(KnowledgeEntityRecord.init(row:))
        let map = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })

        var preferredByEntityId: [String: RelatedKnowledgeReference] = [:]
        for edge in edges {
            let relatedId: String
            let direction: RelationshipDirection

            if edge.fromEntityId == entityId {
                relatedId = edge.toEntityId
                direction = .outgoing
            } else if edge.toEntityId == entityId {
                relatedId = edge.fromEntityId
                direction = .incoming
            } else {
                continue
            }

            guard let entity = map[relatedId] else { continue }
            let reference = RelatedKnowledgeReference(
                entity: entity,
                edgeType: edge.edgeType,
                direction: direction,
                weight: edge.weight
            )

            if let existing = preferredByEntityId[relatedId] {
                preferredByEntityId[relatedId] = prefer(reference, over: existing)
            } else {
                preferredByEntityId[relatedId] = reference
            }
        }

        return preferredByEntityId.values.sorted { lhs, rhs in
            if lhs.entity.entityType != rhs.entity.entityType {
                return lhs.entity.entityType.folderName < rhs.entity.entityType.folderName
            }
            return lhs.entity.canonicalName < rhs.entity.canonicalName
        }
    }

    private func renderMarkdown(
        entity: KnowledgeEntityRecord,
        claims: [KnowledgeClaimRecord],
        relatedReferences: [RelatedKnowledgeReference],
        aliases: [String],
        mergeOverlays: [KnowledgeMergeOverlayRecord],
        windowContexts: [String: String]
    ) -> String {
        let visibleRelationObjects = Set(relatedReferences.map { $0.entity.canonicalName })
        let displayedRelatedReferences = filteredRelatedReferences(relatedReferences, for: entity)
        var markdown = "# \(entity.canonicalName)\n\n"
        markdown += "_Type: \(entity.entityType.rawValue)_\n\n"

        markdown += "## Snapshot\n"
        if let firstSeen = entity.firstSeenAt {
            markdown += "- First seen: \(dateSupport.localDateTimeString(from: firstSeen))\n"
        }
        if let lastSeen = entity.lastSeenAt {
            markdown += "- Last seen: \(dateSupport.localDateTimeString(from: lastSeen))\n"
        }
        markdown += "- Claims collected: \(claims.count)\n\n"

        let overviewLines = buildOverviewLines(
            for: entity,
            claims: claims,
            relatedReferences: displayedRelatedReferences
        )
        if !overviewLines.isEmpty {
            markdown += "## Overview\n"
            for line in overviewLines {
                markdown += "- \(line)\n"
            }
            markdown += "\n"
        }

        if !aliases.isEmpty {
            markdown += "## Aliases\n"
            for alias in aliases {
                markdown += "- \(alias)\n"
            }
            markdown += "\n"
        }

        let mergedContextLines = buildMergedContextLines(mergeOverlays)
        if !mergedContextLines.isEmpty {
            markdown += "## Merged Context\n"
            for line in mergedContextLines {
                markdown += "- \(line)\n"
            }
            markdown += "\n"
        }

        let signals = keySignals(
            for: entity,
            claims: claims,
            visibleRelationObjects: visibleRelationObjects,
            relatedReferences: displayedRelatedReferences
        )
        if !signals.isEmpty {
            markdown += "## Key Signals\n"
            for signal in signals {
                markdown += "- \(signal)\n"
            }
            markdown += "\n"
        }

        let recentClaims = selectedRecentClaims(
            from: claims,
            for: entity,
            visibleRelationObjects: visibleRelationObjects
        )
        if !recentClaims.isEmpty {
            markdown += "## Recent Windows\n"
            for entry in renderRecentWindowEntries(
                from: recentClaims,
                entityType: entity.entityType,
                windowContexts: windowContexts
            ) {
                markdown += "- [\(entry.when)] \(entry.description)\n"
            }
            markdown += "\n"
        }

        if !displayedRelatedReferences.isEmpty {
            markdown += "## Relationships\n"
            for group in groupedRelatedEntities(displayedRelatedReferences, for: entity) {
                markdown += "### \(group.type.folderName)\n"
                for related in group.references {
                    let relationship = describe(relationship: related, for: entity)
                    markdown += "- [[\(linkTarget(for: related.entity))|\(related.entity.canonicalName)]]"
                    if !relationship.isEmpty {
                        markdown += " — \(relationship)"
                    }
                    markdown += "\n"
                }
            }
            markdown += "\n"
        }

        return markdown
    }

    private func buildOverviewLines(
        for entity: KnowledgeEntityRecord,
        claims: [KnowledgeClaimRecord],
        relatedReferences: [RelatedKnowledgeReference]
    ) -> [String] {
        let relationCounts = Dictionary(grouping: relatedReferences, by: { $0.entity.entityType }).mapValues(\.count)
        let recentWindowCount = Set(claims.compactMap { claimWindowKey($0) }.filter { !$0.isEmpty }).count
        let topToolNames = topRelatedNames(
            sortedRelatedReferences(relatedReferences, for: entity.entityType, relatedType: .tool),
            limit: 3
        )
        let topTopicNames = topRelatedNames(
            sortedRelatedReferences(relatedReferences, for: entity.entityType, relatedType: .topic),
            limit: 3
        )
        let topProjectNames = topRelatedNames(
            sortedRelatedReferences(relatedReferences, for: entity.entityType, relatedType: .project),
            limit: 3
        )
        let topLessonNames = topRelatedNames(
            sortedRelatedReferences(relatedReferences, for: entity.entityType, relatedType: .lesson),
            limit: 2
        )

        switch entity.entityType {
        case .project:
            var lines: [String] = []
            var parts: [String] = []
            if let toolCount = relationCounts[.tool], toolCount > 0 {
                parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")")
            }
            if let topicCount = relationCounts[.topic], topicCount > 0 {
                parts.append("\(topicCount) focus topic\(topicCount == 1 ? "" : "s")")
            }
            if let issueCount = relationCounts[.issue], issueCount > 0 {
                parts.append("\(issueCount) issue\(issueCount == 1 ? "" : "s")")
            }
            if let lessonCount = relationCounts[.lesson], lessonCount > 0 {
                parts.append("\(lessonCount) durable lesson\(lessonCount == 1 ? "" : "s")")
            }
            if !parts.isEmpty {
                lines.append("Recent work around this project connects it to \(joinNaturalLanguage(parts)).")
            }
            if !topTopicNames.isEmpty {
                lines.append("The strongest themes here are \(joinNaturalLanguage(topTopicNames)).")
            }
            if !topToolNames.isEmpty {
                lines.append("The main tools around it are \(joinNaturalLanguage(topToolNames)).")
            }
            return Array(lines.prefix(3))

        case .topic:
            var lines: [String] = []
            if let projectCount = relationCounts[.project], projectCount > 0 {
                if !topProjectNames.isEmpty {
                    lines.append("This topic stays active across \(projectCount) project\(projectCount == 1 ? "" : "s"), especially around \(joinNaturalLanguage(topProjectNames)).")
                } else {
                    lines.append("This topic stays active across \(projectCount) project\(projectCount == 1 ? "" : "s").")
                }
            }
            if let topicCount = relationCounts[.topic], topicCount > 0 {
                if !topTopicNames.isEmpty {
                    lines.append("Its closest cluster includes \(joinNaturalLanguage(topTopicNames)).")
                } else {
                    lines.append("Nearby work keeps it close to \(topicCount) related topic\(topicCount == 1 ? "" : "s").")
                }
            }
            if let lessonCount = relationCounts[.lesson], lessonCount > 0 {
                if !topLessonNames.isEmpty {
                    lines.append("The clearest write-up here is \(joinNaturalLanguage(topLessonNames)).")
                } else {
                    lines.append("It is documented by \(lessonCount) lesson\(lessonCount == 1 ? "" : "s").")
                }
            }
            return Array(lines.prefix(3))

        case .lesson:
            var lines: [String] = []
            var parts: [String] = []
            let hasProjectTopicSummary = !topProjectNames.isEmpty && !topTopicNames.isEmpty
            if let projectCount = relationCounts[.project], projectCount > 0 {
                parts.append("\(projectCount) source project\(projectCount == 1 ? "" : "s")")
            }
            if let topicCount = relationCounts[.topic], topicCount > 0 {
                parts.append("\(topicCount) documented topic\(topicCount == 1 ? "" : "s")")
            }
            if hasProjectTopicSummary {
                lines.append("This lesson crystallizes work from \(joinNaturalLanguage(topProjectNames)) into guidance on \(joinNaturalLanguage(topTopicNames)).")
            } else if !parts.isEmpty {
                lines.append("This lesson was distilled from \(joinNaturalLanguage(parts)).")
            }
            if !topProjectNames.isEmpty && !hasProjectTopicSummary {
                lines.append("It mainly comes out of \(joinNaturalLanguage(topProjectNames)).")
            }
            if !topTopicNames.isEmpty && lines.count < 3 {
                let coverageLine = hasProjectTopicSummary
                    ? "Its core focus stays on \(joinNaturalLanguage(topTopicNames))."
                    : "Its core coverage is \(joinNaturalLanguage(topTopicNames))."
                lines.append(coverageLine)
            }
            return Array(lines.prefix(3))

        case .tool:
            var parts: [String] = []
            if recentWindowCount > 0 {
                parts.append("\(recentWindowCount) recent work window\(recentWindowCount == 1 ? "" : "s")")
            }
            if let projectCount = relationCounts[.project], projectCount > 0 {
                parts.append("\(projectCount) project\(projectCount == 1 ? "" : "s")")
            }
            if let topicCount = relationCounts[.topic], topicCount > 0 {
                parts.append("\(topicCount) topic\(topicCount == 1 ? "" : "s")")
            }
            guard !parts.isEmpty else { return [] }
            var lines = ["Recent activity places this tool across \(joinNaturalLanguage(parts))."]
            if !topProjectNames.isEmpty {
                lines.append("It is most tied to \(joinNaturalLanguage(topProjectNames)).")
            }
            if !topTopicNames.isEmpty {
                lines.append("It most often shows up around \(joinNaturalLanguage(topTopicNames)).")
            }
            return Array(lines.prefix(3))

        case .issue:
            var parts: [String] = []
            if let projectCount = relationCounts[.project], projectCount > 0 {
                parts.append("\(projectCount) affected project\(projectCount == 1 ? "" : "s")")
            }
            if recentWindowCount > 0 {
                parts.append("\(recentWindowCount) surfaced window\(recentWindowCount == 1 ? "" : "s")")
            }
            guard !parts.isEmpty else { return [] }
            return ["This issue shows up across \(joinNaturalLanguage(parts))."]

        case .model:
            guard let projectCount = relationCounts[.project], projectCount > 0 else { return [] }
            return ["This model shows up in \(projectCount) project\(projectCount == 1 ? "" : "s")."]

        case .site, .person:
            guard recentWindowCount > 0 else { return [] }
            return ["Seen across \(recentWindowCount) recent window\(recentWindowCount == 1 ? "" : "s")."]
        }
    }

    private func aliases(
        for entity: KnowledgeEntityRecord,
        mergeOverlays: [KnowledgeMergeOverlayRecord]
    ) -> [String] {
        guard let aliasesJson = entity.aliasesJson,
              let data = aliasesJson.data(using: .utf8),
              let aliases = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return mergedAliases(baseAliases: [], entity: entity, mergeOverlays: mergeOverlays)
        }

        let cleanedAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(entity.canonicalName) != .orderedSame }

        return mergedAliases(baseAliases: cleanedAliases, entity: entity, mergeOverlays: mergeOverlays)
    }

    private func mergedAliases(
        baseAliases: [String],
        entity: KnowledgeEntityRecord,
        mergeOverlays: [KnowledgeMergeOverlayRecord]
    ) -> [String] {
        var values = Set(baseAliases)
        for overlay in mergeOverlays {
            values.insert(overlay.sourceTitle)
            values.formUnion(overlay.sourceAliases)
        }
        return values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(entity.canonicalName) != .orderedSame }
            .sorted()
    }

    private func mergeOverlays(for entityId: String) -> [KnowledgeMergeOverlayRecord] {
        settings.knowledgeMergeOverlays
            .filter { $0.targetEntityId == entityId }
            .sorted { lhs, rhs in
                if lhs.appliedAt != rhs.appliedAt {
                    return lhs.appliedAt > rhs.appliedAt
                }
                return lhs.sourceTitle.localizedCaseInsensitiveCompare(rhs.sourceTitle) == .orderedAscending
            }
    }

    private func buildMergedContextLines(_ overlays: [KnowledgeMergeOverlayRecord]) -> [String] {
        overlays.prefix(4).map { overlay in
            let timestamp = dateSupport.parseDateTime(overlay.appliedAt)
                .map(dateSupport.localDateTimeString(from:))
                ?? overlay.appliedAt
            var parts: [String] = ["Merged from \(overlay.sourceTitle) on \(timestamp)."]
            if let overview = overlay.sourceOverview, !overview.isEmpty {
                parts.append(overview)
            }
            if !overlay.preservedSignals.isEmpty {
                let signalSummary = overlay.preservedSignals
                    .prefix(2)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")
                if !signalSummary.isEmpty {
                    parts.append("Preserved signals: \(signalSummary)")
                }
            }
            return parts.joined(separator: " ")
        }
    }

    private func keySignals(
        for entity: KnowledgeEntityRecord,
        claims: [KnowledgeClaimRecord],
        visibleRelationObjects: Set<String>,
        relatedReferences: [RelatedKnowledgeReference]
    ) -> [String] {
        let grouped = Dictionary(grouping: claims, by: \.predicate)
        let examplePriority = examplePriorityMap(for: entity, from: relatedReferences)
        let orderedPredicates = [
            "advanced_during_window",
            "surfaced_in_window",
            "used_during_window",
            "topic_in_focus",
            "related_topic",
            "uses_tool",
            "supports_project",
            "works_on_topic",
            "worked_with_tool",
            "focuses_on_topic",
            "relevant_to_project",
            "blocked_by_issue",
            "affects_project",
            "uses_model",
            "used_in_project",
            "generates_lesson",
            "derived_from_project",
            "explains_topic",
            "documented_in_lesson",
            "worth_capturing"
        ]

        let summaries = orderedPredicates.compactMap { predicate -> PredicateSignalSummary? in
            guard let predicateClaims = grouped[predicate], !predicateClaims.isEmpty else {
                return nil
            }

            let filteredClaims = predicateClaims.filter {
                shouldShowForVisibleRelations($0, visibleRelationObjects: visibleRelationObjects)
            }
            guard !filteredClaims.isEmpty else { return nil }

            let count = filteredClaims.count
            let examples = predicateExampleObjects(
                from: filteredClaims,
                predicate: predicate,
                visibleRelationObjects: visibleRelationObjects,
                priority: examplePriority
            )
            let latest = filteredClaims.compactMap { claim in
                claim.windowEnd
                    ?? claim.windowStart
                    ?? claim.sourceSummaryGeneratedAt
            }.max()

            return PredicateSignalSummary(
                predicate: predicate,
                evidenceCount: count,
                objectCount: examples.count,
                examples: examples,
                latest: latest
            )
        }

        let summaryByPredicate = Dictionary(uniqueKeysWithValues: summaries.map { ($0.predicate, $0) })
        let entitySpecific = entitySpecificKeySignals(
            for: entity.entityType,
            summaries: summaryByPredicate
        )
        if !entitySpecific.isEmpty {
            return entitySpecific
        }

        return summaries.compactMap(renderGenericSignal)
    }

    private func describe(claim: KnowledgeClaimRecord) -> String {
        let object = claim.objectText?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch claim.predicate {
        case "used_during_window":
            return object.map { "Used during \($0)." } ?? "Used during a captured work window."
        case "advanced_during_window":
            return object.map { "Advanced in summary window \($0)." } ?? "Advanced in a summary window."
        case "topic_in_focus":
            return object.map { "Appeared as a focus topic for \($0)." } ?? "Appeared as a focus topic."
        case "related_topic":
            return object.map { "Closely related to topic \($0)." } ?? "Closely related to another topic."
        case "uses_tool":
            return object.map { "Worked on with \($0)." } ?? "Worked on with a tool."
        case "supports_project":
            return object.map { "Supported work on \($0)." } ?? "Supported work on a project."
        case "works_on_topic":
            return object.map { "Used on topic \($0)." } ?? "Used on a topic."
        case "worked_with_tool":
            return object.map { "Worked with tool \($0)." } ?? "Worked with a tool."
        case "focuses_on_topic":
            return object.map { "Focused on \($0)." } ?? "Focused on a topic."
        case "relevant_to_project":
            return object.map { "Relevant to \($0)." } ?? "Relevant to a project."
        case "blocked_by_issue":
            return object.map { "Blocked by \($0)." } ?? "Blocked by an issue."
        case "affects_project":
            return object.map { "Affected \($0)." } ?? "Affected a project."
        case "uses_model":
            return object.map { "Used model \($0)." } ?? "Used a model."
        case "used_in_project":
            return object.map { "Used in \($0)." } ?? "Used in a project."
        case "generates_lesson":
            return object.map { "Generated lesson \($0)." } ?? "Generated a durable lesson."
        case "derived_from_project":
            return object.map { "Derived from \($0)." } ?? "Derived from a project."
        case "explains_topic":
            return object.map { "Explains topic \($0)." } ?? "Explains a topic."
        case "documented_in_lesson":
            return object.map { "Documented in lesson \($0)." } ?? "Documented in a lesson."
        case "worth_capturing":
            return object.map { "Suggested as durable knowledge for \($0)." } ?? "Suggested as durable knowledge."
        case "surfaced_in_window":
            return object.map { "Surfaced as an issue for \($0)." } ?? "Surfaced as an issue."
        default:
            return object.map { "\(claim.predicate) — \($0)" } ?? claim.predicate
        }
    }

    private func formatTimestamp(_ value: String?) -> String {
        guard let value else { return "recently" }
        return dateSupport.localDateTimeString(from: value)
    }

    private func entitySpecificKeySignals(
        for entityType: KnowledgeEntityType,
        summaries: [String: PredicateSignalSummary]
    ) -> [String] {
        switch entityType {
        case .project:
            return compactSignalLines([
                signalLine("advanced_during_window", label: "Advanced", summaries: summaries, unit: "summary window"),
                signalLine("used_during_window", label: "Seen", summaries: summaries, unit: "captured work window"),
                signalLine(["uses_tool", "worked_with_tool"], label: "Main tools", summaries: summaries, fallbackNoun: "tool"),
                signalLine("focuses_on_topic", label: "Main focus", summaries: summaries, fallbackNoun: "topic"),
                signalLine("blocked_by_issue", label: "Recent blocker", summaries: summaries, fallbackNoun: "issue"),
                signalLine("generates_lesson", label: "Produced lesson", summaries: summaries, fallbackNoun: "lesson")
            ])
        case .tool:
            return compactSignalLines([
                signalLine("used_during_window", label: "Seen", summaries: summaries, unit: "captured work window"),
                signalLine(["supports_project", "used_in_project"], label: "Main projects", summaries: summaries, fallbackNoun: "project"),
                signalLine("works_on_topic", label: "Commonly used for", summaries: summaries, fallbackNoun: "topic"),
                signalLine("topic_in_focus", label: "Mentioned in summary focus", summaries: summaries, unit: "summary window")
            ])
        case .topic:
            return compactSignalLines([
                signalLine("topic_in_focus", label: "Focused", summaries: summaries, unit: "summary window"),
                signalLine("relevant_to_project", label: "Main projects", summaries: summaries, fallbackNoun: "project"),
                signalLine("related_topic", label: "Closest cluster", summaries: summaries, fallbackNoun: "topic"),
                signalLine("documented_in_lesson", label: "Best write-up", summaries: summaries, fallbackNoun: "lesson")
            ])
        case .lesson:
            return compactSignalLines([
                signalLine("derived_from_project", label: "Source projects", summaries: summaries, fallbackNoun: "project"),
                signalLine("explains_topic", label: "Core topic", summaries: summaries, fallbackNoun: "topic"),
                signalLine("worth_capturing", label: nil, summaries: summaries)
            ])
        case .issue:
            return compactSignalLines([
                signalLine("surfaced_in_window", label: "Surfaced", summaries: summaries, unit: "summary window"),
                signalLine("affects_project", label: "Affected", summaries: summaries, fallbackNoun: "project")
            ])
        case .model:
            return compactSignalLines([
                signalLine(["used_in_project", "uses_model"], label: "Seen on", summaries: summaries, fallbackNoun: "project")
            ])
        case .site, .person:
            return compactSignalLines([
                signalLine("used_during_window", label: "Seen", summaries: summaries, unit: "captured work window")
            ])
        }
    }

    private func compactSignalLines(_ lines: [String?]) -> [String] {
        Array(lines.compactMap { $0 }.prefix(4))
    }

    private func signalLine(
        _ predicate: String,
        label: String?,
        summaries: [String: PredicateSignalSummary],
        fallbackNoun: String? = nil,
        unit: String? = nil
    ) -> String? {
        guard let summary = summaries[predicate] else { return nil }
        return renderSignalLine(
            summary,
            label: label,
            fallbackNoun: fallbackNoun,
            unit: unit
        )
    }

    private func signalLine(
        _ predicates: [String],
        label: String?,
        summaries: [String: PredicateSignalSummary],
        fallbackNoun: String? = nil,
        unit: String? = nil
    ) -> String? {
        let matching = predicates.compactMap { summaries[$0] }
        guard !matching.isEmpty else { return nil }
        return renderSignalLine(
            mergeSignalSummaries(matching),
            label: label,
            fallbackNoun: fallbackNoun,
            unit: unit
        )
    }

    private func renderSignalLine(
        _ summary: PredicateSignalSummary,
        label: String?,
        fallbackNoun: String?,
        unit: String?
    ) -> String {
        if summary.predicate == "worth_capturing" {
            return "Captured as a durable note candidate \(summary.evidenceCount == 1 ? "once" : "\(summary.evidenceCount) times"); last seen \(formatTimestamp(summary.latest))."
        }

        if let unit {
            let phrase = "\(summary.evidenceCount) \(unit)\(summary.evidenceCount == 1 ? "" : "s")"
            if let label {
                return "\(label) in \(phrase); last seen \(formatTimestamp(summary.latest))."
            }
            return "\(phrase.capitalized); last seen \(formatTimestamp(summary.latest))."
        }

        let objectCount = summary.objectCount > 0 ? summary.objectCount : summary.evidenceCount
        let objectSummary = summarizeExamples(
            summary.examples,
            totalCount: objectCount,
            fallbackNoun: fallbackNoun ?? "item"
        )
        if let label {
            return "\(label): \(objectSummary); last seen \(formatTimestamp(summary.latest))."
        }
        return "\(objectSummary); last seen \(formatTimestamp(summary.latest))."
    }

    private func mergeSignalSummaries(_ summaries: [PredicateSignalSummary]) -> PredicateSignalSummary {
        let evidenceCount = summaries.reduce(0) { $0 + $1.evidenceCount }
        var seenExamples: Set<String> = []
        let examples = summaries.flatMap(\.examples).filter { seenExamples.insert($0).inserted }
        let latest = summaries.compactMap(\.latest).max()
        return PredicateSignalSummary(
            predicate: summaries.first?.predicate ?? "",
            evidenceCount: evidenceCount,
            objectCount: examples.count,
            examples: examples,
            latest: latest
        )
    }

    private func renderGenericSignal(_ summary: PredicateSignalSummary) -> String? {
        switch summary.predicate {
        case "advanced_during_window":
            return "Advanced in \(summary.evidenceCount) summary window\(summary.evidenceCount == 1 ? "" : "s"); last seen \(formatTimestamp(summary.latest))."
        case "surfaced_in_window":
            return "Surfaced as an issue in \(summary.evidenceCount) summary window\(summary.evidenceCount == 1 ? "" : "s"); last seen \(formatTimestamp(summary.latest))."
        case "used_during_window":
            return "Seen in \(summary.evidenceCount) captured work window\(summary.evidenceCount == 1 ? "" : "s"); last seen \(formatTimestamp(summary.latest))."
        case "topic_in_focus":
            return "Focus topic in \(summary.evidenceCount) summary window\(summary.evidenceCount == 1 ? "" : "s"); last seen \(formatTimestamp(summary.latest))."
        case "related_topic":
            return "Related to \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "topic")); last seen \(formatTimestamp(summary.latest))."
        case "uses_tool", "worked_with_tool":
            return "Worked with \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "tool")); last seen \(formatTimestamp(summary.latest))."
        case "supports_project":
            return "Supported \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "project")); last seen \(formatTimestamp(summary.latest))."
        case "works_on_topic":
            return "Used on \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "topic")); last seen \(formatTimestamp(summary.latest))."
        case "focuses_on_topic":
            return "Focus topic: \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "topic")); last seen \(formatTimestamp(summary.latest))."
        case "relevant_to_project":
            return "Relevant to \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "project")); last seen \(formatTimestamp(summary.latest))."
        case "blocked_by_issue":
            return "Blocked by \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "issue")); last seen \(formatTimestamp(summary.latest))."
        case "affects_project":
            return "Affected \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "project")); last seen \(formatTimestamp(summary.latest))."
        case "uses_model":
            return "Used with \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "model")); last seen \(formatTimestamp(summary.latest))."
        case "used_in_project":
            return "Used in \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "project")); last seen \(formatTimestamp(summary.latest))."
        case "generates_lesson":
            return "Generated \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "lesson")); last seen \(formatTimestamp(summary.latest))."
        case "derived_from_project":
            return "Derived from \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "project")); last seen \(formatTimestamp(summary.latest))."
        case "explains_topic":
            return "Explains \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "topic")); last seen \(formatTimestamp(summary.latest))."
        case "documented_in_lesson":
            return "Documented in \(summarizeExamples(summary.examples, totalCount: summary.objectCount, fallbackNoun: "lesson")); last seen \(formatTimestamp(summary.latest))."
        case "worth_capturing":
            return "Captured as a durable note candidate \(summary.evidenceCount == 1 ? "once" : "\(summary.evidenceCount) times"); last seen \(formatTimestamp(summary.latest))."
        default:
            return nil
        }
    }

    private func predicateExampleObjects(
        from claims: [KnowledgeClaimRecord],
        predicate: String,
        visibleRelationObjects: Set<String>,
        priority: [String: Int]
    ) -> [String] {
        let uniqueExamples = Array(Set(claims.compactMap {
            filteredExampleObject(
                from: $0,
                predicate: predicate,
                visibleRelationObjects: visibleRelationObjects
            )
        })).filter { !$0.isEmpty }

        return uniqueExamples.sorted { lhs, rhs in
            let lhsPriority = priority[lhs] ?? Int.max
            let rhsPriority = priority[rhs] ?? Int.max
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs < rhs
        }
    }

    private func examplePriorityMap(
        for entity: KnowledgeEntityRecord,
        from references: [RelatedKnowledgeReference]
    ) -> [String: Int] {
        var ranking: [String: Int] = [:]
        let orderedReferences = groupedRelatedEntities(references, for: entity).flatMap(\.references)
        for (index, reference) in orderedReferences.enumerated() {
            ranking[reference.entity.canonicalName] = min(ranking[reference.entity.canonicalName] ?? Int.max, index)
        }
        return ranking
    }

    private func topRelatedNames(
        _ references: [RelatedKnowledgeReference]?,
        limit: Int
    ) -> [String] {
        Array((references ?? []).prefix(limit).map { $0.entity.canonicalName })
    }

    private func sortedRelatedReferences(
        _ references: [RelatedKnowledgeReference],
        for entityType: KnowledgeEntityType,
        relatedType: KnowledgeEntityType
    ) -> [RelatedKnowledgeReference] {
        references
            .filter { $0.entity.entityType == relatedType }
            .sorted { lhs, rhs in
                let lhsPriority = relationPriority(lhs.edgeType, for: entityType, relatedType: relatedType)
                let rhsPriority = relationPriority(rhs.edgeType, for: entityType, relatedType: relatedType)
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.entity.canonicalName < rhs.entity.canonicalName
            }
    }

    private func summarizeExamples(
        _ examples: [String],
        totalCount: Int,
        fallbackNoun: String
    ) -> String {
        guard !examples.isEmpty else {
            return "\(totalCount) \(fallbackNoun)\(totalCount == 1 ? "" : "s")"
        }

        let visibleExamples = Array(examples.prefix(2))
        let remaining = max(totalCount - visibleExamples.count, 0)
        if remaining > 0 {
            return visibleExamples.joined(separator: ", ") + " and \(remaining) more"
        }
        return joinNaturalLanguage(visibleExamples)
    }

    private func filteredExampleObject(
        from claim: KnowledgeClaimRecord,
        predicate: String,
        visibleRelationObjects: Set<String>
    ) -> String? {
        guard let object = claim.objectText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !object.isEmpty else {
            return nil
        }

        switch predicate {
        case "focuses_on_topic", "relevant_to_project":
            guard graphShaper.isMeaningfulProjectRelationTopic(object) else { return nil }
            return visibleRelationObjects.isEmpty || visibleRelationObjects.contains(object) ? object : nil
        case "related_topic", "uses_tool", "supports_project", "works_on_topic", "worked_with_tool", "uses_model", "used_in_project", "blocked_by_issue",
             "affects_project", "generates_lesson", "derived_from_project", "explains_topic", "documented_in_lesson":
            return visibleRelationObjects.isEmpty || visibleRelationObjects.contains(object) ? object : nil
        default:
            return object
        }
    }

    private func selectedRecentClaims(
        from claims: [KnowledgeClaimRecord],
        for entity: KnowledgeEntityRecord,
        visibleRelationObjects: Set<String>,
        limit: Int = 8
    ) -> [KnowledgeClaimRecord] {
        let ordered = claims.sorted { lhs, rhs in
            let lhsTimestamp = claimSortTimestamp(lhs)
            let rhsTimestamp = claimSortTimestamp(rhs)
            if lhsTimestamp != rhsTimestamp {
                return lhsTimestamp > rhsTimestamp
            }

            let lhsPriority = recentClaimPriority(lhs, entityType: entity.entityType)
            let rhsPriority = recentClaimPriority(rhs, entityType: entity.entityType)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }

            let lhsSourcePriority = sourceKindPriority(lhs.sourceKind)
            let rhsSourcePriority = sourceKindPriority(rhs.sourceKind)
            if lhsSourcePriority != rhsSourcePriority {
                return lhsSourcePriority > rhsSourcePriority
            }

            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }

            return (lhs.objectText ?? "") < (rhs.objectText ?? "")
        }

        var selected: [KnowledgeClaimRecord] = []
        var seenSignatures: Set<String> = []
        var relationCountsByWindow: [String: Int] = [:]
        var predicateCountsByWindow: [String: Int] = [:]

        for claim in ordered {
            guard shouldShowInRecentWindows(
                claim,
                entityType: entity.entityType,
                visibleRelationObjects: visibleRelationObjects
            ) else {
                continue
            }

            let signature = claimSignature(claim)
            guard seenSignatures.insert(signature).inserted else { continue }

            let windowKey = claimWindowKey(claim)
            let predicateWindowKey = "\(windowKey)|\(claim.predicate)"

            if isRelationClaim(claim) {
                if relationCountsByWindow[windowKey, default: 0] >= maxRelationClaimsPerWindow(for: entity.entityType) {
                    continue
                }
                if predicateCountsByWindow[predicateWindowKey, default: 0] >= maxRelationClaimsPerPredicate(
                    for: entity.entityType,
                    predicate: claim.predicate
                ) {
                    continue
                }
            } else if predicateCountsByWindow[predicateWindowKey, default: 0] >= 1 {
                continue
            }

            selected.append(claim)
            predicateCountsByWindow[predicateWindowKey, default: 0] += 1
            if isRelationClaim(claim) {
                relationCountsByWindow[windowKey, default: 0] += 1
            }

            if selected.count == limit {
                break
            }
        }

        return selected
    }

    private func renderRecentWindowEntries(
        from claims: [KnowledgeClaimRecord],
        entityType: KnowledgeEntityType,
        windowContexts: [String: String]
    ) -> [(when: String, description: String)] {
        var claimsByWindow: [String: [KnowledgeClaimRecord]] = [:]

        for claim in claims {
            let windowKey = claimWindowKey(claim)
            claimsByWindow[windowKey, default: []].append(claim)
        }

        let orderedWindowKeys = claimsByWindow.keys.sorted { lhs, rhs in
            let lhsClaims = claimsByWindow[lhs] ?? []
            let rhsClaims = claimsByWindow[rhs] ?? []
            let lhsScore = recentWindowScore(
                for: lhsClaims,
                entityType: entityType,
                context: windowContexts[lhs]
            )
            let rhsScore = recentWindowScore(
                for: rhsClaims,
                entityType: entityType,
                context: windowContexts[rhs]
            )
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return recentWindowSortTimestamp(for: lhsClaims) > recentWindowSortTimestamp(for: rhsClaims)
        }

        return orderedWindowKeys.compactMap { windowKey in
            guard let windowClaims = claimsByWindow[windowKey], !windowClaims.isEmpty else {
                return nil
            }

            let when = windowClaims.first?.windowStart.map { dateSupport.localDateTimeString(from: $0) }
                ?? windowClaims.first?.sourceSummaryGeneratedAt.map { dateSupport.localDateTimeString(from: $0) }
                ?? "unknown time"

            var seenFragments = Set<String>()
            let fragments = windowClaims.compactMap { claim -> String? in
                let fragment = describeRecentWindowClaim(claim, entityType: entityType)
                guard seenFragments.insert(fragment).inserted else { return nil }
                return fragment
            }

            guard !fragments.isEmpty else { return nil }
            var description = buildRecentWindowNarrative(
                fragments: fragments,
                entityType: entityType
            )
            if let context = windowContexts[windowKey], !context.isEmpty {
                description += " Context: \(context)"
            }
            return (when: when, description: description)
        }
    }

    private func recentWindowScore(
        for claims: [KnowledgeClaimRecord],
        entityType: KnowledgeEntityType,
        context: String?
    ) -> Int {
        let relationBonus = claims.reduce(0) { partial, claim in
            partial + recentClaimPriority(claim, entityType: entityType)
        }
        let sourceBonus = claims.reduce(0) { partial, claim in
            partial + sourceKindPriority(claim.sourceKind)
        }
        let contextBonus = (context?.isEmpty == false) ? 6 : 0
        let activityBonus = claims.contains { claim in
            ["used_during_window", "advanced_during_window", "surfaced_in_window", "topic_in_focus"].contains(claim.predicate)
        } ? 4 : 0
        return relationBonus + sourceBonus + contextBonus + activityBonus
    }

    private func recentWindowSortTimestamp(for claims: [KnowledgeClaimRecord]) -> String {
        claims
            .map(claimSortTimestamp)
            .max() ?? ""
    }

    private func describeRecentWindowClaim(_ claim: KnowledgeClaimRecord, entityType: KnowledgeEntityType) -> String {
        let object = claim.objectText?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch claim.predicate {
        case "used_during_window":
            return object.map { "active during \($0)" } ?? "active in a captured work window"
        case "advanced_during_window":
            return "advanced in the summary"
        case "topic_in_focus":
            return entityType == .topic ? "in focus during the summary" : "in focus for the summary"
        case "related_topic":
            return object.map { "near \($0)" } ?? "near another topic"
        case "uses_tool":
            return object.map { "with \($0)" } ?? "with a tool"
        case "supports_project":
            if entityType == .tool {
                return object.map { "used while working on \($0)" } ?? "used while working on a project"
            }
            return object.map { "supporting \($0)" } ?? "supporting a project"
        case "works_on_topic":
            if entityType == .tool {
                return object.map { "exploring \($0)" } ?? "exploring a topic"
            }
            return object.map { "used on \($0)" } ?? "used on a topic"
        case "worked_with_tool":
            return object.map { "with \($0)" } ?? "with a tool"
        case "focuses_on_topic":
            return object.map { "focused on \($0)" } ?? "focused on a topic"
        case "relevant_to_project":
            if entityType == .topic {
                return object.map { "active around \($0)" } ?? "active around a project"
            }
            return object.map { "tied to \($0)" } ?? "tied to a project"
        case "blocked_by_issue":
            return object.map { "blocked by \($0)" } ?? "blocked by an issue"
        case "affects_project":
            return object.map { "affected \($0)" } ?? "affected a project"
        case "uses_model":
            return object.map { "using \($0)" } ?? "using a model"
        case "used_in_project":
            if entityType == .model {
                return object.map { "used on \($0)" } ?? "used on a project"
            }
            return object.map { "used in \($0)" } ?? "used in a project"
        case "generates_lesson":
            return object.map { "generated lesson \($0)" } ?? "generated a lesson"
        case "derived_from_project":
            if entityType == .lesson {
                return object.map { "distilled from \($0)" } ?? "distilled from a project"
            }
            return object.map { "derived from \($0)" } ?? "derived from a project"
        case "explains_topic":
            if entityType == .lesson {
                return object.map { "covering \($0)" } ?? "covering a topic"
            }
            return object.map { "explains \($0)" } ?? "explains a topic"
        case "documented_in_lesson":
            if entityType == .topic {
                return object.map { "explained in \($0)" } ?? "explained in a lesson"
            }
            return object.map { "documented in \($0)" } ?? "documented in a lesson"
        case "worth_capturing":
            return "captured as a durable note candidate"
        case "surfaced_in_window":
            return object.map { "surfaced as an issue for \($0)" } ?? "surfaced as an issue"
        default:
            return describe(claim: claim).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
    }

    private func buildRecentWindowNarrative(
        fragments: [String],
        entityType: KnowledgeEntityType
    ) -> String {
        let uniqueFragments = Array(NSOrderedSet(array: fragments)) as? [String] ?? fragments
        let ordered = uniqueFragments.enumerated().sorted { lhs, rhs in
            let lhsPriority = recentWindowFragmentPriority(lhs.element, entityType: entityType)
            let rhsPriority = recentWindowFragmentPriority(rhs.element, entityType: entityType)
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        guard let first = ordered.first else { return "" }
        let tail = Array(ordered.dropFirst())
        let sentenceBody: String
        if tail.isEmpty {
            sentenceBody = first
        } else {
            sentenceBody = ([first] + tail).joined(separator: ", ")
        }
        return uppercaseFirst(sentenceBody) + "."
    }

    private func recentWindowFragmentPriority(_ fragment: String, entityType: KnowledgeEntityType) -> Int {
        let normalized = fragment.lowercased()
        if normalized.hasPrefix("active during") || normalized.hasPrefix("surfaced as an issue") {
            return 6
        }
        if normalized.hasPrefix("advanced in the summary")
            || normalized.hasPrefix("in focus for the summary")
            || normalized.hasPrefix("in focus during the summary") {
            return 5
        }
        if normalized.hasPrefix("with ") || normalized.hasPrefix("focused on ") || normalized.hasPrefix("using ")
            || normalized.hasPrefix("used while working on ") || normalized.hasPrefix("exploring ") {
            return entityType == .project ? 4 : 3
        }
        if normalized.hasPrefix("derived from ") || normalized.hasPrefix("distilled from ")
            || normalized.hasPrefix("explains ") || normalized.hasPrefix("covering ") {
            return entityType == .lesson ? 4 : 3
        }
        if normalized.hasPrefix("near ") || normalized.hasPrefix("tied to ") || normalized.hasPrefix("active around ") {
            return 2
        }
        return 1
    }

    private func uppercaseFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }

    private func buildWindowContextSnippets(
        for entity: KnowledgeEntityRecord,
        aliases: [String],
        claims: [KnowledgeClaimRecord]
    ) throws -> [String: String] {
        switch entity.entityType {
        case .project, .topic, .lesson:
            break
        default:
            return [:]
        }

        var snippets: [String: String] = [:]
        var summaryCache: [String: String?] = [:]
        for claim in claims {
            let windowKey = claimWindowKey(claim)
            guard snippets[windowKey] == nil else { continue }

            let summaryLookupKey = [
                claim.sourceSummaryDate ?? "",
                claim.sourceSummaryGeneratedAt ?? ""
            ].joined(separator: "|")

            let summaryText: String?
            if let cached = summaryCache[summaryLookupKey] {
                summaryText = cached
            } else {
                let loaded = try loadSummaryText(
                    date: claim.sourceSummaryDate,
                    generatedAt: claim.sourceSummaryGeneratedAt
                )
                summaryCache[summaryLookupKey] = loaded
                summaryText = loaded
            }

            guard let summaryText,
                  let snippet = extractEntityContextSnippet(
                    from: summaryText,
                    entityType: entity.entityType,
                    canonicalName: entity.canonicalName,
                    aliases: aliases
                  ) else {
                continue
            }
            snippets[windowKey] = snippet
        }

        return snippets
    }

    private func loadSummaryText(date: String?, generatedAt: String?) throws -> String? {
        if let generatedAt, !generatedAt.isEmpty {
            let rows = try db.query("""
                SELECT summary_text
                FROM daily_summaries
                WHERE generated_at = ?
                LIMIT 1
            """, params: [.text(generatedAt)])
            return rows.first?["summary_text"]?.textValue
        }

        guard let date, !date.isEmpty else { return nil }
        let rows = try db.query("""
            SELECT summary_text
            FROM daily_summaries
            WHERE date = ?
            LIMIT 1
        """, params: [.text(date)])
        return rows.first?["summary_text"]?.textValue
    }

    private func extractEntityContextSnippet(
        from summaryText: String,
        entityType: KnowledgeEntityType,
        canonicalName: String,
        aliases: [String]
    ) -> String? {
        let matchingNames = [canonicalName] + aliases
        switch entityType {
        case .project:
            if let projectSectionSnippet = extractProjectSectionSnippet(
                from: summaryText,
                matchingNames: matchingNames
            ) {
                return projectSectionSnippet
            }
            if let summarySentence = extractFallbackSummarySentence(
                from: summaryText,
                matchingNames: matchingNames
            ) {
                return summarySentence
            }
            return extractMatchingBulletSnippet(
                from: summaryText,
                matchingNames: matchingNames,
                preferredSections: ["проекты и код", "детальный таймлайн"]
            )
        case .topic:
            if let summarySentence = extractFallbackSummarySentence(
                from: summaryText,
                matchingNames: matchingNames
            ) {
                return summarySentence
            }
            return extractMatchingBulletSnippet(
                from: summaryText,
                matchingNames: matchingNames,
                preferredSections: ["что изучал / читал", "инструменты и технологии", "проекты и код"]
            )
        case .lesson:
            if let suggestedNoteSnippet = extractMatchingBulletSnippet(
                from: summaryText,
                matchingNames: matchingNames,
                preferredSections: ["предлагаемые заметки"]
            ) {
                return suggestedNoteSnippet
            }
            return extractFallbackSummarySentence(
                from: summaryText,
                matchingNames: matchingNames
            )
        default:
            return nil
        }
    }

    private func extractProjectSectionSnippet(
        from summaryText: String,
        matchingNames: [String]
    ) -> String? {
        let lines = summaryText.components(separatedBy: .newlines)
        var inProjectsSection = false
        var collectingTarget = false
        var detailLines: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                let heading = stripKnowledgeMarkdown(String(line.dropFirst(3)))
                if heading.caseInsensitiveCompare("Проекты и код") == .orderedSame {
                    inProjectsSection = true
                    collectingTarget = false
                    detailLines = []
                    continue
                }
                if inProjectsSection {
                    break
                }
            }

            guard inProjectsSection else { continue }

            if line.hasPrefix("### ") {
                if collectingTarget && !detailLines.isEmpty {
                    break
                }
                let heading = stripKnowledgeMarkdown(String(line.dropFirst(4)))
                collectingTarget = matchesAnyKnowledgeName(heading, names: matchingNames)
                detailLines = []
                continue
            }

            guard collectingTarget else { continue }
            if line.hasPrefix("- ") {
                let cleaned = extractBulletDetail(from: line)
                if !cleaned.isEmpty {
                    detailLines.append(cleaned)
                }
            } else if !line.isEmpty && !detailLines.isEmpty {
                break
            }
        }

        guard !detailLines.isEmpty else { return nil }
        return condensedContextSnippet(from: Array(detailLines.prefix(2)))
    }

    private func extractFallbackSummarySentence(
        from summaryText: String,
        matchingNames: [String]
    ) -> String? {
        let summarySection = summaryText
            .components(separatedBy: "\n## ")
            .first ?? summaryText
        let plain = stripLeadingSummaryLabel(from: stripKnowledgeMarkdown(summarySection))
        let sentences = plain.split(whereSeparator: \.isNewline)
            .flatMap { $0.split(separator: ".", omittingEmptySubsequences: true) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            if matchesAnyKnowledgeName(sentence, names: matchingNames) {
                return condensedContextSnippet(from: [sentence + "."])
            }
        }

        return nil
    }

    private func stripLeadingSummaryLabel(from value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["summary ", "сводка "]
        for prefix in prefixes {
            if trimmed.lowercased().hasPrefix(prefix) {
                return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    private func extractMatchingBulletSnippet(
        from summaryText: String,
        matchingNames: [String],
        preferredSections: [String]
    ) -> String? {
        let preferred = Set(preferredSections.map { normalizedKnowledgeText($0) })
        let lines = summaryText.components(separatedBy: .newlines)
        var currentSection = ""
        var bestPreferredMatches: [String] = []
        var bestFallbackMatches: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                currentSection = normalizedKnowledgeText(String(line.dropFirst(3)))
                continue
            }

            guard line.hasPrefix("- ") else { continue }
            let plain = stripKnowledgeMarkdown(line)
            guard matchesAnyKnowledgeName(plain, names: matchingNames) else { continue }

            let detail = extractBulletDetail(from: line)
            guard !detail.isEmpty else { continue }

            if preferred.contains(currentSection) {
                bestPreferredMatches.append(detail)
            } else {
                bestFallbackMatches.append(detail)
            }
        }

        if !bestPreferredMatches.isEmpty {
            return condensedContextSnippet(from: Array(bestPreferredMatches.prefix(2)))
        }
        if !bestFallbackMatches.isEmpty {
            return condensedContextSnippet(from: Array(bestFallbackMatches.prefix(2)))
        }
        return nil
    }

    private func extractBulletDetail(from line: String) -> String {
        let withoutBullet = line.replacingOccurrences(
            of: #"^\-\s*"#,
            with: "",
            options: .regularExpression
        )
        let plain = stripKnowledgeMarkdown(withoutBullet)
        let value: String
        if let separatorRange = plain.range(of: " — ") {
            value = String(plain[separatorRange.upperBound...])
        } else if let separatorRange = plain.range(of: " – ") {
            value = String(plain[separatorRange.upperBound...])
        } else if let separatorRange = plain.range(of: " - ") {
            value = String(plain[separatorRange.upperBound...])
        } else if let colonIndex = plain.firstIndex(of: ":") {
            value = String(plain[plain.index(after: colonIndex)...])
        } else {
            value = plain
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func condensedContextSnippet(from parts: [String], maxLength: Int = 220) -> String {
        let joined = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard joined.count > maxLength else { return joined }
        let cutoffIndex = joined.index(joined.startIndex, offsetBy: maxLength)
        let truncated = String(joined[..<cutoffIndex])
        if let lastSpace = truncated.lastIndex(of: " ") {
            return String(truncated[..<lastSpace]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }
        return truncated.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private func matchesAnyKnowledgeName(_ text: String, names: [String]) -> Bool {
        let normalizedText = normalizedKnowledgeText(text)
        guard !normalizedText.isEmpty else { return false }
        return names.contains { name in
            let normalizedName = normalizedKnowledgeText(name)
            return !normalizedName.isEmpty && normalizedText.contains(normalizedName)
        }
    }

    private func normalizedKnowledgeText(_ value: String) -> String {
        stripKnowledgeMarkdown(value)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func stripKnowledgeMarkdown(_ value: String) -> String {
        var cleaned = value
        cleaned = cleaned.replacingOccurrences(
            of: #"(?m)^\s*#+\s*"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\[\[([^\]|]+)\|([^\]]+)\]\]"#,
            with: "$2",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\[\[([^\]]+)\]\]"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "**", with: "")
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")
        return cleaned
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldShowInRecentWindows(
        _ claim: KnowledgeClaimRecord,
        entityType: KnowledgeEntityType,
        visibleRelationObjects: Set<String>
    ) -> Bool {
        guard shouldShowForVisibleRelations(claim, visibleRelationObjects: visibleRelationObjects) else {
            return false
        }

        switch claim.predicate {
        case "topic_in_focus":
            return entityType == .topic
        case "focuses_on_topic", "relevant_to_project":
            if let object = claim.objectText?.trimmingCharacters(in: .whitespacesAndNewlines) {
                return graphShaper.isMeaningfulProjectRelationTopic(object)
            }
            return false
        default:
            return true
        }
    }

    private func shouldShowForVisibleRelations(
        _ claim: KnowledgeClaimRecord,
        visibleRelationObjects: Set<String>
    ) -> Bool {
        guard isRelationClaim(claim),
              let object = claim.objectText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !object.isEmpty else {
            return true
        }

        return visibleRelationObjects.isEmpty || visibleRelationObjects.contains(object)
    }

    private func claimSortTimestamp(_ claim: KnowledgeClaimRecord) -> String {
        claim.windowEnd
            ?? claim.windowStart
            ?? claim.sourceSummaryGeneratedAt
            ?? ""
    }

    private func claimWindowKey(_ claim: KnowledgeClaimRecord) -> String {
        [
            claim.windowStart ?? "",
            claim.windowEnd ?? "",
            claim.sourceSummaryGeneratedAt ?? "",
            claim.sourceSummaryDate ?? ""
        ].joined(separator: "|")
    }

    private func claimSignature(_ claim: KnowledgeClaimRecord) -> String {
        [
            claimWindowKey(claim),
            claim.predicate,
            claim.objectText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            claim.sourceKind ?? ""
        ].joined(separator: "|")
    }

    private func isRelationClaim(_ claim: KnowledgeClaimRecord) -> Bool {
        claim.sourceKind == "relation_inference"
    }

    private func maxRelationClaimsPerWindow(for entityType: KnowledgeEntityType) -> Int {
        switch entityType {
        case .project:
            return 3
        case .topic, .lesson:
            return 2
        default:
            return 2
        }
    }

    private func maxRelationClaimsPerPredicate(for entityType: KnowledgeEntityType, predicate: String) -> Int {
        switch (entityType, predicate) {
        case (.project, "uses_tool"), (.tool, "supports_project"):
            return 2
        case (.tool, "works_on_topic"), (.topic, "worked_with_tool"):
            return 2
        case (.topic, "related_topic"):
            return 2
        default:
            return 1
        }
    }

    private func recentClaimPriority(_ claim: KnowledgeClaimRecord, entityType: KnowledgeEntityType) -> Int {
        switch claim.predicate {
        case "advanced_during_window", "surfaced_in_window", "used_during_window":
            return 6
        case "topic_in_focus":
            return entityType == .topic ? 6 : 1
        case "related_topic":
            return entityType == .topic ? 5 : 2
        case "blocked_by_issue", "affects_project":
            return 5
        case "uses_tool", "supports_project", "works_on_topic", "worked_with_tool":
            return 4
        case "focuses_on_topic", "relevant_to_project", "uses_model", "used_in_project", "generates_lesson", "derived_from_project":
            return 3
        case "explains_topic", "documented_in_lesson", "worth_capturing":
            return 2
        default:
            return 1
        }
    }

    private func sourceKindPriority(_ sourceKind: String?) -> Int {
        switch sourceKind {
        case "hourly_summary":
            return 3
        case "summary_suggestion":
            return 2
        case "relation_inference":
            return 1
        default:
            return 0
        }
    }

    private func prefer(
        _ candidate: RelatedKnowledgeReference,
        over existing: RelatedKnowledgeReference
    ) -> RelatedKnowledgeReference {
        let candidatePriority = relationPriority(candidate.edgeType)
        let existingPriority = relationPriority(existing.edgeType)
        if candidatePriority != existingPriority {
            return candidatePriority > existingPriority ? candidate : existing
        }
        if candidate.weight != existing.weight {
            return candidate.weight > existing.weight ? candidate : existing
        }
        return candidate
    }

    private func relationPriority(_ edgeType: String) -> Int {
        switch edgeType {
        case "blocked_by_issue", "uses_tool", "works_on_topic", "focuses_on_topic", "uses_model", "generates_lesson", "explains_topic":
            return 3
        case "related_topic":
            return 2
        case "co_occurs_with":
            return 1
        default:
            return 2
        }
    }

    private func groupedRelatedEntities(
        _ references: [RelatedKnowledgeReference],
        for entity: KnowledgeEntityRecord
    ) -> [(type: KnowledgeEntityType, references: [RelatedKnowledgeReference])] {
        let grouped = Dictionary(grouping: references, by: { $0.entity.entityType })

        let orderedTypes = KnowledgeEntityType.allCases.sorted { lhs, rhs in
            let lhsPriority = relationshipSectionPriority(relatedType: lhs, for: entity.entityType)
            let rhsPriority = relationshipSectionPriority(relatedType: rhs, for: entity.entityType)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.folderName < rhs.folderName
        }

        return orderedTypes.compactMap { type in
            guard let group = grouped[type], !group.isEmpty else { return nil }
            let orderedReferences = group.sorted { lhs, rhs in
                let lhsPriority = relationPriority(
                    lhs.edgeType,
                    for: entity.entityType,
                    relatedType: lhs.entity.entityType
                )
                let rhsPriority = relationPriority(
                    rhs.edgeType,
                    for: entity.entityType,
                    relatedType: rhs.entity.entityType
                )
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.entity.canonicalName < rhs.entity.canonicalName
            }

            let limit = maxRelationshipsPerSection(for: entity.entityType, relatedType: type)
            return (type, Array(orderedReferences.prefix(limit)))
        }
    }

    private func relationshipSectionPriority(
        relatedType: KnowledgeEntityType,
        for entityType: KnowledgeEntityType
    ) -> Int {
        let order: [KnowledgeEntityType]
        switch entityType {
        case .project:
            order = [.tool, .topic, .issue, .lesson, .model, .project, .site, .person]
        case .tool:
            order = [.project, .topic, .model, .tool, .issue, .lesson, .site, .person]
        case .topic:
            order = [.project, .lesson, .tool, .topic, .issue, .model, .site, .person]
        case .lesson:
            order = [.project, .topic, .tool, .lesson, .issue, .model, .site, .person]
        case .issue:
            order = [.project, .tool, .topic, .lesson, .model, .issue, .site, .person]
        case .model:
            order = [.project, .tool, .topic, .lesson, .model, .issue, .site, .person]
        case .site, .person:
            order = [.project, .tool, .topic, .lesson, .model, .issue, .site, .person]
        }

        return order.firstIndex(of: relatedType) ?? order.count
    }

    private func relationPriority(
        _ edgeType: String,
        for entityType: KnowledgeEntityType,
        relatedType: KnowledgeEntityType
    ) -> Int {
        switch entityType {
        case .project:
            switch edgeType {
            case "uses_tool", "worked_with_tool", "focuses_on_topic", "blocked_by_issue":
                return 6
            case "generates_lesson", "uses_model":
                return 5
            case "co_occurs_with":
                return relatedType == .project ? 1 : 2
            default:
                return relationPriority(edgeType)
            }
        case .tool:
            switch edgeType {
            case "uses_tool", "supports_project", "used_in_project":
                return 6
            case "works_on_topic":
                return 5
            case "co_occurs_with":
                return relatedType == .tool ? 1 : 2
            default:
                return relationPriority(edgeType)
            }
        case .topic:
            switch edgeType {
            case "focuses_on_topic", "relevant_to_project":
                return 6
            case "explains_topic", "documented_in_lesson":
                return 5
            case "worked_with_tool", "related_topic":
                return 4
            case "co_occurs_with":
                return relatedType == .topic ? 1 : 2
            default:
                return relationPriority(edgeType)
            }
        case .lesson:
            switch edgeType {
            case "generates_lesson", "derived_from_project":
                return 6
            case "explains_topic", "documented_in_lesson":
                return 5
            case "co_occurs_with":
                return relatedType == .lesson ? 1 : 2
            default:
                return relationPriority(edgeType)
            }
        case .issue:
            switch edgeType {
            case "blocked_by_issue", "affects_project":
                return 6
            case "co_occurs_with":
                return 1
            default:
                return relationPriority(edgeType)
            }
        case .model:
            switch edgeType {
            case "uses_model", "used_in_project":
                return 6
            case "co_occurs_with":
                return relatedType == .model ? 1 : 2
            default:
                return relationPriority(edgeType)
            }
        case .site, .person:
            switch edgeType {
            case "co_occurs_with":
                return 1
            default:
                return relationPriority(edgeType)
            }
        }
    }

    private func maxRelationshipsPerSection(
        for entityType: KnowledgeEntityType,
        relatedType: KnowledgeEntityType
    ) -> Int {
        switch entityType {
        case .project:
            switch relatedType {
            case .tool: return 5
            case .topic: return 6
            case .project: return 2
            default: return 3
            }
        case .tool:
            switch relatedType {
            case .project: return 4
            case .topic: return 3
            case .tool: return 5
            default: return 2
            }
        case .topic:
            switch relatedType {
            case .project, .lesson: return 3
            case .topic: return 5
            case .tool: return 3
            default: return 2
            }
        case .lesson:
            switch relatedType {
            case .project, .topic: return 3
            case .tool: return 2
            default: return 2
            }
        case .issue:
            switch relatedType {
            case .project: return 4
            case .tool, .topic: return 3
            default: return 2
            }
        case .model:
            switch relatedType {
            case .project: return 4
            case .tool: return 3
            case .topic: return 2
            default: return 2
            }
        case .site, .person:
            return 3
        }
    }

    private func filteredRelatedReferences(
        _ references: [RelatedKnowledgeReference],
        for entity: KnowledgeEntityRecord
    ) -> [RelatedKnowledgeReference] {
        references.filter { reference in
            if entity.entityType == .lesson &&
                reference.entity.entityType == .lesson &&
                reference.edgeType == "co_occurs_with" {
                return false
            }
            return true
        }
    }

    private func joinNaturalLanguage(_ parts: [String]) -> String {
        switch parts.count {
        case 0:
            return ""
        case 1:
            return parts[0]
        case 2:
            return "\(parts[0]) and \(parts[1])"
        default:
            let head = parts.dropLast().joined(separator: ", ")
            return "\(head), and \(parts.last!)"
        }
    }

    private func describe(relationship: RelatedKnowledgeReference, for entity: KnowledgeEntityRecord) -> String {
        switch relationship.edgeType {
        case "uses_tool":
            return relationship.direction == .outgoing
                ? "used while working on this project"
                : "project where this tool showed up"
        case "works_on_topic":
            return relationship.direction == .outgoing
                ? "topic this tool was used to explore"
                : "tool often used while exploring this topic"
        case "related_topic":
            return "part of the same working cluster"
        case "focuses_on_topic":
            return relationship.direction == .outgoing
                ? "topic that became central in this project"
                : "project where this topic became central"
        case "blocked_by_issue":
            return relationship.direction == .outgoing
                ? "issue that blocked this project"
                : "project impacted by this issue"
        case "uses_model":
            return relationship.direction == .outgoing
                ? "model used in this project"
                : "project where this model was used"
        case "generates_lesson":
            return relationship.direction == .outgoing
                ? "lesson distilled out of this project"
                : "source project behind this lesson"
        case "explains_topic":
            return relationship.direction == .outgoing
                ? "topic this lesson helps explain"
                : "lesson that captures this topic"
        case "co_occurs_with":
            return "often appeared in the same work windows"
        default:
            return relationship.edgeType.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func linkTarget(for entity: KnowledgeEntityRecord) -> String {
        "Knowledge/\(entity.entityType.folderName)/\(entity.slug)"
    }

    private func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
