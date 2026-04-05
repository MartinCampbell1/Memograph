import Foundation

final class WeeklyPacketBuilder {
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
        weekDate: String,
        windowStart: Date,
        windowEnd: Date,
        threads: [AdvisoryThreadRecord],
        continuityItems: [ContinuityItemRecord],
        sessions: [SessionData],
        enrichment: ReflectionPacketEnrichment
    ) -> WeeklyPacket {
        let threadRollup = threads.prefix(6).map { thread in
            WeeklyThreadRollup(
                id: thread.id,
                title: thread.displayTitle,
                status: thread.status,
                importanceScore: thread.importanceScore,
                totalActiveMinutes: thread.totalActiveMinutes,
                summary: thread.summary,
                openItemCount: continuityItems.filter {
                    $0.threadId == thread.id && ($0.status == .open || $0.status == .stabilizing)
                }.count,
                artifactCount: thread.lastArtifactAt == nil ? 0 : 1
            )
        }

        let patterns = buildPatterns(
            threads: threads,
            continuityItems: continuityItems,
            sessions: sessions
        )

        let continuityRefs = continuityItems.prefix(8).map { item in
            ReflectionContinuityItemRef(
                id: item.id,
                threadId: item.threadId,
                kind: item.kind,
                title: item.title,
                body: item.body,
                confidence: item.confidence
            )
        }

        let attentionSignals = buildAttentionSignals(
            threadRollup: threadRollup,
            continuityItems: continuityItems,
            sessions: sessions,
            patterns: patterns,
            enrichment: enrichment
        )
        let threadConfidenceHints = threadRollup.map { ("thread:\($0.id)", min(1.0, $0.importanceScore)) }
        let domainConfidenceHints: [(String, Double)] = [
            ("continuity", attentionSignals.first(where: { $0.name == "continuity_pressure" })?.score ?? 0),
            ("expression", attentionSignals.first(where: { $0.name == "expression_pull" })?.score ?? 0),
            ("research", attentionSignals.first(where: { $0.name == "research_pull" })?.score ?? 0),
            ("social", attentionSignals.first(where: { $0.name == "social_pull" })?.score ?? 0),
            ("decisions", attentionSignals.first(where: { $0.name == "decision_density" })?.score ?? 0),
            ("life_admin", attentionSignals.first(where: { $0.name == "life_admin_pressure" })?.score ?? 0)
        ]
        let evidenceRefs = AdvisorySupport.dedupe(
            threadRollup.map { "thread:\($0.id)" }
            + continuityRefs.map { "continuity:\($0.id)" }
            + patterns.map { "pattern:\($0.id)" }
            + enrichment.bundles.flatMap { $0.items.flatMap(\.evidenceRefs) }
        )

        let packetId = AdvisorySupport.stableIdentifier(
            prefix: "advpkt",
            components: [
                AdvisoryPacketKind.weekly.rawValue,
                weekDate,
                triggerKind.rawValue,
                threadRollup.map(\.id).joined(separator: ",")
            ]
        )

        return WeeklyPacket(
            packetId: packetId,
            packetVersion: "v2.weekly.1",
            kind: .weekly,
            triggerKind: triggerKind,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: weekDate,
                start: dateSupport.isoString(from: windowStart),
                end: dateSupport.isoString(from: windowEnd)
            ),
            threadRollup: threadRollup,
            patterns: patterns,
            continuityItems: continuityRefs,
            attentionSignals: attentionSignals,
            constraints: packetConstraints(),
            language: settings.advisoryPreferredLanguage,
            evidenceRefs: evidenceRefs,
            confidenceHints: Dictionary(uniqueKeysWithValues: threadConfidenceHints + domainConfidenceHints),
            accessLevelGranted: settings.advisoryAccessProfile,
            allowedTools: allowedTools(),
            providerConstraints: providerConstraints(),
            enrichment: enrichment
        )
    }

    private func buildPatterns(
        threads: [AdvisoryThreadRecord],
        continuityItems: [ContinuityItemRecord],
        sessions: [SessionData]
    ) -> [WeeklyPattern] {
        var patterns: [WeeklyPattern] = []
        if continuityItems.count >= 3 {
            patterns.append(
                WeeklyPattern(
                    id: "continuity-pressure",
                    title: "Continuity pressure kept resurfacing",
                    summary: "За неделю накопилось несколько return points и open loops, значит Weekly Review может снизить стоимость входа в понедельник.",
                    confidence: min(0.92, Double(continuityItems.count) / 5.0)
                )
            )
        }
        if sessions.count >= 8 {
            patterns.append(
                WeeklyPattern(
                    id: "fragmentation-pattern",
                    title: "Fragmentation stayed visible",
                    summary: "Неделя выглядит более switch-heavy, чем хотелось бы; лучше завершить её через ясные anchors, а не через новые ветки.",
                    confidence: min(0.86, Double(sessions.count) / 14.0)
                )
            )
        }
        if threads.filter({ $0.status == .active || $0.status == .stalled }).count >= 3 {
            patterns.append(
                WeeklyPattern(
                    id: "thread-cluster",
                    title: "A few threads carried most of the week",
                    summary: "Несколько устойчивых нитей тянули неделю через разные дни и окна, так что weekly synthesis уже grounded.",
                    confidence: 0.78
                )
            )
        }
        if patterns.isEmpty {
            patterns.append(
                WeeklyPattern(
                    id: "light-week",
                    title: "The week still has one continuity center",
                    summary: "Даже если неделя была спокойнее, уже видно хотя бы одну нить, вокруг которой полезно собрать ясный weekly anchor.",
                    confidence: 0.58
                )
            )
        }
        return Array(patterns.prefix(3))
    }

    private func buildAttentionSignals(
        threadRollup: [WeeklyThreadRollup],
        continuityItems: [ContinuityItemRecord],
        sessions: [SessionData],
        patterns: [WeeklyPattern],
        enrichment: ReflectionPacketEnrichment
    ) -> [ReflectionAttentionSignal] {
        let noteCount = enrichmentCount(.notes, in: enrichment)
        let calendarCount = enrichmentCount(.calendar, in: enrichment)
        let reminderCount = enrichmentCount(.reminders, in: enrichment)
        let webCount = enrichmentCount(.webResearch, in: enrichment)
        let decisionCount = continuityItems.filter { $0.kind == .decision }.count
        let commitmentCount = continuityItems.filter { $0.kind == .commitment || $0.kind == .blockedItem }.count
        let continuityPressure = min(1.0, Double(continuityItems.count) / 5.0)
        let threadDensity = min(1.0, Double(threadRollup.count) / 4.0)
        let focusTurbulence = min(1.0, Double(max(0, sessions.count - 4)) / 10.0)
        let expressionPull = min(
            1.0,
            Double(patterns.count) * 0.2
                + Double(threadRollup.filter { $0.importanceScore >= 0.7 }.count) * 0.18
                + Double(noteCount + webCount) * 0.05
        )
        let researchPull = min(1.0, Double(webCount) * 0.22 + Double(noteCount) * 0.1 + Double(patterns.count) * 0.08)
        let socialPull = min(1.0, Double(calendarCount + reminderCount) * 0.12 + Double(webCount) * 0.08)
        let decisionDensity = min(1.0, Double(decisionCount) * 0.28 + Double(reminderCount) * 0.12 + Double(patterns.count) * 0.05)
        let lifeAdminPressure = min(1.0, Double(commitmentCount) * 0.26 + Double(reminderCount) * 0.18 + Double(calendarCount) * 0.08)
        let healthPressure = min(1.0, focusTurbulence * 0.52 + Double(calendarCount) * 0.08)

        return [
            ReflectionAttentionSignal(id: "weekly-continuity", name: "continuity_pressure", score: continuityPressure, note: "Week-level continuity pressure across open loops."),
            ReflectionAttentionSignal(id: "weekly-thread-density", name: "thread_density", score: threadDensity, note: "How many threads carried the week in a durable way."),
            ReflectionAttentionSignal(id: "weekly-focus", name: "focus_turbulence", score: focusTurbulence, note: "Week-level turbulence and re-entry cost."),
            ReflectionAttentionSignal(id: "weekly-expression", name: "expression_pull", score: expressionPull, note: "Whether the week already wants a compact synthesis."),
            ReflectionAttentionSignal(id: "weekly-research", name: "research_pull", score: researchPull, note: "Whether the week accumulated enough research material to deserve synthesis."),
            ReflectionAttentionSignal(id: "weekly-social", name: "social_pull", score: socialPull, note: "Whether the week contains outward-facing contact or social follow-up opportunities."),
            ReflectionAttentionSignal(id: "weekly-decisions", name: "decision_density", score: decisionDensity, note: "Whether the week contains decisions worth fixing explicitly."),
            ReflectionAttentionSignal(id: "weekly-life-admin", name: "life_admin_pressure", score: lifeAdminPressure, note: "Whether the week left visible admin tails or commitments."),
            ReflectionAttentionSignal(id: "weekly-health", name: "health_pressure", score: healthPressure, note: "Whether the week rhythm suggests a gentler re-entry path.")
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
