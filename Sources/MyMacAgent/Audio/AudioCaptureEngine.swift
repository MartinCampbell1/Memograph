import AVFoundation
import CoreAudio
import os

/// Captures mic audio ONLY when another app is using the microphone
/// (Zoom, Telegram, Spokenly, WhatsApp, etc.).
/// It inspects CoreAudio client process objects so we do not mistake our own
/// AVAudioEngine input tap for external microphone usage.
final class AudioCaptureEngine: @unchecked Sendable {
    private let audioEngine = AVAudioEngine()
    private var currentFile: AVAudioFile?
    private var currentFilePath: String?
    private var segmentTimer: Timer?
    private var statePollTimer: Timer?
    private var pendingStopWorkItem: DispatchWorkItem?
    private let minimumSegmentDuration: TimeInterval
    private let maximumSegmentDuration: TimeInterval
    private let audioDir: String
    private let transcriber: AudioTranscriber
    private let sessionManager: SessionManager
    private let logger = Logger.app
    private var isMonitoring = false
    private var isCapturing = false
    private var currentSegmentStartedAt: Date?
    private var lastSpeechActivityAt: Date?
    private var inputDeviceID: AudioDeviceID = 0
    private let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
    private let speechActivityThreshold: Float = 0.01
    private let recentSpeechWindow: TimeInterval = 2.5
    private let adaptiveSegmentStep: TimeInterval = 5.0

    init(transcriber: AudioTranscriber, sessionManager: SessionManager,
         segmentDuration: TimeInterval = 75, audioDir: String? = nil) {
        self.transcriber = transcriber
        self.sessionManager = sessionManager
        let clampedDuration = max(60, min(segmentDuration, 90))
        self.minimumSegmentDuration = min(60, clampedDuration)
        self.maximumSegmentDuration = clampedDuration
        if let dir = audioDir {
            self.audioDir = dir
        } else {
            self.audioDir = AppPaths.audioDirectoryURL().path
        }
    }

    /// Start monitoring — does NOT record until another app uses the mic
    func start() {
        guard !isMonitoring else { return }

        do {
            try FileManager.default.createDirectory(atPath: audioDir, withIntermediateDirectories: true)
        } catch {
            logger.error("AudioCapture: failed to create dir: \(error.localizedDescription)")
            return
        }

        // Get default input device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            logger.error("AudioCapture: no default input device")
            return
        }
        inputDeviceID = deviceID

        statePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkMicState()
        }

        isMonitoring = true
        logger.info("AudioCapture: monitoring external mic usage (device: \(deviceID))")

        // Check initial state
        checkMicState()
    }

    func stop() {
        if isCapturing {
            stopCapture()
        }

        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        statePollTimer?.invalidate()
        statePollTimer = nil

        isMonitoring = false
        logger.info("AudioCapture: monitoring stopped")
    }

    var recording: Bool { isCapturing }

    // MARK: - Mic state monitoring

    private func checkMicState() {
        let externalMicInUse = isExternalProcessUsingMic()
        if externalMicInUse {
            pendingStopWorkItem?.cancel()
            pendingStopWorkItem = nil
        }

        if externalMicInUse && !isCapturing {
            startCapture()
        } else if !externalMicInUse && isCapturing && pendingStopWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isExternalProcessUsingMic() else { return }
                self.stopCapture()
            }
            pendingStopWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        }
    }

    private func isExternalProcessUsingMic() -> Bool {
        let processes = AudioProcessInspector.fetchProcesses()
        if !processes.isEmpty {
            return MicrophoneUsageEvaluator.hasExternalProcessUsingInputDevice(
                processes,
                inputDeviceID: inputDeviceID,
                currentPID: currentPID
            )
        }

        // Fallback for environments where process inspection is unavailable.
        return !isCapturing && isMicRunningSomewhere()
    }

    private func isMicRunningSomewhere() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(inputDeviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }
    // MARK: - Capture control

    private func startCapture() {
        guard !isCapturing else { return }

        do {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else { return }

            startNewSegment(format: format)

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self, let file = self.currentFile else { return }
                self.noteSpeechActivityIfNeeded(buffer)
                try? file.write(from: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isCapturing = true

            scheduleSegmentEvaluationTimer(after: minimumSegmentDuration)

            logger.info("AudioCapture: another app is using mic — recording started")
        } catch {
            logger.error("AudioCapture: failed to start: \(error.localizedDescription)")
        }
    }

    private func stopCapture() {
        guard isCapturing else { return }

        segmentTimer?.invalidate()
        segmentTimer = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isCapturing = false

        if let path = currentFilePath {
            let segmentStart = currentSegmentStartedAt ?? Date()
            let segmentEnd = Date()
            currentFile = nil
            currentFilePath = nil
            currentSegmentStartedAt = nil
            queueTranscription(path: path, segmentStartedAt: segmentStart, segmentEndedAt: segmentEnd)
        }

        logger.info("AudioCapture: mic released by other apps — recording stopped")
    }

    // MARK: - Segments

    private func startNewSegment(format: AVAudioFormat? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let filename = "mic_\(timestamp).wav"
        let path = (audioDir as NSString).appendingPathComponent(filename)

        let fmt = format ?? audioEngine.inputNode.outputFormat(forBus: 0)

        do {
            currentFile = try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: fmt.settings)
            currentFilePath = path
            currentSegmentStartedAt = Date()
            lastSpeechActivityAt = nil
        } catch {
            logger.error("AudioCapture: failed to create file: \(error.localizedDescription)")
        }
    }

    private func rotateSegment() {
        guard isCapturing else { return }
        let oldPath = currentFilePath
        let segmentStart = currentSegmentStartedAt ?? Date()
        let segmentEnd = Date()
        currentFile = nil
        startNewSegment()
        if let path = oldPath {
            queueTranscription(path: path, segmentStartedAt: segmentStart, segmentEndedAt: segmentEnd)
        }
        scheduleSegmentEvaluationTimer(after: minimumSegmentDuration)
    }

    private func scheduleSegmentEvaluationTimer(after delay: TimeInterval) {
        segmentTimer?.invalidate()
        segmentTimer = Timer.scheduledTimer(withTimeInterval: max(1, delay), repeats: false) { [weak self] _ in
            self?.evaluateSegmentRotation()
        }
    }

    private func evaluateSegmentRotation() {
        guard isCapturing, let segmentStart = currentSegmentStartedAt else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(segmentStart)
        let hasRecentSpeech = lastSpeechActivityAt.map {
            now.timeIntervalSince($0) <= recentSpeechWindow
        } ?? false

        if elapsed >= maximumSegmentDuration || (elapsed >= minimumSegmentDuration && hasRecentSpeech) {
            rotateSegment()
            return
        }

        let remaining = max(1, maximumSegmentDuration - elapsed)
        scheduleSegmentEvaluationTimer(after: min(adaptiveSegmentStep, remaining))
    }

    private func noteSpeechActivityIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard peakAmplitude(in: buffer) >= speechActivityThreshold else { return }
        lastSpeechActivityAt = Date()
    }

    private func peakAmplitude(in buffer: AVAudioPCMBuffer) -> Float {
        if let channelData = buffer.floatChannelData {
            let frameLength = Int(buffer.frameLength)
            var peak: Float = 0
            for index in 0..<frameLength {
                peak = max(peak, abs(channelData[0][index]))
            }
            return peak
        }

        if let channelData = buffer.int16ChannelData {
            let frameLength = Int(buffer.frameLength)
            var peak: Float = 0
            for index in 0..<frameLength {
                peak = max(peak, Float(abs(channelData[0][index])) / Float(Int16.max))
            }
            return peak
        }

        return 0
    }

    private func queueTranscription(path: String, segmentStartedAt: Date, segmentEndedAt: Date) {
        let sessionId = sessionManager.currentSessionId
        let transcriber = self.transcriber

        Task {
            do {
                try transcriber.enqueueTranscriptionJob(
                    path: path,
                    sessionId: sessionId,
                    source: "microphone",
                    segmentStartedAt: segmentStartedAt,
                    segmentEndedAt: segmentEndedAt
                )
                let completed = try await transcriber.drainQueuedTranscriptions(limit: 1)
                if completed > 0 {
                    Logger.app.info("AudioCapture: drained \(completed) queued mic segment(s)")
                }
            } catch {
                Logger.app.error("AudioCapture: failed to queue transcription: \(error.localizedDescription)")
            }
        }
    }
}
