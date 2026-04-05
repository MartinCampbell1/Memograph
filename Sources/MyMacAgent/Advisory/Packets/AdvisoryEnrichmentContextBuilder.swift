import Foundation

final class AdvisoryEnrichmentContextBuilder {
    private let db: DatabaseManager
    private let settings: AppSettings
    private let dateSupport: LocalDateSupport
    private let fallbackProviders: [AdvisoryEnrichmentSource: any AdvisoryExternalEnrichmentProviding]
    private let connectorProviders: [AdvisoryEnrichmentSource: [any AdvisoryExternalEnrichmentProviding]]

    init(
        db: DatabaseManager,
        settings: AppSettings = AppSettings(),
        timeZone: TimeZone = .autoupdatingCurrent,
        externalProviders: [AdvisoryEnrichmentSource: any AdvisoryExternalEnrichmentProviding]? = nil,
        connectorProviders: [AdvisoryEnrichmentSource: [any AdvisoryExternalEnrichmentProviding]]? = nil
    ) {
        self.db = db
        self.settings = settings
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.fallbackProviders = externalProviders ?? [
            .calendar: AdvisoryCalendarEnrichmentProvider(),
            .reminders: AdvisoryRemindersEnrichmentProvider(),
            .webResearch: AdvisoryWebResearchEnrichmentProvider(db: db, timeZone: timeZone),
            .wearable: AdvisoryRhythmEnrichmentProvider(timeZone: timeZone)
        ]
        self.connectorProviders = connectorProviders ?? [:]
    }

    func buildReflectionEnrichment(
        window: SummaryWindowDescriptor,
        summary: DailySummaryRecord?,
        threads: [AdvisoryThreadRecord],
        sessions: [SessionData]
    ) throws -> ReflectionPacketEnrichment {
        let keywords = buildReflectionKeywords(
            window: window,
            summary: summary,
            threads: threads,
            sessions: sessions
        )
        return try buildPacketEnrichment(
            window: window,
            summary: summary,
            threads: threads,
            sessions: sessions,
            keywords: keywords
        )
    }

    func buildThreadEnrichment(
        window: SummaryWindowDescriptor,
        detail: AdvisoryThreadDetailSnapshot,
        sessions: [SessionData]
    ) throws -> ReflectionPacketEnrichment {
        let keywords = buildThreadKeywords(
            window: window,
            detail: detail,
            sessions: sessions
        )
        return try buildPacketEnrichment(
            window: window,
            summary: nil,
            threads: [detail.thread] + detail.childThreads,
            sessions: sessions,
            keywords: keywords
        )
    }

    func buildWeeklyEnrichment(
        window: SummaryWindowDescriptor,
        threads: [AdvisoryThreadRecord],
        continuityItems: [ContinuityItemRecord],
        sessions: [SessionData]
    ) throws -> ReflectionPacketEnrichment {
        let keywords = buildWeeklyKeywords(
            window: window,
            threads: threads,
            continuityItems: continuityItems,
            sessions: sessions
        )
        return try buildPacketEnrichment(
            window: window,
            summary: nil,
            threads: threads,
            sessions: sessions,
            keywords: keywords
        )
    }

    private func buildPacketEnrichment(
        window: SummaryWindowDescriptor,
        summary: DailySummaryRecord?,
        threads: [AdvisoryThreadRecord],
        sessions: [SessionData],
        keywords: [String]
    ) throws -> ReflectionPacketEnrichment {
        let notesBundle = try buildNotesBundle(
            window: window,
            summary: summary,
            keywords: keywords
        )
        let context = AdvisoryEnrichmentBuildContext(
            window: window,
            summary: summary,
            threads: threads,
            sessions: sessions,
            keywords: keywords,
            settings: settings,
            dateSupport: dateSupport,
            db: db
        )

        return ReflectionPacketEnrichment(
            phase: settings.advisoryEnrichmentPhase,
            bundles: [
                notesBundle,
                buildExternalBundle(for: .calendar, context: context),
                buildExternalBundle(for: .reminders, context: context),
                buildExternalBundle(for: .webResearch, context: context),
                buildExternalBundle(for: .wearable, context: context)
            ]
        )
    }

