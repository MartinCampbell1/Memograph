import Foundation

final class ThreadPacketBuilder {
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
        detail: AdvisoryThreadDetailSnapshot,
        sessions: [SessionData],
        enrichment: ReflectionPacketEnrichment
    ) -> ThreadPacket {
        let thread = ReflectionThreadRef(
            id: detail.thread.id,
            title: detail.thread.displayTitle,
            kind: detail.thread.kind,
            status: detail.thread.status,
            confidence: detail.thread.confidence,
            lastActiveAt: detail.thread.lastActiveAt,
            parentThreadId: detail.thread.parentThreadId,
            totalActiveMinutes: detail.thread.totalActiveMinutes,
            importanceScore: detail.thread.importanceScore,
            summary: detail.thread.summary
        )

        let linkedItems = detail.continuityItems.prefix(8).map {
            ReflectionContinuityItemRef(
                id: $0.id,
                threadId: $0.threadId,
                kind: $0.kind,
                title: $0.title,
                body: $0.body,
                confidence: $0.confidence
            )
        }

        let packetId = AdvisorySupport.stableIdentifier(
            prefix: "advpkt",
            components: [
                AdvisoryPacketKind.thread.rawValue,
                detail.thread.id,
                window.date,
                triggerKind.rawValue
            ]
        )

        let recentEvidence = buildRecentEvidence(
            detail: detail,
            sessions: sessions,
            enrichment: enrichment
        )
        let attentionSignals = buildAttentionSignals(
            detail: detail,
            sessions: sessions,
            linkedItems: Array(linkedItems),
            enrichment: enrichment
        )
        let evidenceRefs = AdvisorySupport.dedupe(
            ["thread:\(detail.thread.id)"]
            + recentEvidence.map(\.evidenceRef)
            + linkedItems.map { "continuity:\($0.id)" }
            + enrichment.bundles.flatMap { $0.items.flatMap(\.evidenceRefs) }
        )
        let confidenceHints: [String: Double] = [
            "thread:\(detail.thread.id)": detail.thread.confidence,
            "expression": attentionSignals.first(where: { $0.name == "expression_pull" })?.score ?? 0,
            "continuity": attentionSignals.first(where: { $0.name == "continuity_pressure" })?.score ?? 0,
            "research": attentionSignals.first(where: { $0.name == "research_pull" })?.score ?? 0,
            "social": attentionSignals.first(where: { $0.name == "social_pull" })?.score ?? 0,
            "decisions": attentionSignals.first(where: { $0.name == "decision_density" })?.score ?? 0,
            "life_admin": attentionSignals.first(where: { $0.name == "life_admin_pressure" })?.score ?? 0
        ]

        return ThreadPacket(
            packetId: packetId,
            packetVersion: "v2.thread.1",
            kind: .thread,
            triggerKind: triggerKind,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: window.date,
                start: dateSupport.isoString(from: window.start),
                end: dateSupport.isoString(from: window.end)
            ),
            thread: thread,
            recentEvidence: recentEvidence,
            linkedItems: Array(linkedItems),
            continuityState: ThreadPacketContinuityState(
                openItemCount: detail.continuityItems.filter { $0.status == .open || $0.status == .stabilizing }.count,
                parkedItemCount: detail.continuityItems.filter { $0.status == .parked }.count,
                resolvedItemCount: detail.continuityItems.filter { $0.status == .resolved }.count,
                suggestedEntryPoint: suggestedEntryPoint(detail: detail, sessions: sessions),
                latestArtifactTitle: detail.artifacts.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }.first?.title
            ),
            attentionSignals: attentionSignals,
            constraints: packetConstraints(),
            language: settings.advisoryPreferredLanguage,
            evidenceRefs: evidenceRefs,
            confidenceHints: confidenceHints,
            accessLevelGranted: settings.advisoryAccessProfile,
            allowedTools: allowedTools(),
            providerConstraints: providerConstraints(),
            enrichment: enrichment
        )
    }

    private func buildRecentEvidence(
        detail: AdvisoryThreadDetailSnapshot,
        sessions: [SessionData],
        enrichment: ReflectionPacketEnrichment
    ) -> [ThreadPacketEvidence] {
        let evidenceRecords = detail.evidence.prefix(6).map { evidence in
            ThreadPacketEvidence(
                id: evidence.id,
                evidenceKind: evidence.evidenceKind,
                evidenceRef: evidence.evidenceRef,
                snippet: nil,
                weight: evidence.weight
            )
        }

        let sessionEvidence = sessions
            .filter { session in
                let haystacks = session.contextTexts + session.windowTitles + [session.appName]
                return haystacks.joined(separator: " ").localizedCaseInsensitiveContains(detail.thread.displayTitle)
            }
            .prefix(3)
            .map { session in
                ThreadPacketEvidence(
                    id: "session-\(session.sessionId)",
                    evidenceKind: "session",
                    evidenceRef: "session:\(session.sessionId)",
                    snippet: AdvisorySupport.bestSnippet(containing: detail.thread.displayTitle, in: session.contextTexts),
                    weight: min(1.0, Double(session.durationMs) / Double(90 * 60_000))
                )
            }

        let enrichmentEvidence = enrichment.bundles
            .filter { $0.availability == .embedded }
            .flatMap { bundle in
                bundle.items.prefix(2).map { item in
                    ThreadPacketEvidence(
                        id: item.id,
                        evidenceKind: bundle.source.rawValue,
                        evidenceRef: item.sourceRef ?? item.evidenceRefs.first ?? "\(bundle.source.rawValue):\(item.id)",
                        snippet: AdvisorySupport.cleanedSnippet(item.snippet, maxLength: 140),
                        weight: min(1.0, 0.34 + item.relevance * 0.5)
                    )
                }
            }

        return Array((evidenceRecords + sessionEvidence + enrichmentEvidence).prefix(8))
    }

    private func suggestedEntryPoint(
        detail: AdvisoryThreadDetailSnapshot,
        sessions: [SessionData]
    ) -> String? {
        if let firstOpen = detail.continuityItems.first(where: { $0.status == .open || $0.status == .stabilizing }) {
            return "Вернуться через «\(firstOpen.title)»."
        }
        if let recentSession = sessions.first(where: { session in
            (session.contextTexts + session.windowTitles).joined(separator: " ")
                .localizedCaseInsensitiveContains(detail.thread.displayTitle)
        }) {
            return "Открыть \(recentSession.windowTitles.first ?? recentSession.appName) и продолжить от последнего тёплого контекста."
        }
        return detail.thread.summary
    }

    private func buildAttentionSignals(
        detail: AdvisoryThreadDetailSnapshot,
        sessions: [SessionData],
        linkedItems: [ReflectionContinuityItemRef],
        enrichment: ReflectionPacketEnrichment
    ) -> [ReflectionAttentionSignal] {
        let continuityPressure = min(1.0, Double(linkedItems.count) / 4.0)
        let noteCount = enrichmentCount(.notes, in: enrichment)
        let calendarCount = enrichmentCount(.calendar, in: enrichment)
        let reminderCount = enrichmentCount(.reminders, in: enrichment)
        let webCount = enrichmentCount(.webResearch, in: enrichment)
        let decisionCount = linkedItems.filter { $0.kind == .decision }.count
        let commitmentCount = linkedItems.filter { $0.kind == .commitment || $0.kind == .blockedItem }.count
        let expressionPull = min(
            1.0,
            0.35
                + min(0.3, detail.thread.importanceScore * 0.35)
                + Double(detail.artifacts.filter { [.tweetSeed, .threadSeed, .noteSeed].contains($0.kind) }.count) * 0.12
                + Double(noteCount + webCount) * 0.06
        )
        let researchPull = detail.thread.kind == .question
            ? min(1.0, 0.72 + Double(webCount) * 0.08)
            : min(1.0, Double(detail.evidence.count) * 0.08 + Double(noteCount + webCount) * 0.1)
        let socialPull = detail.thread.kind == .person ? 0.66 : min(1.0, Double(sessions.filter { session in
            let appName = session.appName.lowercased()
            return ["x", "telegram", "slack", "mail", "messages"].contains { token in
                appName.contains(token)
            }
        }.count) * 0.18 + Double(calendarCount + reminderCount) * 0.08)
        let threadDensity = min(1.0, 0.3 + detail.thread.importanceScore * 0.5)
        let focusTurbulence = min(1.0, max(0, Double(sessions.count - 2)) * 0.18 + Double(reminderCount) * 0.05)
        let decisionDensity = min(1.0, Double(decisionCount) * 0.36 + Double(reminderCount) * 0.12)
        let lifeAdminPressure = min(1.0, Double(commitmentCount) * 0.28 + Double(reminderCount) * 0.18 + Double(calendarCount) * 0.08)
        let healthPressure = min(1.0, focusTurbulence * 0.48 + Double(calendarCount) * 0.06)

        return [
            ReflectionAttentionSignal(id: "thread-expression", name: "expression_pull", score: expressionPull, note: "Нить уже достаточно плотная для expression output."),
            ReflectionAttentionSignal(id: "thread-continuity", name: "continuity_pressure", score: continuityPressure, note: "У нити остаются continuity хвосты и return points."),
            ReflectionAttentionSignal(id: "thread-research", name: "research_pull", score: researchPull, note: "В нити остаётся исследовательская тяга."),
            ReflectionAttentionSignal(id: "thread-social", name: "social_pull", score: socialPull, note: "У нити есть potential public/social signal."),
            ReflectionAttentionSignal(id: "thread-focus", name: "focus_turbulence", score: focusTurbulence, note: "Нить может требовать мягкого re-entry вместо нового фронта."),
            ReflectionAttentionSignal(id: "thread-decisions", name: "decision_density", score: decisionDensity, note: "В нити есть решения или implicit branches, которые стоит закрепить."),
            ReflectionAttentionSignal(id: "thread-life-admin", name: "life_admin_pressure", score: lifeAdminPressure, note: "В нити есть admin tails, commitments или reminders."),
            ReflectionAttentionSignal(id: "thread-health", name: "health_pressure", score: healthPressure, note: "Темп нити может требовать более бережного pacing."),
            ReflectionAttentionSignal(id: "thread-density", name: "thread_density", score: threadDensity, note: "Нить выглядит устойчивой, а не разовой.")
        ]
    }

    private func enrichmentCount(
        _ source: AdvisoryEnrichmentSource,
        in enrichment: ReflectionPacketEnrichment
    ) -> Int {
        enrichment.bundles.first(where: { $0.source == source && $0.availability == .embedded })?.items.count ?? 0
    }

    private func packetConstraints() -> ReflectionPacketConstraints {
        ReflectionPacketConstraints(
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
        )
    }

    private func allowedTools() -> [String] {
        switch settings.advisoryAccessProfile {
        case .conservative:
            return []
        case .balanced:
            return ["timeline.search"]
        case .deepContext:
            return ["timeline.search", "knowledge.lookup"]
        case .fullResearchMode:
            return ["timeline.search", "knowledge.lookup", "mcp.enrichment", "screenshot.bundle"]
        }
    }

    private func providerConstraints() -> [String] {
        AdvisorySupport.dedupe([
            settings.networkAllowed ? "external_cli_remote_allowed" : "external_cli_remote_disabled",
            settings.advisoryAllowMCPEnrichment ? "mcp_optional" : "mcp_disabled",
            settings.advisoryBridgeMode == .stubOnly ? "sidecar_transport_stub_only" : "sidecar_transport_jsonrpc_uds"
        ])
    }
}
