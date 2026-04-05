import Testing
import Foundation
@testable import MyMacAgent

struct ObsidianExporterTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let makassar = TimeZone(secondsFromGMT: 8 * 3600)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V005_KnowledgeGraph.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    private func makeAdvisoryDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_advisory_\(UUID().uuidString).db"
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

    @Test("Renders daily note markdown")
    func rendersDailyNote() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Seed sessions for app duration calculation
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.cursor"), .text("Cursor")])
        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.apple.Safari"), .text("Safari")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1), .text("2026-04-02T09:00:00Z"),
                      .text("2026-04-02T11:14:00Z"), .integer(8040000)])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s2"), .integer(2), .text("2026-04-02T11:14:00Z"),
                      .text("2026-04-02T12:22:00Z"), .integer(4080000)])

        let summary = DailySummaryRecord(
            date: "2026-04-02",
            summaryText: "Productive day focused on Swift development and testing.",
            topAppsJson: "[{\"name\":\"Cursor\",\"duration_min\":134},{\"name\":\"Safari\",\"duration_min\":68}]",
            topTopicsJson: "[\"Swift concurrency\",\"Testing\"]",
            aiSessionsJson: nil, contextSwitchesJson: "{\"count\":5,\"window_start\":\"2026-04-02T09:00:00Z\",\"window_end\":\"2026-04-02T12:22:00Z\",\"mode\":\"hourly\"}",
            unfinishedItemsJson: nil,
            suggestedNotesJson: "[\"Swift Testing patterns\"]",
            generatedAt: "2026-04-02T23:00:00Z", modelName: "claude-3-haiku",
            tokenUsageInput: 1000, tokenUsageOutput: 300,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let markdown = try exporter.renderDailyNote(summary: summary)

        #expect(markdown.contains("# Почасовой лог — 2026-04-02 09:00–12:22"))
        #expect(markdown.contains("## Сводка"))
        #expect(markdown.contains("Productive day"))
        #expect(markdown.contains("## Основные приложения"))
        #expect(markdown.contains("Cursor"))
        #expect(markdown.contains("## Основные темы"))
        #expect(markdown.contains("Swift concurrency"))
        #expect(markdown.contains("## Предлагаемые заметки"))
        #expect(markdown.contains("[[Swift Testing patterns]]"))
    }

    @Test("Renders rich structured markdown without flattening it")
    func rendersRichStructuredMarkdown() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: """
            ## Сводка
            Rich body.

            ## Детальный таймлайн
            - Block 1

            ## Проекты и код
            - Project
            """,
            topAppsJson: nil,
            topTopicsJson: nil,
            aiSessionsJson: nil,
            contextSwitchesJson: nil,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: nil,
            modelName: nil,
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let markdown = try exporter.renderDailyNote(summary: summary)

        #expect(markdown.contains("# Дневной лог — 2026-04-03"))
        #expect(markdown.contains("## Детальный таймлайн"))
        #expect(markdown.contains("## Проекты и код"))
        #expect(!markdown.contains("## Основные приложения"))
    }

    @Test("Writes daily note to vault directory")
    func writesToVault() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_vault_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let summary = DailySummaryRecord(
            date: "2026-04-02", summaryText: "Good day.",
            topAppsJson: nil, topTopicsJson: nil,
            aiSessionsJson: nil, contextSwitchesJson: nil,
            unfinishedItemsJson: nil, suggestedNotesJson: nil,
            generatedAt: nil, modelName: nil,
            tokenUsageInput: 0, tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let filePath = try exporter.exportDailyNote(summary: summary)

        #expect(FileManager.default.fileExists(atPath: filePath))
        let content = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(content.contains("# Дневной лог — 2026-04-02"))
        #expect(filePath.contains("/Daily/2026-04-02_"))
    }

    @Test("Exports advisory thread notes into Obsidian thread folder")
    func exportsAdvisoryThreadNote() throws {
        let (db, path) = try makeAdvisoryDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_thread_vault_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        try db.execute("""
            INSERT INTO advisory_threads
                (id, title, slug, kind, status, confidence, user_pinned, user_title_override, parent_thread_id,
                 first_seen_at, last_active_at, total_active_minutes, last_artifact_at, importance_score,
                 source, summary, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("thread-parent"), .text("Advisory surface"), .text("advisory-surface"), .text("project"), .text("active"), .real(0.84), .integer(1), .text("Нить: advisory surface"), .null, .text("2026-04-02T08:00:00Z"), .text("2026-04-04T09:30:00Z"), .integer(135), .text("2026-04-04T09:35:00Z"), .real(0.78), .text("manual"), .text("Parent thread summary"), .text("2026-04-02T08:00:00Z"), .text("2026-04-04T09:30:00Z")
        ])
        try db.execute("""
            INSERT INTO advisory_threads
                (id, title, slug, kind, status, confidence, user_pinned, user_title_override, parent_thread_id,
                 first_seen_at, last_active_at, total_active_minutes, last_artifact_at, importance_score,
                 source, summary, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("thread-child"), .text("Inspector polish"), .text("inspector-polish"), .text("theme"), .text("stalled"), .real(0.63), .integer(0), .null, .text("thread-parent"), .text("2026-04-03T08:00:00Z"), .text("2026-04-04T08:45:00Z"), .integer(35), .null, .real(0.42), .text("manual"), .text("Child thread summary"), .text("2026-04-03T08:00:00Z"), .text("2026-04-04T08:45:00Z")
        ])

        try db.execute("""
            INSERT INTO continuity_items
                (id, thread_id, kind, title, body, status, confidence, source_packet_id, created_at, updated_at, resolved_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("cont-1"),
            .text("thread-parent"),
            .text("open_loop"),
            .text("Finish inspector copy"),
            .text("Keep the thread detail readable in Timeline."),
            .text("open"),
            .real(0.72),
            .null,
            .text("2026-04-04T09:00:00Z"),
            .text("2026-04-04T09:00:00Z"),
            .null
        ])

        try db.execute("""
            INSERT INTO advisory_thread_evidence
                (id, thread_id, evidence_kind, evidence_ref, weight, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ev-1"),
            .text("thread-parent"),
            .text("summary"),
            .text("summary:2026-04-04"),
            .real(1.0),
            .text("2026-04-04T09:20:00Z")
        ])

        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, payload_json, language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("packet-1"),
            .text("v2.reflection.1"),
            .text("reflection"),
            .text("morning_resume"),
            .text("{}"),
            .text("ru"),
            .text("deep_context"),
            .text("2026-04-04T09:30:00Z")
        ])

        try db.execute("""
            INSERT INTO advisory_artifacts
                (id, domain, kind, title, body, thread_id, source_packet_id, source_recipe, confidence,
                 why_now, evidence_json, language, status, market_score, created_at, surfaced_at, expires_at,
                 attention_vector_json, market_context_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("artifact-1"),
            .text("continuity"),
            .text("resume_card"),
            .text("Resume advisory"),
            .text("Вернуться к advisory surface и дожать inspector."),
            .text("thread-parent"),
            .text("packet-1"),
            .text("continuity_resume"),
            .real(0.86),
            .text("Strong continuity signal"),
            .text(#"["summary:2026-04-04"]"#),
            .text("ru"),
            .text("surfaced"),
            .real(0.83),
            .text("2026-04-04T09:35:00Z"),
            .text("2026-04-04T09:35:00Z"),
            .null,
            .null,
            .null
        ])

        let store = AdvisoryArtifactStore(db: db, timeZone: utc)
        let parentThread = try store.thread(id: "thread-parent")
        let detail = AdvisoryThreadDetailSnapshot(
            thread: try #require(parentThread),
            parentThread: nil,
            childThreads: try store.childThreads(parentThreadId: "thread-parent"),
            continuityItems: try store.continuityItemsForThread(threadId: "thread-parent"),
            artifacts: try store.artifactsForThread("thread-parent"),
            evidence: try store.threadEvidence(threadId: "thread-parent"),
            maintenanceProposals: [
                AdvisoryThreadMaintenanceProposal(
                    id: "proposal-1",
                    kind: .splitIntoSubthread,
                    title: "Вынести sub-thread: Provider routing policy",
                    rationale: "Отдельный routing concern уже стал самостоятельным return point.",
                    confidence: 0.78,
                    targetThreadId: nil,
                    targetThreadTitle: nil,
                    suggestedStatus: nil,
                    suggestedTitle: "Provider routing policy",
                    suggestedSummary: "Sub-thread for provider routing decisions.",
                    suggestedKind: .question,
                    sourceContinuityItemId: nil
                )
            ]
        )

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let filePath = try exporter.exportAdvisoryThread(detail)
        let content = try String(contentsOfFile: filePath, encoding: .utf8)

        #expect(FileManager.default.fileExists(atPath: filePath))
        #expect(filePath.contains("/Knowledge/Threads/advisory-surface.md"))
        #expect(content.contains("# Нить — Нить: advisory surface"))
        #expect(content.contains("## Open Loops"))
        #expect(content.contains("Finish inspector copy"))
        #expect(content.contains("## Child Threads"))
        #expect(content.contains("Inspector polish"))
        #expect(content.contains("## Maintenance"))
        #expect(content.contains("Provider routing policy"))
        #expect(content.contains("## Recent Advisory Artifacts"))
        #expect(content.contains("Resume advisory"))
        #expect(content.contains("## Evidence"))
        #expect(content.contains("summary:2026-04-04"))
    }

    @Test("Generates timeline from sessions")
    func generatesTimeline() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s1"), .integer(1),
                      .text("2026-04-02T09:10:00Z"), .text("2026-04-02T09:32:00Z"),
                      .integer(1320000)])

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let timeline = try exporter.buildTimeline(for: "2026-04-02")

        #expect(timeline.contains("09:10"))
        #expect(timeline.contains("09:32"))
        #expect(timeline.contains("TestApp"))
    }

    @Test("Generates timeline using local times for the selected day")
    func generatesTimelineForLocalDay() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s-local"), .integer(1),
                      .text("2026-04-02T16:10:00Z"), .text("2026-04-02T16:32:00Z"),
                      .integer(1320000)])

        let exporter = ObsidianExporter(db: db, timeZone: makassar)
        let timeline = try exporter.buildTimeline(for: "2026-04-03")

        #expect(timeline.contains("00:10"))
        #expect(timeline.contains("00:32"))
        #expect(timeline.contains("TestApp"))
    }

    @Test("Generates hourly timeline using overlap semantics")
    func generatesHourlyTimelineUsingWindowOverlap() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("TestApp")])
        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms)
            VALUES (?, ?, ?, ?, ?)
        """, params: [.text("s-hourly"), .integer(1),
                      .text("2026-04-03T10:50:00Z"), .text("2026-04-03T11:20:00Z"),
                      .integer(1_800_000)])

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let window = SummaryWindowDescriptor(
            date: "2026-04-03",
            start: ISO8601DateFormatter().date(from: "2026-04-03T11:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-03T12:00:00Z")!
        )
        let timeline = try exporter.buildTimeline(for: window)

        #expect(timeline.contains("11:00"))
        #expect(timeline.contains("11:20"))
        #expect(!timeline.contains("10:50"))
    }

    @Test("formatDuration formats minutes to hours and minutes")
    func formatDuration() {
        #expect(ObsidianExporter.formatDuration(minutes: 134) == "2h 14m")
        #expect(ObsidianExporter.formatDuration(minutes: 45) == "45m")
        #expect(ObsidianExporter.formatDuration(minutes: 60) == "1h 00m")
        #expect(ObsidianExporter.formatDuration(minutes: 0) == "0m")
    }

    @Test("Queues failed exports and drains them later")
    func queuesAndDrainsExports() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_vault_queue_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let summary = DailySummaryRecord(
            date: "2026-04-03",
            summaryText: "Queued note body.",
            topAppsJson: nil,
            topTopicsJson: nil,
            aiSessionsJson: nil,
            contextSwitchesJson: """
            {"window_start":"2026-04-03T03:01:55Z","window_end":"2026-04-03T04:01:55Z","mode":"hourly"}
            """,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-03T04:02:10Z",
            modelName: "test",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        try exporter.enqueueSummaryExport(summary, lastError: "simulated failure")

        let queued = try db.query("""
            SELECT status, last_error
            FROM sync_queue
            WHERE job_type = ?
        """, params: [.text("obsidian_export_summary")])
        #expect(queued.count == 1)
        #expect(queued[0]["status"]?.textValue == "pending")
        #expect(queued[0]["last_error"]?.textValue == "simulated failure")

        let drained = try exporter.drainQueuedExports()
        #expect(drained == 1)

        let filePath = (vaultDir as NSString).appendingPathComponent("Daily/2026-04-03_03-01-04-01.md")
        #expect(FileManager.default.fileExists(atPath: filePath))

        let finished = try db.query("""
            SELECT status
            FROM sync_queue
            WHERE job_type = ?
        """, params: [.text("obsidian_export_summary")])
        #expect(finished.first?["status"]?.textValue == "done")
    }

    @Test("cleanupSyncQueueHistory prunes stale completed rows")
    func cleanupSyncQueueHistoryPrunesStaleRows() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO sync_queue (job_type, entity_id, status, finished_at)
            VALUES (?, ?, 'done', ?)
        """, params: [
            .text("obsidian_export_summary"),
            .text("old-done"),
            .text("2026-03-01T00:00:00Z")
        ])
        try db.execute("""
            INSERT INTO sync_queue (job_type, entity_id, status, finished_at)
            VALUES (?, ?, 'failed', ?)
        """, params: [
            .text("audio_transcription"),
            .text("old-failed"),
            .text("2026-02-01T00:00:00Z")
        ])
        try db.execute("""
            INSERT INTO sync_queue (job_type, entity_id, status, finished_at)
            VALUES (?, ?, 'done', ?)
        """, params: [
            .text("obsidian_export_summary"),
            .text("recent-done"),
            .text(ISO8601DateFormatter().string(from: Date()))
        ])

        let exporter = ObsidianExporter(db: db, timeZone: utc)
        let deleted = try exporter.cleanupSyncQueueHistory(doneOlderThanDays: 7, failedOlderThanDays: 30)
        let remaining = try db.query("SELECT entity_id FROM sync_queue ORDER BY entity_id")

        #expect(deleted == 2)
        #expect(remaining.count == 1)
        #expect(remaining.first?["entity_id"]?.textValue == "recent-done")
    }

    @Test("Syncs knowledge maintenance draft artifacts and prunes stale files")
    func syncsKnowledgeMaintenanceDraftArtifacts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_drafts_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)

        let firstBatch = [
            KnowledgeDraftArtifact(
                kind: .reviewDraft,
                relativePath: "Maintenance/lesson-promotion-sqlite.md",
                title: "Draft Lesson Promotion — SQLite",
                markdown: "# Draft Lesson Promotion — SQLite\n"
            ),
            KnowledgeDraftArtifact(
                kind: .applyReadyRedirect,
                relativePath: "Apply/Redirects/ocr-accuracy.md",
                title: "OCR Accuracy",
                markdown: "# OCR Accuracy\n"
            ),
            KnowledgeDraftArtifact(
                kind: .applyReadyMergePatch,
                relativePath: "Apply/Merge/ocr-accuracy-into-ocr.md",
                title: "Merge Patch — OCR Accuracy into OCR",
                markdown: "# Merge Patch\n"
            )
        ]

        let written = try exporter.syncKnowledgeDraftArtifacts(firstBatch)
        #expect(written.count == 3)

        let draftsRoot = (vaultDir as NSString).appendingPathComponent("Knowledge/_drafts")
        let firstFile = (draftsRoot as NSString).appendingPathComponent("Maintenance/lesson-promotion-sqlite.md")
        let secondFile = (draftsRoot as NSString).appendingPathComponent("Apply/Redirects/ocr-accuracy.md")
        let thirdFile = (draftsRoot as NSString).appendingPathComponent("Apply/Merge/ocr-accuracy-into-ocr.md")
        #expect(FileManager.default.fileExists(atPath: firstFile))
        #expect(FileManager.default.fileExists(atPath: secondFile))
        #expect(FileManager.default.fileExists(atPath: thirdFile))

        let secondBatch = [
            KnowledgeDraftArtifact(
                kind: .reviewDraft,
                relativePath: "Maintenance/lesson-promotion-sqlite.md",
                title: "Draft Lesson Promotion — SQLite",
                markdown: "# Updated Draft\n"
            )
        ]

        _ = try exporter.syncKnowledgeDraftArtifacts(secondBatch)
        #expect(FileManager.default.fileExists(atPath: firstFile))
        #expect(!FileManager.default.fileExists(atPath: secondFile))
        #expect(!FileManager.default.fileExists(atPath: thirdFile))
        #expect(!FileManager.default.fileExists(atPath: (draftsRoot as NSString).appendingPathComponent("Apply/Redirects")))
        #expect(!FileManager.default.fileExists(atPath: (draftsRoot as NSString).appendingPathComponent("Apply/Merge")))
        let updated = try String(contentsOfFile: firstFile, encoding: .utf8)
        #expect(updated.contains("# Updated Draft"))
    }

    @Test("Preserves review decisions across draft sync and discovers non-pending review decisions")
    func preservesAndDiscoversReviewDecisions() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_review_decisions_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let artifact = KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: "Review/reclassify-prompt-engineering.md",
            title: "Пакет ревью — Переклассификация Prompt Engineering",
            markdown: """
            <!-- memograph-review-key: reclassify:topic-123 -->
            <!-- memograph-review-kind: promote-to-lesson -->
            # Пакет ревью — Переклассификация Prompt Engineering

            ## Решение
            Decision: pending
            """,
            reviewPacketKey: "reclassify:topic-123",
            reviewDecisionKind: .promoteToLesson
        )

        _ = try exporter.syncKnowledgeDraftArtifacts([artifact])
        let reviewPath = (vaultDir as NSString).appendingPathComponent("Knowledge/_drafts/Review/reclassify-prompt-engineering.md")
        let approved = try String(contentsOfFile: reviewPath, encoding: .utf8).replacingOccurrences(of: "Decision: pending", with: "Decision: apply")
        try approved.write(toFile: reviewPath, atomically: true, encoding: .utf8)

        let refreshedArtifact = KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: "Review/reclassify-prompt-engineering.md",
            title: "Пакет ревью — Переклассификация Prompt Engineering",
            markdown: """
            <!-- memograph-review-key: reclassify:topic-123 -->
            <!-- memograph-review-kind: promote-to-lesson -->
            # Пакет ревью — Переклассификация Prompt Engineering

            ## Решение
            Decision: pending

            ## Кандидат
            - Исходная заметка: [[Knowledge/Topics/prompt-engineering|Prompt Engineering]]
            """,
            reviewPacketKey: "reclassify:topic-123",
            reviewDecisionKind: .promoteToLesson
        )

        _ = try exporter.syncKnowledgeDraftArtifacts([refreshedArtifact])
        let preserved = try String(contentsOfFile: reviewPath, encoding: .utf8)
        #expect(preserved.contains("Decision: apply"))
        #expect(preserved.contains("## Кандидат"))

        let dismissedArtifact = KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: "Review/weak-topic-gpu-rendering.md",
            title: "Пакет ревью — Слабая тема GPU Rendering",
            markdown: """
            <!-- memograph-review-key: weak:topic-gpu -->
            <!-- memograph-review-kind: suppress -->
            # Пакет ревью — Слабая тема GPU Rendering

            ## Решение
            Decision: dismiss
            """,
            reviewPacketKey: "weak:topic-gpu",
            reviewDecisionKind: .suppress
        )
        _ = try exporter.syncKnowledgeDraftArtifacts([refreshedArtifact, dismissedArtifact])

        let allDecisions = exporter.discoverKnowledgeReviewDecisions()
        #expect(allDecisions.count == 2)
        #expect(allDecisions.contains {
            $0.key == "weak:topic-gpu" && $0.kind == .suppress && $0.status == .dismiss
        })

        let decisions = exporter.discoverApprovedKnowledgeReviewDecisions()
        #expect(decisions.count == 1)
        #expect(decisions.first?.key == "reclassify:topic-123")
        #expect(decisions.first?.kind == .promoteToLesson)
        #expect(decisions.first?.status == .apply)
        #expect(decisions.first?.recordedAt != nil)
    }

    @Test("Review decision discovery preserves prior history and clears it when a draft goes back to pending")
    func preservesReviewDecisionHistoryAcrossPruning() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_review_history_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let existing = [
            KnowledgeReviewDecisionRecord(
                key: "weak:topic-gpu",
                kind: .suppress,
                status: .dismiss,
                title: "Пакет ревью — Слабая тема GPU Rendering",
                path: "/tmp/Knowledge/_drafts/Review/weak-topic-gpu-rendering.md",
                recordedAt: "2026-04-04T12:00:00Z"
            )
        ]

        let preserved = exporter.discoverKnowledgeReviewDecisions(existing: existing)
        #expect(preserved.count == 1)
        #expect(preserved.first?.status == .dismiss)

        let pendingArtifact = KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: "Review/weak-topic-gpu-rendering.md",
            title: "Пакет ревью — Слабая тема GPU Rendering",
            markdown: """
            <!-- memograph-review-key: weak:topic-gpu -->
            <!-- memograph-review-kind: suppress -->
            # Пакет ревью — Слабая тема GPU Rendering

            ## Решение
            Decision: pending
            """,
            reviewPacketKey: "weak:topic-gpu",
            reviewDecisionKind: .suppress
        )

        _ = try exporter.syncKnowledgeDraftArtifacts([pendingArtifact])
        let reset = exporter.discoverKnowledgeReviewDecisions(existing: existing)
        #expect(reset.isEmpty)

        let reviewHistoryPath = try exporter.exportKnowledgeReviewHistory(existing)
        let history = try String(contentsOfFile: reviewHistoryPath, encoding: .utf8)
        #expect(history.contains("# Memograph Решения ревью по слою знаний"))
        #expect(history.contains("отклонено [[Knowledge/_drafts/Review/weak-topic-gpu-rendering|Пакет ревью — Слабая тема GPU Rendering]]"))
    }

    @Test("Resolved review drafts are archived during sync and remain discoverable")
    func archivesResolvedReviewDrafts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_review_archive_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let reviewArtifact = KnowledgeDraftArtifact(
            kind: .reviewDraft,
            relativePath: "Review/reclassify-prompt-engineering.md",
            title: "Пакет ревью — Переклассификация Prompt Engineering",
            markdown: """
            <!-- memograph-review-key: reclassify:topic-123 -->
            <!-- memograph-review-kind: promote-to-lesson -->
            # Пакет ревью — Переклассификация Prompt Engineering

            ## Решение
            Decision: pending
            """,
            reviewPacketKey: "reclassify:topic-123",
            reviewDecisionKind: .promoteToLesson
        )

        _ = try exporter.syncKnowledgeDraftArtifacts([reviewArtifact])
        let activePath = (vaultDir as NSString).appendingPathComponent("Knowledge/_drafts/Review/reclassify-prompt-engineering.md")
        let approved = try String(contentsOfFile: activePath, encoding: .utf8).replacingOccurrences(of: "Decision: pending", with: "Decision: apply")
        try approved.write(toFile: activePath, atomically: true, encoding: .utf8)

        _ = try exporter.syncKnowledgeDraftArtifacts([])

        let archivedPath = (vaultDir as NSString).appendingPathComponent("Knowledge/_drafts/ReviewResolved/reclassify-prompt-engineering.md")
        #expect(!FileManager.default.fileExists(atPath: activePath))
        #expect(FileManager.default.fileExists(atPath: archivedPath))

        let decisions = exporter.discoverKnowledgeReviewDecisions()
        #expect(decisions.count == 1)
        #expect(decisions.first?.status == .apply)
        #expect(decisions.first?.path == archivedPath)

        let historyPath = try exporter.exportKnowledgeReviewHistory(decisions)
        let history = try String(contentsOfFile: historyPath, encoding: .utf8)
        #expect(history.contains("[[Knowledge/_drafts/ReviewResolved/_index|доска завершенных ревью]]"))
        #expect(history.contains("одобрено [[Knowledge/_drafts/ReviewResolved/reclassify-prompt-engineering|Пакет ревью — Переклассификация Prompt Engineering]]"))

        let boardPath = try exporter.exportKnowledgeResolvedReviewBoard(decisions)
        let board = try String(contentsOfFile: boardPath, encoding: .utf8)
        #expect(board.contains("# Доска завершенных ревью слоя знаний"))
        #expect(board.contains("## Одобрено"))
        #expect(board.contains("[[Knowledge/_drafts/ReviewResolved/reclassify-prompt-engineering|Пакет ревью — Переклассификация Prompt Engineering]]"))
    }

    @Test("Applies safe knowledge draft artifacts into the main knowledge tree with backups")
    func appliesKnowledgeDraftArtifacts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_apply_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let knowledgeRoot = (vaultDir as NSString).appendingPathComponent("Knowledge")
        let existingTopicPath = (knowledgeRoot as NSString).appendingPathComponent("Topics/sqlite.md")
        try FileManager.default.createDirectory(
            atPath: (existingTopicPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try "# Old SQLite Topic\n".write(toFile: existingTopicPath, atomically: true, encoding: .utf8)

        let artifacts = [
            KnowledgeDraftArtifact(
                kind: .applyReadyLesson,
                relativePath: "Apply/Lessons/sqlite-optimization.md",
                title: "SQLite Optimization",
                markdown: "# SQLite Optimization\n",
                applyTargetRelativePath: "Lessons/sqlite-optimization.md",
                suppressedEntityId: "topic-sqlite-opt"
            ),
            KnowledgeDraftArtifact(
                kind: .applyReadyRedirect,
                relativePath: "Apply/Redirects/sqlite-to-lesson.md",
                title: "SQLite",
                markdown: "# SQLite\n\nSee [[Knowledge/Lessons/sqlite-optimization|SQLite Optimization]].\n",
                applyTargetRelativePath: "Topics/sqlite.md",
                suppressedEntityId: "topic-sqlite"
            ),
            KnowledgeDraftArtifact(
                kind: .applyReadyMergePatch,
                relativePath: "Apply/Merge/sqlite-into-root.md",
                title: "Merge Patch",
                markdown: "# Merge Patch\n"
            )
        ]

        let written = try exporter.applyKnowledgeDraftArtifacts(artifacts)
        #expect(written.count == 2)
        #expect(written.contains { $0.artifact.kind == .applyReadyLesson })
        #expect(written.contains { $0.artifact.kind == .applyReadyRedirect })

        let lessonPath = (knowledgeRoot as NSString).appendingPathComponent("Lessons/sqlite-optimization.md")
        #expect(FileManager.default.fileExists(atPath: lessonPath))
        let rewrittenTopic = try String(contentsOfFile: existingTopicPath, encoding: .utf8)
        #expect(rewrittenTopic.contains("SQLite Optimization"))

        let draftsRoot = (knowledgeRoot as NSString).appendingPathComponent("_drafts/AppliedBackup")
        let backupCandidates = try FileManager.default.subpathsOfDirectory(atPath: draftsRoot)
        #expect(backupCandidates.contains { $0.hasSuffix("Topics/sqlite.md") })

        _ = try exporter.syncKnowledgeDraftArtifacts([])
        let backupCandidatesAfterSync = try FileManager.default.subpathsOfDirectory(atPath: draftsRoot)
        #expect(backupCandidatesAfterSync.contains { $0.hasSuffix("Topics/sqlite.md") })
    }

    @Test("Exports applied knowledge action history note")
    func exportsAppliedKnowledgeActionHistory() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_applied_history_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let records = [
            KnowledgeAppliedActionRecord(
                appliedAt: "2026-04-04T10:33:00Z",
                kind: .lessonPromotion,
                title: "Codex Workflow for AI Founders",
                sourceEntityId: "topic-codex-workflow",
                applyTargetRelativePath: "Lessons/codex-workflow-for-ai-founders.md",
                appliedPath: "/Users/test/vault/Knowledge/Lessons/codex-workflow-for-ai-founders.md",
                backupPath: "/Users/test/vault/Knowledge/_drafts/AppliedBackup/20260404-103351/Lessons/codex-workflow-for-ai-founders.md"
            ),
            KnowledgeAppliedActionRecord(
                id: "merge|topic-ocr-accuracy|topic-ocr",
                appliedAt: "2026-04-04T10:34:00Z",
                kind: .mergeOverlay,
                title: "OCR Accuracy in Memograph",
                sourceEntityId: "topic-ocr-accuracy",
                applyTargetRelativePath: "Topics/ocr.md",
                appliedPath: "/Users/test/vault/Knowledge/Topics/ocr.md",
                targetTitle: "OCR"
            )
        ]

        let filePath = try exporter.exportKnowledgeAppliedHistory(records)
        #expect(FileManager.default.fileExists(atPath: filePath))
        let markdown = try String(contentsOfFile: filePath, encoding: .utf8)
        #expect(markdown.contains("# Memograph Примененные действия слоя знаний"))
        #expect(markdown.contains("## Недавно применено"))
        #expect(markdown.contains("Codex Workflow for AI Founders"))
        #expect(markdown.contains("объединен контекст из `OCR Accuracy in Memograph` в [[Knowledge/Topics/ocr|OCR]]"))
        #expect(markdown.contains("Бэкап:"))
    }

    @Test("Discovers previously applied knowledge actions from the vault")
    func discoversAppliedKnowledgeActionsFromVault() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_applied_discovery_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let lessonPath = (vaultDir as NSString).appendingPathComponent("Knowledge/Lessons/codex-workflow-for-ai-founders.md")
        let topicPath = (vaultDir as NSString).appendingPathComponent("Knowledge/Topics/codex-workflow-for-ai-founders.md")
        try FileManager.default.createDirectory(atPath: (lessonPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: (topicPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)

        try """
        # Codex Workflow for AI Founders

        _Готовый черновик вывода, сгенерированный из безопасного maintenance-действия._
        """.write(toFile: lessonPath, atomically: true, encoding: .utf8)

        try """
        # Codex Workflow for AI Founders

        _Редирект, сгенерированный из безопасного действия повышения в вывод._
        """.write(toFile: topicPath, atomically: true, encoding: .utf8)

        let backupPath = (vaultDir as NSString).appendingPathComponent(
            "Knowledge/_drafts/AppliedBackup/20260404-103351/Lessons/codex-workflow-for-ai-founders.md"
        )
        try FileManager.default.createDirectory(atPath: (backupPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try "# Backup\n".write(toFile: backupPath, atomically: true, encoding: .utf8)

        let records = exporter.discoverAppliedKnowledgeActions(existing: [])
        #expect(records.count == 2)
        #expect(records.contains {
            $0.kind == .lessonPromotion && $0.applyTargetRelativePath == "Lessons/codex-workflow-for-ai-founders.md"
        })
        #expect(records.contains {
            $0.kind == .lessonRedirect && $0.applyTargetRelativePath == "Topics/codex-workflow-for-ai-founders.md"
        })
        #expect(records.contains {
            $0.backupPath?.hasSuffix("Lessons/codex-workflow-for-ai-founders.md") == true
        })
    }

    @Test("Discovers applied merge overlays from merge packets and applied actions")
    func discoversAppliedMergeOverlaysFromVault() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let vaultDir = NSTemporaryDirectory() + "test_kb_merge_overlay_discovery_\(UUID().uuidString)/"
        defer { try? FileManager.default.removeItem(atPath: vaultDir) }

        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, aliases_json, first_seen_at, last_seen_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("topic-ocr-accuracy"), .text("OCR Accuracy in Memograph"), .text("ocr-accuracy-in-memograph"),
            .text("topic"), .text("[\"OCR Accuracy in Memograph\"]"),
            .text("2026-04-04T09:00:00Z"), .text("2026-04-04T10:00:00Z"),
            .text("topic-ocr"), .text("OCR"), .text("ocr"),
            .text("topic"), .null,
            .text("2026-04-04T09:00:00Z"), .text("2026-04-04T10:00:00Z")
        ])

        let mergePath = (vaultDir as NSString).appendingPathComponent(
            "Knowledge/_drafts/Apply/Merge/ocr-accuracy-in-memograph-into-ocr.md"
        )
        try FileManager.default.createDirectory(
            atPath: (mergePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try """
        # Патч слияния — OCR Accuracy in Memograph → OCR

        _Готовый пакет слияния, сгенерированный из безопасного действия консолидации._

        ## Замысел слияния
        Сложить [[Knowledge/Topics/ocr-accuracy-in-memograph|OCR Accuracy in Memograph]] в [[Knowledge/Topics/ocr|OCR]], сохранив уникальный контекст и алиасы.

        ## Сводка источника
        - Эта узкая заметка зафиксировала работу по настройке OCR внутри Memograph.

        ## Сигналы, которые нужно сохранить
        - В фокусе в 1 окне сводки; последний раз 2026-04-04 09:00.
        - Главные проекты: Memograph; последний раз 2026-04-04 09:00.
        """.write(toFile: mergePath, atomically: true, encoding: .utf8)

        let exporter = ObsidianExporter(db: db, vaultPath: vaultDir, timeZone: utc)
        let overlays = exporter.discoverKnowledgeMergeOverlays(
            existing: [],
            appliedActions: [
                KnowledgeAppliedActionRecord(
                    appliedAt: "2026-04-04T10:33:00Z",
                    kind: .redirect,
                    title: "OCR Accuracy in Memograph",
                    sourceEntityId: "topic-ocr-accuracy",
                    applyTargetRelativePath: "Topics/ocr-accuracy-in-memograph.md",
                    appliedPath: (vaultDir as NSString).appendingPathComponent("Knowledge/Topics/ocr-accuracy-in-memograph.md")
                )
            ]
        )

        #expect(overlays.count == 1)
        #expect(overlays.first?.sourceTitle == "OCR Accuracy in Memograph")
        #expect(overlays.first?.targetTitle == "OCR")
        #expect(overlays.first?.targetRelativePath == "Topics/ocr.md")
        #expect(overlays.first?.preservedSignals.count == 2)
    }
}
