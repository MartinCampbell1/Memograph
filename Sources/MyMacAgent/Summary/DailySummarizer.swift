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
    private let logger = Logger.summary
    private let dateSupport: LocalDateSupport
    private let now: () -> Date

    /// Max total characters for all context text in prompt (~4 chars per token)
    private var maxPromptChars: Int { AppSettings().maxPromptChars }

    init(
        db: DatabaseManager,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.now = now
    }

    func collectSessionData(for date: String) throws -> [SessionData] {
        guard let range = dateSupport.utcRange(forLocalDate: date) else {
            logger.error("Invalid local date requested for summarizer: \(date)")
            return []
        }
        let sessions = try db.query("""
            SELECT s.id, s.started_at, s.ended_at, s.active_duration_ms,
                   s.uncertainty_mode, a.app_name, a.bundle_id
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at >= ? AND s.started_at < ?
            ORDER BY s.started_at
        """, params: [.text(range.start), .text(range.end)])

        return try sessions.compactMap { row -> SessionData? in
            guard let sessionId = row["id"]?.textValue,
                  let appName = row["app_name"]?.textValue,
                  let bundleId = row["bundle_id"]?.textValue,
                  let startedAt = row["started_at"]?.textValue else { return nil }

            // Get ALL context text — full OCR + AX merged text, not truncated
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
                durationMs: dateSupport.effectiveDurationMs(
                    startedAt: startedAt,
                    endedAt: row["ended_at"]?.textValue,
                    storedActiveDurationMs: row["active_duration_ms"]?.intValue ?? 0,
                    now: now()
                ),
                uncertaintyMode: row["uncertainty_mode"]?.textValue ?? "normal",
                contextTexts: contextTexts
            )
        }
    }

    /// Load the previous summary for compressed memory (so the model knows what happened before)
    func loadPreviousSummary(before date: String) throws -> String? {
        let rows = try db.query("""
            SELECT date, summary_text, top_topics_json, suggested_notes_json
            FROM daily_summaries
            WHERE date < ?
            ORDER BY date DESC
            LIMIT 1
        """, params: [.text(date)])

        guard let row = rows.first,
              let prevDate = row["date"]?.textValue else { return nil }

        var memory = "Previous day (\(prevDate)):\n"
        if let summary = row["summary_text"]?.textValue {
            memory += summary + "\n"
        }
        if let topics = row["top_topics_json"]?.textValue {
            memory += "Topics: \(topics)\n"
        }
        if let notes = row["suggested_notes_json"]?.textValue {
            memory += "Notes suggested: \(notes)\n"
        }
        return memory
    }

    /// Load the current day's earlier summary (for hourly updates — build on previous hour)
    func loadCurrentDaySummary(for date: String) throws -> String? {
        let rows = try db.query("""
            SELECT summary_text, top_topics_json, generated_at
            FROM daily_summaries
            WHERE date = ?
        """, params: [.text(date)])

        guard let row = rows.first,
              let summary = row["summary_text"]?.textValue else { return nil }

        let generatedAt = row["generated_at"]?.textValue ?? "unknown"
        return "Earlier summary today (generated at \(generatedAt)):\n\(summary)"
    }

    func buildDailyPrompt(for date: String) throws -> String {
        let sessions = try collectSessionData(for: date)

        var prompt = ""

        // 1. Compressed memory — previous day + earlier today
        if let prevDay = try loadPreviousSummary(before: date) {
            prompt += "## Previous context (compressed memory)\n\(prevDay)\n\n"
        }
        if let earlierToday = try loadCurrentDaySummary(for: date) {
            prompt += "## Earlier today\n\(earlierToday)\n\n"
        }

        // 2. Today's sessions with FULL text
        prompt += "## Today's sessions (\(date))\n\n"

        var totalChars = prompt.count
        let charBudgetPerSession = max(1000, (maxPromptChars - totalChars) / max(sessions.count, 1))

        for session in sessions {
            let durationMin = session.durationMs / 60000
            prompt += "### \(session.appName) (\(durationMin) min)\n"
            prompt += "Time: \(dateSupport.localTimeString(from: session.startedAt)) — "
            prompt += "\(session.endedAt.map { dateSupport.localTimeString(from: $0) } ?? "ongoing")\n"

            if !session.windowTitles.isEmpty {
                prompt += "Windows: \(session.windowTitles.joined(separator: ", "))\n"
            }

            if session.uncertaintyMode != "normal" {
                prompt += "Note: content was \(session.uncertaintyMode) (visual tracking, OCR may be incomplete)\n"
            }

            // Full context text — deduplicated, with smart budget
            if !session.contextTexts.isEmpty {
                prompt += "Content:\n"
                let deduped = deduplicateTexts(session.contextTexts)
                var sessionChars = 0
                for text in deduped {
                    if sessionChars + text.count > charBudgetPerSession {
                        let remaining = charBudgetPerSession - sessionChars
                        if remaining > 100 {
                            prompt += String(text.prefix(remaining)) + "...[truncated]\n"
                        }
                        break
                    }
                    prompt += text + "\n"
                    sessionChars += text.count
                }
            }

            prompt += "\n"
            totalChars = prompt.count
        }

        // 2.5 Audio transcripts
        let audioTranscriber = AudioTranscriber(db: db, timeZone: dateSupport.timeZone, now: now)
        if let transcripts = try? audioTranscriber.getTranscriptsForDate(date), !transcripts.isEmpty {
            prompt += "## Audio Transcripts\n\n"
            for transcript in transcripts {
                let time = dateSupport.localDateTimeString(from: transcript.timestamp)
                let lang = transcript.language ?? "?"
                prompt += "[\(time)] (\(lang)): \(transcript.text)\n"
            }
            prompt += "\n"
        }

        // 2.6 Vision analysis of unreadable screenshots
        guard let range = dateSupport.utcRange(forLocalDate: date) else {
            return prompt + "\n---\n" + AppSettings().userPromptSuffix
        }
        let visionSnapshots = try db.query("""
            SELECT timestamp, app_name, window_title, merged_text
            FROM context_snapshots
            WHERE timestamp >= ? AND timestamp < ?
              AND text_source = 'vision' AND merged_text IS NOT NULL
            ORDER BY timestamp
        """, params: [.text(range.start), .text(range.end)])

        if !visionSnapshots.isEmpty {
            prompt += "## Vision Analysis (screenshots that couldn't be OCR'd)\n\n"
            for row in visionSnapshots {
                let time = row["timestamp"]?.textValue.map { dateSupport.localDateTimeString(from: $0) } ?? ""
                let app = row["app_name"]?.textValue ?? ""
                let text = row["merged_text"]?.textValue ?? ""
                prompt += "[\(time)] \(app): \(text)\n"
            }
            prompt += "\n"
        }

        // 3. Instructions (user-editable via Settings → Prompts)
        prompt += "\n---\n" + AppSettings().userPromptSuffix

        return prompt
    }

    func summarize(for date: String, using client: LLMClient) async throws -> DailySummaryRecord {
        let prompt = try buildDailyPrompt(for: date)

        // System prompt from Settings (user-editable)
        let systemPrompt = AppSettings().systemPrompt

        logger.info("Generating daily summary for \(date), prompt length: \(prompt.count) chars")

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
        logger.info("Daily summary saved for \(date), tokens: \(response.promptTokens)+\(response.completionTokens)")

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
                topics = extractBullets(from: lines)
            } else if lines.hasPrefix("Suggested notes") {
                suggestedNotes = extractBullets(from: lines)
                    .map { $0.replacingOccurrences(of: "[[", with: "")
                           .replacingOccurrences(of: "]]", with: "") }
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

    // MARK: - Private

    /// Remove near-duplicate texts (same content captured multiple times)
    private func deduplicateTexts(_ texts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for text in texts {
            // Use first 100 chars as dedup key
            let key = String(text.prefix(100))
            if !seen.contains(key) {
                seen.insert(key)
                result.append(text)
            }
        }
        return result
    }

    private static func extractBullets(from section: String) -> [String] {
        section.split(separator: "\n")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : String($0) }
            .filter { !$0.isEmpty }
    }
}
