import AVFoundation
@preconcurrency import ScreenCaptureKit
import os

/// Captures system audio (what plays from speakers) using ScreenCaptureKit.
/// Records in segments, transcribes each via Whisper, then deletes the WAV.
final class SystemAudioCaptureEngine: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var currentFile: AVAudioFile?
    private var currentFilePath: String?
    private var segmentTimer: Timer?
    private let segmentDuration: TimeInterval
    private let audioDir: String
    private let transcriber: AudioTranscriber
    private let sessionManager: SessionManager
    private let logger = Logger.app
    private var isRecording = false
    private var audioFormat: AVAudioFormat?

    init(transcriber: AudioTranscriber, sessionManager: SessionManager,
         segmentDuration: TimeInterval = 300, audioDir: String? = nil) {
        self.transcriber = transcriber
        self.sessionManager = sessionManager
        self.segmentDuration = segmentDuration
        if let dir = audioDir {
            self.audioDir = dir
        } else {
            self.audioDir = AppPaths.systemAudioDirectoryURL().path
        }
        super.init()
    }

    func start() async {
        guard !isRecording else { return }
        guard CGPreflightScreenCaptureAccess() else {
            logger.info("SystemAudio: no screen recording permission, skipping")
            return
        }

        do {
            try FileManager.default.createDirectory(atPath: audioDir, withIntermediateDirectories: true)

            // Get the main display for audio capture
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else {
                logger.error("SystemAudio: no display found")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()

            // Audio only — disable video to save resources
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum (we don't need video)

            // Audio format: 16kHz mono for Whisper compatibility
            config.sampleRate = 48000
            config.channelCount = 1

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false
            ]
            audioFormat = AVAudioFormat(settings: audioSettings)

            startNewSegment()

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()

            self.stream = stream
            isRecording = true

            // Segment rotation timer
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.segmentTimer = Timer.scheduledTimer(withTimeInterval: self.segmentDuration, repeats: true) { [weak self] _ in
                    self?.rotateSegment()
                }
            }

            logger.info("SystemAudio: started capturing (segment: \(Int(self.segmentDuration))s)")
        } catch {
            logger.error("SystemAudio: failed to start: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRecording else { return }

        segmentTimer?.invalidate()
        segmentTimer = nil

        if let stream {
            Task { try? await stream.stopCapture() }
            self.stream = nil
        }

        isRecording = false

        if let path = currentFilePath {
            currentFile = nil
            transcribeAndCleanup(path: path, source: "system")
        }

        logger.info("SystemAudio: stopped")
    }

    var recording: Bool { isRecording }

    // MARK: - Private

    private func startNewSegment() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "system_\(timestamp).wav"
        let path = (audioDir as NSString).appendingPathComponent(filename)

        if let format = audioFormat {
            do {
                currentFile = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: format.settings)
                currentFilePath = path
            } catch {
                logger.error("SystemAudio: failed to create file: \(error.localizedDescription)")
            }
        }
    }

    private func rotateSegment() {
        let oldPath = currentFilePath
        currentFile = nil
        startNewSegment()

        if let path = oldPath {
            transcribeAndCleanup(path: path, source: "system")
        }
    }

    private func transcribeAndCleanup(path: String, source: String) {
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
                        durationSeconds: result.durationSeconds,
                        source: source
                    )
                    Logger.app.info("SystemAudio: transcribed \(text.count) chars")
                }
            } catch {
                Logger.app.error("SystemAudio: transcription failed: \(error.localizedDescription)")
            }

            try? FileManager.default.removeItem(atPath: path)
        }
    }
}

// MARK: - SCStreamDelegate
extension SystemAudioCaptureEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        logger.error("SystemAudio: stream stopped with error: \(error.localizedDescription)")
        isRecording = false
    }
}

// MARK: - SCStreamOutput
extension SystemAudioCaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let file = currentFile else { return }

        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let data = dataPointer, length > 0 else { return }

        let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: asbd.pointee.mSampleRate,
            channels: AVAudioChannelCount(asbd.pointee.mChannelsPerFrame),
            interleaved: asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        )

        guard let format = audioFormat else { return }
        let frameCount = AVAudioFrameCount(length) / format.streamDescription.pointee.mBytesPerFrame

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        pcmBuffer.frameLength = frameCount

        if let dest = pcmBuffer.floatChannelData?[0] {
            memcpy(dest, data, length)
        }

        do {
            try file.write(from: pcmBuffer)
        } catch {
            // Silently skip write errors
        }
    }
}
