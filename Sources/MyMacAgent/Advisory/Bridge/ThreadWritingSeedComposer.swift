import Foundation

struct ThreadWritingSeedComposer {
    func compose(
        packet: ThreadPacket,
        recipeName: String
    ) -> AdvisoryArtifactCandidate? {
        guard signal(named: "expression_pull", in: packet) >= 0.25,
              matchedAvoidTopic(in: packet) == nil else {
            return nil
        }

        let thread = packet.thread
        let primaryAngle = preferredAngle(in: packet, fallback: .observation)
        let alternatives = alternativeAngles(in: packet, excluding: primaryAngle)
        let kind = artifactKind(for: packet, primaryAngle: primaryAngle)
        let evidencePack = Array(packet.evidenceRefs.prefix(4))
        let voiceExamples = Array(packet.constraints.twitterVoiceExamples.prefix(2))
        let avoidTopics = normalizedAvoidTopics(in: packet)
        let persona = cleanedPersona(in: packet)
        let continuityAnchor = packet.continuityState.suggestedEntryPoint
        let note = enrichmentItem(for: .notes, in: packet)
        let webResearch = enrichmentItem(for: .webResearch, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let timingWindow = timingWindowHint(calendar: calendar, reminder: reminder)
        let metadata = AdvisoryWritingArtifactMetadata(
            primaryAngle: primaryAngle,
            alternativeAngles: alternatives,
            evidencePack: evidencePack,
            voiceExamples: voiceExamples,
            avoidTopics: avoidTopics,
            personaDescription: persona,
            suggestedOpenings: [
                threadTweetOpening(for: primaryAngle, title: thread.title),
                threadTweetOpening(for: alternatives.first ?? .question, title: thread.title)
            ],
            continuityAnchor: continuityAnchor,
            sourceAnchors: sourceAnchors(from: [note, webResearch, calendar, reminder]),
            enrichmentSources: enrichmentSources(from: [note, webResearch, calendar, reminder]),
            timingWindow: timingWindow
        )

        var bodyLines = [
            opening(for: kind, thread: thread),
            "Persona: \(persona)",
            "Angle: \(primaryAngle.rawValue).",
            "Evidence pack: \(evidencePack.joined(separator: ", ")).",
            "Alternative angles: \(alternatives.map(\.rawValue).joined(separator: " | "))."
        ]

        if !voiceExamples.isEmpty {
            bodyLines.append("Voice examples: \(voiceExamples.joined(separator: " | ")).")
        }
        if !avoidTopics.isEmpty {
            bodyLines.append("Avoid topics: \(avoidTopics.joined(separator: ", ")).")
        }
        if let continuityAnchor, !continuityAnchor.isEmpty {
            bodyLines.append("Continuity anchor: \(continuityAnchor)")
        }
        if let note {
            bodyLines.append("Note anchor: \(note.title) — \(note.snippet)")
        }
        if let webResearch {
            bodyLines.append("Context anchor: \(enrichmentAnchor(for: webResearch))")
        }
        if let timingWindow, !timingWindow.isEmpty {
            bodyLines.append("Timing: \(timingWindow)")
        }
        bodyLines.append(contentsOf: structure(for: kind, packet: packet, primaryAngle: primaryAngle, alternatives: alternatives))

        return AdvisoryArtifactCandidate(
            id: nil,
            domain: .writingExpression,
            kind: kind,
            title: title(for: kind, thread: thread),
            body: bodyLines.joined(separator: "\n"),
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: recipeName,
            confidence: confidence(for: kind, packet: packet),
            whyNow: whyNow(for: kind, packet: packet),
            evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
            metadataJson: AdvisorySupport.encodeJSONString(metadata),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
    }

    private func artifactKind(
        for packet: ThreadPacket,
        primaryAngle: AdvisoryWritingAngle
    ) -> AdvisoryArtifactKind {
        if packet.triggerKind == .userInvokedWrite,
           !packet.constraints.twitterVoiceExamples.isEmpty || [.contrarianTake, .provocation].contains(primaryAngle) {
            return .tweetSeed
        }
        if packet.thread.totalActiveMinutes >= 180 || packet.thread.importanceScore >= 0.8 {
            return .threadSeed
        }
        return .noteSeed
    }

    private func title(for kind: AdvisoryArtifactKind, thread: ReflectionThreadRef) -> String {
        switch kind {
        case .tweetSeed: return "Собрать tweet seed по \(thread.title)"
        case .threadSeed: return "Собрать thread seed по \(thread.title)"
        default: return "Собрать note seed по \(thread.title)"
        }
    }

    private func opening(for kind: AdvisoryArtifactKind, thread: ReflectionThreadRef) -> String {
        switch kind {
        case .tweetSeed:
            return "Из этой нити уже можно сделать более публичный signal по \(thread.title), не теряя grounding."
        case .threadSeed:
            return "Нить \(thread.title) уже выдерживает thread seed, а не только короткую заметку."
        default:
            return "Из нити \(thread.title) уже может получиться сильный note seed."
        }
    }

    private func structure(
        for kind: AdvisoryArtifactKind,
        packet: ThreadPacket,
        primaryAngle: AdvisoryWritingAngle,
        alternatives: [AdvisoryWritingAngle]
    ) -> [String] {
        switch kind {
        case .tweetSeed:
            return [
                "Черновой заход:",
                threadTweetOpening(for: primaryAngle, title: packet.thread.title),
                "Запасной заход:",
                threadTweetOpening(for: alternatives.first ?? .question, title: packet.thread.title),
                "Форма:",
                "1. Один тезис из нити.",
                "2. Один continuity anchor.",
                "3. Один implication или вопрос."
            ]
        case .threadSeed:
            return [
                "Skeleton thread:",
                "1. Почему нить «\(packet.thread.title)» оказалась устойчивее, чем казалось.",
                "2. Развернуть angle через один ясный frame.",
                "3. Дать 2-3 evidence anchors из нити и её continuity items.",
                "4. Закрыть тем, что это меняет дальше."
            ]
        default:
            return [
                "Если захочешь развернуть:",
                "1. Назвать главное наблюдение по нити.",
                "2. Подкрепить его 2 evidence anchors.",
                "3. Закончить return point или open question."
            ]
        }
    }

    private func threadTweetOpening(
        for angle: AdvisoryWritingAngle,
        title: String
    ) -> String {
        switch angle {
        case .contrarianTake:
            return "Похоже, в \(title) обычно переоценивают сложность и недооценивают цену повторного входа."
        case .question:
            return "Вопрос по \(title): какой один сдвиг реально удешевляет return into context?"
        case .miniFramework:
            return "Похоже, здесь складывается фрейм: thread -> return point -> signal."
        case .lessonLearned:
            return "Урок из \(title): нить держится дольше, когда у неё есть явный return point."
        case .provocation:
            return "Резкая мысль: в \(title) часто путают depth с повторным прогревом одного и того же контекста."
        case .observation:
            return "Замечаю полезную вещь про \(title): сильный signal появляется, когда нить уже выдержала несколько входов и выходов."
        }
    }

    private func confidence(for kind: AdvisoryArtifactKind, packet: ThreadPacket) -> Double {
        let expressionPull = signal(named: "expression_pull", in: packet)
        let kindLift = kind == .threadSeed ? 0.3 : kind == .tweetSeed ? 0.26 : 0.22
        return min(0.91, max(0.56, 0.52 + expressionPull * 0.22 + packet.thread.importanceScore * 0.14 + kindLift * 0.1))
    }

    private func whyNow(for kind: AdvisoryArtifactKind, packet: ThreadPacket) -> String {
        switch kind {
        case .tweetSeed:
            return "Ты вызвал writing прямо из thread context, а значит лучше дать signal с continuity anchors, а не generic content."
        case .threadSeed:
            return "Нить уже накопила достаточно времени и evidence, чтобы выдержать thread, а не только короткую заметку."
        default:
            return "Нить уже тянет на текст, но ещё не обязана становиться публичным постом."
        }
    }

    private func cleanedPersona(in packet: ThreadPacket) -> String {
        let trimmed = packet.constraints.contentPersonaDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Grounded builder voice. Specific, compact, evidence-led." : trimmed
    }

    private func normalizedAngles(in packet: ThreadPacket) -> [AdvisoryWritingAngle] {
        AdvisoryWritingAngle.normalizedList(
            from: packet.constraints.preferredAngles,
            allowProvocation: packet.constraints.allowProvocation
        )
    }

    private func preferredAngle(in packet: ThreadPacket, fallback: AdvisoryWritingAngle) -> AdvisoryWritingAngle {
        normalizedAngles(in: packet).first ?? fallback
    }

    private func alternativeAngles(
        in packet: ThreadPacket,
        excluding primaryAngle: AdvisoryWritingAngle
    ) -> [AdvisoryWritingAngle] {
        let candidates = normalizedAngles(in: packet).filter { $0 != primaryAngle }
        return Array((candidates.isEmpty ? [.question, .lessonLearned, .miniFramework].filter { $0 != primaryAngle } : candidates).prefix(2))
    }

    private func normalizedAvoidTopics(in packet: ThreadPacket) -> [String] {
        AdvisorySupport.dedupe(packet.constraints.avoidTopics)
    }

    private func matchedAvoidTopic(in packet: ThreadPacket) -> String? {
        let haystack = [
            packet.thread.title,
            packet.thread.summary ?? "",
            packet.evidenceRefs.joined(separator: " "),
            packet.recentEvidence.compactMap(\.snippet).joined(separator: " ")
        ].joined(separator: " ")
        return normalizedAvoidTopics(in: packet).first { haystack.localizedCaseInsensitiveContains($0) }
    }

    private func signal(named name: String, in packet: ThreadPacket) -> Double {
        packet.attentionSignals.first(where: { $0.name == name })?.score ?? 0
    }

    private func enrichmentItems(
        for source: AdvisoryEnrichmentSource,
        in packet: ThreadPacket
    ) -> [ReflectionEnrichmentItem] {
        packet.enrichment.bundles
            .first(where: { $0.source == source && $0.availability == .embedded })?
            .items ?? []
    }

    private func enrichmentItem(
        for source: AdvisoryEnrichmentSource,
        in packet: ThreadPacket
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
            return "в transition вокруг «\(reminder.title)»"
        }
        guard let calendar else { return nil }
        return "вокруг окна «\(calendar.title)»"
    }
}
