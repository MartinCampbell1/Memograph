import Foundation
import os

struct AudioTranscript {
    let id: String
    let sessionId: String?
    let timestamp: String
    let segmentStartedAt: String?
    let segmentEndedAt: String?
    let persistedAt: String?
    let durationSeconds: Double
    let text: String
    let language: String?
    let source: String?
}

final class AudioTranscriber: @unchecked Sendable {
    private struct QueuedTranscriptionPayload: Codable {
        let path: String
        let sessionId: String?
        let source: String
        let language: String?
        let segmentStartedAt: String
        let segmentEndedAt: String
    }

    private let db: DatabaseManager
    let venvPath: String
    private let scriptPath: String
    private let runtimeStatus: AudioRuntimeStatus
    private let logger = Logger.app
    private let dateSupport: LocalDateSupport
    private let now: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(db: DatabaseManager,
         venvPath: String = "",
         scriptPath: String = "",
         runtimeStatus: AudioRuntimeStatus? = nil,
         timeZone: TimeZone = .autoupdatingCurrent,
         now: @escaping () -> Date = Date.init) {
        self.db = db
        self.runtimeStatus = runtimeStatus ?? AudioRuntimeResolver.resolve()
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.now = now

        if venvPath.isEmpty {
            self.venvPath = FileManager.default.currentDirectoryPath + "/.venv"
        } else {
            self.venvPath = venvPath
        }

        if scriptPath.isEmpty {
            switch self.runtimeStatus {
            case .ready(let environment):
                self.scriptPath = environment.scriptPath
            case .missingPython, .missingScript:
                self.scriptPath = ""
            }
        } else {
            self.scriptPath = scriptPath
        }
    }

