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
        let timeline = try buildTimeline(for: summary.date)
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
        guard let range = dateSupport.utcRange(forLocalDate: date) else {
            return ""
        }
        let sessions = try db.query("""
            SELECT s.started_at, s.ended_at, a.app_name
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at >= ? AND s.started_at < ?
            ORDER BY s.started_at
        """, params: [.text(range.start), .text(range.end)])

        var timeline = ""
        for row in sessions {
            guard let startedAt = row["started_at"]?.textValue,
                  let appName = row["app_name"]?.textValue else { continue }

            let startTime = formatTime(startedAt)
            let endTime = row["ended_at"]?.textValue.map { formatTime($0) } ?? "ongoing"
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