    private func buildNotesBundle(
        window: SummaryWindowDescriptor,
        summary: DailySummaryRecord?,
        keywords: [String]
    ) throws -> ReflectionEnrichmentBundle {
        let canEmbedStructured = settings.advisoryAccessProfile == .deepContext
            || settings.advisoryAccessProfile == .fullResearchMode
        guard canEmbedStructured else {
            return ReflectionEnrichmentBundle(
                id: AdvisoryEnrichmentSource.notes.rawValue,
                source: .notes,
                tier: .l2Structured,
                availability: .deferred,
                runtimeKind: .memographDerived,
                providerLabel: "Memograph Notes",
                note: "Structured note context withheld by current advisory access profile.",
                items: []
            )
        }

        let suggestedNoteItems = buildSuggestedNoteItems(summary: summary, keywords: keywords)
        let knowledgeItems = try buildKnowledgeNoteItems(window: window, keywords: keywords)
        let items = Array((suggestedNoteItems + knowledgeItems).prefix(4))

        let note = items.isEmpty
            ? "Memograph structured notes are allowed, but there are no relevant note excerpts yet."
            : "Memograph-derived note fragments attached as L2 structured context."

        return ReflectionEnrichmentBundle(
            id: AdvisoryEnrichmentSource.notes.rawValue,
            source: .notes,
            tier: .l2Structured,
            availability: .embedded,
            runtimeKind: .memographDerived,
            providerLabel: "Memograph Notes",
            note: note,
            items: items
        )
    }

    private func buildSuggestedNoteItems(
        summary: DailySummaryRecord?,
        keywords: [String]
    ) -> [ReflectionEnrichmentItem] {
        let suggestions = AdvisorySupport.decodeStringArray(from: summary?.suggestedNotesJson)
        return suggestions.prefix(2).map { title in
            ReflectionEnrichmentItem(
                id: AdvisorySupport.stableIdentifier(
                    prefix: "advnote",
                    components: ["suggested", summary?.date ?? "", title]
                ),
                source: .notes,
                title: title,
                snippet: "Suggested note from Memograph daily summary.",
                relevance: noteRelevance(title: title, body: title, keywords: keywords),
                evidenceRefs: ["summary:\(summary?.date ?? "unknown")"],
                sourceRef: (summary?.date).map { "daily_summary:\($0)" }
            )
        }
    }

    private func buildKnowledgeNoteItems(
        window: SummaryWindowDescriptor,
        keywords: [String]
    ) throws -> [ReflectionEnrichmentItem] {
        let rows = try db.query("""
            SELECT *
            FROM knowledge_notes
            WHERE source_date IS NULL OR source_date <= ?
            ORDER BY COALESCE(source_date, '') DESC, COALESCE(created_at, '') DESC
            LIMIT 18
        """, params: [.text(window.date)])
        let notes = rows.compactMap(KnowledgeNoteRecord.init(row:))

        let ranked = notes
            .map { note -> (KnowledgeNoteRecord, Double) in
                let relevance = noteRelevance(
                    title: note.title,
                    body: note.bodyMarkdown,
                    keywords: keywords
                )
                return (note, relevance)
            }
            .filter { note, relevance in
                relevance > 0 || note.sourceDate == window.date
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return (lhs.0.sourceDate ?? "") > (rhs.0.sourceDate ?? "")
                }
                return lhs.1 > rhs.1
            }

