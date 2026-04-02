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

    // VAD — voice activity detection
    private let silenceThreshold: Float = 0.01  // RMS below this = silence
    private let silenceTimeout: TimeInterval = 3.0  // seconds of silence before pausing
    private var lastSoundTime: Date = Date()
    private var isCapturing = false  // true when voice detected, false during silence
    private var silentFrames = 0

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

            guard format.sampleRate > 0 else {
                logger.error("AudioCapture: no valid input format")
                return
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.processBuffer(buffer, format: format)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            // Timer to rotate segments
            segmentTimer = Timer.scheduledTimer(withTimeInterval: segmentDuration, repeats: true) { [weak self] _ in
                self?.rotateSegment()
            }

            logger.info("AudioCapture: started with VAD (threshold: \(self.silenceThreshold), timeout: \(self.silenceTimeout)s)")
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
        isCapturing = false

        if let path = currentFilePath {
            currentFile = nil
            transcribeAndCleanup(path: path)
        }

        logger.info("AudioCapture: stopped")
    }

    var recording: Bool { isRecording }

    // MARK: - VAD + Write

    private func processBuffer(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        let rms = computeRMS(buffer)

        if rms > silenceThreshold {
            // Sound detected
            lastSoundTime = Date()
            silentFrames = 0

            if !isCapturing {
                // Start capturing — voice detected after silence
                isCapturing = true
                startNewSegment(format: format)
                logger.info("AudioCapture: voice detected, recording started")
            }

            // Write audio
            if let file = currentFile {
                try? file.write(from: buffer)
            }
        } else {
            // Silence
            silentFrames += 1

            if isCapturing {
                // Still write for a bit during short pauses
                if Date().timeIntervalSince(lastSoundTime) < silenceTimeout {
                    if let file = currentFile {
                        try? file.write(from: buffer)
                    }
                } else {
                    // Silence exceeded timeout — stop capturing
                    isCapturing = false
                    if let path = currentFilePath {
                        currentFile = nil
                        currentFilePath = nil
                        transcribeAndCleanup(path: path)
                        logger.info("AudioCapture: silence detected, segment saved")
                    }
                }
            }
        }
    }

    private func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sum: Float = 0
        let data = channelData[0]
        for i in 0..<frames {
            sum += data[i] * data[i]
        }
        return sqrtf(sum / Float(frames))
    }

    // MARK: - Segments

    private func startNewSegment(format: AVAudioFormat? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "audio_\(timestamp).wav"
        let path = (audioDir as NSString).appendingPathComponent(filename)

        let fmt = format ?? audioEngine.inputNode.outputFormat(forBus: 0)

        do {
            currentFile = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings)
            currentFilePath = path
        } catch {
            logger.error("AudioCapture: failed to create file: \(error.localizedDescription)")
        }
    }

    private func rotateSegment() {
        guard isCapturing, let oldPath = currentFilePath else { return }
        currentFile = nil
        startNewSegment()
        transcribeAndCleanup(path: oldPath)
    }

    private func transcribeAndCleanup(path: String) {
        let sessionId = sessionManager.currentSessionId
        let transcriber = self.transcriber

        Task {
            do {
                let result = try await transcriber.transcribeFile(audioPath: path)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    try transcriber.persistTranscript(
                        sessionId: sessionId,
                        text: text,
                        language: result.language,
                        durationSeconds: result.durationSeconds
                    )
                    Logger.app.info("AudioCapture: transcribed \(text.count) chars")
                }
            } catch {
                Logger.app.error("AudioCapture: transcription failed: \(error.localizedDescription)")
            }

            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
