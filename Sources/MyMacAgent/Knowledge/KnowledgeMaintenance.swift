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

private struct KnowledgeManualReviewItem {
    enum Kind {
        case reclassify
        case consolidate
        case weakTopic
        case stale
    }

    enum Priority {
        case high
        case medium
        case low

        var sortOrder: Int {
            switch self {
            case .high: return 0
            case .medium: return 1
            case .low: return 2
            }
        }

        var badge: String {
            switch self {
            case .high: return "High"
            case .medium: return "Medium"
            case .low: return "Low"
            }
        }

        var sectionTitle: String {
            switch self {
            case .high: return "High Priority"
            case .medium: return "Standard Review"
            case .low: return "Low-Signal Review"
            }
        }
    }

    let kind: Kind
    let title: String
    let markdownLine: String
    let score: Int
    let priority: Priority
    let artifactKey: String
}

private struct KnowledgeSafeAction {
    enum ActionKind {
        case promoteToLessonDraft
        case consolidateIntoRoot
    }

    let kind: ActionKind
    let source: KnowledgeEntityRecord
    let target: KnowledgeEntityRecord?
    let reason: String
    let score: Int
}

enum KnowledgeDraftArtifactKind {
    case workflowIndex
    case reviewDraft
    case reviewIndex
    case applyReadyLesson
    case applyReadyLessonRedirect
    case applyReadyRedirect
    case applyReadyMergePatch
    case applyIndex

    var sortOrder: Int {
        switch self {
        case .workflowIndex:
            return 0
        case .reviewDraft:
            return 1
        case .reviewIndex:
            return 2
        case .applyReadyLesson, .applyReadyLessonRedirect, .applyReadyRedirect, .applyReadyMergePatch:
            return 3
        case .applyIndex:
            return 4
        }
    }

    var lineLabel: String {
        switch self {
        case .workflowIndex:
            return "Board"
        case .reviewDraft:
            return "Review"
        case .reviewIndex:
            return "Board"
        case .applyReadyLesson:
            return "Apply"
        case .applyReadyLessonRedirect, .applyReadyRedirect:
            return "Redirect"
        case .applyReadyMergePatch:
            return "Merge"
        case .applyIndex:
            return "Board"
        }
    }

    var linkLabel: String {
        switch self {
        case .workflowIndex:
            return "workflow center"
        case .reviewDraft:
            return "review draft"
        case .reviewIndex:
            return "review board"
        case .applyReadyLesson:
            return "apply-ready lesson"
        case .applyReadyLessonRedirect, .applyReadyRedirect:
            return "redirect stub"
        case .applyReadyMergePatch:
            return "merge patch"
        case .applyIndex:
            return "apply board"
        }
    }
}

struct KnowledgeDraftArtifact {
    struct MergeOverlayDraft {
        let sourceEntityId: String
        let sourceTitle: String
        let sourceAliases: [String]
        let sourceOverview: String?
        let preservedSignals: [String]
        let targetEntityId: String
        let targetTitle: String
        let targetRelativePath: String
    }

    let kind: KnowledgeDraftArtifactKind
    let relativePath: String
    let fileName: String
    let title: String
    let markdown: String
    let applyTargetRelativePath: String?
    let suppressedEntityId: String?
    let mergeOverlayDraft: MergeOverlayDraft?
    let reviewPacketKey: String?
    let reviewDecisionKind: KnowledgeReviewDecisionKind?

    init(
        kind: KnowledgeDraftArtifactKind,
        relativePath: String,
        title: String,
        markdown: String,
        applyTargetRelativePath: String? = nil,
        suppressedEntityId: String? = nil,
        mergeOverlayDraft: MergeOverlayDraft? = nil,
        reviewPacketKey: String? = nil,
        reviewDecisionKind: KnowledgeReviewDecisionKind? = nil
    ) {
        let normalizedPath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.kind = kind
        self.relativePath = normalizedPath
        self.fileName = (normalizedPath as NSString).lastPathComponent
        self.title = title
        self.markdown = markdown
        self.applyTargetRelativePath = applyTargetRelativePath?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.suppressedEntityId = suppressedEntityId
        self.mergeOverlayDraft = mergeOverlayDraft
        self.reviewPacketKey = reviewPacketKey
        self.reviewDecisionKind = reviewDecisionKind
    }

    init(fileName: String, title: String, markdown: String) {
        self.init(
            kind: .reviewDraft,
            relativePath: "Maintenance/\(fileName)",
            title: title,
            markdown: markdown
        )
    }

    var linkTarget: String {
        "Knowledge/_drafts/\(relativePath.replacingOccurrences(of: ".md", with: ""))"
    }
}

struct KnowledgeMaintenanceArtifacts {
    let markdown: String
    let draftArtifacts: [KnowledgeDraftArtifact]
}

private struct KnowledgeAppliedDecisionIndex {
    let promotedEntityIds: Set<String>
    let promotedNameKeys: Set<String>
    let mergedEntityIds: Set<String>
    let mergedSourceKeys: Set<String>
    let mergedTargetKeysBySourceKey: [String: Set<String>]

    static let empty = KnowledgeAppliedDecisionIndex(
        promotedEntityIds: [],
        promotedNameKeys: [],
        mergedEntityIds: [],
        mergedSourceKeys: [],
        mergedTargetKeysBySourceKey: [:]
    )
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

