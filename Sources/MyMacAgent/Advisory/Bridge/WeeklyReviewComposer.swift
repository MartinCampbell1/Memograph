import Foundation

struct WeeklyReviewComposer {
    func compose(
        packet: WeeklyPacket,
        recipeName: String
    ) -> AdvisoryArtifactCandidate? {
        guard !packet.threadRollup.isEmpty else {
            return nil
        }

        let dominantThread = packet.threadRollup.first
        let topPattern = packet.patterns.first
        let note = enrichmentItem(for: .notes, in: packet)
        let webResearch = enrichmentItem(for: .webResearch, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let timingWindow = timingWindowHint(calendar: calendar, reminder: reminder)
        let actionSteps = [
            "Назвать 1-2 нити, которые реально тянули неделю.",
            "Отметить, что из этого уже стало яснее.",
            "Оставить один return point на следующую неделю."
        ]

        var bodyLines = [
            "Неделя уже выглядит достаточно собранной, чтобы оставить один мягкий weekly anchor.",
            "Это не попытка закрыть всё разом, а способ вернуть себе быстрый вход в основные нити в начале следующей недели."
        ]
        if let dominantThread {
            bodyLines.append("Главная несущая нить недели: \(dominantThread.title).")
        }
        if let topPattern {
            bodyLines.append("Самый заметный паттерн: \(topPattern.summary)")
        }
        if let note {
            bodyLines.append("Из заметок неделя уже держится через: «\(note.title)» — \(note.snippet)")
        }
        if let webResearch {
            bodyLines.append("Во внешнем контексте тоже тянется: \(enrichmentAnchor(for: webResearch))")
        }
        if let reminder {
            bodyLines.append("На следующую неделю уже виден мягкий anchor: \(enrichmentAnchor(for: reminder)).")
        } else if let calendar {
            bodyLines.append("На следующую неделю уже виден мягкий anchor: \(enrichmentAnchor(for: calendar)).")
        }
        if let timingWindow, !timingWindow.isEmpty {
            bodyLines.append("Если оставить return point мягко, лучше делать это \(timingWindow).")
        }
        if !packet.continuityItems.isEmpty {
            bodyLines.append("Открытые loops, которые стоит не потерять:")
            for (index, item) in packet.continuityItems.prefix(3).enumerated() {
                bodyLines.append("\(index + 1). \(item.title)")
            }
        }
        bodyLines.append("Если захочешь зафиксировать неделю коротко:")
        bodyLines.append("1. \(actionSteps[0])")
        bodyLines.append("2. \(actionSteps[1])")
        bodyLines.append("3. \(actionSteps[2])")

        return AdvisoryArtifactCandidate(
            id: nil,
            domain: .continuity,
            kind: .weeklyReview,
            title: "Weekly review: собрать несущие нити недели",
            body: bodyLines.joined(separator: "\n"),
            threadId: dominantThread?.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: recipeName,
            confidence: min(0.88, 0.52 + signal(named: "continuity_pressure", in: packet) * 0.18 + signal(named: "thread_density", in: packet) * 0.14),
            whyNow: "Weekly review полезен, когда уже видны повторяющиеся нити и continuity pressure, а не просто сумма дней.",
            evidenceJson: AdvisorySupport.encodeJSONString(packet.evidenceRefs.prefix(8).map { $0 }),
            metadataJson: AdvisorySupport.encodeJSONString(
                AdvisoryArtifactGuidanceMetadata(
                    summary: dominantThread?.summary ?? topPattern?.summary,
                    evidencePack: Array(packet.evidenceRefs.prefix(4)),
                    actionSteps: actionSteps,
                    continuityAnchor: actionSteps.last,
                    openLoop: packet.continuityItems.first?.title,
                    noteAnchorTitle: note?.title,
                    noteAnchorSnippet: note?.snippet,
                    patternName: topPattern?.title,
                    sourceAnchors: sourceAnchors(from: [note, webResearch, calendar, reminder]),
                    enrichmentSources: enrichmentSources(from: [note, webResearch, calendar, reminder]),
                    timingWindow: timingWindow
                )
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
    }

    private func signal(named name: String, in packet: WeeklyPacket) -> Double {
        packet.attentionSignals.first(where: { $0.name == name })?.score ?? 0
    }

    private func enrichmentItems(
        for source: AdvisoryEnrichmentSource,
        in packet: WeeklyPacket
    ) -> [ReflectionEnrichmentItem] {
        packet.enrichment.bundles
            .first(where: { $0.source == source && $0.availability == .embedded })?
            .items ?? []
    }

    private func enrichmentItem(
        for source: AdvisoryEnrichmentSource,
        in packet: WeeklyPacket
    ) -> ReflectionEnrichmentItem? {
        enrichmentItems(for: source, in: packet).first
    }

    private func enrichmentAnchor(for item: ReflectionEnrichmentItem) -> String {
        let snippet = AdvisorySupport.cleanedSnippet(item.snippet, maxLength: 110)
        return snippet.isEmpty ? "\(item.source.label): \(item.title)" : "\(item.source.label): \(item.title) — \(snippet)"
    }

    private func sourceAnchors(from items: [ReflectionEnrichmentItem?]) -> [String] {
        AdvisorySupport.dedupe(items.compactMap { $0 }.map(enrichmentAnchor(for:)))
    }

    private func enrichmentSources(from items: [ReflectionEnrichmentItem?]) -> [AdvisoryEnrichmentSource] {
        var seen: Set<AdvisoryEnrichmentSource> = []
        var result: [AdvisoryEnrichmentSource] = []
        for source in items.compactMap({ $0?.source }) where seen.insert(source).inserted {
            result.append(source)
        }
        return result
    }

    private func timingWindowHint(
        calendar: ReflectionEnrichmentItem?,
        reminder: ReflectionEnrichmentItem?
    ) -> String? {
        if let reminder {
            return "вокруг transition рядом с «\(reminder.title)»"
        }
        guard let calendar else { return nil }
        return "вокруг окна «\(calendar.title)»"
    }
}
