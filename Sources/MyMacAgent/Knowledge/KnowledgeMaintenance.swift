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
    let score: Int
}

final class KnowledgeMaintenance {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport

    init(db: DatabaseManager, timeZone: TimeZone = .autoupdatingCurrent) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func buildMarkdown(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>,
        graphShaper: GraphShaper
    ) throws -> String {
        let metricIndex = Dictionary(uniqueKeysWithValues: metrics.map { ($0.entity.id, $0) })
        let entities = metrics
            .filter { materializedEntityIds.contains($0.entity.id) }
            .map(\.entity)
        let edgeRows = try loadEdges(materializedEntityIds: materializedEntityIds)
        let hotspots = buildHotspots(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds,
            graphShaper: graphShaper
        )

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

        let autoDemotedLessons = metrics
            .filter { !materializedEntityIds.contains($0.entity.id) }
            .filter { graphShaper.maintenanceFlags(for: $0, in: metricIndex).contains(.autoDemoteBroadLesson) }
            .sorted { lhs, rhs in
                if lhs.projectRelationCount != rhs.projectRelationCount {
                    return lhs.projectRelationCount > rhs.projectRelationCount
                }
                return lhs.entity.canonicalName.localizedCaseInsensitiveCompare(rhs.entity.canonicalName) == .orderedAscending
            }

        let weakTopics = hotspots
            .filter { $0.entity.entityType == .topic && $0.relationStats.typedEdges <= 1 && $0.relationStats.coOccurrenceEdges >= 4 }
            .sorted { lhs, rhs in
                if lhs.relationStats.coOccurrenceEdges != rhs.relationStats.coOccurrenceEdges {
                    return lhs.relationStats.coOccurrenceEdges > rhs.relationStats.coOccurrenceEdges
                }
                return lhs.entity.canonicalName < rhs.entity.canonicalName
            }

        let autoDemotedTopics = metrics
            .filter { !materializedEntityIds.contains($0.entity.id) }
            .filter { graphShaper.maintenanceFlags(for: $0, in: metricIndex).contains(.autoDemoteWeakTopic) }
            .sorted { lhs, rhs in
                if lhs.coOccurrenceEdgeCount != rhs.coOccurrenceEdgeCount {
                    return lhs.coOccurrenceEdgeCount > rhs.coOccurrenceEdgeCount
                }
                return lhs.entity.canonicalName.localizedCaseInsensitiveCompare(rhs.entity.canonicalName) == .orderedAscending
            }

        let commodityWeakTopics = autoDemotedTopics.filter {
            graphShaper.shouldSuppressWeakTopicInMaintenance($0.entity.canonicalName)
        }
        let actionableAutoDemotedTopics = autoDemotedTopics.filter {
            !graphShaper.shouldSuppressWeakTopicInMaintenance($0.entity.canonicalName)
        }

        markdown += "## Review Queue\n"
        if autoDemotedLessons.isEmpty && weakTopics.isEmpty && actionableAutoDemotedTopics.isEmpty && commodityWeakTopics.isEmpty {
            markdown += "- No immediate KB maintenance flags.\n\n"
        } else {
            if !autoDemotedLessons.isEmpty {
                markdown += "### Auto-demoted Broad Lessons\n"
                for metric in autoDemotedLessons.prefix(8) {
                    markdown += "- `\(metric.entity.canonicalName)`"
                    markdown += " — linked to \(metric.projectRelationCount) projects"
                    markdown += ", \(metric.claimCount) claims\n"
                }
                markdown += "\n"
            }

            if !actionableAutoDemotedTopics.isEmpty {
                markdown += "### Auto-demoted Weak Topics\n"
                for metric in actionableAutoDemotedTopics.prefix(8) {
                    markdown += "- `\(metric.entity.canonicalName)`"
                    markdown += " — \(metric.coOccurrenceEdgeCount) co-occurrence edges"
                    markdown += ", only \(metric.typedEdgeCount) typed relation"
                    if metric.typedEdgeCount == 1 { markdown += "" } else { markdown += "s" }
                    markdown += "\n"
                }
                markdown += "\n"
            }

            if !commodityWeakTopics.isEmpty {
                let examples = commodityWeakTopics.prefix(4).map(\.entity.canonicalName).joined(separator: ", ")
                markdown += "- Suppressed commodity weak topics: \(commodityWeakTopics.count)"
                if !examples.isEmpty {
                    markdown += " (\(examples))"
                }
                markdown += "\n\n"
            }

            if !weakTopics.isEmpty {
                markdown += "### Weak Durable Topics\n"
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
        markdown += "- Auto-demoted broad lessons: generic lessons linked to 3+ projects with weak direct evidence are removed from the materialized graph.\n"
        markdown += "- Auto-demoted weak topics: non-durable topics with heavy co-occurrence and weak typed relations are removed from the materialized graph.\n"
        markdown += "- Weak durable topics: durable topics stay visible, but low typed-relation coverage means relation extraction still needs improvement.\n"
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

    private func buildHotspots(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>,
        graphShaper: GraphShaper
    ) -> [KnowledgeHotspot] {
        metrics
            .filter { materializedEntityIds.contains($0.entity.id) }
            .filter { !graphShaper.shouldHideFromHotspots($0) }
            .map { metric in
            KnowledgeHotspot(
                entity: metric.entity,
                claimCount: metric.claimCount,
                relationStats: KnowledgeRelationStats(
                    totalEdges: metric.typedEdgeCount + metric.coOccurrenceEdgeCount,
                    typedEdges: metric.typedEdgeCount,
                    coOccurrenceEdges: metric.coOccurrenceEdgeCount,
                    projectRelations: metric.projectRelationCount
                ),
                score: graphShaper.hotspotScore(for: metric)
            )
        }
    }

    private func compareHotspots(_ lhs: KnowledgeHotspot, _ rhs: KnowledgeHotspot) -> Bool {
        let lhsScore = lhs.score
        let rhsScore = rhs.score
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }
        if lhs.relationStats.projectRelations != rhs.relationStats.projectRelations {
            return lhs.relationStats.projectRelations > rhs.relationStats.projectRelations
        }
        if lhs.relationStats.typedEdges != rhs.relationStats.typedEdges {
            return lhs.relationStats.typedEdges > rhs.relationStats.typedEdges
        }
        return lhs.entity.canonicalName < rhs.entity.canonicalName
    }

    private func linkTarget(for entity: KnowledgeEntityRecord) -> String {
        "Knowledge/\(entity.entityType.folderName)/\(entity.slug)"
    }
}
