import Testing
import Foundation
@testable import MyMacAgent

struct AudioTranscriberTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let makassar = TimeZone(secondsFromGMT: 8 * 3600)!

    private func makeDB() throws -> (DatabaseManager, String) {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).db"
        let db = try DatabaseManager(path: path)
        let runner = MigrationRunner(db: db, migrations: [
            V001_InitialSchema.migration,
            V002_AudioTranscripts.migration,
            V004_AudioTranscriptDurability.migration
        ])
        try runner.runPending()
        return (db, path)
    }

    @Test("Transcriber initializes with correct paths")
    func initializes() {
        let transcriber = AudioTranscriber(db: DatabaseManager.forTesting(), timeZone: utc)
        #expect(transcriber.venvPath.contains(".venv"))
    }

    @Test("persistTranscript saves to DB")
    func persistsTranscript() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("INSERT INTO apps (bundle_id, app_name) VALUES (?, ?)",
            params: [.text("com.test"), .text("Test")])
        try db.execute("INSERT INTO sessions (id, app_id, started_at) VALUES (?, ?, ?)",
            params: [.text("s1"), .integer(1), .text("2026-04-02T10:00:00Z")])

        let transcriber = AudioTranscriber(db: db, timeZone: utc)
        try transcriber.persistTranscript(
            sessionId: "s1",
            text: "Обсуждали архитектуру нового сервиса",
            language: "ru",
            durationSeconds: 300,
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z"),
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:05:00Z")
        )

        let rows = try db.query("SELECT * FROM audio_transcripts")
        #expect(rows.count == 1)
        #expect(rows[0]["transcript"]?.textValue?.contains("архитектуру") == true)
        #expect(rows[0]["language"]?.textValue == "ru")
        #expect(rows[0]["segment_started_at"]?.textValue == "2026-04-02T10:00:00Z")
        #expect(rows[0]["segment_ended_at"]?.textValue == "2026-04-02T10:05:00Z")
    }

    @Test("getTranscriptsForDate returns ordered transcripts")
    func getsTranscripts() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO audio_transcripts
                (id, timestamp, segment_started_at, segment_ended_at, persisted_at, transcript, duration_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("t1"),
            .text("2026-04-02T10:00:00Z"),
            .text("2026-04-02T10:00:00Z"),
            .text("2026-04-02T10:05:00Z"),
            .text("2026-04-02T10:05:05Z"),
            .text("First chunk"),
            .real(300)
        ])
        try db.execute("""
            INSERT INTO audio_transcripts
                (id, timestamp, segment_started_at, segment_ended_at, persisted_at, transcript, duration_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("t2"),
            .text("2026-04-02T10:05:00Z"),
            .text("2026-04-02T10:05:00Z"),
            .text("2026-04-02T10:10:00Z"),
            .text("2026-04-02T10:10:03Z"),
            .text("Second chunk"),
            .real(300)
        ])

        let transcriber = AudioTranscriber(db: db, timeZone: utc)
        let transcripts = try transcriber.getTranscriptsForDate("2026-04-02")

        #expect(transcripts.count == 2)
        #expect(transcripts[0].text == "First chunk")
    }

    @Test("getTranscriptsForDate uses local day boundaries")
    func getsTranscriptsForLocalDay() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try db.execute("""
            INSERT INTO audio_transcripts
                (id, timestamp, segment_started_at, segment_ended_at, persisted_at, transcript, duration_seconds)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text("t-local"),
            .text("2026-04-02T16:05:00Z"),
            .text("2026-04-02T16:05:00Z"),
            .text("2026-04-02T16:06:00Z"),
            .text("2026-04-02T16:06:01Z"),
            .text("Late-night note"),
            .real(60)
        ])

        let transcriber = AudioTranscriber(db: db, timeZone: makassar)
        let transcripts = try transcriber.getTranscriptsForDate("2026-04-03")

        #expect(transcripts.count == 1)
        #expect(transcripts[0].text == "Late-night note")
    }

    @Test("Queued transcription retries without deleting the source file on failure")
    func queuedTranscriptionRetries() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("queued-audio-\(UUID().uuidString).wav")
        try Data("fake audio".utf8).write(to: URL(fileURLWithPath: audioPath))
        defer { try? FileManager.default.removeItem(atPath: audioPath) }

        let transcriber = AudioTranscriber(
            db: db,
            venvPath: "/missing",
            scriptPath: "/missing",
            runtimeStatus: .missingPython("/missing"),
            timeZone: utc
        )
        try transcriber.enqueueTranscriptionJob(
            path: audioPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:01:00Z")!
        )

        let drained = try await transcriber.drainQueuedTranscriptions(limit: 1)
        #expect(drained == 0)
        #expect(FileManager.default.fileExists(atPath: audioPath))

        let rows = try db.query("""
            SELECT status, retry_count
            FROM sync_queue
            WHERE job_type = ?
        """, params: [.text("audio_transcription")])
        #expect(rows.count == 1)
        #expect(rows[0]["status"]?.textValue == "failed")
        #expect(rows[0]["retry_count"]?.intValue == 1)
    }

    @Test("Cloud transcription uses premium microphone model")
    func cloudTranscriptionUsesPremiumMicrophoneModel() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var bodies: [String] = []

            func append(_ body: String) {
                lock.lock()
                bodies.append(body)
                lock.unlock()
            }
        }

        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let suiteName = "test_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.audioTranscriptionProvider = .openAI
        settings.audioTranscriptionBaseURL = "https://api.openai.com/v1"
        settings.audioTranscriptionAPIKey = "sk-audio-test"
        settings.audioMicrophoneModel = "gpt-4o-transcribe"
        settings.audioSystemModel = "gpt-4o-mini-transcribe"
        let settingsProvider: @Sendable () -> AppSettings = {
            AppSettings(defaults: UserDefaults(suiteName: suiteName)!, credentialsStore: store)
        }

        let recorder = Recorder()
        let audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cloud-mic-\(UUID().uuidString).wav")
        try Data("fake audio".utf8).write(to: URL(fileURLWithPath: audioPath))
        defer { try? FileManager.default.removeItem(atPath: audioPath) }

        let transcriber = AudioTranscriber(
            db: db,
            timeZone: utc,
            settingsProvider: settingsProvider,
            uploadTransport: { request, bodyFileURL in
                let body = try String(decoding: Data(contentsOf: bodyFileURL), as: UTF8.self)
                recorder.append(body)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = try JSONSerialization.data(withJSONObject: [
                    "text": "Привет из облака",
                    "language": "ru",
                    "duration": 12.0
                ])
                return (data, response)
            }
        )

        try transcriber.enqueueTranscriptionJob(
            path: audioPath,
            sessionId: nil,
            source: "microphone",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:12Z")!
        )

        let drained = try await transcriber.drainQueuedTranscriptions(limit: 1)
        #expect(drained == 1)
        #expect(recorder.bodies.count == 1)
        #expect(recorder.bodies[0].contains("gpt-4o-transcribe"))
        #expect(!recorder.bodies[0].contains("gpt-4o-mini-transcribe"))

        let rows = try db.query("SELECT transcript, source FROM audio_transcripts")
        #expect(rows.count == 1)
        #expect(rows[0]["transcript"]?.textValue == "Привет из облака")
        #expect(rows[0]["source"]?.textValue == "microphone")
    }

    @Test("Cloud transcription uses cheaper system-audio model")
    func cloudTranscriptionUsesCheaperSystemModel() async throws {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var lastBody: String = ""

            func set(_ body: String) {
                lock.lock()
                lastBody = body
                lock.unlock()
            }
        }

        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let suiteName = "test_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.audioTranscriptionProvider = .openAI
        settings.audioTranscriptionBaseURL = "https://api.openai.com/v1"
        settings.audioTranscriptionAPIKey = "sk-audio-test"
        settings.audioMicrophoneModel = "gpt-4o-transcribe"
        settings.audioSystemModel = "gpt-4o-mini-transcribe"
        let settingsProvider: @Sendable () -> AppSettings = {
            AppSettings(defaults: UserDefaults(suiteName: suiteName)!, credentialsStore: store)
        }

        let recorder = Recorder()
        let audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cloud-system-\(UUID().uuidString).wav")
        try Data("fake audio".utf8).write(to: URL(fileURLWithPath: audioPath))
        defer { try? FileManager.default.removeItem(atPath: audioPath) }

        let transcriber = AudioTranscriber(
            db: db,
            timeZone: utc,
            settingsProvider: settingsProvider,
            uploadTransport: { request, bodyFileURL in
                let body = try String(decoding: Data(contentsOf: bodyFileURL), as: UTF8.self)
                recorder.set(body)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = try JSONSerialization.data(withJSONObject: [
                    "text": "System audio",
                    "language": "en",
                    "duration": 8.0
                ])
                return (data, response)
            }
        )

        try transcriber.enqueueTranscriptionJob(
            path: audioPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:08Z")!
        )

        let drained = try await transcriber.drainQueuedTranscriptions(limit: 1)
        #expect(drained == 1)
        #expect(recorder.lastBody.contains("gpt-4o-mini-transcribe"))
    }

    @Test("Queued transcription deduplicates identical segment jobs")
    func queuedTranscriptionDeduplicatesIdenticalSegments() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("dedupe-audio-\(UUID().uuidString).wav")
        try Data("fake audio".utf8).write(to: URL(fileURLWithPath: audioPath))
        defer { try? FileManager.default.removeItem(atPath: audioPath) }

        let transcriber = AudioTranscriber(db: db, timeZone: utc)
        let startedAt = ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!
        let endedAt = ISO8601DateFormatter().date(from: "2026-04-02T10:01:00Z")!

        try transcriber.enqueueTranscriptionJob(
            path: audioPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: startedAt,
            segmentEndedAt: endedAt
        )
        try transcriber.enqueueTranscriptionJob(
            path: audioPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: startedAt,
            segmentEndedAt: endedAt
        )

        let rows = try db.query("""
            SELECT entity_id, status
            FROM sync_queue
            WHERE job_type = ?
        """, params: [.text("audio_transcription")])

        #expect(rows.count == 1)
        #expect(rows[0]["entity_id"]?.textValue?.contains("2026-04-02T10:00:00Z") == true)
        #expect(rows[0]["status"]?.textValue == "pending")
    }

    @Test("Missing queued segment becomes terminal instead of retrying forever")
    func missingQueuedSegmentIsTerminal() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("missing-audio-\(UUID().uuidString).wav")
        let transcriber = AudioTranscriber(db: db, timeZone: utc)

        try transcriber.enqueueTranscriptionJob(
            path: audioPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:01:00Z")!
        )

        let drained = try await transcriber.drainQueuedTranscriptions(limit: 1)
        #expect(drained == 0)

        let rows = try db.query("""
            SELECT status, retry_count, last_error
            FROM sync_queue
            WHERE job_type = ?
        """, params: [.text("audio_transcription")])
        #expect(rows.count == 1)
        #expect(rows[0]["status"]?.textValue == "done")
        #expect(rows[0]["retry_count"]?.intValue == 0)
        #expect(rows[0]["last_error"]?.textValue?.contains("Queued audio segment missing") == true)
    }

    @Test("Microphone jobs are drained before system audio jobs")
    func microphoneJobsHavePriority() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let micPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("priority-mic-\(UUID().uuidString).wav")
        let systemPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("priority-system-\(UUID().uuidString).wav")
        try Data("mic".utf8).write(to: URL(fileURLWithPath: micPath))
        try Data("system".utf8).write(to: URL(fileURLWithPath: systemPath))
        defer {
            try? FileManager.default.removeItem(atPath: micPath)
            try? FileManager.default.removeItem(atPath: systemPath)
        }

        let suiteName = "test_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.audioTranscriptionProvider = .openAI
        settings.audioTranscriptionBaseURL = "https://api.openai.com/v1"
        settings.audioTranscriptionAPIKey = "sk-audio-test"
        let settingsProvider: @Sendable () -> AppSettings = {
            AppSettings(defaults: UserDefaults(suiteName: suiteName)!, credentialsStore: store)
        }

        let transcriber = AudioTranscriber(
            db: db,
            timeZone: utc,
            settingsProvider: settingsProvider,
            uploadTransport: { request, bodyFileURL in
                let body = try String(decoding: Data(contentsOf: bodyFileURL), as: UTF8.self)
                let text = body.contains("priority-mic") ? "Mic first" : "System first"
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = try JSONSerialization.data(withJSONObject: [
                    "text": text,
                    "language": "en",
                    "duration": 8.0
                ])
                return (data, response)
            }
        )

        try transcriber.enqueueTranscriptionJob(
            path: systemPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:08Z")!
        )
        try transcriber.enqueueTranscriptionJob(
            path: micPath,
            sessionId: nil,
            source: "microphone",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:10Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:18Z")!
        )

        let drained = try await transcriber.drainQueuedTranscriptions(limit: 1)
        #expect(drained == 1)

        let rows = try db.query("""
            SELECT transcript, source
            FROM audio_transcripts
        """)
        #expect(rows.count == 1)
        #expect(rows[0]["transcript"]?.textValue == "Mic first")
        #expect(rows[0]["source"]?.textValue == "microphone")
    }

    @Test("Concurrent drain calls still run a single active transcription")
    func concurrentDrainCallsAreSerialized() async throws {
        final class ConcurrencyProbe: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var active = 0
            private(set) var maxActive = 0

            func begin() {
                lock.lock()
                active += 1
                maxActive = max(maxActive, active)
                lock.unlock()
            }

            func end() {
                lock.lock()
                active -= 1
                lock.unlock()
            }
        }

        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let suiteName = "test_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.audioTranscriptionProvider = .openAI
        settings.audioTranscriptionBaseURL = "https://api.openai.com/v1"
        settings.audioTranscriptionAPIKey = "sk-audio-test"
        let settingsProvider: @Sendable () -> AppSettings = {
            AppSettings(defaults: UserDefaults(suiteName: suiteName)!, credentialsStore: store)
        }

        let firstPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("serial-one-\(UUID().uuidString).wav")
        let secondPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("serial-two-\(UUID().uuidString).wav")
        try Data("one".utf8).write(to: URL(fileURLWithPath: firstPath))
        try Data("two".utf8).write(to: URL(fileURLWithPath: secondPath))
        defer {
            try? FileManager.default.removeItem(atPath: firstPath)
            try? FileManager.default.removeItem(atPath: secondPath)
        }

        let probe = ConcurrencyProbe()
        let transcriber = AudioTranscriber(
            db: db,
            timeZone: utc,
            settingsProvider: settingsProvider,
            uploadTransport: { request, _ in
                probe.begin()
                defer { probe.end() }
                try await Task.sleep(for: .milliseconds(150))
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                let data = try JSONSerialization.data(withJSONObject: [
                    "text": "Serialized",
                    "language": "en",
                    "duration": 5.0
                ])
                return (data, response)
            }
        )

        try transcriber.enqueueTranscriptionJob(
            path: firstPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:05Z")!
        )
        try transcriber.enqueueTranscriptionJob(
            path: secondPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:10Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:15Z")!
        )

        let firstDrain = Task { try await transcriber.drainQueuedTranscriptions(limit: 1) }
        try await Task.sleep(for: .milliseconds(20))
        let secondDrain = Task { try await transcriber.drainQueuedTranscriptions(limit: 1) }

        let results = try await [firstDrain.value, secondDrain.value].sorted()
        #expect(results == [0, 1])
        #expect(probe.maxActive == 1)
    }

    @Test("Health snapshot reflects queue depth and system throttle state")
    func healthSnapshotReflectsQueueAndThrottle() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let micPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("health-mic-\(UUID().uuidString).wav")
        let systemPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("health-system-\(UUID().uuidString).wav")
        try Data("mic".utf8).write(to: URL(fileURLWithPath: micPath))
        try Data("system".utf8).write(to: URL(fileURLWithPath: systemPath))
        defer {
            try? FileManager.default.removeItem(atPath: micPath)
            try? FileManager.default.removeItem(atPath: systemPath)
        }

        let transcriber = AudioTranscriber(db: db, timeZone: utc)
        try transcriber.enqueueTranscriptionJob(
            path: micPath,
            sessionId: nil,
            source: "microphone",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:08Z")!
        )
        try transcriber.enqueueTranscriptionJob(
            path: systemPath,
            sessionId: nil,
            source: "system",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:01:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:01:08Z")!
        )
        transcriber.setSystemAudioThrottled(true, reason: "audio queue backlog", cooldown: 45)

        let snapshot = transcriber.currentHealthSnapshot()
        #expect(snapshot.pendingJobs == 2)
        #expect(snapshot.pendingMicrophoneJobs == 1)
        #expect(snapshot.pendingSystemJobs == 1)
        #expect(snapshot.cloudTranscriptionDelayed)
        #expect(snapshot.systemAudioThrottled)
        #expect(snapshot.systemAudioThrottleReason == "audio queue backlog")
    }

    @Test("System audio throttle decision prefers microphone work")
    func systemAudioThrottleDecisionPrefersMicrophone() throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let micPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("throttle-mic-\(UUID().uuidString).wav")
        try Data("mic".utf8).write(to: URL(fileURLWithPath: micPath))
        defer { try? FileManager.default.removeItem(atPath: micPath) }

        let transcriber = AudioTranscriber(db: db, timeZone: utc)
        try transcriber.enqueueTranscriptionJob(
            path: micPath,
            sessionId: nil,
            source: "microphone",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:08Z")!
        )

        let decision = transcriber.systemAudioThrottleDecision()
        #expect(decision.shouldThrottle)
        #expect(decision.reason == "microphone priority")
    }

    @Test("Network failures are reflected in audio health telemetry")
    func networkFailuresAppearInHealthTelemetry() async throws {
        let (db, path) = try makeDB()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let suiteName = "test_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = InMemoryCredentialsStore()
        var settings = AppSettings(defaults: defaults, credentialsStore: store)
        settings.audioTranscriptionProvider = .openAI
        settings.audioTranscriptionBaseURL = "https://api.openai.com/v1"
        settings.audioTranscriptionAPIKey = "sk-audio-test"
        let settingsProvider: @Sendable () -> AppSettings = {
            AppSettings(defaults: UserDefaults(suiteName: suiteName)!, credentialsStore: store)
        }

        let audioPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("network-failure-\(UUID().uuidString).wav")
        try Data("fake audio".utf8).write(to: URL(fileURLWithPath: audioPath))
        defer { try? FileManager.default.removeItem(atPath: audioPath) }

        let transcriber = AudioTranscriber(
            db: db,
            timeZone: utc,
            settingsProvider: settingsProvider,
            uploadTransport: { _, _ in
                throw URLError(.timedOut)
            }
        )

        try transcriber.enqueueTranscriptionJob(
            path: audioPath,
            sessionId: nil,
            source: "microphone",
            segmentStartedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:00Z")!,
            segmentEndedAt: ISO8601DateFormatter().date(from: "2026-04-02T10:00:08Z")!
        )

        let drained = try await transcriber.drainQueuedTranscriptions(limit: 1)
        #expect(drained == 0)

        let snapshot = transcriber.currentHealthSnapshot()
        #expect(snapshot.networkFailureCount == 1)
        #expect(snapshot.consecutiveCloudFailures == 1)
        #expect(snapshot.lastError?.isEmpty == false)
    }
}
