import Foundation
import os

struct AudioTranscript {
    let id: String
    let sessionId: String?
    let timestamp: String
    let durationSeconds: Double
    let text: String
    let language: String?
    let source: String?
}

final class AudioTranscriber: @unchecked Sendable {
    private let db: DatabaseManager
    let venvPath: String
    private let scriptPath: String
    private let runtimeStatus: AudioRuntimeStatus
    private let logger = Logger.app
    private let dateSupport: LocalDateSupport
    private let now: () -> Date

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
                duration_seconds REAL DEFAULT 0,
                transcript TEXT,
                language TEXT,
                source TEXT DEFAULT 'system',
                created_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
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
        source: String = "system"
    ) throws {
        let id = UUID().uuidString
        let timestamp = ISO8601DateFormatter().string(from: now())

        try db.execute("""
            INSERT INTO audio_transcripts (id, session_id, timestamp, duration_seconds, transcript, language, source)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            sessionId.map { .text($0) } ?? .null,
            .text(timestamp),
            .real(durationSeconds),
            .text(text),
            language.map { .text($0) } ?? .null,
            .text(source)
        ])
    }

    func getTranscriptsForDate(_ date: String) throws -> [AudioTranscript] {
        guard let range = dateSupport.utcRange(forLocalDate: date) else {
            return []
        }
        let rows = try db.query("""
            SELECT id, session_id, timestamp, duration_seconds, transcript, language, source
            FROM audio_transcripts
            WHERE timestamp >= ? AND timestamp < ?
            ORDER BY timestamp
        """, params: [.text(range.start), .text(range.end)])

        return rows.compactMap { row -> AudioTranscript? in
            guard let id = row["id"]?.textValue,
                  let timestamp = row["timestamp"]?.textValue,
                  let text = row["transcript"]?.textValue else { return nil }
            return AudioTranscript(
                id: id,
                sessionId: row["session_id"]?.textValue,
                timestamp: timestamp,
                durationSeconds: row["duration_seconds"]?.realValue ?? 0,
                text: text,
                language: row["language"]?.textValue,
                source: row["source"]?.textValue
            )
        }
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
