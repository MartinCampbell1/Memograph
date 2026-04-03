#!/usr/bin/env swift

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct SessionRow {
    let appName: String
    let bundleID: String
    let startedAt: Date
    let endedAt: Date?
    let activeDurationMs: Int64
}

struct SnapshotRow {
    let timestamp: Date
    let appName: String
    let bundleID: String
    let windowTitle: String
    let mergedText: String
}

enum BackfillError: Error, CustomStringConvertible {
    case sqliteOpen(String)
    case sqlitePrepare(String)

    var description: String {
        switch self {
        case .sqliteOpen(let path):
            return "Failed to open SQLite database at \(path)"
        case .sqlitePrepare(let message):
            return "SQLite prepare failed: \(message)"
        }
    }
}

final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(path: String) throws {
        var rawHandle: OpaquePointer?
        if sqlite3_open_v2(path, &rawHandle, SQLITE_OPEN_READONLY, nil) != SQLITE_OK || rawHandle == nil {
            throw BackfillError.sqliteOpen(path)
        }
        self.handle = rawHandle!
    }

    deinit {
        sqlite3_close(handle)
    }

    func rows(sql: String, params: [String] = []) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, statement != nil else {
            throw BackfillError.sqlitePrepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in params.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }

        var result: [[String: String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String] = [:]
            for columnIndex in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, columnIndex))
                if let text = sqlite3_column_text(statement, columnIndex) {
                    row[key] = String(cString: text)
                } else {
                    row[key] = nil
                }
            }
            result.append(row)
        }

        return result
    }
}

struct BackfillReportGenerator {
    private let minimumSessionDurationMs: Int64 = 3_000
    private let mergeGapThreshold: TimeInterval = 20
    private let db: SQLiteDatabase
    private let dbPath: String
    private let vaultPath: String
    private let timeZone: TimeZone
    private let noiseBundles = Set([
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.accessibility.universalAccessAuthWarn",
        "com.apple.loginwindow"
    ])

    private let isoFormatter: ISO8601DateFormatter
    private let localDateTimeFormatter: DateFormatter
    private let localTimeFormatter: DateFormatter
    private let fileTimeFormatter: DateFormatter

    init(dbPath: String, vaultPath: String, timeZone: TimeZone = .autoupdatingCurrent) throws {
        self.dbPath = dbPath
        self.db = try SQLiteDatabase(path: dbPath)
        self.vaultPath = vaultPath
        self.timeZone = timeZone

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = iso

        let localDateTime = DateFormatter()
        localDateTime.timeZone = timeZone
        localDateTime.dateFormat = "yyyy-MM-dd HH:mm:ss"
        self.localDateTimeFormatter = localDateTime

        let localTime = DateFormatter()
        localTime.timeZone = timeZone
        localTime.dateFormat = "HH:mm"
        self.localTimeFormatter = localTime

        let fileTime = DateFormatter()
        fileTime.timeZone = timeZone
        fileTime.dateFormat = "yyyy-MM-dd_HH-mm"
        self.fileTimeFormatter = fileTime
    }

    func latestGeneratedAt() throws -> Date? {
        let rows = try db.rows(
            sql: """
                SELECT generated_at
                FROM daily_summaries
                WHERE generated_at IS NOT NULL
                ORDER BY generated_at DESC
                LIMIT 1
            """
        )

        guard let raw = rows.first?["generated_at"] else {
            return nil
        }

        return parseISO(raw)
    }

