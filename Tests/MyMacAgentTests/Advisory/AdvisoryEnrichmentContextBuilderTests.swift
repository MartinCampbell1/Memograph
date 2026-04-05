import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryEnrichmentContextBuilderTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    @Test("Phase 2 embeds staged external bundles from configured providers")
    func phase2EmbedsConfiguredProviders() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_enrichment_builder_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryAllowMCPEnrichment = true
        settings.advisoryEnrichmentPhase = .phase2ReadOnly

        let builder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: StubProvider(bundle: makeBundle(source: .calendar, title: "Architecture Review")),
                .reminders: StubProvider(bundle: makeBundle(source: .reminders, title: "Ping design partner")),
                .webResearch: StubProvider(bundle: makeBundle(source: .webResearch, title: "Attention market notes"))
            ]
        )

        let enrichment = try builder.buildReflectionEnrichment(
            window: makeWindow(),
            summary: DailySummaryRecord(
                date: "2026-04-04",
                summaryText: "Worked on Memograph advisory attention market.",
                topAppsJson: nil,
                topTopicsJson: #"["Memograph","advisory"]"#,
                aiSessionsJson: nil,
                contextSwitchesJson: nil,
                unfinishedItemsJson: nil,
                suggestedNotesJson: nil,
                generatedAt: nil,
                modelName: nil,
                tokenUsageInput: 0,
                tokenUsageOutput: 0,
                generationStatus: nil
            ),
            threads: [],
            sessions: []
        )

        let calendar = try #require(enrichment.bundles.first(where: { $0.source == .calendar }))
        let reminders = try #require(enrichment.bundles.first(where: { $0.source == .reminders }))
        let web = try #require(enrichment.bundles.first(where: { $0.source == .webResearch }))

        #expect(calendar.availability == .embedded)
        #expect(reminders.availability == .embedded)
        #expect(web.availability == .embedded)
        #expect(calendar.items.first?.title == "Architecture Review")
        #expect(reminders.items.first?.title == "Ping design partner")
        #expect(web.items.first?.title == "Attention market notes")
    }

    @Test("Phase 1 keeps external enrichers deferred and does not invoke providers")
    func phase1KeepsExternalProvidersDeferred() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_enrichment_builder_phase1_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryAllowMCPEnrichment = true
        settings.advisoryEnrichmentPhase = .phase1Memograph

        let calendar = CountingProvider(source: .calendar, bundle: makeBundle(source: .calendar, title: "Should not be called"))
        let reminders = CountingProvider(source: .reminders, bundle: makeBundle(source: .reminders, title: "Should not be called"))
        let web = CountingProvider(source: .webResearch, bundle: makeBundle(source: .webResearch, title: "Should not be called"))

        let builder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: calendar,
                .reminders: reminders,
                .webResearch: web
            ]
        )

        let enrichment = try builder.buildReflectionEnrichment(
            window: makeWindow(),
            summary: nil,
            threads: [],
            sessions: []
        )

        #expect(enrichment.bundles.first(where: { $0.source == .calendar })?.availability == .deferred)
        #expect(enrichment.bundles.first(where: { $0.source == .reminders })?.availability == .deferred)
        #expect(enrichment.bundles.first(where: { $0.source == .webResearch })?.availability == .deferred)
        #expect(calendar.invocations == 0)
        #expect(reminders.invocations == 0)
        #expect(web.invocations == 0)
    }

    @Test("Web research provider harvests browser context and ignores non-browser snapshots")
    func webProviderUsesBrowserContext() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO apps (bundle_id, app_name)
            VALUES (?, ?), (?, ?)
        """, params: [
            .text("com.apple.Safari"), .text("Safari"),
            .text("com.openai.codex"), .text("Codex")
        ])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-browser"), .integer(1), .text("2026-04-04T09:00:00Z"), .text("2026-04-04T09:20:00Z"), .integer(1_200_000), .text("normal"),
            .text("sess-code"), .integer(2), .text("2026-04-04T09:05:00Z"), .text("2026-04-04T09:25:00Z"), .integer(1_200_000), .text("normal")
        ])
        try db.execute("""
            INSERT INTO context_snapshots
                (id, session_id, timestamp, app_name, bundle_id, window_title, text_source, merged_text, topic_hint, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-browser"),
            .text("sess-browser"),
            .text("2026-04-04T09:10:00Z"),
            .text("Safari"),
            .text("com.apple.Safari"),
            .text("Attention Market Research"),
            .text("ax+ocr"),
            .text("Studying attention market and category-aware balancing."),
            .text("research"),
            .real(0.92),
            .real(0.08),
            .text("ctx-code"),
            .text("sess-code"),
            .text("2026-04-04T09:12:00Z"),
            .text("Codex"),
            .text("com.openai.codex"),
            .text("AdvisoryBridgeClient.swift"),
            .text("ax+ocr"),
            .text("Implementing weekly review flow."),
            .text("coding"),
            .real(0.95),
            .real(0.05)
        ])

        let defaults = UserDefaults(suiteName: "advisory_web_provider_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryAllowMCPEnrichment = true
        settings.advisoryEnrichmentPhase = .phase2ReadOnly

        let context = AdvisoryEnrichmentBuildContext(
            window: makeWindow(),
            summary: nil,
            threads: [],
            sessions: [],
            keywords: ["attention", "market"],
            settings: settings,
            dateSupport: LocalDateSupport(timeZone: utc),
            db: db
        )
        let provider = AdvisoryWebResearchEnrichmentProvider(db: db, timeZone: utc)
        let bundle = try provider.buildBundle(context: context)

        #expect(bundle.availability == .embedded)
        #expect(bundle.items.count == 1)
        #expect(bundle.items.first?.title == "Attention Market Research")
        #expect(bundle.items.first?.evidenceRefs.contains("context_snapshot:ctx-browser") == true)
    }

    @Test("Rhythm provider surfaces health-derived work patterns without device telemetry")
    func rhythmProviderBuildsHealthDerivedSignals() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_rhythm_provider_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryAllowMCPEnrichment = true
        settings.advisoryEnrichmentPhase = .phase3Expanded

        let context = AdvisoryEnrichmentBuildContext(
            window: makeWindow(),
            summary: nil,
            threads: [],
            sessions: [
                SessionData(
                    sessionId: "sess-1",
                    appName: "Safari",
                    bundleId: "com.apple.Safari",
                    windowTitles: ["Docs"],
                    startedAt: "2026-04-04T08:00:00Z",
                    endedAt: "2026-04-04T08:08:00Z",
                    durationMs: 8 * 60_000,
                    uncertaintyMode: "normal",
                    contextTexts: ["docs"]
                ),
                SessionData(
                    sessionId: "sess-2",
                    appName: "Telegram",
                    bundleId: "ru.keepcoder.Telegram",
                    windowTitles: ["Chat"],
                    startedAt: "2026-04-04T08:08:00Z",
                    endedAt: "2026-04-04T08:15:00Z",
                    durationMs: 7 * 60_000,
                    uncertaintyMode: "degraded",
                    contextTexts: ["chat"]
                ),
                SessionData(
                    sessionId: "sess-3",
                    appName: "Mail",
                    bundleId: "com.apple.mail",
                    windowTitles: ["Inbox"],
                    startedAt: "2026-04-04T08:15:00Z",
                    endedAt: "2026-04-04T08:22:00Z",
                    durationMs: 7 * 60_000,
                    uncertaintyMode: "normal",
                    contextTexts: ["mail"]
                ),
                SessionData(
                    sessionId: "sess-4",
                    appName: "Finder",
                    bundleId: "com.apple.finder",
                    windowTitles: ["Files"],
                    startedAt: "2026-04-04T08:22:00Z",
                    endedAt: "2026-04-04T08:30:00Z",
                    durationMs: 8 * 60_000,
                    uncertaintyMode: "degraded",
                    contextTexts: ["files"]
                ),
                SessionData(
                    sessionId: "sess-5",
                    appName: "Codex",
                    bundleId: "com.openai.codex",
                    windowTitles: ["Repo"],
                    startedAt: "2026-04-04T20:30:00Z",
                    endedAt: "2026-04-04T22:05:00Z",
                    durationMs: 95 * 60_000,
                    uncertaintyMode: "normal",
                    contextTexts: ["repo"]
                )
            ],
            keywords: ["attention", "market"],
            settings: settings,
            dateSupport: LocalDateSupport(timeZone: utc),
            db: db
        )

        let provider = AdvisoryRhythmEnrichmentProvider(timeZone: utc)
        let bundle = try provider.buildBundle(context: context)

        #expect(bundle.availability == .embedded)
        #expect(bundle.tier == .l3Rich)
        #expect(bundle.note.contains("No wearable device telemetry") || bundle.note.contains("No wearable device telemetry is included"))
        #expect(bundle.items.contains(where: { $0.title == "Fragmented work blocks" }))
        #expect(bundle.items.contains(where: { $0.title == "Late work stretch" }))
    }

    @Test("Connector-backed provider wins before local fallback and exposes provenance")
    func connectorBackedProviderWinsBeforeFallback() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_connector_wins_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryAllowMCPEnrichment = true
        settings.advisoryEnrichmentPhase = .phase2ReadOnly

        let fallback = CountingProvider(
            source: .webResearch,
            bundle: makeBundle(
                source: .webResearch,
                title: "Timeline fallback",
                runtimeKind: .timelineDerived,
                providerLabel: "Timeline Browser Context"
            )
        )
        let connector = StubProvider(
            bundle: makeBundle(
                source: .webResearch,
                title: "Connector search result",
                runtimeKind: .connectorBacked,
                providerLabel: "Search Connector"
            )
        )

        let builder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [.webResearch: fallback],
            connectorProviders: [.webResearch: [connector]]
        )

        let enrichment = try builder.buildReflectionEnrichment(
            window: makeWindow(),
            summary: nil,
            threads: [],
            sessions: []
        )
        let web = try #require(enrichment.bundles.first(where: { $0.source == .webResearch }))

        #expect(web.availability == .embedded)
        #expect(web.items.first?.title == "Connector search result")
        #expect(web.runtimeKind == .connectorBacked)
        #expect(web.providerLabel == "Search Connector")
        #expect(!web.isFallback)
        #expect(fallback.invocations == 0)
    }

    @Test("Connector failure falls back to local provider and marks bundle as fallback")
    func connectorFailureFallsBackToLocalProvider() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_connector_fallback_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryAllowMCPEnrichment = true
        settings.advisoryEnrichmentPhase = .phase2ReadOnly

        let fallback = CountingProvider(
            source: .calendar,
            bundle: makeBundle(
                source: .calendar,
                title: "Local event",
                runtimeKind: .localConnector,
                providerLabel: "EventKit"
            )
        )
        let connector = FailingProvider(source: .calendar, message: "Search session expired")

        let builder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [.calendar: fallback],
            connectorProviders: [.calendar: [connector]]
        )

        let enrichment = try builder.buildReflectionEnrichment(
            window: makeWindow(),
            summary: nil,
            threads: [],
            sessions: []
        )
        let calendar = try #require(enrichment.bundles.first(where: { $0.source == .calendar }))

        #expect(calendar.availability == .embedded)
        #expect(calendar.runtimeKind == .localConnector)
        #expect(calendar.providerLabel == "EventKit")
        #expect(calendar.isFallback)
        #expect(calendar.note.contains("fallback"))
        #expect(fallback.invocations == 1)
    }

    @Test("Source-level toggle disables a source even when phase allows it")
    func sourceLevelToggleDisablesSource() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_source_toggle_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryAllowMCPEnrichment = true
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryWebResearchEnrichmentEnabled = false

        let web = CountingProvider(
            source: .webResearch,
            bundle: makeBundle(source: .webResearch, title: "Should stay disabled")
        )
        let builder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [.webResearch: web]
        )

        let enrichment = try builder.buildReflectionEnrichment(
            window: makeWindow(),
            summary: nil,
            threads: [],
            sessions: []
        )
        let webBundle = try #require(enrichment.bundles.first(where: { $0.source == .webResearch }))

        #expect(webBundle.availability == .disabled)
        #expect(webBundle.runtimeKind == .stagedPlaceholder)
        #expect(web.invocations == 0)
    }

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "advisory_enrichment_context_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V005_KnowledgeGraph.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    private func makeWindow() -> SummaryWindowDescriptor {
        SummaryWindowDescriptor(
            date: "2026-04-04",
            start: ISO8601DateFormatter().date(from: "2026-04-04T08:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-04T10:00:00Z")!
        )
    }

    private func makeBundle(
        source: AdvisoryEnrichmentSource,
        title: String,
        runtimeKind: AdvisoryEnrichmentRuntimeKind = .connectorBacked,
        providerLabel: String? = nil
    ) -> ReflectionEnrichmentBundle {
        ReflectionEnrichmentBundle(
            id: source.rawValue,
            source: source,
            tier: .l2Structured,
            availability: .embedded,
            runtimeKind: runtimeKind,
            providerLabel: providerLabel,
            note: "Stubbed bundle for \(source.rawValue).",
            items: [
                ReflectionEnrichmentItem(
                    id: "item-\(source.rawValue)",
                    source: source,
                    title: title,
                    snippet: "Stub snippet",
                    relevance: 0.9,
                    evidenceRefs: ["\(source.rawValue):stub"],
                    sourceRef: "\(source.rawValue):stub"
                )
            ]
        )
    }
}

private struct StubProvider: AdvisoryExternalEnrichmentProviding {
    let bundle: ReflectionEnrichmentBundle
    var source: AdvisoryEnrichmentSource { bundle.source }

    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle {
        bundle
    }
}

private final class CountingProvider: AdvisoryExternalEnrichmentProviding {
    let source: AdvisoryEnrichmentSource
    let bundle: ReflectionEnrichmentBundle
    private(set) var invocations = 0

    init(source: AdvisoryEnrichmentSource, bundle: ReflectionEnrichmentBundle) {
        self.source = source
        self.bundle = bundle
    }

    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle {
        invocations += 1
        return bundle
    }
}

private struct FailingProvider: AdvisoryExternalEnrichmentProviding {
    let source: AdvisoryEnrichmentSource
    let message: String

    var runtimeKind: AdvisoryEnrichmentRuntimeKind { .connectorBacked }
    var providerLabel: String { "Connector" }

    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle {
        throw DatabaseError.executeFailed(message)
    }
}
