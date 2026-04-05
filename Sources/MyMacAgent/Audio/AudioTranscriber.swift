import AVFoundation
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
    typealias UploadTransport = @Sendable (URLRequest, URL) async throws -> (Data, URLResponse)

    private final class LegacyExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(session: AVAssetExportSession) {
            self.session = session
        }
    }

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
    private let runtimeStatusOverride: AudioRuntimeStatus?
    private let logger = Logger.app
    private let dateSupport: LocalDateSupport
    private let now: () -> Date
    private let settingsProvider: @Sendable () -> AppSettings
    private let uploadTransport: UploadTransport
    private let healthMonitor: AudioHealthMonitor
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let drainStateQueue = DispatchQueue(label: "com.memograph.audio-transcriber.drain-state")
    private var isDrainingQueue = false
    private let telemetryQueue = DispatchQueue(label: "com.memograph.audio-transcriber.telemetry")
    private var lastUploadSizeBytes: Int64?
    private var lastTranscriptionLatencyMs: Int?
    private var lastRetryCount: Int = 0
    private var networkFailureCount: Int = 0
    private var consecutiveCloudFailures: Int = 0
    private var recentCloudFailureDates: [Date] = []
    private var currentRunningSource: String?
    private var currentRunningJob: String?
    private var systemAudioThrottled = false
    private var systemAudioThrottleReason: String?
    private var systemAudioThrottleUntil = Date.distantPast
    private var lastErrorDescription: String?

    init(db: DatabaseManager,
         venvPath: String = "",
         scriptPath: String = "",
         runtimeStatus: AudioRuntimeStatus? = nil,
         timeZone: TimeZone = .autoupdatingCurrent,
         settingsProvider: @escaping @Sendable () -> AppSettings = { AppSettings() },
         uploadTransport: UploadTransport? = nil,
         healthMonitor: AudioHealthMonitor = .shared,
         now: @escaping () -> Date = Date.init) {
        self.db = db
        self.runtimeStatusOverride = runtimeStatus
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.settingsProvider = settingsProvider
        self.uploadTransport = uploadTransport ?? { request, fileURL in
            try await Self.uploadRequest(request, fromFile: fileURL)
        }
        self.healthMonitor = healthMonitor
        self.now = now

        if venvPath.isEmpty {
            self.venvPath = FileManager.default.currentDirectoryPath + "/.venv"
        } else {
            self.venvPath = venvPath
        }

        if scriptPath.isEmpty {
            switch runtimeStatus ?? AudioRuntimeResolver.resolve(settings: settingsProvider()) {
            case .ready(let environment):
                self.scriptPath = environment.scriptPath
            case .cloudReady, .missingAPIKey, .missingPython, .missingScript:
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
        try db.execute("""
            CREATE INDEX IF NOT EXISTS idx_sync_queue_audio_entity
            ON sync_queue(job_type, entity_id)
        """)
        publishHealthSnapshot()
    }

    func transcribeFile(audioPath: String, language: String? = nil, source: String? = nil) async throws -> AudioTranscript {
        let settings = settingsProvider()
        let runtimeStatus = runtimeStatusOverride ?? AudioRuntimeResolver.resolve(settings: settings)

        switch runtimeStatus {
        case .cloudReady(let environment):
            return try await transcribeViaCloud(
                audioPath: audioPath,
                language: language,
                source: source,
                environment: environment
            )

        case .ready(let resolvedEnvironment):
            return try await transcribeViaLocalWhisper(
                audioPath: audioPath,
                language: language,
                environment: resolvedEnvironment
            )

        case .missingAPIKey(let details):
            throw AudioError.missingAPIKey(details)
        case .missingPython(let details):
            throw AudioError.pythonNotFound(details)
        case .missingScript(let details):
            throw AudioError.scriptNotFound(details)
        }
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
        let entityID = makeQueueEntityID(
            path: path,
            source: source,
            segmentStartedAt: payload.segmentStartedAt,
            segmentEndedAt: payload.segmentEndedAt
        )
        let existing = try db.query("""
            SELECT id, status
            FROM sync_queue
            WHERE job_type = ?
              AND (
                entity_id = ?
                OR entity_id = ?
              )
            ORDER BY
              CASE status
                WHEN 'done' THEN 0
                WHEN 'running' THEN 1
                WHEN 'pending' THEN 2
                WHEN 'failed' THEN 3
                ELSE 4
              END,
              id DESC
            LIMIT 1
        """, params: [
            .text("audio_transcription"),
            .text(entityID),
            .text(path)
        ])

        if let row = existing.first,
           let id = row["id"]?.intValue,
           let status = row["status"]?.textValue {
            switch status {
            case "done", "pending", "running":
                publishHealthSnapshot()
                return
            case "failed":
                try db.execute("""
                    UPDATE sync_queue
                    SET entity_id = ?, payload_json = ?, status = 'pending', retry_count = 0,
                        scheduled_at = ?, started_at = NULL, finished_at = NULL, last_error = NULL
                    WHERE id = ?
                """, params: [
                    .text(entityID),
                    .text(payloadJson),
                    .text(nowString),
                    .integer(id)
                ])
            default:
                return
            }
        } else {
            try db.execute("""
                INSERT INTO sync_queue (job_type, entity_id, payload_json, status, retry_count, scheduled_at)
                VALUES (?, ?, ?, 'pending', 0, ?)
            """, params: [
                .text("audio_transcription"),
                .text(entityID),
                .text(payloadJson),
                .text(nowString)
            ])
        }

        publishHealthSnapshot()
    }

    @discardableResult
    func drainQueuedTranscriptions(limit: Int = 1) async throws -> Int {
        guard beginDrainIfNeeded() else {
            logger.debug("AudioTranscriber: queue drain skipped because another drain is active")
            return 0
        }
        defer { finishDrain() }

        let nowDate = now()
        let nowString = dateSupport.isoString(from: nowDate)
        let rows = try db.query("""
            SELECT id, payload_json, retry_count, status
            FROM sync_queue
            WHERE job_type = ?
              AND status IN ('pending', 'failed')
              AND (scheduled_at IS NULL OR scheduled_at <= ?)
            ORDER BY
              CASE
                WHEN entity_id LIKE 'audio:microphone:%'
                  OR payload_json LIKE '%"source":"microphone"%'
                THEN 0
                ELSE 1
              END,
              CASE status
                WHEN 'pending' THEN 0
                ELSE 1
              END,
              id
            LIMIT ?
        """, params: [
            .text("audio_transcription"),
            .text(nowString),
            .integer(Int64(max(limit, 1)))
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
            setCurrentRunningJob(from: row["payload_json"]?.textValue)
            publishHealthSnapshot()

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
                telemetryQueue.sync {
                    lastRetryCount = retryCount
                    lastErrorDescription = nil
                }
            } catch let error as AudioError where error.isTerminalQueueFailure {
                try db.execute("""
                    UPDATE sync_queue
                    SET status = 'done', finished_at = ?, started_at = COALESCE(started_at, ?), last_error = ?
                    WHERE id = ?
                """, params: [
                    .text(nowString),
                    .text(nowString),
                    .text(error.localizedDescription),
                    .integer(id)
                ])
                telemetryQueue.sync {
                    lastRetryCount = retryCount
                    lastErrorDescription = error.localizedDescription
                }
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
                telemetryQueue.sync {
                    lastRetryCount = retryCount + 1
                    lastErrorDescription = error.localizedDescription
                }
            }

            clearCurrentRunningJob()
            publishHealthSnapshot()
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
            throw AudioError.missingQueuedSegment(payload.path)
        }

        let result = try await transcribeFile(
            audioPath: payload.path,
            language: payload.language,
            source: payload.source
        )
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

    private func makeQueueEntityID(
        path: String,
        source: String,
        segmentStartedAt: String,
        segmentEndedAt: String
    ) -> String {
        "audio:\(source):\(segmentStartedAt):\(segmentEndedAt):\(path)"
    }

    private func beginDrainIfNeeded() -> Bool {
        drainStateQueue.sync {
            guard !isDrainingQueue else { return false }
            isDrainingQueue = true
            return true
        }
    }

    private func finishDrain() {
        drainStateQueue.sync {
            isDrainingQueue = false
        }
        publishHealthSnapshot()
    }

    private func transcribeViaLocalWhisper(
        audioPath: String,
        language: String?,
        environment: AudioRuntimeEnvironment
    ) async throws -> AudioTranscript {
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

        return try parseTranscriptResponse(json, fallbackLanguage: language)
    }

    private func transcribeViaCloud(
        audioPath: String,
        language: String?,
        source: String?,
        environment: AudioCloudRuntimeEnvironment
    ) async throws -> AudioTranscript {
        let fileURL = URL(fileURLWithPath: audioPath)
        let uploadAudioURL = await prepareUploadAudioFileIfNeeded(fileURL, source: source)
        let modelName = modelName(for: source, environment: environment)
        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: normalizedBaseURL(environment.baseURL) + "/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(environment.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let bodyFileURL = try buildMultipartBodyFile(
            boundary: boundary,
            audioFileURL: uploadAudioURL,
            fileName: uploadAudioURL.lastPathComponent,
            mimeType: mimeType(for: uploadAudioURL.pathExtension),
            modelName: modelName,
            language: language
        )
        defer {
            try? FileManager.default.removeItem(at: bodyFileURL)
            if uploadAudioURL != fileURL {
                try? FileManager.default.removeItem(at: uploadAudioURL)
            }
        }

        let uploadSizeBytes = fileSize(at: bodyFileURL)
        let latencyStart = Date()
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await uploadTransport(request, bodyFileURL)
        } catch {
            recordCloudAttemptFailure(error, uploadSizeBytes: uploadSizeBytes, startedAt: latencyStart)
            throw error
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            let error = AudioError.transcriptionFailed("Invalid HTTP response from audio transcription API")
            recordCloudAttemptFailure(error, uploadSizeBytes: uploadSizeBytes, startedAt: latencyStart)
            throw error
        }

        guard httpResponse.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let error = AudioError.transcriptionFailed("HTTP \(httpResponse.statusCode): \(bodyText)")
            recordCloudAttemptFailure(error, uploadSizeBytes: uploadSizeBytes, startedAt: latencyStart)
            throw error
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let error = AudioError.transcriptionFailed("Failed to parse cloud transcription output")
            recordCloudAttemptFailure(error, uploadSizeBytes: uploadSizeBytes, startedAt: latencyStart)
            throw error
        }

        recordCloudAttemptSuccess(uploadSizeBytes: uploadSizeBytes, startedAt: latencyStart)
        logger.info("AudioTranscriber: cloud transcription ok for \(source ?? "audio", privacy: .public) using \(modelName, privacy: .public)")
        return try parseTranscriptResponse(json, fallbackLanguage: language)
    }

    private func prepareUploadAudioFileIfNeeded(_ sourceURL: URL, source: String?) async -> URL {
        guard shouldCompressBeforeUpload(source: source, pathExtension: sourceURL.pathExtension) else {
            return sourceURL
        }

        do {
            let compressedURL = try await transcodeAudioForUpload(sourceURL)
            let sourceSize = fileSize(at: sourceURL)
            let compressedSize = fileSize(at: compressedURL)
            logger.info(
                "AudioTranscriber: compressed microphone upload from \(sourceSize) bytes to \(compressedSize) bytes"
            )
            return compressedURL
        } catch {
            logger.error(
                "AudioTranscriber: microphone upload compression failed, falling back to original file: \(error.localizedDescription)"
            )
            return sourceURL
        }
    }

    private func parseTranscriptResponse(
        _ json: [String: Any],
        fallbackLanguage: String?
    ) throws -> AudioTranscript {
        if let error = json["error"] as? String {
            throw AudioError.transcriptionFailed(error)
        }

        guard let text = json["text"] as? String else {
            throw AudioError.transcriptionFailed("Transcription output did not contain text")
        }

        let detectedLang = (json["language"] as? String) ?? fallbackLanguage
        let durationSeconds = json["duration"] as? Double ?? 0

        return AudioTranscript(
            id: UUID().uuidString,
            sessionId: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            segmentStartedAt: nil,
            segmentEndedAt: nil,
            persistedAt: nil,
            durationSeconds: durationSeconds,
            text: text,
            language: detectedLang,
            source: nil
        )
    }

    private func modelName(for source: String?, environment: AudioCloudRuntimeEnvironment) -> String {
        switch source {
        case "microphone":
            return environment.microphoneModel
        case "system":
            return environment.systemAudioModel
        default:
            return environment.systemAudioModel
        }
    }

    private func normalizedBaseURL(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        case "caf":
            return "audio/x-caf"
        default:
            return "application/octet-stream"
        }
    }

    private func shouldCompressBeforeUpload(source: String?, pathExtension: String) -> Bool {
        guard source == "microphone" else { return false }
        switch pathExtension.lowercased() {
        case "wav", "caf", "aif", "aiff":
            return true
        default:
            return false
        }
    }

    private func transcodeAudioForUpload(_ sourceURL: URL) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memograph-audio-upload-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let asset = AVURLAsset(url: sourceURL)

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.transcriptionFailed("No compatible export session for audio compression")
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .m4a
        exportSession.shouldOptimizeForNetworkUse = true

        if #available(macOS 15.0, *) {
            try await exportSession.export(to: outputURL, as: .m4a)
        } else {
            let box = LegacyExportSessionBox(session: exportSession)
            try await withCheckedThrowingContinuation { continuation in
                box.session.exportAsynchronously {
                    switch box.session.status {
                    case .completed:
                        continuation.resume(returning: ())
                    case .failed:
                        continuation.resume(
                            throwing: box.session.error
                                ?? AudioError.transcriptionFailed("Audio compression failed")
                        )
                    case .cancelled:
                        continuation.resume(
                            throwing: AudioError.transcriptionFailed("Audio compression was cancelled")
                        )
                    default:
                        continuation.resume(
                            throwing: AudioError.transcriptionFailed("Audio compression ended in unexpected state")
                        )
                    }
                }
            }
        }

        return outputURL
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func currentHealthSnapshot() -> AudioHealthSnapshot {
        buildHealthSnapshot()
    }

    func systemAudioThrottleDecision(now: Date = Date()) -> SystemAudioThrottleDecision {
        let snapshot = buildHealthSnapshot(now: now)

        if snapshot.currentRunningSource == "microphone" || snapshot.pendingMicrophoneJobs > 0 {
            return SystemAudioThrottleDecision(
                shouldThrottle: true,
                reason: "microphone priority",
                cooldown: 30
            )
        }

        if snapshot.pendingJobs + snapshot.runningJobs >= 4 || snapshot.pendingSystemJobs >= 3 {
            return SystemAudioThrottleDecision(
                shouldThrottle: true,
                reason: "audio queue backlog",
                cooldown: 45
            )
        }

        if recentCloudFailureCount(within: 15 * 60, now: now) >= 3 || snapshot.consecutiveCloudFailures >= 2 {
            return SystemAudioThrottleDecision(
                shouldThrottle: true,
                reason: "recent cloud failures",
                cooldown: 90
            )
        }

        return .allow
    }

    func setSystemAudioThrottled(_ throttled: Bool, reason: String? = nil, cooldown: TimeInterval = 0) {
        let changed = telemetryQueue.sync { () -> Bool in
            let normalizedReason = throttled ? reason : nil
            let nextUntil = throttled ? now().addingTimeInterval(cooldown) : .distantPast
            let didChange = systemAudioThrottled != throttled
                || systemAudioThrottleReason != normalizedReason
                || (throttled && abs(systemAudioThrottleUntil.timeIntervalSince(nextUntil)) > 1)

            systemAudioThrottled = throttled
            systemAudioThrottleReason = normalizedReason
            systemAudioThrottleUntil = nextUntil
            return didChange
        }
        guard changed else { return }
        publishHealthSnapshot()
    }

    private func setCurrentRunningJob(from payloadJson: String?) {
        telemetryQueue.sync {
            guard let payloadJson,
                  let payloadData = payloadJson.data(using: .utf8),
                  let payload = try? decoder.decode(QueuedTranscriptionPayload.self, from: payloadData) else {
                currentRunningSource = nil
                currentRunningJob = nil
                return
            }
            currentRunningSource = payload.source
            currentRunningJob = payload.path
        }
    }

    private func clearCurrentRunningJob() {
        telemetryQueue.sync {
            currentRunningSource = nil
            currentRunningJob = nil
        }
    }

    private func recordCloudAttemptSuccess(uploadSizeBytes: Int64, startedAt: Date) {
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        telemetryQueue.sync {
            lastUploadSizeBytes = uploadSizeBytes
            lastTranscriptionLatencyMs = latencyMs
            consecutiveCloudFailures = 0
        }
        logger.info("AudioTranscriber: upload size \(uploadSizeBytes) bytes, latency \(latencyMs) ms")
        publishHealthSnapshot()
    }

    private func recordCloudAttemptFailure(
        _ error: Error,
        uploadSizeBytes: Int64,
        startedAt: Date
    ) {
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        telemetryQueue.sync {
            lastUploadSizeBytes = uploadSizeBytes
            lastTranscriptionLatencyMs = latencyMs
            consecutiveCloudFailures += 1
            lastErrorDescription = error.localizedDescription
            if Self.isLikelyNetworkFailure(error) {
                networkFailureCount += 1
                recentCloudFailureDates.append(now())
                recentCloudFailureDates = recentCloudFailureDates.filter {
                    now().timeIntervalSince($0) <= 15 * 60
                }
            }
        }
        logger.error("AudioTranscriber: cloud failure after \(latencyMs) ms, upload \(uploadSizeBytes) bytes: \(error.localizedDescription)")
        publishHealthSnapshot()
    }

    private func recentCloudFailureCount(within window: TimeInterval, now: Date) -> Int {
        telemetryQueue.sync {
            recentCloudFailureDates.filter { now.timeIntervalSince($0) <= window }.count
        }
    }

    private func publishHealthSnapshot() {
        let snapshot = buildHealthSnapshot()
        Task { @MainActor [healthMonitor] in
            healthMonitor.publish(snapshot)
        }
    }

    private func buildHealthSnapshot(now: Date? = nil) -> AudioHealthSnapshot {
        let referenceDate = now ?? self.now()
        let rows = (try? db.query("""
            SELECT status, entity_id, payload_json, retry_count, last_error
            FROM sync_queue
            WHERE job_type = ?
              AND status IN ('pending', 'running', 'failed')
        """, params: [.text("audio_transcription")])) ?? []

        var pendingJobs = 0
        var runningJobs = 0
        var failedJobs = 0
        var pendingMicrophoneJobs = 0
        var pendingSystemJobs = 0

        for row in rows {
            let status = row["status"]?.textValue ?? ""
            let source = queuedSource(entityID: row["entity_id"]?.textValue, payloadJson: row["payload_json"]?.textValue)

            switch status {
            case "pending":
                pendingJobs += 1
                if source == "microphone" {
                    pendingMicrophoneJobs += 1
                } else if source == "system" {
                    pendingSystemJobs += 1
                }
            case "running":
                runningJobs += 1
            case "failed":
                failedJobs += 1
            default:
                break
            }
        }

        let telemetry = telemetryQueue.sync { () -> (
            Int64?, Int?, Int, Int, Int, String?, String?, Bool, String?, Date, String?
        ) in
            if systemAudioThrottled, referenceDate >= systemAudioThrottleUntil {
                systemAudioThrottled = false
                systemAudioThrottleReason = nil
                systemAudioThrottleUntil = .distantPast
            }

            return (
                lastUploadSizeBytes,
                lastTranscriptionLatencyMs,
                lastRetryCount,
                networkFailureCount,
                consecutiveCloudFailures,
                currentRunningSource,
                currentRunningJob,
                systemAudioThrottled,
                systemAudioThrottleReason,
                systemAudioThrottleUntil,
                lastErrorDescription
            )
        }

        return AudioHealthSnapshot(
            pendingJobs: pendingJobs,
            runningJobs: runningJobs,
            failedJobs: failedJobs,
            pendingMicrophoneJobs: pendingMicrophoneJobs,
            pendingSystemJobs: pendingSystemJobs,
            currentRunningSource: telemetry.5,
            currentRunningJob: telemetry.6,
            lastUploadSizeBytes: telemetry.0,
            lastTranscriptionLatencyMs: telemetry.1,
            lastRetryCount: telemetry.2,
            networkFailureCount: telemetry.3,
            consecutiveCloudFailures: telemetry.4,
            cloudTranscriptionDelayed: pendingJobs > 0 || failedJobs > 0,
            systemAudioThrottled: telemetry.7,
            systemAudioThrottleReason: telemetry.8,
            lastError: telemetry.10,
            updatedAt: referenceDate
        )
    }

    private func queuedSource(entityID: String?, payloadJson: String?) -> String? {
        if let entityID, entityID.hasPrefix("audio:microphone:") {
            return "microphone"
        }
        if let entityID, entityID.hasPrefix("audio:system:") {
            return "system"
        }
        guard let payloadJson,
              let payloadData = payloadJson.data(using: .utf8),
              let payload = try? decoder.decode(QueuedTranscriptionPayload.self, from: payloadData) else {
            return nil
        }
        return payload.source
    }

    private static func isLikelyNetworkFailure(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }

        if let audioError = error as? AudioError,
           case .transcriptionFailed(let message) = audioError {
            return message.hasPrefix("HTTP 5")
                || message.contains("timed out")
                || message.contains("network")
                || message.contains("offline")
                || message.contains("cannot connect")
        }

        return false
    }

    private static func uploadRequest(_ request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.uploadTask(with: request, fromFile: fileURL) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data, let response else {
                    continuation.resume(throwing: AudioError.transcriptionFailed("Missing upload response"))
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }
    }

    private func buildMultipartBodyFile(
        boundary: String,
        audioFileURL: URL,
        fileName: String,
        mimeType: String,
        modelName: String,
        language: String?
    ) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memograph-audio-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        let writer = try FileHandle(forWritingTo: tempURL)
        defer { try? writer.close() }

        func append(_ string: String) throws {
            try writer.write(contentsOf: Data(string.utf8))
        }

        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        try append("\(modelName)\r\n")

        if let language, !language.isEmpty {
            try append("--\(boundary)\r\n")
            try append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            try append("\(language)\r\n")
        }

        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        try append("json\r\n")

        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        try append("Content-Type: \(mimeType)\r\n\r\n")

        let reader = try FileHandle(forReadingFrom: audioFileURL)
        defer { try? reader.close() }
        while true {
            let chunk = try reader.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            try writer.write(contentsOf: chunk)
        }

        try append("\r\n")
        try append("--\(boundary)--\r\n")
        return tempURL
    }
}

enum AudioError: Error, LocalizedError {
    case missingAPIKey(String)
    case pythonNotFound(String)
    case scriptNotFound(String)
    case missingQueuedSegment(String)
    case transcriptionFailed(String)

    var isTerminalQueueFailure: Bool {
        switch self {
        case .missingQueuedSegment:
            return true
        case .missingAPIKey, .pythonNotFound, .scriptNotFound, .transcriptionFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let message): return "Missing API key: \(message)"
        case .pythonNotFound(let p): return "Python runtime not found: \(p)"
        case .scriptNotFound(let p): return "Whisper script not found at \(p)"
        case .missingQueuedSegment(let path): return "Queued audio segment missing at \(path)"
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        }
    }
}
