import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryEngineTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "advisory_engine_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V005_KnowledgeGraph.migration,
            V006_AdvisoryThreads.migration,
            V007_AdvisoryArtifacts.migration,
            V008_AdvisoryRuns.migration,
            V009_AttentionMarketMetadata.migration,
            V010_ThreadIntelligenceMetadata.migration,
            V011_AdvisoryArtifactMetadata.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    private func seedBaselineAdvisoryContext(db: DatabaseManager) throws {
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)", params: [
            .text("com.openai.codex"),
            .text("Codex")
        ])

        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-1"),
            .integer(1),
            .text("2026-04-04T08:00:00Z"),
            .text("2026-04-04T09:10:00Z"),
            .integer(4_200_000),
            .text("normal")
        ])

        try db.execute("""
            INSERT INTO context_snapshots
                (id, session_id, timestamp, app_name, bundle_id, window_title, text_source, merged_text, readable_score, uncertainty_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ctx-1"),
            .text("sess-1"),
            .text("2026-04-04T08:40:00Z"),
            .text("Codex"),
            .text("com.openai.codex"),
            .text("Memograph advisory sidecar"),
            .text("ax+ocr"),
            .text("Memograph advisory sidecar architecture and continuity_resume recipe draft"),
            .real(0.92),
            .real(0.08)
        ])

        try db.execute("""
            INSERT INTO daily_summaries
                (date, summary_text, top_topics_json, unfinished_items_json, generated_at, model_name, generation_status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("2026-03-20"),
            .text("Early baseline day for advisory cold start aging."),
            .text(#"["Memograph"]"#),
            .text(""),
            .text("2026-03-20T09:00:00Z"),
            .text("stub"),
            .text("success")
        ])

        try db.execute("""
            INSERT INTO daily_summaries
                (date, summary_text, top_topics_json, unfinished_items_json, generated_at, model_name, generation_status)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("2026-04-04"),
            .text("Worked on [[Memograph]] advisory sidecar and decided to keep the sidecar isolated from SQLite writes."),
            .text(#"["Memograph","advisory sidecar","continuity_resume"]"#),
            .text("Finish the continuity_resume flow\nCheck packet-first evidence escalation"),
            .text("2026-04-04T09:15:00Z"),
            .text("stub"),
            .text("success")
        ])

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("project-1"),
            .text("Memograph"),
            .text("memograph"),
            .text("project"),
            .text("2026-04-03T10:00:00Z"),
            .text("2026-04-04T09:00:00Z")
        ])
    }

    @Test("AdvisoryEngine generates and surfaces a Russian continuity resume card")
    func generatesResumeCard() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)

        let defaults = UserDefaults(suiteName: "advisory_engine_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)

        let generated = try engine.generateResumeArtifact(for: "2026-04-04", triggerKind: .userInvokedLost)
        let artifact = try #require(generated)
        let inbox = try engine.advisoryInbox(limit: 8)
        let domains = Set(inbox.map(\.domain))

        #expect(artifact.kind == .resumeCard)
        #expect(artifact.domain == .continuity)
        #expect(artifact.status == .surfaced)
        #expect(artifact.body.contains("Я заметил"))
        #expect(artifact.body.contains("Если хочешь продолжить"))
        #expect(domains.contains(.continuity))
        #expect(domains.contains(.writingExpression) || domains.contains(.decisions) || domains.contains(.research))

        let threads = try db.query("SELECT COUNT(*) AS count FROM advisory_threads")
        let continuity = try db.query("SELECT COUNT(*) AS count FROM continuity_items")
        let packets = try db.query("SELECT COUNT(*) AS count FROM advisory_packets")
        let artifacts = try db.query("SELECT COUNT(*) AS count FROM advisory_artifacts")
        let runs = try db.query("SELECT COUNT(*) AS count FROM advisory_runs")

        #expect((threads.first?["count"]?.intValue ?? 0) >= 2)
        #expect((continuity.first?["count"]?.intValue ?? 0) >= 1)
        #expect(packets.first?["count"]?.intValue == 1)
        #expect((artifacts.first?["count"]?.intValue ?? 0) >= 2)
        #expect((runs.first?["count"]?.intValue ?? 0) >= 2)

        let openItems = try engine.openContinuityItems(limit: 4)
        #expect(!inbox.isEmpty)
        #expect(!openItems.isEmpty)
    }

    @Test("AdvisoryEngine embeds notes enrichment and records structured evidence grants")
    func embedsNotesEnrichmentAndRecordsEvidenceGrant() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)
        try db.execute("""
            INSERT INTO knowledge_notes
                (id, note_type, title, body_markdown, source_date, tags_json, links_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("note-memograph-continuity"),
            .text("project"),
            .text("Memograph Continuity Note"),
            .text("Resume Me works better when a thread keeps one explicit return point across days."),
            .text("2026-04-04"),
            .text(#"["continuity"]"#),
            .text("[]")
        ])

        let defaults = UserDefaults(suiteName: "advisory_enrichment_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryAllowMCPEnrichment = true

        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)
        _ = try engine.generateResumeArtifact(for: "2026-04-04", triggerKind: .userInvokedLost)

        let packetRow = try #require(try db.query("""
            SELECT payload_json
            FROM advisory_packets
            ORDER BY created_at DESC
            LIMIT 1
        """).first)
        let payload = try #require(packetRow["payload_json"]?.textValue)
        let packetData = try #require(payload.data(using: .utf8))
        let packet = try JSONDecoder().decode(ReflectionPacket.self, from: packetData)
        let notesBundle = try #require(packet.enrichment.bundles.first(where: { $0.source == .notes }))
        let calendarBundle = try #require(packet.enrichment.bundles.first(where: { $0.source == .calendar }))

        #expect(packet.enrichment.phase == .phase2ReadOnly)
        #expect(notesBundle.availability == .embedded)
        #expect(notesBundle.items.contains(where: { $0.title == "Memograph Continuity Note" }))
        #expect(calendarBundle.availability == .unavailable)

        let evidenceRows = try db.query("""
            SELECT requested_level, reason, evidence_kinds_json, granted
            FROM advisory_evidence_requests
            ORDER BY created_at DESC
        """)
        let requestedLevel = evidenceRows.first?["requested_level"]?.textValue
        let reason = evidenceRows.first?["reason"]?.textValue ?? ""
        let evidenceKinds = AdvisorySupport.decodeStringArray(from: evidenceRows.first?["evidence_kinds_json"]?.textValue)
        let granted = (evidenceRows.first?["granted"]?.intValue ?? 0) != 0

        #expect(requestedLevel == AdvisoryAccessProfile.deepContext.rawValue)
        #expect(granted)
        #expect(reason.contains("Preloaded packet enrichment"))
        #expect(evidenceKinds.contains("notes"))
    }

    @Test("AdvisoryEngine records external enrichment evidence grants when staged providers embed context")
    func recordsExternalEnrichmentEvidenceGrant() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)

        let defaults = UserDefaults(suiteName: "advisory_external_enrichment_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryAllowMCPEnrichment = true

        let enrichmentBuilder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .calendar, title: "Architecture review")),
                .reminders: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .reminders, title: "Ping design partner")),
                .webResearch: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .webResearch, title: "Attention market notes"))
            ]
        )
        let engine = AdvisoryEngine(
            db: db,
            timeZone: utc,
            settings: settings,
            enrichmentContextBuilder: enrichmentBuilder
        )

        _ = try engine.generateResumeArtifact(for: "2026-04-04", triggerKind: .userInvokedLost)

        let packetRow = try #require(try db.query("""
            SELECT payload_json
            FROM advisory_packets
            ORDER BY created_at DESC
            LIMIT 1
        """).first)
        let payload = try #require(packetRow["payload_json"]?.textValue)
        let packetData = try #require(payload.data(using: .utf8))
        let packet = try JSONDecoder().decode(ReflectionPacket.self, from: packetData)

        #expect(packet.enrichment.bundles.first(where: { $0.source == .calendar })?.availability == .embedded)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .reminders })?.availability == .embedded)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .webResearch })?.availability == .embedded)

        let evidenceRows = try db.query("""
            SELECT evidence_kinds_json
            FROM advisory_evidence_requests
            ORDER BY created_at DESC
            LIMIT 1
        """)
        let evidenceKinds = AdvisorySupport.decodeStringArray(from: evidenceRows.first?["evidence_kinds_json"]?.textValue)

        #expect(evidenceKinds.contains("notes"))
        #expect(evidenceKinds.contains("calendar"))
        #expect(evidenceKinds.contains("reminders"))
        #expect(evidenceKinds.contains("web_research"))
    }

    @Test("Workspace snapshot carries domain market and enrichment source status")
    func workspaceSnapshotCarriesMarketAndEnrichmentStatus() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)
        try db.execute("""
            INSERT INTO knowledge_notes
                (id, note_type, title, body_markdown, source_date, tags_json, links_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("note-workspace-snapshot"),
            .text("project"),
            .text("Advisor workspace note"),
            .text("The advisor should show both domain competition and source grounding in one place."),
            .text("2026-04-04"),
            .text(#"["workspace","advisory"]"#),
            .text("[]")
        ])

        let defaults = UserDefaults(suiteName: "advisory_workspace_snapshot_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryAllowMCPEnrichment = true
        let enrichmentBuilder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .calendar, title: "Advisor planning window")),
                .reminders: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .reminders, title: "Ship advisor polish")),
                .webResearch: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .webResearch, title: "Attention governor notes"))
            ]
        )
        let engine = AdvisoryEngine(
            db: db,
            timeZone: utc,
            settings: settings,
            enrichmentContextBuilder: enrichmentBuilder
        )

        _ = try engine.generateResumeArtifact(for: "2026-04-04", triggerKind: .userInvokedLost)
        let snapshot = try engine.workspaceSnapshot(for: "2026-04-04")

        #expect(snapshot.surfacedCount >= 1)
        #expect(snapshot.domainMarketSnapshots.contains(where: { $0.domain == .continuity && $0.activeArtifactCount >= 1 }))
        #expect(snapshot.enrichmentSourceStatuses.contains(where: { $0.source == .notes && $0.availability == .embedded }))
        #expect(snapshot.enrichmentSourceStatuses.contains(where: { $0.source == .calendar && $0.availability == .embedded }))
        #expect(snapshot.enrichmentSourceStatuses.contains(where: { $0.source == .reminders && $0.availability == .embedded }))
        #expect(snapshot.enrichmentSourceStatuses.contains(where: { $0.source == .webResearch && $0.availability == .embedded }))
    }

    @Test("Manual advisory thread operations preserve title override pin state and parent-child detail")
    func manualThreadWorkspaceOperations() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_thread_workspace_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)

        let parent = try engine.createManualThread(
            title: "Advisory thread workspace",
            kind: .project,
            summary: "Manual thread for UI workspace coverage."
        )
        let child = try engine.createManualThread(
            title: "Inspector polish",
            kind: .theme,
            summary: "Child thread under the parent workspace thread.",
            parentThreadId: parent.thread.id
        )
        let renamed = try engine.renameThread(
            threadId: parent.thread.id,
            userTitleOverride: "Нить: advisory workspace"
        )
        let pinned = try engine.setThreadPinned(
            threadId: parent.thread.id,
            isPinned: true
        )
        let loadedDetail = try engine.threadDetail(for: parent.thread.id)
        let detail = try #require(loadedDetail)
        let threads = try engine.threads(limit: 10)

        #expect(renamed.thread.displayTitle == "Нить: advisory workspace")
        #expect(pinned.thread.userPinned)
        #expect(detail.thread.userPinned)
        #expect(detail.thread.userTitleOverride == "Нить: advisory workspace")
        #expect(detail.childThreads.contains(where: { $0.id == child.thread.id }))
        #expect(threads.first?.id == parent.thread.id)
    }

    @Test("Workspace snapshot exposes focus phase queue counts and active domains")
    func workspaceSnapshotExposesMarketState() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)

        let defaults = UserDefaults(suiteName: "advisory_workspace_snapshot_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryBridgeMode = .stubOnly
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)

        _ = try engine.runAdvisorySweep(for: "2026-04-04", triggerKind: .sessionEnd)
        if let thread = try engine.threads(limit: 1).first {
            _ = try engine.turnThreadIntoSignal(threadId: thread.id, for: "2026-04-04")
        }

        let snapshot = try engine.workspaceSnapshot(for: "2026-04-04")

        #expect(snapshot.focusState == .deepWork || snapshot.focusState == .browsing)
        #expect(snapshot.coldStartPhase == .operational)
        #expect(snapshot.activeThreadCount >= 1)
        #expect(snapshot.openContinuityCount >= 1)
        #expect(snapshot.surfacedCount + snapshot.pendingCount >= 1)
        #expect(snapshot.domainSummaries.contains(where: { $0.domain == .continuity }))
        #expect(snapshot.domainSummaries.contains(where: { $0.domain == .writingExpression }))
    }

    @Test("Thread maintenance actions merge duplicate threads and split broad threads into subthreads")
    func threadMaintenanceActions() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_thread_maintenance_actions_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        let target = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-target",
            title: "Memograph",
            slug: "memograph",
            kind: .project,
            status: .active,
            confidence: 0.84,
            firstSeenAt: "2026-04-01T08:00:00Z",
            lastActiveAt: "2026-04-04T10:00:00Z",
            source: "tests",
            summary: "Broad product thread.",
            parentThreadId: nil,
            totalActiveMinutes: 210,
            importanceScore: 0.8
        ))
        let source = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-source",
            title: "Memograph advisory sidecar",
            slug: "memograph-advisory-sidecar",
            kind: .project,
            status: .active,
            confidence: 0.8,
            firstSeenAt: "2026-04-02T08:00:00Z",
            lastActiveAt: "2026-04-04T10:30:00Z",
            source: "tests",
            summary: "Narrow child-like thread.",
            parentThreadId: nil,
            totalActiveMinutes: 40,
            importanceScore: 0.34
        ))

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-maintenance-1"),
            .text("v2.reflection.1"),
            .text("reflection"),
            .text("session_end"),
            .text("{}"),
            .text("ru"),
            .text("deep_context"),
            .text("2026-04-04T10:40:00Z")
        ])

        _ = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-source-thread",
            domain: .continuity,
            kind: .resumeCard,
            title: "Resume source thread",
            body: "Source thread artifact.",
            threadId: source.id,
            sourcePacketId: "pkt-maintenance-1",
            sourceRecipe: "continuity_resume",
            confidence: 0.82,
            whyNow: nil,
            evidenceJson: #"["thread:thread-source"]"#,
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T10:40:00Z",
            surfacedAt: "2026-04-04T10:40:00Z",
            expiresAt: nil
        ))
        _ = try store.upsertContinuityItem(ContinuityItemCandidate(
            id: "cont-source-thread",
            threadId: source.id,
            kind: .openLoop,
            title: "Finish sidecar parity",
            body: "Move the remaining sidecar logic into the real runtime.",
            status: .open,
            confidence: 0.84,
            sourcePacketId: "pkt-maintenance-1",
            createdAt: nil,
            updatedAt: nil,
            resolvedAt: nil
        ))

        let mergeProposal = AdvisoryThreadMaintenanceProposal(
            id: "merge-proposal",
            kind: .mergeIntoThread,
            title: "Merge narrow thread",
            rationale: "Duplicate narrow thread under broad target.",
            confidence: 0.82,
            targetThreadId: target.id,
            targetThreadTitle: target.displayTitle,
            suggestedStatus: nil,
            suggestedTitle: nil,
            suggestedSummary: nil,
            suggestedKind: nil,
            sourceContinuityItemId: nil
        )
        let mergedDetail = try engine.applyThreadMaintenanceProposal(
            threadId: source.id,
            proposal: mergeProposal
        )
        let mergedSource = try #require(try engine.thread(for: source.id))

        #expect(mergedDetail.thread.id == target.id)
        #expect(mergedDetail.continuityItems.contains(where: { $0.id == "cont-source-thread" }))
        #expect(mergedDetail.artifacts.contains(where: { $0.id == "artifact-source-thread" }))
        #expect(mergedSource.parentThreadId == target.id)
        #expect(mergedSource.status == .resolved)

        let splitHost = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-split-host",
            title: "Ambient advisory",
            slug: "ambient-advisory",
            kind: .project,
            status: .active,
            confidence: 0.78,
            firstSeenAt: "2026-04-01T08:00:00Z",
            lastActiveAt: "2026-04-04T12:00:00Z",
            source: "tests",
            summary: "Broad thread with multiple sub-concerns.",
            parentThreadId: nil,
            totalActiveMinutes: 260,
            importanceScore: 0.74
        ))
        _ = try store.upsertContinuityItem(ContinuityItemCandidate(
            id: "cont-split-host",
            threadId: splitHost.id,
            kind: .question,
            title: "Provider routing policy",
            body: "Decide how provider routing should degrade.",
            status: .open,
            confidence: 0.81,
            sourcePacketId: "pkt-maintenance-1",
            createdAt: nil,
            updatedAt: nil,
            resolvedAt: nil
        ))

        let splitProposal = AdvisoryThreadMaintenanceProposal(
            id: "split-proposal",
            kind: .splitIntoSubthread,
            title: "Split sub-thread",
            rationale: "Broad thread should spawn a child.",
            confidence: 0.76,
            targetThreadId: nil,
            targetThreadTitle: nil,
            suggestedStatus: nil,
            suggestedTitle: "Provider routing policy",
            suggestedSummary: "Focused sub-thread for provider routing.",
            suggestedKind: .question,
            sourceContinuityItemId: "cont-split-host"
        )
        let splitDetail = try engine.applyThreadMaintenanceProposal(
            threadId: splitHost.id,
            proposal: splitProposal
        )
        let updatedContinuity = try #require(try store.continuityItem(id: "cont-split-host"))

        #expect(splitDetail.childThreads.contains(where: { $0.displayTitle == "Provider routing policy" }))
        #expect(updatedContinuity.status == .stabilizing)
    }

    @Test("AdvisoryExchange keeps proactive artifacts queued when min gap is exhausted")
    func respectsProactiveMinGap() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_gap_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryMinGapMinutes = 45
        let store = AdvisoryArtifactStore(
            db: db,
            timeZone: utc,
            now: { ISO8601DateFormatter().date(from: "2026-04-04T10:10:00Z")! }
        )

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-old"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T10:00:00Z"),
            .text("pkt-new"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T10:10:00Z")
        ])

        let existing = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-old",
            domain: .continuity,
            kind: .resumeCard,
            title: "Старый resume",
            body: "Я заметил старую нить.",
            threadId: nil,
            sourcePacketId: "pkt-old",
            sourceRecipe: "continuity_resume",
            confidence: 0.85,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04"]"#,
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T10:00:00Z",
            surfacedAt: "2026-04-04T10:00:00Z",
            expiresAt: nil
        ))
        try store.updateArtifactMarketState(
            artifactId: existing.id,
            status: .surfaced,
            marketScore: 0.9,
            surfacedAt: "2026-04-04T10:00:00Z"
        )

        let candidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-new",
            domain: .continuity,
            kind: .resumeCard,
            title: "Новый resume",
            body: "Я заметил новую нить.\n1. Первый вход\n2. Второй вход",
            threadId: nil,
            sourcePacketId: "pkt-new",
            sourceRecipe: "continuity_resume",
            confidence: 0.92,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T10:10:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        let dayContext = AdvisoryDayContext(
            localDate: "2026-04-04",
            triggerKind: .sessionEnd,
            activeThreadCount: 1,
            openContinuityCount: 1,
            focusState: .transition,
            systemAgeDays: 14,
            coldStartPhase: .operational,
            signalWeights: ["continuity_pressure": 0.7]
        )
        let ranked = try exchange.evaluateAndSurface(
            candidateArtifacts: [candidate],
            triggerKind: .sessionEnd,
            dayContext: dayContext,
            now: ISO8601DateFormatter().date(from: "2026-04-04T10:10:00Z")!
        )
        let loadedArtifact = try store.artifact(id: ranked[0].id)
        let reloaded = try #require(loadedArtifact)

        #expect(reloaded.status == .queued)
    }

    @Test("Attention market can surface a different domain when continuity is fatigued")
    func favorsCategoryBalanceWhenContinuityIsFatigued() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_balance_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryMinGapMinutes = 1
        let store = AdvisoryArtifactStore(
            db: db,
            timeZone: utc,
            now: { ISO8601DateFormatter().date(from: "2026-04-04T14:00:00Z")! }
        )

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-old"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T12:20:00Z"),
            .text("pkt-cont"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T14:00:00Z"),
            .text("pkt-research"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T14:00:00Z")
        ])

        let oldContinuity = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-old-balance",
            domain: .continuity,
            kind: .resumeCard,
            title: "Старый continuity artifact",
            body: "Я заметил прежнюю нить.",
            threadId: nil,
            sourcePacketId: "pkt-old",
            sourceRecipe: "continuity_resume",
            confidence: 0.88,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04"]"#,
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T12:20:00Z",
            surfacedAt: "2026-04-04T12:20:00Z",
            expiresAt: nil
        ))
        try store.updateArtifactMarketState(
            artifactId: oldContinuity.id,
            status: .surfaced,
            marketScore: 0.88,
            surfacedAt: "2026-04-04T12:20:00Z"
        )

        let continuityCandidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-cont-balance",
            domain: .continuity,
            kind: .resumeCard,
            title: "Ещё один continuity card",
            body: "Я заметил continuity card.\n1. Первый вход\n2. Второй вход",
            threadId: nil,
            sourcePacketId: "pkt-cont",
            sourceRecipe: "continuity_resume",
            confidence: 0.9,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T14:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let researchCandidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-research-balance",
            domain: .research,
            kind: .researchDirection,
            title: "Куда копнуть дальше",
            body: "Есть исследовательское направление.\n1. Вопрос\n2. Контрастный пример",
            threadId: nil,
            sourcePacketId: "pkt-research",
            sourceRecipe: "research_direction",
            confidence: 0.78,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s2","thread:thread-2"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T14:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        let dayContext = AdvisoryDayContext(
            localDate: "2026-04-04",
            triggerKind: .sessionEnd,
            activeThreadCount: 2,
            openContinuityCount: 2,
            focusState: .transition,
            systemAgeDays: 14,
            coldStartPhase: .operational,
            signalWeights: [
                "continuity_pressure": 0.9,
                "research_pull": 0.82,
                "thread_density": 0.7
            ]
        )
        let surfaced = try exchange.evaluateAndSurface(
            candidateArtifacts: [continuityCandidate, researchCandidate],
            triggerKind: .sessionEnd,
            dayContext: dayContext,
            now: ISO8601DateFormatter().date(from: "2026-04-04T14:00:00Z")!
        )

        #expect(surfaced.first?.domain == .research)
        let continuityReload = try store.artifact(id: continuityCandidate.id)
        let researchReload = try store.artifact(id: researchCandidate.id)
        let reloadedContinuity = try #require(continuityReload)
        let reloadedResearch = try #require(researchReload)
        #expect(reloadedResearch.status == .surfaced)
        #expect(reloadedContinuity.status == .queued)
    }

    @Test("AdvisoryEngine falls back to stub when preferred sidecar is unavailable")
    func fallsBackToStubWhenSidecarUnavailable() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedBaselineAdvisoryContext(db: db)

        let defaults = UserDefaults(suiteName: "advisory_sidecar_fallback_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryBridgeMode = .preferSidecar

        let bridge = AdvisoryBridgeClient(
            primaryServer: FailingRemoteBridgeServer(status: "unavailable"),
            mode: .preferSidecar
        )
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings, bridge: bridge)

        let generated = try engine.generateResumeArtifact(for: "2026-04-04", triggerKind: .userInvokedLost)
        let artifact = try #require(generated)
        #expect(artifact.domain == .continuity)

        let runs = try db.query("""
            SELECT provider_name, status, error_text
            FROM advisory_runs
        """)
        #expect(runs.contains {
            $0["provider_name"]?.textValue == "sidecar_jsonrpc_uds"
                && $0["status"]?.textValue == "failed"
                && ($0["error_text"]?.textValue?.contains("unavailable") ?? false)
        })
        #expect(runs.contains {
            $0["provider_name"]?.textValue == "local_stub"
                && $0["status"]?.textValue == "success"
        })
    }

    @Test("AdvisoryEngine keeps core working when required sidecar is unavailable")
    func continuesGracefullyWhenRequiredSidecarIsUnavailable() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try seedBaselineAdvisoryContext(db: db)

        let defaults = UserDefaults(suiteName: "advisory_sidecar_required_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryBridgeMode = .requireSidecar

        let bridge = AdvisoryBridgeClient(
            primaryServer: FailingRemoteBridgeServer(status: "unavailable"),
            mode: .requireSidecar
        )
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings, bridge: bridge)

        let generated = try engine.generateResumeArtifact(for: "2026-04-04", triggerKind: .userInvokedLost)
        #expect(generated == nil)

        let continuityItems = try engine.openContinuityItems(limit: 8)
        #expect(!continuityItems.isEmpty)

        let packets = try db.query("SELECT COUNT(*) AS count FROM advisory_packets")
        let failedRuns = try db.query("SELECT COUNT(*) AS count FROM advisory_runs WHERE status = 'failed'")
        let artifacts = try db.query("SELECT COUNT(*) AS count FROM advisory_artifacts")

        #expect((packets.first?["count"]?.intValue ?? 0) == 1)
        #expect((failedRuns.first?["count"]?.intValue ?? 0) >= 1)
        #expect((artifacts.first?["count"]?.intValue ?? 0) == 0)
    }

    @Test("Bootstrap cold start keeps ambient advisory queued instead of surfaced")
    func bootstrapSuppressesAmbientSurfacing() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_bootstrap_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-bootstrap"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T10:10:00Z")
        ])

        let candidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-bootstrap",
            domain: .continuity,
            kind: .resumeCard,
            title: "Bootstrap resume",
            body: "Я заметил нить.",
            threadId: nil,
            sourcePacketId: "pkt-bootstrap",
            sourceRecipe: "continuity_resume",
            confidence: 0.86,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T10:10:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        let surfaced = try exchange.evaluateAndSurface(
            candidateArtifacts: [candidate],
            triggerKind: .sessionEnd,
            dayContext: AdvisoryDayContext(
                localDate: "2026-04-04",
                triggerKind: .sessionEnd,
                activeThreadCount: 1,
                openContinuityCount: 1,
                focusState: .transition,
                systemAgeDays: 2,
                coldStartPhase: .bootstrap,
                signalWeights: ["continuity_pressure": 0.8, "thread_density": 0.6]
            ),
            now: ISO8601DateFormatter().date(from: "2026-04-04T10:10:00Z")!
        )

        #expect(surfaced.first?.status != .surfaced)
        let reloaded = try #require(try store.artifact(id: candidate.id))
        #expect(reloaded.status == .queued)
    }

    @Test("Deep work suppresses proactive advisory surfaces")
    func deepWorkSuppressesAmbientSurfacing() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_deep_work_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-deep"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T15:00:00Z")
        ])

        let candidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-deep",
            domain: .focus,
            kind: .focusIntervention,
            title: "Не трогай deep work",
            body: "Есть мягкое вмешательство по фокусу.",
            threadId: nil,
            sourcePacketId: "pkt-deep",
            sourceRecipe: "focus_reflection",
            confidence: 0.8,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T15:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        _ = try exchange.evaluateAndSurface(
            candidateArtifacts: [candidate],
            triggerKind: .sessionEnd,
            dayContext: AdvisoryDayContext(
                localDate: "2026-04-04",
                triggerKind: .sessionEnd,
                activeThreadCount: 1,
                openContinuityCount: 0,
                focusState: .deepWork,
                systemAgeDays: 21,
                coldStartPhase: .operational,
                signalWeights: ["focus_turbulence": 0.85, "fragmentation": 0.4]
            ),
            now: ISO8601DateFormatter().date(from: "2026-04-04T15:00:00Z")!
        )

        let reloaded = try #require(try store.artifact(id: candidate.id))
        #expect(reloaded.status == .queued)
    }

    @Test("Feedback more_like_this boosts a related writing candidate inside the same domain")
    func feedbackBoostsRelatedWritingCandidate() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_feedback_boost_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryMinGapMinutes = 1

        let feedbackTime = ISO8601DateFormatter().date(from: "2026-04-04T09:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2026-04-04T14:00:00Z")!
        let feedbackStore = AdvisoryArtifactStore(db: db, timeZone: utc, now: { feedbackTime })
        let store = AdvisoryArtifactStore(db: db, timeZone: utc, now: { now })

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-feedback-old"), .text("v2.reflection.1"), .text("reflection"), .text("user_invoked_write"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-03T08:00:00Z"),
            .text("pkt-feedback-note"), .text("v2.reflection.1"), .text("reflection"), .text("user_invoked_write"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T14:00:00Z"),
            .text("pkt-feedback-tweet"), .text("v2.reflection.1"), .text("reflection"), .text("user_invoked_write"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T14:00:00Z")
        ])

        let thread = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-writing",
            title: "Memograph writing",
            slug: "memograph-writing",
            kind: .project,
            status: .active,
            confidence: 0.84,
            firstSeenAt: "2026-04-03T08:00:00Z",
            lastActiveAt: "2026-04-04T13:45:00Z",
            source: "tests",
            summary: "Writing threads around Memograph.",
            parentThreadId: nil,
            totalActiveMinutes: 120,
            importanceScore: 0.72
        ))

        let historical = try feedbackStore.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-feedback-old",
            domain: .writingExpression,
            kind: .noteSeed,
            title: "Старый note seed",
            body: "Из этого получился хороший note seed.",
            threadId: thread.id,
            sourcePacketId: "pkt-feedback-old",
            sourceRecipe: "writing_seed",
            confidence: 0.84,
            whyNow: nil,
            evidenceJson: #"["thread:thread-writing","summary:2026-04-03"]"#,
            language: "ru",
            status: .accepted,
            createdAt: "2026-04-03T08:10:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))
        _ = try feedbackStore.recordFeedback(artifactId: historical.id, kind: .moreLikeThis)

        let noteCandidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-feedback-note",
            domain: .writingExpression,
            kind: .noteSeed,
            title: "Новый note seed",
            body: "Есть наблюдение, которое лучше развернуть в note.",
            threadId: thread.id,
            sourcePacketId: "pkt-feedback-note",
            sourceRecipe: "writing_seed",
            confidence: 0.79,
            whyNow: nil,
            evidenceJson: #"["thread:thread-writing","summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T14:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let tweetCandidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-feedback-tweet",
            domain: .writingExpression,
            kind: .tweetSeed,
            title: "Новый tweet seed",
            body: "Есть другой writing candidate для твита.",
            threadId: nil,
            sourcePacketId: "pkt-feedback-tweet",
            sourceRecipe: "writing_seed",
            confidence: 0.82,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s2"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T14:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        let surfaced = try exchange.evaluateAndSurface(
            candidateArtifacts: [noteCandidate, tweetCandidate],
            triggerKind: .userInvokedWrite,
            dayContext: AdvisoryDayContext(
                localDate: "2026-04-04",
                triggerKind: .userInvokedWrite,
                activeThreadCount: 1,
                openContinuityCount: 0,
                focusState: .browsing,
                systemAgeDays: 14,
                coldStartPhase: .operational,
                signalWeights: ["expression_pull": 0.86, "thread_density": 0.6]
            ),
            now: now
        )

        #expect(surfaced.first?.id == noteCandidate.id)
        let reloadedNote = try #require(try store.artifact(id: noteCandidate.id))
        let reloadedTweet = try #require(try store.artifact(id: tweetCandidate.id))
        #expect(reloadedNote.status == .surfaced)
        #expect(reloadedTweet.status == .queued)
    }

    @Test("Feedback not_now delays resurfacing for the same continuity thread")
    func feedbackNotNowQueuesRelatedContinuityCandidate() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_feedback_not_now_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryMinGapMinutes = 1

        let feedbackTime = ISO8601DateFormatter().date(from: "2026-04-04T11:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2026-04-04T12:00:00Z")!
        let feedbackStore = AdvisoryArtifactStore(db: db, timeZone: utc, now: { feedbackTime })
        let store = AdvisoryArtifactStore(db: db, timeZone: utc, now: { now })

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-not-now-old"), .text("v2.reflection.1"), .text("reflection"), .text("reentry_after_idle"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-03T09:00:00Z"),
            .text("pkt-not-now-new"), .text("v2.reflection.1"), .text("reflection"), .text("reentry_after_idle"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T12:00:00Z")
        ])

        let thread = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-continuity",
            title: "Resume thread",
            slug: "resume-thread",
            kind: .project,
            status: .active,
            confidence: 0.9,
            firstSeenAt: "2026-04-03T09:00:00Z",
            lastActiveAt: "2026-04-04T11:30:00Z",
            source: "tests",
            summary: "Continuity thread for resume.",
            parentThreadId: nil,
            totalActiveMinutes: 95,
            importanceScore: 0.78
        ))

        let historical = try feedbackStore.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-not-now-old",
            domain: .continuity,
            kind: .resumeCard,
            title: "Старый resume",
            body: "Это continuity artifact, который уже показали раньше.",
            threadId: thread.id,
            sourcePacketId: "pkt-not-now-old",
            sourceRecipe: "continuity_resume",
            confidence: 0.88,
            whyNow: nil,
            evidenceJson: #"["thread:thread-continuity","summary:2026-04-03"]"#,
            language: "ru",
            status: .accepted,
            createdAt: "2026-04-03T09:15:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))
        _ = try feedbackStore.recordFeedback(artifactId: historical.id, kind: .notNow)

        let candidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-not-now-new",
            domain: .continuity,
            kind: .resumeCard,
            title: "Новый resume вход",
            body: "Есть мягкий вход назад в ту же нить.",
            threadId: thread.id,
            sourcePacketId: "pkt-not-now-new",
            sourceRecipe: "continuity_resume",
            confidence: 0.9,
            whyNow: nil,
            evidenceJson: #"["thread:thread-continuity","summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T12:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        _ = try exchange.evaluateAndSurface(
            candidateArtifacts: [candidate],
            triggerKind: .reentryAfterIdle,
            dayContext: AdvisoryDayContext(
                localDate: "2026-04-04",
                triggerKind: .reentryAfterIdle,
                activeThreadCount: 1,
                openContinuityCount: 1,
                focusState: .idleReturn,
                systemAgeDays: 14,
                coldStartPhase: .operational,
                signalWeights: ["continuity_pressure": 0.92, "thread_density": 0.72]
            ),
            now: now
        )

        let reloaded = try #require(try store.artifact(id: candidate.id))
        #expect(reloaded.status == .queued)
    }

    @Test("Feedback mute_kind suppresses proactive artifacts of the same kind")
    func feedbackMuteKindSuppressesMatchingKind() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_feedback_mute_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryMinGapMinutes = 1

        let feedbackTime = ISO8601DateFormatter().date(from: "2026-04-04T13:00:00Z")!
        let now = ISO8601DateFormatter().date(from: "2026-04-04T14:00:00Z")!
        let feedbackStore = AdvisoryArtifactStore(db: db, timeZone: utc, now: { feedbackTime })
        let store = AdvisoryArtifactStore(db: db, timeZone: utc, now: { now })

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-mute-old"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-03T12:00:00Z"),
            .text("pkt-mute-new"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T14:00:00Z")
        ])

        let historical = try feedbackStore.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-mute-old",
            domain: .social,
            kind: .socialNudge,
            title: "Старый social nudge",
            body: "Это social nudge из предыдущего дня.",
            threadId: nil,
            sourcePacketId: "pkt-mute-old",
            sourceRecipe: "social_signal",
            confidence: 0.82,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-03"]"#,
            language: "ru",
            status: .accepted,
            createdAt: "2026-04-03T12:10:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))
        _ = try feedbackStore.recordFeedback(artifactId: historical.id, kind: .muteKind)

        let candidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-mute-new",
            domain: .social,
            kind: .socialNudge,
            title: "Новый social nudge",
            body: "Есть мягкий social prompt.",
            threadId: nil,
            sourcePacketId: "pkt-mute-new",
            sourceRecipe: "social_signal",
            confidence: 0.84,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T14:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        _ = try exchange.evaluateAndSurface(
            candidateArtifacts: [candidate],
            triggerKind: .sessionEnd,
            dayContext: AdvisoryDayContext(
                localDate: "2026-04-04",
                triggerKind: .sessionEnd,
                activeThreadCount: 0,
                openContinuityCount: 0,
                focusState: .browsing,
                systemAgeDays: 14,
                coldStartPhase: .operational,
                signalWeights: ["social_pull": 0.88]
            ),
            now: now
        )

        let reloaded = try #require(try store.artifact(id: candidate.id))
        #expect(reloaded.status == .queued)
    }

    @Test("Applying useful feedback marks artifact accepted and records feedback")
    func applyUsefulFeedbackAcceptsArtifact() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_apply_feedback_useful_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-feedback-useful"),
            .text("v2.reflection.1"),
            .text("reflection"),
            .text("user_invoked_lost"),
            .text("{}"),
            .text("ru"),
            .text("deep_context"),
            .text("2026-04-04T10:00:00Z")
        ])

        _ = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-feedback-useful",
            domain: .continuity,
            kind: .resumeCard,
            title: "Resume Me",
            body: "Я заметил, где можно вернуться в нить.",
            threadId: nil,
            sourcePacketId: "pkt-feedback-useful",
            sourceRecipe: "continuity_resume",
            confidence: 0.88,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","thread:resume"]"#,
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T10:00:00Z",
            surfacedAt: "2026-04-04T10:00:00Z",
            expiresAt: nil
        ))

        let updated = try engine.applyFeedback(
            artifactId: "artifact-feedback-useful",
            kind: .useful
        )
        let feedbackRows = try db.query("""
            SELECT feedback_kind
            FROM advisory_artifact_feedback
            WHERE artifact_id = ?
        """, params: [.text("artifact-feedback-useful")])

        #expect(updated.status == .accepted)
        #expect(feedbackRows.last?["feedback_kind"]?.textValue == AdvisoryArtifactFeedbackKind.useful.rawValue)
    }

    @Test("Applying not_now feedback dismisses artifact without deleting it")
    func applyNotNowFeedbackDismissesArtifact() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_apply_feedback_not_now_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-feedback-not-now"),
            .text("v2.reflection.1"),
            .text("reflection"),
            .text("reentry_after_idle"),
            .text("{}"),
            .text("ru"),
            .text("deep_context"),
            .text("2026-04-04T11:00:00Z")
        ])

        _ = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-feedback-not-now",
            domain: .continuity,
            kind: .resumeCard,
            title: "Resume later",
            body: "Есть мягкий вход обратно в контекст.",
            threadId: nil,
            sourcePacketId: "pkt-feedback-not-now",
            sourceRecipe: "continuity_resume",
            confidence: 0.86,
            whyNow: nil,
            evidenceJson: #"["thread:thread-feedback-not-now","summary:2026-04-04"]"#,
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T11:00:00Z",
            surfacedAt: "2026-04-04T11:00:00Z",
            expiresAt: nil
        ))

        let updated = try engine.applyFeedback(
            artifactId: "artifact-feedback-not-now",
            kind: .notNow
        )

        #expect(updated.status == .dismissed)
        #expect(try store.artifact(id: "artifact-feedback-not-now")?.status == .dismissed)
    }

    @Test("Applying mute_kind feedback moves artifact into muted state")
    func applyMuteKindFeedbackMutesArtifact() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_apply_feedback_mute_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-feedback-mute"),
            .text("v2.reflection.1"),
            .text("reflection"),
            .text("session_end"),
            .text("{}"),
            .text("ru"),
            .text("deep_context"),
            .text("2026-04-04T12:00:00Z")
        ])

        _ = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-feedback-mute",
            domain: .social,
            kind: .socialNudge,
            title: "Social nudge",
            body: "Есть тихий social signal.",
            threadId: nil,
            sourcePacketId: "pkt-feedback-mute",
            sourceRecipe: "social_signal",
            confidence: 0.8,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04"]"#,
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T12:00:00Z",
            surfacedAt: "2026-04-04T12:00:00Z",
            expiresAt: nil
        ))

        let updated = try engine.applyFeedback(
            artifactId: "artifact-feedback-mute",
            kind: .muteKind
        )

        #expect(updated.status == .muted)
        #expect(try store.artifact(id: "artifact-feedback-mute")?.status == .muted)
    }

    @Test("Materializing resume quick action creates continuity item and keeps artifact surfaced")
    func materializeResumeQuickActionCreatesContinuityItem() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_materialize_resume_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-materialize-resume"),
            .text("v2.reflection.1"),
            .text("reflection"),
            .text("user_invoked_lost"),
            .text("{}"),
            .text("ru"),
            .text("deep_context"),
            .text("2026-04-04T13:00:00Z")
        ])

        let parent = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-parent-materialize",
            title: "Memograph advisory",
            slug: "memograph-advisory",
            kind: .project,
            status: .active,
            confidence: 0.87,
            firstSeenAt: "2026-04-03T08:00:00Z",
            lastActiveAt: "2026-04-04T13:00:00Z",
            source: "tests",
            summary: "Parent advisory thread.",
            parentThreadId: nil,
            totalActiveMinutes: 120,
            importanceScore: 0.78
        ))
        _ = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-child-materialize",
            title: "Old narrow resume thread",
            slug: "old-narrow-resume-thread",
            kind: .theme,
            status: .resolved,
            confidence: 0.62,
            firstSeenAt: "2026-04-02T08:00:00Z",
            lastActiveAt: "2026-04-03T12:00:00Z",
            source: "tests",
            summary: "Resolved child thread.",
            parentThreadId: parent.id,
            totalActiveMinutes: 35,
            importanceScore: 0.24
        ))

        let guidance = AdvisoryArtifactGuidanceMetadata(
            summary: "The main re-entry cost is finding the sidecar lifecycle edge again.",
            actionSteps: ["Check sidecar lifecycle against runtime health."],
            continuityAnchor: "Open the sidecar lifecycle path before touching provider routing.",
            openLoop: "Real sidecar lifecycle still needs one explicit re-entry anchor."
        )
        _ = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-materialize-resume",
            domain: .continuity,
            kind: .resumeCard,
            title: "Resume Me",
            body: "Есть мягкий вход обратно в advisory runtime.",
            threadId: "thread-child-materialize",
            sourcePacketId: "pkt-materialize-resume",
            sourceRecipe: "continuity_resume",
            confidence: 0.91,
            whyNow: "Эта нить уже возвращалась несколько раз.",
            evidenceJson: #"["thread:thread-child-materialize","summary:2026-04-04"]"#,
            metadataJson: AdvisorySupport.encodeJSONString(guidance),
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T13:00:00Z",
            surfacedAt: "2026-04-04T13:00:00Z",
            expiresAt: nil
        ))

        let artifact = try #require(try store.artifact(id: "artifact-materialize-resume"))
        let action = try #require(artifact.quickActions.first)
        let outcome = try engine.materializeArtifactQuickAction(
            artifactId: artifact.id,
            actionId: action.id
        )

        #expect(outcome.continuityItem.kind == .commitment)
        #expect(outcome.continuityItem.threadId == parent.id)
        #expect(outcome.continuityItem.title == "Open the sidecar lifecycle path before touching provider routing.")
        #expect(try store.artifact(id: artifact.id)?.status == .surfaced)
    }

    @Test("Research quick action materializes a question continuity item")
    func materializeResearchQuickActionAsQuestion() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_materialize_research_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-materialize-research"),
            .text("v2.reflection.1"),
            .text("reflection"),
            .text("user_invoked_write"),
            .text("{}"),
            .text("ru"),
            .text("deep_context"),
            .text("2026-04-04T14:00:00Z")
        ])

        let thread = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-research-materialize",
            title: "Provider routing research",
            slug: "provider-routing-research",
            kind: .question,
            status: .active,
            confidence: 0.8,
            firstSeenAt: "2026-04-03T08:00:00Z",
            lastActiveAt: "2026-04-04T14:00:00Z",
            source: "tests",
            summary: "Research thread for provider routing.",
            parentThreadId: nil,
            totalActiveMinutes: 90,
            importanceScore: 0.72
        ))
        let guidance = AdvisoryArtifactGuidanceMetadata(
            summary: "The next useful research move is clarifying the failure boundary.",
            actionSteps: ["Compare cooldown and retry semantics."],
            focusQuestion: "Which provider failures should trigger rotation versus local retry?"
        )
        _ = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-materialize-research",
            domain: .research,
            kind: .researchDirection,
            title: "Research direction",
            body: "Есть исследовательский угол для provider routing.",
            threadId: thread.id,
            sourcePacketId: "pkt-materialize-research",
            sourceRecipe: "research_direction",
            confidence: 0.79,
            whyNow: "Failure edges still feel underspecified.",
            evidenceJson: #"["thread:thread-research-materialize","summary:2026-04-04"]"#,
            metadataJson: AdvisorySupport.encodeJSONString(guidance),
            language: "ru",
            status: .queued,
            createdAt: "2026-04-04T14:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let artifact = try #require(try store.artifact(id: "artifact-materialize-research"))
        let action = try #require(artifact.quickActions.first)
        let outcome = try engine.materializeArtifactQuickAction(
            artifactId: artifact.id,
            actionId: action.id
        )

        #expect(outcome.continuityItem.kind == .question)
        #expect(outcome.continuityItem.title == "Which provider failures should trigger rotation versus local retry?")
        #expect(outcome.continuityItem.threadId == thread.id)
        #expect(try store.artifact(id: artifact.id)?.status == .queued)
    }

    @Test("Materializing the same quick action is idempotent until the item is resolved")
    func materializeQuickActionIsIdempotentUntilResolved() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_materialize_idempotent_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let engine = AdvisoryEngine(db: db, timeZone: utc, settings: settings)
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-materialize-idempotent"),
            .text("v2.reflection.1"),
            .text("reflection"),
            .text("session_end"),
            .text("{}"),
            .text("ru"),
            .text("deep_context"),
            .text("2026-04-04T15:00:00Z")
        ])

        let guidance = AdvisoryArtifactGuidanceMetadata(
            summary: "There is one life-admin tail still bouncing around.",
            openLoop: "Provider subscription still needs explicit renewal.",
            candidateTask: "Renew the provider subscription before the next call."
        )
        _ = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-materialize-idempotent",
            domain: .lifeAdmin,
            kind: .lifeAdminReminder,
            title: "Life admin tail",
            body: "Есть небольшой operational хвост.",
            threadId: nil,
            sourcePacketId: "pkt-materialize-idempotent",
            sourceRecipe: "life_admin_review",
            confidence: 0.74,
            whyNow: "This can silently become tomorrow-morning friction.",
            evidenceJson: #"["summary:2026-04-04"]"#,
            metadataJson: AdvisorySupport.encodeJSONString(guidance),
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T15:00:00Z",
            surfacedAt: "2026-04-04T15:00:00Z",
            expiresAt: nil
        ))

        let artifact = try #require(try store.artifact(id: "artifact-materialize-idempotent"))
        let action = try #require(artifact.quickActions.first)

        let first = try engine.materializeArtifactQuickAction(
            artifactId: artifact.id,
            actionId: action.id
        )
        let second = try engine.materializeArtifactQuickAction(
            artifactId: artifact.id,
            actionId: action.id
        )

        #expect(first.continuityItem.id == second.continuityItem.id)
        #expect(second.reusedExistingItem)
        #expect(try store.listContinuityItems(limit: 10).count == 1)

        _ = try store.updateContinuityItemStatus(itemId: first.continuityItem.id, status: .resolved)
        let reopened = try engine.materializeArtifactQuickAction(
            artifactId: artifact.id,
            actionId: action.id
        )

        #expect(reopened.continuityItem.id != first.continuityItem.id)
        #expect(reopened.continuityItem.status == .open)
        #expect(try store.listContinuityItems(limit: 10).count == 2)
    }

    @Test("Idle return uses a shorter ambient gap for continuity resume")
    func idleReturnUsesAdaptiveAmbientGap() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_idle_return_gap_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryMinGapMinutes = 45
        let now = ISO8601DateFormatter().date(from: "2026-04-04T10:30:00Z")!
        let store = AdvisoryArtifactStore(db: db, timeZone: utc, now: { now })

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-idle-old"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T10:00:00Z"),
            .text("pkt-idle-new"), .text("v2.reflection.1"), .text("reflection"), .text("reentry_after_idle"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T10:30:00Z")
        ])

        let previous = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-idle-old",
            domain: .research,
            kind: .researchDirection,
            title: "Старый research hint",
            body: "Был недавний research advisory.",
            threadId: nil,
            sourcePacketId: "pkt-idle-old",
            sourceRecipe: "interest_miner",
            confidence: 0.76,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04"]"#,
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T10:00:00Z",
            surfacedAt: "2026-04-04T10:00:00Z",
            expiresAt: nil
        ))
        try store.updateArtifactMarketState(
            artifactId: previous.id,
            status: .surfaced,
            marketScore: 0.74,
            surfacedAt: "2026-04-04T10:00:00Z"
        )

        let candidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-idle-new",
            domain: .continuity,
            kind: .resumeCard,
            title: "Resume после idle return",
            body: "Есть мягкий вход назад в активную нить.",
            threadId: nil,
            sourcePacketId: "pkt-idle-new",
            sourceRecipe: "continuity_resume",
            confidence: 0.92,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T10:30:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        let surfaced = try exchange.evaluateAndSurface(
            candidateArtifacts: [candidate],
            triggerKind: .reentryAfterIdle,
            dayContext: AdvisoryDayContext(
                localDate: "2026-04-04",
                triggerKind: .reentryAfterIdle,
                activeThreadCount: 1,
                openContinuityCount: 1,
                focusState: .idleReturn,
                systemAgeDays: 20,
                coldStartPhase: .operational,
                signalWeights: ["continuity_pressure": 0.92, "thread_density": 0.68]
            ),
            now: now
        )

        #expect(surfaced.first?.id == candidate.id)
        let reloaded = try #require(try store.artifact(id: candidate.id))
        #expect(reloaded.status == .surfaced)
    }

    @Test("Per-thread cooldown keeps cross-domain repeats queued while a fresh thread can surface")
    func perThreadCooldownSuppressesCrossDomainRepeat() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_thread_cooldown_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryMinGapMinutes = 1

        let now = ISO8601DateFormatter().date(from: "2026-04-04T11:05:00Z")!
        let store = AdvisoryArtifactStore(db: db, timeZone: utc, now: { now })

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-thread-old"), .text("v2.reflection.1"), .text("reflection"), .text("reentry_after_idle"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T10:00:00Z"),
            .text("pkt-thread-repeat"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T11:05:00Z"),
            .text("pkt-thread-fresh"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T11:05:00Z")
        ])

        let repeatedThread = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-shared",
            title: "Shared advisory thread",
            slug: "shared-advisory-thread",
            kind: .project,
            status: .active,
            confidence: 0.9,
            firstSeenAt: "2026-04-04T09:00:00Z",
            lastActiveAt: "2026-04-04T11:05:00Z",
            source: "tests",
            summary: "Shared thread for cooldown coverage.",
            parentThreadId: nil,
            totalActiveMinutes: 110,
            importanceScore: 0.82
        ))
        let freshThread = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-fresh",
            title: "Fresh advisory thread",
            slug: "fresh-advisory-thread",
            kind: .project,
            status: .active,
            confidence: 0.84,
            firstSeenAt: "2026-04-04T10:20:00Z",
            lastActiveAt: "2026-04-04T11:05:00Z",
            source: "tests",
            summary: "Fresh thread for comparison.",
            parentThreadId: nil,
            totalActiveMinutes: 30,
            importanceScore: 0.56
        ))

        let previous = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-thread-old",
            domain: .continuity,
            kind: .resumeCard,
            title: "Недавний resume",
            body: "Эта нить уже всплывала недавно.",
            threadId: repeatedThread.id,
            sourcePacketId: "pkt-thread-old",
            sourceRecipe: "continuity_resume",
            confidence: 0.91,
            whyNow: nil,
            evidenceJson: #"["thread:thread-shared","summary:2026-04-04"]"#,
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T10:00:00Z",
            surfacedAt: "2026-04-04T10:00:00Z",
            expiresAt: nil
        ))
        try store.updateArtifactMarketState(
            artifactId: previous.id,
            status: .surfaced,
            marketScore: 0.82,
            surfacedAt: "2026-04-04T10:00:00Z"
        )

        let repeatedCandidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-thread-repeat",
            domain: .writingExpression,
            kind: .noteSeed,
            title: "Повтор по той же нити",
            body: "Можно оформить это как note seed.",
            threadId: repeatedThread.id,
            sourcePacketId: "pkt-thread-repeat",
            sourceRecipe: "tweet_from_thread",
            confidence: 0.86,
            whyNow: nil,
            evidenceJson: #"["thread:thread-shared","summary:2026-04-04","session:s1"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T11:05:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let freshCandidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-thread-fresh",
            domain: .writingExpression,
            kind: .noteSeed,
            title: "Свежая нить для note seed",
            body: "Это похожий writing artifact, но по новой нити.",
            threadId: freshThread.id,
            sourcePacketId: "pkt-thread-fresh",
            sourceRecipe: "tweet_from_thread",
            confidence: 0.83,
            whyNow: nil,
            evidenceJson: #"["thread:thread-fresh","summary:2026-04-04","session:s2"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T11:05:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        let surfaced = try exchange.evaluateAndSurface(
            candidateArtifacts: [repeatedCandidate, freshCandidate],
            triggerKind: .sessionEnd,
            dayContext: AdvisoryDayContext(
                localDate: "2026-04-04",
                triggerKind: .sessionEnd,
                activeThreadCount: 2,
                openContinuityCount: 1,
                focusState: .browsing,
                systemAgeDays: 16,
                coldStartPhase: .operational,
                signalWeights: ["expression_pull": 0.8, "thread_density": 0.72]
            ),
            now: now
        )

        #expect(surfaced.first?.id == freshCandidate.id)
        let repeatedReloaded = try #require(try store.artifact(id: repeatedCandidate.id))
        let freshReloaded = try #require(try store.artifact(id: freshCandidate.id))
        #expect(repeatedReloaded.status == .queued)
        #expect(freshReloaded.status == .surfaced)
    }

    @Test("Fragmented state gives ambient priority to focus intervention")
    func fragmentedStatePrioritizesFocusIntervention() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "advisory_fragmented_focus_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryMinGapMinutes = 1
        let now = ISO8601DateFormatter().date(from: "2026-04-04T14:00:00Z")!
        let store = AdvisoryArtifactStore(db: db, timeZone: utc, now: { now })

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("pkt-frag-focus"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T14:00:00Z"),
            .text("pkt-frag-research"), .text("v2.reflection.1"), .text("reflection"), .text("session_end"), .text("{}"), .text("ru"), .text("deep_context"), .text("2026-04-04T14:00:00Z")
        ])

        let focusCandidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-frag-focus",
            domain: .focus,
            kind: .focusIntervention,
            title: "Мягкий focus intervention",
            body: "Кажется, день распался на фрагменты; можно вернуть один опорный шаг.",
            threadId: nil,
            sourcePacketId: "pkt-frag-focus",
            sourceRecipe: "pattern_finder",
            confidence: 0.84,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s1","session:s2"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T14:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let researchCandidate = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-frag-research",
            domain: .research,
            kind: .researchDirection,
            title: "Research direction в неподходящий момент",
            body: "Есть исследовательская нить, но она не лучшая для fragmented state.",
            threadId: nil,
            sourcePacketId: "pkt-frag-research",
            sourceRecipe: "interest_miner",
            confidence: 0.86,
            whyNow: nil,
            evidenceJson: #"["summary:2026-04-04","session:s3"]"#,
            language: "ru",
            status: .candidate,
            createdAt: "2026-04-04T14:00:00Z",
            surfacedAt: nil,
            expiresAt: nil
        ))

        let exchange = AdvisoryExchange(store: store, settings: settings, timeZone: utc)
        let surfaced = try exchange.evaluateAndSurface(
            candidateArtifacts: [focusCandidate, researchCandidate],
            triggerKind: .sessionEnd,
            dayContext: AdvisoryDayContext(
                localDate: "2026-04-04",
                triggerKind: .sessionEnd,
                activeThreadCount: 2,
                openContinuityCount: 1,
                focusState: .fragmented,
                systemAgeDays: 18,
                coldStartPhase: .operational,
                signalWeights: ["focus_turbulence": 0.92, "fragmentation": 0.88, "research_pull": 0.76]
            ),
            now: now
        )

        #expect(surfaced.first?.id == focusCandidate.id)
        let focusReloaded = try #require(try store.artifact(id: focusCandidate.id))
        let researchReloaded = try #require(try store.artifact(id: researchCandidate.id))
        #expect(focusReloaded.status == .surfaced)
        #expect(researchReloaded.status == .queued)
    }

    @Test("Turn thread into signal generates writing artifact from thread packet")
    func turnThreadIntoSignalGeneratesWritingArtifact() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)
        try db.execute("""
            INSERT INTO knowledge_notes
                (id, note_type, title, body_markdown, source_date, tags_json, links_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("note-thread-packet"),
            .text("project"),
            .text("Thread packet note"),
            .text("Thread packets should carry their own enrichment context instead of reflection-only notes."),
            .text("2026-04-04"),
            .text(#"["threads","advisory"]"#),
            .text("[]")
        ])

        let defaults = UserDefaults(suiteName: "advisory_thread_signal_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryBridgeMode = .stubOnly
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryAllowMCPEnrichment = true
        let enrichmentBuilder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .calendar, title: "Thread planning block")),
                .reminders: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .reminders, title: "Ship thread packet routing")),
                .webResearch: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .webResearch, title: "Attention market deep dive"))
            ]
        )
        let engine = AdvisoryEngine(
            db: db,
            timeZone: utc,
            settings: settings,
            enrichmentContextBuilder: enrichmentBuilder
        )

        _ = try engine.runAdvisorySweep(for: "2026-04-04", triggerKind: .sessionEnd)
        let thread = try #require(try engine.threads(limit: 1).first)

        let artifacts = try engine.turnThreadIntoSignal(
            threadId: thread.id,
            for: "2026-04-04"
        )
        let artifact = try #require(artifacts.first)
        let sourcePacketId = try #require(artifact.sourcePacketId)
        let metadata = try #require(artifact.writingMetadata)

        #expect(artifact.domain == .writingExpression)
        #expect([.tweetSeed, .threadSeed, .noteSeed].contains(artifact.kind))
        #expect(artifact.sourceRecipe == "tweet_from_thread")
        #expect(metadata.evidencePack.isEmpty == false)
        #expect(metadata.primaryAngle == .observation)
        #expect(metadata.enrichmentSources.contains(.notes))
        #expect(metadata.enrichmentSources.contains(.calendar))
        #expect(metadata.enrichmentSources.contains(.reminders))
        #expect(metadata.enrichmentSources.contains(.webResearch))

        let packetRow = try #require(db.query("""
            SELECT payload_json
            FROM advisory_packets
            WHERE id = ?
        """, params: [.text(sourcePacketId)]).first)
        let payload = try #require(packetRow["payload_json"]?.textValue)
        let packetData = try #require(payload.data(using: .utf8))
        let packet = try JSONDecoder().decode(ThreadPacket.self, from: packetData)
        #expect(packet.kind == .thread)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .notes })?.availability == .embedded)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .calendar })?.availability == .embedded)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .reminders })?.availability == .embedded)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .webResearch })?.availability == .embedded)

        let evidenceRows = try db.query("""
            SELECT evidence_kinds_json
            FROM advisory_evidence_requests
            ORDER BY created_at DESC
            LIMIT 1
        """)
        let evidenceKinds = AdvisorySupport.decodeStringArray(from: evidenceRows.first?["evidence_kinds_json"]?.textValue)
        #expect(evidenceKinds.contains("notes"))
        #expect(evidenceKinds.contains("calendar"))
        #expect(evidenceKinds.contains("reminders"))
        #expect(evidenceKinds.contains("web_research"))
    }

    @Test("Generate weekly review creates weekly packet and weekly review artifact")
    func generateWeeklyReviewCreatesWeeklyArtifact() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)
        try db.execute("""
            INSERT INTO knowledge_notes
                (id, note_type, title, body_markdown, source_date, tags_json, links_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("note-weekly-packet"),
            .text("project"),
            .text("Weekly review note"),
            .text("Weekly review should keep the main thread and one return point visible together."),
            .text("2026-03-30"),
            .text(#"["weekly","advisory"]"#),
            .text("[]")
        ])

        let defaults = UserDefaults(suiteName: "advisory_weekly_review_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryBridgeMode = .stubOnly
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryAllowMCPEnrichment = true
        let enrichmentBuilder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .calendar, title: "Monday weekly planning")),
                .reminders: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .reminders, title: "Review weekly return point")),
                .webResearch: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .webResearch, title: "Weekly synthesis framing"))
            ]
        )
        let engine = AdvisoryEngine(
            db: db,
            timeZone: utc,
            settings: settings,
            enrichmentContextBuilder: enrichmentBuilder
        )

        _ = try engine.runAdvisorySweep(for: "2026-04-04", triggerKind: .endOfDay)
        let artifact = try engine.generateWeeklyReview(for: "2026-04-04")
        let weeklyReview = try #require(artifact)
        let sourcePacketId = try #require(weeklyReview.sourcePacketId)
        let metadata = try #require(weeklyReview.guidanceMetadata)

        #expect(weeklyReview.kind == .weeklyReview)
        #expect(weeklyReview.sourceRecipe == "weekly_reflection")
        #expect(metadata.enrichmentSources.contains(.notes))
        #expect(metadata.enrichmentSources.contains(.calendar))
        #expect(metadata.enrichmentSources.contains(.reminders))
        #expect(metadata.enrichmentSources.contains(.webResearch))

        let packetRow = try #require(db.query("""
            SELECT payload_json
            FROM advisory_packets
            WHERE id = ?
        """, params: [.text(sourcePacketId)]).first)
        let payload = try #require(packetRow["payload_json"]?.textValue)
        let packetData = try #require(payload.data(using: .utf8))
        let packet = try JSONDecoder().decode(WeeklyPacket.self, from: packetData)
        #expect(packet.kind == .weekly)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .notes })?.availability == .embedded)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .calendar })?.availability == .embedded)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .reminders })?.availability == .embedded)
        #expect(packet.enrichment.bundles.first(where: { $0.source == .webResearch })?.availability == .embedded)

        let evidenceRows = try db.query("""
            SELECT evidence_kinds_json
            FROM advisory_evidence_requests
            ORDER BY created_at DESC
            LIMIT 1
        """)
        let evidenceKinds = AdvisorySupport.decodeStringArray(from: evidenceRows.first?["evidence_kinds_json"]?.textValue)
        #expect(evidenceKinds.contains("notes"))
        #expect(evidenceKinds.contains("calendar"))
        #expect(evidenceKinds.contains("reminders"))
        #expect(evidenceKinds.contains("web_research"))
    }

    @Test("Manual domain pull generates research artifact from current day context")
    func manualDomainPullGeneratesResearchArtifact() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)
        try db.execute("""
            INSERT INTO knowledge_notes
                (id, note_type, title, body_markdown, source_date, tags_json, links_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("note-manual-research"),
            .text("project"),
            .text("Research note"),
            .text("Category-aware advisory works better when one narrow question is grounded in actual evidence."),
            .text("2026-04-04"),
            .text(#"["research","advisory"]"#),
            .text("[]")
        ])

        let defaults = UserDefaults(suiteName: "advisory_manual_domain_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryBridgeMode = .stubOnly
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryAllowMCPEnrichment = true

        let enrichmentBuilder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .calendar, title: "Research block")),
                .reminders: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .reminders, title: "Close research question")),
                .webResearch: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .webResearch, title: "Attention market framing"))
            ]
        )
        let engine = AdvisoryEngine(
            db: db,
            timeZone: utc,
            settings: settings,
            enrichmentContextBuilder: enrichmentBuilder
        )

        let artifact = try engine.generateDomainArtifact(for: "2026-04-04", domain: .research)
        let researchArtifact = try #require(artifact)
        let metadata = try #require(researchArtifact.guidanceMetadata)

        #expect(researchArtifact.domain == .research)
        #expect([.researchDirection, .explorationSeed].contains(researchArtifact.kind))
        #expect(metadata.enrichmentSources.contains(.notes))
        #expect(metadata.enrichmentSources.contains(.webResearch))
        #expect(metadata.sourceAnchors.contains(where: { $0.contains("Attention market framing") }))
    }

    @Test("Manual domain pull does not get shadowed by other packet artifacts")
    func manualDomainPullDoesNotReuseForeignRecipeArtifacts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)
        try db.execute("""
            INSERT INTO knowledge_notes
                (id, note_type, title, body_markdown, source_date, tags_json, links_json)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("note-manual-research-shadow"),
            .text("project"),
            .text("Research shadow note"),
            .text("Research should still run even when continuity already produced a packet artifact."),
            .text("2026-04-04"),
            .text(#"["research","advisory"]"#),
            .text("[]")
        ])

        let defaults = UserDefaults(suiteName: "advisory_manual_domain_shadow_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryBridgeMode = .stubOnly
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryAllowMCPEnrichment = true

        let enrichmentBuilder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .calendar, title: "Research block")),
                .reminders: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .reminders, title: "Close research question")),
                .webResearch: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .webResearch, title: "Attention market framing"))
            ]
        )
        let engine = AdvisoryEngine(
            db: db,
            timeZone: utc,
            settings: settings,
            enrichmentContextBuilder: enrichmentBuilder
        )

        _ = try engine.runAdvisorySweep(for: "2026-04-04", triggerKind: .sessionEnd)
        let artifact = try engine.generateDomainArtifact(for: "2026-04-04", domain: .research)
        let researchArtifact = try #require(artifact)

        #expect(researchArtifact.domain == .research)
        #expect(researchArtifact.sourceRecipe == "research_direction")
    }

    @Test("Domain workspace detail exposes recent artifacts related threads feedback and grounding")
    func domainWorkspaceDetailExposesProductSurfaceState() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)

        let defaults = UserDefaults(suiteName: "advisory_domain_workspace_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryEnrichmentPhase = .phase2ReadOnly
        settings.advisoryAllowMCPEnrichment = true

        let enrichmentBuilder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .calendar, title: "Founder coffee")),
                .reminders: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .reminders, title: "Ping Lena")),
                .webResearch: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .webResearch, title: "People follow-up notes")),
                .wearable: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .wearable, title: "Fragmented afternoon"))
            ]
        )
        let engine = AdvisoryEngine(
            db: db,
            timeZone: utc,
            settings: settings,
            enrichmentContextBuilder: enrichmentBuilder
        )
        let store = AdvisoryArtifactStore(db: db, timeZone: utc)

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, window_started_at, window_ended_at, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("packet-domain-social"),
            .text("v2"),
            .text(AdvisoryPacketKind.reflection.rawValue),
            .text(AdvisoryTriggerKind.sessionEnd.rawValue),
            .text("2026-04-04T00:00:00Z"),
            .text("2026-04-04T23:59:00Z"),
            .text("{}"),
            .text("ru"),
            .text(AdvisoryAccessProfile.deepContext.rawValue),
            .text("2026-04-04T12:00:00Z")
        ])

        let thread = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-social",
            title: "Lena partnership thread",
            slug: "lena-partnership-thread",
            kind: .person,
            status: .active,
            confidence: 0.82,
            firstSeenAt: "2026-04-02T09:00:00Z",
            lastActiveAt: "2026-04-04T11:00:00Z",
            source: "tests",
            summary: "Relationship thread around a partner follow-up.",
            parentThreadId: nil,
            totalActiveMinutes: 85,
            importanceScore: 0.71
        ))
        _ = try store.upsertContinuityItem(ContinuityItemCandidate(
            id: "continuity-social",
            threadId: thread.id,
            kind: .commitment,
            title: "Reply to Lena about the partnership draft",
            body: "Need a soft follow-up with one concrete next step.",
            status: .open,
            confidence: 0.74,
            sourcePacketId: "packet-domain-social",
            createdAt: "2026-04-04T12:00:00Z",
            updatedAt: "2026-04-04T12:00:00Z",
            resolvedAt: nil
        ))

        let socialMetadata = AdvisoryArtifactGuidanceMetadata(
            summary: "There is enough evidence for a low-pressure follow-up.",
            evidencePack: ["Reminder already exists", "Calendar has a natural window"],
            actionSteps: ["Send one soft ping", "Offer one concrete next step"],
            candidateTask: "Ping Lena with a lightweight update",
            patternName: "Social nudge",
            sourceAnchors: ["Ping Lena", "Founder coffee"],
            enrichmentSources: [.reminders, .calendar],
            timingWindow: "Better in a transition window, not during deep work."
        )

        let surfaced = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-social-surfaced",
            domain: .social,
            kind: .socialNudge,
            title: "Soft follow-up for Lena",
            body: "Похоже, сейчас хороший момент для короткого, ненавязчивого follow-up.",
            threadId: thread.id,
            sourcePacketId: "packet-domain-social",
            sourceRecipe: "social_signal",
            confidence: 0.78,
            whyNow: "Есть reminder и календарное окно.",
            evidenceJson: AdvisorySupport.encodeJSONString(["reminder:ping-lena", "calendar_event:founder-coffee"]),
            metadataJson: AdvisorySupport.encodeJSONString(socialMetadata),
            language: "ru",
            status: .surfaced,
            createdAt: "2026-04-04T12:01:00Z",
            surfacedAt: "2026-04-04T12:02:00Z"
        ))
        let queued = try store.upsertArtifact(AdvisoryArtifactCandidate(
            id: "artifact-social-queued",
            domain: .social,
            kind: .socialNudge,
            title: "Alternative social angle",
            body: "Можно не писать сейчас, а лишь пометить естественный момент для ответа.",
            threadId: thread.id,
            sourcePacketId: "packet-domain-social",
            sourceRecipe: "social_signal",
            confidence: 0.61,
            whyNow: "Это скорее latent option.",
            evidenceJson: AdvisorySupport.encodeJSONString(["reminder:ping-lena"]),
            metadataJson: AdvisorySupport.encodeJSONString(socialMetadata),
            language: "ru",
            status: .queued,
            createdAt: "2026-04-04T12:03:00Z"
        ))

        _ = try engine.applyFeedback(artifactId: surfaced.id, kind: .moreLikeThis)
        _ = try engine.applyFeedback(artifactId: queued.id, kind: .notNow)

        let detail = try engine.domainWorkspaceDetail(for: "2026-04-04", domain: .social)

        #expect(detail.domain == .social)
        #expect(detail.leadArtifact?.id == surfaced.id)
        #expect(detail.relatedThreads.contains(where: { $0.id == thread.id }))
        #expect(detail.continuityItems.contains(where: { $0.id == "continuity-social" }))
        #expect(detail.feedbackSummaries.contains(where: { $0.kind == .moreLikeThis && $0.count == 1 }))
        #expect(detail.feedbackSummaries.contains(where: { $0.kind == .notNow && $0.count == 1 }))
        #expect(detail.groundingSources.contains(.calendar))
        #expect(detail.groundingSources.contains(.reminders))
        #expect(detail.enrichmentStatuses.contains(where: { $0.source == .calendar && $0.availability == .embedded }))
        #expect(detail.enrichmentStatuses.contains(where: { $0.source == .reminders && $0.availability == .embedded }))
        #expect(detail.sourceAnchors.contains("Ping Lena"))
        #expect(detail.evidenceRefs.contains("reminder:ping-lena"))
    }

    @Test("Domain workspace detail stays inspectable for quiet domains without artifacts")
    func quietDomainWorkspaceDetailStillShowsLaneContext() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try seedBaselineAdvisoryContext(db: db)

        let defaults = UserDefaults(suiteName: "advisory_quiet_domain_workspace_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.advisoryEnrichmentPhase = .phase3Expanded
        settings.advisoryAllowMCPEnrichment = true

        let enrichmentBuilder = AdvisoryEnrichmentContextBuilder(
            db: db,
            settings: settings,
            timeZone: utc,
            externalProviders: [
                .calendar: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .calendar, title: "Quiet window")),
                .reminders: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .reminders, title: "Admin follow-up")),
                .webResearch: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .webResearch, title: "Research traces")),
                .wearable: AdvisoryEngineStubEnrichmentProvider(bundle: makeExternalBundle(source: .wearable, title: "Late stretch"))
            ]
        )
        let engine = AdvisoryEngine(
            db: db,
            timeZone: utc,
            settings: settings,
            enrichmentContextBuilder: enrichmentBuilder
        )

        let detail = try engine.domainWorkspaceDetail(for: "2026-04-04", domain: .health)

        #expect(detail.domain == .health)
        #expect(detail.leadArtifact == nil)
        #expect(detail.isQuiet)
        #expect(detail.groundingSources.contains(.wearable))
        #expect(detail.groundingSources.contains(.calendar))
        #expect(detail.groundingSources.contains(.reminders))
        #expect(detail.enrichmentStatuses.contains(where: { $0.source == .wearable && $0.availability == .embedded }))
    }
}

private struct FailingRemoteBridgeServer: AdvisoryBridgeServerProtocol {
    let status: String

    func health() -> AdvisoryBridgeHealth {
        AdvisoryBridgeHealth(
            runtimeName: "memograph-advisor",
            status: status,
            providerName: "sidecar_jsonrpc_uds",
            transport: "jsonrpc_uds"
        )
    }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        throw AdvisoryBridgeError.unavailable("Advisory sidecar is unavailable (\(status)).")
    }

    func cancelRun(runId: String) {}
}

private struct AdvisoryEngineStubEnrichmentProvider: AdvisoryExternalEnrichmentProviding {
    let bundle: ReflectionEnrichmentBundle
    var source: AdvisoryEnrichmentSource { bundle.source }

    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle {
        bundle
    }
}

private func makeExternalBundle(
    source: AdvisoryEnrichmentSource,
    title: String
) -> ReflectionEnrichmentBundle {
    ReflectionEnrichmentBundle(
        id: source.rawValue,
        source: source,
        tier: .l2Structured,
        availability: .embedded,
        note: "Stub external bundle",
        items: [
            ReflectionEnrichmentItem(
                id: "item-\(source.rawValue)",
                source: source,
                title: title,
                snippet: "Stub external context",
                relevance: 0.88,
                evidenceRefs: ["\(source.rawValue):stub"],
                sourceRef: "\(source.rawValue):stub"
            )
        ]
    )
}
