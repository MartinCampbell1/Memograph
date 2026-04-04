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
            case .high: return "Высокий"
            case .medium: return "Средний"
            case .low: return "Низкий"
            }
        }

        var sectionTitle: String {
            switch self {
            case .high: return "Высокий приоритет"
            case .medium: return "Обычное ревью"
            case .low: return "Низкосигнальное ревью"
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
            return "Доска"
        case .reviewDraft:
            return "Ревью"
        case .reviewIndex:
            return "Доска"
        case .applyReadyLesson:
            return "Применить"
        case .applyReadyLessonRedirect, .applyReadyRedirect:
            return "Редирект"
        case .applyReadyMergePatch:
            return "Слияние"
        case .applyIndex:
            return "Доска"
        }
    }

    var linkLabel: String {
        switch self {
        case .workflowIndex:
            return "центр управления"
        case .reviewDraft:
            return "черновик ревью"
        case .reviewIndex:
            return "доска ревью"
        case .applyReadyLesson:
            return "готовый черновик вывода"
        case .applyReadyLessonRedirect, .applyReadyRedirect:
            return "редирект"
        case .applyReadyMergePatch:
            return "патч слияния"
        case .applyIndex:
            return "доска применения"
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

        var markdown = "# Memograph Обслуживание слоя знаний\n\n"
        markdown += "_Обновлено: \(dateSupport.localDateTimeString(from: Date()))_\n\n"

        markdown += "## Снимок\n"
        markdown += "- Материализованных сущностей: \(entities.count)\n"
        markdown += "- Материализованных заметок: \(entities.count)\n"
        markdown += "- Просканировано ребер связей: \(edgeRows.count)\n"
        markdown += "- Часовой пояс: \(dateSupport.timeZone.identifier)\n\n"

        let typeCounts = Dictionary(grouping: entities, by: \.entityType)
        markdown += "## Распределение по типам\n"
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

        markdown += "## Дашборд\n"
        if !topHotspotNames.isEmpty {
            markdown += "- Самые сильные кластеры сейчас: \(joinNaturalLanguage(topHotspotNames))\n"
        }
        markdown += "- [[\(workflowIndexArtifact.linkTarget)|центр управления]]\n"
        markdown += "- Готовых безопасных действий: \(safeActions.count)\n"
        markdown += "- Кандидатов на ручное ревью: \(manualReviewItems.count)\n"
        markdown += "- Элементов в очереди ревью: \(reviewItemCount)\n"
        markdown += "- Высокоприоритетных элементов ревью: \(highPriorityReviewCount)\n"
        markdown += "- Обычных элементов ревью: \(standardPriorityReviewCount)\n"
        markdown += "- Низкосигнальных элементов ревью: \(lowSignalReviewCount)\n"
        markdown += "- Подавлено слабых товарных тем: \(commodityWeakTopics.count)\n\n"
        if !appliedActions.isEmpty {
            markdown += "- Отслеживаемых примененных действий: \(appliedActions.count)\n\n"
        }
        if !reviewDecisions.isEmpty {
            markdown += "- Отслеживаемых решений ревью: \(reviewDecisions.count)\n\n"
        }

        markdown += "## Следующие действия\n"
        if safeActions.isEmpty && manualReviewItems.isEmpty {
            markdown += "- Сейчас нет немедленной очереди действий.\n\n"
        } else {
            if !safeActions.isEmpty {
                markdown += "### Безопасно применить\n"
                for action in safeActions.prefix(3) {
                    switch action.kind {
                    case .promoteToLessonDraft:
                        markdown += "- Перенести [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]] в `Lessons`.\n"
                    case .consolidateIntoRoot:
                        guard let target = action.target else { continue }
                        markdown += "- Сконсолидировать [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]] в [[\(linkTarget(for: target))|\(target.canonicalName)]].\n"
                    }
                }
                markdown += "\n"
            }

            if !manualReviewItems.isEmpty {
                let actionableReviewItems = manualReviewItems.filter { $0.priority != .low }
                markdown += "### Требует ревью\n"
                if let reviewIndexArtifact {
                    markdown += "- [[\(reviewIndexArtifact.linkTarget)|доска ревью]]\n"
                }
                for item in actionableReviewItems.prefix(5) {
                    let reviewLink = manualReviewArtifactsByKey[item.artifactKey]?
                        .first(where: { $0.kind == .reviewDraft })
                        .map { " • [[\($0.linkTarget)|ревью]]" }
                        ?? ""
                    markdown += "- [\(item.priority.badge)] \(item.markdownLine)\(reviewLink)\n"
                }
                if lowSignalReviewCount > 0 {
                    markdown += "- В низкосигнальное ревью отложено \(counted(lowSignalReviewCount, one: "пакет", few: "пакета", many: "пакетов")). Они остаются на доске ревью.\n"
                }
                markdown += "\n"
            }
        }

        markdown += "## Очередь ревью\n"
        if autoDemotedLessons.isEmpty && filteredWeakTopics.isEmpty && filteredActionableAutoDemotedTopics.isEmpty && commodityWeakTopics.isEmpty {
            markdown += "- Сейчас нет срочных флагов обслуживания слоя знаний.\n\n"
        } else {
            if !autoDemotedLessons.isEmpty {
                markdown += "### Автоматически пониженные широкие выводы\n"
                for metric in autoDemotedLessons.prefix(8) {
                    markdown += "- `\(metric.entity.canonicalName)`"
                    markdown += " — слишком широкий вывод: связан с \(counted(metric.projectRelationCount, one: "проектом", few: "проектами", many: "проектами"))"
                    markdown += " через \(counted(metric.claimCount, one: "утверждение", few: "утверждения", many: "утверждений"))"
                    markdown += "\n"
                }
                markdown += "\n"
            }

            if !filteredActionableAutoDemotedTopics.isEmpty {
                markdown += "### Автоматически пониженные слабые темы\n"
                for metric in filteredActionableAutoDemotedTopics.prefix(8) {
                    markdown += "- `\(metric.entity.canonicalName)`"
                    markdown += " — слабая тема: \(counted(metric.coOccurrenceEdgeCount, one: "слабой связью", few: "слабыми связями", many: "слабыми связями"))"
                    markdown += ", только \(counted(metric.typedEdgeCount, one: "сильная связь", few: "сильные связи", many: "сильных связей"))"
                    markdown += "\n"
                }
                markdown += "\n"
            }

            if !commodityWeakTopics.isEmpty {
                let examples = commodityWeakTopics.prefix(4).map(\.entity.canonicalName).joined(separator: ", ")
                markdown += "- Подавленные слабые товарные темы: \(commodityWeakTopics.count)"
                if !examples.isEmpty {
                    markdown += " (\(examples))"
                }
                markdown += "\n\n"
            }

            if !filteredWeakTopics.isEmpty {
                markdown += "### Слабые, но устойчивые темы\n"
                for hotspot in filteredWeakTopics.prefix(8) {
                    markdown += "- [[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]]"
                    markdown += " — устойчивая, но пока с тонкой поддержкой: \(counted(hotspot.relationStats.coOccurrenceEdges, one: "слабая связь", few: "слабые связи", many: "слабых связей"))"
                    markdown += ", только \(counted(hotspot.relationStats.typedEdges, one: "сильная связь", few: "сильные связи", many: "сильных связей"))"
                    markdown += "\n"
                }
                markdown += "\n"
            }
        }

        markdown += "## Safe Auto-Actions\n"
        if safeActions.isEmpty {
            markdown += "- Сейчас нет auto-action с высоким уровнем уверенности.\n\n"
        } else {
            let lessonPromotions = safeActions.filter { $0.kind == .promoteToLessonDraft }
            let consolidations = safeActions.filter { $0.kind == .consolidateIntoRoot }
            if let applyIndexArtifact {
                markdown += "- [[\(applyIndexArtifact.linkTarget)|\(applyIndexArtifact.kind.linkLabel)]]\n\n"
            }

            if !lessonPromotions.isEmpty {
                markdown += "### Черновики повышения в Lessons\n"
                for action in lessonPromotions.prefix(6) {
                    markdown += "- [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]]"
                    markdown += " — повысить в раздел `\(KnowledgeEntityType.lesson.folderName)`: \(action.reason)\n"
                    for artifact in draftArtifactsByKey[safeActionKey(action)] ?? [] {
                        markdown += "  \(artifact.kind.lineLabel): [[\(artifact.linkTarget)|\(artifact.kind.linkLabel)]]\n"
                    }
                }
                markdown += "\n"
            }

            if !consolidations.isEmpty {
                markdown += "### Безопасные консолидации\n"
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

        markdown += "## Кандидаты на улучшение\n"
        if filteredReclassifyCandidates.isEmpty && filteredConsolidationCandidates.isEmpty && filteredStaleCandidates.isEmpty {
            markdown += "- Сейчас нет кандидатов на слияние, переклассификацию или устаревание для ревью.\n\n"
        } else {
            if !filteredReclassifyCandidates.isEmpty {
                markdown += "### Кандидаты на переклассификацию\n"
                for candidate in filteredReclassifyCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"
                    markdown += " — стоит перенести в \(candidate.targetType.folderName): \(candidate.reason)\n"
                    if let reviewArtifact = manualReviewArtifactsByKey[manualReviewKey(for: candidate)]?
                        .first(where: { $0.kind == .reviewDraft }) {
                        markdown += "  Ревью: [[\(reviewArtifact.linkTarget)|черновик ревью]]\n"
                    }
                }
                markdown += "\n"
            }

            if !filteredConsolidationCandidates.isEmpty {
                markdown += "### Кандидаты на консолидацию\n"
                for candidate in filteredConsolidationCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.source))|\(candidate.source.canonicalName)]]"
                    markdown += " → [[\(linkTarget(for: candidate.target))|\(candidate.target.canonicalName)]]"
                    markdown += " — \(candidate.reason)\n"
                    if let reviewArtifact = manualReviewArtifactsByKey[manualReviewKey(for: candidate)]?
                        .first(where: { $0.kind == .reviewDraft }) {
                        markdown += "  Ревью: [[\(reviewArtifact.linkTarget)|черновик ревью]]\n"
                    }
                }
                markdown += "\n"
            }

            if !filteredStaleCandidates.isEmpty {
                markdown += "### Кандидаты на ревью устаревания\n"
                for candidate in filteredStaleCandidates.prefix(6) {
                    markdown += "- [[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"
                    markdown += " — последний раз замечено \(counted(candidate.daysSinceSeen, one: "день", few: "дня", many: "дней")) назад; \(candidate.reason)\n"
                    if let reviewArtifact = manualReviewArtifactsByKey[manualReviewKey(for: candidate)]?
                        .first(where: { $0.kind == .reviewDraft }) {
                        markdown += "  Ревью: [[\(reviewArtifact.linkTarget)|черновик ревью]]\n"
                    }
                }
                markdown += "\n"
            }
        }

        markdown += "## Недавно применено\n"
        if appliedActions.isEmpty {
            markdown += "- Пока нет примененных KB-action в истории.\n\n"
        } else {
            for action in appliedActions
                .sorted(by: compareAppliedActions)
                .prefix(8) {
                markdown += "- \(formattedAppliedAction(action))\n"
                if let backupPath = action.backupPath, !backupPath.isEmpty {
                    markdown += "  Бэкап: `\(backupPath)`\n"
                }
            }
            markdown += "\n"
        }

        markdown += "## Недавно отревьюено\n"
        let sortedReviewDecisions = reviewDecisions.sorted(by: compareReviewDecisions)
        if sortedReviewDecisions.isEmpty {
            markdown += "- Пока нет решений ревью со статусом не-pending.\n\n"
        } else {
            markdown += "- [[Knowledge/_reviewed|история ревью]]\n"
            markdown += "- [[Knowledge/_drafts/ReviewResolved/_index|доска завершенных ревью]]\n"
            for decision in sortedReviewDecisions.prefix(8) {
                markdown += "- \(formattedReviewDecision(decision))\n"
            }
            markdown += "\n"
        }

        markdown += "## Горячие точки\n"
        for hotspot in sortedHotspots.prefix(10) {
            markdown += "- [[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]]"
            markdown += " — сейчас это самый сильный кластер: \(counted(hotspot.claimCount, one: "утверждение", few: "утверждения", many: "утверждений")), \(counted(hotspot.relationStats.typedEdges, one: "сильная связь", few: "сильные связи", many: "сильных связей")), \(counted(hotspot.relationStats.coOccurrenceEdges, one: "слабая связь", few: "слабые связи", many: "слабых связей"))\n"
        }
        markdown += "\n"

        markdown += "## Правила обслуживания\n"
        markdown += "- Автоматически пониженные широкие выводы: слишком общие выводы, связанные с 3+ проектами при слабом прямом подтверждении, убираются из материализованного графа.\n"
        markdown += "- Автоматически пониженные слабые темы: неустойчивые темы с тяжелым шумом совместной встречаемости и слабыми типизированными связями убираются из материализованного графа.\n"
        markdown += "- Слабые устойчивые темы: такие темы остаются видимыми, но низкое покрытие типизированных связей означает, что извлечение связей еще нужно улучшать.\n"
        markdown += "- Горячие точки: сущности с самым высоким совокупным давлением утверждений и связей.\n"

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
            return "\(parts[0]) и \(parts[1])"
        default:
            let head = parts.dropLast().joined(separator: ", ")
            return "\(head) и \(parts.last!)"
        }
    }

    private func counted(_ count: Int, one: String, few: String, many: String) -> String {
        "\(count) \(pluralized(count, one: one, few: few, many: many))"
    }

    private func pluralized(_ count: Int, one: String, few: String, many: String) -> String {
        let remainder100 = count % 100
        let remainder10 = count % 10
        if remainder100 >= 11 && remainder100 <= 14 {
            return many
        }
        switch remainder10 {
        case 1:
            return one
        case 2...4:
            return few
        default:
            return many
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
            return "`\(timestamp)` — [[\(linkTarget)|\(action.title)]] повышено в основное дерево знаний"
        case .lessonRedirect:
            return "`\(timestamp)` — применен редирект на вывод для [[\(linkTarget)|\(action.title)]]"
        case .redirect:
            return "`\(timestamp)` — применен редирект консолидации для [[\(linkTarget)|\(action.title)]]"
        case .mergeOverlay:
            if let targetTitle = action.targetTitle {
                return "`\(timestamp)` — объединен контекст из `\(action.title)` в [[\(linkTarget)|\(targetTitle)]]"
            }
            return "`\(timestamp)` — объединен контекст в [[\(linkTarget)|\(action.title)]]"
        case .suppression:
            return "`\(timestamp)` — [[\(linkTarget)|\(action.title)]] подавлено в активном графе знаний"
        }
    }

    private func formattedReviewDecision(_ decision: KnowledgeReviewDecisionRecord) -> String {
        let timestamp = decision.recordedAt.flatMap(dateSupport.parseDateTime)
            .map(dateSupport.localDateTimeString(from:))
            ?? decision.recordedAt
            ?? "неизвестное время"
        let draftLink = reviewDecisionLinkTarget(for: decision)
        switch decision.status {
        case .apply:
            return "`\(timestamp)` — одобрено [[\(draftLink)|\(decision.title)]]"
        case .dismiss:
            return "`\(timestamp)` — отклонено [[\(draftLink)|\(decision.title)]]"
        case .pending:
            return "`\(timestamp)` — ожидает решения [[\(draftLink)|\(decision.title)]]"
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
                    reason: "заметка почти не поддерживается и уже не имеет активного следа по проектам"
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
                reason: "высокоуверенная заметка, которая уже ведет себя как устойчивый вывод",
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
                reason: "сильная корневая заметка уже доминирует в этом семействе тем",
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
                markdownLine: "[[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]] → стоит перенести в \(candidate.targetType.folderName.lowercased())",
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
                markdownLine: "`\(metric.entity.canonicalName)` — слабая тема: \(metric.coOccurrenceEdgeCount) рыхлых связей и только \(metric.typedEdgeCount) сильн\(metric.typedEdgeCount == 1 ? "ая связь" : metric.typedEdgeCount < 5 ? "ые связи" : "ых связей")",
                score: metric.coOccurrenceEdgeCount * 2 - metric.typedEdgeCount,
                priority: .low,
                artifactKey: manualReviewKey(forWeakTopic: metric.entity)
            )
        }

        let weakDurableItems = weakTopics.map { hotspot in
            KnowledgeManualReviewItem(
                kind: .weakTopic,
                title: hotspot.entity.canonicalName,
                markdownLine: "[[\(linkTarget(for: hotspot.entity))|\(hotspot.entity.canonicalName)]] — устойчивая, но пока тонко поддержанная тема",
                score: hotspot.relationStats.coOccurrenceEdges + hotspot.relationStats.projectRelations * 4,
                priority: hotspot.relationStats.projectRelations > 0 ? .medium : .low,
                artifactKey: manualReviewKey(forWeakTopic: hotspot.entity)
            )
        }

        let staleItems = staleCandidates.map { candidate in
            KnowledgeManualReviewItem(
                kind: .stale,
                title: candidate.entity.canonicalName,
                markdownLine: "[[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]] — не обновлялась уже \(counted(candidate.daysSinceSeen, one: "день", few: "дня", many: "дней"))",
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
        # Черновик повышения в Lesson — \(action.source.canonicalName)

        ## Кандидат
        - Исходная заметка: \(sourceLink)
        - Предлагаемое место назначения: [[Knowledge/Lessons/\(destinationSlug)|\(action.source.canonicalName)]]
        - Причина: \(action.reason)

        ## Предлагаемый Lesson Stub
        ```md
        # \(action.source.canonicalName)

        _Тип: вывод_

        ## Черновая сводка
        - Повышено из \(sourceLink), потому что эта заметка ведет себя как устойчивое руководство, а не как отдельная узкая тема.

        ## Исходный материал
        - \(sourceLink)
        ```

        ## Чеклист ревью
        - Оставь исходную заметку темы как алиас или короткий редирект, если на нее уже смотрят существующие ссылки.
        - Перенеси переиспользуемое знание в заметку вывода до удаления или понижения исходной заметки темы.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Черновик повышения в Lesson — \(action.source.canonicalName)",
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
            ?? "Повышено из \(sourceLink), потому что эта заметка теперь ведет себя как устойчивое руководство, а не как рыхлая отдельная тема."
        let signalLines = extractBulletSection("Ключевые сигналы", from: sourceNote?.bodyMarkdown).prefix(4)
        let relationshipLines = extractBulletSection("Связи", from: sourceNote?.bodyMarkdown).prefix(4)
        let aliases = aliases(for: action.source)

        var draft = "# \(action.source.canonicalName)\n\n"
        draft += "_Готовый черновик вывода, сгенерированный из безопасного действия обслуживания._\n\n"
        draft += "## Черновая сводка\n"
        draft += "\(overview)\n\n"
        draft += "## Сконденсированное руководство\n"
        if signalLines.isEmpty {
            draft += "- Переформулируй эту заметку как переиспользуемое руководство, а не как узкий фрагмент темы.\n"
            draft += "- Оставь объяснение достаточно компактным, чтобы оно жило и вне исходного hourly window.\n"
        } else {
            for line in signalLines {
                draft += "\(line)\n"
            }
        }
        draft += "\n## Связанный контекст\n"
        if relationshipLines.isEmpty {
            draft += "- Исходная заметка: \(sourceLink)\n"
            draft += "- Предлагаемое финальное место: \(destinationLink)\n"
        } else {
            for line in relationshipLines {
                draft += "\(line)\n"
            }
        }
        draft += "\n## Источник\n"
        draft += "- Повышено из: \(sourceLink)\n"
        draft += "- Предлагаемое финальное место: \(destinationLink)\n"
        draft += "- Причина повышения: \(action.reason)\n"
        if !aliases.isEmpty {
            draft += "- Сохранить алиасы: \(joinNaturalLanguage(aliases))\n"
        }
        draft += "\n## Чеклист ревью\n"
        draft += "- Сожми сводку в устойчивое руководство до переноса этой заметки в `Knowledge/Lessons`.\n"
        draft += "- Оставь короткий редирект или алиас-заметку, если существующие ссылки уже смотрят в заметку темы.\n"
        draft += "- Перетащи уникальные связи, которых еще нет в целевом выводе.\n"

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
        draft += "_Редирект, сгенерированный из безопасного действия повышения в вывод._\n\n"
        draft += "Эта тема теперь указывает на \(destinationLink).\n\n"
        draft += "## Предлагаемый текст редиректа\n"
        draft += "Для устойчивого знания используй \(destinationLink).\n\n"
        draft += "## След алиасов\n"
        draft += "- \(action.source.canonicalName)\n"
        for alias in aliases.prefix(6) {
            draft += "- \(alias)\n"
        }
        draft += "\n## Чеклист ревью\n"
        draft += "- Держи этот редирект, пока обратные ссылки не перестанут зависеть от \(sourceLink).\n"
        draft += "- Сохрани старые алиасы в целевой заметке вывода.\n"
        draft += "- Удаляй отдельную тему только после того, как заметка вывода полностью заберет переиспользуемое знание.\n"

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
        # Черновик консолидации — \(action.source.canonicalName) → \(target.canonicalName)

        ## Кандидат
        - Исходная заметка: \(sourceLink)
        - Целевая заметка: \(targetLink)
        - Причина: \(action.reason)

        ## Предлагаемый редирект / алиас-заметка
        ```md
        # \(action.source.canonicalName)

        _Кандидат на редирект_

        Эта заметка, скорее всего, должна жить внутри \(targetLink).

        ## След алиасов
        - \(action.source.canonicalName)
        ```

        ## Чеклист слияния
        - Перенеси любые уникальные утверждения из \(sourceLink) в \(targetLink).
        - Сохрани \(action.source.canonicalName) как алиас, если на нее еще смотрят существующие ссылки.
        - Заменяй или редиректь слабую отдельную заметку только после того, как корневая заметка заберет недостающий контекст.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Черновик консолидации — \(action.source.canonicalName) → \(target.canonicalName)",
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
        let signalLines = extractBulletSection("Ключевые сигналы", from: sourceNote?.bodyMarkdown).prefix(4)
        let aliases = aliases(for: action.source)

        var draft = "# \(action.source.canonicalName)\n\n"
        draft += "_Редирект, сгенерированный из безопасного действия консолидации._\n\n"
        draft += "Эта заметка, скорее всего, должна сложиться в \(targetLink).\n\n"
        draft += "## Предлагаемый текст редиректа\n"
        draft += "Этот кусок работы лучше считать частью \(targetLink). Перед заменой отдельной заметки просмотри уникальный контекст ниже.\n\n"
        draft += "## Уникальный контекст, который надо сохранить\n"
        if !signalLines.isEmpty {
            for line in signalLines {
                draft += "\(line)\n"
            }
        } else if let overview {
            draft += "- \(overview)\n"
        } else {
            draft += "- Исходная заметка: \(sourceLink)\n"
        }
        draft += "\n## След алиасов\n"
        draft += "- \(action.source.canonicalName)\n"
        for alias in aliases.prefix(6) {
            draft += "- \(alias)\n"
        }
        draft += "\n## Чеклист слияния\n"
        draft += "- Перенеси любые уникальные сигналы из \(sourceLink) в \(targetLink).\n"
        draft += "- Сохрани \(action.source.canonicalName) как алиас в более сильной корневой заметке, если ссылки все еще ведут сюда.\n"
        draft += "- Заменяй отдельную заметку только после того, как корневая заметка заберет недостающий контекст.\n"

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
        let signalLines = extractBulletSection("Ключевые сигналы", from: sourceNote?.bodyMarkdown).prefix(5)
        let relationshipLines = extractBulletSection("Связи", from: sourceNote?.bodyMarkdown).prefix(5)
        let aliases = aliases(for: action.source)

        var draft = "# Патч слияния — \(action.source.canonicalName) → \(target.canonicalName)\n\n"
        draft += "_Готовый пакет слияния, сгенерированный из безопасного действия консолидации._\n\n"
        draft += "## Замысел слияния\n"
        draft += "Сложить \(sourceLink) в \(targetLink), сохранив уникальный контекст и алиасы.\n\n"
        draft += "## Сводка источника\n"
        if let overview {
            draft += "- \(overview)\n"
        } else {
            draft += "- Исходная заметка: \(sourceLink)\n"
        }
        draft += "\n## Сигналы, которые нужно сохранить\n"
        if signalLines.isEmpty && relationshipLines.isEmpty {
            draft += "- Кроме заголовка исходной заметки, дополнительных структурированных сигналов не найдено.\n"
        } else {
            for line in signalLines {
                draft += "\(line)\n"
            }
            for line in relationshipLines {
                draft += "\(line)\n"
            }
        }
        draft += "\n## Предлагаемые дополнения в корневую заметку\n"
        draft += "- Добавь `\(action.source.canonicalName)` в след алиасов у \(targetLink).\n"
        draft += "- Перетащи любую уникальную сводку или контекст связей из \(sourceLink) в \(targetLink).\n"
        if !aliases.isEmpty {
            draft += "- Сохрани алиасы: \(joinNaturalLanguage(aliases))\n"
        }
        draft += "\n## Чеклист ревью\n"
        draft += "- Обнови более сильную корневую заметку до замены исходной отдельной заметки.\n"
        draft += "- Держи редирект, пока обратные ссылки не перестанут зависеть от исходного заголовка.\n"
        draft += "- После слияния пересобери knowledge graph, чтобы убедиться, что более слабая заметка чисто выпала.\n"

        return KnowledgeDraftArtifact(
            kind: .applyReadyMergePatch,
            relativePath: relativePath,
            title: "Патч слияния — \(action.source.canonicalName) → \(target.canonicalName)",
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
                    + " — поднять [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]] в черновик вывода"
                    + (redirectArtifact.map { " • [[\($0.linkTarget)|редирект]]" } ?? "")
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

        var markdown = "# Доска применения изменений знаний\n\n"
        markdown += "_Готовые черновики применения, экспортированные из безопасных действий обслуживания._\n\n"
        markdown += "- [[Knowledge/_drafts/_index|центр управления]]\n\n"
        if !lessonRows.isEmpty {
            markdown += "## Повышения в Lessons\n"
            markdown += lessonRows.joined(separator: "\n")
            markdown += "\n\n"
        }
        if !redirectRows.isEmpty {
            markdown += "## Редиректы\n"
            markdown += redirectRows.joined(separator: "\n")
            markdown += "\n\n"
        }
        if !mergeRows.isEmpty {
            markdown += "## Патчи слияния\n"
            markdown += mergeRows.joined(separator: "\n")
            markdown += "\n\n"
        }
        markdown += "## Как использовать\n"
        markdown += "- Просмотри готовый черновик применения до переноса в основное дерево `Knowledge/*`.\n"
        markdown += "- Держи рядом парный черновик ревью, если нужен контекст решения и migration checklist.\n"
        markdown += "- Не заменяй основную заметку, пока не сохранены алиасы и уникальный контекст.\n"

        return KnowledgeDraftArtifact(
            kind: .applyIndex,
            relativePath: "Apply/_index.md",
            title: "Доска применения изменений знаний",
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

        var markdown = "# Доска ревью знаний\n\n"
        markdown += "_Пакеты ревью, экспортированные из текущей очереди обслуживания._\n\n"
        markdown += "- [[Knowledge/_drafts/_index|центр управления]]\n\n"
        markdown += "## Сводка по приоритетам\n"
        markdown += "- Высокий приоритет: \(highCount)\n"
        markdown += "- Обычное ревью: \(mediumCount)\n"
        markdown += "- Низкосигнальное ревью: \(lowCount)\n\n"

        for priority in [KnowledgeManualReviewItem.Priority.high, .medium, .low] {
            guard let rows = groupedRows[priority], !rows.isEmpty else { continue }
            markdown += "## \(priority.sectionTitle)\n"
            let rowLimit = priority == .low ? 6 : 10
            markdown += rows.map(\.1).prefix(rowLimit).joined(separator: "\n")
            if priority == .low && rows.count > rowLimit {
                let remaining = rows.count - rowLimit
                markdown += "\n- ...и еще \(counted(remaining, one: "низкосигнальный пакет ревью", few: "низкосигнальных пакета ревью", many: "низкосигнальных пакетов ревью"))"
            }
            markdown += "\n\n"
        }
        markdown += "## Как использовать\n"
        markdown += "- Открывай связанный черновик ревью до изменения основной заметки в `Knowledge/*`.\n"
        markdown += "- Используй эти пакеты для решений по слиянию, переклассификации, устареванию и слабым темам, которые еще недостаточно безопасны для автоприменения.\n"
        markdown += "- После применения решения кандидат должен выпасть из очереди ревью на следующем rebuild.\n"

        return KnowledgeDraftArtifact(
            kind: .reviewIndex,
            relativePath: "Review/_index.md",
            title: "Доска ревью знаний",
            markdown: markdown
        )
    }

    private func manualReviewKindLabel(for kind: KnowledgeManualReviewItem.Kind) -> String {
        switch kind {
        case .reclassify:
            return "Переклассификация"
        case .consolidate:
            return "Консолидация"
        case .weakTopic:
            return "Слабая тема"
        case .stale:
            return "Устаревшее"
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
        var markdown = "# Центр управления слоем знаний\n\n"
        markdown += "_Операционный хаб для активных, примененных и завершенных действий слоя знаний._\n\n"
        markdown += "## Дашборд\n"
        markdown += "- [[Knowledge/_maintenance|дашборд обслуживания]]\n"
        markdown += "- Безопасно применить: \(safeActions.count)\n"
        markdown += "- Требует ревью: \(manualReviewItems.count)\n"
        markdown += "- Обычное ревью: \(manualReviewItems.filter { $0.priority != .low }.count)\n"
        markdown += "- Низкосигнальное ревью: \(manualReviewItems.filter { $0.priority == .low }.count)\n"
        markdown += "- Недавно применено: \(appliedActions.count)\n"
        markdown += "- Недавно отревьюено: \(reviewDecisions.count)\n\n"

        let actionableReviewItems = manualReviewItems.filter { $0.priority != .low }
        let lowSignalReviewCount = manualReviewItems.count - actionableReviewItems.count
        markdown += "## Рекомендуемые следующие шаги\n"
        if safeActions.isEmpty && actionableReviewItems.isEmpty {
            markdown += "- Сейчас нет немедленной очереди действий.\n"
        } else {
            for action in safeActions.prefix(3) {
                switch action.kind {
                case .promoteToLessonDraft:
                    markdown += "- Применить: перенести [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]] в `Lessons`.\n"
                case .consolidateIntoRoot:
                    guard let target = action.target else { continue }
                    markdown += "- Применить: сконсолидировать [[\(linkTarget(for: action.source))|\(action.source.canonicalName)]] в [[\(linkTarget(for: target))|\(target.canonicalName)]].\n"
                }
            }
            for item in actionableReviewItems.prefix(3) {
                markdown += "- Ревью [\(item.priority.badge)]: \(item.markdownLine)\n"
            }
            if lowSignalReviewCount > 0 {
                markdown += "- Отложить: \(counted(lowSignalReviewCount, one: "низкосигнальный пакет ревью", few: "низкосигнальных пакета ревью", many: "низкосигнальных пакетов ревью")) остаются на доске ревью.\n"
            }
        }
        markdown += "\n"

        markdown += "## Активные очереди\n"
        if let applyIndexArtifact {
            markdown += "- [[\(applyIndexArtifact.linkTarget)|доска применения]]\n"
        } else {
            markdown += "- Сейчас нет готовых пакетов применения.\n"
        }
        if let reviewIndexArtifact {
            markdown += "- [[\(reviewIndexArtifact.linkTarget)|доска ревью]]\n"
        } else {
            markdown += "- Сейчас нет активной очереди ревью.\n"
        }
        markdown += "\n"

        markdown += "## История и завершенные\n"
        markdown += "- [[Knowledge/_applied|история применений]]\n"
        markdown += "- [[Knowledge/_reviewed|история ревью]]\n"
        markdown += "- [[Knowledge/_drafts/ReviewResolved/_index|доска завершенных ревью]]\n\n"

        markdown += "## Как использовать\n"
        markdown += "- Начинай отсюда, если хочешь пройтись по безопасным действиям, пакетам ревью и архиву решений без ручного открытия папок.\n"
        markdown += "- Используй доску применения для высокоуверенных пакетов, доску ревью для ручных решений, а доску завершенных ревью — чтобы пересматривать закрытые решения.\n"

        return KnowledgeDraftArtifact(
            kind: .workflowIndex,
            relativePath: "_index.md",
            title: "Центр управления слоем знаний",
            markdown: markdown
        )
    }

    private func buildReclassifyReviewDraft(for candidate: KnowledgeReclassifyCandidate) throws -> KnowledgeDraftArtifact {
        let note = try loadKnowledgeNote(for: candidate.entity)
        let overview = extractOverview(from: note?.bodyMarkdown)
        let keySignals = extractBulletSection("Ключевые сигналы", from: note?.bodyMarkdown).prefix(4)
        let relationships = extractBulletSection("Связи", from: note?.bodyMarkdown).prefix(4)
        let relativePath = "Review/reclassify-\(candidate.entity.slug).md"
        let sourceLink = "[[\(linkTarget(for: candidate.entity))|\(candidate.entity.canonicalName)]]"
        let targetFolder = candidate.targetType.folderName
        let destinationLink = "[[Knowledge/\(targetFolder)/\(candidate.entity.slug)|\(candidate.entity.canonicalName)]]"

        var markdown = """
        <!-- memograph-review-key: \(manualReviewKey(for: candidate)) -->
        <!-- memograph-review-kind: \(KnowledgeReviewDecisionKind.promoteToLesson.rawValue) -->
        # Пакет ревью — Переклассификация \(candidate.entity.canonicalName)

        """
        markdown += "## Кандидат\n"
        markdown += "- Исходная заметка: \(sourceLink)\n"
        markdown += "- Предлагаемое место: \(destinationLink)\n"
        markdown += "- Причина: \(candidate.reason)\n\n"
        markdown += "## Решение\n"
        markdown += "- Замени `Decision: pending` на `Decision: apply`, когда это ревью будет одобрено.\n"
        markdown += "- Используй `Decision: dismiss`, если заметка должна остаться как есть.\n"
        markdown += "Decision: pending\n\n"
        markdown += "## Текущее чтение\n"
        if let overview {
            markdown += "- \(overview)\n"
        } else {
            markdown += "- В текущей заметке не нашлось блока обзора.\n"
        }
        markdown += "\n## Сигналы, которые нужно сохранить\n"
        if keySignals.isEmpty && relationships.isEmpty {
            markdown += "- Просмотри исходную заметку вручную: структурированных сигналов не нашлось.\n"
        } else {
            for line in keySignals { markdown += "\(line)\n" }
            for line in relationships { markdown += "\(line)\n" }
        }
        markdown += "\n## Чеклист ревью\n"
        markdown += "- Подтверди, что заметка больше похожа на устойчивое руководство, чем на отдельную тему.\n"
        markdown += "- Сохрани алиасы и обратные ссылки, если переносишь ее в `\(targetFolder)`.\n"
        markdown += "- Сохрани уникальные связи с проектами и темами до смены типа заметки.\n"

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Пакет ревью — Переклассификация \(candidate.entity.canonicalName)",
            markdown: markdown,
            reviewPacketKey: manualReviewKey(for: candidate),
            reviewDecisionKind: .promoteToLesson
        )
    }

    private func buildManualConsolidationReviewDraft(for candidate: KnowledgeConsolidationCandidate) throws -> KnowledgeDraftArtifact {
        let sourceNote = try loadKnowledgeNote(for: candidate.source)
        let sourceOverview = extractOverview(from: sourceNote?.bodyMarkdown)
        let sourceSignals = extractBulletSection("Ключевые сигналы", from: sourceNote?.bodyMarkdown).prefix(4)
        let relativePath = "Review/consolidate-\(candidate.source.slug)-into-\(candidate.target.slug).md"
        let sourceLink = "[[\(linkTarget(for: candidate.source))|\(candidate.source.canonicalName)]]"
        let targetLink = "[[\(linkTarget(for: candidate.target))|\(candidate.target.canonicalName)]]"

        var markdown = """
        <!-- memograph-review-key: \(manualReviewKey(for: candidate)) -->
        <!-- memograph-review-kind: \(KnowledgeReviewDecisionKind.consolidate.rawValue) -->
        # Пакет ревью — Консолидация \(candidate.source.canonicalName)

        """
        markdown += "## Кандидат\n"
        markdown += "- Исходная заметка: \(sourceLink)\n"
        markdown += "- Целевая заметка: \(targetLink)\n"
        markdown += "- Причина: \(candidate.reason)\n\n"
        markdown += "## Решение\n"
        markdown += "- Замени `Decision: pending` на `Decision: apply`, когда это слияние будет одобрено.\n"
        markdown += "- Используй `Decision: dismiss`, если исходная заметка должна остаться отдельной.\n"
        markdown += "Decision: pending\n\n"
        markdown += "## Контекст источника\n"
        if let sourceOverview {
            markdown += "- \(sourceOverview)\n"
        } else {
            markdown += "- В текущей исходной заметке не нашлось блока обзора.\n"
        }
        markdown += "\n## Сигналы, которые нужно сохранить\n"
        if sourceSignals.isEmpty {
            markdown += "- Перед слиянием просмотри исходную заметку вручную.\n"
        } else {
            for line in sourceSignals { markdown += "\(line)\n" }
        }
        markdown += "\n## Чеклист ревью\n"
        markdown += "- Подтверди, что целевая заметка действительно более сильный root для этого семейства тем.\n"
        markdown += "- Сохрани уникальные алиасы и контекст до редиректа исходной заметки.\n"
        markdown += "- Если источник все еще несет уникальный смысл, оставь его отдельно и отклони консолидацию.\n"

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Пакет ревью — Консолидация \(candidate.source.canonicalName)",
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
        # Пакет ревью — Устаревшая заметка \(candidate.entity.canonicalName)

        ## Кандидат
        - Заметка: \(sourceLink)
        - Последний раз замечена \(counted(candidate.daysSinceSeen, one: "день", few: "дня", many: "дней")) назад
        - Причина: \(candidate.reason)

        ## Решение
        - Замени `Decision: pending` на `Decision: apply`, чтобы подавить эту заметку в активном графе знаний.
        - Используй `Decision: dismiss`, если заметка должна остаться видимой.
        Decision: pending

        ## Чеклист ревью
        - Оставь ее, если она все еще служит устойчивым справочным материалом.
        - Слей или заредиректь ее, если более сильная корневая заметка уже покрывает ту же идею.
        - Архивируй или подави ее, если у нее больше нет активного следа по проектам.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Пакет ревью — Устаревшая заметка \(candidate.entity.canonicalName)",
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
        # Пакет ревью — Слабая тема \(metric.entity.canonicalName)

        ## Кандидат
        - Тема: \(sourceLink)
        - Слабые связи: \(metric.coOccurrenceEdgeCount)
        - Сильные связи: \(metric.typedEdgeCount)

        ## Решение
        - Замени `Decision: pending` на `Decision: apply`, чтобы подавить эту заметку в активном графе знаний.
        - Используй `Decision: dismiss`, если тема должна остаться видимой.
        Decision: pending

        ## Чеклист ревью
        - Оставляй ее только если она несет устойчивый смысл сверх шума совместной встречаемости.
        - Сконсолидируй ее в более сильную корневую тему, если это просто узкий вариант.
        - Переклассифицируй ее, если по смыслу это руководство, рабочий процесс или вывод.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Пакет ревью — Слабая тема \(metric.entity.canonicalName)",
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
        # Пакет ревью — Тонкая устойчивая тема \(hotspot.entity.canonicalName)

        ## Кандидат
        - Тема: \(sourceLink)
        - Сильные связи: \(hotspot.relationStats.typedEdges)
        - Слабые связи: \(hotspot.relationStats.coOccurrenceEdges)
        - Связей с проектами: \(hotspot.relationStats.projectRelations)

        ## Решение
        - Замени `Decision: pending` на `Decision: apply`, чтобы подавить эту заметку в активном графе знаний.
        - Используй `Decision: dismiss`, если тема должна остаться видимой.
        Decision: pending

        ## Чеклист ревью
        - Оставь ее видимой, если это реальная устойчивая тема, которую граф должен показывать.
        - Улучши типизированные связи или слей ее в более сильную тему, если заметка остается слишком тонкой.
        - Переклассифицируй ее, если заголовок и контекст больше похожи на lesson, чем на тему.
        """

        return KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: relativePath,
            title: "Пакет ревью — Тонкая устойчивая тема \(hotspot.entity.canonicalName)",
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
        return "тема больше похожа на устойчивое руководство или заметку о рабочем процессе"
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

        return "темы перекрываются; стоит консолидировать под более сильной корневой заметкой"
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
        guard let section = extractSection(named: "Обзор", from: markdown) else { return nil }
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
        let variants = localizedSectionHeadingVariants(for: heading)

        for line in lines {
            if variants.contains(line) {
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

    private func localizedSectionHeadingVariants(for heading: String) -> Set<String> {
        let normalized = heading.trimmingCharacters(in: .whitespacesAndNewlines)
        let variants: [String]
        switch normalized.lowercased() {
        case "overview", "обзор":
            variants = ["## Overview", "## Обзор"]
        case "key signals", "ключевые сигналы":
            variants = ["## Key Signals", "## Ключевые сигналы"]
        case "relationships", "связи":
            variants = ["## Relationships", "## Связи"]
        default:
            variants = ["## \(normalized)"]
        }
        return Set(variants)
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
