import Foundation
import os

final class ThreadDetector {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport
    private let logger = Logger.advisory

    init(db: DatabaseManager, timeZone: TimeZone = .autoupdatingCurrent) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func detect(
        summary: DailySummaryRecord?,
        window: SummaryWindowDescriptor,
        sessions: [SessionData]
    ) throws -> [AdvisoryThreadDetection] {
        let existingThreads = try loadExistingThreads()
        let topTopics = AdvisorySupport.decodeStringArray(from: summary?.topTopicsJson)
        let referenced = AdvisorySupport.referencedEntities(in: summary?.summaryText)
        let unfinishedItems = AdvisorySupport.looseStringList(from: summary?.unfinishedItemsJson)
        let windowTitles = sessions.flatMap(\.windowTitles)
        let explicitSeeds = AdvisorySupport.dedupe(topTopics + referenced + unfinishedItems + windowTitles)

        var detections: [AdvisoryThreadDetection] = []
        for seed in explicitSeeds {
            guard seed.count >= 3 else { continue }

            let knowledgeEntity = try loadKnowledgeEntity(matching: seed)
            let sourceTexts = [summary?.summaryText]
                .compactMap { $0 }
                + sessions.flatMap(\.contextTexts)
                + sessions.flatMap(\.windowTitles)
            let matchedSessions = sessions.filter { session in
                session.windowTitles.contains(where: { $0.localizedCaseInsensitiveContains(seed) })
                    || session.contextTexts.contains(where: { $0.localizedCaseInsensitiveContains(seed) })
            }

            let appearsInTopTopics = topTopics.contains { AdvisorySupport.slug(for: $0) == AdvisorySupport.slug(for: seed) }
            let appearsInUnfinished = unfinishedItems.contains { $0.localizedCaseInsensitiveContains(seed) }
            let kind = classify(seed: seed, knowledgeEntity: knowledgeEntity, appearsInUnfinished: appearsInUnfinished)

            var confidence = 0.42
            if appearsInTopTopics { confidence += 0.16 }
            if appearsInUnfinished { confidence += 0.12 }
            if knowledgeEntity != nil { confidence += 0.16 }
            confidence += min(0.18, Double(matchedSessions.count) * 0.08)
            confidence = min(0.94, confidence)

            let rawTitle = knowledgeEntity?.canonicalName ?? seed
            let rawSlug = AdvisorySupport.slug(for: rawTitle)
            let existingThread = matchingExistingThread(
                rawTitle: rawTitle,
                rawSlug: rawSlug,
                kind: kind,
                existingThreads: existingThreads
            )
            let title = existingThread?.title ?? rawTitle
            let slug = existingThread?.slug ?? rawSlug
            let summarySnippet = AdvisorySupport.bestSnippet(containing: title, in: sourceTexts)
            let lastActiveAt = matchedSessions.compactMap(\.endedAt).max() ?? dateSupport.isoString(from: window.end)
            let totalActiveMinutes = max(
                existingThread?.totalActiveMinutes ?? 0,
                matchedSessions.reduce(0) { $0 + Int($1.durationMs / 60_000) }
            )
            let importanceScore = min(
                1.0,
                max(existingThread?.importanceScore ?? 0, confidence * 0.58 + min(0.32, Double(totalActiveMinutes) / 360.0))
            )
            let candidate = AdvisoryThreadCandidate(
                id: existingThread?.id,
                title: title,
                slug: slug,
                kind: kind,
                status: .active,
                confidence: confidence,
                firstSeenAt: existingThread?.firstSeenAt ?? knowledgeEntity?.firstSeenAt ?? dateSupport.isoString(from: window.start),
                lastActiveAt: maxTimestamp(existingThread?.lastActiveAt, knowledgeEntity?.lastSeenAt ?? lastActiveAt) ?? lastActiveAt,
                source: buildSource(knowledgeEntity: knowledgeEntity, appearsInTopTopics: appearsInTopTopics, appearsInUnfinished: appearsInUnfinished, matchedSessions: matchedSessions),
                summary: summarySnippet,
                parentThreadId: existingThread?.parentThreadId,
                totalActiveMinutes: totalActiveMinutes,
                importanceScore: importanceScore
            )

            var evidence: [AdvisoryThreadEvidenceCandidate] = []
            if summary != nil {
                evidence.append(AdvisoryThreadEvidenceCandidate(
                    id: nil,
                    evidenceKind: "summary",
                    evidenceRef: "summary:\(window.date)",
                    weight: appearsInTopTopics ? 1.0 : 0.7,
                    createdAt: dateSupport.isoString(from: window.end)
                ))
            }
            if let knowledgeEntity {
                evidence.append(AdvisoryThreadEvidenceCandidate(
                    id: nil,
                    evidenceKind: "entity",
                    evidenceRef: "entity:\(knowledgeEntity.id)",
                    weight: 0.85,
                    createdAt: knowledgeEntity.lastSeenAt
                ))
            }
            for session in matchedSessions {
                evidence.append(AdvisoryThreadEvidenceCandidate(
                    id: nil,
                    evidenceKind: "session",
                    evidenceRef: "session:\(session.sessionId)",
                    weight: min(1.0, max(0.4, Double(session.durationMs) / 3_600_000.0)),
                    createdAt: session.endedAt ?? session.startedAt
                ))
            }

            detections.append(AdvisoryThreadDetection(thread: candidate, evidence: evidence))
        }

        let deduped = Dictionary(grouping: detections, by: { $0.thread.slug }).compactMap { _, group in
            group.max { lhs, rhs in lhs.thread.confidence < rhs.thread.confidence }
        }

        logger.info("Detected \(deduped.count) advisory thread candidates")
        return deduped.sorted { lhs, rhs in
            if lhs.thread.confidence == rhs.thread.confidence {
                return lhs.thread.title.localizedCaseInsensitiveCompare(rhs.thread.title) == .orderedAscending
            }
            return lhs.thread.confidence > rhs.thread.confidence
        }
    }

