import Foundation

final class ThreadMaintenanceEngine {
    private let db: DatabaseManager
    private let store: AdvisoryArtifactStore
    private let dateSupport: LocalDateSupport

    init(
        db: DatabaseManager,
        store: AdvisoryArtifactStore,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.db = db
        self.store = store
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    @discardableResult
    func refresh(referenceDate: String) throws -> [AdvisoryThreadRecord] {
        let threads = try store.listThreads(limit: 500)
        guard !threads.isEmpty else { return [] }

        let metricsById = try batchMetrics(for: threads, referenceDate: referenceDate)
        let parentByThreadId = inferParents(threads: threads, metricsById: metricsById)

        for thread in threads {
            guard let metrics = metricsById[thread.id] else { continue }
            try store.updateThreadIntelligence(
                threadId: thread.id,
                status: metrics.status,
                parentThreadId: parentByThreadId[thread.id] ?? thread.parentThreadId,
                totalActiveMinutes: metrics.totalActiveMinutes,
                lastArtifactAt: metrics.lastArtifactAt,
                importanceScore: metrics.importanceScore
            )
        }

        return try store.listThreads(limit: 500)
    }

    func proposals(
        for threadId: String,
        referenceDate: String? = nil,
        limit: Int = 6
    ) throws -> [AdvisoryThreadMaintenanceProposal] {
        let threads = try store.listThreads(limit: 500)
        guard let thread = threads.first(where: { $0.id == threadId }) else { return [] }

        let resolvedDate = referenceDate ?? dateSupport.currentLocalDateString()
        let metricsById = try batchMetrics(for: threads, referenceDate: resolvedDate)
        let parentByThreadId = inferParents(threads: threads, metricsById: metricsById)
        let continuityItems = try store.continuityItemsForThread(
            threadId: threadId,
            statuses: [.open, .stabilizing, .parked],
            limit: 12
        )
        let childThreads = try store.childThreads(parentThreadId: threadId, limit: 12)
        let artifacts = try store.artifactsForThread(
            threadId,
            statuses: [.surfaced, .accepted, .queued, .candidate],
            limit: 12
        )

        let inferredMetrics = metricsById[threadId]
        var proposals: [AdvisoryThreadMaintenanceProposal] = []

        if let inferredStatus = inferredMetrics?.status,
           inferredStatus != thread.status {
            proposals.append(
                AdvisoryThreadMaintenanceProposal(
                    id: proposalId(kind: .statusChange, threadId: threadId, suffix: inferredStatus.rawValue),
                    kind: .statusChange,
                    title: statusProposalTitle(for: inferredStatus),
                    rationale: statusProposalRationale(
                        thread: thread,
                        suggestedStatus: inferredStatus,
                        continuityItems: continuityItems,
                        artifacts: artifacts,
                        referenceDate: resolvedDate
                    ),
                    confidence: min(0.92, 0.56 + abs((inferredMetrics?.importanceScore ?? thread.importanceScore) - thread.importanceScore) * 0.12 + (continuityItems.isEmpty ? 0.12 : 0.0)),
                    targetThreadId: nil,
                    targetThreadTitle: nil,
                    suggestedStatus: inferredStatus,
                    suggestedTitle: nil,
                    suggestedSummary: nil,
                    suggestedKind: nil,
                    sourceContinuityItemId: nil
                )
            )
        }

        if let suggestedParentId = parentByThreadId[threadId],
           let target = threads.first(where: { $0.id == suggestedParentId }),
           suggestedParentId != thread.parentThreadId {
            let overlap = overlapScore(child: thread, parent: target)
            let shouldMerge = shouldMerge(
                thread: thread,
                target: target,
                continuityItems: continuityItems,
                childThreads: childThreads,
                artifacts: artifacts,
                overlapScore: overlap
            )
            let kind: AdvisoryThreadMaintenanceProposalKind = shouldMerge ? .mergeIntoThread : .reparentUnderThread
            proposals.append(
                AdvisoryThreadMaintenanceProposal(
                    id: proposalId(kind: kind, threadId: threadId, suffix: target.id),
                    kind: kind,
                    title: shouldMerge ? "Склеить с «\(target.displayTitle)»" : "Подвесить под «\(target.displayTitle)»",
                    rationale: shouldMerge
                        ? "Похоже, это уже не самостоятельная нить, а узкий дубль более широкой нити «\(target.displayTitle)». Merge снизит шум в Resume Me и weekly review."
                        : "Похоже, эту нить лучше воспринимать как подпоток внутри «\(target.displayTitle)», а не как отдельный верхний thread.",
                    confidence: min(0.92, 0.54 + overlap * 0.34 + (target.userPinned ? 0.08 : 0)),
                    targetThreadId: target.id,
                    targetThreadTitle: target.displayTitle,
                    suggestedStatus: nil,
                    suggestedTitle: nil,
                    suggestedSummary: nil,
                    suggestedKind: nil,
                    sourceContinuityItemId: nil
                )
            )
        }

        if childThreads.isEmpty,
           let splitSeed = splitSeed(for: thread, continuityItems: continuityItems, artifacts: artifacts),
           shouldSuggestSplit(thread: thread, continuityItems: continuityItems, artifacts: artifacts) {
            let suggestedKind = suggestedSubthreadKind(thread: thread, seed: splitSeed)
            proposals.append(
                AdvisoryThreadMaintenanceProposal(
                    id: proposalId(kind: .splitIntoSubthread, threadId: threadId, suffix: splitSeed.id),
                    kind: .splitIntoSubthread,
                    title: "Вынести sub-thread: \(splitSeed.title)",
                    rationale: "Нить уже достаточно широкая. Похоже, «\(splitSeed.title)» стало отдельным return point, который лучше не держать внутри одной общей нити.",
                    confidence: min(0.88, 0.52 + min(1.0, Double(thread.totalActiveMinutes) / 240.0) * 0.18 + min(0.12, Double(continuityItems.count) * 0.03)),
                    targetThreadId: nil,
                    targetThreadTitle: nil,
                    suggestedStatus: nil,
                    suggestedTitle: splitSeed.title,
                    suggestedSummary: splitSeed.summary,
                    suggestedKind: suggestedKind,
                    sourceContinuityItemId: splitSeed.sourceContinuityItemId,
                )
            )
        }

        return proposals
            .sorted { lhs, rhs in
                if lhs.confidence == rhs.confidence {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhs.confidence > rhs.confidence
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    private func batchMetrics(
        for threads: [AdvisoryThreadRecord],
        referenceDate: String
    ) throws -> [String: ThreadMetrics] {
        let threadIds = threads.map(\.id)

        let allEvidence = try batchThreadEvidence(threadIds: threadIds)
        let allContinuityStats = try batchContinuityStats(threadIds: threadIds)
        let allArtifactStats = try batchArtifactStats(threadIds: threadIds)

        // Collect all session IDs across all threads
        var allSessionIds = Set<String>()
        for threadId in threadIds {
            let evidence = allEvidence[threadId] ?? []
            for ev in evidence where ev.evidenceKind == "session" && ev.evidenceRef.hasPrefix("session:") {
                allSessionIds.insert(String(ev.evidenceRef.dropFirst("session:".count)))
            }
        }
        let allSessions = try batchSessionSnapshots(ids: Array(allSessionIds))

        var result: [String: ThreadMetrics] = [:]
        for thread in threads {
            let evidence = allEvidence[thread.id] ?? []
            let sessionIds = evidence
                .filter { $0.evidenceKind == "session" && $0.evidenceRef.hasPrefix("session:") }
                .map { String($0.evidenceRef.dropFirst("session:".count)) }
            let sessions = sessionIds.compactMap { allSessions[$0] }

            let computedActiveMinutes = sessions.reduce(0) { $0 + Int($1.activeDurationMs / 60_000) }
            let evidenceKinds = Set(evidence.map(\.evidenceKind)).count
            let recurrenceDays = recurrenceDays(for: evidence, sessions: sessions)
            let cStats = allContinuityStats[thread.id] ?? (openCount: 0, totalCount: 0)
            let aStats = allArtifactStats[thread.id] ?? (engagedCount: 0, continuityArtifactCount: 0, lastArtifactAt: nil)

            let totalActiveMinutes = max(thread.totalActiveMinutes, computedActiveMinutes)
            let status = inferStatus(
                thread: thread,
                referenceDate: referenceDate,
                openContinuityCount: cStats.openCount,
                engagedArtifactCount: aStats.engagedCount
            )
            let importanceScore = inferImportance(
                thread: thread,
                status: status,
                totalActiveMinutes: totalActiveMinutes,
                evidenceKinds: evidenceKinds,
                recurrenceDays: recurrenceDays,
                engagedArtifactCount: aStats.engagedCount,
                reentryCount: aStats.continuityArtifactCount
            )

            result[thread.id] = ThreadMetrics(
                status: status,
                totalActiveMinutes: totalActiveMinutes,
                lastArtifactAt: aStats.lastArtifactAt ?? thread.lastArtifactAt,
                importanceScore: importanceScore
            )
        }
        return result
    }

    private func inferStatus(
        thread: AdvisoryThreadRecord,
        referenceDate: String,
        openContinuityCount: Int,
        engagedArtifactCount: Int
    ) -> AdvisoryThreadStatus {
        let daysSinceLastActive = daysSinceLastActive(thread.lastActiveAt, referenceDate: referenceDate)

        if thread.status == .resolved, openContinuityCount == 0, engagedArtifactCount == 0 {
            return .resolved
        }
        if openContinuityCount > 0 || daysSinceLastActive <= 2 {
            return .active
        }
        if daysSinceLastActive <= 7 {
            return .stalled
        }
        if thread.userPinned {
            return .parked
        }
        if engagedArtifactCount > 0 && daysSinceLastActive > 21 {
            return .resolved
        }
        return .parked
    }

    private func inferImportance(
        thread: AdvisoryThreadRecord,
        status: AdvisoryThreadStatus,
        totalActiveMinutes: Int,
        evidenceKinds: Int,
        recurrenceDays: Int,
        engagedArtifactCount: Int,
        reentryCount: Int
    ) -> Double {
        let activeMinutesFactor = min(1.0, Double(totalActiveMinutes) / 240.0)
        let evidenceFactor = min(1.0, Double(evidenceKinds) / 4.0)
        let recurrenceFactor = min(1.0, Double(recurrenceDays) / 5.0)
        let engagementFactor = min(1.0, Double(engagedArtifactCount) / 3.0)
        let reentryFactor = min(1.0, Double(reentryCount) / 3.0)
        let statusLift: Double
        switch status {
        case .active: statusLift = 0.08
        case .stalled: statusLift = 0.04
        case .parked, .resolved: statusLift = 0
        }

        let pinnedLift = thread.userPinned ? 0.18 : 0
        let score =
            activeMinutesFactor * 0.32
            + evidenceFactor * 0.18
            + recurrenceFactor * 0.18
            + engagementFactor * 0.14
            + reentryFactor * 0.1
            + max(0, thread.confidence) * 0.08
            + statusLift
            + pinnedLift
        return min(1.0, max(thread.importanceScore, score))
    }

    private func inferParents(
        threads: [AdvisoryThreadRecord],
        metricsById: [String: ThreadMetrics]
    ) -> [String: String] {
        let sorted = threads.sorted { lhs, rhs in
            let lhsScore = metricsById[lhs.id]?.importanceScore ?? lhs.importanceScore
            let rhsScore = metricsById[rhs.id]?.importanceScore ?? rhs.importanceScore
            if lhsScore == rhsScore {
                return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
            }
            return lhsScore > rhsScore
        }

        var result: [String: String] = [:]
        for child in sorted {
            let childTokens = tokenSet(for: child.displayTitle)
            guard childTokens.count >= 2 else { continue }

            var bestMatch: (id: String, score: Double)?
            for parent in sorted where parent.id != child.id {
                let parentTokens = tokenSet(for: parent.displayTitle)
                guard parentTokens.count >= 1, parentTokens.count < childTokens.count else { continue }

                let childScore = metricsById[child.id]?.importanceScore ?? child.importanceScore
                let parentScore = metricsById[parent.id]?.importanceScore ?? parent.importanceScore
                guard parentScore + 0.05 >= childScore || parent.userPinned else { continue }

                let overlapCount = childTokens.intersection(parentTokens).count
                let overlapRatio = Double(overlapCount) / Double(max(1, parentTokens.count))
                let slugContainment = child.slug != parent.slug && child.slug.contains(parent.slug)
                let broader = slugContainment || parentTokens.isSubset(of: childTokens)
                guard broader else { continue }

                let score = (slugContainment ? 0.42 : 0.0) + overlapRatio * 0.4 + max(0, parentScore - childScore) * 0.18
                guard score >= 0.55 else { continue }
                if let current = bestMatch, current.score >= score { continue }
                bestMatch = (parent.id, score)
            }

            if let bestMatch {
                result[child.id] = bestMatch.id
            }
        }
        return result
    }

    private func batchThreadEvidence(
        threadIds: [String]
    ) throws -> [String: [AdvisoryThreadEvidenceRecord]] {
        guard !threadIds.isEmpty else { return [:] }
        let sqlIds = threadIds.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        let rows = try db.query("""
            SELECT * FROM advisory_thread_evidence
            WHERE thread_id IN (\(sqlIds))
            ORDER BY weight DESC, created_at DESC
        """)
        var result: [String: [AdvisoryThreadEvidenceRecord]] = [:]
        for row in rows {
            guard let record = AdvisoryThreadEvidenceRecord(row: row) else { continue }
            result[record.threadId, default: []].append(record)
        }
        return result
    }

    private func batchContinuityStats(
        threadIds: [String]
    ) throws -> [String: (openCount: Int, totalCount: Int)] {
        guard !threadIds.isEmpty else { return [:] }
        let sqlIds = threadIds.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        let rows = try db.query("""
            SELECT
                thread_id,
                COUNT(*) AS total_count,
                SUM(CASE WHEN status IN ('open', 'stabilizing') THEN 1 ELSE 0 END) AS open_count
            FROM continuity_items
            WHERE thread_id IN (\(sqlIds))
            GROUP BY thread_id
        """)
        var result: [String: (openCount: Int, totalCount: Int)] = [:]
        for row in rows {
            guard let threadId = row["thread_id"]?.textValue else { continue }
            result[threadId] = (
                openCount: row["open_count"]?.intValue.flatMap(Int.init) ?? 0,
                totalCount: row["total_count"]?.intValue.flatMap(Int.init) ?? 0
            )
        }
        return result
    }

    private func batchArtifactStats(
        threadIds: [String]
    ) throws -> [String: (engagedCount: Int, continuityArtifactCount: Int, lastArtifactAt: String?)] {
        guard !threadIds.isEmpty else { return [:] }
        let sqlIds = threadIds.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        let rows = try db.query("""
            SELECT
                thread_id,
                SUM(CASE WHEN status IN ('surfaced', 'accepted') THEN 1 ELSE 0 END) AS engaged_count,
                SUM(CASE WHEN source_recipe = 'continuity_resume' THEN 1 ELSE 0 END) AS continuity_count,
                MAX(COALESCE(surfaced_at, created_at)) AS last_artifact_at
            FROM advisory_artifacts
            WHERE thread_id IN (\(sqlIds))
            GROUP BY thread_id
        """)
        var result: [String: (engagedCount: Int, continuityArtifactCount: Int, lastArtifactAt: String?)] = [:]
        for row in rows {
            guard let threadId = row["thread_id"]?.textValue else { continue }
            result[threadId] = (
                engagedCount: row["engaged_count"]?.intValue.flatMap(Int.init) ?? 0,
                continuityArtifactCount: row["continuity_count"]?.intValue.flatMap(Int.init) ?? 0,
                lastArtifactAt: row["last_artifact_at"]?.textValue
            )
        }
        return result
    }

    private func batchSessionSnapshots(
        ids: [String]
    ) throws -> [String: ThreadSessionSnapshot] {
        guard !ids.isEmpty else { return [:] }
        let sqlIds = ids.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        let rows = try db.query("""
            SELECT id, started_at, ended_at, active_duration_ms
            FROM sessions
            WHERE id IN (\(sqlIds))
        """)
        var result: [String: ThreadSessionSnapshot] = [:]
        for row in rows {
            guard let id = row["id"]?.textValue,
                  let startedAt = row["started_at"]?.textValue else {
                continue
            }
            result[id] = ThreadSessionSnapshot(
                id: id,
                startedAt: startedAt,
                endedAt: row["ended_at"]?.textValue,
                activeDurationMs: row["active_duration_ms"]?.intValue ?? 0
            )
        }
        return result
    }

    private func recurrenceDays(
        for evidence: [AdvisoryThreadEvidenceRecord],
        sessions: [ThreadSessionSnapshot]
    ) -> Int {
        let evidenceDays = evidence.compactMap { $0.createdAt.flatMap(dateSupport.localDateString(from:)) }
        let sessionDays = sessions.compactMap { $0.endedAt ?? $0.startedAt }.compactMap(dateSupport.localDateString(from:))
        return Set(evidenceDays + sessionDays).count
    }

    private func daysSinceLastActive(_ lastActiveAt: String?, referenceDate: String) -> Int {
        guard let lastActiveAt,
              let lastDate = dateSupport.parseDateTime(lastActiveAt),
              let referenceStart = dateSupport.startOfLocalDay(for: referenceDate) else {
            return 365
        }
        let lastLocalDate = dateSupport.localDateString(from: lastDate)
        guard let lastLocalStart = dateSupport.startOfLocalDay(for: lastLocalDate) else {
            return 365
        }
        return max(0, Calendar(identifier: .gregorian).dateComponents([.day], from: lastLocalStart, to: referenceStart).day ?? 365)
    }

    private func tokenSet(for title: String) -> Set<String> {
        Set(title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 })
    }

    private func proposalId(
        kind: AdvisoryThreadMaintenanceProposalKind,
        threadId: String,
        suffix: String
    ) -> String {
        AdvisorySupport.stableIdentifier(
            prefix: "advmaint",
            components: [kind.rawValue, threadId, suffix]
        )
    }

    private func overlapScore(
        child: AdvisoryThreadRecord,
        parent: AdvisoryThreadRecord
    ) -> Double {
        let childTokens = tokenSet(for: child.displayTitle)
        let parentTokens = tokenSet(for: parent.displayTitle)
        guard !childTokens.isEmpty, !parentTokens.isEmpty else { return 0 }
        let overlap = Double(childTokens.intersection(parentTokens).count) / Double(parentTokens.count)
        let slugContainment = child.slug != parent.slug && child.slug.contains(parent.slug) ? 0.3 : 0
        return min(1.0, overlap + slugContainment)
    }

    private func shouldMerge(
        thread: AdvisoryThreadRecord,
        target: AdvisoryThreadRecord,
        continuityItems: [ContinuityItemRecord],
        childThreads: [AdvisoryThreadRecord],
        artifacts: [AdvisoryArtifactRecord],
        overlapScore: Double
    ) -> Bool {
        guard childThreads.isEmpty else { return false }
        guard overlapScore >= 0.6 else { return false }
        if thread.userPinned { return false }
        if thread.status == .resolved || thread.status == .parked { return true }
        if continuityItems.count <= 1 && artifacts.count <= 2 && thread.totalActiveMinutes <= 120 {
            return true
        }
        return target.importanceScore - thread.importanceScore >= 0.16
    }

    private func statusProposalTitle(for status: AdvisoryThreadStatus) -> String {
        switch status {
        case .active: return "Вернуть в active"
        case .stalled: return "Пометить как stalled"
        case .parked: return "Припарковать thread"
        case .resolved: return "Пометить как resolved"
        }
    }

    private func statusProposalRationale(
        thread: AdvisoryThreadRecord,
        suggestedStatus: AdvisoryThreadStatus,
        continuityItems: [ContinuityItemRecord],
        artifacts: [AdvisoryArtifactRecord],
        referenceDate: String
    ) -> String {
        let days = daysSinceLastActive(thread.lastActiveAt, referenceDate: referenceDate)
        switch suggestedStatus {
        case .active:
            return "Нить снова выглядит живой: есть свежий continuity pressure или недавний re-entry."
        case .stalled:
            return "Движение по нити уже замедлилось. Последняя явная активность была \(days) дн. назад, но она ещё не выглядит завершённой."
        case .parked:
            return "Открытых loops почти не осталось, а активность остыла. Лучше тихо припарковать нить, чтобы она не шумела в ambient advisory."
        case .resolved:
            return "Нить выглядит завершённой: активность давно остыла, а уже surfaced artifacts и continuity не держат её в active состоянии."
        }
    }

    private func shouldSuggestSplit(
        thread: AdvisoryThreadRecord,
        continuityItems: [ContinuityItemRecord],
        artifacts: [AdvisoryArtifactRecord]
    ) -> Bool {
        thread.totalActiveMinutes >= 180
            || continuityItems.count >= 3
            || artifacts.count >= 4
    }

    private func splitSeed(
        for thread: AdvisoryThreadRecord,
        continuityItems: [ContinuityItemRecord],
        artifacts: [AdvisoryArtifactRecord]
    ) -> SplitSeed? {
        if let item = continuityItems.first(where: { candidate in
            !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && candidate.title.caseInsensitiveCompare(thread.displayTitle) != .orderedSame
        }) {
            let summary = item.body?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? item.body?.trimmingCharacters(in: .whitespacesAndNewlines)
                : "Focused sub-thread spun out of \(thread.displayTitle)."
            return SplitSeed(
                id: item.id,
                title: item.title,
                summary: summary,
                sourceContinuityItemId: item.id,
                sourceKind: item.kind
            )
        }
        if let artifact = artifacts.first(where: { candidate in
            candidate.kind == .noteSeed || candidate.kind == .threadSeed || candidate.kind == .researchDirection || candidate.kind == .explorationSeed
        }) {
            return SplitSeed(
                id: artifact.id,
                title: artifact.title,
                summary: AdvisorySupport.cleanedSnippet(artifact.body, maxLength: 140),
                sourceContinuityItemId: nil,
                sourceKind: nil
            )
        }
        return nil
    }

    private func suggestedSubthreadKind(
        thread: AdvisoryThreadRecord,
        seed: SplitSeed
    ) -> AdvisoryThreadKind {
        switch seed.sourceKind {
        case .question:
            return .question
        case .commitment:
            return .commitment
        case .decision, .openLoop, .blockedItem, .none:
            return thread.kind == .project ? .theme : thread.kind
        }
    }
}

private struct ThreadMetrics {
    let status: AdvisoryThreadStatus
    let totalActiveMinutes: Int
    let lastArtifactAt: String?
    let importanceScore: Double
}

private struct ThreadSessionSnapshot {
    let id: String
    let startedAt: String
    let endedAt: String?
    let activeDurationMs: Int64
}

private struct SplitSeed {
    let id: String
    let title: String
    let summary: String?
    let sourceContinuityItemId: String?
    let sourceKind: ContinuityItemKind?
}
