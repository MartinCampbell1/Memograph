import Foundation
import os

struct SessionData {
    let sessionId: String
    let appName: String
    let bundleId: String
    let windowTitles: [String]
    let startedAt: String
    let endedAt: String?
    let durationMs: Int64
    let uncertaintyMode: String
    let contextTexts: [String]
}

struct ParsedSummary {
    let summaryText: String
    let topics: [String]
    let suggestedNotes: [String]
    let continueTomorrow: String?
}

final class DailySummarizer: @unchecked Sendable {
    private let db: DatabaseManager
    nonisolated(unsafe) private let logger = Logger.summary

    init(db: DatabaseManager) {
        self.db = db
    }

    func collectSessionData(for date: String) throws -> [SessionData] {
        let sessions = try db.query("""
            SELECT s.id, s.started_at, s.ended_at, s.active_duration_ms,
                   s.uncertainty_mode, a.app_name, a.bundle_id
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at LIKE ?
            ORDER BY s.started_at
        """, params: [.text("\(date)%")])

        return try sessions.compactMap { row -> SessionData? in
            guard let sessionId = row["id"]?.textValue,
                  let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue,
                  let startedAt = row["started_at"]?.textValue else { return nil }

            let contexts = try db.query("""
                SELECT window_title, merged_text FROM context_snapshots
                WHERE session_id = ? ORDER BY timestamp
            """, params: [.text(sessionId)])

            let windowTitles = contexts.compactMap { $0["window_title"]?.textValue }
            let contextTexts = contexts.compactMap { $0["merged_text"]?.textValue }

            return SessionData(
                sessionId: sessionId,
                appName: appName, bundleId: bundleId,
                windowTitles: Array(Set(windowTitles)),
                startedAt: startedAt,
                endedAt: row["ended_at"]?.textValue,
                durationMs: row["active_duration_ms"]?.intValue ?? 0,
                uncertaintyMode: row["uncertainty_mode"]?.textValue ?? "normal",
                contextTexts: contextTexts
            )
        }
    }

    func buildDailyPrompt(for date: String) throws -> String {
        let sessions = try collectSessionData(for: date)

        var prompt = "Generate a daily activity summary for \(date).\n\n"
        prompt += "## Sessions\n\n"

        for session in sessions {
            let durationMin = session.durationMs / 60000
            prompt += "### \(session.appName) (\(durationMin) min)\n"
            prompt += "Time: \(session.startedAt) — \(session.endedAt ?? "ongoing")\n"
            if !session.windowTitles.isEmpty {
                prompt += "Windows: \(session.windowTitles.joined(separator: ", "))\n"
            }
            if session.uncertaintyMode != "normal" {
                prompt += "Note: content was \(session.uncertaintyMode) (visual tracking)\n"
            }
            let textPreview = session.contextTexts
                .prefix(3)
                .map { String($0.prefix(200)) }
                .joined(separator: "\n")
            if !textPreview.isEmpty {
                prompt += "Content preview:\n\(textPreview)\n"
            }
            prompt += "\n"
        }

        prompt += """
        Respond with these sections exactly:

        ## Summary
        (1-3 sentence summary of the day)

        ## Main topics
        (bullet list of main topics/activities)

        ## Suggested notes
        (bullet list of [[wiki-link]] notes worth creating)

        ## Continue tomorrow
        (what to continue working on)
        """

        return prompt
    }