    func generate(from startDate: Date, to endDate: Date = Date()) throws -> String {
        let sessions = try loadSessions(from: startDate, to: endDate)
        let snapshots = try loadSnapshots(from: startDate, to: endDate)

        let filteredSessions = mergeSessions(
            sessions.filter {
                !noiseBundles.contains($0.bundleID)
                && $0.activeDurationMs >= minimumSessionDurationMs
            }
        )
        let filteredSnapshots = snapshots.filter { !noiseBundles.contains($0.bundleID) }

        let markdown = buildMarkdown(
            from: startDate,
            to: endDate,
            sessions: filteredSessions,
            snapshots: filteredSnapshots,
            skippedBundles: Set(sessions.filter { noiseBundles.contains($0.bundleID) }.map(\.appName)).sorted()
        )

        let dailyDir = (vaultPath as NSString).appendingPathComponent("Daily")
        try FileManager.default.createDirectory(atPath: dailyDir, withIntermediateDirectories: true)

        let filename = "recovery_\(fileTimeFormatter.string(from: startDate))_to_\(fileTimeFormatter.string(from: endDate)).md"
        let path = (dailyDir as NSString).appendingPathComponent(filename)
        try markdown.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func loadSessions(from startDate: Date, to endDate: Date) throws -> [SessionRow] {
        let rows = try db.rows(
            sql: """
                SELECT a.app_name, a.bundle_id, s.started_at, s.ended_at, s.active_duration_ms
                FROM sessions s
                JOIN apps a ON a.id = s.app_id
                WHERE s.started_at > ? AND s.started_at <= ?
                ORDER BY s.started_at
            """,
            params: [isoString(startDate), isoString(endDate)]
        )

        return rows.compactMap { row in
            guard let appName = row["app_name"],
                  let bundleID = row["bundle_id"],
                  let startedAtRaw = row["started_at"],
                  let startedAt = parseISO(startedAtRaw),
                  let activeDurationRaw = row["active_duration_ms"],
                  let activeDurationMs = Int64(activeDurationRaw) else {
                return nil
            }

            return SessionRow(
                appName: appName,
                bundleID: bundleID,
                startedAt: startedAt,
                endedAt: row["ended_at"].flatMap(parseISO),
                activeDurationMs: activeDurationMs
            )
        }
    }

    private func loadSnapshots(from startDate: Date, to endDate: Date) throws -> [SnapshotRow] {
        let rows = try db.rows(
            sql: """
                SELECT cs.timestamp, a.app_name, a.bundle_id, cs.window_title, cs.merged_text
                FROM context_snapshots cs
                JOIN sessions s ON s.id = cs.session_id
                JOIN apps a ON a.id = s.app_id
                WHERE cs.timestamp > ? AND cs.timestamp <= ?
                  AND cs.merged_text IS NOT NULL
                ORDER BY cs.timestamp
            """,
            params: [isoString(startDate), isoString(endDate)]
        )

        return rows.compactMap { row in
            guard let timestampRaw = row["timestamp"],
                  let timestamp = parseISO(timestampRaw),
                  let appName = row["app_name"],
                  let bundleID = row["bundle_id"] else {
                return nil
            }

            return SnapshotRow(
                timestamp: timestamp,
                appName: appName,
                bundleID: bundleID,
                windowTitle: row["window_title"] ?? "",
                mergedText: row["merged_text"] ?? ""
            )
        }
    }

    private func buildMarkdown(
        from startDate: Date,
        to endDate: Date,
        sessions: [SessionRow],
        snapshots: [SnapshotRow],
        skippedBundles: [String]
    ) -> String {
        let totalActiveMs = sessions.reduce(Int64(0)) { $0 + $1.activeDurationMs }
        let appDurations = Dictionary(grouping: sessions, by: \.appName)
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.activeDurationMs } }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }

        var markdown = "# Recovery Log — \(localTimeFormatter.string(from: startDate))–\(localTimeFormatter.string(from: endDate))\n\n"
        markdown += "Generated from captured activity after a missed auto-summary window.\n\n"

        markdown += "## Overview\n"
        markdown += "- Range: \(localDateTimeFormatter.string(from: startDate)) → \(localDateTimeFormatter.string(from: endDate)) (\(timeZone.identifier))\n"
        markdown += "- Database: `\(dbPath)`\n"
        markdown += "- Active sessions: \(sessions.count)\n"
        markdown += "- Active time: \(formatDuration(totalActiveMs))\n"
        markdown += "- Captured snapshots: \(snapshots.count)\n"
        if !skippedBundles.isEmpty {
            markdown += "- Omitted noise apps: \(skippedBundles.joined(separator: ", "))\n"
        }
        markdown += "\n"

        markdown += "## Main Apps\n"
        if appDurations.isEmpty {
            markdown += "- No non-idle sessions recorded in this interval\n\n"
        } else {
            for (app, durationMs) in appDurations {
                markdown += "- \(app) — \(formatDuration(durationMs))\n"
            }
            markdown += "\n"
        }

        markdown += "## Timeline\n"
        if sessions.isEmpty {
            markdown += "- No timeline entries\n\n"
        } else {
            for session in sessions {
                let start = localTimeFormatter.string(from: session.startedAt)
                let end = session.endedAt.map(localTimeFormatter.string(from:)) ?? "ongoing"
                markdown += "- \(start)–\(end) — \(session.appName) (\(formatDuration(session.activeDurationMs)))\n"
            }
            markdown += "\n"
        }

        markdown += "## Notable Windows\n"
        let windowsByApp = Dictionary(grouping: snapshots, by: \.appName)
            .mapValues { rows in
                Array(
                    Set(
                        rows.map(\.windowTitle)
                            .map(cleanWindowTitle)
                            .filter { !$0.isEmpty && $0 != rows.first?.appName }
                    )
                ).sorted()
            }
            .filter { !$0.value.isEmpty }

        if windowsByApp.isEmpty {
            markdown += "- No distinct windows captured\n\n"
        } else {
            for app in windowsByApp.keys.sorted() {
                markdown += "### \(app)\n"
                for title in windowsByApp[app, default: []].prefix(6) {
                    markdown += "- \(title)\n"
                }
                markdown += "\n"
            }
        }

        markdown += "## Captured Context\n"
        let snippetsByApp = Dictionary(grouping: snapshots, by: \.appName)
            .mapValues(selectSnippets)
            .filter { !$0.value.isEmpty }

        if snippetsByApp.isEmpty {
            markdown += "- No merged text captured\n"
        } else {
            for app in snippetsByApp.keys.sorted() {
                markdown += "### \(app)\n"
                for snippet in snippetsByApp[app, default: []] {
                    markdown += "- \(localTimeFormatter.string(from: snippet.timestamp)) — \(snippet.text)\n"
                }
                markdown += "\n"
            }
        }

        return markdown
    }

    private func selectSnippets(from snapshots: [SnapshotRow]) -> [(timestamp: Date, text: String)] {
        var seen = Set<String>()
        var result: [(Date, String)] = []

        for snapshot in snapshots {
            let cleanedText = cleanSnippet(snapshot.mergedText)
            let cleanedWindow = cleanWindowTitle(snapshot.windowTitle)
            let candidate: String

            if cleanedText.count >= 20, isHighSignalSnippet(cleanedText) {
                candidate = cleanedText
            } else if cleanedWindow.count >= 20, cleanedWindow != snapshot.appName {
                candidate = cleanedWindow
            } else {
                continue
            }

            let dedupeKey = String(candidate.prefix(100))
            guard !seen.contains(dedupeKey) else { continue }
            seen.insert(dedupeKey)
            result.append((snapshot.timestamp, candidate))

            if result.count == 5 {
                break
            }
        }

        return result
    }

    private func mergeSessions(_ sessions: [SessionRow]) -> [SessionRow] {
        guard var current = sessions.first else { return [] }
        var merged: [SessionRow] = []

        for session in sessions.dropFirst() {
            let currentEnd = current.endedAt ?? current.startedAt
            let gap = session.startedAt.timeIntervalSince(currentEnd)
            if session.appName == current.appName,
               session.bundleID == current.bundleID,
               gap >= 0,
               gap <= mergeGapThreshold {
                current = SessionRow(
                    appName: current.appName,
                    bundleID: current.bundleID,
                    startedAt: current.startedAt,
                    endedAt: session.endedAt ?? session.startedAt,
                    activeDurationMs: current.activeDurationMs + session.activeDurationMs
                )
                continue
            }

            merged.append(current)
            current = session
        }

        merged.append(current)
        return merged
    }

    private func cleanSnippet(_ text: String) -> String {
        var cleaned = text
            .replacingOccurrences(of: "```markdown", with: " ")
            .replacingOccurrences(of: "```text", with: " ")
            .replacingOccurrences(of: "```json", with: " ")
            .replacingOccurrences(of: "```", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")

        cleaned = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if cleaned.count > 220 {
            cleaned = String(cleaned.prefix(220)) + "..."
        }

        return cleaned
    }

    private func isHighSignalSnippet(_ text: String) -> Bool {
        let scalarView = text.unicodeScalars
        let letterCount = scalarView.filter { CharacterSet.letters.contains($0) }.count
        let digitCount = scalarView.filter { CharacterSet.decimalDigits.contains($0) }.count
        let punctuationCount = scalarView.filter { CharacterSet.punctuationCharacters.contains($0) }.count
        let words = text
            .lowercased()
            .split(separator: " ")
            .map(String.init)
        let distinctWords = Set(words)

        guard letterCount >= 15 else {
            return false
        }

        guard distinctWords.count >= 8 else {
            return false
        }

        return letterCount >= digitCount && letterCount > punctuationCount / 2
    }

    private func cleanWindowTitle(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func parseISO(_ raw: String) -> Date? {
        if let exact = isoFormatter.date(from: raw) {
            return exact
        }

        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func formatDuration(_ milliseconds: Int64) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

func defaultDatabasePath() -> String {
    (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/MyMacAgent/mymacagent.db")
}

func defaultVaultPath() -> String {
    let defaults = UserDefaults(suiteName: "com.memograph.app")
    return defaults?.string(forKey: "obsidianVaultPath")
        ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents/MyMacAgentVault")
}

let dbPath = defaultDatabasePath()
let vaultPath = defaultVaultPath()
let generator = try BackfillReportGenerator(dbPath: dbPath, vaultPath: vaultPath)

guard let startDate = try generator.latestGeneratedAt() else {
    fputs("No previous summary found; cannot determine backfill start.\n", stderr)
    exit(1)
}

let reportPath = try generator.generate(from: startDate, to: Date())
print(reportPath)
