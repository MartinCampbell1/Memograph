import AVFoundation
import CoreAudio
import os

/// Captures mic audio ONLY when another app is using the microphone
/// (Zoom, Telegram, Spokenly, WhatsApp, etc.)
/// Uses CoreAudio's kAudioDevicePropertyDeviceIsRunningSomewhere to detect this.
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
    private var isMonitoring = false
    private var isCapturing = false
    private var micInUseListener: AudioObjectPropertyListenerBlock?
    private var inputDeviceID: AudioDeviceID = 0

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

        // Listen for "device is running somewhere" changes
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.checkMicState()
            }
        }
        micInUseListener = listener

        AudioObjectAddPropertyListenerBlock(deviceID, &runningAddress, DispatchQueue.main, listener)

        isMonitoring = true
        logger.info("AudioCapture: monitoring mic usage (device: \(deviceID))")

        // Check initial state
        checkMicState()
    }

    func stop() {
        if isCapturing {
            stopCapture()
        }

        // Remove listener
        if inputDeviceID != 0, let listener = micInUseListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(inputDeviceID, &address, DispatchQueue.main, listener)
        }

        isMonitoring = false
        logger.info("AudioCapture: monitoring stopped")
    }

    var recording: Bool { isCapturing }

    // MARK: - Mic state monitoring

    private func checkMicState() {
        let running = isMicRunning()
        if running && !isCapturing {
            startCapture()
        } else if !running && isCapturing {
            // Small delay — apps sometimes briefly release mic
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, !self.isMicRunning() else { return }
                self.stopCapture()
            }
        }
    }

    private func isMicRunning() -> Bool {
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
                try? file.write(from: buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isCapturing = true

            segmentTimer = Timer.scheduledTimer(withTimeInterval: segmentDuration, repeats: true) { [weak self] _ in
                self?.rotateSegment()
            }

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
            currentFile = nil
            currentFilePath = nil
            transcribeAndCleanup(path: path)
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
        } catch {
            logger.error("AudioCapture: failed to create file: \(error.localizedDescription)")
        }
    }

    private func rotateSegment() {
        guard isCapturing else { return }
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
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    try transcriber.persistTranscript(
                        sessionId: sessionId,
                        text: text,
                        language: result.language,
                        durationSeconds: result.durationSeconds
                    )
                    Logger.app.info("AudioCapture: transcribed \(text.count) chars from mic")
                }
            } catch {
                Logger.app.error("AudioCapture: transcription failed: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