    func summarize(for date: String, using client: LLMClient) async throws -> DailySummaryRecord {
        let prompt = try buildDailyPrompt(for: date)

        let systemPrompt = """
        You are a personal productivity assistant. Analyze the user's computer activity
        and produce a concise, insightful daily summary. Focus on what they accomplished,
        what topics they explored, and what they should continue tomorrow. Be specific
        about the actual content they worked on based on window titles and text excerpts.
        """

        logger.info("Generating daily summary for \(date)")

        let response = try await client.complete(
            systemPrompt: systemPrompt,
            userPrompt: prompt
        )

        let parsed = Self.parseSummaryResponse(response.content)
        let now = ISO8601DateFormatter().string(from: Date())

        let topicsJson = try? String(
            data: JSONSerialization.data(withJSONObject: parsed.topics),
            encoding: .utf8
        )
        let notesJson = try? String(
            data: JSONSerialization.data(withJSONObject: parsed.suggestedNotes),
            encoding: .utf8
        )

        // Collect app durations
        let sessions = try collectSessionData(for: date)
        let appDurations = Dictionary(grouping: sessions, by: \.appName)
            .mapValues { $0.reduce(0) { $0 + $1.durationMs } / 60000 }
            .sorted { $0.value > $1.value }
            .map { ["name": $0.key, "duration_min": $0.value] as [String: Any] }
        let appsJson = try? String(
            data: JSONSerialization.data(withJSONObject: appDurations),
            encoding: .utf8
        )

        let summary = DailySummaryRecord(
            date: date,
            summaryText: parsed.summaryText,
            topAppsJson: appsJson,
            topTopicsJson: topicsJson,
            aiSessionsJson: nil,
            contextSwitchesJson: "{\"count\":\(sessions.count)}",
            unfinishedItemsJson: parsed.continueTomorrow.map { "{\"items\":[\"\($0)\"]}" },
            suggestedNotesJson: notesJson,
            generatedAt: now,
            modelName: client.model,
            tokenUsageInput: response.promptTokens,
            tokenUsageOutput: response.completionTokens,
            generationStatus: "success"
        )

        try persistSummary(summary)
        logger.info("Daily summary saved for \(date)")

        return summary
    }

    func persistSummary(_ summary: DailySummaryRecord) throws {
        try db.execute("""
            INSERT OR REPLACE INTO daily_summaries
                (date, summary_text, top_apps_json, top_topics_json,
                 ai_sessions_json, context_switches_json, unfinished_items_json,
                 suggested_notes_json, generated_at, model_name,
                 token_usage_input, token_usage_output, generation_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(summary.date),
            summary.summaryText.map { .text($0) } ?? .null,
            summary.topAppsJson.map { .text($0) } ?? .null,
            summary.topTopicsJson.map { .text($0) } ?? .null,
            summary.aiSessionsJson.map { .text($0) } ?? .null,
            summary.contextSwitchesJson.map { .text($0) } ?? .null,
            summary.unfinishedItemsJson.map { .text($0) } ?? .null,
            summary.suggestedNotesJson.map { .text($0) } ?? .null,
            summary.generatedAt.map { .text($0) } ?? .null,
            summary.modelName.map { .text($0) } ?? .null,
            .integer(Int64(summary.tokenUsageInput)),
            .integer(Int64(summary.tokenUsageOutput)),
            summary.generationStatus.map { .text($0) } ?? .null
        ])
    }

    static func parseSummaryResponse(_ text: String) -> ParsedSummary {
        let sections = text.components(separatedBy: "## ")

        var summaryText = ""
        var topics: [String] = []
        var suggestedNotes: [String] = []
        var continueTomorrow: String?

        for section in sections {
            let lines = section.trimmingCharacters(in: .whitespacesAndNewlines)
            if lines.hasPrefix("Summary") {
                summaryText = lines.replacingOccurrences(of: "Summary\n", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else if lines.hasPrefix("Main topics") {
                topics = lines.split(separator: "\n")
                    .dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
                    .filter { !$0.isEmpty }
            } else if lines.hasPrefix("Suggested notes") {
                suggestedNotes = lines.split(separator: "\n")
                    .dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
                    .map { $0.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "") }
                    .filter { !$0.isEmpty }
            } else if lines.hasPrefix("Continue tomorrow") {
                continueTomorrow = lines.replacingOccurrences(of: "Continue tomorrow\n", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return ParsedSummary(
            summaryText: summaryText,
            topics: topics,
            suggestedNotes: suggestedNotes,
            continueTomorrow: continueTomorrow
        )
    }
}
