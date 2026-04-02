import Foundation
import os

final class ObsidianExporter {
    private let db: DatabaseManager
    private let vaultPath: String
    private let logger = Logger.export

    init(db: DatabaseManager, vaultPath: String = "") {
        self.db = db
        self.vaultPath = vaultPath
    }

    func renderDailyNote(summary: DailySummaryRecord) throws -> String {
        var md = "# Daily Log — \(summary.date)\n\n"

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
                md += "- \(topic)\n"
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

        // Continue tomorrow
        if let unfinished = summary.unfinishedItemsJson {
            md += "## Continue tomorrow\n"
            md += "- \(unfinished)\n\n"
        }

        return md
    }

    func buildTimeline(for date: String) throws -> String {
        let sessions = try db.query("""
            SELECT s.started_at, s.ended_at, a.app_name
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at LIKE ?
            ORDER BY s.started_at
        """, params: [.text("\(date)%")])

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

        let filename = "\(summary.date).md"
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

    private func formatTime(_ isoString: String) -> String {
        // Extract HH:mm from ISO 8601 string like "2026-04-02T09:10:00Z"
        guard isoString.count >= 16 else { return isoString }
        let startIndex = isoString.index(isoString.startIndex, offsetBy: 11)
        let endIndex = isoString.index(startIndex, offsetBy: 5)
        return String(isoString[startIndex..<endIndex])
    }
}
