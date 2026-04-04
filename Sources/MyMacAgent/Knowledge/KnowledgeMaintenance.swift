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

private struct KnowledgeReclassifyCandidate {
    let entity: KnowledgeEntityRecord
    let targetType: KnowledgeEntityType
    let reason: String
    let score: Int
}

private struct KnowledgeConsolidationCandidate {
    let source: KnowledgeEntityRecord
    let target: KnowledgeEntityRecord
    let reason: String
    let score: Int
}

private struct KnowledgeStaleCandidate {
    let entity: KnowledgeEntityRecord
    let daysSinceSeen: Int
    let reason: String
}

final class KnowledgeMaintenance {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport
    private let lessonLikeTopicSignals = [
        "accuracy",
        "algorithm",
        "architecture",
        "automation",
        "background persistence",
        "engineering",
        "growth",
        "guide",
        "heartbeat",
        "optimization",
        "playbook",
        "plugins",
        "report",
        "resource consumption",
        "selection",
        "setup",
        "state management",
        "strategy",
        "tool",
        "workflow"
    ]
    private let consolidationSuffixSignals = [
        "accuracy",
        "algorithm",
        "architecture",
        "automation",
        "background persistence",
        "growth",
        "heartbeat",
        "optimization",
        "plugins",
        "resource consumption",
        "selection",
        "state management"
    ]
    private let tokenStopWords: Set<String> = [
        "a", "an", "and", "for", "in", "of", "on", "the", "to", "vs", "with"
    ]

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
        let sortedHotspots = hotspots.sorted(by: compareHotspots)
        let topHotspotNames = sortedHotspots.prefix(3).map(\.entity.canonicalName)
        let reviewItemCount = autoDemotedLessons.count + actionableAutoDemotedTopics.count + weakTopics.count
        let reclassifyCandidates = buildReclassifyCandidates(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds
        )
        let consolidationCandidates = buildConsolidationCandidates(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds
        )
        let staleCandidates = buildStaleCandidates(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds
        )

        markdown += "## Dashboard\n"
        if !topHotspotNames.isEmpty {
            markdown += "- Strongest clusters right now: \(joinNaturalLanguage(topHotspotNames))\n"
        }
        markdown += "- Review items waiting: \(reviewItemCount)\n"
        markdown += "- Commodity weak topics already suppressed: \(commodityWeakTopics.count)\n\n"

        markdown += "## Review Queue\n"
        if autoDemotedLessons.isEmpty && weakTopics.isEmpty && actionableAutoDemotedTopics.isEmpty && commodityWeakTopics.isEmpty {
            markdown += "- No immediate KB maintenance flags.\n\n"
        } else {
            if !autoDemotedLessons.isEmpty {
                markdown += "### Auto-demoted Broad Lessons\n"
                for metric in autoDemotedLessons.prefix(8) {
                    markdown += "- `\(metric.entity.canonicalName)`"
                    markdown += " — broad lesson: linked to \(metric.projectRelationCount) project"
                    if metric.projectRelationCount == 1 { markdown += "" } else { markdown += "s" }
                    markdown += " across \(metric.claimCount) claim"
                    if metric.claimCount == 1 { markdown += "" } else { markdown += "s" }
                    markdown += "\n"
                }
                markdown += "\n"
            }

            if !actionableAutoDemotedTopics.isEmpty {
                markdown += "### Auto-demoted Weak Topics\n"
                for metric in actionableAutoDemotedTopics.prefix(8) {
                    markdown += "- `\(metric.entity.canonicalName)`"
                    markdown += " — weak topic: \(metric.coOccurrenceEdgeCount) loose links"
                    markdown += ", only \(metric.typedEdgeCount) strong relation"
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
                    markdown += " — durable but thinly supported: \(hotspot.relationStats.coOccurrenceEdges) loose links"
                    markdown += ", only \(hotspot.relationStats.typedEdges) strong relation"
                    if hotspot.relationStats.typedEdges == 1 { markdown += "" } else { markdown += "s" }
                    markdown += "\n"
                }
                markdown += "\n"
            }
        }

        markdown += "## Improvement Candidates\n"
        if reclassifyCandidates.isEmpty && consolidationCandidates.isEmpty && staleCandidates.isEmpty {
            markdown += "- No merge, reclassify, or stale review candidates right now.\n\n"
        } else {
            if !reclassifyCandidates.isEmpty {
                markdown += "### Reclassify Candidates\n"
                for candidate in reclassifyCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"
                    markdown += " — consider moving to \(candidate.targetType.folderName): \(candidate.reason)\n"
                }
                markdown += "\n"
            }

