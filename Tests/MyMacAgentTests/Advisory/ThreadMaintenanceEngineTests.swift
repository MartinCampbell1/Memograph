import Foundation
import Testing
@testable import MyMacAgent

struct ThreadMaintenanceEngineTests {
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "advisory_thread_maintenance_\(UUID().uuidString).db"
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

    @Test("Thread maintenance infers parent child links and lifecycle states from evidence")
    func refreshesThreadIntelligence() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)", params: [
            .text("com.openai.codex"),
            .text("Codex")
        ])

        try db.execute("""
            INSERT INTO sessions (id, app_id, started_at, ended_at, active_duration_ms, uncertainty_mode)
            VALUES (?, ?, ?, ?, ?, ?),
                   (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("sess-parent"), .integer(1), .text("2026-04-09T08:00:00Z"), .text("2026-04-09T10:00:00Z"), .integer(7_200_000), .text("normal"),
            .text("sess-child"), .integer(1), .text("2026-04-09T10:10:00Z"), .text("2026-04-09T10:55:00Z"), .integer(2_700_000), .text("normal")
        ])

        try db.execute("""
            INSERT INTO advisory_threads
                (id, title, slug, kind, status, confidence, user_pinned, user_title_override, parent_thread_id,
                 first_seen_at, last_active_at, total_active_minutes, last_artifact_at, importance_score,
                 source, summary, created_at, updated_at)
            VALUES
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("thread-parent"), .text("Memograph"), .text("memograph"), .text("project"), .text("active"), .real(0.82), .integer(0), .null, .null, .text("2026-04-02T08:00:00Z"), .text("2026-04-09T10:00:00Z"), .integer(0), .null, .real(0.2), .text("tests"), .text("Broad thread"), .text("2026-04-02T08:00:00Z"), .text("2026-04-09T10:00:00Z"),
            .text("thread-child"), .text("Memograph advisory sidecar"), .text("memograph-advisory-sidecar"), .text("project"), .text("active"), .real(0.8), .integer(0), .null, .null, .text("2026-04-05T08:00:00Z"), .text("2026-04-09T10:55:00Z"), .integer(0), .null, .real(0.2), .text("tests"), .text("Narrow child thread"), .text("2026-04-05T08:00:00Z"), .text("2026-04-09T10:55:00Z"),
            .text("thread-stalled"), .text("Inbox cleanup"), .text("inbox-cleanup"), .text("commitment"), .text("active"), .real(0.7), .integer(0), .null, .null, .text("2026-04-01T08:00:00Z"), .text("2026-04-05T12:00:00Z"), .integer(30), .null, .real(0.1), .text("tests"), .text("Stalled thread"), .text("2026-04-01T08:00:00Z"), .text("2026-04-05T12:00:00Z"),
            .text("thread-resolved"), .text("Release preview"), .text("release-preview"), .text("project"), .text("active"), .real(0.76), .integer(0), .null, .null, .text("2026-03-01T08:00:00Z"), .text("2026-03-10T12:00:00Z"), .integer(45), .null, .real(0.1), .text("tests"), .text("Resolved thread"), .text("2026-03-01T08:00:00Z"), .text("2026-03-10T12:00:00Z")
        ])

        try db.execute("""
            INSERT INTO advisory_thread_evidence (id, thread_id, evidence_kind, evidence_ref, weight, created_at)
            VALUES
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?),
                (?, ?, ?, ?, ?, ?)
        """, params: [
            .text("ev-parent-session"), .text("thread-parent"), .text("session"), .text("session:sess-parent"), .real(1.0), .text("2026-04-09T10:00:00Z"),
            .text("ev-parent-summary"), .text("thread-parent"), .text("summary"), .text("summary:2026-04-09"), .real(0.8), .text("2026-04-09T10:05:00Z"),
            .text("ev-child-session"), .text("thread-child"), .text("session"), .text("session:sess-child"), .real(1.0), .text("2026-04-09T10:55:00Z"),
            .text("ev-stalled-summary"), .text("thread-stalled"), .text("summary"), .text("summary:2026-04-05"), .real(0.7), .text("2026-04-05T12:00:00Z")
        ])

        try db.execute("""
            INSERT INTO continuity_items
                (id, thread_id, kind, title, body, status, confidence, source_packet_id, created_at, updated_at, resolved_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("cont-parent"),
            .text("thread-parent"),
            .text("open_loop"),
            .text("Finish continuity card"),
            .text("Still active"),
            .text("open"),
            .real(0.8),
            .null,
            .text("2026-04-09T10:10:00Z"),
            .text("2026-04-09T10:10:00Z"),
            .null
        ])

        try db.execute("""
            INSERT INTO advisory_artifacts
                (id, domain, kind, title, body, thread_id, source_packet_id, source_recipe, confidence,
                 why_now, evidence_json, language, status, market_score, created_at, surfaced_at, expires_at,
                 attention_vector_json, market_context_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("artifact-resolved"),
            .text("continuity"),
            .text("resume_card"),
            .text("Resolved artifact"),
            .text("Historic artifact"),
            .text("thread-resolved"),
            .null,
            .text("continuity_resume"),
            .real(0.78),
            .null,
            .text(#"["summary:2026-03-10"]"#),
            .text("ru"),
            .text("accepted"),
            .real(0.6),
            .text("2026-03-10T12:10:00Z"),
            .text("2026-03-10T12:10:00Z"),
            .null,
            .null,
            .null
        ])

        let store = AdvisoryArtifactStore(db: db, timeZone: utc)
        let engine = ThreadMaintenanceEngine(db: db, store: store, timeZone: utc)
        let threads = try engine.refresh(referenceDate: "2026-04-10")
        let byId = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })

        let parent = try #require(byId["thread-parent"])
        let child = try #require(byId["thread-child"])
        let stalled = try #require(byId["thread-stalled"])
        let resolved = try #require(byId["thread-resolved"])

        #expect(parent.status == .active)
        #expect(parent.totalActiveMinutes >= 120)
        #expect(child.parentThreadId == parent.id)
        #expect(child.totalActiveMinutes >= 45)
        #expect(stalled.status == .stalled)
        #expect(resolved.status == .resolved)
        #expect(parent.importanceScore > stalled.importanceScore)
    }

    @Test("Thread maintenance proposes merge split and status moves for thread cleanup")
    func proposesMaintenanceMoves() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = AdvisoryArtifactStore(db: db, timeZone: utc)
        let broad = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-broad",
            title: "Memograph",
            slug: "memograph",
            kind: .project,
            status: .active,
            confidence: 0.84,
            firstSeenAt: "2026-04-01T08:00:00Z",
            lastActiveAt: "2026-04-09T12:00:00Z",
            source: "tests",
            summary: "Broad product thread.",
            parentThreadId: nil,
            totalActiveMinutes: 240,
            importanceScore: 0.82
        ))
        let child = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-narrow",
            title: "Memograph advisory sidecar",
            slug: "memograph-advisory-sidecar",
            kind: .project,
            status: .active,
            confidence: 0.78,
            firstSeenAt: "2026-04-05T08:00:00Z",
            lastActiveAt: "2026-04-09T11:00:00Z",
            source: "tests",
            summary: "Narrow duplicate-like child thread.",
            parentThreadId: nil,
            totalActiveMinutes: 45,
            importanceScore: 0.38
        ))
        let splitSource = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-split",
            title: "Advisory platform",
            slug: "advisory-platform",
            kind: .project,
            status: .active,
            confidence: 0.8,
            firstSeenAt: "2026-04-02T08:00:00Z",
            lastActiveAt: "2026-04-09T11:30:00Z",
            source: "tests",
            summary: "Broad thread that should likely spawn a child thread.",
            parentThreadId: nil,
            totalActiveMinutes: 260,
            importanceScore: 0.75
        ))
        let parked = try store.upsertThread(AdvisoryThreadCandidate(
            id: "thread-parked",
            title: "Old cleanup loop",
            slug: "old-cleanup-loop",
            kind: .commitment,
            status: .active,
            confidence: 0.7,
            firstSeenAt: "2026-03-20T08:00:00Z",
            lastActiveAt: "2026-03-29T12:00:00Z",
            source: "tests",
            summary: "Old thread with no fresh pressure.",
            parentThreadId: nil,
            totalActiveMinutes: 35,
            importanceScore: 0.16
        ))

        _ = broad
        try store.upsertContinuityItem(ContinuityItemCandidate(
            id: "cont-split-1",
            threadId: splitSource.id,
            kind: .openLoop,
            title: "Provider routing policy",
            body: "Decide how routing should work for advisory providers.",
            status: .open,
            confidence: 0.82,
            sourcePacketId: nil,
            createdAt: nil,
            updatedAt: nil,
            resolvedAt: nil
        ))
        try store.upsertContinuityItem(ContinuityItemCandidate(
            id: "cont-split-2",
            threadId: splitSource.id,
            kind: .question,
            title: "Sidecar retry budget",
            body: "Define how degraded retries should work.",
            status: .open,
            confidence: 0.8,
            sourcePacketId: nil,
            createdAt: nil,
            updatedAt: nil,
            resolvedAt: nil
        ))
        try store.upsertContinuityItem(ContinuityItemCandidate(
            id: "cont-split-3",
            threadId: splitSource.id,
            kind: .commitment,
            title: "UI runtime banner polish",
            body: "Make degraded advisory state visible but calm.",
            status: .open,
            confidence: 0.76,
            sourcePacketId: nil,
            createdAt: nil,
            updatedAt: nil,
            resolvedAt: nil
        ))

        let engine = ThreadMaintenanceEngine(db: db, store: store, timeZone: utc)

        let childProposals = try engine.proposals(for: child.id, referenceDate: "2026-04-10")
        let splitProposals = try engine.proposals(for: splitSource.id, referenceDate: "2026-04-10")
        let parkedProposals = try engine.proposals(for: parked.id, referenceDate: "2026-04-10")

        #expect(childProposals.contains {
            $0.kind == .mergeIntoThread && $0.targetThreadTitle == "Memograph"
        })
        #expect(splitProposals.contains { $0.kind == .splitIntoSubthread && $0.suggestedTitle == "Provider routing policy" })
        #expect(parkedProposals.contains { $0.kind == .statusChange && $0.suggestedStatus == .parked })
    }
}
