import AVFoundation
import os

final class AudioCaptureEngine: @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private var currentFile: AVAudioFile?
    private var currentFilePath: String?
    private var segmentTimer: Timer?
    private let segmentDuration: TimeInterval
    private let audioDir: String
    private let transcriber: AudioTranscriber
    private let sessionManager: SessionManager
    nonisolated(unsafe) private let logger = Logger.app
    private var isRecording = false

    init(transcriber: AudioTranscriber, sessionManager: SessionManager,
         segmentDuration: TimeInterval = 300, audioDir: String? = nil) {
        self.transcriber = transcriber
        self.sessionManager = sessionManager
        self.segmentDuration = segmentDuration
        if let dir = audioDir {
            self.audioDir = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.audioDir = appSupport.appendingPathComponent("MyMacAgent/audio").path
        }
    }

    func start() {
        guard !isRecording else { return }

        do {
            try FileManager.default.createDirectory(atPath: audioDir, withIntermediateDirectories: true)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)

            // Ensure we have a valid format
            guard format.sampleRate > 0 else {
                logger.error("AudioCapture: no valid input format")
                return
            }

            startNewSegment(format: format)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.writeBuffer(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            // Timer to rotate segments
            segmentTimer = Timer.scheduledTimer(withTimeInterval: segmentDuration, repeats: true) { [weak self] _ in
                self?.rotateSegment()
            }

            logger.info("AudioCapture: started recording (segment: \(Int(self.segmentDuration))s)")
        } catch {
            logger.error("AudioCapture: failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRecording else { return }
        segmentTimer?.invalidate()
        segmentTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRecording = false

        // Finalize current segment
        if let path = currentFilePath {
            currentFile = nil
            transcribeAndCleanup(path: path)
        }

        logger.info("AudioCapture: stopped")
    }

    var recording: Bool { isRecording }

    // MARK: - Private

    private func startNewSegment(format: AVAudioFormat? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "audio_\(timestamp).wav"
        let path = (audioDir as NSString).appendingPathComponent(filename)

        let fmt = format ?? audioEngine.inputNode.outputFormat(forBus: 0)

        do {
            let url = URL(fileURLWithPath: path)
            currentFile = try AVAudioFile(forWriting: url, settings: fmt.settings)
            currentFilePath = path
        } catch {
            logger.error("AudioCapture: failed to create file: \(error.localizedDescription)")
        }
    }

    private func writeBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let file = currentFile else { return }
        do {
            try file.write(from: buffer)
        } catch {
            // Don't spam logs for write errors
        }
    }

    private func rotateSegment() {
        let oldPath = currentFilePath
        currentFile = nil
        startNewSegment()

        if let path = oldPath {
            transcribeAndCleanup(path: path)
        }
    }

    private func transcribeAndCleanup(path: String) {
        let sessionId = sessionManager.currentSessionId
        let transcriber = self.transcriber

        Task {
            do {
                let result = try await transcriber.transcribeFile(audioPath: path)
                if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try transcriber.persistTranscript(
                        sessionId: sessionId,
                        text: result.text,
                        language: result.language,
                        durationSeconds: result.durationSeconds
                    )
                    Logger.app.info("AudioCapture: transcribed \(result.text.count) chars from \(path)")
                }
            } catch {
                Logger.app.error("AudioCapture: transcription failed: \(error.localizedDescription)")
            }

            // Delete WAV after transcription
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