            if !consolidationCandidates.isEmpty {
                markdown += "### Consolidation Candidates\n"
                for candidate in consolidationCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.source))|\(candidate.source.canonicalName)]]"
                    markdown += " → [[\(linkTarget(for: candidate.target))|\(candidate.target.canonicalName)]]"
                    markdown += " — \(candidate.reason)\n"
                }
                markdown += "\n"
            }

            if !staleCandidates.isEmpty {
                markdown += "### Stale Review Candidates\n"
                for candidate in staleCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"
                    markdown += " — last seen \(candidate.daysSinceSeen) day"
                    if candidate.daysSinceSeen == 1 { markdown += "" } else { markdown += "s" }
                    markdown += " ago; \(candidate.reason)\n"
                }
                markdown += "\n"
            }
        }

        markdown += "## Hotspots\n"
        for hotspot in sortedHotspots.prefix(10) {
            markdown += "- [[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]]"
            markdown += " — strongest cluster right now: \(hotspot.claimCount) claims, \(hotspot.relationStats.typedEdges) strong links, \(hotspot.relationStats.coOccurrenceEdges) loose links\n"
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

    private func buildReclassifyCandidates(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>
    ) -> [KnowledgeReclassifyCandidate] {
        metrics
            .filter { materializedEntityIds.contains($0.entity.id) }
            .compactMap { metric in
                guard metric.entity.entityType == .topic else { return nil }
                guard let reason = reclassifyReason(for: metric.entity.canonicalName) else { return nil }
                return KnowledgeReclassifyCandidate(
                    entity: metric.entity,
                    targetType: .lesson,
                    reason: reason,
                    score: metric.claimCount * 4 + metric.typedEdgeCount * 3 + metric.projectRelationCount * 5
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.entity.canonicalName.localizedCaseInsensitiveCompare(rhs.entity.canonicalName) == .orderedAscending
            }
    }

    private func buildConsolidationCandidates(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>
    ) -> [KnowledgeConsolidationCandidate] {
        let visibleMetrics = metrics.filter { materializedEntityIds.contains($0.entity.id) }
        let topics = visibleMetrics.filter { $0.entity.entityType == .topic }
        var candidates: [KnowledgeConsolidationCandidate] = []
        var seenPairs = Set<String>()

        for source in topics {
            for target in topics {
                guard source.entity.id != target.entity.id else { continue }
                guard let reason = consolidationReason(source: source, target: target) else { continue }
                let pairKey = "\(source.entity.id)->\(target.entity.id)"
                guard seenPairs.insert(pairKey).inserted else { continue }
                candidates.append(
                    KnowledgeConsolidationCandidate(
                        source: source.entity,
                        target: target.entity,
                        reason: reason,
                        score: source.claimCount * 3 + source.typedEdgeCount * 2 + target.claimCount * 2
                    )
                )
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.target.canonicalName != rhs.target.canonicalName {
                return lhs.target.canonicalName.localizedCaseInsensitiveCompare(rhs.target.canonicalName) == .orderedAscending
            }
            return lhs.source.canonicalName.localizedCaseInsensitiveCompare(rhs.source.canonicalName) == .orderedAscending
        }
    }

    private func buildStaleCandidates(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>,
        now: Date = Date()
    ) -> [KnowledgeStaleCandidate] {
        metrics
            .filter { materializedEntityIds.contains($0.entity.id) }
            .compactMap { metric in
                guard metric.entity.entityType != .project else { return nil }
                guard metric.claimCount <= 4 else { return nil }
                guard metric.projectRelationCount == 0 else { return nil }
                guard let lastSeenAt = metric.entity.lastSeenAt,
                      let lastSeenDate = dateSupport.parseDateTime(lastSeenAt) else {
                    return nil
                }
                let days = Int(now.timeIntervalSince(lastSeenDate) / 86_400)
                guard days >= 7 else { return nil }
                return KnowledgeStaleCandidate(
                    entity: metric.entity,
                    daysSinceSeen: days,
                    reason: "low-touch note with no active project trail"
                )
            }
            .sorted { lhs, rhs in
                if lhs.daysSinceSeen != rhs.daysSinceSeen {
                    return lhs.daysSinceSeen > rhs.daysSinceSeen
                }
                return lhs.entity.canonicalName.localizedCaseInsensitiveCompare(rhs.entity.canonicalName) == .orderedAscending
            }
    }

    private func reclassifyReason(for name: String) -> String? {
        let lowered = name.lowercased()
        guard lessonLikeTopicSignals.contains(where: { lowered.contains($0) }) else {
            return nil
        }
        return "topic reads more like a durable guide or workflow note"
    }

    private func consolidationReason(
        source: KnowledgeEntityMetrics,
        target: KnowledgeEntityMetrics
    ) -> String? {
        let sourceName = source.entity.canonicalName
        let targetName = target.entity.canonicalName
        let sourceLower = sourceName.lowercased()
        let targetLower = targetName.lowercased()
        guard sourceLower != targetLower else { return nil }
        guard sourceName.count > targetName.count else { return nil }
        guard sourceLower.hasPrefix(targetLower + " ") || sourceLower.contains(targetLower + " ") else {
            return nil
        }
        guard consolidationSuffixSignals.contains(where: { sourceLower.contains($0) }) else {
            return nil
        }

        let sourceTokens = significantTokens(in: sourceName)
        let targetTokens = significantTokens(in: targetName)
        guard !sourceTokens.isEmpty, !targetTokens.isEmpty else { return nil }
        guard Set(targetTokens).isSubset(of: Set(sourceTokens)) else { return nil }
        guard targetTokens.count <= 3 else { return nil }
        guard target.claimCount >= source.claimCount else { return nil }

        return "overlapping topic family; consider consolidating under the stronger root note"
    }

    private func significantTokens(in value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !tokenStopWords.contains($0) }
    }
}
