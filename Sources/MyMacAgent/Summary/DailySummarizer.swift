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

struct SessionEventData {
    let timestamp: String
    let eventType: String
    let payloadJson: String?
}

struct ParsedSummary {
    let summaryText: String
    let topics: [String]
    let suggestedNotes: [String]
    let continueTomorrow: String?
}

struct SummaryWindowDescriptor {
    let date: String
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }
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

    func sessionCount(for date: String) throws -> Int {
        guard let range = dateSupport.utcRange(forLocalDate: date) else {
            return 0
        }

        let rows = try db.query("""
            SELECT COUNT(*) as count
            FROM sessions
            WHERE started_at >= ? AND started_at < ?
        """, params: [.text(range.start), .text(range.end)])

        return rows.first?["count"]?.intValue.flatMap(Int.init) ?? 0
    }

    func summaryRecord(for date: String) throws -> DailySummaryRecord? {
        let rows = try db.query("""
            SELECT *
            FROM daily_summaries
            WHERE date = ?
            LIMIT 1
        """, params: [.text(date)])

        guard let row = rows.first else { return nil }
        return DailySummaryRecord(row: row)
    }

    func summaryWindow(for date: String) throws -> SummaryWindowDescriptor? {
        guard let startOfDay = dateSupport.startOfLocalDay(for: date) else {
            return nil
        }

        let currentLocalDate = dateSupport.currentLocalDateString(now: now())
        if date != currentLocalDate {
            guard let endOfDay = dateSupport.endOfLocalDay(for: date) else {
                return nil
            }
            return SummaryWindowDescriptor(date: date, start: startOfDay, end: endOfDay)
        }

        let previousGeneratedAt = try summaryRecord(for: date)?
            .generatedAt
            .flatMap(dateSupport.parseDateTime)

        let windowStart = max(previousGeneratedAt ?? startOfDay, startOfDay)
        return SummaryWindowDescriptor(date: date, start: windowStart, end: now())
    }

    func summaryWindow(for date: String, start: Date, end: Date) -> SummaryWindowDescriptor {
        SummaryWindowDescriptor(date: date, start: start, end: end)
    }

    func shouldGenerateSummary(
        for date: String,
        currentLocalDate: String,
        minimumIntervalMinutes: Int
    ) throws -> Bool {
        let existingSummary = try summaryRecord(for: date)
        let sessionCount = try sessionCount(for: date)

        guard let existingSummary else {
            return true
        }

        if date != currentLocalDate {
            return false
        }

        if sessionCount == 0 {
            return false
        }

        guard let generatedAt = existingSummary.generatedAt,
              let generatedDate = dateSupport.parseDateTime(generatedAt) else {
            return true
        }

        let minimumInterval = max(15, minimumIntervalMinutes)
        let elapsed = now().timeIntervalSince(generatedDate)
        return elapsed >= Double(minimumInterval * 60)
    }

    func collectSessionData(for date: String) throws -> [SessionData] {
        guard let window = try summaryWindow(for: date) else {
            logger.error("Invalid summary window requested for \(date)")
            return []
        }
        return try collectSessionData(for: window)
    }

    func collectSessionData(for window: SummaryWindowDescriptor) throws -> [SessionData] {
        let rangeStart = dateSupport.isoString(from: window.start)
        let rangeEnd = dateSupport.isoString(from: window.end)
        let sessions = try db.query("""
            SELECT s.id, s.started_at, s.ended_at, s.active_duration_ms,
                   s.uncertainty_mode, a.app_name, a.bundle_id
            FROM sessions s
            JOIN apps a ON s.app_id = a.id
            WHERE s.started_at < ? AND COALESCE(s.ended_at, s.started_at) >= ?
            ORDER BY s.started_at
        """, params: [.text(rangeEnd), .text(rangeStart)])

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

    func collectSessionEvents(for window: SummaryWindowDescriptor) throws -> [SessionEventData] {
        let rangeStart = dateSupport.isoString(from: window.start)
        let rangeEnd = dateSupport.isoString(from: window.end)

        let rows = try db.query("""
            SELECT timestamp, event_type, payload_json
            FROM session_events
            WHERE timestamp >= ? AND timestamp < ?
              AND event_type IN ('app_activated', 'window_changed', 'idle_started', 'idle_ended')
            ORDER BY timestamp
        """, params: [.text(rangeStart), .text(rangeEnd)])

        return rows.compactMap { row in
            guard let timestamp = row["timestamp"]?.textValue,
                  let eventType = row["event_type"]?.textValue else {
                return nil
            }
            return SessionEventData(
                timestamp: timestamp,
                eventType: eventType,
                payloadJson: row["payload_json"]?.textValue
            )
        }
    }

    func buildDailyPrompt(for date: String) throws -> String {
        guard let window = try summaryWindow(for: date) else {
            return "\n---\n" + AppSettings().userPromptSuffix
        }
        return try buildPrompt(for: window)
    }

    func buildPrompt(for window: SummaryWindowDescriptor) throws -> String {
        let sessions = try collectSessionData(for: window)
        let events = try collectSessionEvents(for: window)

        var prompt = ""

        // 1. Compressed memory — previous day + earlier today
        if let prevDay = try loadPreviousSummary(before: window.date) {
            prompt += "## Previous context (compressed memory)\n\(prevDay)\n\n"
        }
        if let earlierToday = try loadCurrentDaySummary(for: window.date),
           window.duration < 23 * 3600 {
            prompt += "## Earlier today\n\(earlierToday)\n\n"
        }

        prompt += "## Report window\n"
        prompt += "Local date: \(window.date)\n"
        prompt += "Cover ONLY this window: \(dateSupport.localDateTimeString(from: window.start)) — "
        prompt += "\(dateSupport.localDateTimeString(from: window.end)) (\(dateSupport.timeZone.identifier))\n"
        prompt += "If this is an hourly update, focus on new work in this window and only reference earlier work for continuity.\n\n"

        // 2. Sessions with FULL text
        prompt += "## Sessions in this window\n\n"

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

        if !events.isEmpty {
            prompt += "## Session events\n"
            for event in events {
                let payload = event.payloadJson?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                prompt += "[\(dateSupport.localDateTimeString(from: event.timestamp))] \(event.eventType)"
                if !payload.isEmpty {
                    prompt += ": \(payload)"
                }
                prompt += "\n"
            }
            prompt += "\n"
        }

        // 2.5 Audio transcripts
        let audioTranscriber = AudioTranscriber(db: db, timeZone: dateSupport.timeZone, now: now)
        if let transcripts = try? audioTranscriber.getTranscriptsForDate(window.date), !transcripts.isEmpty {
            prompt += "## Audio Transcripts\n\n"
            for transcript in transcripts {
                guard let transcriptDate = dateSupport.parseDateTime(transcript.timestamp),
                      transcriptDate >= window.start,
                      transcriptDate < window.end else {
                    continue
                }
                let time = dateSupport.localDateTimeString(from: transcript.timestamp)
                let lang = transcript.language ?? "?"
                prompt += "[\(time)] (\(lang)): \(transcript.text)\n"
            }
            prompt += "\n"
        }

        // 2.6 Vision analysis of unreadable screenshots
        let rangeStart = dateSupport.isoString(from: window.start)
        let rangeEnd = dateSupport.isoString(from: window.end)
        guard !rangeStart.isEmpty, !rangeEnd.isEmpty else {
            return prompt + "\n---\n" + AppSettings().userPromptSuffix
        }
        let visionSnapshots = try db.query("""
            SELECT timestamp, app_name, window_title, merged_text
            FROM context_snapshots
            WHERE timestamp >= ? AND timestamp < ?
              AND text_source = 'vision' AND merged_text IS NOT NULL
            ORDER BY timestamp
        """, params: [.text(rangeStart), .text(rangeEnd)])

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

    func summarize(for date: String, using client: LLMClient, persist: Bool = true) async throws -> DailySummaryRecord {
        guard let window = try summaryWindow(for: date) else {
            throw LLMError.parseError("Failed to derive summary window")
        }
        return try await summarize(for: window, using: client, persist: persist)
    }

    func summarize(for window: SummaryWindowDescriptor, using client: LLMClient, persist: Bool = true) async throws -> DailySummaryRecord {
        let prompt = try buildPrompt(for: window)

        // System prompt from Settings (user-editable)
        let systemPrompt = AppSettings().systemPrompt

        logger.info("Generating summary for \(window.date) [\(self.dateSupport.localTimeString(from: window.start))-\(self.dateSupport.localTimeString(from: window.end))], prompt length: \(prompt.count) chars")

        let response = try await client.complete(
            systemPrompt: systemPrompt,
            userPrompt: prompt
        )

        let parsed = Self.parseSummaryResponse(response.content)
        let summaryText = Self.shouldPreserveRichMarkdown(response.content)
            ? response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            : (parsed.summaryText.isEmpty
                ? response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                : parsed.summaryText)
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
        let sessions = try collectSessionData(for: window)
        let appDurations = Dictionary(grouping: sessions, by: \.appName)
            .mapValues { $0.reduce(0) { $0 + $1.durationMs } / 60000 }
            .sorted { $0.value > $1.value }
            .map { ["name": $0.key, "duration_min": $0.value] as [String: Any] }
        let appsJson = try? String(
            data: JSONSerialization.data(withJSONObject: appDurations),
            encoding: .utf8
        )

        let summary = DailySummaryRecord(
            date: window.date,
            summaryText: summaryText,
            topAppsJson: appsJson,
            topTopicsJson: topicsJson,
            aiSessionsJson: nil,
            contextSwitchesJson: summaryWindowMetadataJson(window: window, sessionCount: sessions.count),
            unfinishedItemsJson: parsed.continueTomorrow.map { "{\"items\":[\"\($0)\"]}" },
            suggestedNotesJson: notesJson,
            generatedAt: now,
            modelName: client.model,
            tokenUsageInput: response.promptTokens,
            tokenUsageOutput: response.completionTokens,
            generationStatus: "success"
        )

        if persist {
            try persistSummary(summary)
            logger.info("Summary saved for \(window.date), tokens: \(response.promptTokens)+\(response.completionTokens)")
        }

        return summary
    }

    func buildFallbackSummary(for date: String, failureReason: String? = nil, persist: Bool = true) throws -> DailySummaryRecord {
        guard let window = try summaryWindow(for: date) else {
            throw DatabaseError.executeFailed("Failed to derive summary window")
        }
        return try buildFallbackSummary(for: window, failureReason: failureReason, persist: persist)
    }

    func buildFallbackSummary(for window: SummaryWindowDescriptor, failureReason: String? = nil, persist: Bool = true) throws -> DailySummaryRecord {
        let sessions = try collectSessionData(for: window)
        let totalMinutes = sessions.reduce(0) { $0 + Int($1.durationMs / 60000) }
        let distinctApps = Array(Set(sessions.map(\.appName))).sorted()
        let appDurations = Dictionary(grouping: sessions, by: \.appName)
            .mapValues { $0.reduce(0) { $0 + Int($1.durationMs / 60000) } }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
        let appDurationPayload = appDurations.map { ["name": $0.key, "duration_min": $0.value] as [String: Any] }

        let topAppSummary = appDurations
            .prefix(3)
            .map { "\($0.key) (\($0.value)m)" }
            .joined(separator: ", ")

        let summaryText: String
        if sessions.isEmpty {
            summaryText = """
            No recorded activity for \(window.date) in the window \(dateSupport.localTimeString(from: window.start))–\(dateSupport.localTimeString(from: window.end)). Memograph generated a local fallback report because the configured summary provider did not return a usable result.
            """
        } else {
            let reasonSuffix: String
            if let failureReason,
               !failureReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reasonSuffix = " External summarization failed, so this note was generated locally. Reason: \(failureReason)"
            } else {
                reasonSuffix = " External summarization failed, so this note was generated locally."
            }

            summaryText = """
            Recorded \(sessions.count) sessions across \(distinctApps.count) apps for about \(totalMinutes) active minutes on \(window.date) in the window \(dateSupport.localTimeString(from: window.start))–\(dateSupport.localTimeString(from: window.end)). Main apps: \(topAppSummary.isEmpty ? "none" : topAppSummary).\(reasonSuffix)
            """
        }

        let topics = Array(distinctApps.prefix(8))
        let suggestedNotes = Array(appDurations.prefix(5).map(\.key))
        let nowString = ISO8601DateFormatter().string(from: now())

        let summary = DailySummaryRecord(
            date: window.date,
            summaryText: summaryText,
            topAppsJson: jsonString(appDurationPayload),
            topTopicsJson: jsonString(topics),
            aiSessionsJson: nil,
            contextSwitchesJson: summaryWindowMetadataJson(window: window, sessionCount: sessions.count),
            unfinishedItemsJson: nil,
            suggestedNotesJson: jsonString(suggestedNotes),
            generatedAt: nowString,
            modelName: "local-fallback",
            tokenUsageInput: 0,
            tokenUsageOutput: 0,
            generationStatus: "fallback"
        )

        if persist {
            try persistSummary(summary)
            logger.info("Fallback summary saved for \(window.date)")
        }
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
            } else if lines.hasPrefix("Suggested notes")
                        || lines.hasPrefix("Предлагаемые заметки") {
                suggestedNotes = extractBullets(from: lines)
                    .map { $0.replacingOccurrences(of: "[[", with: "")
                           .replacingOccurrences(of: "]]", with: "") }
            } else if lines.hasPrefix("Continue tomorrow")
                        || lines.hasPrefix("Продолжить завтра")
                        || lines.hasPrefix("Продолжить далее") {
                continueTomorrow = lines
                    .replacingOccurrences(of: "Continue tomorrow\n", with: "")
                    .replacingOccurrences(of: "Продолжить завтра\n", with: "")
                    .replacingOccurrences(of: "Продолжить далее\n", with: "")
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

    private static func shouldPreserveRichMarkdown(_ text: String) -> Bool {
        let headers = [
            "## Детальный таймлайн",
            "## Проекты и код",
            "## Инструменты и технологии",
            "## Что изучал / читал",
            "## AI-взаимодействие",
            "## Граф связей",
            "## Предлагаемые заметки",
            "## Продолжить далее",
            "## Продолжить завтра"
        ]

        let matchCount = headers.reduce(into: 0) { count, header in
            if text.contains(header) {
                count += 1
            }
        }

        return matchCount >= 2
    }

    private func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func summaryWindowMetadataJson(window: SummaryWindowDescriptor, sessionCount: Int) -> String? {
        jsonString([
            "count": sessionCount,
            "window_start": dateSupport.isoString(from: window.start),
            "window_end": dateSupport.isoString(from: window.end),
            "window_start_local": dateSupport.localDateTimeString(from: window.start),
            "window_end_local": dateSupport.localDateTimeString(from: window.end),
            "mode": window.duration < 23 * 3600 ? "hourly" : "daily"
        ])
    }
}
