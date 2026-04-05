import Foundation

struct WritingSeedComposer {
    func compose(
        packet: ReflectionPacket,
        recipeName: String
    ) -> AdvisoryArtifactCandidate? {
        guard signal(named: "expression_pull", in: packet) >= 0.25,
              let thread = packet.candidateThreadRefs.first,
              matchedAvoidTopic(in: packet, thread: thread) == nil else {
            return nil
        }

        let primaryAngle = preferredAngle(in: packet, fallback: .observation)
        let alternatives = alternativeAngles(in: packet, excluding: primaryAngle)
        let kind = artifactKind(for: packet, thread: thread, primaryAngle: primaryAngle)
        let evidencePack = Array(packet.evidenceRefs.prefix(3))
        let voiceExamples = Array(packet.constraints.twitterVoiceExamples.prefix(2))
        let avoidTopics = normalizedAvoidTopics(in: packet)
        let persona = cleanedPersona(in: packet)
        let note = enrichmentItem(for: .notes, in: packet)
        let webResearch = enrichmentItem(for: .webResearch, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let timingWindow = timingWindowHint(
            calendar: calendar,
            reminder: reminder,
            trigger: packet.triggerKind
        )
        let suggestedOpenings = [
            tweetOpening(for: primaryAngle, thread: thread, packet: packet),
            tweetOpening(for: alternatives.first ?? .question, thread: thread, packet: packet)
        ]
        let metadata = AdvisoryWritingArtifactMetadata(
            primaryAngle: primaryAngle,
            alternativeAngles: alternatives,
            evidencePack: evidencePack,
            voiceExamples: voiceExamples,
            avoidTopics: avoidTopics,
            personaDescription: persona,
            suggestedOpenings: suggestedOpenings,
            continuityAnchor: nil,
            sourceAnchors: sourceAnchors(from: [note, webResearch, calendar, reminder]),
            enrichmentSources: enrichmentSources(from: [note, webResearch, calendar, reminder]),
            timingWindow: timingWindow
        )

        return AdvisoryArtifactCandidate(
            id: nil,
            domain: .writingExpression,
            kind: kind,
            title: title(for: kind, thread: thread),
            body: body(
                for: kind,
                thread: thread,
                persona: persona,
                primaryAngle: primaryAngle,
                alternativeAngles: alternatives,
                evidencePack: evidencePack,
                voiceExamples: voiceExamples,
                avoidTopics: avoidTopics,
                note: note,
                webResearch: webResearch,
                timingWindow: timingWindow,
                packet: packet
            ),
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: recipeName,
            confidence: confidence(for: kind, packet: packet, thread: thread),
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
        for packet: ReflectionPacket,
        thread: ReflectionThreadRef,
        primaryAngle: AdvisoryWritingAngle
    ) -> AdvisoryArtifactKind {
        let voiceExamples = packet.constraints.twitterVoiceExamples
        let socialPull = signal(named: "social_pull", in: packet)
        let threadDensity = signal(named: "thread_density", in: packet)

        if packet.triggerKind == .userInvokedWrite,
           !voiceExamples.isEmpty || socialPull >= 0.32 || [.contrarianTake, .provocation].contains(primaryAngle) {
            return .tweetSeed
        }

        if thread.totalActiveMinutes >= 180 || thread.importanceScore >= 0.8 || threadDensity >= 0.76 {
            return .threadSeed
        }

        return .noteSeed
    }

    private func title(
        for kind: AdvisoryArtifactKind,
        thread: ReflectionThreadRef
    ) -> String {
        switch kind {
        case .tweetSeed:
            return "Собрать tweet seed по \(thread.title)"
        case .threadSeed:
            return "Собрать thread seed по \(thread.title)"
        default:
            return "Собрать note seed по \(thread.title)"
        }
    }

    private func body(
        for kind: AdvisoryArtifactKind,
        thread: ReflectionThreadRef,
        persona: String,
        primaryAngle: AdvisoryWritingAngle,
        alternativeAngles: [AdvisoryWritingAngle],
        evidencePack: [String],
        voiceExamples: [String],
        avoidTopics: [String],
        note: ReflectionEnrichmentItem?,
        webResearch: ReflectionEnrichmentItem?,
        timingWindow: String?,
        packet: ReflectionPacket
    ) -> String {
        var lines: [String] = []
        lines.append(opening(for: kind, thread: thread))
        lines.append("Persona: \(persona)")
        lines.append("Angle: \(primaryAngle.rawValue).")
        lines.append("Evidence pack: \(evidencePack.joined(separator: ", ")).")
        lines.append("Alternative angles: \(alternativeAngles.map(\.rawValue).joined(separator: " | ")).")
        if !voiceExamples.isEmpty {
            lines.append("Voice examples: \(voiceExamples.joined(separator: " | ")).")
        }
        if !avoidTopics.isEmpty {
            lines.append("Avoid topics: \(avoidTopics.joined(separator: ", ")).")
        }
        if let note {
            lines.append("Note anchor: \(note.title) — \(note.snippet)")
        }
        if let webResearch {
            lines.append("Context anchor: \(enrichmentAnchor(for: webResearch))")
        }
        if let timingWindow, !timingWindow.isEmpty {
            lines.append("Timing: \(timingWindow)")
        }
        lines.append("Почему это может сработать: нить уже заземлена в lived context, а не в generic AI abstraction.")
        lines.append(contentsOf: structure(for: kind, thread: thread, primaryAngle: primaryAngle, alternativeAngles: alternativeAngles, packet: packet))
        return lines.joined(separator: "\n")
    }

    private func structure(
        for kind: AdvisoryArtifactKind,
        thread: ReflectionThreadRef,
        primaryAngle: AdvisoryWritingAngle,
        alternativeAngles: [AdvisoryWritingAngle],
        packet: ReflectionPacket
    ) -> [String] {
        switch kind {
        case .tweetSeed:
            return [
                "Черновой заход:",
                tweetOpening(for: primaryAngle, thread: thread, packet: packet),
                "Запасной заход:",
                tweetOpening(for: alternativeAngles.first ?? .question, thread: thread, packet: packet),
                "Форма:",
                "1. Один тезис.",
                "2. Один evidence anchor из дня.",
                "3. Один implication или открытый вопрос."
            ]
        case .threadSeed:
            return [
                "Skeleton thread:",
                "1. Входной тезис: \(thread.title) неожиданно оказался важнее, чем казалось.",
                "2. Развернуть angle: \(threadFrame(for: primaryAngle, thread: thread)).",
                "3. Дать 2-3 evidence anchors из дня.",
                "4. Закончить тем, что именно меняется в подходе дальше."
            ]
        default:
            return [
                "Если захочешь развернуть:",
                "1. Начать с одного тезиса о том, что в этой нити оказалось неожиданным.",
                "2. Добавить 2-3 evidence anchors из сегодняшних сессий.",
                "3. Закончить тем, что эта нить меняет в подходе дальше."
            ]
        }
    }

    private func opening(
        for kind: AdvisoryArtifactKind,
        thread: ReflectionThreadRef
    ) -> String {
        switch kind {
        case .tweetSeed:
            return "Из этой нити уже можно собрать tweet seed вокруг \(thread.title), не звуча как generic content machine."
        case .threadSeed:
            return "Нить \(thread.title) уже достаточно плотная, чтобы из неё вырос thread seed, а не только короткая заметка."
        default:
            return "Из этой нити может получиться сильный note seed вокруг \(thread.title)."
        }
    }

    private func tweetOpening(
        for angle: AdvisoryWritingAngle,
        thread: ReflectionThreadRef,
        packet: ReflectionPacket
    ) -> String {
        let focus = packet.activeEntities.first ?? thread.title
        switch angle {
        case .contrarianTake:
            return "Кажется, интуитивный ход в \(focus) часто неверный: проблема не там, где все привыкли искать."
        case .question:
            return "Вопрос по \(focus): какой один сдвиг реально меняет результат, а не только создаёт ощущение прогресса?"
        case .miniFramework:
            return "Похоже, здесь складывается простой фреймворк: signal -> decision -> return point."
        case .lessonLearned:
            return "Урок из \(focus): контекст возвращается быстрее, если оставить не просто note, а явный return point."
        case .provocation:
            return "Непопулярная мысль: в \(focus) часто переоценивают сложность и недооценивают стоимость повторного входа."
        case .observation:
            return "Замечаю одну полезную вещь про \(focus): реальный bottleneck становится виден только когда смотришь на lived evidence дня."
        }
    }

    private func threadFrame(
        for angle: AdvisoryWritingAngle,
        thread: ReflectionThreadRef
    ) -> String {
        switch angle {
        case .contrarianTake:
            return "Где популярная интерпретация по \(thread.title) расходится с тем, что показал день."
        case .question:
            return "Какой один вопрос по \(thread.title) сейчас снимает больше всего неопределённости."
        case .miniFramework:
            return "Разложить \(thread.title) в короткий рабочий framework."
        case .lessonLearned:
            return "Что именно в \(thread.title) уже превратилось в usable lesson."
        case .provocation:
            return "Какой sharp take по \(thread.title) всё ещё остаётся grounded."
        case .observation:
            return "Что именно наблюдается в \(thread.title), если убрать абстракции."
        }
    }

    private func confidence(
        for kind: AdvisoryArtifactKind,
        packet: ReflectionPacket,
        thread: ReflectionThreadRef
    ) -> Double {
        let base = signal(named: "expression_pull", in: packet)
        let kindLift: Double
        switch kind {
        case .tweetSeed:
            kindLift = 0.26
        case .threadSeed:
            kindLift = 0.3
        default:
            kindLift = 0.24
        }
        return min(0.9, max(0.55, 0.5 + base * 0.24 + thread.importanceScore * 0.12 + kindLift * 0.1))
    }

    private func whyNow(
        for kind: AdvisoryArtifactKind,
        packet: ReflectionPacket
    ) -> String {
        switch kind {
        case .tweetSeed:
            return packet.triggerKind == .userInvokedWrite
                ? "Сигнал на writing был ручным, и в дне уже есть persona-shaped материал для короткого post seed."
                : "Есть social/expression pull и enough evidence, чтобы короткий seed не звучал натянуто."
        case .threadSeed:
            return "Нить уже достаточно плотная по времени и evidence, чтобы выдержать не только note, но и thread."
        default:
            return "В дне уже есть материал для expression, но он ещё не распался на шум."
        }
    }

    private func cleanedPersona(in packet: ReflectionPacket) -> String {
        let trimmed = packet.constraints.contentPersonaDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Grounded builder voice. Specific, compact, evidence-led."
        }
        return trimmed
    }

    private func normalizedAngles(in packet: ReflectionPacket) -> [AdvisoryWritingAngle] {
        AdvisoryWritingAngle.normalizedList(
            from: packet.constraints.preferredAngles,
            allowProvocation: packet.constraints.allowProvocation
        )
    }

    private func preferredAngle(
        in packet: ReflectionPacket,
        fallback: AdvisoryWritingAngle
    ) -> AdvisoryWritingAngle {
        normalizedAngles(in: packet).first ?? fallback
    }

    private func alternativeAngles(
        in packet: ReflectionPacket,
        excluding primaryAngle: AdvisoryWritingAngle
    ) -> [AdvisoryWritingAngle] {
        let candidates = normalizedAngles(in: packet).filter { $0 != primaryAngle }
        if candidates.isEmpty {
            return [.question, .lessonLearned, .miniFramework].filter { $0 != primaryAngle }
        }
        return Array(candidates.prefix(2))
    }

    private func normalizedAvoidTopics(in packet: ReflectionPacket) -> [String] {
        AdvisorySupport.dedupe(
            packet.constraints.avoidTopics
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private func matchedAvoidTopic(
        in packet: ReflectionPacket,
        thread: ReflectionThreadRef
    ) -> String? {
        let haystacks = [
            thread.title,
            thread.summary ?? "",
            packet.activeEntities.joined(separator: " "),
            packet.evidenceRefs.joined(separator: " ")
        ]
        for topic in normalizedAvoidTopics(in: packet) {
            let lowered = topic.lowercased()
            if haystacks.contains(where: { $0.lowercased().contains(lowered) }) {
                return topic
            }
        }
        return nil
    }

    private func signal(named name: String, in packet: ReflectionPacket) -> Double {
        packet.attentionSignals.first(where: { $0.name == name })?.score ?? 0
    }

    private func enrichmentItems(
        for source: AdvisoryEnrichmentSource,
        in packet: ReflectionPacket
    ) -> [ReflectionEnrichmentItem] {
        packet.enrichment.bundles
            .first(where: { $0.source == source && $0.availability == .embedded })?
            .items ?? []
    }

    private func enrichmentItem(
        for source: AdvisoryEnrichmentSource,
        in packet: ReflectionPacket
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
        reminder: ReflectionEnrichmentItem?,
        trigger: AdvisoryTriggerKind
    ) -> String? {
        if let reminder {
            return trigger == .userInvokedWrite
                ? "вокруг окна «\(reminder.title)»"
                : "в мягком transition вокруг «\(reminder.title)»"
        }
        guard let calendar else { return nil }
        return trigger == .userInvokedWrite
            ? "вокруг окна «\(calendar.title)»"
            : "до или после блока «\(calendar.title)»"
    }
}