        return ranked.prefix(3).map { note, relevance in
            ReflectionEnrichmentItem(
                id: AdvisorySupport.stableIdentifier(
                    prefix: "advnote",
                    components: ["knowledge", note.id, note.title]
                ),
                source: .notes,
                title: note.title,
                snippet: AdvisorySupport.cleanedSnippet(note.bodyMarkdown, maxLength: 180),
                relevance: relevance,
                evidenceRefs: ["knowledge_note:\(note.id)"],
                sourceRef: "knowledge_note:\(note.id)"
            )
        }
    }

    private func noteRelevance(
        title: String,
        body: String,
        keywords: [String]
    ) -> Double {
        let haystack = "\(title) \(body)".lowercased()
        var score = 0.0
        for keyword in keywords.prefix(10) {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3 else { continue }
            let lowered = trimmed.lowercased()
            if haystack.contains(lowered) {
                score += title.lowercased().contains(lowered) ? 0.45 : 0.24
            }
        }
        return min(1.0, score)
    }

    private func placeholderBundle(
        for source: AdvisoryEnrichmentSource
    ) -> ReflectionEnrichmentBundle {
        let availability: AdvisoryEnrichmentAvailability
        let note: String

        switch source {
        case .notes:
            availability = .embedded
            note = "Memograph-derived note context."
        case .calendar, .reminders, .webResearch, .wearable:
            if !settings.advisoryAllowMCPEnrichment {
                availability = .disabled
                note = "Read-only external enrichment disabled in settings."
            } else if !settings.advisoryEnrichmentPhase.supports(source) {
                availability = .deferred
                note = "\(source.label) enrichment stays staged until \(source.minimumPhase.label)."
            } else if !settings.advisoryEnrichmentSourceEnabled(source) {
                availability = .disabled
                note = "\(source.label) enrichment disabled for this rollout in settings."
            } else {
                availability = .unavailable
                note = "No live provider is configured for \(source.label)."
            }
        }

        let tier: AdvisoryEvidenceTier = source == .wearable ? .l3Rich : .l2Structured
        return ReflectionEnrichmentBundle(
            id: source.rawValue,
            source: source,
            tier: tier,
            availability: availability,
            runtimeKind: source == .notes ? .memographDerived : .stagedPlaceholder,
            providerLabel: source == .notes ? "Memograph Notes" : source.label,
            note: note,
            items: []
        )
    }

    private func buildReflectionKeywords(
        window: SummaryWindowDescriptor,
        summary: DailySummaryRecord?,
        threads: [AdvisoryThreadRecord],
        sessions: [SessionData]
    ) -> [String] {
        let threadKeywords = threads.map(\.displayTitle)
        let topicKeywords = AdvisorySupport.decodeStringArray(from: summary?.topTopicsJson)
        let suggestedNoteKeywords = summary.map { AdvisorySupport.decodeStringArray(from: $0.suggestedNotesJson) } ?? []
        let sessionKeywords = sessions.flatMap { [$0.appName] + $0.windowTitles }
        let summaryKeywords = summary?.summaryText.map { derivedKeywords(from: $0, limit: 6) } ?? []
        return AdvisorySupport.dedupe(
            [window.date] + threadKeywords + topicKeywords + suggestedNoteKeywords + sessionKeywords + summaryKeywords
        )
    }

    private func buildThreadKeywords(
        window: SummaryWindowDescriptor,
        detail: AdvisoryThreadDetailSnapshot,
        sessions: [SessionData]
    ) -> [String] {
        let threadKeywords = [
            detail.thread.displayTitle,
            detail.thread.summary ?? "",
            detail.parentThread?.displayTitle ?? ""
        ]
        let continuityKeywords = detail.continuityItems.flatMap { [$0.title, $0.body ?? ""] }
        let artifactKeywords = detail.artifacts.flatMap { [$0.title, AdvisorySupport.cleanedSnippet($0.body, maxLength: 120)] }
        let childKeywords = detail.childThreads.map(\.displayTitle)
        let evidenceKeywords = detail.evidence.flatMap { [$0.evidenceKind, $0.evidenceRef] }
        let sessionKeywords = sessions.flatMap { [$0.appName] + $0.windowTitles + Array($0.contextTexts.prefix(2)) }
        let derived = derivedKeywords(
            from: ([detail.thread.summary, detail.thread.displayTitle] + detail.continuityItems.map(\.title))
                .compactMap { $0 }
                .joined(separator: " "),
            limit: 8
        )
        return AdvisorySupport.dedupe(
            [window.date]
            + threadKeywords
            + continuityKeywords
            + artifactKeywords
            + childKeywords
            + evidenceKeywords
            + sessionKeywords
            + derived
        )
    }

    private func buildWeeklyKeywords(
        window: SummaryWindowDescriptor,
        threads: [AdvisoryThreadRecord],
        continuityItems: [ContinuityItemRecord],
        sessions: [SessionData]
    ) -> [String] {
        let threadKeywords = threads.prefix(6).flatMap { [$0.displayTitle, $0.summary ?? ""] }
        let continuityKeywords = continuityItems.prefix(10).flatMap { [$0.title, $0.body ?? ""] }
        let sessionKeywords = sessions.flatMap { [$0.appName] + $0.windowTitles }
        let derived = derivedKeywords(
            from: (
                threads.prefix(4).compactMap(\.summary)
                + continuityItems.prefix(4).map(\.title)
            ).joined(separator: " "),
            limit: 10
        )
        return AdvisorySupport.dedupe(
            [window.date] + threadKeywords + continuityKeywords + sessionKeywords + derived
        )
    }

    private func buildExternalBundle(
        for source: AdvisoryEnrichmentSource,
        context: AdvisoryEnrichmentBuildContext
    ) -> ReflectionEnrichmentBundle {
        guard source != .notes else {
            return placeholderBundle(for: .notes)
        }
        guard sourceEnabled(source) else {
            return placeholderBundle(for: source)
        }
        let providers = resolvedProviders(for: source)
        guard !providers.isEmpty else {
            return ReflectionEnrichmentBundle(
                id: source.rawValue,
                source: source,
                tier: source == .wearable ? .l3Rich : .l2Structured,
                availability: .unavailable,
                runtimeKind: .stagedPlaceholder,
                providerLabel: source.label,
                note: "No provider is configured for \(source.rawValue) enrichment.",
                items: []
            )
        }

        var failures: [String] = []
        for (index, provider) in providers.enumerated() {
            do {
                let bundle = try provider.buildBundle(context: context)
                if bundle.availability == .embedded || index == providers.count - 1 {
                    return bundleFrom(
                        bundle,
                        provider: provider,
                        isFallback: index > 0,
                        failures: failures
                    )
                }
                failures.append("\(provider.providerLabel): \(bundle.note)")
            } catch {
                failures.append("\(provider.providerLabel): \(error.localizedDescription)")
            }
        }

        return ReflectionEnrichmentBundle(
            id: source.rawValue,
            source: source,
            tier: source == .wearable ? .l3Rich : .l2Structured,
            availability: .unavailable,
            runtimeKind: providers.first?.runtimeKind ?? .stagedPlaceholder,
            providerLabel: providers.first?.providerLabel ?? source.label,
            note: failures.isEmpty
                ? "Enrichment provider is unavailable."
                : "All enrichment providers failed or stayed unavailable. " + failures.joined(separator: " | "),
            items: []
        )
    }

    private func resolvedProviders(
        for source: AdvisoryEnrichmentSource
    ) -> [any AdvisoryExternalEnrichmentProviding] {
        let connectors = connectorProviders[source] ?? []
        let fallback = fallbackProviders[source].map { [$0] } ?? []
        return connectors + fallback
    }

    private func bundleFrom(
        _ bundle: ReflectionEnrichmentBundle,
        provider: any AdvisoryExternalEnrichmentProviding,
        isFallback: Bool,
        failures: [String]
    ) -> ReflectionEnrichmentBundle {
        let runtimeKind = bundle.runtimeKind
        let providerLabel = bundle.providerLabel
        let prefix: String
        if isFallback, !failures.isEmpty {
            prefix = "Primary connector unavailable, used fallback \(providerLabel). "
        } else {
            prefix = ""
        }
        return ReflectionEnrichmentBundle(
            id: bundle.id,
            source: bundle.source,
            tier: bundle.tier,
            availability: bundle.availability,
            runtimeKind: runtimeKind,
            providerLabel: providerLabel,
            isFallback: isFallback,
            note: prefix + bundle.note,
            items: bundle.items
        )
    }

    private func sourceEnabled(_ source: AdvisoryEnrichmentSource) -> Bool {
        settings.advisoryEnrichmentSourceEnabled(source)
    }

    private func derivedKeywords(
        from text: String,
        limit: Int
    ) -> [String] {
        let tokens = text
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }
        return Array(AdvisorySupport.dedupe(tokens).prefix(max(1, limit)))
    }
}
