import Foundation
import Testing
@testable import MyMacAgent

struct ThreadDetectorTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "advisory_thread_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V005_KnowledgeGraph.migration,
            V006_AdvisoryThreads.migration,
            V010_ThreadIntelligenceMetadata.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    @Test("ThreadDetector promotes known project entities into advisory threads")
    func detectsProjectThreadFromKnowledgeAndSummary() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

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
            .text("2026-04-04T08:30:00Z")
        ])

        let summary = DailySummaryRecord(
            date: "2026-04-04",
            summaryText: """
            Worked on [[Memograph]] and compared capture edge cases before deciding to keep the advisory sidecar isolated.
            """,
            topAppsJson: nil,
            topTopicsJson: #"["Memograph","advisory sidecar"]"#,
            aiSessionsJson: nil,
            contextSwitchesJson: nil,
            unfinishedItemsJson: "Finish the continuity_resume flow",
            suggestedNotesJson: nil,
            generatedAt: "2026-04-04T09:00:00Z",
            modelName: "stub",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let window = SummaryWindowDescriptor(
            date: "2026-04-04",
            start: ISO8601DateFormatter().date(from: "2026-04-04T08:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-04T09:00:00Z")!
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Memograph advisory notes"],
                startedAt: "2026-04-04T08:00:00Z",
                endedAt: "2026-04-04T08:45:00Z",
                durationMs: 2_700_000,
                uncertaintyMode: "normal",
                contextTexts: ["Memograph advisory sidecar architecture and continuity_resume recipe"]
            )
        ]

        let detector = ThreadDetector(db: db, timeZone: utc)
        let detections = try detector.detect(summary: summary, window: window, sessions: sessions)

        #expect(!detections.isEmpty)
        let memograph = try #require(detections.first { $0.thread.title == "Memograph" })
        #expect(memograph.thread.kind == .project)
        #expect(memograph.thread.confidence >= 0.7)
        #expect(memograph.evidence.contains { $0.evidenceKind == "entity" })
        #expect(memograph.evidence.contains { $0.evidenceKind == "session" })
        #expect(memograph.evidence.contains { $0.evidenceKind == "summary" })
    }

    @Test("ThreadDetector reuses an existing broader thread when current seed overlaps semantically")
    func reusesExistingThreadAcrossDays() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO advisory_threads
                (id, title, slug, kind, status, confidence, user_pinned, parent_thread_id,
                 first_seen_at, last_active_at, total_active_minutes, importance_score, source, summary, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("thread-memograph"),
            .text("Memograph"),
            .text("memograph"),
            .text("project"),
            .text("active"),
            .real(0.82),
            .integer(0),
            .null,
            .text("2026-04-02T10:00:00Z"),
            .text("2026-04-03T16:00:00Z"),
            .integer(140),
            .real(0.74),
            .text("tests"),
            .text("Core Memograph thread."),
            .text("2026-04-02T10:00:00Z"),
            .text("2026-04-03T16:00:00Z")
        ])

        let summary = DailySummaryRecord(
            date: "2026-04-04",
            summaryText: "Worked on Memograph advisory sidecar routing and bridge resilience.",
            topAppsJson: nil,
            topTopicsJson: #"["Memograph advisory sidecar"]"#,
            aiSessionsJson: nil,
            contextSwitchesJson: nil,
            unfinishedItemsJson: nil,
            suggestedNotesJson: nil,
            generatedAt: "2026-04-04T09:00:00Z",
            modelName: "stub",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "success"
        )

        let window = SummaryWindowDescriptor(
            date: "2026-04-04",
            start: ISO8601DateFormatter().date(from: "2026-04-04T08:00:00Z")!,
            end: ISO8601DateFormatter().date(from: "2026-04-04T09:00:00Z")!
        )

        let sessions = [
            SessionData(
                sessionId: "s1",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Memograph advisory sidecar"],
                startedAt: "2026-04-04T08:00:00Z",
                endedAt: "2026-04-04T08:45:00Z",
                durationMs: 2_700_000,
                uncertaintyMode: "normal",
                contextTexts: ["Memograph advisory sidecar bridge"]
            )
        ]

        let detector = ThreadDetector(db: db, timeZone: utc)
        let detections = try detector.detect(summary: summary, window: window, sessions: sessions)
        let merged = try #require(detections.first { $0.thread.slug == "memograph" })

        #expect(merged.thread.id == "thread-memograph")
        #expect(merged.thread.title == "Memograph")
        #expect(merged.thread.totalActiveMinutes >= 140)
    }
}
