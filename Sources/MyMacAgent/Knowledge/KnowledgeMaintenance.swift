import Foundation

private struct KnowledgeRelationStats {
    var totalEdges: Int = 0
    var typedEdges: Int = 0
    var coOccurrenceEdges: Int = 0
    var projectRelations: Int = 0
}

private struct KnowledgeHotspot {
    let entity: KnowledgeEntityRecord
    let claimCount: Int
    let relationStats: KnowledgeRelationStats
}

final class KnowledgeMaintenance {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport

    init(db: DatabaseManager, timeZone: TimeZone = .autoupdatingCurrent) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func buildMarkdown(materializedEntityIds: Set<String>) throws -> String {
        let entities = try loadEntities(materializedEntityIds: materializedEntityIds)
        let edgeRows = try loadEdges(materializedEntityIds: materializedEntityIds)
        let claimCounts = try loadClaimCounts(materializedEntityIds: materializedEntityIds)
        let hotspots = buildHotspots(entities: entities, edgeRows: edgeRows, claimCounts: claimCounts)

        var markdown = "# Memograph Knowledge Maintenance\n\n"
        markdown += "_Refreshed: \(dateSupport.localDateTimeString(from: Date()))_\n\n"

        markdown += "## Snapshot\n"
        markdown += "- Materialized entities: \(entities.count)\n"
        markdown += "- Materialized notes: \(entities.count)\n"
        markdown += "- Relationship edges scanned: \(edgeRows.count)\n"
        markdown += "- Time zone: \(dateSupport.timeZone.identifier)\n\n"

        let typeCounts = Dictionary(grouping: entities, by: \.entityType)
        markdown += "## Type Counts\n"
        for type in KnowledgeEntityType.allCases {
            let count = typeCounts[type, default: []].count
            guard count > 0 else { continue }
            markdown += "- \(type.folderName): \(count)\n"
        }
        markdown += "\n"

        let broadLessons = hotspots
            .filter { $0.entity.entityType == .lesson && $0.relationStats.projectRelations >= 3 }
            .sorted { lhs, rhs in
                if lhs.relationStats.projectRelations != rhs.relationStats.projectRelations {
                    return lhs.relationStats.projectRelations > rhs.relationStats.projectRelations
                }
                return lhs.entity.canonicalName < rhs.entity.canonicalName
            }

        let weakTopics = hotspots
            .filter { $0.entity.entityType == .topic && $0.relationStats.typedEdges <= 1 && $0.relationStats.coOccurrenceEdges >= 4 }
            .sorted { lhs, rhs in
                if lhs.relationStats.coOccurrenceEdges != rhs.relationStats.coOccurrenceEdges {
                    return lhs.relationStats.coOccurrenceEdges > rhs.relationStats.coOccurrenceEdges
                }
                return lhs.entity.canonicalName < rhs.entity.canonicalName
            }

        markdown += "## Review Queue\n"
        if broadLessons.isEmpty && weakTopics.isEmpty {
            markdown += "- No immediate KB maintenance flags.\n\n"
        } else {
            if !broadLessons.isEmpty {
                markdown += "### Broad Lessons\n"
                for hotspot in broadLessons.prefix(8) {
                    markdown += "- [[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]]"
                    markdown += " — linked to \(hotspot.relationStats.projectRelations) projects"
                    markdown += ", \(hotspot.claimCount) claims\n"
                }
                markdown += "\n"
            }

            if !weakTopics.isEmpty {
                markdown += "### Weak Topics\n"
                for hotspot in weakTopics.prefix(8) {
                    markdown += "- [[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]]"
                    markdown += " — \(hotspot.relationStats.coOccurrenceEdges) co-occurrence edges"
                    markdown += ", only \(hotspot.relationStats.typedEdges) typed relation"
                    if hotspot.relationStats.typedEdges == 1 { markdown += "" } else { markdown += "s" }
                    markdown += "\n"
                }
                markdown += "\n"
            }
        }

        markdown += "## Hotspots\n"
        for hotspot in hotspots.sorted(by: compareHotspots).prefix(10) {
            markdown += "- [[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]]"
            markdown += " — \(hotspot.claimCount) claims, \(hotspot.relationStats.typedEdges) typed edges, \(hotspot.relationStats.coOccurrenceEdges) co-occurrence edges\n"
        }
        markdown += "\n"

        markdown += "## Maintenance Rules\n"
        markdown += "- Broad lessons: lessons connected to 3+ projects should be reviewed for over-generalization.\n"
        markdown += "- Weak topics: topics with many co-occurrence edges but almost no typed relations are candidates for pruning or reclassification.\n"
        markdown += "- Hotspots: entities with the highest combined claim and relation pressure.\n"

        return markdown
    }

