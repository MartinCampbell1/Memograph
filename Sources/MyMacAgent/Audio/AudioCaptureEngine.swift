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
    private let segmentDuration: TimeInterval
    private let audioDir: String
    private let transcriber: AudioTranscriber
    private let sessionManager: SessionManager
    private let logger = Logger.app
    private var isMonitoring = false
    private var isCapturing = false
    private var inputDeviceID: AudioDeviceID = 0
    private let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)

    init(transcriber: AudioTranscriber, sessionManager: SessionManager,
         segmentDuration: TimeInterval = 300, audioDir: String? = nil) {
        self.transcriber = transcriber
        self.sessionManager = sessionManager
        self.segmentDuration = segmentDuration
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
        let processes = fetchAudioProcesses()
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

    private func fetchAudioProcesses() -> [AudioProcessInfo] {
        let processObjectIDs = readObjectIDArray(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal
        )

        return processObjectIDs.compactMap { processObjectID in
            guard let pid = readUInt32(
                objectID: processObjectID,
                selector: kAudioProcessPropertyPID
            ) else {
                return nil
            }

            let inputDevices = readObjectIDArray(
                objectID: processObjectID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            )
            let isRunningInput = readUInt32(
                objectID: processObjectID,
                selector: kAudioProcessPropertyIsRunningInput
            ) ?? 0

            return AudioProcessInfo(
                pid: pid_t(pid),
                inputDeviceIDs: inputDevices,
                isRunningInput: isRunningInput != 0
            )
        }
    }

    private func readUInt32(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    private func readObjectIDArray(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &propertySize)
        guard sizeStatus == noErr, propertySize > 0 else {
            return []
        }

        let count = Int(propertySize) / MemoryLayout<AudioObjectID>.size
        var values = Array(repeating: AudioObjectID(0), count: count)
        let readStatus = AudioObjectGetPropertyData(objectID, &address, 0, nil, &propertySize, &values)
        guard readStatus == noErr else {
            return []
        }
        return values
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
                        durationSeconds: result.durationSeconds,
                        source: "microphone"
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
