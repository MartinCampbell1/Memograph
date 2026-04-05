import Foundation

final class ReflectionPacketBuilder {
    private let settings: AppSettings
    private let dateSupport: LocalDateSupport

    init(
        settings: AppSettings = AppSettings(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.settings = settings
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func build(
        triggerKind: AdvisoryTriggerKind,
        window: SummaryWindowDescriptor,
        summary: DailySummaryRecord?,
        sessions: [SessionData],
        threads: [AdvisoryThreadRecord],
        continuityItems: [ContinuityItemCandidate],
        enrichment: ReflectionPacketEnrichment
    ) -> ReflectionPacket {
        let topTopics = AdvisorySupport.decodeStringArray(from: summary?.topTopicsJson)
        let activeEntities = AdvisorySupport.dedupe(topTopics + threads.map(\.displayTitle)).prefix(8)
        let salientSessions = sessions
            .sorted { lhs, rhs in lhs.durationMs > rhs.durationMs }
            .prefix(4)
            .map { session in
                ReflectionSalientSession(
                    id: session.sessionId,
                    appName: session.appName,
                    startedAt: session.startedAt,
                    endedAt: session.endedAt,
                    durationMinutes: Int(session.durationMs / 60_000),
                    windowTitle: session.windowTitles.first,
                    evidenceSnippet: AdvisorySupport.bestSnippet(containing: session.appName, in: session.contextTexts)
                )
            }

        let threadRefs = threads
            .sorted { lhs, rhs in
                if lhs.userPinned != rhs.userPinned {
                    return lhs.userPinned && !rhs.userPinned
                }
                if lhs.importanceScore == rhs.importanceScore {
                    return lhs.confidence > rhs.confidence
                }
                return lhs.importanceScore > rhs.importanceScore
            }
            .prefix(6)
            .map { thread in
                ReflectionThreadRef(
                    id: thread.id,
                    title: thread.displayTitle,
                    kind: thread.kind,
                    status: thread.status,
                    confidence: thread.confidence,
                    lastActiveAt: thread.lastActiveAt,
                    parentThreadId: thread.parentThreadId,
                    totalActiveMinutes: thread.totalActiveMinutes,
                    importanceScore: thread.importanceScore,
                    summary: thread.summary
                )
            }

        let continuityRefs = continuityItems.prefix(6).enumerated().map { index, item in
            ReflectionContinuityItemRef(
                id: item.id ?? "candidate-\(index)",
                threadId: item.threadId,
                kind: item.kind,
                title: item.title,
                body: item.body,
                confidence: item.confidence
            )
        }

        let evidenceRefs = AdvisorySupport.dedupe(
            (summary != nil ? ["summary:\(window.date)"] : [])
                + sessions.map { "session:\($0.sessionId)" }
                + threads.map { "thread:\($0.id)" }
                + continuityRefs.map { "continuity:\($0.id)" }
                + enrichment.bundles.flatMap { $0.items.flatMap(\.evidenceRefs) }
        )

        let confidenceHints = Dictionary(uniqueKeysWithValues:
            threads.prefix(6).map { ("thread:\($0.id)", $0.confidence) }
            + continuityItems.prefix(6).enumerated().map { ("continuity:\($0.offset)", $0.element.confidence) }
        )

        let attentionSignals = buildAttentionSignals(
            summary: summary,
            sessions: sessions,
            threads: threads,
            continuityItems: continuityItems
        )

        let allowedTools: [String]
        switch settings.advisoryAccessProfile {
        case .conservative:
            allowedTools = []
        case .balanced:
            allowedTools = ["timeline.search"]
        case .deepContext:
            allowedTools = ["timeline.search", "knowledge.lookup"]
        case .fullResearchMode:
            allowedTools = ["timeline.search", "knowledge.lookup", "mcp.enrichment", "screenshot.bundle"]
        }

        let providerConstraints = AdvisorySupport.dedupe([
            settings.networkAllowed ? "external_cli_remote_allowed" : "external_cli_remote_disabled",
            settings.advisoryAllowMCPEnrichment ? "mcp_optional" : "mcp_disabled",
            settings.advisoryBridgeMode == .stubOnly ? "sidecar_transport_stub_only" : "sidecar_transport_jsonrpc_uds"
        ])

        let packetId = AdvisorySupport.stableIdentifier(
            prefix: "advpkt",
            components: [
                AdvisoryPacketKind.reflection.rawValue,
                window.date,
                triggerKind.rawValue,
                settings.advisoryAccessProfile.rawValue,
                threads.prefix(3).map(\.id).joined(separator: ",")
            ]
        )

        return ReflectionPacket(
            packetId: packetId,
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: triggerKind,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: window.date,
                start: dateSupport.isoString(from: window.start),
                end: dateSupport.isoString(from: window.end)
            ),
            activeEntities: Array(activeEntities),
            candidateThreadRefs: threadRefs,
            salientSessions: Array(salientSessions),
            candidateContinuityItems: continuityRefs,
            attentionSignals: attentionSignals,
            constraints: ReflectionPacketConstraints(
                toneMode: settings.guidanceProfile.toneMode,
                writingStyle: settings.advisoryWritingStyle,
                allowScreenshotEscalation: settings.advisoryAllowScreenshotEscalation,
                allowMCPEnrichment: settings.advisoryAllowMCPEnrichment,
                enrichmentPhase: settings.advisoryEnrichmentPhase,
                enabledEnrichmentSources: settings.guidanceProfile.enabledEnrichmentSources,
                enabledDomains: settings.advisoryEnabledDomains,
                attentionMode: settings.guidanceProfile.attentionMarketMode,
                twitterVoiceExamples: settings.guidanceProfile.twitterVoiceExamples,
                preferredAngles: settings.guidanceProfile.preferredAngles,
                avoidTopics: settings.guidanceProfile.avoidTopics,
                contentPersonaDescription: settings.guidanceProfile.contentPersonaDescription,
                allowProvocation: settings.guidanceProfile.allowProvocation
            ),
            language: settings.advisoryPreferredLanguage,
            evidenceRefs: evidenceRefs,
            confidenceHints: confidenceHints,
            accessLevelGranted: settings.advisoryAccessProfile,
            allowedTools: allowedTools,
            providerConstraints: providerConstraints,
            enrichment: enrichment
        )
    }

    func buildDayContext(
        packet: ReflectionPacket,
        threads: [AdvisoryThreadRecord],
        continuityItems: [ContinuityItemCandidate],
        sessions: [SessionData],
        systemAgeDays: Int,
        coldStartPhase: AdvisoryColdStartPhase
    ) -> AdvisoryDayContext {
        buildDayContext(
            localDate: packet.timeWindow.localDate,
            triggerKind: packet.triggerKind,
            activeThreadCount: threads.count,
            openContinuityCount: continuityItems.count,
            sessions: sessions,
            systemAgeDays: systemAgeDays,
            coldStartPhase: coldStartPhase,
            signalWeights: Dictionary(uniqueKeysWithValues: packet.attentionSignals.map { ($0.name, $0.score) })
        )
    }

    func buildDayContext(
        localDate: String,
        triggerKind: AdvisoryTriggerKind,
        activeThreadCount: Int,
        openContinuityCount: Int,
        sessions: [SessionData],
        systemAgeDays: Int,
        coldStartPhase: AdvisoryColdStartPhase,
        signalWeights: [String: Double]
    ) -> AdvisoryDayContext {
        AdvisoryDayContext(
            localDate: localDate,
            triggerKind: triggerKind,
            activeThreadCount: activeThreadCount,
            openContinuityCount: openContinuityCount,
            focusState: focusState(triggerKind: triggerKind, sessions: sessions),
            systemAgeDays: systemAgeDays,
            coldStartPhase: coldStartPhase,
            signalWeights: signalWeights
        )
    }

    private func buildAttentionSignals(
        summary: DailySummaryRecord?,
        sessions: [SessionData],
        threads: [AdvisoryThreadRecord],
        continuityItems: [ContinuityItemCandidate]
    ) -> [ReflectionAttentionSignal] {
        let summaryText = summary?.summaryText ?? ""
        let suggestedNotes = AdvisorySupport.decodeStringArray(from: summary?.suggestedNotesJson)
        let topTopics = AdvisorySupport.decodeStringArray(from: summary?.topTopicsJson)
        let personThreads = threads.filter { $0.kind == .person }
        let researchKeywords = sessions.flatMap(\.contextTexts).filter {
            let lower = $0.lowercased()
            return lower.contains("research") || lower.contains("read ") || lower.contains("investigat") || lower.contains("исслед")
        }
        let decisionHints = summaryText.components(separatedBy: CharacterSet(charactersIn: ".!\n")).filter {
            let lower = $0.lowercased()
            return lower.contains("decid") || lower.contains("решил") || lower.contains("выбрал")
        }
        let unfinishedItems = AdvisorySupport.looseStringList(from: summary?.unfinishedItemsJson)

        let fragmentationScore = min(1.0, Double(max(0, sessions.count - 1)) / 6.0)
        let continuityScore = min(1.0, Double(continuityItems.count) / 4.0)
        let threadDensityScore = min(1.0, Double(threads.count) / 5.0)
        let expressionScore = min(1.0, Double(suggestedNotes.count + min(threads.count, 2)) / 5.0)
        let researchScore = min(1.0, Double(researchKeywords.count + topTopics.filter { $0.contains("?") }.count + (summaryText.lowercased().contains("read") ? 1 : 0)) / 4.0)
        let focusScore = min(1.0, (fragmentationScore * 0.7) + Double(sessions.filter { $0.uncertaintyMode != "normal" }.count) * 0.15)
        let socialScore = min(1.0, Double(personThreads.count) * 0.35 + Double(sessions.filter { session in
            ["x", "telegram", "slack", "mail", "messages"].contains { session.appName.lowercased().contains($0) }
        }.count) * 0.2)
        let healthScore = min(1.0, Double(sessions.filter { $0.uncertaintyMode != "normal" }.count) * 0.22 + fragmentationScore * 0.25)
        let decisionScore = min(1.0, Double(decisionHints.count + continuityItems.filter { $0.kind == .decision }.count) / 4.0)
        let lifeAdminScore = min(1.0, Double(unfinishedItems.count + continuityItems.filter { $0.kind == .commitment || $0.kind == .blockedItem }.count) / 5.0)

        return [
            ReflectionAttentionSignal(
                id: "fragmentation",
                name: "fragmentation",
                score: fragmentationScore,
                note: "Сколько переключений накопилось в окне."
            ),
            ReflectionAttentionSignal(
                id: "continuity_pressure",
                name: "continuity_pressure",
                score: continuityScore,
                note: "Сколько незакрытых continuity items поднялось в окне."
            ),
            ReflectionAttentionSignal(
                id: "thread_density",
                name: "thread_density",
                score: threadDensityScore,
                note: "Насколько отчётливо видны повторяющиеся нити."
            ),
            ReflectionAttentionSignal(
                id: "expression_pull",
                name: "expression_pull",
                score: expressionScore,
                note: "Насколько день тянет в note/thread/tweet expression."
            ),
            ReflectionAttentionSignal(
                id: "research_pull",
                name: "research_pull",
                score: researchScore,
                note: "Есть ли исследовательская тяга и незакрытые exploratory нити."
            ),
            ReflectionAttentionSignal(
                id: "focus_turbulence",
                name: "focus_turbulence",
                score: focusScore,
                note: "Насколько день сейчас похож на фрагментированный вход-выход."
            ),
            ReflectionAttentionSignal(
                id: "social_pull",
                name: "social_pull",
                score: socialScore,
                note: "Есть ли социальный материал, который может стать signal."
            ),
            ReflectionAttentionSignal(
                id: "health_pressure",
                name: "health_pressure",
                score: healthScore,
                note: "Косвенная нагрузка по ритму и degraded окнам."
            ),
            ReflectionAttentionSignal(
                id: "decision_density",
                name: "decision_density",
                score: decisionScore,
                note: "Сколько решений и развилок требует фиксации."
            ),
            ReflectionAttentionSignal(
                id: "life_admin_pressure",
                name: "life_admin_pressure",
                score: lifeAdminScore,
                note: "Сколько бытовых и административных хвостов просится в мягкую фиксацию."
            )
        ]
    }

    private func focusState(
        triggerKind: AdvisoryTriggerKind,
        sessions: [SessionData]
    ) -> AdvisoryFocusState {
        if triggerKind == .morningResume || triggerKind == .reentryAfterIdle {
            return .idleReturn
        }
        if triggerKind == .focusBreakNatural {
            return .transition
        }

        guard !sessions.isEmpty else {
            return .idleReturn
        }

        let ordered = sessions.sorted { lhs, rhs in lhs.startedAt < rhs.startedAt }
        let totalMinutes = ordered.reduce(0.0) { partial, session in
            partial + Double(session.durationMs) / 60_000.0
        }
        let dominantMinutes = Double(ordered.map(\.durationMs).max() ?? 0) / 60_000.0
        let dominantShare = totalMinutes > 0 ? dominantMinutes / totalMinutes : 0
        let shortSessionCount = ordered.filter { $0.durationMs < 12 * 60_000 }.count
        let degradedCount = ordered.filter { $0.uncertaintyMode != "normal" }.count
        let switchCount = zip(ordered, ordered.dropFirst()).reduce(0) { count, pair in
            let lhs = pair.0
            let rhs = pair.1
            return count + ((lhs.bundleId != rhs.bundleId || lhs.appName != rhs.appName) ? 1 : 0)
        }

        if dominantMinutes >= 80,
           dominantShare >= 0.64,
           ordered.count <= 3,
           switchCount <= 1,
           degradedCount == 0 {
            return .deepWork
        }

        if ordered.count >= 6
            || shortSessionCount >= 4
            || switchCount >= 4
            || degradedCount >= 3
            || (ordered.count >= 4 && totalMinutes > 0 && Double(shortSessionCount) / Double(ordered.count) >= 0.6) {
            return .fragmented
        }

        if ordered.count >= 3
            || switchCount >= 2
            || shortSessionCount >= 2
            || degradedCount >= 1 {
            return .transition
        }

        if totalMinutes <= 18, ordered.count <= 2 {
            return .idleReturn
        }

        return .browsing
    }
}