    private func loadEntities(materializedEntityIds: Set<String>) throws -> [KnowledgeEntityRecord] {
        guard !materializedEntityIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: materializedEntityIds.count).joined(separator: ",")
        let rows = try db.query(
            "SELECT * FROM knowledge_entities WHERE id IN (\(placeholders))",
            params: materializedEntityIds.sorted().map(SQLiteValue.text)
        )
        return rows.compactMap(KnowledgeEntityRecord.init(row:))
    }

    private func loadEdges(materializedEntityIds: Set<String>) throws -> [KnowledgeEdgeRecord] {
        guard !materializedEntityIds.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: materializedEntityIds.count).joined(separator: ",")
        let params = materializedEntityIds.sorted().map(SQLiteValue.text)
        let rows = try db.query("""
            SELECT *
            FROM knowledge_edges
            WHERE from_entity_id IN (\(placeholders))
               OR to_entity_id IN (\(placeholders))
        """, params: params + params)
        return rows.compactMap(KnowledgeEdgeRecord.init(row:))
    }

    private func loadClaimCounts(materializedEntityIds: Set<String>) throws -> [String: Int] {
        guard !materializedEntityIds.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: materializedEntityIds.count).joined(separator: ",")
        let rows = try db.query("""
            SELECT subject_entity_id, COUNT(*) AS claim_count
            FROM knowledge_claims
            WHERE subject_entity_id IN (\(placeholders))
            GROUP BY subject_entity_id
        """, params: materializedEntityIds.sorted().map(SQLiteValue.text))

        var counts: [String: Int] = [:]
        for row in rows {
            if let id = row["subject_entity_id"]?.textValue {
                counts[id] = Int(row["claim_count"]?.intValue ?? 0)
            }
        }
        return counts
    }

    private func buildHotspots(
        entities: [KnowledgeEntityRecord],
        edgeRows: [KnowledgeEdgeRecord],
        claimCounts: [String: Int]
    ) -> [KnowledgeHotspot] {
        let entityMap = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
        var statsByEntityId: [String: KnowledgeRelationStats] = [:]

        for edge in edgeRows {
            guard let fromEntity = entityMap[edge.fromEntityId],
                  let toEntity = entityMap[edge.toEntityId] else {
                continue
            }
            accumulate(edge: edge, on: fromEntity, related: toEntity, into: &statsByEntityId)
            accumulate(edge: edge, on: toEntity, related: fromEntity, into: &statsByEntityId)
        }

        return entities.map { entity in
            KnowledgeHotspot(
                entity: entity,
                claimCount: claimCounts[entity.id] ?? 0,
                relationStats: statsByEntityId[entity.id] ?? KnowledgeRelationStats()
            )
        }
    }

    private func accumulate(
        edge: KnowledgeEdgeRecord,
        on entity: KnowledgeEntityRecord,
        related: KnowledgeEntityRecord,
        into statsByEntityId: inout [String: KnowledgeRelationStats]
    ) {
        var stats = statsByEntityId[entity.id] ?? KnowledgeRelationStats()
        stats.totalEdges += 1
        if edge.edgeType == "co_occurs_with" {
            stats.coOccurrenceEdges += 1
        } else {
            stats.typedEdges += 1
        }
        if related.entityType == .project {
            stats.projectRelations += 1
        }
        statsByEntityId[entity.id] = stats
    }

    private func compareHotspots(_ lhs: KnowledgeHotspot, _ rhs: KnowledgeHotspot) -> Bool {
        let lhsScore = lhs.claimCount + lhs.relationStats.typedEdges + lhs.relationStats.coOccurrenceEdges
        let rhsScore = rhs.claimCount + rhs.relationStats.typedEdges + rhs.relationStats.coOccurrenceEdges
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        return lhs.entity.canonicalName < rhs.entity.canonicalName
    }

    private func linkTarget(for entity: KnowledgeEntityRecord) -> String {
        "Knowledge/\(entity.entityType.folderName)/\(entity.slug)"
    }
}
