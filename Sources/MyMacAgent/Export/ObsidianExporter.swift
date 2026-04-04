import Foundation
import os

final class ObsidianExporter {
    private struct SummaryWindowMetadata {
        let count: Int?
        let windowStart: Date?
        let windowEnd: Date?
        let mode: String?

        var isHourly: Bool {
            guard let windowStart, let windowEnd else { return false }
            if mode == "hourly" {
                return true
            }
            return windowEnd.timeIntervalSince(windowStart) < 23 * 3600
        }
    }

    private let db: DatabaseManager
    private let vaultPath: String
    private let logger = Logger.export
    private let dateSupport: LocalDateSupport
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(db: DatabaseManager, vaultPath: String = "", timeZone: TimeZone = .autoupdatingCurrent) {
        self.db = db
        self.vaultPath = vaultPath
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func renderDailyNote(summary: DailySummaryRecord) throws -> String {
        let metadata = summaryWindowMetadata(from: summary.contextSwitchesJson)
        let title = noteTitle(for: summary, metadata: metadata)
        var md = "# \(title)\n\n"

        // Navigation links (graph connections between days)
        let prevDay = offsetDate(summary.date, by: -1)
        let nextDay = offsetDate(summary.date, by: 1)
        md += "← [[Daily/\(prevDay)|\(prevDay)]] | [[Daily/\(nextDay)|\(nextDay)]] →\n\n"

        if let metadata, metadata.isHourly,
           let windowStart = metadata.windowStart,
           let windowEnd = metadata.windowEnd {
            md += "_Окно отчёта: \(dateSupport.localDateTimeString(from: windowStart)) → "
            md += "\(dateSupport.localDateTimeString(from: windowEnd)) (\(dateSupport.timeZone.identifier))_\n\n"
        }

        if let richBody = richStructuredBody(from: summary.summaryText) {
            return md + stripTopHeading(from: richBody) + (richBody.hasSuffix("\n") ? "" : "\n")
        }

        // Summary
        md += "## Summary\n"
        md += "\(summary.summaryText ?? "No summary available.")\n\n"

        // Main apps
        md += "## Main apps\n"
        if let appsJson = summary.topAppsJson,
           let appsData = appsJson.data(using: .utf8),
           let apps = try? JSONSerialization.jsonObject(with: appsData) as? [[String: Any]] {
            for app in apps {
                let name = app["name"] as? String ?? "Unknown"
                let minutes = app["duration_min"] as? Int ?? 0
                md += "- \(name) — \(Self.formatDuration(minutes: minutes))\n"
            }
        } else {
            md += "- No app data available\n"
        }
        md += "\n"

        // Main topics
        md += "## Main topics\n"
        if let topicsJson = summary.topTopicsJson,
           let topicsData = topicsJson.data(using: .utf8),
           let topics = try? JSONSerialization.jsonObject(with: topicsData) as? [String] {
            for topic in topics {
                md += "- [[\(topic)]]\n"
            }
        } else {
            md += "- No topics extracted\n"
        }
        md += "\n"

        // Timeline
        md += "## Timeline\n"
        let timeline: String
        if let metadata, metadata.isHourly,
           let windowStart = metadata.windowStart,
           let windowEnd = metadata.windowEnd {
            let window = SummaryWindowDescriptor(date: summary.date, start: windowStart, end: windowEnd)
            timeline = try buildTimeline(for: window)
        } else {
            timeline = try buildTimeline(for: summary.date)
        }
        md += timeline.isEmpty ? "- No sessions recorded\n" : timeline
        md += "\n"

        // Suggested notes
        md += "## Suggested notes\n"
        if let notesJson = summary.suggestedNotesJson,
           let notesData = notesJson.data(using: .utf8),
           let notes = try? JSONSerialization.jsonObject(with: notesData) as? [String] {
            for note in notes {
                md += "- [[\(note)]]\n"
            }
        } else {
            md += "- No suggestions\n"
        }
        md += "\n"

        // Continue next
        if let unfinished = summary.unfinishedItemsJson {
            md += "## Продолжить далее\n"
            md += "- \(unfinished)\n\n"
        }

        return md
    }

    func buildTimeline(for date: String) throws -> String {
        guard let start = dateSupport.startOfLocalDay(for: date),
              let end = dateSupport.endOfLocalDay(for: date) else {
            return ""
        }
        return try buildTimeline(for: SummaryWindowDescriptor(date: date, start: start, end: end))
    }

    func buildTimeline(for window: SummaryWindowDescriptor) throws -> String {
        let rangeStart = dateSupport.isoString(from: window.start)
        let rangeEnd = dateSupport.isoString(from: window.end)
        let sessions = try db.query("""
            SELECT s.started_at, s.ended_at, a.app_name
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at < ? AND COALESCE(s.ended_at, ?) >= ?
            ORDER BY s.started_at
        """, params: [.text(rangeEnd), .text(rangeEnd), .text(rangeStart)])

        var timeline = ""
        for row in sessions {
            guard let startedAt = row["started_at"]?.textValue,
                  let appName = row["app_name"]?.textValue else { continue }
            guard let sessionStart = dateSupport.parseDateTime(startedAt) else { continue }

            let sessionEnd = row["ended_at"]?.textValue.flatMap(dateSupport.parseDateTime) ?? window.end
            let clippedStart = max(sessionStart, window.start)
            let clippedEnd = min(sessionEnd, window.end)
            guard clippedEnd > clippedStart else { continue }

            let startTime = formatTime(dateSupport.isoString(from: clippedStart))
            let endTime = formatTime(dateSupport.isoString(from: clippedEnd))
            timeline += "- \(startTime)–\(endTime) — \(appName)\n"
        }
        return timeline
    }

    func exportDailyNote(summary: DailySummaryRecord) throws -> String {
        let markdown = try renderDailyNote(summary: summary)

        let dailyDir = (vaultPath as NSString).appendingPathComponent("Daily")
        try FileManager.default.createDirectory(atPath: dailyDir, withIntermediateDirectories: true)

        let filename = noteFilename(for: summary)
        let filePath = (dailyDir as NSString).appendingPathComponent(filename)

        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        logger.info("Exported daily note to \(filePath)")

        return filePath
    }

    func exportKnowledgeNote(_ note: KnowledgeNoteRecord) throws -> String {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        let folder = knowledgeFolderName(for: note.noteType)
        let directory = (knowledgeRoot as NSString).appendingPathComponent(folder)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let slug = knowledgeSlug(for: note.title)
        let filePath = (directory as NSString).appendingPathComponent("\(slug).md")
        try note.bodyMarkdown.write(toFile: filePath, atomically: true, encoding: .utf8)

        try? db.execute("""
            UPDATE knowledge_notes
            SET export_obsidian_status = 'done'
            WHERE id = ?
        """, params: [.text(note.id)])

        return filePath
    }

    func exportKnowledgeIndex(_ markdown: String) throws -> String {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        try FileManager.default.createDirectory(atPath: knowledgeRoot, withIntermediateDirectories: true)

        let filePath = (knowledgeRoot as NSString).appendingPathComponent("_index.md")
        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    func exportKnowledgeMaintenance(_ markdown: String) throws -> String {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        try FileManager.default.createDirectory(atPath: knowledgeRoot, withIntermediateDirectories: true)

        let filePath = (knowledgeRoot as NSString).appendingPathComponent("_maintenance.md")
        try markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
        return filePath
    }

    @discardableResult
    func syncKnowledgeDraftArtifacts(_ artifacts: [KnowledgeDraftArtifact]) throws -> [String] {
        let draftsDirectory = knowledgeDraftsDirectory()
        try FileManager.default.createDirectory(atPath: draftsDirectory, withIntermediateDirectories: true)

        let expectedFileNames = Set(artifacts.map(\.fileName))
        let existingFiles = (try? FileManager.default.contentsOfDirectory(atPath: draftsDirectory)) ?? []
        for file in existingFiles where file.hasSuffix(".md") && !expectedFileNames.contains(file) {
            let path = (draftsDirectory as NSString).appendingPathComponent(file)
            try? FileManager.default.removeItem(atPath: path)
        }

        var writtenPaths: [String] = []
        for artifact in artifacts {
            let filePath = (draftsDirectory as NSString).appendingPathComponent(artifact.fileName)
            try artifact.markdown.write(toFile: filePath, atomically: true, encoding: .utf8)
            writtenPaths.append(filePath)
        }

        return writtenPaths
    }

    func deleteKnowledgeNote(_ note: KnowledgeNoteRecord) throws {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        let folder = knowledgeFolderName(for: note.noteType)
        let directory = (knowledgeRoot as NSString).appendingPathComponent(folder)
        let slug = knowledgeSlug(for: note.title)
        let filePath = (directory as NSString).appendingPathComponent("\(slug).md")

        if FileManager.default.fileExists(atPath: filePath) {
            try FileManager.default.removeItem(atPath: filePath)
        }
    }

    func enqueueSummaryExport(_ summary: DailySummaryRecord, lastError: String? = nil) throws {
        let entityId = exportEntityId(for: summary)
        let payloadData = try encoder.encode(summary)
        guard let payloadJson = String(data: payloadData, encoding: .utf8) else {
            throw DatabaseError.executeFailed("Failed to encode export payload")
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let existing = try db.query("""
            SELECT id, retry_count
            FROM sync_queue
            WHERE job_type = ? AND entity_id = ?
              AND status IN ('pending', 'running', 'failed')
            ORDER BY id DESC
            LIMIT 1
        """, params: [.text("obsidian_export_summary"), .text(entityId)])

        if let row = existing.first,
           let id = row["id"]?.intValue {
            try db.execute("""
                UPDATE sync_queue
                SET payload_json = ?, status = 'pending', scheduled_at = ?, last_error = ?, finished_at = NULL
                WHERE id = ?
            """, params: [
                .text(payloadJson),
                .text(now),
                lastError.map { .text($0) } ?? .null,
                .integer(id)
            ])
        } else {
            try db.execute("""
                INSERT INTO sync_queue (job_type, entity_id, payload_json, status, retry_count, scheduled_at, last_error)
                VALUES (?, ?, ?, 'pending', 0, ?, ?)
            """, params: [
                .text("obsidian_export_summary"),
                .text(entityId),
                .text(payloadJson),
                .text(now),
                lastError.map { .text($0) } ?? .null
            ])
        }
    }

    @discardableResult
    func drainQueuedExports(limit: Int = 8) throws -> Int {
        let now = Date()
        let nowString = ISO8601DateFormatter().string(from: now)
        let rows = try db.query("""
            SELECT id, payload_json, retry_count
            FROM sync_queue
            WHERE job_type = ?
              AND status IN ('pending', 'failed')
              AND (scheduled_at IS NULL OR scheduled_at <= ?)
            ORDER BY id
            LIMIT ?
        """, params: [
            .text("obsidian_export_summary"),
            .text(nowString),
            .integer(Int64(limit))
        ])

        var exportedCount = 0
        for row in rows {
            guard let id = row["id"]?.intValue else { continue }
            let retryCount = Int(row["retry_count"]?.intValue ?? 0)

            try db.execute("""
                UPDATE sync_queue
                SET status = 'running', started_at = ?, last_error = NULL
                WHERE id = ?
            """, params: [.text(nowString), .integer(id)])

            do {
                guard let payloadJson = row["payload_json"]?.textValue,
                      let payloadData = payloadJson.data(using: .utf8) else {
                    throw DatabaseError.executeFailed("Missing export payload")
                }

                let summary = try decoder.decode(DailySummaryRecord.self, from: payloadData)
                _ = try exportDailyNote(summary: summary)

                try db.execute("""
                    UPDATE sync_queue
                    SET status = 'done', finished_at = ?, started_at = COALESCE(started_at, ?), last_error = NULL
                    WHERE id = ?
                """, params: [.text(nowString), .text(nowString), .integer(id)])
                exportedCount += 1
            } catch {
                let nextRetry = ISO8601DateFormatter().string(
                    from: now.addingTimeInterval(retryDelay(for: retryCount + 1))
                )
                try db.execute("""
                    UPDATE sync_queue
                    SET status = 'failed', retry_count = ?, scheduled_at = ?, finished_at = ?, last_error = ?
                    WHERE id = ?
                """, params: [
                    .integer(Int64(retryCount + 1)),
                    .text(nextRetry),
                    .text(nowString),
                    .text(error.localizedDescription),
                    .integer(id)
                ])
            }
        }

        return exportedCount
    }

    @discardableResult
    func cleanupSyncQueueHistory(
        doneOlderThanDays: Int = 7,
        failedOlderThanDays: Int = 30
    ) throws -> Int {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let doneCutoff = formatter.string(
            from: Calendar.current.date(byAdding: .day, value: -doneOlderThanDays, to: now) ?? now
        )
        let failedCutoff = formatter.string(
            from: Calendar.current.date(byAdding: .day, value: -failedOlderThanDays, to: now) ?? now
        )

        let doneRows = try db.query("""
            SELECT COUNT(*) as c
            FROM sync_queue
            WHERE status = 'done'
              AND finished_at IS NOT NULL
              AND finished_at < ?
        """, params: [.text(doneCutoff)])
        let failedRows = try db.query("""
            SELECT COUNT(*) as c
            FROM sync_queue
            WHERE status = 'failed'
              AND finished_at IS NOT NULL
              AND finished_at < ?
        """, params: [.text(failedCutoff)])
        let deletedCount = Int(doneRows.first?["c"]?.intValue ?? 0)
            + Int(failedRows.first?["c"]?.intValue ?? 0)

        try db.execute("""
            DELETE FROM sync_queue
            WHERE status = 'done'
              AND finished_at IS NOT NULL
              AND finished_at < ?
        """, params: [.text(doneCutoff)])
        try db.execute("""
            DELETE FROM sync_queue
            WHERE status = 'failed'
              AND finished_at IS NOT NULL
              AND finished_at < ?
        """, params: [.text(failedCutoff)])

        return deletedCount
    }

    static func formatDuration(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let mins = minutes % 60
        return "\(hours)h \(String(format: "%02d", mins))m"
    }

    private func offsetDate(_ dateStr: String, by days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateStr) else { return dateStr }
        guard let offset = Calendar.current.date(byAdding: .day, value: days, to: date) else { return dateStr }
        return formatter.string(from: offset)
    }

    private func formatTime(_ isoString: String) -> String {
        dateSupport.localTimeString(from: isoString)
    }

    private func noteTitle(for summary: DailySummaryRecord, metadata: SummaryWindowMetadata?) -> String {
        guard let metadata, metadata.isHourly,
              let windowStart = metadata.windowStart,
              let windowEnd = metadata.windowEnd else {
            return "Daily Log — \(summary.date)"
        }

        return "Hourly Log — \(dateSupport.localDateString(from: windowStart)) "
            + "\(dateSupport.localTimeString(from: windowStart))–\(dateSupport.localTimeString(from: windowEnd))"
    }

    private func noteFilename(for summary: DailySummaryRecord) -> String {
        if let metadata = summaryWindowMetadata(from: summary.contextSwitchesJson),
           metadata.isHourly,
           let windowStart = metadata.windowStart,
           let windowEnd = metadata.windowEnd {
            return "\(dateSupport.localDateString(from: windowStart))_"
                + "\(dateSupport.localTimeString(from: windowStart).replacingOccurrences(of: ":", with: "-"))-"
                + "\(dateSupport.localTimeString(from: windowEnd).replacingOccurrences(of: ":", with: "-")).md"
        }

        let timeStamp = summary.generatedAt
            .flatMap(dateSupport.parseDateTime)
            .map { dateSupport.localTimeString(from: $0).replacingOccurrences(of: ":", with: "-") }
            ?? dateSupport.localTimeString(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(summary.date)_\(timeStamp).md"
    }

    private func exportEntityId(for summary: DailySummaryRecord) -> String {
        if let metadata = summaryWindowMetadata(from: summary.contextSwitchesJson),
           let windowStart = metadata.windowStart,
           let windowEnd = metadata.windowEnd {
            return "\(summary.date)|\(dateSupport.isoString(from: windowStart))|\(dateSupport.isoString(from: windowEnd))"
        }

        return "\(summary.date)|daily"
    }

    private func summaryWindowMetadata(from json: String?) -> SummaryWindowMetadata? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let count = object["count"] as? Int
        let windowStart = (object["window_start"] as? String).flatMap(dateSupport.parseDateTime)
        let windowEnd = (object["window_end"] as? String).flatMap(dateSupport.parseDateTime)
        let mode = object["mode"] as? String
        return SummaryWindowMetadata(count: count, windowStart: windowStart, windowEnd: windowEnd, mode: mode)
    }

    private func retryDelay(for retryCount: Int) -> TimeInterval {
        let boundedRetryCount = min(max(retryCount, 1), 6)
        return Double(1 << boundedRetryCount) * 60
    }

    private func knowledgeFolderName(for noteType: String) -> String {
        KnowledgeEntityType(rawValue: noteType)?.folderName ?? "Topics"
    }

    private func knowledgeDraftsDirectory() -> String {
        let knowledgeRoot = (vaultPath as NSString).appendingPathComponent("Knowledge")
        let draftsRoot = (knowledgeRoot as NSString).appendingPathComponent("_drafts")
        return (draftsRoot as NSString).appendingPathComponent("Maintenance")
    }

    private func knowledgeSlug(for title: String) -> String {
        let lowered = title.lowercased()
        let allowed = lowered.map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return "-"
        }
        let collapsed = String(allowed)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "note" : collapsed
    }

    private func stripTopHeading(from markdown: String) -> String {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n")
        guard let first = lines.first,
              first.hasPrefix("# ") else {
            return trimmed + "\n"
        }
        return lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private func richStructuredBody(from text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("# Daily Log —") || trimmed.hasPrefix("# Hourly Log —") {
            return trimmed
        }

        if trimmed.contains("## Детальный таймлайн") && trimmed.contains("## Проекты и код") {
            return trimmed
        }

        return nil
    }
}
