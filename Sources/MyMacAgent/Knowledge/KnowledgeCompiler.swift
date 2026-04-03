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

final class KnowledgeCompiler {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport
    private let normalizer: EntityNormalizer
    private let graphShaper = GraphShaper()

    init(
        db: DatabaseManager,
        timeZone: TimeZone = .autoupdatingCurrent,
        normalizer: EntityNormalizer = EntityNormalizer()
    ) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.normalizer = normalizer
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
        let markdown = renderMarkdown(entity: entity, claims: claims, relatedReferences: relatedReferences)
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
        relatedReferences: [RelatedKnowledgeReference]
    ) -> String {
        let visibleRelationObjects = Set(relatedReferences.map { $0.entity.canonicalName })
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

        let aliases = aliases(for: entity)
        if !aliases.isEmpty {
            markdown += "## Aliases\n"
            for alias in aliases {
                markdown += "- \(alias)\n"
            }
            markdown += "\n"
        }

        let signals = keySignals(for: entity, claims: claims, visibleRelationObjects: visibleRelationObjects)
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
            for claim in recentClaims {
                let when = claim.windowStart.map { dateSupport.localDateTimeString(from: $0) }
                    ?? claim.sourceSummaryGeneratedAt.map { dateSupport.localDateTimeString(from: $0) }
                    ?? "unknown time"
                let description = describe(claim: claim)
                markdown += "- [\(when)] \(description)\n"
            }
            markdown += "\n"
        }

        if !relatedReferences.isEmpty {
            markdown += "## Relationships\n"
            for group in groupedRelatedEntities(relatedReferences) {
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

    private func aliases(for entity: KnowledgeEntityRecord) -> [String] {
        guard let aliasesJson = entity.aliasesJson,
              let data = aliasesJson.data(using: .utf8),
              let aliases = try? JSONSerialization.jsonObject(with: data) as? [String] else {
            return []
        }

        return aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(entity.canonicalName) != .orderedSame }
            .sorted()
    }

    private func keySignals(
        for entity: KnowledgeEntityRecord,
        claims: [KnowledgeClaimRecord],
        visibleRelationObjects: Set<String>
    ) -> [String] {
        let grouped = Dictionary(grouping: claims, by: \.predicate)
        let orderedPredicates = [
            "advanced_during_window",
            "surfaced_in_window",
            "used_during_window",
            "topic_in_focus",
            "uses_tool",
            "supports_project",
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

        return orderedPredicates.compactMap { predicate in
            guard let predicateClaims = grouped[predicate], !predicateClaims.isEmpty else {
                return nil
            }

            let filteredClaims = predicateClaims.filter {
                shouldShowForVisibleRelations($0, visibleRelationObjects: visibleRelationObjects)
            }
            guard !filteredClaims.isEmpty else { return nil }

            let count = filteredClaims.count
            let examples = predicateExamples(
                from: filteredClaims,
                predicate: predicate,
                visibleRelationObjects: visibleRelationObjects
            )
            let latest = filteredClaims.compactMap { claim in
                claim.windowEnd
                    ?? claim.windowStart
                    ?? claim.sourceSummaryGeneratedAt
            }.max()

            switch predicate {
            case "advanced_during_window":
                return "\(entity.canonicalName) was explicitly advanced in \(count) summary window\(count == 1 ? "" : "s"), last seen \(formatTimestamp(latest))."
            case "surfaced_in_window":
                return "\(entity.canonicalName) surfaced as an issue in \(count) summary window\(count == 1 ? "" : "s"), last seen \(formatTimestamp(latest))."
            case "used_during_window":
                return "\(entity.canonicalName) was used in \(count) captured work window\(count == 1 ? "" : "s"), last seen \(formatTimestamp(latest))."
            case "topic_in_focus":
                return "\(entity.canonicalName) appeared as a focus topic in \(count) summary window\(count == 1 ? "" : "s"), last seen \(formatTimestamp(latest))."
            case "uses_tool":
                return "\(entity.canonicalName) was worked on with \(count) tool relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "supports_project":
                return "\(entity.canonicalName) supported \(count) project relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "focuses_on_topic":
                return "\(entity.canonicalName) focused on \(count) topic relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "relevant_to_project":
                return "\(entity.canonicalName) was relevant to \(count) project window\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "blocked_by_issue":
                return "\(entity.canonicalName) hit \(count) blocking issue relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "affects_project":
                return "\(entity.canonicalName) affected \(count) project window\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "uses_model":
                return "\(entity.canonicalName) was paired with \(count) model relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "used_in_project":
                return "\(entity.canonicalName) appeared in \(count) project relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "generates_lesson":
                return "\(entity.canonicalName) generated \(count) durable lesson relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "derived_from_project":
                return "\(entity.canonicalName) was derived from \(count) project relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "explains_topic":
                return "\(entity.canonicalName) explained \(count) topic relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "documented_in_lesson":
                return "\(entity.canonicalName) was documented in \(count) lesson relation\(count == 1 ? "" : "s")\(examples), last seen \(formatTimestamp(latest))."
            case "worth_capturing":
                return "\(entity.canonicalName) was suggested as durable knowledge \(count) time\(count == 1 ? "" : "s"), last seen \(formatTimestamp(latest))."
            default:
                return nil
            }
        }
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
        case "uses_tool":
            return object.map { "Worked on with \($0)." } ?? "Worked on with a tool."
        case "supports_project":
            return object.map { "Supported work on \($0)." } ?? "Supported work on a project."
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

    private func predicateExamples(
        from claims: [KnowledgeClaimRecord],
        predicate: String,
        visibleRelationObjects: Set<String>
    ) -> String {
        let examples = Array(Set(claims.compactMap {
            filteredExampleObject(
                from: $0,
                predicate: predicate,
                visibleRelationObjects: visibleRelationObjects
            )
        })).filter { !$0.isEmpty }.sorted()
        guard !examples.isEmpty else { return "" }
        return " (\(examples.prefix(3).joined(separator: ", ")))"
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
        case "uses_tool", "supports_project", "uses_model", "used_in_project", "blocked_by_issue",
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
        case "blocked_by_issue", "affects_project":
            return 5
        case "uses_tool", "supports_project":
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
        case "blocked_by_issue", "uses_tool", "focuses_on_topic", "uses_model", "generates_lesson", "explains_topic":
            return 3
        case "co_occurs_with":
            return 1
        default:
            return 2
        }
    }

    private func groupedRelatedEntities(_ references: [RelatedKnowledgeReference]) -> [(type: KnowledgeEntityType, references: [RelatedKnowledgeReference])] {
        let grouped = Dictionary(grouping: references, by: { $0.entity.entityType })
        return KnowledgeEntityType.allCases.compactMap { type in
            guard let group = grouped[type], !group.isEmpty else { return nil }
            return (type, group.sorted { lhs, rhs in
                let lhsPriority = relationPriority(lhs.edgeType)
                let rhsPriority = relationPriority(rhs.edgeType)
                if lhsPriority != rhsPriority {
                    return lhsPriority > rhsPriority
                }
                if lhs.weight != rhs.weight {
                    return lhs.weight > rhs.weight
                }
                return lhs.entity.canonicalName < rhs.entity.canonicalName
            })
        }
    }

    private func describe(relationship: RelatedKnowledgeReference, for entity: KnowledgeEntityRecord) -> String {
        switch relationship.edgeType {
        case "uses_tool":
            return relationship.direction == .outgoing
                ? "tool used in this project"
                : "project this tool was used in"
        case "focuses_on_topic":
            return relationship.direction == .outgoing
                ? "focus topic for this project"
                : "project where this topic was in focus"
        case "blocked_by_issue":
            return relationship.direction == .outgoing
                ? "blocking issue"
                : "project affected by this issue"
        case "uses_model":
            return relationship.direction == .outgoing
                ? "model used in this project"
                : "project that used this model"
        case "generates_lesson":
            return relationship.direction == .outgoing
                ? "durable lesson generated from this project"
                : "project this lesson came from"
        case "explains_topic":
            return relationship.direction == .outgoing
                ? "topic explained by this lesson"
                : "lesson that documents this topic"
        case "co_occurs_with":
            return "appeared in the same captured windows"
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