    func ensureTable() throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS audio_transcripts (
                id TEXT PRIMARY KEY,
                session_id TEXT,
                timestamp TEXT NOT NULL,
                segment_started_at TEXT,
                segment_ended_at TEXT,
                persisted_at TEXT,
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
        """)
        try ensureColumns()
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_audio_transcripts_timestamp
            ON audio_transcripts(timestamp)
        """)
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_audio_transcripts_segment_window
            ON audio_transcripts(segment_started_at, segment_ended_at)
        """)
    }

    func transcribeFile(audioPath: String, language: String? = nil) async throws -> AudioTranscript {
        let environment: AudioRuntimeEnvironment
        switch runtimeStatus {
        case .ready(let resolvedEnvironment):
            environment = resolvedEnvironment
        case .missingPython(let details):
            throw AudioError.pythonNotFound(details)
        case .missingScript(let details):
            throw AudioError.scriptNotFound(details)
        }

        var args = environment.launchArgumentsPrefix + [environment.scriptPath, audioPath]
        if let lang = language { args.append(lang) }

        let process = Process()
        process.executableURL = environment.executableURL
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["MEMOGRAPH_WHISPER_MODEL": environment.modelName]
        ) { _, newValue in newValue }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let json = try? JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
            throw AudioError.transcriptionFailed(stderr.isEmpty ? "Failed to parse whisper output" : stderr)
        }

        if let error = json["error"] as? String {
            throw AudioError.transcriptionFailed(error)
        }

        guard let text = json["text"] as? String else {
            throw AudioError.transcriptionFailed("Whisper output did not contain text")
        }

        let detectedLang = json["language"] as? String

        return AudioTranscript(
            id: UUID().uuidString,
            sessionId: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            segmentStartedAt: nil,
            segmentEndedAt: nil,
            persistedAt: nil,
            durationSeconds: 0,
            text: text,
            language: detectedLang ?? language,
            source: nil
        )
    }

    func persistTranscript(
        sessionId: String?,
        text: String,
        language: String?,
        durationSeconds: Double,
        source: String = "system",
        segmentStartedAt: Date? = nil,
        segmentEndedAt: Date? = nil,
        persistedAt: Date? = nil
    ) throws {
        try ensureTable()
        let id = UUID().uuidString
        let persistedDate = persistedAt ?? now()
        let persistedTimestamp = dateSupport.isoString(from: persistedDate)
        let startTimestamp = segmentStartedAt.map(dateSupport.isoString(from:)) ?? persistedTimestamp
        let endTimestamp = segmentEndedAt.map(dateSupport.isoString(from:)) ?? startTimestamp

        try db.execute("""
            INSERT INTO audio_transcripts (
                id, session_id, timestamp, segment_started_at, segment_ended_at, persisted_at,
                duration_seconds, transcript, language, source
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            sessionId.map { .text($0) } ?? .null,
            .text(startTimestamp),
            .text(startTimestamp),
            .text(endTimestamp),
            .text(persistedTimestamp),
            .real(durationSeconds),
            .text(text),
            language.map { .text($0) } ?? .null,
            .text(source)
        ])
    }

    func enqueueTranscriptionJob(
        path: String,
        sessionId: String?,
        source: String,
        language: String? = nil,
        segmentStartedAt: Date,
        segmentEndedAt: Date
    ) throws {
        try ensureTable()

        let payload = QueuedTranscriptionPayload(
            path: path,
            sessionId: sessionId,
            source: source,
            language: language,
            segmentStartedAt: dateSupport.isoString(from: segmentStartedAt),
            segmentEndedAt: dateSupport.isoString(from: segmentEndedAt)
        )
        let payloadData = try encoder.encode(payload)
        guard let payloadJson = String(data: payloadData, encoding: .utf8) else {
            throw DatabaseError.executeFailed("Failed to encode audio transcription payload")
        }

        let nowString = dateSupport.isoString(from: now())
        let existing = try db.query("""
            SELECT id
            FROM sync_queue
            WHERE job_type = ? AND entity_id = ?
              AND status IN ('pending', 'running', 'failed')
            ORDER BY id DESC
            LIMIT 1
        """, params: [.text("audio_transcription"), .text(path)])

        if let row = existing.first,
           let id = row["id"]?.intValue {
            try db.execute("""
                UPDATE sync_queue
                SET payload_json = ?, status = 'pending', retry_count = 0,
                    scheduled_at = ?, started_at = NULL, finished_at = NULL, last_error = NULL
                WHERE id = ?
            """, params: [
                .text(payloadJson),
                .text(nowString),
                .integer(id)
            ])
        } else {
            try db.execute("""
                INSERT INTO sync_queue (job_type, entity_id, payload_json, status, retry_count, scheduled_at)
                VALUES (?, ?, ?, 'pending', 0, ?)
            """, params: [
                .text("audio_transcription"),
                .text(path),
                .text(payloadJson),
                .text(nowString)
            ])
        }
    }

    @discardableResult
    func drainQueuedTranscriptions(limit: Int = 4) async throws -> Int {
        let nowDate = now()
        let nowString = dateSupport.isoString(from: nowDate)
        let rows = try db.query("""
            SELECT id, payload_json, retry_count
            FROM sync_queue
            WHERE job_type = ?
              AND status IN ('pending', 'failed')
              AND (scheduled_at IS NULL OR scheduled_at <= ?)
            ORDER BY id
            LIMIT ?
        """, params: [
            .text("audio_transcription"),
            .text(nowString),
            .integer(Int64(limit))
        ])

        var completed = 0
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
                    throw DatabaseError.executeFailed("Missing audio transcription payload")
                }

                let payload = try decoder.decode(QueuedTranscriptionPayload.self, from: payloadData)
                try await transcribeQueuedSegment(payload)

                try db.execute("""
                    UPDATE sync_queue
                    SET status = 'done', finished_at = ?, started_at = COALESCE(started_at, ?), last_error = NULL
                    WHERE id = ?
                """, params: [.text(nowString), .text(nowString), .integer(id)])
                completed += 1
            } catch {
                let nextRetry = dateSupport.isoString(
                    from: nowDate.addingTimeInterval(retryDelay(for: retryCount + 1))
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

        return completed
    }

    func getTranscriptsForDate(_ date: String) throws -> [AudioTranscript] {
        guard let range = dateSupport.utcRange(forLocalDate: date) else {
            return []
        }
        let rows = try db.query("""
            SELECT id, session_id, timestamp, segment_started_at, segment_ended_at, persisted_at,
                   duration_seconds, transcript, language, source
            FROM audio_transcripts
            WHERE COALESCE(segment_started_at, timestamp) < ?
              AND COALESCE(segment_ended_at, persisted_at, timestamp) >= ?
            ORDER BY COALESCE(segment_started_at, timestamp), timestamp
        """, params: [.text(range.end), .text(range.start)])

        return rows.compactMap { row -> AudioTranscript? in
            guard let id = row["id"]?.textValue,
                  let timestamp = row["timestamp"]?.textValue,
                  let text = row["transcript"]?.textValue else { return nil }
            return AudioTranscript(
                id: id,
                sessionId: row["session_id"]?.textValue,
                timestamp: timestamp,
                segmentStartedAt: row["segment_started_at"]?.textValue,
                segmentEndedAt: row["segment_ended_at"]?.textValue,
                persistedAt: row["persisted_at"]?.textValue,
                durationSeconds: row["duration_seconds"]?.realValue ?? 0,
                text: text,
                language: row["language"]?.textValue,
                source: row["source"]?.textValue
            )
        }
    }

    private func ensureColumns() throws {
        let rows = try db.query("PRAGMA table_info(audio_transcripts)")
        let existingColumns = Set(rows.compactMap { $0["name"]?.textValue })

        if !existingColumns.contains("segment_started_at") {
            try db.execute("ALTER TABLE audio_transcripts ADD COLUMN segment_started_at TEXT")
        }
        if !existingColumns.contains("segment_ended_at") {
            try db.execute("ALTER TABLE audio_transcripts ADD COLUMN segment_ended_at TEXT")
        }
        if !existingColumns.contains("persisted_at") {
            try db.execute("ALTER TABLE audio_transcripts ADD COLUMN persisted_at TEXT")
        }

        try db.execute("""
            UPDATE audio_transcripts
            SET segment_started_at = COALESCE(segment_started_at, timestamp),
                segment_ended_at = COALESCE(
                    segment_ended_at,
                    CASE
                        WHEN duration_seconds > 0 THEN datetime(timestamp, '+' || CAST(duration_seconds AS INTEGER) || ' seconds')
                        ELSE timestamp
                    END
                ),
                persisted_at = COALESCE(persisted_at, timestamp)
        """)
    }

    private func transcribeQueuedSegment(_ payload: QueuedTranscriptionPayload) async throws {
        guard FileManager.default.fileExists(atPath: payload.path) else {
            throw AudioError.transcriptionFailed("Queued audio segment missing at \(payload.path)")
        }

        let result = try await transcribeFile(audioPath: payload.path, language: payload.language)
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let segmentStart = dateSupport.parseDateTime(payload.segmentStartedAt) ?? now()
        let segmentEnd = dateSupport.parseDateTime(payload.segmentEndedAt) ?? segmentStart
        let durationSeconds = max(
            result.durationSeconds,
            max(0, segmentEnd.timeIntervalSince(segmentStart))
        )

        if !text.isEmpty {
            try persistTranscript(
                sessionId: payload.sessionId,
                text: text,
                language: result.language ?? payload.language,
                durationSeconds: durationSeconds,
                source: payload.source,
                segmentStartedAt: segmentStart,
                segmentEndedAt: segmentEnd,
                persistedAt: now()
            )
        }

        try? FileManager.default.removeItem(atPath: payload.path)
    }

    private func retryDelay(for retryCount: Int) -> TimeInterval {
        let boundedRetryCount = min(max(retryCount, 1), 6)
        return Double(1 << boundedRetryCount) * 60
    }
}

enum AudioError: Error, LocalizedError {
    case pythonNotFound(String)
    case scriptNotFound(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonNotFound(let p): return "Python runtime not found: \(p)"
        case .scriptNotFound(let p): return "Whisper script not found at \(p)"
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        }
    }
}