    func buildArtifacts(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>,
        graphShaper: GraphShaper,
        appliedActions: [KnowledgeAppliedActionRecord] = [],
        aliasOverrides: [KnowledgeAliasOverrideRecord] = [],
        reviewDecisions: [KnowledgeReviewDecisionRecord] = []
    ) throws -> KnowledgeMaintenanceArtifacts {
        let appliedDecisionIndex = buildAppliedDecisionIndex(
            appliedActions: appliedActions,
            aliasOverrides: aliasOverrides
        )
        let dismissedReviewKeys = Set(
            reviewDecisions
                .filter { $0.status == .dismiss }
                .map(\.key)
        )
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
        let reclassifyCandidates = buildReclassifyCandidates(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds,
            appliedDecisionIndex: appliedDecisionIndex
        )
        let consolidationCandidates = buildConsolidationCandidates(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds,
            appliedDecisionIndex: appliedDecisionIndex
        )
        let staleCandidates = buildStaleCandidates(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds,
            appliedDecisionIndex: appliedDecisionIndex
        )
        let safeActions = buildSafeActions(
            metrics: metrics,
            reclassifyCandidates: reclassifyCandidates,
            consolidationCandidates: consolidationCandidates
        ).filter { !dismissedReviewKeys.contains(manualReviewKey(for: $0)) }
        let safeActionSourceEntityIds = Set(safeActions.map(\.source.id))
        let filteredReclassifyCandidates = reclassifyCandidates.filter {
            !safeActionSourceEntityIds.contains($0.entity.id)
                && !dismissedReviewKeys.contains(manualReviewKey(for: $0))
        }
        let filteredConsolidationCandidates = consolidationCandidates.filter {
            !safeActionSourceEntityIds.contains($0.source.id)
                && !dismissedReviewKeys.contains(manualReviewKey(for: $0))
        }
        let filteredWeakTopics = weakTopics.filter {
            !dismissedReviewKeys.contains(manualReviewKey(forWeakTopic: $0.entity))
        }
        let filteredActionableAutoDemotedTopics = actionableAutoDemotedTopics.filter {
            !dismissedReviewKeys.contains(manualReviewKey(forWeakTopic: $0.entity))
        }
        let filteredStaleCandidates = staleCandidates.filter {
            !dismissedReviewKeys.contains(manualReviewKey(for: $0))
        }
        let manualReviewItems = buildManualReviewItems(
            actionableAutoDemotedTopics: filteredActionableAutoDemotedTopics,
            weakTopics: filteredWeakTopics,
            reclassifyCandidates: filteredReclassifyCandidates,
            consolidationCandidates: filteredConsolidationCandidates,
            staleCandidates: filteredStaleCandidates
        )
        let reviewItemCount = manualReviewItems.count
        let highPriorityReviewCount = manualReviewItems.filter { $0.priority == .high }.count
        let standardPriorityReviewCount = manualReviewItems.filter { $0.priority == .medium }.count
        let lowSignalReviewCount = manualReviewItems.filter { $0.priority == .low }.count
        let draftArtifactEntries = try buildDraftArtifacts(from: safeActions)
        let manualReviewArtifactEntries = try buildManualReviewDraftArtifacts(
            actionableAutoDemotedTopics: filteredActionableAutoDemotedTopics,
            weakTopics: filteredWeakTopics,
            reclassifyCandidates: filteredReclassifyCandidates,
            consolidationCandidates: filteredConsolidationCandidates,
            staleCandidates: filteredStaleCandidates
        )
        let draftArtifactsByKey = Dictionary(grouping: draftArtifactEntries, by: \.key)
            .mapValues { entries in
                entries.map(\.value).sorted { lhs, rhs in
                    lhs.kind.sortOrder < rhs.kind.sortOrder
                }
            }
        let manualReviewArtifactsByKey = Dictionary(grouping: manualReviewArtifactEntries, by: \.key)
            .mapValues { entries in
                entries.map(\.value).sorted { lhs, rhs in
                    lhs.kind.sortOrder < rhs.kind.sortOrder
                }
            }
        let applyIndexArtifact = buildApplyIndexArtifact(
            from: safeActions,
            draftArtifactsByKey: draftArtifactsByKey
        )
        let reviewIndexArtifact = buildReviewIndexArtifact(
            from: manualReviewItems,
            draftArtifactsByKey: manualReviewArtifactsByKey
        )
        let workflowIndexArtifact = buildWorkflowIndexArtifact(
            safeActions: safeActions,
            manualReviewItems: manualReviewItems,
            applyIndexArtifact: applyIndexArtifact,
            reviewIndexArtifact: reviewIndexArtifact,
            appliedActions: appliedActions,
            reviewDecisions: reviewDecisions
        )
        var draftArtifacts = draftArtifactEntries.map(\.value) + manualReviewArtifactEntries.map(\.value)
        draftArtifacts.append(workflowIndexArtifact)
        if let applyIndexArtifact {
            draftArtifacts.append(applyIndexArtifact)
        }
        if let reviewIndexArtifact {
            draftArtifacts.append(reviewIndexArtifact)
        }

        markdown += "## Dashboard\n"
        if !topHotspotNames.isEmpty {
            markdown += "- Strongest clusters right now: \(joinNaturalLanguage(topHotspotNames))\n"
        }
        markdown += "- [[\(workflowIndexArtifact.linkTarget)|workflow center]]\n"
        markdown += "- Safe actions ready: \(safeActions.count)\n"
        markdown += "- Manual review candidates: \(manualReviewItems.count)\n"
        markdown += "- Review items waiting: \(reviewItemCount)\n"
        markdown += "- High-priority review items: \(highPriorityReviewCount)\n"
        markdown += "- Standard review items: \(standardPriorityReviewCount)\n"
        markdown += "- Low-signal review items: \(lowSignalReviewCount)\n"
        markdown += "- Commodity weak topics already suppressed: \(commodityWeakTopics.count)\n\n"
        if !appliedActions.isEmpty {
            markdown += "- Recently applied actions tracked: \(appliedActions.count)\n\n"
        }
        if !reviewDecisions.isEmpty {
            markdown += "- Review decisions tracked: \(reviewDecisions.count)\n\n"
        }

        markdown += "## Next Actions\n"
        if safeActions.isEmpty && manualReviewItems.isEmpty {
            markdown += "- No immediate action queue right now.\n\n"
        } else {
            if !safeActions.isEmpty {
                markdown += "### Safe to Apply\n"
                for action in safeActions.prefix(3) {
                    switch action.kind {
                    case .promoteToLessonDraft:
                        markdown += "- Promote [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]] into `Lessons`.\n"
                    case .consolidateIntoRoot:
                        guard let target = action.target else { continue }
                        markdown += "- Consolidate [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]] into [[\(linkTarget(for: target))|\(target.canonicalName)]].\n"
                    }
                }
                markdown += "\n"
            }

            if !manualReviewItems.isEmpty {
                let actionableReviewItems = manualReviewItems.filter { $0.priority != .low }
                markdown += "### Needs Review\n"
                if let reviewIndexArtifact {
                    markdown += "- [[\(reviewIndexArtifact.linkTarget)|\(reviewIndexArtifact.kind.linkLabel)]]\n"
                }
                for item in actionableReviewItems.prefix(5) {
                    let reviewLink = manualReviewArtifactsByKey[item.artifactKey]?
                        .first(where: { $0.kind == .reviewDraft })
                        .map { " • [[\($0.linkTarget)|review]]" }
                        ?? ""
                    markdown += "- [\(item.priority.badge)] \(item.markdownLine)\(reviewLink)\n"
                }
                if lowSignalReviewCount > 0 {
                    markdown += "- Deferred low-signal review: \(lowSignalReviewCount) item"
                    if lowSignalReviewCount == 1 { markdown += "" } else { markdown += "s" }
                    markdown += " remain in the review board.\n"
                }
                markdown += "\n"
            }
        }

        markdown += "## Review Queue\n"
        if autoDemotedLessons.isEmpty && filteredWeakTopics.isEmpty && filteredActionableAutoDemotedTopics.isEmpty && commodityWeakTopics.isEmpty {
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

            if !filteredActionableAutoDemotedTopics.isEmpty {
                markdown += "### Auto-demoted Weak Topics\n"
                for metric in filteredActionableAutoDemotedTopics.prefix(8) {
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

            if !filteredWeakTopics.isEmpty {
                markdown += "### Weak Durable Topics\n"
                for hotspot in filteredWeakTopics.prefix(8) {
                    markdown += "- [[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]]"
                    markdown += " — durable but thinly supported: \(hotspot.relationStats.coOccurrenceEdges) loose links"
                    markdown += ", only \(hotspot.relationStats.typedEdges) strong relation"
                    if hotspot.relationStats.typedEdges == 1 { markdown += "" } else { markdown += "s" }
                    markdown += "\n"
                }
                markdown += "\n"
            }
        }

        markdown += "## Safe Auto-Actions\n"
        if safeActions.isEmpty {
            markdown += "- No high-confidence auto-actions right now.\n\n"
        } else {
            let lessonPromotions = safeActions.filter { $0.kind == .promoteToLessonDraft }
            let consolidations = safeActions.filter { $0.kind == .consolidateIntoRoot }
            if let applyIndexArtifact {
                markdown += "- [[\(applyIndexArtifact.linkTarget)|\(applyIndexArtifact.kind.linkLabel)]]\n\n"
            }

            if !lessonPromotions.isEmpty {
                markdown += "### Draft Lesson Promotions\n"
                for action in lessonPromotions.prefix(6) {
                    markdown += "- [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
                    markdown += " — promote into \(KnowledgeEntityType.lesson.folderName): \(action.reason)\n"
                    for artifact in draftArtifactsByKey[safeActionKey(action)] ?? [] {
                        markdown += "  \(artifact.kind.lineLabel): [[\(artifact.linkTarget)|\(artifact.kind.linkLabel)]]\n"
                    }
                }
                markdown += "\n"
            }

            if !consolidations.isEmpty {
                markdown += "### Safe Consolidations\n"
                for action in consolidations.prefix(6) {
                    guard let target = action.target else { continue }
                    markdown += "- [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
                    markdown += " → [[\(linkTarget(for: target))|\(target.canonicalName)]]"
                    markdown += " — \(action.reason)\n"
                    for artifact in draftArtifactsByKey[safeActionKey(action)] ?? [] {
                        markdown += "  \(artifact.kind.lineLabel): [[\(artifact.linkTarget)|\(artifact.kind.linkLabel)]]\n"
                    }
                }
                markdown += "\n"
            }
        }

        markdown += "## Improvement Candidates\n"
        if filteredReclassifyCandidates.isEmpty && filteredConsolidationCandidates.isEmpty && filteredStaleCandidates.isEmpty {
            markdown += "- No merge, reclassify, or stale review candidates right now.\n\n"
        } else {
            if !filteredReclassifyCandidates.isEmpty {
                markdown += "### Reclassify Candidates\n"
                for candidate in filteredReclassifyCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"
                    markdown += " — consider moving to \(candidate.targetType.folderName): \(candidate.reason)\n"
                    if let reviewArtifact = manualReviewArtifactsByKey[manualReviewKey(for: candidate)]?
                        .first(where: { $0.kind == .reviewDraft }) {
                        markdown += "  Review: [[\(reviewArtifact.linkTarget)|review draft]]\n"
                    }
                }
                markdown += "\n"
            }

            if !filteredConsolidationCandidates.isEmpty {
                markdown += "### Consolidation Candidates\n"
                for candidate in filteredConsolidationCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.source))|\(candidate.source.canonicalName)]]"
                    markdown += " → [[\(linkTarget(for: candidate.target))|\(candidate.target.canonicalName)]]"
                    markdown += " — \(candidate.reason)\n"
                    if let reviewArtifact = manualReviewArtifactsByKey[manualReviewKey(for: candidate)]?
                        .first(where: { $0.kind == .reviewDraft }) {
                        markdown += "  Review: [[\(reviewArtifact.linkTarget)|review draft]]\n"
                    }
                }
                markdown += "\n"
            }

            if !filteredStaleCandidates.isEmpty {
                markdown += "### Stale Review Candidates\n"
                for candidate in filteredStaleCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"
                    markdown += " — last seen \(candidate.daysSinceSeen) day"
                    if candidate.daysSinceSeen == 1 { markdown += "" } else { markdown += "s" }
                    markdown += " ago; \(candidate.reason)\n"
                    if let reviewArtifact = manualReviewArtifactsByKey[manualReviewKey(for: candidate)]?
                        .first(where: { $0.kind == .reviewDraft }) {
                        markdown += "  Review: [[\(reviewArtifact.linkTarget)|review draft]]\n"
                    }
                }
                markdown += "\n"
            }
        }

        markdown += "## Recently Applied\n"
        if appliedActions.isEmpty {
            markdown += "- No applied KB actions tracked yet.\n\n"
        } else {
            for action in appliedActions
                .sorted(by: compareAppliedActions)
                .prefix(8) {
                markdown += "- \(formattedAppliedAction(action))\n"
                if let backupPath = action.backupPath, !backupPath.isEmpty {
                    markdown += "  Backup: `\(backupPath)`\n"
                }
            }
            markdown += "\n"
        }

        markdown += "## Recently Reviewed\n"
        let sortedReviewDecisions = reviewDecisions.sorted(by: compareReviewDecisions)
        if sortedReviewDecisions.isEmpty {
            markdown += "- No non-pending review decisions tracked yet.\n\n"
        } else {
            markdown += "- [[Knowledge/_reviewed|review history]]\n"
            markdown += "- [[Knowledge/_drafts/ReviewResolved/_index|resolved review board]]\n"
            for decision in sortedReviewDecisions.prefix(8) {
                markdown += "- \(formattedReviewDecision(decision))\n"
            }
            markdown += "\n"
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

        return KnowledgeMaintenanceArtifacts(
            markdown: markdown,
            draftArtifacts: draftArtifacts
        )
    }

    func buildMarkdown(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>,
        graphShaper: GraphShaper,
        appliedActions: [KnowledgeAppliedActionRecord] = [],
        aliasOverrides: [KnowledgeAliasOverrideRecord] = [],
        reviewDecisions: [KnowledgeReviewDecisionRecord] = []
    ) throws -> String {
        try buildArtifacts(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds,
            graphShaper: graphShaper,
            appliedActions: appliedActions,
            aliasOverrides: aliasOverrides,
            reviewDecisions: reviewDecisions
        ).markdown
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

    private func compareAppliedActions(_ lhs: KnowledgeAppliedActionRecord, _ rhs: KnowledgeAppliedActionRecord) -> Bool {
        if lhs.appliedAt != rhs.appliedAt {
            return lhs.appliedAt > rhs.appliedAt
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func compareReviewDecisions(_ lhs: KnowledgeReviewDecisionRecord, _ rhs: KnowledgeReviewDecisionRecord) -> Bool {
        if lhs.recordedAt != rhs.recordedAt {
            return (lhs.recordedAt ?? "") > (rhs.recordedAt ?? "")
        }
        return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
    }

    private func formattedAppliedAction(_ action: KnowledgeAppliedActionRecord) -> String {
        let timestamp = dateSupport
            .parseDateTime(action.appliedAt)
            .map(dateSupport.localDateTimeString(from:))
            ?? action.appliedAt
        let linkTarget = "Knowledge/\(action.applyTargetRelativePath.replacingOccurrences(of: ".md", with: ""))"
        switch action.kind {
        case .lessonPromotion:
            return "`\(timestamp)` — promoted [[\(linkTarget)|\(action.title)]] into the main knowledge tree"
        case .lessonRedirect:
            return "`\(timestamp)` — applied a lesson redirect at [[\(linkTarget)|\(action.title)]]"
        case .redirect:
            return "`\(timestamp)` — applied a consolidation redirect at [[\(linkTarget)|\(action.title)]]"
        case .mergeOverlay:
            if let targetTitle = action.targetTitle {
                return "`\(timestamp)` — merged context from `\(action.title)` into [[\(linkTarget)|\(targetTitle)]]"
            }
            return "`\(timestamp)` — merged context into [[\(linkTarget)|\(action.title)]]"
        case .suppression:
            return "`\(timestamp)` — suppressed [[\(linkTarget)|\(action.title)]] from the active knowledge graph"
        }
    }

    private func formattedReviewDecision(_ decision: KnowledgeReviewDecisionRecord) -> String {
        let timestamp = decision.recordedAt.flatMap(dateSupport.parseDateTime)
            .map(dateSupport.localDateTimeString(from:))
            ?? decision.recordedAt
            ?? "unknown time"
        let draftLink = reviewDecisionLinkTarget(for: decision)
        switch decision.status {
        case .apply:
            return "`\(timestamp)` — approved [[\(draftLink)|\(decision.title)]]"
        case .dismiss:
            return "`\(timestamp)` — dismissed [[\(draftLink)|\(decision.title)]]"
        case .pending:
            return "`\(timestamp)` — pending [[\(draftLink)|\(decision.title)]]"
        }
    }

    private func reviewDecisionLinkTarget(for decision: KnowledgeReviewDecisionRecord) -> String {
        if let range = decision.path.range(of: "/Knowledge/_drafts/") {
            let relative = String(decision.path[range.upperBound...]).replacingOccurrences(of: ".md", with: "")
            return "Knowledge/_drafts/\(relative)"
        }
        let draftName = ((decision.path as NSString).lastPathComponent as NSString).deletingPathExtension
        return "Knowledge/_drafts/Review/\(draftName)"
    }

    private func buildReclassifyCandidates(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>,
        appliedDecisionIndex: KnowledgeAppliedDecisionIndex
    ) -> [KnowledgeReclassifyCandidate] {
        metrics
            .filter { materializedEntityIds.contains($0.entity.id) }
            .filter {
                !isAlreadyPromoted($0.entity, appliedDecisionIndex: appliedDecisionIndex)
                    && !isAlreadyMerged($0.entity, appliedDecisionIndex: appliedDecisionIndex)
            }
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
        materializedEntityIds: Set<String>,
        appliedDecisionIndex: KnowledgeAppliedDecisionIndex
    ) -> [KnowledgeConsolidationCandidate] {
        let visibleMetrics = metrics.filter { materializedEntityIds.contains($0.entity.id) }
        let topics = visibleMetrics.filter { $0.entity.entityType == .topic }
        var candidates: [KnowledgeConsolidationCandidate] = []
        var seenPairs = Set<String>()

        for source in topics {
            guard !isAlreadyMerged(source.entity, appliedDecisionIndex: appliedDecisionIndex) else { continue }
            for target in topics {
                guard source.entity.id != target.entity.id else { continue }
                guard !isAlreadyMerged(source.entity, into: target.entity, appliedDecisionIndex: appliedDecisionIndex) else {
                    continue
                }
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
        appliedDecisionIndex: KnowledgeAppliedDecisionIndex,
        now: Date = Date()
    ) -> [KnowledgeStaleCandidate] {
        metrics
            .filter { materializedEntityIds.contains($0.entity.id) }
            .filter {
                !isAlreadyPromoted($0.entity, appliedDecisionIndex: appliedDecisionIndex)
                    && !isAlreadyMerged($0.entity, appliedDecisionIndex: appliedDecisionIndex)
            }
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

    private func buildAppliedDecisionIndex(
        appliedActions: [KnowledgeAppliedActionRecord],
        aliasOverrides: [KnowledgeAliasOverrideRecord]
    ) -> KnowledgeAppliedDecisionIndex {
        guard !appliedActions.isEmpty || !aliasOverrides.isEmpty else {
            return .empty
        }

        var promotedEntityIds = Set<String>()
        var promotedNameKeys = Set<String>()
        var mergedEntityIds = Set<String>()
        var mergedSourceKeys = Set<String>()
        var mergedTargetKeysBySourceKey: [String: Set<String>] = [:]

        for action in appliedActions {
            let titleKey = decisionKey(for: action.title)
            switch action.kind {
            case .lessonPromotion, .lessonRedirect:
                if let sourceEntityId = action.sourceEntityId, !sourceEntityId.isEmpty {
                    promotedEntityIds.insert(sourceEntityId)
                }
                if !titleKey.isEmpty {
                    promotedNameKeys.insert(titleKey)
                }
            case .redirect, .mergeOverlay:
                if let sourceEntityId = action.sourceEntityId, !sourceEntityId.isEmpty {
                    mergedEntityIds.insert(sourceEntityId)
                }
                if !titleKey.isEmpty {
                    mergedSourceKeys.insert(titleKey)
                    if let targetTitle = action.targetTitle {
                        let targetKey = decisionKey(for: targetTitle)
                        if !targetKey.isEmpty {
                            mergedTargetKeysBySourceKey[titleKey, default: []].insert(targetKey)
                        }
                    }
                }
            case .suppression:
                continue
            }
        }

        for override in aliasOverrides {
            let sourceKey = decisionKey(for: override.sourceName)
            let canonicalKey = decisionKey(for: override.canonicalName)
            switch override.entityType {
            case .lesson:
                if !sourceKey.isEmpty {
                    promotedNameKeys.insert(sourceKey)
                }
            default:
                if override.reason == "mergeOverlay", !sourceKey.isEmpty {
                    mergedSourceKeys.insert(sourceKey)
                    if !canonicalKey.isEmpty {
                        mergedTargetKeysBySourceKey[sourceKey, default: []].insert(canonicalKey)
                    }
                }
            }
        }

        return KnowledgeAppliedDecisionIndex(
            promotedEntityIds: promotedEntityIds,
            promotedNameKeys: promotedNameKeys,
            mergedEntityIds: mergedEntityIds,
            mergedSourceKeys: mergedSourceKeys,
            mergedTargetKeysBySourceKey: mergedTargetKeysBySourceKey
        )
    }

    private func isAlreadyPromoted(
        _ entity: KnowledgeEntityRecord,
        appliedDecisionIndex: KnowledgeAppliedDecisionIndex
    ) -> Bool {
        appliedDecisionIndex.promotedEntityIds.contains(entity.id)
            || appliedDecisionIndex.promotedNameKeys.contains(decisionKey(for: entity.canonicalName))
    }

    private func isAlreadyMerged(
        _ entity: KnowledgeEntityRecord,
        appliedDecisionIndex: KnowledgeAppliedDecisionIndex
    ) -> Bool {
        appliedDecisionIndex.mergedEntityIds.contains(entity.id)
            || appliedDecisionIndex.mergedSourceKeys.contains(decisionKey(for: entity.canonicalName))
    }

    private func isAlreadyMerged(
        _ source: KnowledgeEntityRecord,
        into target: KnowledgeEntityRecord,
        appliedDecisionIndex: KnowledgeAppliedDecisionIndex
    ) -> Bool {
        let sourceKey = decisionKey(for: source.canonicalName)
        let targetKey = decisionKey(for: target.canonicalName)
        guard !sourceKey.isEmpty, !targetKey.isEmpty else { return false }
        return appliedDecisionIndex.mergedTargetKeysBySourceKey[sourceKey]?.contains(targetKey) == true
    }

    private func decisionKey(for value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private func buildSafeActions(
        metrics: [KnowledgeEntityMetrics],
        reclassifyCandidates: [KnowledgeReclassifyCandidate],
        consolidationCandidates: [KnowledgeConsolidationCandidate]
    ) -> [KnowledgeSafeAction] {
        let metricIndex = Dictionary(uniqueKeysWithValues: metrics.map { ($0.entity.id, $0) })

        let lessonPromotions = reclassifyCandidates.compactMap { candidate -> KnowledgeSafeAction? in
            guard let metric = metricIndex[candidate.entity.id] else { return nil }
            let lowered = candidate.entity.canonicalName.lowercased()
            let hasStrongLessonSignal = [
                "guide",
                "workflow",
                "playbook",
                "setup",
                "optimization",
                "architecture",
                "strategy"
            ].contains { lowered.contains($0) }
            guard hasStrongLessonSignal else { return nil }
            guard metric.claimCount >= 2, metric.typedEdgeCount >= 2 else { return nil }
            return KnowledgeSafeAction(
                kind: .promoteToLessonDraft,
                source: candidate.entity,
                target: nil,
                reason: "high-confidence lesson-like note with stable repeated evidence",
                score: candidate.score + metric.typedEdgeCount * 4
            )
        }

        let safeConsolidations = consolidationCandidates.compactMap { candidate -> KnowledgeSafeAction? in
            guard let sourceMetric = metricIndex[candidate.source.id],
                  let targetMetric = metricIndex[candidate.target.id] else {
                return nil
            }
            let targetClearlyStronger =
                targetMetric.claimCount >= max(sourceMetric.claimCount * 2, sourceMetric.claimCount + 2) &&
                targetMetric.typedEdgeCount >= max(sourceMetric.typedEdgeCount, 1)
            guard targetClearlyStronger else { return nil }
            return KnowledgeSafeAction(
                kind: .consolidateIntoRoot,
                source: candidate.source,
                target: candidate.target,
                reason: "strong root note already dominates this topic family",
                score: candidate.score + targetMetric.claimCount * 3 + targetMetric.typedEdgeCount * 2
            )
        }

        return (lessonPromotions + safeConsolidations).sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            if lhs.kind != rhs.kind {
                switch (lhs.kind, rhs.kind) {
                case (.consolidateIntoRoot, .promoteToLessonDraft):
                    return true
                case (.promoteToLessonDraft, .consolidateIntoRoot):
                    return false
                default:
                    break
                }
            }
            return lhs.source.canonicalName.localizedCaseInsensitiveCompare(rhs.source.canonicalName) == .orderedAscending
        }
    }

    private func buildManualReviewItems(
        actionableAutoDemotedTopics: [KnowledgeEntityMetrics],
        weakTopics: [KnowledgeHotspot],
        reclassifyCandidates: [KnowledgeReclassifyCandidate],
        consolidationCandidates: [KnowledgeConsolidationCandidate],
        staleCandidates: [KnowledgeStaleCandidate]
    ) -> [KnowledgeManualReviewItem] {
        let reclassifyItems = reclassifyCandidates.map { candidate in
            KnowledgeManualReviewItem(
                kind: .reclassify,
                title: candidate.entity.canonicalName,
                markdownLine: "[[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]] → consider moving to \(candidate.targetType.folderName.lowercased())",
                score: candidate.score + 40,
                priority: reviewPriority(for: candidate),
                artifactKey: manualReviewKey(for: candidate)
            )
        }

        let consolidationItems = consolidationCandidates.map { candidate in
            KnowledgeManualReviewItem(
                kind: .consolidate,
                title: candidate.source.canonicalName,
                markdownLine: "[[\(linkTarget(for: candidate.source))|\(candidate.source.canonicalName)]] → [[\(linkTarget(for: candidate.target))|\(candidate.target.canonicalName)]]",
                score: candidate.score + 50,
                priority: reviewPriority(for: candidate),
                artifactKey: manualReviewKey(for: candidate)
            )
        }

        let weakTopicItems = actionableAutoDemotedTopics.map { metric in
            KnowledgeManualReviewItem(
                kind: .weakTopic,
                title: metric.entity.canonicalName,
                markdownLine: "`\(metric.entity.canonicalName)` — weak topic with \(metric.coOccurrenceEdgeCount) loose links and only \(metric.typedEdgeCount) strong relation\(metric.typedEdgeCount == 1 ? "" : "s")",
                score: metric.coOccurrenceEdgeCount * 2 - metric.typedEdgeCount,
                priority: .low,
                artifactKey: manualReviewKey(forWeakTopic: metric.entity)
            )
        }

        let weakDurableItems = weakTopics.map { hotspot in
            KnowledgeManualReviewItem(
                kind: .weakTopic,
                title: hotspot.entity.canonicalName,
                markdownLine: "[[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]] — durable but thinly supported",
                score: hotspot.relationStats.coOccurrenceEdges + hotspot.relationStats.projectRelations * 4,
                priority: hotspot.relationStats.projectRelations > 0 ? .medium : .low,
                artifactKey: manualReviewKey(forWeakTopic: hotspot.entity)
            )
        }

        let staleItems = staleCandidates.map { candidate in
            KnowledgeManualReviewItem(
                kind: .stale,
                title: candidate.entity.canonicalName,
                markdownLine: "[[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]] — stale for \(candidate.daysSinceSeen) day\(candidate.daysSinceSeen == 1 ? "" : "s")",
                score: min(candidate.daysSinceSeen, 365) / 7,
                priority: candidate.daysSinceSeen >= 120 ? .medium : .low,
                artifactKey: manualReviewKey(for: candidate)
            )
        }

        let kindPriority: [KnowledgeManualReviewItem.Kind: Int] = [
            .consolidate: 0,
            .reclassify: 1,
            .weakTopic: 2,
            .stale: 3
        ]

        var seenTitles = Set<String>()
        return (consolidationItems + reclassifyItems + weakTopicItems + weakDurableItems + staleItems)
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    return lhs.priority.sortOrder < rhs.priority.sortOrder
                }
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                let lhsPriority = kindPriority[lhs.kind, default: 99]
                let rhsPriority = kindPriority[rhs.kind, default: 99]
                if lhsPriority != rhsPriority {
                    return lhsPriority < rhsPriority
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            .filter { item in
                let key = decisionKey(for: item.title)
                guard seenTitles.insert(key).inserted else { return false }
                return true
            }
    }

    private func reviewPriority(for candidate: KnowledgeReclassifyCandidate) -> KnowledgeManualReviewItem.Priority {
        candidate.score >= 55 ? .high : .medium
    }

    private func reviewPriority(for candidate: KnowledgeConsolidationCandidate) -> KnowledgeManualReviewItem.Priority {
        candidate.score >= 65 ? .high : .medium
    }

    private func manualReviewKey(for candidate: KnowledgeReclassifyCandidate) -> String {
        "reclassify:\(candidate.entity.id)"
    }

    private func manualReviewKey(for candidate: KnowledgeConsolidationCandidate) -> String {
        "consolidate:\(candidate.source.id)->\(candidate.target.id)"
    }

    private func manualReviewKey(for candidate: KnowledgeStaleCandidate) -> String {
        "stale:\(candidate.entity.id)"
    }

    private func manualReviewKey(forWeakTopic entity: KnowledgeEntityRecord) -> String {
        "weak:\(entity.id)"
    }

    private func manualReviewKey(for action: KnowledgeSafeAction) -> String {
        switch action.kind {
        case .promoteToLessonDraft:
            return "reclassify:\(action.source.id)"
        case .consolidateIntoRoot:
            guard let target = action.target else {
                return "consolidate:\(action.source.id)"
            }
            return "consolidate:\(action.source.id)->\(target.id)"
        }
    }

    private func buildManualReviewDraftArtifacts(
        actionableAutoDemotedTopics: [KnowledgeEntityMetrics],
        weakTopics: [KnowledgeHotspot],
        reclassifyCandidates: [KnowledgeReclassifyCandidate],
        consolidationCandidates: [KnowledgeConsolidationCandidate],
        staleCandidates: [KnowledgeStaleCandidate]
    ) throws -> [(key: String, value: KnowledgeDraftArtifact)] {
        var artifacts: [(key: String, value: KnowledgeDraftArtifact)] = []

        for candidate in reclassifyCandidates {
            artifacts.append((manualReviewKey(for: candidate), try buildReclassifyReviewDraft(for: candidate)))
            let reviewAction = manualReviewAction(for: candidate)
            let lessonArtifact = try buildLessonPromotionApplyDraft(for: reviewAction)
            artifacts.append((
                manualReviewKey(for: candidate),
                rehousedReviewApplyArtifact(
                    lessonArtifact,
                    relativePath: lessonArtifact.relativePath.replacingOccurrences(of: "Apply/", with: "ReviewApply/"),
                    reviewPacketKey: manualReviewKey(for: candidate),
                    reviewDecisionKind: .promoteToLesson
                )
            ))
            let redirectArtifact = buildLessonPromotionRedirectDraft(for: reviewAction)
            artifacts.append((
                manualReviewKey(for: candidate),
                rehousedReviewApplyArtifact(
                    redirectArtifact,
                    relativePath: redirectArtifact.relativePath.replacingOccurrences(of: "Apply/", with: "ReviewApply/"),
                    reviewPacketKey: manualReviewKey(for: candidate),
                    reviewDecisionKind: .promoteToLesson
                )
            ))
        }
        for candidate in consolidationCandidates {
            artifacts.append((manualReviewKey(for: candidate), try buildManualConsolidationReviewDraft(for: candidate)))
            let reviewAction = manualReviewAction(for: candidate)
            if let redirectArtifact = try buildConsolidationApplyDraft(for: reviewAction) {
                artifacts.append((
                    manualReviewKey(for: candidate),
                    rehousedReviewApplyArtifact(
                        redirectArtifact,
                        relativePath: redirectArtifact.relativePath.replacingOccurrences(of: "Apply/", with: "ReviewApply/"),
                        reviewPacketKey: manualReviewKey(for: candidate),
                        reviewDecisionKind: .consolidate
                    )
                ))
            }
            if let mergeArtifact = try buildConsolidationMergeDraft(for: reviewAction) {
                artifacts.append((
                    manualReviewKey(for: candidate),
                    rehousedReviewApplyArtifact(
                        mergeArtifact,
                        relativePath: mergeArtifact.relativePath.replacingOccurrences(of: "Apply/", with: "ReviewApply/"),
                        reviewPacketKey: manualReviewKey(for: candidate),
                        reviewDecisionKind: .consolidate
                    )
                ))
            }
        }
        for candidate in staleCandidates {
            artifacts.append((manualReviewKey(for: candidate), buildStaleReviewDraft(for: candidate)))
        }
        for metric in actionableAutoDemotedTopics {
            artifacts.append((manualReviewKey(forWeakTopic: metric.entity), buildWeakTopicReviewDraft(for: metric)))
        }
        for hotspot in weakTopics {
            artifacts.append((manualReviewKey(forWeakTopic: hotspot.entity), buildWeakDurableTopicReviewDraft(for: hotspot)))
        }

        return artifacts
    }

    private func manualReviewAction(for candidate: KnowledgeReclassifyCandidate) -> KnowledgeSafeAction {
        KnowledgeSafeAction(
            kind: .promoteToLessonDraft,
            source: candidate.entity,
            target: nil,
            reason: candidate.reason,
            score: candidate.score
        )
    }

    private func manualReviewAction(for candidate: KnowledgeConsolidationCandidate) -> KnowledgeSafeAction {
        KnowledgeSafeAction(
            kind: .consolidateIntoRoot,
            source: candidate.source,
            target: candidate.target,
            reason: candidate.reason,
            score: candidate.score
        )
    }

    private func rehousedReviewApplyArtifact(
        _ artifact: KnowledgeDraftArtifact,
        relativePath: String,
        reviewPacketKey: String,
        reviewDecisionKind: KnowledgeReviewDecisionKind
    ) -> KnowledgeDraftArtifact {
        KnowledgeDraftArtifact(
            kind: artifact.kind,
            relativePath: relativePath,
            title: artifact.title,
            markdown: artifact.markdown,
            applyTargetRelativePath: artifact.applyTargetRelativePath,
            suppressedEntityId: artifact.suppressedEntityId,
            mergeOverlayDraft: artifact.mergeOverlayDraft,
            reviewPacketKey: reviewPacketKey,
            reviewDecisionKind: reviewDecisionKind
        )
    }

    private func buildDraftArtifacts(from safeActions: [KnowledgeSafeAction]) throws -> [(key: String, value: KnowledgeDraftArtifact)] {
        var artifacts: [(key: String, value: KnowledgeDraftArtifact)] = []

        for action in safeActions {
            let key = safeActionKey(action)
            switch action.kind {
            case .promoteToLessonDraft:
                artifacts.append((key, buildLessonPromotionReviewDraft(for: action)))
                artifacts.append((key, try buildLessonPromotionApplyDraft(for: action)))
                artifacts.append((key, buildLessonPromotionRedirectDraft(for: action)))
            case .consolidateIntoRoot:
                if let artifact = buildConsolidationReviewDraft(for: action) {
                    artifacts.append((key, artifact))
                }
                if let applyArtifact = try buildConsolidationApplyDraft(for: action) {
                    artifacts.append((key, applyArtifact))
                }
                if let mergeArtifact = try buildConsolidationMergeDraft(for: action) {
                    artifacts.append((key, mergeArtifact))
                }
            }
        }

        return artifacts
    }

    private func buildLessonPromotionReviewDraft(for action: KnowledgeSafeAction) -> KnowledgeDraftArtifact {
        let destinationSlug = slug(for: action.source.canonicalName)
        let relativePath = "Maintenance/lesson-promotion-\(destinationSlug).md"
        let sourceLink = "[[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
        let draft = """
        # Draft Lesson Promotion — \(action.source.canonicalName)

        ## Candidate
        - Source note: \(sourceLink)
        - Proposed destination: [[Knowledge/Lessons/\(destinationSlug)|\(action.source.canonicalName)]]
        - Reason: \(action.reason)

        ## Proposed Lesson Stub
        ```md
        # \(action.source.canonicalName)

        _Type: lesson_

        ## Draft Summary
        - Promoted from \(sourceLink) because this note behaves like durable guidance rather than a standalone topic.

        ## Source Material
        - \(sourceLink)
        ```

        ## Review Checklist
        - Keep the original topic note as an alias or short redirect if existing links already point to it.
        - Fold reusable guidance into the lesson note before deleting or downgrading the topic note.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Draft Lesson Promotion — \(action.source.canonicalName)",
            markdown: draft
        )
    }

    private func buildLessonPromotionApplyDraft(for action: KnowledgeSafeAction) throws -> KnowledgeDraftArtifact {
        let destinationSlug = slug(for: action.source.canonicalName)
        let relativePath = "Apply/Lessons/\(destinationSlug).md"
        let applyTargetRelativePath = "Lessons/\(destinationSlug).md"
        let sourceLink = "[[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
        let destinationLink = "[[Knowledge/Lessons/\(destinationSlug)|\(action.source.canonicalName)]]"
        let sourceNote = try loadKnowledgeNote(for: action.source)
        let overview = extractOverview(from: sourceNote?.bodyMarkdown)
            ?? "Promoted from \(sourceLink) because this note now behaves like durable guidance instead of a loose standalone topic."
        let signalLines = extractBulletSection("Key Signals", from: sourceNote?.bodyMarkdown).prefix(4)
        let relationshipLines = extractBulletSection("Relationships", from: sourceNote?.bodyMarkdown).prefix(4)
        let aliases = aliases(for: action.source)

        var draft = "# \(action.source.canonicalName)\n\n"
        draft += "_Apply-ready lesson draft generated from a safe maintenance action._\n\n"
        draft += "## Draft Summary\n"
        draft += "\(overview)\n\n"
        draft += "## Distilled Guidance\n"
        if signalLines.isEmpty {
            draft += "- Reframe this note as reusable guidance rather than a narrow topic fragment.\n"
            draft += "- Keep the explanation concise enough to survive outside the original hourly window.\n"
        } else {
            for line in signalLines {
                draft += "\(line)\n"
            }
        }
        draft += "\n## Related Context\n"
        if relationshipLines.isEmpty {
            draft += "- Source note: \(sourceLink)\n"
            draft += "- Proposed final location: \(destinationLink)\n"
        } else {
            for line in relationshipLines {
                draft += "\(line)\n"
            }
        }
        draft += "\n## Source Trail\n"
        draft += "- Promoted from: \(sourceLink)\n"
        draft += "- Proposed final location: \(destinationLink)\n"
        draft += "- Promotion reason: \(action.reason)\n"
        if !aliases.isEmpty {
            draft += "- Preserve aliases: \(joinNaturalLanguage(aliases))\n"
        }
        draft += "\n## Review Checklist\n"
        draft += "- Tighten the summary into durable guidance before moving this note into `Knowledge/Lessons`.\n"
        draft += "- Keep a short redirect or alias note if existing links already point to the topic note.\n"
        draft += "- Pull over any unique relationships that are missing from the target lesson.\n"

        return KnowledgeDraftArtifact(
            kind: .applyReadyLesson,
            relativePath: relativePath,
            title: action.source.canonicalName,
            markdown: draft,
            applyTargetRelativePath: applyTargetRelativePath,
            suppressedEntityId: action.source.id
        )
    }

    private func buildLessonPromotionRedirectDraft(for action: KnowledgeSafeAction) -> KnowledgeDraftArtifact {
        let sourceSlug = slug(for: action.source.canonicalName)
        let destinationSlug = slug(for: action.source.canonicalName)
        let relativePath = "Apply/Redirects/\(sourceSlug)-to-lesson.md"
        let applyTargetRelativePath = "\(action.source.entityType.folderName)/\(sourceSlug).md"
        let sourceLink = "[[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
        let destinationLink = "[[Knowledge/Lessons/\(destinationSlug)|\(action.source.canonicalName)]]"
        let aliases = aliases(for: action.source)

        var draft = "# \(action.source.canonicalName)\n\n"
        draft += "_Redirect stub generated from a safe lesson-promotion action._\n\n"
        draft += "This topic now points to \(destinationLink).\n\n"
        draft += "## Proposed Redirect Copy\n"
        draft += "For durable guidance, use \(destinationLink).\n\n"
        draft += "## Alias Trail\n"
        draft += "- \(action.source.canonicalName)\n"
        for alias in aliases.prefix(6) {
            draft += "- \(alias)\n"
        }
        draft += "\n## Review Checklist\n"
        draft += "- Keep this redirect in place until backlinks stop depending on \(sourceLink).\n"
        draft += "- Preserve old aliases on the destination lesson note.\n"
        draft += "- Remove the standalone topic only after the lesson note fully captures the reusable guidance.\n"

        return KnowledgeDraftArtifact(
            kind: .applyReadyLessonRedirect,
            relativePath: relativePath,
            title: action.source.canonicalName,
            markdown: draft,
            applyTargetRelativePath: applyTargetRelativePath,
            suppressedEntityId: action.source.id
        )
    }

    private func buildConsolidationReviewDraft(for action: KnowledgeSafeAction) -> KnowledgeDraftArtifact? {
        guard let target = action.target else { return nil }
        let sourceSlug = slug(for: action.source.canonicalName)
        let targetSlug = slug(for: target.canonicalName)
        let relativePath = "Maintenance/consolidate-\(sourceSlug)-into-\(targetSlug).md"
        let sourceLink = "[[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
        let targetLink = "[[\(linkTarget(for: target))|\(target.canonicalName)]]"
        let draft = """
        # Draft Consolidation — \(action.source.canonicalName) → \(target.canonicalName)

        ## Candidate
        - Source note: \(sourceLink)
        - Target note: \(targetLink)
        - Reason: \(action.reason)

        ## Suggested Redirect / Alias Stub
        ```md
        # \(action.source.canonicalName)

        _Redirect candidate_

        This note likely belongs under \(targetLink).

        ## Alias Trail
        - \(action.source.canonicalName)
        ```

        ## Merge Checklist
        - Move any unique claims from \(sourceLink) into \(targetLink).
        - Preserve \(action.source.canonicalName) as an alias if existing links still reference it.
        - Replace or redirect weak standalone notes after the root note captures the missing context.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Draft Consolidation — \(action.source.canonicalName) → \(target.canonicalName)",
            markdown: draft
        )
    }

    private func buildConsolidationApplyDraft(for action: KnowledgeSafeAction) throws -> KnowledgeDraftArtifact? {
        guard let target = action.target else { return nil }
        let sourceSlug = slug(for: action.source.canonicalName)
        let targetSlug = slug(for: target.canonicalName)
        let relativePath = "Apply/Redirects/\(sourceSlug)-to-\(targetSlug).md"
        let applyTargetRelativePath = "\(action.source.entityType.folderName)/\(sourceSlug).md"
        let sourceLink = "[[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
        let targetLink = "[[\(linkTarget(for: target))|\(target.canonicalName)]]"
        let sourceNote = try loadKnowledgeNote(for: action.source)
        let overview = extractOverview(from: sourceNote?.bodyMarkdown)
        let signalLines = extractBulletSection("Key Signals", from: sourceNote?.bodyMarkdown).prefix(4)
        let aliases = aliases(for: action.source)

        var draft = "# \(action.source.canonicalName)\n\n"
        draft += "_Redirect stub draft generated from a safe consolidation action._\n\n"
        draft += "This note likely folds into \(targetLink).\n\n"
        draft += "## Proposed Redirect Copy\n"
        draft += "This slice of work is better treated as part of \(targetLink). Review the unique context below before replacing the standalone note.\n\n"
        draft += "## Unique Context To Preserve\n"
        if !signalLines.isEmpty {
            for line in signalLines {
                draft += "\(line)\n"
            }
        } else if let overview {
            draft += "- \(overview)\n"
        } else {
            draft += "- Source note: \(sourceLink)\n"
        }
        draft += "\n## Alias Trail\n"
        draft += "- \(action.source.canonicalName)\n"
        for alias in aliases.prefix(6) {
            draft += "- \(alias)\n"
        }
        draft += "\n## Merge Checklist\n"
        draft += "- Move any unique signals from \(sourceLink) into \(targetLink).\n"
        draft += "- Preserve \(action.source.canonicalName) as an alias on the stronger root note if links still point here.\n"
        draft += "- Replace the standalone note only after the root note captures the missing context.\n"

        return KnowledgeDraftArtifact(
            kind: .applyReadyRedirect,
            relativePath: relativePath,
            title: action.source.canonicalName,
            markdown: draft,
            applyTargetRelativePath: applyTargetRelativePath,
            suppressedEntityId: action.source.id
        )
    }

    private func buildConsolidationMergeDraft(for action: KnowledgeSafeAction) throws -> KnowledgeDraftArtifact? {
        guard let target = action.target else { return nil }
        let sourceSlug = slug(for: action.source.canonicalName)
        let targetSlug = slug(for: target.canonicalName)
        let relativePath = "Apply/Merge/\(sourceSlug)-into-\(targetSlug).md"
        let targetRelativePath = "\(target.entityType.folderName)/\(targetSlug).md"
        let sourceLink = "[[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
        let targetLink = "[[\(linkTarget(for: target))|\(target.canonicalName)]]"
        let sourceNote = try loadKnowledgeNote(for: action.source)
        let overview = extractOverview(from: sourceNote?.bodyMarkdown)
        let signalLines = extractBulletSection("Key Signals", from: sourceNote?.bodyMarkdown).prefix(5)
        let relationshipLines = extractBulletSection("Relationships", from: sourceNote?.bodyMarkdown).prefix(5)
        let aliases = aliases(for: action.source)

        var draft = "# Merge Patch — \(action.source.canonicalName) → \(target.canonicalName)\n\n"
        draft += "_Apply-ready merge packet generated from a safe consolidation action._\n\n"
        draft += "## Merge Intent\n"
        draft += "Fold \(sourceLink) into \(targetLink) while preserving any unique context and aliases.\n\n"
        draft += "## Source Summary\n"
        if let overview {
            draft += "- \(overview)\n"
        } else {
            draft += "- Source note: \(sourceLink)\n"
        }
        draft += "\n## Signals To Preserve\n"
        if signalLines.isEmpty && relationshipLines.isEmpty {
            draft += "- No extra structured signals were found beyond the source note title.\n"
        } else {
            for line in signalLines {
                draft += "\(line)\n"
            }
            for line in relationshipLines {
                draft += "\(line)\n"
            }
        }
        draft += "\n## Suggested Root Additions\n"
        draft += "- Add `\(action.source.canonicalName)` to the alias trail of \(targetLink).\n"
        draft += "- Pull any unique summary or relationship context from \(sourceLink) into \(targetLink).\n"
        if !aliases.isEmpty {
            draft += "- Preserve aliases: \(joinNaturalLanguage(aliases))\n"
        }
        draft += "\n## Review Checklist\n"
        draft += "- Update the stronger root note before replacing the standalone source note.\n"
        draft += "- Keep a redirect stub until backlinks stop depending on the source title.\n"
        draft += "- Rebuild the knowledge graph after merging to confirm the weaker note drops out cleanly.\n"

        return KnowledgeDraftArtifact(
            kind: .applyReadyMergePatch,
            relativePath: relativePath,
            title: "Merge Patch — \(action.source.canonicalName) → \(target.canonicalName)",
            markdown: draft,
            suppressedEntityId: action.source.id,
            mergeOverlayDraft: KnowledgeDraftArtifact.MergeOverlayDraft(
                sourceEntityId: action.source.id,
                sourceTitle: action.source.canonicalName,
                sourceAliases: aliases,
                sourceOverview: overview,
                preservedSignals: Array(signalLines),
                targetEntityId: target.id,
                targetTitle: target.canonicalName,
                targetRelativePath: targetRelativePath
            )
        )
    }

    private func buildApplyIndexArtifact(
        from safeActions: [KnowledgeSafeAction],
        draftArtifactsByKey: [String: [KnowledgeDraftArtifact]]
    ) -> KnowledgeDraftArtifact? {
        var lessonRows: [String] = []
        var redirectRows: [String] = []
        var mergeRows: [String] = []

        for action in safeActions {
            let artifacts = draftArtifactsByKey[safeActionKey(action)] ?? []
            switch action.kind {
            case .promoteToLessonDraft:
                guard let applyArtifact = artifacts.first(where: { $0.kind == .applyReadyLesson }) else { continue }
                let redirectArtifact = artifacts.first(where: { $0.kind == .applyReadyLessonRedirect })
                lessonRows.append(
                    "- [[\(applyArtifact.linkTarget)|\(action.source.canonicalName)]]"
                    + " — promote [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]] into a lesson draft"
                    + (redirectArtifact.map { " • [[\($0.linkTarget)|redirect]]" } ?? "")
                )
            case .consolidateIntoRoot:
                guard let target = action.target,
                      let applyArtifact = artifacts.first(where: { $0.kind == .applyReadyRedirect }) else {
                    continue
                }
                redirectRows.append(
                    "- [[\(applyArtifact.linkTarget)|\(action.source.canonicalName)]]"
                    + " → [[\(linkTarget(for: target))|\(target.canonicalName)]]"
                )
                if let mergeArtifact = artifacts.first(where: { $0.kind == .applyReadyMergePatch }) {
                    mergeRows.append(
                        "- [[\(mergeArtifact.linkTarget)|\(action.source.canonicalName)]]"
                        + " → [[\(linkTarget(for: target))|\(target.canonicalName)]]"
                    )
                }
            }
        }

        guard !lessonRows.isEmpty || !redirectRows.isEmpty || !mergeRows.isEmpty else { return nil }

        var markdown = "# Knowledge Apply Board\n\n"
        markdown += "_Apply-ready drafts exported from safe maintenance actions._\n\n"
        markdown += "- [[Knowledge/_drafts/_index|Workflow center]]\n\n"
        if !lessonRows.isEmpty {
            markdown += "## Lesson Promotions\n"
            markdown += lessonRows.joined(separator: "\n")
            markdown += "\n\n"
        }
        if !redirectRows.isEmpty {
            markdown += "## Redirect Stubs\n"
            markdown += redirectRows.joined(separator: "\n")
            markdown += "\n\n"
        }
        if !mergeRows.isEmpty {
            markdown += "## Merge Patches\n"
            markdown += mergeRows.joined(separator: "\n")
            markdown += "\n\n"
        }
        markdown += "## Usage\n"
        markdown += "- Review the apply-ready draft before moving it into the main `Knowledge/*` tree.\n"
        markdown += "- Keep the paired review draft open if you need the rationale and migration checklist.\n"
        markdown += "- Do not replace the main note until aliases and unique context are preserved.\n"

        return KnowledgeDraftArtifact(
            kind: .applyIndex,
            relativePath: "Apply/_index.md",
            title: "Knowledge Apply Board",
            markdown: markdown
        )
    }

    private func buildReviewIndexArtifact(
        from manualReviewItems: [KnowledgeManualReviewItem],
        draftArtifactsByKey: [String: [KnowledgeDraftArtifact]]
    ) -> KnowledgeDraftArtifact? {
        guard !manualReviewItems.isEmpty else { return nil }
        let prioritizedRows = manualReviewItems.compactMap { item -> (KnowledgeManualReviewItem.Priority, String)? in
            guard let reviewArtifact = draftArtifactsByKey[item.artifactKey]?.first(where: { $0.kind == .reviewDraft }) else {
                return nil
            }
            return (
                item.priority,
                "- [\(item.priority.badge)] [[\(reviewArtifact.linkTarget)|\(item.title)]] — \(manualReviewKindLabel(for: item.kind)): \(item.markdownLine)"
            )
        }

        guard !prioritizedRows.isEmpty else { return nil }

        let groupedRows = Dictionary(grouping: prioritizedRows, by: \.0)
        let highCount = groupedRows[.high]?.count ?? 0
        let mediumCount = groupedRows[.medium]?.count ?? 0
        let lowCount = groupedRows[.low]?.count ?? 0

        var markdown = "# Knowledge Review Board\n\n"
        markdown += "_Review packets exported from the current maintenance queue._\n\n"
        markdown += "- [[Knowledge/_drafts/_index|Workflow center]]\n\n"
        markdown += "## Priority Overview\n"
        markdown += "- High priority: \(highCount)\n"
        markdown += "- Standard review: \(mediumCount)\n"
        markdown += "- Low-signal review: \(lowCount)\n\n"

        for priority in [KnowledgeManualReviewItem.Priority.high, .medium, .low] {
            guard let rows = groupedRows[priority], !rows.isEmpty else { continue }
            markdown += "## \(priority.sectionTitle)\n"
            let rowLimit = priority == .low ? 6 : 10
            markdown += rows.map(\.1).prefix(rowLimit).joined(separator: "\n")
            if priority == .low && rows.count > rowLimit {
                let remaining = rows.count - rowLimit
                markdown += "\n- ...and \(remaining) more low-signal review packet"
                if remaining == 1 { markdown += "" } else { markdown += "s" }
            }
            markdown += "\n\n"
        }
        markdown += "## Usage\n"
        markdown += "- Open the linked review draft before changing the main `Knowledge/*` note.\n"
        markdown += "- Use these packets for merge, reclassify, stale, and weak-topic decisions that are not safe enough to auto-apply.\n"
        markdown += "- Once a decision is applied, the candidate should drop out of the review queue on the next rebuild.\n"

        return KnowledgeDraftArtifact(
            kind: .reviewIndex,
            relativePath: "Review/_index.md",
            title: "Knowledge Review Board",
            markdown: markdown
        )
    }

    private func manualReviewKindLabel(for kind: KnowledgeManualReviewItem.Kind) -> String {
        switch kind {
        case .reclassify:
            return "Reclassify"
        case .consolidate:
            return "Consolidate"
        case .weakTopic:
            return "Weak Topic"
        case .stale:
            return "Stale"
        }
    }

    private func buildWorkflowIndexArtifact(
        safeActions: [KnowledgeSafeAction],
        manualReviewItems: [KnowledgeManualReviewItem],
        applyIndexArtifact: KnowledgeDraftArtifact?,
        reviewIndexArtifact: KnowledgeDraftArtifact?,
        appliedActions: [KnowledgeAppliedActionRecord],
        reviewDecisions: [KnowledgeReviewDecisionRecord]
    ) -> KnowledgeDraftArtifact {
        var markdown = "# Knowledge Workflow Center\n\n"
        markdown += "_Operational hub for active, applied, and resolved knowledge actions._\n\n"
        markdown += "## Dashboard\n"
        markdown += "- [[Knowledge/_maintenance|maintenance dashboard]]\n"
        markdown += "- Safe to apply: \(safeActions.count)\n"
        markdown += "- Needs review: \(manualReviewItems.count)\n"
        markdown += "- Standard review: \(manualReviewItems.filter { $0.priority != .low }.count)\n"
        markdown += "- Low-signal review: \(manualReviewItems.filter { $0.priority == .low }.count)\n"
        markdown += "- Recently applied: \(appliedActions.count)\n"
        markdown += "- Recently reviewed: \(reviewDecisions.count)\n\n"

        markdown += "## Active Queues\n"
        if let applyIndexArtifact {
            markdown += "- [[\(applyIndexArtifact.linkTarget)|apply board]]\n"
        } else {
            markdown += "- No apply-ready packets right now.\n"
        }
        if let reviewIndexArtifact {
            markdown += "- [[\(reviewIndexArtifact.linkTarget)|review board]]\n"
        } else {
            markdown += "- No active review queue right now.\n"
        }
        markdown += "\n"

        markdown += "## History and Resolved\n"
        markdown += "- [[Knowledge/_applied|applied history]]\n"
        markdown += "- [[Knowledge/_reviewed|review history]]\n"
        markdown += "- [[Knowledge/_drafts/ReviewResolved/_index|resolved review board]]\n\n"

        markdown += "## Usage\n"
        markdown += "- Start here when you want to move through safe actions, review packets, and archived decisions without opening folders manually.\n"
        markdown += "- Use the apply board for high-confidence packets, the review board for manual decisions, and the resolved board to revisit closed decisions.\n"

        return KnowledgeDraftArtifact(
            kind: .workflowIndex,
            relativePath: "_index.md",
            title: "Knowledge Workflow Center",
            markdown: markdown
        )
    }

    private func buildReclassifyReviewDraft(for candidate: KnowledgeReclassifyCandidate) throws -> KnowledgeDraftArtifact {
        let note = try loadKnowledgeNote(for: candidate.entity)
        let overview = extractOverview(from: note?.bodyMarkdown)
        let keySignals = extractBulletSection("Key Signals", from: note?.bodyMarkdown).prefix(4)
        let relationships = extractBulletSection("Relationships", from: note?.bodyMarkdown).prefix(4)
        let relativePath = "Review/reclassify-\(candidate.entity.slug).md"
        let sourceLink = "[[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"
        let targetFolder = candidate.targetType.folderName
        let destinationLink = "[[Knowledge/\(targetFolder)/\(candidate.entity.slug)|\(candidate.entity.canonicalName)]]"

        var markdown = """
        <!-- memograph-review-key: \(manualReviewKey(for: candidate)) -->
        <!-- memograph-review-kind: \(KnowledgeReviewDecisionKind.promoteToLesson.rawValue) -->
        # Review Packet — Reclassify \(candidate.entity.canonicalName)

        """
        markdown += "## Candidate\n"
        markdown += "- Source note: \(sourceLink)\n"
        markdown += "- Proposed destination: \(destinationLink)\n"
        markdown += "- Reason: \(candidate.reason)\n\n"
        markdown += "## Decision\n"
        markdown += "- Change `Decision: pending` to `Decision: apply` once this review is approved.\n"
        markdown += "- Use `Decision: dismiss` if this note should stay as-is.\n"
        markdown += "Decision: pending\n\n"
        markdown += "## Current Read\n"
        if let overview {
            markdown += "- \(overview)\n"
        } else {
            markdown += "- No overview was available in the current note.\n"
        }
        markdown += "\n## Signals To Keep\n"
        if keySignals.isEmpty && relationships.isEmpty {
            markdown += "- Review the source note manually; no structured signals were available.\n"
        } else {
            for line in keySignals { markdown += "\(line)\n" }
            for line in relationships { markdown += "\(line)\n" }
        }
        markdown += "\n## Review Checklist\n"
        markdown += "- Confirm this note reads more like durable guidance than a standalone topic.\n"
        markdown += "- Keep aliases and backlinks intact if you move it under `\(targetFolder)`.\n"
        markdown += "- Preserve any unique project or topic relationships before changing the note type.\n"

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Review Packet — Reclassify \(candidate.entity.canonicalName)",
            markdown: markdown,
            reviewPacketKey: manualReviewKey(for: candidate),
            reviewDecisionKind: .promoteToLesson
        )
    }

    private func buildManualConsolidationReviewDraft(for candidate: KnowledgeConsolidationCandidate) throws -> KnowledgeDraftArtifact {
        let sourceNote = try loadKnowledgeNote(for: candidate.source)
        let sourceOverview = extractOverview(from: sourceNote?.bodyMarkdown)
        let sourceSignals = extractBulletSection("Key Signals", from: sourceNote?.bodyMarkdown).prefix(4)
        let relativePath = "Review/consolidate-\(candidate.source.slug)-into-\(candidate.target.slug).md"
        let sourceLink = "[[\(linkTarget(for: candidate.source))|\(candidate.source.canonicalName)]]"
        let targetLink = "[[\(linkTarget(for: candidate.target))|\(candidate.target.canonicalName)]]"

        var markdown = """
        <!-- memograph-review-key: \(manualReviewKey(for: candidate)) -->
        <!-- memograph-review-kind: \(KnowledgeReviewDecisionKind.consolidate.rawValue) -->
        # Review Packet — Consolidate \(candidate.source.canonicalName)

        """
        markdown += "## Candidate\n"
        markdown += "- Source note: \(sourceLink)\n"
        markdown += "- Target note: \(targetLink)\n"
        markdown += "- Reason: \(candidate.reason)\n\n"
        markdown += "## Decision\n"
        markdown += "- Change `Decision: pending` to `Decision: apply` once this merge is approved.\n"
        markdown += "- Use `Decision: dismiss` if the source note should remain standalone.\n"
        markdown += "Decision: pending\n\n"
        markdown += "## Source Context\n"
        if let sourceOverview {
            markdown += "- \(sourceOverview)\n"
        } else {
            markdown += "- No overview was available in the current source note.\n"
        }
        markdown += "\n## Signals To Preserve\n"
        if sourceSignals.isEmpty {
            markdown += "- Review the source note manually before merging.\n"
        } else {
            for line in sourceSignals { markdown += "\(line)\n" }
        }
        markdown += "\n## Review Checklist\n"
        markdown += "- Confirm the target note is actually the stronger root for this topic family.\n"
        markdown += "- Preserve unique aliases and context before redirecting the source note.\n"
        markdown += "- If the source still carries unique meaning, keep it separate and reject the consolidation.\n"

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Review Packet — Consolidate \(candidate.source.canonicalName)",
            markdown: markdown,
            reviewPacketKey: manualReviewKey(for: candidate),
            reviewDecisionKind: .consolidate
        )
    }

    private func buildStaleReviewDraft(for candidate: KnowledgeStaleCandidate) -> KnowledgeDraftArtifact {
        let relativePath = "Review/stale-\(candidate.entity.slug).md"
        let sourceLink = "[[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"

        let markdown = """
        <!-- memograph-review-key: \(manualReviewKey(for: candidate)) -->
        <!-- memograph-review-kind: \(KnowledgeReviewDecisionKind.suppress.rawValue) -->
        # Review Packet — Stale Note \(candidate.entity.canonicalName)

        ## Candidate
        - Note: \(sourceLink)
        - Last seen: \(candidate.daysSinceSeen) day\(candidate.daysSinceSeen == 1 ? "" : "s") ago
        - Reason: \(candidate.reason)

        ## Decision
        - Change `Decision: pending` to `Decision: apply` to suppress this note from the active knowledge graph.
        - Use `Decision: dismiss` if the note should stay visible.
        Decision: pending

        ## Review Checklist
        - Keep it if it still serves as durable reference material.
        - Merge or redirect it if a stronger root note already covers the same idea.
        - Archive or suppress it if it no longer has an active project trail.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Review Packet — Stale Note \(candidate.entity.canonicalName)",
            markdown: markdown,
            suppressedEntityId: candidate.entity.id,
            reviewPacketKey: manualReviewKey(for: candidate),
            reviewDecisionKind: .suppress
        )
    }

    private func buildWeakTopicReviewDraft(for metric: KnowledgeEntityMetrics) -> KnowledgeDraftArtifact {
        let relativePath = "Review/weak-topic-\(metric.entity.slug).md"
        let sourceLink = "[[\(linkTarget(for: metric.entity))|\(metric.entity.canonicalName)]]"

        let markdown = """
        <!-- memograph-review-key: \(manualReviewKey(forWeakTopic: metric.entity)) -->
        <!-- memograph-review-kind: \(KnowledgeReviewDecisionKind.suppress.rawValue) -->
        # Review Packet — Weak Topic \(metric.entity.canonicalName)

        ## Candidate
        - Topic: \(sourceLink)
        - Loose links: \(metric.coOccurrenceEdgeCount)
        - Strong relations: \(metric.typedEdgeCount)

        ## Decision
        - Change `Decision: pending` to `Decision: apply` to suppress this note from the active knowledge graph.
        - Use `Decision: dismiss` if the topic should stay visible.
        Decision: pending

        ## Review Checklist
        - Keep it only if it carries durable meaning beyond co-occurrence noise.
        - Consolidate it into a stronger root topic if it is just a narrow variant.
        - Reclassify it if it actually reads like a guide, workflow, or lesson.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Review Packet — Weak Topic \(metric.entity.canonicalName)",
            markdown: markdown,
            suppressedEntityId: metric.entity.id,
            reviewPacketKey: manualReviewKey(forWeakTopic: metric.entity),
            reviewDecisionKind: .suppress
        )
    }

    private func buildWeakDurableTopicReviewDraft(for hotspot: KnowledgeHotspot) -> KnowledgeDraftArtifact {
        let relativePath = "Review/durable-topic-\(hotspot.entity.slug).md"
        let sourceLink = "[[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]]"

        let markdown = """
        <!-- memograph-review-key: \(manualReviewKey(forWeakTopic: hotspot.entity)) -->
        <!-- memograph-review-kind: \(KnowledgeReviewDecisionKind.suppress.rawValue) -->
        # Review Packet — Thin Durable Topic \(hotspot.entity.canonicalName)

        ## Candidate
        - Topic: \(sourceLink)
        - Strong relations: \(hotspot.relationStats.typedEdges)
        - Loose links: \(hotspot.relationStats.coOccurrenceEdges)
        - Project trail: \(hotspot.relationStats.projectRelations)

        ## Decision
        - Change `Decision: pending` to `Decision: apply` to suppress this note from the active knowledge graph.
        - Use `Decision: dismiss` if the topic should stay visible.
        Decision: pending

        ## Review Checklist
        - Keep it visible if it represents a real durable topic the graph should expose.
        - Improve typed relations or merge it into a stronger topic if the note stays too thin.
        - Reclassify it if the title and context suggest a lesson rather than a topic.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Review Packet — Thin Durable Topic \(hotspot.entity.canonicalName)",
            markdown: markdown,
            suppressedEntityId: hotspot.entity.id,
            reviewPacketKey: manualReviewKey(forWeakTopic: hotspot.entity),
            reviewDecisionKind: .suppress
        )
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

    private func loadKnowledgeNote(for entity: KnowledgeEntityRecord) throws -> KnowledgeNoteRecord? {
        let rows = try db.query(
            "SELECT * FROM knowledge_notes WHERE id = ? LIMIT 1",
            params: [.text("knowledge:\(entity.id)")]
        )
        return rows.first.flatMap(KnowledgeNoteRecord.init(row:))
    }

    private func extractOverview(from markdown: String?) -> String? {
        guard let section = extractSection(named: "Overview", from: markdown) else { return nil }
        let lines = section
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("- ") && !$0.hasPrefix("### ") }
        return lines.first
    }

    private func extractBulletSection(_ heading: String, from markdown: String?) -> [String] {
        guard let section = extractSection(named: heading, from: markdown) else { return [] }
        return section
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
    }

    private func extractSection(named heading: String, from markdown: String?) -> String? {
        guard let markdown else { return nil }
        let lines = markdown.components(separatedBy: "\n")
        var captured: [String] = []
        var isInSection = false

        for line in lines {
            if line == "## \(heading)" {
                isInSection = true
                continue
            }

            if isInSection && line.hasPrefix("## ") {
                break
            }

            if isInSection {
                captured.append(line)
            }
        }

        let section = captured.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
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

    private func slug(for value: String) -> String {
        let lowered = value.lowercased()
        let allowed = lowered.map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return "-"
        }
        let collapsed = String(allowed)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "draft" : collapsed
    }

    private func safeActionKey(_ action: KnowledgeSafeAction) -> String {
        let targetId = action.target?.id ?? "-"
        return "\(action.kind)-\(action.source.id)-\(targetId)"
    }
}
