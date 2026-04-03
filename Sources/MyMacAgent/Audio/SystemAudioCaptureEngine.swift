import AVFoundation
import CoreAudio
@preconcurrency import ScreenCaptureKit
import os

/// Captures system audio (what plays from speakers) using ScreenCaptureKit.
/// Monitors default output usage and only opens ScreenCaptureKit while another
/// app is actively sending audio to the selected output device.
final class SystemAudioCaptureEngine: NSObject, @unchecked Sendable {
    private let silenceTimeout: TimeInterval = 1.5
    private let signalWarmupWindow: TimeInterval = 2.0
    private let retryCooldownAfterSilence: TimeInterval = 4.0
    private let retryCooldownAfterPermissionFailure: TimeInterval = 30.0
    private let audibleThreshold: Float = 0.003
    private var stream: SCStream?
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
    private var isStartingCapture = false
    private var captureStartedAt: Date?
    private var lastAudibleAt: Date?
    private var hasAudibleSamples = false
    private var retryCaptureAfter = Date.distantPast
    private var audioFormat: AVAudioFormat?
    private var outputDeviceID: AudioDeviceID = 0
    private let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)

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
        guard !isMonitoring else { return }

        do {
            try FileManager.default.createDirectory(atPath: audioDir, withIntermediateDirectories: true)
        } catch {
            logger.error("SystemAudio: failed to create dir: \(error.localizedDescription)")
            return
        }

        guard let deviceID = resolveDefaultOutputDevice() else {
            logger.error("SystemAudio: no default output device")
            return
        }
        outputDeviceID = deviceID

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.statePollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.checkOutputState()
            }
        }

        isMonitoring = true
        logger.info("SystemAudio: monitoring external output usage (device: \(deviceID))")
        checkOutputState()
    }

    func stop() {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        statePollTimer?.invalidate()
        statePollTimer = nil
        isMonitoring = false

        if isCapturing {
            stopCapture(reason: "output went idle")
        }

        logger.info("SystemAudio: monitoring stopped")
    }

    var recording: Bool { isCapturing }

    // MARK: - Output state monitoring

    private func checkOutputState() {
        let now = Date()
        if isCapturing, shouldStopForSilence(now: now) {
            retryCaptureAfter = now.addingTimeInterval(retryCooldownAfterSilence)
            stopCapture(reason: "output became silent")
            return
        }

        let externalOutputInUse = isExternalProcessUsingOutput()
        if externalOutputInUse {
            pendingStopWorkItem?.cancel()
            pendingStopWorkItem = nil
        }

        if externalOutputInUse && !isCapturing && now >= retryCaptureAfter {
            Task { await startCaptureIfNeeded() }
        } else if !externalOutputInUse && isCapturing && pendingStopWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isExternalProcessUsingOutput() else { return }
                self.stopCapture(reason: "output went idle")
            }
            pendingStopWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        }
    }

    private func isExternalProcessUsingOutput() -> Bool {
        let processes = AudioProcessInspector.fetchProcesses()
        if !processes.isEmpty {
            return SystemAudioUsageEvaluator.hasExternalProcessUsingOutputDevice(
                processes,
                outputDeviceID: outputDeviceID,
                currentPID: currentPID
            )
        }

        return !isCapturing && isOutputRunningSomewhere()
    }

    private func resolveDefaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    private func isOutputRunningSomewhere() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(outputDeviceID, &address, 0, nil, &size, &isRunning)
        return status == noErr && isRunning != 0
    }

    // MARK: - Capture control

    private func startCaptureIfNeeded() async {
        guard isMonitoring, !isCapturing, !isStartingCapture else { return }
        guard Date() >= retryCaptureAfter else { return }
        guard CGPreflightScreenCaptureAccess() else {
            retryCaptureAfter = Date().addingTimeInterval(retryCooldownAfterPermissionFailure)
            logger.info("SystemAudio: no screen recording permission, backing off")
            return
        }

        isStartingCapture = true
        defer { isStartingCapture = false }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard isMonitoring else { return }
            guard let display = content.displays.first else {
                logger.error("SystemAudio: no display found")
                return
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()

            config.capturesAudio = true
            config.excludesCurrentProcessAudio = false
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
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
            isCapturing = true
            captureStartedAt = Date()
            lastAudibleAt = nil
            hasAudibleSamples = false

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.segmentTimer = Timer.scheduledTimer(withTimeInterval: self.segmentDuration, repeats: true) { [weak self] _ in
                    self?.rotateSegment()
                }
            }

            logger.info("SystemAudio: external speaker output detected — capture started")
        } catch {
            cleanupCurrentSegmentFile()
            logger.error("SystemAudio: failed to start: \(error.localizedDescription)")
        }
    }

    private func stopCapture(reason: String) {
        guard isCapturing else { return }

        segmentTimer?.invalidate()
        segmentTimer = nil

        if let stream {
            Task { try? await stream.stopCapture() }
            self.stream = nil
        }

        isCapturing = false
        captureStartedAt = nil
        lastAudibleAt = nil

        if let path = currentFilePath {
            currentFile = nil
            currentFilePath = nil
            if hasAudibleSamples {
                transcribeAndCleanup(path: path, source: "system")
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        hasAudibleSamples = false

        logger.info("SystemAudio: \(reason) — capture stopped")
    }

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
        guard isCapturing else { return }
        let oldPath = currentFilePath
        let hadAudibleSamples = hasAudibleSamples
        currentFile = nil
        startNewSegment()
        hasAudibleSamples = false

        if let path = oldPath {
            if hadAudibleSamples {
                transcribeAndCleanup(path: path, source: "system")
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private func cleanupCurrentSegmentFile() {
        currentFile = nil
        if let path = currentFilePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        currentFilePath = nil
        hasAudibleSamples = false
    }

    private func shouldStopForSilence(now: Date) -> Bool {
        if let lastAudibleAt {
            return now.timeIntervalSince(lastAudibleAt) >= silenceTimeout
        }

        if let captureStartedAt {
            return now.timeIntervalSince(captureStartedAt) >= signalWarmupWindow
        }

        return false
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
        isCapturing = false
        segmentTimer?.invalidate()
        segmentTimer = nil
        cleanupCurrentSegmentFile()
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

        let sampleCount = length / MemoryLayout<Float>.size
        if sampleCount > 0 {
            let floatPointer = UnsafeRawPointer(data).assumingMemoryBound(to: Float.self)
            var peak: Float = 0
            for index in 0..<sampleCount {
                peak = max(peak, abs(floatPointer[index]))
            }
            if peak >= audibleThreshold {
                lastAudibleAt = Date()
                hasAudibleSamples = true
            }
        }

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
