import Testing
import Foundation
@testable import MyMacAgent

struct KnowledgePipelineTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "knowledge_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V005_KnowledgeGraph.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    @Test("Knowledge pipeline persists entities claims edges and notes")
    func persistsKnowledgeArtifacts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Worked on [[Memograph]] inside [[Codex]] and investigated [[ScreenCaptureKit blink]] while comparing notes from [[X]].
            """,
            topAppsJson: """
            [{"name":"Codex","duration_min":45},{"name":"Safari","duration_min":15}]
            """,
            topTopicsJson: """
            ["Memograph","ScreenCaptureKit blink","X"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: "Investigate the residual audio blinking path",
            suggestedNotesJson: """
            ["False Positive ScreenCaptureKit Blink"]
            """,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "google/gemini-3-flash-preview",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Fix blinking"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T10:50:00Z",
                durationMs: 3_000_000,
                uncertaintyMode: "normal",
                contextTexts: ["Worked on Memograph audio fixes"]
            ),
            SessionData(
                sessionId: "s2",
                appName: "Safari",
                bundleId: "com.apple.Safari",
                windowTitles: ["X"],
                startedAt: "2026-04-03T10:50:00Z",
                endedAt: "2026-04-03T11:00:00Z",
                durationMs: 600_000,
                uncertaintyMode: "normal",
                contextTexts: ["Read X posts about ScreenCaptureKit"]
            )
        ]

        let vaultPath = NSTemporaryDirectory() + "kb_vault_\(UUID().uuidString)/"
        let exporter = ObsidianExporter(db: db, vaultPath: vaultPath, timeZone: utc)
        defer { try? FileManager.default.removeItem(atPath: vaultPath) }

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        let result = try pipeline.process(summary: summary, window: window, sessions: sessions, exporter: exporter)

        #expect(result.entityCount >= 4)
        #expect(result.claimCount >= 4)
        #expect(result.noteCount >= 1)

        let entityRows = try db.query("SELECT canonical_name, entity_type FROM knowledge_entities ORDER BY canonical_name")
        #expect(entityRows.contains { $0["canonical_name"]?.textValue == "Memograph" && $0["entity_type"]?.textValue == "project" })
        #expect(entityRows.contains { $0["canonical_name"]?.textValue == "Codex" && $0["entity_type"]?.textValue == "tool" })

        let noteRows = try db.query("SELECT title FROM knowledge_notes WHERE title = ?", params: [.text("Memograph")])
        #expect(noteRows.count == 1)

        let edgeRows = try db.query("SELECT COUNT(*) AS count FROM knowledge_edges")
        #expect((edgeRows.first?["count"]?.intValue ?? 0) > 0)
    }

    @Test("Knowledge pipeline respects applied alias overrides during extraction")
    func respectsAppliedAliasOverrides() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        var settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        settings.knowledgeAliasOverrides = [
            KnowledgeAliasOverrideRecord(
                sourceName: "OCR Accuracy in Memograph",
                canonicalName: "OCR",
                entityType: .topic,
                reason: "mergeOverlay",
                appliedAt: "2026-04-04T10:33:00Z"
            )
        ]

        let summary = DailySummaryRecord(
            date: "2026-04-04",
            summaryText: """
            ## Summary
            Investigated [[OCR Accuracy in Memograph]] while working on [[Memograph]].
            """,
            topAppsJson: """
            [{"name":"Codex","duration_min":30}]
            """,
            topTopicsJson: """
            ["OCR Accuracy in Memograph","Memograph"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-04T01:00:00Z","window_end":"2026-04-04T02:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-04T02:01:00Z",
            modelName: "google/gemini-3-flash-preview",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["OCR pass"],
                startedAt: "2026-04-04T01:00:00Z",
                endedAt: "2026-04-04T01:40:00Z",
                durationMs: 2_400_000,
                uncertaintyMode: "normal",
                contextTexts: ["Reviewed OCR extraction quality in Memograph"]
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc, settings: settings)
        let window = SummaryWindowDescriptor(
            date: "2026-04-04",
            start: ISO8601DateFormatter().date(from: "2026-04-04T01:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-04T02:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let entityRows = try db.query("SELECT canonical_name, entity_type FROM knowledge_entities ORDER BY canonical_name")
        #expect(entityRows.contains { $0["canonical_name"]?.textValue == "OCR" && $0["entity_type"]?.textValue == "topic" })
        #expect(!entityRows.contains { $0["canonical_name"]?.textValue == "OCR Accuracy in Memograph" && $0["entity_type"]?.textValue == "topic" })
    }

    @Test("Knowledge compiler builds index grouped by entity type")
    func buildsKnowledgeIndex() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("issue-1"), .text("ScreenCaptureKit Blink"), .text("screencapturekit-blink"), .text("issue"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z")
        ])
        try db.execute("""
            INSERT INTO knowledge_notes
                (id, note_type, title, body_markdown, source_date, export_obsidian_status, export_notion_status)
            VALUES (?, ?, ?, ?, ?, 'pending', 'pending'),
                   (?, ?, ?, ?, ?, 'pending', 'pending')
        """, params: [
            .text("knowledge:project-1"), .text("project"), .text("Memograph"), .text("# Memograph"), .text("2026-04-03"),
            .text("knowledge:issue-1"), .text("issue"), .text("ScreenCaptureKit Blink"), .text("# ScreenCaptureKit Blink"), .text("2026-04-03")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let index = try compiler.buildIndexMarkdown()

        #expect(index.contains("## Projects"))
        #expect(index.contains("[[Knowledge/Projects/memograph|Memograph]]"))
        #expect(index.contains("## Issues"))
        #expect(index.contains("[[Knowledge/Issues/screencapturekit-blink|ScreenCaptureKit Blink]]"))
    }

    @Test("Knowledge sync exports maintenance report with review queue")
    func exportsKnowledgeMaintenanceReport() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("project-2"), .text("autopilot"), .text("autopilot"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("project-3"), .text("geminicode"), .text("geminicode"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("lesson-1"), .text("macOS System Audio Capture Guide"), .text("macos-system-audio-capture-guide"), .text("lesson"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("project-1"), .text("advanced_during_window"), .text("2026-04-03"), .real(0.9), .text("hourly_summary"),
            .text("claim-2"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("project-2"), .text("advanced_during_window"), .text("2026-04-03"), .real(0.9), .text("hourly_summary"),
            .text("claim-3"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("project-3"), .text("advanced_during_window"), .text("2026-04-03"), .real(0.9), .text("hourly_summary"),
            .text("claim-4"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("lesson-1"), .text("derived_from_project"), .text("Memograph"), .real(0.8), .text("relation_inference")
        ])

        try db.execute("""
            INSERT INTO knowledge_edges
                (id, from_entity_id, to_entity_id, edge_type, weight, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("edge-1"), .text("project-1"), .text("lesson-1"), .text("generates_lesson"), .real(1),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-2"), .text("project-2"), .text("lesson-1"), .text("generates_lesson"), .real(1),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-3"), .text("project-3"), .text("lesson-1"), .text("generates_lesson"), .real(1),
            .text("2026-04-03T11:01:00Z")
        ])

        let vaultPath = NSTemporaryDirectory() + "kb_vault_\(UUID().uuidString)/"
        let exporter = ObsidianExporter(db: db, vaultPath: vaultPath, timeZone: utc)
        defer { try? FileManager.default.removeItem(atPath: vaultPath) }

        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        var settings = AppSettings(
            defaults: defaults,
            credentialsStore: InMemoryCredentialsStore(),
            legacyCredentialsStore: InMemoryCredentialsStore()
        )
        settings.knowledgeAppliedActions = [
            KnowledgeAppliedActionRecord(
                appliedAt: "2026-04-04T10:33:00Z",
                kind: .lessonPromotion,
                title: "Codex Workflow for AI Founders",
                sourceEntityId: "topic-codex-workflow",
                applyTargetRelativePath: "Lessons/codex-workflow-for-ai-founders.md",
                appliedPath: (vaultPath as NSString).appendingPathComponent("Knowledge/Lessons/codex-workflow-for-ai-founders.md"),
                backupPath: (vaultPath as NSString).appendingPathComponent("Knowledge/_drafts/AppliedBackup/20260404-103351/Lessons/codex-workflow-for-ai-founders.md")
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc, settings: settings)
        _ = try pipeline.syncMaterializedKnowledge(exporter: exporter)

        let maintenancePath = (vaultPath as NSString).appendingPathComponent("Knowledge/_maintenance.md")
        let maintenance = try String(contentsOfFile: maintenancePath, encoding: .utf8)

        #expect(maintenance.contains("# Memograph Обслуживание слоя знаний"))
        #expect(maintenance.contains("## Снимок"))
        #expect(maintenance.contains("## Дашборд"))
        #expect(maintenance.contains("[[Knowledge/_drafts/_index|центр управления]]"))
        #expect(maintenance.contains("## Следующие действия"))
        #expect(maintenance.contains("## Очередь ревью"))
        #expect(maintenance.contains("## Safe Auto-Actions"))
        #expect(maintenance.contains("## Кандидаты на улучшение"))
        #expect(maintenance.contains("## Недавно применено"))
        #expect(maintenance.contains("## Горячие точки"))
        #expect(maintenance.contains("Автоматически пониженные широкие выводы"))
        #expect(maintenance.contains("macOS System Audio Capture Guide"))
        #expect(maintenance.contains("Codex Workflow for AI Founders"))
    }

    @Test("Knowledge sync excludes suppressed entities from materialized notes")
    func syncExcludesSuppressedEntities() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z")
        ])
        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("project-1"), .text("advanced_during_window"), .text("2026-04-03"), .real(0.9), .text("hourly_summary")
        ])

        let vaultPath = NSTemporaryDirectory() + "kb_vault_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultPath) }
        let exporter = ObsidianExporter(db: db, vaultPath: vaultPath, timeZone: utc)

        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        var settings = AppSettings(
            defaults: defaults,
            credentialsStore: InMemoryCredentialsStore(),
            legacyCredentialsStore: InMemoryCredentialsStore()
        )
        settings.knowledgeSuppressedEntityIds = ["project-1"]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc, settings: settings)
        let noteCount = try pipeline.syncMaterializedKnowledge(exporter: exporter)

        #expect(noteCount == 0)
        let noteRows = try db.query("SELECT COUNT(*) AS count FROM knowledge_notes")
        #expect(noteRows.first?["count"]?.intValue == 0)
        let projectPath = (vaultPath as NSString).appendingPathComponent("Knowledge/Projects/memograph.md")
        #expect(!FileManager.default.fileExists(atPath: projectPath))
    }

    @Test("Knowledge maintenance suppresses commodity weak topics and prioritizes project-connected hotspots")
    func maintenanceSuppressesCommodityNoiseAndRanksHotspots() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let maintenance = KnowledgeMaintenance(db: db, timeZone: utc)
        let shaper = GraphShaper()

        let memograph = KnowledgeEntityRecord(
            id: "project-1",
            canonicalName: "Memograph",
            slug: "memograph",
            entityType: .project,
            aliasesJson: nil,
            firstSeenAt: nil,
            lastSeenAt: nil
        )
        let gpu = KnowledgeEntityRecord(
            id: "topic-1",
            canonicalName: "GPU",
            slug: "gpu",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: nil,
            lastSeenAt: nil
        )
        let nvidiaTesla = KnowledgeEntityRecord(
            id: "topic-2",
            canonicalName: "NVIDIA Tesla",
            slug: "nvidia-tesla",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: nil,
            lastSeenAt: nil
        )
        let systemAudio = KnowledgeEntityRecord(
            id: "topic-3",
            canonicalName: "System Audio Capture",
            slug: "system-audio-capture",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: nil,
            lastSeenAt: nil
        )

        let metrics = [
            KnowledgeEntityMetrics(
                entity: memograph,
                claimCount: 20,
                typedEdgeCount: 18,
                coOccurrenceEdgeCount: 2,
                projectRelationCount: 6
            ),
            KnowledgeEntityMetrics(
                entity: gpu,
                claimCount: 3,
                typedEdgeCount: 0,
                coOccurrenceEdgeCount: 44,
                projectRelationCount: 0
            ),
            KnowledgeEntityMetrics(
                entity: nvidiaTesla,
                claimCount: 18,
                typedEdgeCount: 17,
                coOccurrenceEdgeCount: 44,
                projectRelationCount: 0
            ),
            KnowledgeEntityMetrics(
                entity: systemAudio,
                claimCount: 9,
                typedEdgeCount: 8,
                coOccurrenceEdgeCount: 34,
                projectRelationCount: 2
            )
        ]

        let markdown = try maintenance.buildMarkdown(
            metrics: metrics,
            materializedEntityIds: Set(["project-1", "topic-2", "topic-3"]),
            graphShaper: shaper
        )

        #expect(markdown.contains("Подавлено слабых товарных тем: 1"))
        #expect(markdown.contains("Подавленные слабые товарные темы: 1"))
        #expect(markdown.contains("GPU"))
        #expect(!markdown.contains("NVIDIA Tesla"))

        let memographRange = markdown.range(of: "[[Knowledge/Projects/memograph|Memograph]]")
        let nvidiaRange = markdown.range(of: "[[Knowledge/Topics/nvidia-tesla|NVIDIA Tesla]]")
        let systemAudioRange = markdown.range(of: "[[Knowledge/Topics/system-audio-capture|System Audio Capture]]")

        #expect(memographRange != nil)
        #expect(systemAudioRange != nil)
        #expect(nvidiaRange == nil)
        #expect(systemAudioRange!.lowerBound > memographRange!.lowerBound)
    }

    @Test("Knowledge maintenance surfaces reclassify consolidation and stale review candidates")
    func maintenanceSurfacesImprovementCandidates() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let maintenance = KnowledgeMaintenance(db: db, timeZone: utc)
        let shaper = GraphShaper()

        let rootTopic = KnowledgeEntityRecord(
            id: "topic-1",
            canonicalName: "TurboQuant",
            slug: "turboquant",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: "2026-04-03T10:00:00Z",
            lastSeenAt: "2026-04-03T11:00:00Z"
        )
        let expandedTopic = KnowledgeEntityRecord(
            id: "topic-2",
            canonicalName: "TurboQuant Algorithm",
            slug: "turboquant-algorithm",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: "2026-04-03T10:00:00Z",
            lastSeenAt: "2026-04-03T11:00:00Z"
        )
        let workflowTopic = KnowledgeEntityRecord(
            id: "topic-3",
            canonicalName: "Codex Workflow for AI Founders",
            slug: "codex-workflow-for-ai-founders",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: "2026-04-03T10:00:00Z",
            lastSeenAt: "2026-04-03T11:00:00Z"
        )
        let staleTool = KnowledgeEntityRecord(
            id: "tool-1",
            canonicalName: "Old Utility",
            slug: "old-utility",
            entityType: .tool,
            aliasesJson: nil,
            firstSeenAt: "2020-01-01T00:00:00Z",
            lastSeenAt: "2020-01-02T00:00:00Z"
        )

        let metrics = [
            KnowledgeEntityMetrics(
                entity: rootTopic,
                claimCount: 5,
                typedEdgeCount: 4,
                coOccurrenceEdgeCount: 10,
                projectRelationCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: expandedTopic,
                claimCount: 2,
                typedEdgeCount: 2,
                coOccurrenceEdgeCount: 6,
                projectRelationCount: 0
            ),
            KnowledgeEntityMetrics(
                entity: workflowTopic,
                claimCount: 4,
                typedEdgeCount: 3,
                coOccurrenceEdgeCount: 5,
                projectRelationCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: staleTool,
                claimCount: 2,
                typedEdgeCount: 1,
                coOccurrenceEdgeCount: 1,
                projectRelationCount: 0
            )
        ]

        let artifacts = try maintenance.buildArtifacts(
            metrics: metrics,
            materializedEntityIds: Set(["topic-1", "topic-2", "topic-3", "tool-1"]),
            graphShaper: shaper
        )
        let markdown = artifacts.markdown

        #expect(markdown.contains("## Кандидаты на улучшение"))
        #expect(markdown.contains("## Safe Auto-Actions"))
        #expect(markdown.contains("## Следующие действия"))
        #expect(markdown.contains("[[Knowledge/_drafts/_index|центр управления]]"))
        #expect(markdown.contains("[[Knowledge/_drafts/Apply/_index|доска применения]]"))
        #expect(markdown.contains("Высокоприоритетных элементов ревью:"))
        #expect(markdown.contains("Обычных элементов ревью:"))
        #expect(markdown.contains("Низкосигнальных элементов ревью:"))
        #expect(markdown.contains("### Безопасно применить"))
        #expect(markdown.contains("Перенести [[Knowledge/Topics/codex-workflow-for-ai-founders|Codex Workflow for AI Founders]] в `Lessons`."))
        #expect(markdown.contains("Сконсолидировать [[Knowledge/Topics/turboquant-algorithm|TurboQuant Algorithm]] в [[Knowledge/Topics/turboquant|TurboQuant]]."))
        #expect(markdown.contains("### Требует ревью"))
        #expect(markdown.contains("[[Knowledge/_drafts/Review/_index|доска ревью]]"))
        #expect(markdown.contains("[Средний] [[Knowledge/Tools/old-utility|Old Utility]]"))
        #expect(!markdown.contains("[Low]"))
        #expect(markdown.contains("[[Knowledge/Tools/old-utility|Old Utility]] — не обновлялась уже"))
        #expect(markdown.contains("[[Knowledge/_drafts/Review/stale-old-utility|ревью]]"))
        #expect(markdown.contains("### Черновики повышения в Lessons"))
        #expect(markdown.contains("[[Knowledge/Topics/codex-workflow-for-ai-founders|Codex Workflow for AI Founders]]"))
        #expect(markdown.contains("высокоуверенная заметка, которая уже ведет себя как устойчивый вывод"))
        #expect(markdown.contains("[[Knowledge/_drafts/Maintenance/lesson-promotion-codex-workflow-for-ai-founders|черновик ревью]]"))
        #expect(markdown.contains("[[Knowledge/_drafts/Apply/Lessons/codex-workflow-for-ai-founders|готовый черновик вывода]]"))
        #expect(markdown.contains("[[Knowledge/_drafts/Apply/Redirects/codex-workflow-for-ai-founders-to-lesson|редирект]]"))
        #expect(markdown.contains("### Безопасные консолидации"))
        #expect(markdown.contains("[[Knowledge/Topics/turboquant-algorithm|TurboQuant Algorithm]] → [[Knowledge/Topics/turboquant|TurboQuant]]"))
        #expect(markdown.contains("сильная корневая заметка уже доминирует в этом семействе тем"))
        #expect(markdown.contains("[[Knowledge/_drafts/Maintenance/consolidate-turboquant-algorithm-into-turboquant|черновик ревью]]"))
        #expect(markdown.contains("[[Knowledge/_drafts/Apply/Redirects/turboquant-algorithm-to-turboquant|редирект]]"))
        #expect(markdown.contains("[[Knowledge/_drafts/Apply/Merge/turboquant-algorithm-into-turboquant|патч слияния]]"))
        #expect(!markdown.contains("### Кандидаты на переклассификацию"))
        #expect(!markdown.contains("Codex Workflow for AI Founders]] — consider moving to Lessons"))
        #expect(!markdown.contains("### Кандидаты на консолидацию"))
        #expect(!markdown.contains("[[Knowledge/Topics/turboquant-algorithm|TurboQuant Algorithm]] → [[Knowledge/Topics/turboquant|TurboQuant]] — overlapping topic family; consider consolidating under the stronger root note"))
        #expect(markdown.contains("### Кандидаты на ревью устаревания"))
        #expect(markdown.contains("[[Knowledge/Tools/old-utility|Old Utility]]"))
        #expect(markdown.contains("заметка почти не поддерживается и уже не имеет активного следа по проектам"))
        #expect(markdown.contains("Ревью: [[Knowledge/_drafts/Review/stale-old-utility|черновик ревью]]"))
        #expect(artifacts.draftArtifacts.count == 10)
        #expect(artifacts.draftArtifacts.contains { $0.relativePath == "_index.md" && $0.kind == .workflowIndex })
        let reviewBoard = artifacts.draftArtifacts.first { $0.relativePath == "Review/_index.md" }?.markdown ?? ""
        #expect(reviewBoard.contains("## Сводка по приоритетам"))
        #expect(reviewBoard.contains("Высокий приоритет: 0"))
        #expect(reviewBoard.contains("Обычное ревью: 1"))
        #expect(reviewBoard.contains("Низкосигнальное ревью: 0"))
        #expect(reviewBoard.contains("## Обычное ревью"))
        #expect(reviewBoard.contains("Устаревшее: [[Knowledge/Tools/old-utility|Old Utility]]"))
        let workflowBoard = artifacts.draftArtifacts.first { $0.relativePath == "_index.md" }?.markdown ?? ""
        #expect(workflowBoard.contains("## Рекомендуемые следующие шаги"))
        #expect(workflowBoard.contains("Применить: перенести [[Knowledge/Topics/codex-workflow-for-ai-founders|Codex Workflow for AI Founders]] в `Lessons`."))
        #expect(workflowBoard.contains("Ревью [Средний]: [[Knowledge/Tools/old-utility|Old Utility]] — не обновлялась уже"))
    }

    @Test("Knowledge maintenance suppresses already applied promotions and consolidations")
    func maintenanceSuppressesAlreadyAppliedCandidates() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let maintenance = KnowledgeMaintenance(db: db, timeZone: utc)
        let shaper = GraphShaper()

        let rootTopic = KnowledgeEntityRecord(
            id: "topic-1",
            canonicalName: "TurboQuant",
            slug: "turboquant",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: "2026-04-03T10:00:00Z",
            lastSeenAt: "2026-04-03T11:00:00Z"
        )
        let expandedTopic = KnowledgeEntityRecord(
            id: "topic-2",
            canonicalName: "TurboQuant Algorithm",
            slug: "turboquant-algorithm",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: "2026-04-03T10:00:00Z",
            lastSeenAt: "2026-04-03T11:00:00Z"
        )
        let workflowTopic = KnowledgeEntityRecord(
            id: "topic-3",
            canonicalName: "Codex Workflow for AI Founders",
            slug: "codex-workflow-for-ai-founders",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: "2026-04-03T10:00:00Z",
            lastSeenAt: "2026-04-03T11:00:00Z"
        )
        let staleTool = KnowledgeEntityRecord(
            id: "tool-1",
            canonicalName: "Old Utility",
            slug: "old-utility",
            entityType: .tool,
            aliasesJson: nil,
            firstSeenAt: "2020-01-01T00:00:00Z",
            lastSeenAt: "2020-01-02T00:00:00Z"
        )

        let metrics = [
            KnowledgeEntityMetrics(
                entity: rootTopic,
                claimCount: 5,
                typedEdgeCount: 4,
                coOccurrenceEdgeCount: 10,
                projectRelationCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: expandedTopic,
                claimCount: 2,
                typedEdgeCount: 2,
                coOccurrenceEdgeCount: 6,
                projectRelationCount: 0
            ),
            KnowledgeEntityMetrics(
                entity: workflowTopic,
                claimCount: 4,
                typedEdgeCount: 3,
                coOccurrenceEdgeCount: 5,
                projectRelationCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: staleTool,
                claimCount: 2,
                typedEdgeCount: 1,
                coOccurrenceEdgeCount: 1,
                projectRelationCount: 0
            )
        ]

        let appliedActions = [
            KnowledgeAppliedActionRecord(
                appliedAt: "2026-04-04T10:33:00Z",
                kind: .lessonPromotion,
                title: "Codex Workflow for AI Founders",
                sourceEntityId: "topic-3",
                applyTargetRelativePath: "Lessons/codex-workflow-for-ai-founders.md",
                appliedPath: "/tmp/Knowledge/Lessons/codex-workflow-for-ai-founders.md"
            ),
            KnowledgeAppliedActionRecord(
                appliedAt: "2026-04-04T10:35:00Z",
                kind: .mergeOverlay,
                title: "TurboQuant Algorithm",
                sourceEntityId: "topic-2",
                applyTargetRelativePath: "Topics/turboquant.md",
                appliedPath: "/tmp/Knowledge/Topics/turboquant.md",
                targetTitle: "TurboQuant"
            )
        ]
        let aliasOverrides = [
            KnowledgeAliasOverrideRecord(
                sourceName: "Codex Workflow for AI Founders",
                canonicalName: "Codex Workflow for AI Founders",
                entityType: .lesson,
                reason: "lessonPromotion",
                appliedAt: "2026-04-04T10:33:00Z"
            ),
            KnowledgeAliasOverrideRecord(
                sourceName: "TurboQuant Algorithm",
                canonicalName: "TurboQuant",
                entityType: .topic,
                reason: "mergeOverlay",
                appliedAt: "2026-04-04T10:35:00Z"
            )
        ]

        let artifacts = try maintenance.buildArtifacts(
            metrics: metrics,
            materializedEntityIds: Set(["topic-1", "topic-2", "topic-3", "tool-1"]),
            graphShaper: shaper,
            appliedActions: appliedActions,
            aliasOverrides: aliasOverrides
        )
        let markdown = artifacts.markdown

        #expect(markdown.contains("## Safe Auto-Actions"))
        #expect(markdown.contains("- Сейчас нет auto-action с высоким уровнем уверенности."))
        #expect(markdown.contains("## Кандидаты на улучшение"))
        #expect(markdown.contains("[[Knowledge/_drafts/_index|центр управления]]"))
        #expect(markdown.contains("Обычных элементов ревью: 1"))
        #expect(markdown.contains("Низкосигнальных элементов ревью: 0"))
        #expect(markdown.contains("[[Knowledge/Tools/old-utility|Old Utility]]"))
        #expect(markdown.contains("## Недавно применено"))
        #expect(markdown.contains("Codex Workflow for AI Founders"))
        #expect(markdown.contains("TurboQuant Algorithm"))
        #expect(!markdown.contains("consider moving to Lessons"))
        #expect(!markdown.contains("[[Knowledge/Topics/turboquant-algorithm|TurboQuant Algorithm]] → [[Knowledge/Topics/turboquant|TurboQuant]]"))
        #expect(markdown.contains("## Следующие действия"))
        #expect(markdown.contains("[[Knowledge/_drafts/Review/_index|доска ревью]]"))
        #expect(markdown.contains("[[Knowledge/_drafts/Review/stale-old-utility|ревью]]"))
        #expect(artifacts.draftArtifacts.count == 3)
        #expect(artifacts.draftArtifacts.contains { $0.relativePath == "_index.md" && $0.kind == .workflowIndex })
    }

    @Test("Knowledge maintenance suppresses dismissed review candidates and shows review history")
    func maintenanceSuppressesDismissedReviewCandidates() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let maintenance = KnowledgeMaintenance(db: db, timeZone: utc)
        let shaper = GraphShaper()

        let rootTopic = KnowledgeEntityRecord(
            id: "topic-1",
            canonicalName: "TurboQuant",
            slug: "turboquant",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: "2026-04-03T10:00:00Z",
            lastSeenAt: "2026-04-03T11:00:00Z"
        )
        let expandedTopic = KnowledgeEntityRecord(
            id: "topic-2",
            canonicalName: "TurboQuant Algorithm",
            slug: "turboquant-algorithm",
            entityType: .topic,
            aliasesJson: nil,
            firstSeenAt: "2026-04-03T10:00:00Z",
            lastSeenAt: "2026-04-03T11:00:00Z"
        )
        let staleTool = KnowledgeEntityRecord(
            id: "tool-1",
            canonicalName: "Old Utility",
            slug: "old-utility",
            entityType: .tool,
            aliasesJson: nil,
            firstSeenAt: "2020-01-01T00:00:00Z",
            lastSeenAt: "2020-01-02T00:00:00Z"
        )

        let metrics = [
            KnowledgeEntityMetrics(
                entity: rootTopic,
                claimCount: 5,
                typedEdgeCount: 4,
                coOccurrenceEdgeCount: 10,
                projectRelationCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: expandedTopic,
                claimCount: 2,
                typedEdgeCount: 2,
                coOccurrenceEdgeCount: 6,
                projectRelationCount: 0
            ),
            KnowledgeEntityMetrics(
                entity: staleTool,
                claimCount: 2,
                typedEdgeCount: 1,
                coOccurrenceEdgeCount: 1,
                projectRelationCount: 0
            )
        ]

        let reviewDecisions = [
            KnowledgeReviewDecisionRecord(
                key: "consolidate:topic-2->topic-1",
                kind: .consolidate,
                status: .dismiss,
                title: "Review Packet — Consolidate TurboQuant Algorithm",
                path: "/tmp/Knowledge/_drafts/Review/consolidate-turboquant-algorithm-into-turboquant.md",
                recordedAt: "2026-04-04T12:00:00Z"
            ),
            KnowledgeReviewDecisionRecord(
                key: "stale:tool-1",
                kind: .suppress,
                status: .dismiss,
                title: "Review Packet — Stale Note Old Utility",
                path: "/tmp/Knowledge/_drafts/Review/stale-old-utility.md",
                recordedAt: "2026-04-04T12:05:00Z"
            )
        ]

        let artifacts = try maintenance.buildArtifacts(
            metrics: metrics,
            materializedEntityIds: Set(["topic-1", "topic-2", "tool-1"]),
            graphShaper: shaper,
            reviewDecisions: reviewDecisions
        )
        let markdown = artifacts.markdown

        #expect(markdown.contains("## Недавно отревьюено"))
        #expect(markdown.contains("отклонено"))
        #expect(markdown.contains("stale-old-utility"))
        #expect(markdown.contains("consolidate-turboquant-algorithm-into-turboquant"))
        #expect(!markdown.contains("### Кандидаты на ревью устаревания"))
        #expect(!markdown.contains("[[Knowledge/Tools/old-utility|Old Utility]] — не обновлялась"))
        #expect(!markdown.contains("### Кандидаты на консолидацию"))
        #expect(!markdown.contains("[[Knowledge/Topics/turboquant-algorithm|TurboQuant Algorithm]] → [[Knowledge/Topics/turboquant|TurboQuant]]"))
        #expect(!artifacts.draftArtifacts.contains { $0.relativePath.contains("stale-old-utility") })
        #expect(!artifacts.draftArtifacts.contains { $0.relativePath.contains("consolidate-turboquant-algorithm-into-turboquant") })
    }

    @Test("Knowledge compiler renders readable signals aliases and grouped related entities")
    func rendersReadableKnowledgeNote() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, aliases_json, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("tool-1"), .text("Claude"), .text("claude"), .text("tool"),
            .text("[\"Claude.app\"]"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .null,
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("tool-1"), .text("used_during_window"), .text("2026-04-03 10:00-11:00"), .real(0.9), .text("hourly_summary"),
            .text("claim-2"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("tool-1"), .text("topic_in_focus"), .text("2026-04-03"), .real(0.7), .text("hourly_summary")
        ])

        try db.execute("""
            INSERT INTO knowledge_edges
                (id, from_entity_id, to_entity_id, edge_type, weight, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("edge-1"), .text("tool-1"), .text("project-1"), .text("co_occurs_with"), .real(2),
            .text("2026-04-03T11:01:00Z")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "tool-1", sourceDate: "2026-04-03")

        #expect(note != nil)
        #expect(note?.bodyMarkdown.contains("## Обзор") == true)
        #expect(note?.bodyMarkdown.contains("Недавняя активность помещает этот инструмент") == true)
        #expect(note?.bodyMarkdown.contains("## Алиасы") == true)
        #expect(note?.bodyMarkdown.contains("Claude.app") == true)
        #expect(note?.bodyMarkdown.contains("## Ключевые сигналы") == true)
        #expect(note?.bodyMarkdown.contains("Зафиксирован:") == true)
        #expect(note?.bodyMarkdown.contains("## Недавние окна") == true)
        #expect(note?.bodyMarkdown.contains("Активно в 2026-04-03 10:00-11:00.") == true)
        #expect(note?.bodyMarkdown.contains("### Проекты") == true)
        #expect(note?.bodyMarkdown.contains("[[Knowledge/Projects/memograph|Memograph]]") == true)
    }

    @Test("Project notes suppress generic topic relations and avoid topic in focus self-noise")
    func suppressesGenericProjectTopicNoise() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Worked on [[Memograph]] in [[Codex]] while researching [[AI]] and debugging [[Screen Recording]].
            """,
            topAppsJson: """
            [{"name":"Codex","duration_min":45}]
            """,
            topTopicsJson: """
            ["Memograph","AI","Screen Recording"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "test",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Memograph"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T11:00:00Z",
                durationMs: 3_600_000,
                uncertaintyMode: "normal",
                contextTexts: ["Worked on Memograph"]
            )
        ]

        let vaultPath = NSTemporaryDirectory() + "kb_vault_\(UUID().uuidString)/"
        let exporter = ObsidianExporter(db: db, vaultPath: vaultPath, timeZone: utc)
        defer { try? FileManager.default.removeItem(atPath: vaultPath) }

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions, exporter: exporter)

        let projectClaims = try db.query("""
            SELECT kc.predicate, kc.object_text
            FROM knowledge_claims kc
            JOIN knowledge_entities ke ON ke.id = kc.subject_entity_id
            WHERE ke.canonical_name = 'Memograph'
            ORDER BY kc.predicate, kc.object_text
        """)

        #expect(projectClaims.contains {
            $0["predicate"]?.textValue == "focuses_on_topic" &&
            $0["object_text"]?.textValue == "Screen Recording"
        })
        #expect(projectClaims.contains {
            $0["predicate"]?.textValue == "focuses_on_topic" &&
            $0["object_text"]?.textValue == "AI"
        } == false)
        #expect(projectClaims.contains {
            $0["predicate"]?.textValue == "topic_in_focus"
        } == false)
    }

    @Test("Recent windows prioritizes real activity over relation spam")
    func recentWindowsPrioritizesActivitySignals() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("tool-1"), .text("ChatGPT"), .text("chatgpt"), .text("tool"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("tool-2"), .text("Codex"), .text("codex"), .text("tool"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("tool-3"), .text("Telegram"), .text("telegram"), .text("tool"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("topic-1"), .text("System Audio Capture"), .text("system-audio-capture"), .text("topic"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("used_during_window"), .text("2026-04-03 20:02-21:02"), .real(0.95), .text("hourly_summary"),
            .text("claim-2"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("advanced_during_window"), .text("2026-04-03"), .real(0.9), .text("hourly_summary"),
            .text("claim-3"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("uses_tool"), .text("ChatGPT"), .real(0.9), .text("relation_inference"),
            .text("claim-4"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("uses_tool"), .text("Codex"), .real(0.9), .text("relation_inference"),
            .text("claim-5"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("uses_tool"), .text("Telegram"), .real(0.9), .text("relation_inference"),
            .text("claim-6"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("focuses_on_topic"), .text("System Audio Capture"), .real(0.88), .text("relation_inference")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "project-1", sourceDate: "2026-04-03")
        let windowMarkerCount = note?.bodyMarkdown.components(separatedBy: "[2026-04-03 20:02]").count ?? 0

        #expect(note?.bodyMarkdown.contains("Активно в 2026-04-03 20:02-21:02") == true)
        #expect(note?.bodyMarkdown.contains("развивалось в сводке") == true)
        #expect(note?.bodyMarkdown.contains("с ChatGPT") == true)
        #expect(note?.bodyMarkdown.contains("с Codex") == true)
        #expect(note?.bodyMarkdown.contains("сфокусировано на System Audio Capture") == true)
        #expect(note?.bodyMarkdown.contains("с Telegram") == false)
        #expect(windowMarkerCount == 2)
    }

    @Test("Recent windows ranks richer activity windows ahead of newer sparse relation-only windows")
    func recentWindowsRanksRicherWindowsAheadOfSparseOnes() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T23:02:00Z"),
            .text("tool-1"), .text("Codex"), .text("codex"), .text("tool"),
            .text("2026-04-03T22:02:00Z"), .text("2026-04-03T23:02:00Z"),
            .text("topic-1"), .text("OCR"), .text("ocr"), .text("topic"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z")
        ])

        try db.execute("""
            INSERT INTO daily_summaries
                (date, summary_text, top_apps_json, top_topics_json, context_switches_json,
                 unfinished_items_json, suggested_notes_json, generated_at, model_name,
                 token_usage_input, token_usage_output, generation_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("2026-04-03"),
            .text("""
            ## Summary
            Worked deeply on [[Memograph]] and stabilized the OCR export loop.

            ## Проекты и код
            ### [[Memograph]]
            - Проверка hourly summary и экспорта в Obsidian.
            - Разбор OCR-пайплайна и качества знания в graph notes.
            """),
            .text("[{\"name\":\"Memograph\",\"duration_min\":40}]"),
            .text("[\"OCR\"]"),
            .text("{\"window_start\":\"2026-04-03T20:02:00Z\",\"window_end\":\"2026-04-03T21:02:00Z\",\"mode\":\"hourly\"}"),
            .null,
            .null,
            .text("2026-04-03T21:02:46Z"),
            .text("test"),
            .integer(0),
            .integer(0),
            .text("success")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("used_during_window"), .text("2026-04-03 20:02-21:02"), .real(0.95), .text("hourly_summary"),
            .text("claim-2"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("advanced_during_window"), .text("2026-04-03"), .real(0.9), .text("hourly_summary"),
            .text("claim-3"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("focuses_on_topic"), .text("OCR"), .real(0.85), .text("relation_inference"),
            .text("claim-4"),
            .text("2026-04-03T22:02:00Z"), .text("2026-04-03T23:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T23:02:46Z"),
            .text("project-1"), .text("uses_tool"), .text("Codex"), .real(0.8), .text("relation_inference")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "project-1", sourceDate: "2026-04-03")
        let body = note?.bodyMarkdown ?? ""

        let richWindowRange = body.range(of: "[2026-04-03 20:02]")
        let sparseWindowRange = body.range(of: "[2026-04-03 22:02]")

        #expect(richWindowRange != nil)
        #expect(sparseWindowRange != nil)
        if let richWindowRange, let sparseWindowRange {
            #expect(richWindowRange.lowerBound < sparseWindowRange.lowerBound)
        }
        #expect(body.contains("Контекст: Проверка hourly summary и экспорта в Obsidian.") == true)
    }

    @Test("Project recent windows include compact summary context when available")
    func projectRecentWindowsIncludeSummaryContext() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, aliases_json, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text(#"["MyMacAgent"]"#),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("used_during_window"), .text("2026-04-03 20:02-21:02"), .real(0.95), .text("hourly_summary"),
            .text("claim-2"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("project-1"), .text("advanced_during_window"), .text("2026-04-03"), .real(0.9), .text("hourly_summary")
        ])

        try db.execute("""
            INSERT INTO daily_summaries
                (date, summary_text, generated_at, generation_status)
            VALUES (?, ?, ?, ?)
        """, params: [
            .text("2026-04-03"),
            .text("""
                ## Summary
                Worked on [[Memograph]] while monitoring background stability.

                ## Проекты и код

                ### [[Memograph]] / [[MyMacAgent]]
                - **Task**: Stabilize the background runtime.
                - **Events**: Notifications through [[UserNotificationCenter]] indicated active capture work.
                """),
            .text("2026-04-03T21:02:46Z"),
            .text("success")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "project-1", sourceDate: "2026-04-03")

        #expect(note?.bodyMarkdown.contains("Активно в 2026-04-03 20:02-21:02") == true)
        #expect(note?.bodyMarkdown.contains("Контекст: Stabilize the background runtime. Notifications through UserNotificationCenter indicated active capture work.") == true)
    }

    @Test("Topic recent windows include compact summary context when available")
    func topicRecentWindowsIncludeSummaryContext() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("topic-1"), .text("System Audio Capture"), .text("system-audio-capture"), .text("topic"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("topic-1"), .text("topic_in_focus"), .text("2026-04-03"), .real(0.92), .text("hourly_summary")
        ])

        try db.execute("""
            INSERT INTO daily_summaries
                (date, summary_text, generated_at, generation_status)
            VALUES (?, ?, ?, ?)
        """, params: [
            .text("2026-04-03"),
            .text("""
                ## Summary
                Work on [[Memograph]] included planning [[System Audio Capture]] through [[ScreenCaptureKit]] to reduce background blinking.
                """),
            .text("2026-04-03T21:02:46Z"),
            .text("success")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "topic-1", sourceDate: "2026-04-03")

        #expect(note?.bodyMarkdown.contains("В фокусе этой сводки.") == true || note?.bodyMarkdown.contains("В фокусе сводки.") == true)
        #expect(note?.bodyMarkdown.contains("Контекст: Work on Memograph included planning System Audio Capture through ScreenCaptureKit to reduce background blinking.") == true)
    }

    @Test("Tool notes prioritize project and topic evidence in signals and recent windows")
    func toolNotesPrioritizeProjectAndTopicEvidence() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("tool-1"), .text("Codex"), .text("codex"), .text("tool"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("project-2"), .text("geminicode"), .text("geminicode"), .text("project"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("topic-1"), .text("OCR"), .text("ocr"), .text("topic"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("2026-04-04"), .text("2026-04-04T05:01:00Z"),
            .text("tool-1"), .text("used_during_window"), .text("2026-04-04 04:00-05:00"), .real(0.9), .text("hourly_summary"),
            .text("claim-2"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("2026-04-04"), .text("2026-04-04T05:01:00Z"),
            .text("tool-1"), .text("supports_project"), .text("Memograph"), .real(0.9), .text("relation_inference"),
            .text("claim-3"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("2026-04-04"), .text("2026-04-04T05:01:00Z"),
            .text("tool-1"), .text("used_in_project"), .text("Memograph"), .real(0.8), .text("relation_inference"),
            .text("claim-4"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("2026-04-04"), .text("2026-04-04T05:01:00Z"),
            .text("tool-1"), .text("supports_project"), .text("geminicode"), .real(0.8), .text("relation_inference"),
            .text("claim-5"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("2026-04-04"), .text("2026-04-04T05:01:00Z"),
            .text("tool-1"), .text("works_on_topic"), .text("OCR"), .real(0.8), .text("relation_inference")
        ])

        try db.execute("""
            INSERT INTO knowledge_edges
                (id, from_entity_id, to_entity_id, edge_type, weight, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("edge-1"), .text("tool-1"), .text("project-1"), .text("co_occurs_with"), .real(2),
            .text("2026-04-04T05:01:00Z"),
            .text("edge-2"), .text("tool-1"), .text("project-2"), .text("co_occurs_with"), .real(1),
            .text("2026-04-04T05:01:00Z"),
            .text("edge-3"), .text("tool-1"), .text("topic-1"), .text("works_on_topic"), .real(1),
            .text("2026-04-04T05:01:00Z")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "tool-1", sourceDate: "2026-04-04")

        #expect(note?.bodyMarkdown.contains("Главные проекты: Memograph и geminicode;") == true)
        #expect(note?.bodyMarkdown.contains("and 1 more") == false)
        #expect(note?.bodyMarkdown.contains("Чаще всего использовался для: OCR;") == true)
        #expect(note?.bodyMarkdown.contains("использовался при работе над Memograph") == true)
        #expect(note?.bodyMarkdown.contains("исследуя OCR") == true)
    }

    @Test("Lesson recent windows include proposed note context when available")
    func lessonRecentWindowsIncludeSuggestedNoteContext() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("lesson-1"), .text("macOS System Audio Capture Guide"), .text("macos-system-audio-capture-guide"), .text("lesson"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T20:02:00Z"), .text("2026-04-03T21:02:00Z"),
            .text("2026-04-03"), .text("2026-04-03T21:02:46Z"),
            .text("lesson-1"), .text("worth_capturing"), .text("2026-04-03"), .real(0.92), .text("summary_suggestion")
        ])

        try db.execute("""
            INSERT INTO daily_summaries
                (date, summary_text, generated_at, generation_status)
            VALUES (?, ?, ?, ?)
        """, params: [
            .text("2026-04-03"),
            .text("""
                ## Summary
                Investigated audio stability.

                ## Предлагаемые заметки
                - [[macOS System Audio Capture Guide]] — how to use ScreenCaptureKit without noisy false-positive probes.
                """),
            .text("2026-04-03T21:02:46Z"),
            .text("success")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "lesson-1", sourceDate: "2026-04-03")

        #expect(note?.bodyMarkdown.contains("Зафиксировано как кандидат в устойчивые заметки.") == true)
        #expect(note?.bodyMarkdown.contains("Контекст: how to use ScreenCaptureKit without noisy false-positive probes.") == true)
    }

    @Test("Knowledge edge weights stay stable when the same window is reprocessed")
    func knowledgeEdgesAreIdempotentForReruns() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: "Worked in [[Memograph]] using [[Codex]].",
            topAppsJson: "[{\"name\":\"Codex\",\"duration_min\":30}]",
            topTopicsJson: "[\"Memograph\"]",
            aiSessionsJson: nil,
            contextSwitchesJson: "{\"window_start\":\"2026-04-03T12:00:00Z\",\"window_end\":\"2026-04-03T13:00:00Z\",\"mode\":\"hourly\"}",
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T13:01:00Z",
            modelName: "test",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )
        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Memograph"],
                startedAt: "2026-04-03T12:00:00Z",
                endedAt: "2026-04-03T13:00:00Z",
                durationMs: 3_600_000,
                uncertaintyMode: "normal",
                contextTexts: ["Worked on Memograph"]
            )
        ]
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T12:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T13:00:00Z")!
        )

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)
        let firstRows = try db.query("""
            SELECT weight, supporting_claim_ids_json
            FROM knowledge_edges
            LIMIT 1
        """)
        let firstWeight = firstRows.first?["weight"]?.realValue ?? 0

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let rows = try db.query("""
            SELECT weight, supporting_claim_ids_json
            FROM knowledge_edges
            LIMIT 1
        """)

        #expect(rows.count == 1)
        #expect(rows.first?["weight"]?.realValue == firstWeight)
        let supportJson = rows.first?["supporting_claim_ids_json"]?.textValue ?? ""
        #expect(supportJson.contains("kbclm_"))
    }

    @Test("Knowledge pipeline creates directed semantic project relations")
    func persistsDirectedSemanticRelations() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Worked on [[Memograph]] in [[Codex]] using [[Gemini 3 Flash]] while debugging [[macOS permissions]] and focusing on [[System Audio Capture]].
            """,
            topAppsJson: """
            [{"name":"Codex","duration_min":45}]
            """,
            topTopicsJson: """
            ["Memograph","System Audio Capture","macOS permissions","Gemini 3 Flash"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: "Finish residual audio blinking fixes",
            suggestedNotesJson: """
            ["macOS System Audio Capture Guide"]
            """,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "google/gemini-3-flash-preview",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Fix Memograph audio relations"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T10:50:00Z",
                durationMs: 3_000_000,
                uncertaintyMode: "normal",
                contextTexts: ["Worked on Memograph audio fixes"]
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let rows = try db.query("""
            SELECT edge_type
            FROM knowledge_edges
            ORDER BY edge_type
        """)
        let edgeTypes = rows.compactMap { $0["edge_type"]?.textValue }

        #expect(edgeTypes.contains("uses_tool"))
        #expect(edgeTypes.contains("focuses_on_topic"))
        #expect(edgeTypes.contains("blocked_by_issue"))
        #expect(edgeTypes.contains("uses_model"))
        #expect(edgeTypes.contains("generates_lesson"))
    }

    @Test("Lesson topic relations require semantic name overlap")
    func filtersNoisyLessonTopicRelations() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Investigated [[System Audio Capture]] and saved notes for later.
            """,
            topAppsJson: """
            [{"name":"Codex","duration_min":20}]
            """,
            topTopicsJson: """
            ["System Audio Capture"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: """
            ["macOS System Audio Capture Guide","Gemini 3 Flash Preview Benchmarks"]
            """,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "google/gemini-3-flash-preview",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["System audio notes"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T10:30:00Z",
                durationMs: 1_800_000,
                uncertaintyMode: "normal",
                contextTexts: ["Investigated system audio capture"]
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let rows = try db.query("""
            SELECT e_from.canonical_name AS from_name, e_to.canonical_name AS to_name
            FROM knowledge_edges edge
            JOIN knowledge_entities e_from ON e_from.id = edge.from_entity_id
            JOIN knowledge_entities e_to ON e_to.id = edge.to_entity_id
            WHERE edge.edge_type = 'explains_topic'
            ORDER BY from_name, to_name
        """)

        #expect(rows.count == 1)
        #expect(rows.first?["from_name"]?.textValue == "macOS System Audio Capture Guide")
        #expect(rows.first?["to_name"]?.textValue == "System Audio Capture")
    }

    @Test("Durable topics gain tool relations from session evidence")
    func durableTopicsGainToolRelations() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Investigated [[System Audio Capture]] inside [[Codex]] while debugging Memograph.
            """,
            topAppsJson: """
            [{"name":"Codex","duration_min":35}]
            """,
            topTopicsJson: """
            ["System Audio Capture"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "google/gemini-3-flash-preview",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["System audio capture runtime"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T10:50:00Z",
                durationMs: 3_000_000,
                uncertaintyMode: "normal",
                contextTexts: ["Investigated system audio capture retry logic"]
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let topicClaims = try db.query("""
            SELECT kc.predicate, kc.object_text
            FROM knowledge_claims kc
            JOIN knowledge_entities ke ON ke.id = kc.subject_entity_id
            WHERE ke.canonical_name = 'System Audio Capture'
            ORDER BY kc.predicate, kc.object_text
        """)

        #expect(topicClaims.contains {
            $0["predicate"]?.textValue == "worked_with_tool" &&
            $0["object_text"]?.textValue == "Codex"
        })

        let edgeRows = try db.query("""
            SELECT e_from.canonical_name AS from_name, e_to.canonical_name AS to_name, edge.edge_type
            FROM knowledge_edges edge
            JOIN knowledge_entities e_from ON e_from.id = edge.from_entity_id
            JOIN knowledge_entities e_to ON e_to.id = edge.to_entity_id
            WHERE edge.edge_type = 'works_on_topic'
        """)

        #expect(edgeRows.contains {
            $0["from_name"]?.textValue == "Codex" &&
            $0["to_name"]?.textValue == "System Audio Capture"
        })
    }

    @Test("Summary-only passive tools do not create topic relations without session evidence")
    func passiveToolsDoNotLeakIntoTopicRelations() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Exported notes to [[Obsidian]] after investigating [[System Audio Capture]].
            """,
            topAppsJson: """
            [{"name":"Obsidian","duration_min":10}]
            """,
            topTopicsJson: """
            ["System Audio Capture","Obsidian Knowledge Graph"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "google/gemini-3-flash-preview",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Obsidian",
                bundleId: "md.obsidian",
                windowTitles: ["Daily notes"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T10:10:00Z",
                durationMs: 600_000,
                uncertaintyMode: "normal",
                contextTexts: ["Exported the latest notes into the vault"]
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let edgeRows = try db.query("""
            SELECT e_from.canonical_name AS from_name, e_to.canonical_name AS to_name
            FROM knowledge_edges edge
            JOIN knowledge_entities e_from ON e_from.id = edge.from_entity_id
            JOIN knowledge_entities e_to ON e_to.id = edge.to_entity_id
            WHERE edge.edge_type = 'works_on_topic'
        """)

        #expect(!edgeRows.contains {
            $0["from_name"]?.textValue == "Obsidian" &&
            $0["to_name"]?.textValue == "System Audio Capture"
        })
    }

    @Test("Durable topic families gain typed topic relations")
    func durableTopicFamiliesGainTypedRelations() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Compared [[Q4 quantization]] requirements with [[VRAM]] limits while researching local models.
            """,
            topAppsJson: """
            [{"name":"Safari","duration_min":25}]
            """,
            topTopicsJson: """
            ["Q4 quantization","VRAM","Hardware for AI"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "google/gemini-3-flash-preview",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Safari",
                bundleId: "com.apple.Safari",
                windowTitles: ["VRAM and quantization notes"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T10:25:00Z",
                durationMs: 1_500_000,
                uncertaintyMode: "normal",
                contextTexts: ["Compared q4 quantization tradeoffs against available VRAM"]
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let topicClaims = try db.query("""
            SELECT kc.predicate, kc.object_text
            FROM knowledge_claims kc
            JOIN knowledge_entities ke ON ke.id = kc.subject_entity_id
            WHERE ke.canonical_name = 'Q4 quantization'
            ORDER BY kc.predicate, kc.object_text
        """)

        #expect(topicClaims.contains {
            $0["predicate"]?.textValue == "related_topic" &&
            $0["object_text"]?.textValue == "VRAM"
        })

        let edgeRows = try db.query("""
            SELECT e_from.canonical_name AS from_name, e_to.canonical_name AS to_name, edge.edge_type
            FROM knowledge_edges edge
            JOIN knowledge_entities e_from ON e_from.id = edge.from_entity_id
            JOIN knowledge_entities e_to ON e_to.id = edge.to_entity_id
            WHERE edge.edge_type = 'related_topic'
        """)

        #expect(edgeRows.contains {
            Set([$0["from_name"]?.textValue ?? "", $0["to_name"]?.textValue ?? ""]) == Set(["Q4 quantization", "VRAM"])
        })
    }

    @Test("Durable OCR family topics gain typed relations from affinity in the same window")
    func durableOcrFamilyTopicsGainTypedRelations() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Reviewed capture quality and export polish before the next hourly note.
            """,
            topAppsJson: """
            [{"name":"Memograph","duration_min":20}]
            """,
            topTopicsJson: """
            ["OCR","Screen Recording","Screencap"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "google/gemini-3-flash-preview",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Memograph",
                bundleId: "com.memograph.app",
                windowTitles: ["Capture settings"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T10:20:00Z",
                durationMs: 1_200_000,
                uncertaintyMode: "normal",
                contextTexts: ["Reviewed retention and export settings"]
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let topicClaims = try db.query("""
            SELECT kc.predicate, kc.object_text
            FROM knowledge_claims kc
            JOIN knowledge_entities ke ON ke.id = kc.subject_entity_id
            WHERE ke.canonical_name = 'OCR'
            ORDER BY kc.predicate, kc.object_text
        """)

        #expect(topicClaims.contains {
            $0["predicate"]?.textValue == "related_topic" &&
            $0["object_text"]?.textValue == "Screen Recording"
        })

        let edgeRows = try db.query("""
            SELECT e_from.canonical_name AS from_name, e_to.canonical_name AS to_name
            FROM knowledge_edges edge
            JOIN knowledge_entities e_from ON e_from.id = edge.from_entity_id
            JOIN knowledge_entities e_to ON e_to.id = edge.to_entity_id
            WHERE edge.edge_type = 'related_topic'
        """)

        #expect(edgeRows.contains {
            Set([$0["from_name"]?.textValue ?? "", $0["to_name"]?.textValue ?? ""]) == Set(["OCR", "Screen Recording"])
        })
    }

    @Test("Knowledge entities track window boundaries instead of only summary midnight")
    func knowledgeEntitiesTrackWindowBoundaries() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-02",
            summaryText: "Worked on [[Memograph]] and reviewed [[System Audio Capture]].",
            topAppsJson: "[{\"name\":\"Codex\",\"duration_min\":20}]",
            topTopicsJson: "[\"System Audio Capture\"]",
            aiSessionsJson: nil,
            contextSwitchesJson: "{\"window_start\":\"2026-04-02T13:24:00Z\",\"window_end\":\"2026-04-03T00:00:00Z\",\"mode\":\"hourly\"}",
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T00:01:00Z",
            modelName: "test",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )
        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Memograph"],
                startedAt: "2026-04-02T13:24:00Z",
                endedAt: "2026-04-02T14:00:00Z",
                durationMs: 2_160_000,
                uncertaintyMode: "normal",
                contextTexts: ["Investigated system audio capture"]
            )
        ]
        let window = SummaryWindowDescriptor(
            date: "2026-04-02",
            start: ISO8601DateFormatter().date(from: "2026-04-02T13:24:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T00:00:00Z")!
        )

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let rows = try db.query(
            "SELECT first_seen_at, last_seen_at FROM knowledge_entities WHERE canonical_name = ? LIMIT 1",
            params: [.text("System Audio Capture")]
        )

        #expect(rows.count == 1)
        #expect(rows.first?["first_seen_at"]?.textValue == "2026-04-02T13:24:00Z")
        #expect(rows.first?["last_seen_at"]?.textValue == "2026-04-03T00:00:00Z")
    }

    @Test("Knowledge compiler renders semantic relationship descriptions")
    func rendersSemanticRelationshipDescriptions() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("tool-1"), .text("Codex"), .text("codex"), .text("tool"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("topic-1"), .text("System Audio Capture"), .text("system-audio-capture"), .text("topic"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("project-1"), .text("uses_tool"), .text("Codex"), .real(0.9), .text("relation_inference"),
            .text("claim-2"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("project-1"), .text("focuses_on_topic"), .text("System Audio Capture"), .real(0.85), .text("relation_inference")
        ])

        try db.execute("""
            INSERT INTO knowledge_edges
                (id, from_entity_id, to_entity_id, edge_type, weight, updated_at)
            VALUES (?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("edge-1"), .text("project-1"), .text("tool-1"), .text("uses_tool"), .real(1),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-2"), .text("project-1"), .text("topic-1"), .text("focuses_on_topic"), .real(1),
            .text("2026-04-03T11:01:00Z")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let projectNote = try compiler.compileNote(for: "project-1", sourceDate: "2026-04-03")
        let toolNote = try compiler.compileNote(for: "tool-1", sourceDate: "2026-04-03")

        #expect(projectNote?.bodyMarkdown.contains("С Codex") == true)
        #expect(projectNote?.bodyMarkdown.contains("сфокусировано на System Audio Capture") == true)
        #expect(projectNote?.bodyMarkdown.contains("## Обзор") == true)
        #expect(projectNote?.bodyMarkdown.contains("Недавняя работа вокруг этого проекта связала его с 1 инструментом и 1 ключевой темой.") == true)
        #expect(projectNote?.bodyMarkdown.contains("[[Knowledge/Tools/codex|Codex]] — использовался при работе над этим проектом") == true)
        #expect(projectNote?.bodyMarkdown.contains("[[Knowledge/Topics/system-audio-capture|System Audio Capture]] — тема, ставшая центральной в этом проекте") == true)
        #expect(toolNote?.bodyMarkdown.contains("[[Knowledge/Projects/memograph|Memograph]] — проект, где этот инструмент использовался") == true)
    }

    @Test("Topic and lesson notes render cluster-aware semantic summaries")
    func topicAndLessonNotesRenderClusterAwareSummaries() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("topic-1"), .text("System Audio Capture"), .text("system-audio-capture"), .text("topic"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("project-2"), .text("geminicode"), .text("geminicode"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("topic-2"), .text("Screen Recording"), .text("screen-recording"), .text("topic"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("topic-3"), .text("Accessibility Permissions"), .text("accessibility-permissions"), .text("topic"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("lesson-1"), .text("macOS System Audio Capture Guide"), .text("macos-system-audio-capture-guide"), .text("lesson"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("topic-1"), .text("relevant_to_project"), .text("Memograph"), .real(0.9), .text("relation_inference"),
            .text("claim-2"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("topic-1"), .text("relevant_to_project"), .text("geminicode"), .real(0.85), .text("relation_inference"),
            .text("claim-3"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("topic-1"), .text("related_topic"), .text("Screen Recording"), .real(0.85), .text("relation_inference"),
            .text("claim-4"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("topic-1"), .text("related_topic"), .text("Accessibility Permissions"), .real(0.8), .text("relation_inference"),
            .text("claim-5"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("lesson-1"), .text("derived_from_project"), .text("Memograph"), .real(0.85), .text("relation_inference"),
            .text("claim-6"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("lesson-1"), .text("explains_topic"), .text("System Audio Capture"), .real(0.85), .text("relation_inference")
        ])

        try db.execute("""
            INSERT INTO knowledge_edges
                (id, from_entity_id, to_entity_id, edge_type, weight, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("edge-1"), .text("topic-1"), .text("project-1"), .text("focuses_on_topic"), .real(2),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-2"), .text("topic-1"), .text("project-2"), .text("focuses_on_topic"), .real(1.5),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-3"), .text("topic-1"), .text("topic-2"), .text("related_topic"), .real(1.4),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-4"), .text("topic-1"), .text("topic-3"), .text("related_topic"), .real(1.2),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-5"), .text("project-1"), .text("lesson-1"), .text("generates_lesson"), .real(1.3),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-6"), .text("lesson-1"), .text("topic-1"), .text("explains_topic"), .real(1.2),
            .text("2026-04-03T11:01:00Z")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let topicNote = try compiler.compileNote(for: "topic-1", sourceDate: "2026-04-03")
        let lessonNote = try compiler.compileNote(for: "lesson-1", sourceDate: "2026-04-03")

        #expect(topicNote?.bodyMarkdown.contains("Эта тема остается активной в 2 проектах, особенно вокруг Memograph и geminicode.") == true)
        #expect(topicNote?.bodyMarkdown.contains("Ближайший кластер темы включает Screen Recording и Accessibility Permissions.") == true)
        #expect(topicNote?.bodyMarkdown.contains("Главные проекты: Memograph и geminicode;") == true)
        #expect(topicNote?.bodyMarkdown.contains("Ближайший кластер: Screen Recording и Accessibility Permissions;") == true)
        #expect(topicNote?.bodyMarkdown.contains("[[Knowledge/Lessons/macos-system-audio-capture-guide|macOS System Audio Capture Guide]] — вывод, который фиксирует эту тему") == true)

        #expect(lessonNote?.bodyMarkdown.contains("Этот вывод кристаллизует работу из Memograph в практическое знание о System Audio Capture.") == true)
        #expect(lessonNote?.bodyMarkdown.contains("Исходные проекты: Memograph;") == true)
        #expect(lessonNote?.bodyMarkdown.contains("Ключевая тема: System Audio Capture;") == true)
        #expect(lessonNote?.bodyMarkdown.contains("Captured as a durable note candidate") == false)
        #expect(lessonNote?.bodyMarkdown.contains("[[Knowledge/Projects/memograph|Memograph]] — исходный проект за этим выводом") == true)
        #expect(lessonNote?.bodyMarkdown.contains("[[Knowledge/Topics/system-audio-capture|System Audio Capture]] — тема, которую помогает объяснить этот вывод") == true)
    }

    @Test("Compiler preserves applied merge overlays on the target note")
    func compilerPreservesAppliedMergeOverlays() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, aliases_json, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("topic-ocr"), .text("OCR"), .text("ocr"), .text("topic"),
            .text("[\"Optical Character Recognition\"]"),
            .text("2026-04-04T00:00:00Z"), .text("2026-04-04T10:00:00Z")
        ])
        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-ocr-focus"),
            .text("2026-04-04T09:00:00Z"), .text("2026-04-04T10:00:00Z"),
            .text("2026-04-04"), .text("2026-04-04T10:01:00Z"),
            .text("topic-ocr"), .text("topic_in_focus"), .text("2026-04-04"), .real(0.9), .text("hourly_summary")
        ])

        let defaults = UserDefaults(suiteName: "test_\(UUID().uuidString)")!
        var settings = AppSettings(
            defaults: defaults,
            credentialsStore: InMemoryCredentialsStore(),
            legacyCredentialsStore: InMemoryCredentialsStore()
        )
        settings.knowledgeMergeOverlays = [
            KnowledgeMergeOverlayRecord(
                appliedAt: "2026-04-04T10:33:00Z",
                sourceEntityId: "topic-ocr-accuracy",
                sourceTitle: "OCR Accuracy in Memograph",
                sourceAliases: ["OCR Accuracy in Memograph"],
                sourceOverview: "Эта узкая заметка зафиксировала работу по настройке OCR внутри Memograph.",
                preservedSignals: [
                    "В фокусе в 1 окне сводки; последний раз 2026-04-04 09:00.",
                    "Главные проекты: Memograph; последний раз 2026-04-04 09:00."
                ],
                targetEntityId: "topic-ocr",
                targetTitle: "OCR",
                targetRelativePath: "Topics/ocr.md"
            )
        ]

        let compiler = KnowledgeCompiler(db: db, timeZone: utc, settings: settings)
        let note = try compiler.compileNote(for: "topic-ocr", sourceDate: "2026-04-04")

        #expect(note?.bodyMarkdown.contains("## Объединенный контекст") == true)
        #expect(note?.bodyMarkdown.contains("Объединено из OCR Accuracy in Memograph") == true)
        #expect(note?.bodyMarkdown.contains("Эта узкая заметка зафиксировала работу по настройке OCR внутри Memograph.") == true)
        #expect(note?.bodyMarkdown.contains("Сохраненные сигналы: В фокусе в 1 окне сводки; последний раз 2026-04-04 09:00.") == true)
        #expect(note?.bodyMarkdown.contains("## Алиасы") == true)
        #expect(note?.bodyMarkdown.contains("- OCR Accuracy in Memograph") == true)
    }

    @Test("Tool relationship sections prioritize projects and cap noisy tool neighbors")
    func toolRelationshipSectionsPrioritizeProjectsAndCapNeighbors() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var entityParams: [SQLiteValue] = [
            .text("tool-main"), .text("Codex"), .text("codex"), .text("tool"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z"),
            .text("topic-1"), .text("OCR"), .text("ocr"), .text("topic"),
            .text("2026-04-04T04:00:00Z"), .text("2026-04-04T05:00:00Z")
        ]

        for index in 1...7 {
            entityParams.append(contentsOf: [
                .text("tool-neighbor-\(index)"),
                .text("Neighbor Tool \(index)"),
                .text("neighbor-tool-\(index)"),
                .text("tool"),
                .text("2026-04-04T04:00:00Z"),
                .text("2026-04-04T05:00:00Z")
            ])
        }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: entityParams)

        var edgeParams: [SQLiteValue] = [
            .text("edge-project"), .text("project-1"), .text("tool-main"), .text("uses_tool"), .real(5),
            .text("2026-04-04T05:01:00Z"),
            .text("edge-topic"), .text("tool-main"), .text("topic-1"), .text("works_on_topic"), .real(4),
            .text("2026-04-04T05:01:00Z")
        ]
        for index in 1...7 {
            edgeParams.append(contentsOf: [
                .text("edge-neighbor-\(index)"),
                .text("tool-main"),
                .text("tool-neighbor-\(index)"),
                .text("co_occurs_with"),
                .real(Double(8 - index)),
                .text("2026-04-04T05:01:00Z")
            ])
        }

        try db.execute("""
            INSERT INTO knowledge_edges
                (id, from_entity_id, to_entity_id, edge_type, weight, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: edgeParams)

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "tool-main", sourceDate: "2026-04-04")
        let body = note?.bodyMarkdown ?? ""

        let projectsRange = body.range(of: "### Проекты")
        let topicsRange = body.range(of: "### Темы")
        let toolsRange = body.range(of: "### Инструменты")
        #expect(projectsRange != nil)
        #expect(topicsRange != nil)
        #expect(toolsRange != nil)
        if let projectsRange, let topicsRange, let toolsRange {
            #expect(projectsRange.lowerBound < topicsRange.lowerBound)
            #expect(topicsRange.lowerBound < toolsRange.lowerBound)
        }

        #expect(body.contains("[[Knowledge/Projects/memograph|Memograph]] — проект, где этот инструмент использовался"))
        #expect(body.contains("[[Knowledge/Topics/ocr|OCR]] — тема, для исследования которой использовался этот инструмент"))
        #expect(body.contains("Neighbor Tool 1"))
        #expect(body.contains("Neighbor Tool 5"))
        #expect(body.contains("Neighbor Tool 6") == false)
        #expect(body.contains("Neighbor Tool 7") == false)
    }

    @Test("Lesson notes hide noisy same-window lesson co-occurrence references")
    func lessonNotesHideSameTypeCoOccurrenceNoise() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("lesson-1"), .text("macOS System Audio Capture Guide"), .text("macos-system-audio-capture-guide"), .text("lesson"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("project-1"), .text("Memograph"), .text("memograph"), .text("project"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("topic-1"), .text("System Audio Capture"), .text("system-audio-capture"), .text("topic"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("lesson-2"), .text("Local-first AI Privacy Strategy"), .text("local-first-ai-privacy-strategy"), .text("lesson"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z")
        ])

        try db.execute("""
            INSERT INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, source_kind)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("claim-1"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("lesson-1"), .text("derived_from_project"), .text("Memograph"), .real(0.8), .text("relation_inference"),
            .text("claim-2"),
            .text("2026-04-03T10:00:00Z"), .text("2026-04-03T11:00:00Z"),
            .text("2026-04-03"), .text("2026-04-03T11:01:00Z"),
            .text("lesson-1"), .text("explains_topic"), .text("System Audio Capture"), .real(0.8), .text("relation_inference")
        ])

        try db.execute("""
            INSERT INTO knowledge_edges
                (id, from_entity_id, to_entity_id, edge_type, weight, updated_at)
            VALUES (?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("edge-1"), .text("project-1"), .text("lesson-1"), .text("generates_lesson"), .real(1),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-2"), .text("lesson-1"), .text("topic-1"), .text("explains_topic"), .real(1),
            .text("2026-04-03T11:01:00Z"),
            .text("edge-3"), .text("lesson-1"), .text("lesson-2"), .text("co_occurs_with"), .real(1),
            .text("2026-04-03T11:01:00Z")
        ])

        let compiler = KnowledgeCompiler(db: db, timeZone: utc)
        let note = try compiler.compileNote(for: "lesson-1", sourceDate: "2026-04-03")

        #expect(note?.bodyMarkdown.contains("## Обзор") == true)
        #expect(note?.bodyMarkdown.contains("Этот вывод кристаллизует работу из Memograph в практическое знание о System Audio Capture.") == true)
        #expect(note?.bodyMarkdown.contains("### Проекты") == true)
        #expect(note?.bodyMarkdown.contains("### Темы") == true)
        #expect(note?.bodyMarkdown.contains("### Выводы") == false)
        #expect(note?.bodyMarkdown.contains("Local-first AI Privacy Strategy") == false)
    }

    @Test("Versioned tool aliases collapse into one canonical tool entity")
    func versionedToolAliasesCollapseIntoCanonicalTool() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Summary
            Worked on [[Memograph]] in [[Claude Code v2.1.89]] and later in [[Claude Code v2.1.90]].
            """,
            topAppsJson: """
            [{"name":"Claude Code v2.1.89","duration_min":15},{"name":"Claude Code v2.1.90","duration_min":15}]
            """,
            topTopicsJson: """
            ["Memograph"]
            """,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T10:00:00Z","window_end":"2026-04-03T11:00:00Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T11:01:55Z",
            modelName: "test",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Claude Code v2.1.89",
                bundleId: "com.anthropic.claudecode",
                windowTitles: ["Memograph work"],
                startedAt: "2026-04-03T10:00:00Z",
                endedAt: "2026-04-03T10:30:00Z",
                durationMs: 1_800_000,
                uncertaintyMode: "normal",
                contextTexts: ["Worked on Memograph"]
            ),
            SessionData(
                sessionId: "s2",
                appName: "Claude Code v2.1.90",
                bundleId: "com.anthropic.claudecode",
                windowTitles: ["Memograph work"],
                startedAt: "2026-04-03T10:30:00Z",
                endedAt: "2026-04-03T11:00:00Z",
                durationMs: 1_800_000,
                uncertaintyMode: "normal",
                contextTexts: ["Worked on Memograph"]
            )
        ]

        let pipeline = KnowledgePipeline(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!
        )

        _ = try pipeline.process(summary: summary, window: window, sessions: sessions)

        let entityRows = try db.query("""
            SELECT canonical_name, aliases_json
            FROM knowledge_entities
            WHERE entity_type = 'tool'
            ORDER BY canonical_name
        """)

        #expect(entityRows.contains { row in
            row["canonical_name"]?.textValue == "Claude Code" &&
            (row["aliases_json"]?.textValue?.contains("Claude Code v2.1.89") ?? false) &&
            (row["aliases_json"]?.textValue?.contains("Claude Code v2.1.90") ?? false)
        })
        #expect(!entityRows.contains { row in
            row["canonical_name"]?.textValue == "Claude Code v2.1.89" ||
            row["canonical_name"]?.textValue == "Claude Code v2.1.90"
        })
    }
}
