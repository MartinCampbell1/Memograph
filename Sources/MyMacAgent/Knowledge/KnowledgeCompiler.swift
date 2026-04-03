import Foundation

final class KnowledgeCompiler {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport
    private let normalizer: EntityNormalizer

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

        let relatedEntities = try fetchRelatedEntities(for: entityId, edges: edges)
            .filter { allowedEntityIds?.contains($0.id) ?? true }
        let markdown = renderMarkdown(entity: entity, claims: claims, relatedEntities: relatedEntities)
        let links = relatedEntities.map { linkTarget(for: $0) }
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

    private func fetchRelatedEntities(
        for entityId: String,
        edges: [KnowledgeEdgeRecord]
    ) throws -> [KnowledgeEntityRecord] {
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
        return relatedIds.compactMap { map[$0] }.sorted { $0.canonicalName < $1.canonicalName }
    }

    private func renderMarkdown(
        entity: KnowledgeEntityRecord,
        claims: [KnowledgeClaimRecord],
        relatedEntities: [KnowledgeEntityRecord]
    ) -> String {
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

        let signals = keySignals(for: entity, claims: claims)
        if !signals.isEmpty {
            markdown += "## Key Signals\n"
            for signal in signals {
                markdown += "- \(signal)\n"
            }
            markdown += "\n"
        }

        if !claims.isEmpty {
            markdown += "## Recent Windows\n"
            for claim in claims.prefix(8) {
                let when = claim.windowStart.map { dateSupport.localDateTimeString(from: $0) }
                    ?? claim.sourceSummaryGeneratedAt.map { dateSupport.localDateTimeString(from: $0) }
                    ?? "unknown time"
                let description = describe(claim: claim)
                markdown += "- [\(when)] \(description)\n"
            }
            markdown += "\n"
        }

        if !relatedEntities.isEmpty {
            markdown += "## Related\n"
            for group in groupedRelatedEntities(relatedEntities) {
                markdown += "### \(group.type.folderName)\n"
                for related in group.entities {
                    markdown += "- [[\(linkTarget(for: related))|\(related.canonicalName)]]\n"
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

    private func keySignals(for entity: KnowledgeEntityRecord, claims: [KnowledgeClaimRecord]) -> [String] {
        let grouped = Dictionary(grouping: claims, by: \.predicate)
        let orderedPredicates = [
            "advanced_during_window",
            "surfaced_in_window",
            "used_during_window",
            "topic_in_focus",
            "worth_capturing"
        ]

        return orderedPredicates.compactMap { predicate in
            guard let predicateClaims = grouped[predicate], !predicateClaims.isEmpty else {
                return nil
            }

            let count = predicateClaims.count
            let latest = predicateClaims.compactMap { claim in
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

    private func groupedRelatedEntities(_ entities: [KnowledgeEntityRecord]) -> [(type: KnowledgeEntityType, entities: [KnowledgeEntityRecord])] {
        let grouped = Dictionary(grouping: entities, by: \.entityType)
        return KnowledgeEntityType.allCases.compactMap { type in
            guard let group = grouped[type], !group.isEmpty else { return nil }
            return (type, group.sorted { $0.canonicalName < $1.canonicalName })
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
