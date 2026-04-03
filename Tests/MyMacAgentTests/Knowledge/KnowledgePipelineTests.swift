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
        #expect(note?.bodyMarkdown.contains("## Aliases") == true)
        #expect(note?.bodyMarkdown.contains("Claude.app") == true)
        #expect(note?.bodyMarkdown.contains("## Key Signals") == true)
        #expect(note?.bodyMarkdown.contains("was used in 1 captured work window") == true)
        #expect(note?.bodyMarkdown.contains("## Recent Windows") == true)
        #expect(note?.bodyMarkdown.contains("Used during 2026-04-03 10:00-11:00.") == true)
        #expect(note?.bodyMarkdown.contains("### Projects") == true)
        #expect(note?.bodyMarkdown.contains("[[Knowledge/Projects/memograph|Memograph]]") == true)
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
}