    private func classify(
        seed: String,
        knowledgeEntity: KnowledgeEntityRecord?,
        appearsInUnfinished: Bool
    ) -> AdvisoryThreadKind {
        if let knowledgeEntity {
            switch knowledgeEntity.entityType {
            case .project, .lesson:
                return .project
            case .person:
                return .person
            case .issue:
                return .question
            case .topic, .site, .tool, .model:
                return .theme
            }
        }

        if appearsInUnfinished {
            return seed.contains("?") ? .question : .commitment
        }
        if seed.contains("?") {
            return .question
        }
        return .theme
    }

    private func buildSource(
        knowledgeEntity: KnowledgeEntityRecord?,
        appearsInTopTopics: Bool,
        appearsInUnfinished: Bool,
        matchedSessions: [SessionData]
    ) -> String {
        var parts: [String] = []
        if knowledgeEntity != nil { parts.append("knowledge_graph") }
        if appearsInTopTopics { parts.append("daily_summary") }
        if appearsInUnfinished { parts.append("unfinished_items") }
        if !matchedSessions.isEmpty { parts.append("session_context") }
        return AdvisorySupport.dedupe(parts).joined(separator: " + ")
    }

    private func loadKnowledgeEntity(matching seed: String) throws -> KnowledgeEntityRecord? {
        let normalizedSeed = AdvisorySupport.slug(for: seed)
        let rows = try db.query("""
            SELECT *
            FROM knowledge_entities
            WHERE canonical_name = ? OR slug = ?
            ORDER BY last_seen_at DESC
            LIMIT 1
        """, params: [
            .text(seed),
            .text(normalizedSeed)
        ])
        return rows.first.flatMap(KnowledgeEntityRecord.init(row:))
    }

    private func loadExistingThreads() throws -> [AdvisoryThreadRecord] {
        try db.query("""
            SELECT *
            FROM advisory_threads
            ORDER BY user_pinned DESC, importance_score DESC, last_active_at DESC
            LIMIT 200
        """).compactMap(AdvisoryThreadRecord.init(row:))
    }

    private func matchingExistingThread(
        rawTitle: String,
        rawSlug: String,
        kind: AdvisoryThreadKind,
        existingThreads: [AdvisoryThreadRecord]
    ) -> AdvisoryThreadRecord? {
        if let exact = existingThreads.first(where: {
            $0.slug == rawSlug || AdvisorySupport.slug(for: $0.displayTitle) == rawSlug
        }) {
            return exact
        }

        let rawTokens = tokenSet(for: rawTitle)
        guard !rawTokens.isEmpty else { return nil }

        let scored = existingThreads.compactMap { thread -> (AdvisoryThreadRecord, Double)? in
            let threadTokens = tokenSet(for: thread.displayTitle)
            guard !threadTokens.isEmpty else { return nil }

            let overlap = rawTokens.intersection(threadTokens).count
            let overlapRatio = Double(overlap) / Double(max(1, min(rawTokens.count, threadTokens.count)))
            let slugContainment = rawSlug.contains(thread.slug) || thread.slug.contains(rawSlug)
            let kindBonus = thread.kind == kind ? 0.08 : 0
            let score = overlapRatio * 0.72 + (slugContainment ? 0.18 : 0) + kindBonus
            guard score >= 0.7 else { return nil }
            return (thread, score)
        }

        return scored.max { lhs, rhs in lhs.1 < rhs.1 }?.0
    }

    private func tokenSet(for title: String) -> Set<String> {
        Set(title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 })
    }

    private func maxTimestamp(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (.none, .none): return nil
        case let (.some(value), .none), let (.none, .some(value)): return value
        case let (.some(left), .some(right)): return left > right ? left : right
        }
    }
}
