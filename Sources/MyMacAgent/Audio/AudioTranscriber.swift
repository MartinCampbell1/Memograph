import Foundation
import os

struct AudioTranscript {
    let id: String
    let sessionId: String?
    let timestamp: String
    let durationSeconds: Double
    let text: String
    let language: String?
}

final class AudioTranscriber {
    private let db: DatabaseManager
    let venvPath: String
    private let scriptPath: String
    nonisolated(unsafe) private let logger = Logger.app

    init(db: DatabaseManager,
         venvPath: String = "",
         scriptPath: String = "") {
        self.db = db

        // Default paths
        if venvPath.isEmpty {
            let projectDir = Bundle.main.bundlePath
                .components(separatedBy: "/build/").first ?? NSHomeDirectory() + "/mymacagent"
            self.venvPath = projectDir + "/.venv"
        } else {
            self.venvPath = venvPath
        }

        if scriptPath.isEmpty {
            let projectDir = Bundle.main.bundlePath
                .components(separatedBy: "/build/").first ?? NSHomeDirectory() + "/mymacagent"
            self.scriptPath = projectDir + "/Sources/MyMacAgent/Audio/whisper_transcribe.py"
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
        let pythonPath = venvPath + "/bin/python3"

        guard FileManager.default.fileExists(atPath: pythonPath) else {
            throw AudioError.venvNotFound(venvPath)
        }
        guard FileManager.default.fileExists(atPath: scriptPath) else {
            throw AudioError.scriptNotFound(scriptPath)
        }

        var args = [scriptPath, audioPath]
        if let lang = language { args.append(lang) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw AudioError.transcriptionFailed("Failed to parse whisper output")
        }

        let detectedLang = json["language"] as? String

        return AudioTranscript(
            id: UUID().uuidString,
            sessionId: nil,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            durationSeconds: 0,
            text: text,
            language: detectedLang ?? language
        )
    }

    func persistTranscript(sessionId: String?, text: String, language: String?, durationSeconds: Double) throws {
        let id = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        try db.execute("""
            INSERT INTO audio_transcripts (id, session_id, timestamp, duration_seconds, transcript, language)
            VALUES (?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            sessionId.map { .text($0) } ?? .null,
            .text(now),
            .real(durationSeconds),
            .text(text),
            language.map { .text($0) } ?? .null
        ])
    }

    func getTranscriptsForDate(_ date: String) throws -> [AudioTranscript] {
        let rows = try db.query("""
            SELECT id, session_id, timestamp, duration_seconds, transcript, language
            FROM audio_transcripts
            WHERE timestamp LIKE ?
            ORDER BY timestamp
        """, params: [.text("\(date)%")])

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
                language: row["language"]?.textValue
            )
        }
    }
}

enum AudioError: Error, LocalizedError {
    case venvNotFound(String)
    case scriptNotFound(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .venvNotFound(let p): return "Python venv not found at \(p)"
        case .scriptNotFound(let p): return "Whisper script not found at \(p)"
        case .transcriptionFailed(let m): return "Transcription failed: \(m)"
        }
    }
}
