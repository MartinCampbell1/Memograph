import Foundation

final class ContinuitySignalBuilder {
    private let dateSupport: LocalDateSupport

    init(timeZone: TimeZone = .autoupdatingCurrent) {
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func build(
        summary: DailySummaryRecord?,
        window: SummaryWindowDescriptor,
        sessions: [SessionData],
        threads: [AdvisoryThreadRecord]
    ) -> [ContinuityItemCandidate] {
        let unfinishedItems = AdvisorySupport.looseStringList(from: summary?.unfinishedItemsJson)
        let summaryText = summary?.summaryText ?? ""
        var items: [ContinuityItemCandidate] = []
        let timestamp = dateSupport.isoString(from: window.end)

        for unfinished in unfinishedItems {
            let threadId = bestMatchingThreadId(for: unfinished, threads: threads)
            let kind: ContinuityItemKind = unfinished.contains("?") ? .question : .openLoop
            let confidence = confidenceForContinuity(title: unfinished, threads: threads, threadId: threadId, bonus: 0.18)
            items.append(ContinuityItemCandidate(
                id: nil,
                threadId: threadId,
                kind: kind,
                title: unfinished,
                body: "Незакрытая нить из summary window \(window.date).",
                status: .open,
                confidence: confidence,
                sourcePacketId: nil,
                createdAt: timestamp,
                updatedAt: timestamp,
                resolvedAt: nil
            ))
        }

        for decision in decisionSentences(from: summaryText).prefix(2) {
            let threadId = bestMatchingThreadId(for: decision, threads: threads)
            items.append(ContinuityItemCandidate(
                id: nil,
                threadId: threadId,
                kind: .decision,
                title: "Решение: \(AdvisorySupport.cleanedSnippet(decision, maxLength: 90))",
                body: decision,
                status: .stabilizing,
                confidence: confidenceForContinuity(title: decision, threads: threads, threadId: threadId, bonus: 0.08),
                sourcePacketId: nil,
                createdAt: timestamp,
                updatedAt: timestamp,
                resolvedAt: nil
            ))
        }

        if items.isEmpty, let thread = threads.first {
            let sessionSnippet = AdvisorySupport.bestSnippet(
                containing: thread.title,
                in: sessions.flatMap(\.contextTexts) + sessions.flatMap(\.windowTitles)
            )
            items.append(ContinuityItemCandidate(
                id: nil,
                threadId: thread.id,
                kind: .openLoop,
                title: "Продолжить \(thread.title)",
                body: sessionSnippet ?? thread.summary ?? "Есть незавершённая нить, к которой легко вернуться с текущего места.",
                status: .open,
                confidence: min(0.9, thread.confidence + 0.06),
                sourcePacketId: nil,
                createdAt: timestamp,
                updatedAt: timestamp,
                resolvedAt: nil
            ))
        }

        let deduped = Dictionary(grouping: items, by: { "\($0.kind.rawValue):\(AdvisorySupport.slug(for: $0.title))" })
            .compactMap { _, group in
                group.max { lhs, rhs in lhs.confidence < rhs.confidence }
            }

        return deduped.sorted { lhs, rhs in
            if lhs.confidence == rhs.confidence {
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            return lhs.confidence > rhs.confidence
        }
    }

    private func bestMatchingThreadId(for text: String, threads: [AdvisoryThreadRecord]) -> String? {
        threads
            .filter {
                text.localizedCaseInsensitiveContains($0.displayTitle)
                    || text.localizedCaseInsensitiveContains($0.title)
            }
            .sorted { lhs, rhs in
                if lhs.importanceScore == rhs.importanceScore {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.importanceScore > rhs.importanceScore
            }
            .first?
            .id
    }

    private func confidenceForContinuity(
        title: String,
        threads: [AdvisoryThreadRecord],
        threadId: String?,
        bonus: Double
    ) -> Double {
        let threadConfidence = threads.first(where: { $0.id == threadId }).map {
            max($0.confidence, min(0.92, 0.45 + $0.importanceScore * 0.4))
        } ?? 0.48
        let punctuationBoost = title.contains("?") ? 0.05 : 0
        return min(0.93, threadConfidence + bonus + punctuationBoost)
    }

    private func decisionSentences(from summaryText: String) -> [String] {
        guard !summaryText.isEmpty else { return [] }
        let candidates = summaryText.components(separatedBy: CharacterSet(charactersIn: ".!\n"))
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter {
                let lower = $0.lowercased()
                return !$0.isEmpty && (
                    lower.contains("decided")
                    || lower.contains("switched")
                    || lower.contains("выбрал")
                    || lower.contains("решил")
                    || lower.contains("переш")
                )
            }
    }
}
