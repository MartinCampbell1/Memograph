import AppKit
import Foundation
import SwiftUI
import os

@MainActor
enum MarketingAssetRenderer {
    private static let logger = Logger.app

    static func run() throws {
        let outputDirectory = try makeOutputDirectory()
        let demoDB = try makeDemoDatabase()

        try renderWindow(
            title: "Timeline",
            size: NSSize(width: 1320, height: 640),
            rootView: TimelineView(db: demoDB)
                .frame(width: 1320, height: 640),
            outputURL: outputDirectory.appending(path: "timeline.png")
        )

        try renderWindow(
            title: "Settings",
            size: NSSize(width: 1080, height: 620),
            rootView: SettingsView(initialTab: 1, previewState: .marketing)
                .frame(width: 1080, height: 620),
            outputURL: outputDirectory.appending(path: "settings-providers.png")
        )

        try renderWindow(
            title: "Settings",
            size: NSSize(width: 1080, height: 760),
            rootView: SettingsView(initialTab: 3, previewState: .marketing)
                .frame(width: 1080, height: 760),
            outputURL: outputDirectory.appending(path: "settings-privacy.png")
        )

        logger.info("Marketing screenshots exported to \(outputDirectory.path)")
    }

    private static func makeOutputDirectory() throws -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let outputDirectory = cwd.appending(path: "docs").appending(path: "screenshots")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        return outputDirectory
    }

    private static func makeDemoDatabase() throws -> DatabaseManager {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "memograph-marketing-\(UUID().uuidString).db")
        let db = try DatabaseManager(path: url.path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V002_AudioTranscripts.migration,
            V003_PerformanceIndexes.migration,
            V004_AudioTranscriptDurability.migration,
            V005_KnowledgeGraph.migration,
            V006_AdvisoryThreads.migration,
            V007_AdvisoryArtifacts.migration,
            V008_AdvisoryRuns.migration,
            V009_AttentionMarketMetadata.migration,
            V010_ThreadIntelligenceMetadata.migration,
            V011_AdvisoryArtifactMetadata.migration
        ])
        try runner.runPending()
        try seedDemoData(db: db)
        return db
    }

    private static func seedDemoData(db: DatabaseManager) throws {
        let today = currentDateString()
        let yesterday = offsetDateString(days: -1)

        try insertApp(db: db, bundleId: "com.apple.dt.Xcode", appName: "Xcode")
        try insertApp(db: db, bundleId: "com.apple.Safari", appName: "Safari")
        try insertApp(db: db, bundleId: "md.obsidian", appName: "Obsidian")

        let xcodeAppId = try appId(db: db, bundleId: "com.apple.dt.Xcode")
        let safariAppId = try appId(db: db, bundleId: "com.apple.Safari")
        let obsidianAppId = try appId(db: db, bundleId: "md.obsidian")

        try insertWindow(db: db, id: 1, appId: xcodeAppId, title: "README polish - Memograph")
        try insertWindow(db: db, id: 2, appId: safariAppId, title: "ScreenPipe research")
        try insertWindow(db: db, id: 3, appId: obsidianAppId, title: "Daily note.md")

        try insertSession(
            db: db,
            id: "sess-xcode-morning",
            appId: xcodeAppId,
            windowId: 1,
            startedAt: isoDate(today, hour: 9, minute: 14),
            endedAt: isoDate(today, hour: 10, minute: 32),
            durationMinutes: 78,
            uncertaintyMode: "normal"
        )
        try insertSession(
            db: db,
            id: "sess-safari-research",
            appId: safariAppId,
            windowId: 2,
            startedAt: isoDate(today, hour: 10, minute: 38),
            endedAt: isoDate(today, hour: 11, minute: 22),
            durationMinutes: 44,
            uncertaintyMode: "degraded"
        )
        try insertSession(
            db: db,
            id: "sess-obsidian-export",
            appId: obsidianAppId,
            windowId: 3,
            startedAt: isoDate(today, hour: 17, minute: 18),
            endedAt: isoDate(today, hour: 17, minute: 46),
            durationMinutes: 28,
            uncertaintyMode: "normal"
        )
        try insertSession(
            db: db,
            id: "sess-xcode-yesterday",
            appId: xcodeAppId,
            windowId: 1,
            startedAt: isoDate(yesterday, hour: 14, minute: 8),
            endedAt: isoDate(yesterday, hour: 15, minute: 1),
            durationMinutes: 53,
            uncertaintyMode: "high_uncertainty"
        )

        try insertContextSnapshot(
            db: db,
            id: "ctx-1",
            sessionId: "sess-xcode-morning",
            timestamp: isoDate(today, hour: 9, minute: 30),
            appName: "Xcode",
            bundleId: "com.apple.dt.Xcode",
            windowTitle: "README polish - Memograph",
            textSource: "ax+ocr",
            mergedText: "Reworked README install flow, added Homebrew tap, and replaced placeholder visuals with real app screenshots.",
            topicHint: "release polish",
            readableScore: 0.94,
            uncertaintyScore: 0.06
        )
        try insertContextSnapshot(
            db: db,
            id: "ctx-2",
            sessionId: "sess-safari-research",
            timestamp: isoDate(today, hour: 10, minute: 57),
            appName: "Safari",
            bundleId: "com.apple.Safari",
            windowTitle: "ScreenPipe research",
            textSource: "ocr",
            mergedText: "Compared product positioning, GitHub metadata, pricing posture, and presentation against ScreenPipe.",
            topicHint: "competitive research",
            readableScore: 0.71,
            uncertaintyScore: 0.29
        )
        try insertContextSnapshot(
            db: db,
            id: "ctx-3",
            sessionId: "sess-obsidian-export",
            timestamp: isoDate(today, hour: 17, minute: 30),
            appName: "Obsidian",
            bundleId: "md.obsidian",
            windowTitle: "Daily note.md",
            textSource: "ax",
            mergedText: "Exported final summary to Obsidian and drafted follow-up tasks for release hardening.",
            topicHint: "knowledge capture",
            readableScore: 0.96,
            uncertaintyScore: 0.04
        )

        try db.execute("""
            INSERT OR REPLACE INTO daily_summaries
            (date, summary_text, top_apps_json, top_topics_json, ai_sessions_json,
             context_switches_json, unfinished_items_json, suggested_notes_json,
             generated_at, model_name, token_usage_input, token_usage_output, generation_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(today),
            .text("""
            You spent the day polishing Memograph for a public preview release: tightened install flow, replaced fake visuals with real screenshots, fixed GitHub Actions toolchain drift, and clarified the product story around a free local-first macOS memory app.
            """),
            .text("[{\"app\":\"Xcode\",\"minutes\":78},{\"app\":\"Safari\",\"minutes\":44},{\"app\":\"Obsidian\",\"minutes\":28}]"),
            .text("[\"release polish\",\"competitive research\",\"knowledge capture\"]"),
            .text("[\"README rewrite\",\"CI fix\"]"),
            .text("[\"Xcode -> Safari\",\"Safari -> Obsidian\"]"),
            .text("[\"Capture real screenshots for homepage\",\"Notarize preview build\"]"),
            .text("[\"Memograph positioning\",\"Privacy defaults\",\"Release pipeline\"]"),
            .text(isoDate(today, hour: 18, minute: 2)),
            .text("google/gemini-2.5-flash-preview"),
            .integer(2480),
            .integer(612),
            .text("complete")
        ])
    }

    private static func insertApp(db: DatabaseManager, bundleId: String, appName: String) throws {
        try db.execute("""
            INSERT OR IGNORE INTO apps (bundle_id, app_name, category)
            VALUES (?, ?, ?)
        """, params: [
            .text(bundleId),
            .text(appName),
            .text("work")
        ])
    }

    private static func appId(db: DatabaseManager, bundleId: String) throws -> Int64 {
        let rows = try db.query("SELECT id FROM apps WHERE bundle_id = ?", params: [.text(bundleId)])
        guard let id = rows.first?["id"]?.intValue else {
            throw NSError(domain: "MarketingAssetRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing app id for \(bundleId)"])
        }
        return id
    }

    private static func insertWindow(db: DatabaseManager, id: Int64, appId: Int64, title: String) throws {
        try db.execute("""
            INSERT OR REPLACE INTO windows
            (id, app_id, window_title, window_role, first_seen_at, last_seen_at, fingerprint)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .integer(id),
            .integer(appId),
            .text(title),
            .text("AXWindow"),
            .text(isoDate(currentDateString(), hour: 9, minute: 0)),
            .text(isoDate(currentDateString(), hour: 18, minute: 0)),
            .text(title.lowercased().replacingOccurrences(of: " ", with: "-"))
        ])
    }

    private static func insertSession(
        db: DatabaseManager,
        id: String,
        appId: Int64,
        windowId: Int64,
        startedAt: String,
        endedAt: String,
        durationMinutes: Int,
        uncertaintyMode: String
    ) throws {
        try db.execute("""
            INSERT OR REPLACE INTO sessions
            (id, app_id, window_id, session_type, started_at, ended_at,
             active_duration_ms, idle_duration_ms, confidence_score,
             uncertainty_mode, top_topic, is_ai_related, summary_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            .integer(appId),
            .integer(windowId),
            .text("focused_work"),
            .text(startedAt),
            .text(endedAt),
            .integer(Int64(durationMinutes * 60_000)),
            .integer(0),
            .real(0.91),
            .text(uncertaintyMode),
            .text("release"),
            .integer(1),
            .text("complete")
        ])
    }

    private static func insertContextSnapshot(
        db: DatabaseManager,
        id: String,
        sessionId: String,
        timestamp: String,
        appName: String,
        bundleId: String,
        windowTitle: String,
        textSource: String,
        mergedText: String,
        topicHint: String,
        readableScore: Double,
        uncertaintyScore: Double
    ) throws {
        try db.execute("""
            INSERT OR REPLACE INTO context_snapshots
            (id, session_id, timestamp, app_name, bundle_id, window_title,
             text_source, merged_text, merged_text_hash, topic_hint,
             readable_score, uncertainty_score, source_capture_id, source_ax_id, source_ocr_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            .text(sessionId),
            .text(timestamp),
            .text(appName),
            .text(bundleId),
            .text(windowTitle),
            .text(textSource),
            .text(mergedText),
            .text(UUID().uuidString.lowercased()),
            .text(topicHint),
            .real(readableScore),
            .real(uncertaintyScore),
            .null,
            .null,
            .null
        ])
    }

    private static func renderWindow<Content: View>(
        title: String,
        size: NSSize,
        rootView: Content,
        outputURL: URL
    ) throws {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.center()
        window.backgroundColor = .windowBackgroundColor
        window.contentView = NSHostingView(
            rootView: ZStack {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
                rootView
            }
        )
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()

        RunLoop.main.run(until: Date().addingTimeInterval(1.0))

        if let contentView = window.contentView,
           let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) {
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "MarketingAssetRenderer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode screenshot"])
            }
            try data.write(to: outputURL)
        } else {
            throw NSError(domain: "MarketingAssetRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to capture window"])
        }

        window.orderOut(nil)
    }

    private static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func offsetDateString(days: Int) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let shiftedDate = calendar.date(byAdding: .day, value: days, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: shiftedDate)
    }

    private static func isoDate(_ day: String, hour: Int, minute: Int) -> String {
        String(format: "%@T%02d:%02d:00Z", day, hour, minute)
    }
}
