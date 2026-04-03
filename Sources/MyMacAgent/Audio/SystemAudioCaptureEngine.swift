import AVFoundation
import CoreAudio
@preconcurrency import ScreenCaptureKit
import os

enum SystemAudioCapturePhase: Equatable {
    case idle
    case arming
    case capturing
    case stopping
    case backingOff
}

/// Captures system audio (what plays from speakers) using ScreenCaptureKit.
/// Monitors default output usage and only opens ScreenCaptureKit while another
/// app is actively sending audio to the selected output device.
final class SystemAudioCaptureEngine: NSObject, @unchecked Sendable {
    private struct OutputObservation {
        let hasExternalOutput: Bool
        let signature: String?
    }

    private let silenceTimeout: TimeInterval = 1.5
    private let signalWarmupWindow: TimeInterval = 2.0
    private let minimumStableObservationBeforeProbe: TimeInterval = 10.0
    private let retryCooldownAfterSilence: TimeInterval = 4.0
    private let retryCooldownAfterPermissionFailure: TimeInterval = 30.0
    private let retryCooldownAfterSilentRenderer: TimeInterval = 90.0
    private let retryCooldownAfterError: TimeInterval = 12.0
    private let audibleThreshold: Float = 0.003
    private let stateQueueKey = DispatchSpecificKey<Void>()
    private lazy var stateQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.memograph.system-audio.state")
        queue.setSpecific(key: stateQueueKey, value: ())
        return queue
    }()
    private var stream: SCStream?
    private var currentFile: AVAudioFile?
    private var currentFilePath: String?
    private var segmentTimer: DispatchSourceTimer?
    private var statePollTimer: DispatchSourceTimer?
    private var pendingStopWorkItem: DispatchWorkItem?
    private let segmentDuration: TimeInterval
    private let audioDir: String
    private let transcriber: AudioTranscriber
    private let sessionManager: SessionManager
    private let logger = Logger.app
    private var isMonitoring = false
    private var phase: SystemAudioCapturePhase = .idle
    private var captureStartedAt: Date?
    private var lastAudibleAt: Date?
    private var hasAudibleSamples = false
    private var retryCaptureAfter = Date.distantPast
    private var suppressedSilentSignature: String?
    private var requiresSilentSignatureReset = false
    private var globalSilentCooldownUntil = Date.distantPast
    private var stableOutputSignature: String?
    private var stableOutputObservedSince: Date?
    private var audioFormat: AVAudioFormat?
    private var outputDeviceID: AudioDeviceID = 0
    private var currentCandidateSignature: String?
    private var knownAudibleSignatures = Set<String>()
    private var awaitingStreamShutdown = false
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
        await withStateQueue {
            self.startMonitoringLocked()
        }
    }

    func stop() {
        stateQueue.async {
            self.stopMonitoringLocked()
        }
    }

    var recording: Bool {
        syncOnStateQueue {
            phase == .capturing
        }
    }

    // MARK: - Output state monitoring

    private func startMonitoringLocked() {
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
        retryCaptureAfter = .distantPast
        globalSilentCooldownUntil = .distantPast
        stableOutputSignature = nil
        stableOutputObservedSince = nil
        currentCandidateSignature = nil
        knownAudibleSignatures.removeAll()
        clearSilentSignatureSuppression()
        isMonitoring = true
        phase = .idle
        scheduleStatePollTimerLocked()

        logger.info("SystemAudio: monitoring external output usage (device: \(deviceID))")
        checkOutputStateLocked()
    }

    private func stopMonitoringLocked() {
        guard isMonitoring || phase != .idle else { return }

        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        cancelTimer(&statePollTimer)
        isMonitoring = false
        retryCaptureAfter = .distantPast
        globalSilentCooldownUntil = .distantPast

        if phase == .capturing || phase == .arming || phase == .backingOff {
            stopCaptureLocked(reason: "monitoring stopped", backoffUntil: .distantPast)
        } else if phase == .stopping {
            logger.info("SystemAudio: stop requested while shutdown already in progress")
        } else {
            cleanupCurrentSegmentFile()
            phase = .idle
        }

        logger.info("SystemAudio: monitoring stopped")
    }

    private func checkOutputStateLocked() {
        let now = Date()
        if phase == .backingOff, now >= retryCaptureAfter {
            phase = .idle
        }

        refreshOutputDeviceIfNeeded()
        let observation = currentOutputObservation()
        updateSilentCandidateRearm(observation)
        updateStableOutputObservation(observation, now: now)

        if phase == .capturing, shouldStopForSilence(now: now) {
            let signature = currentCandidateSignature ?? observation.signature
            let isKnownAudibleSignature = signature.map { knownAudibleSignatures.contains($0) } ?? false

            retryCaptureAfter = now.addingTimeInterval(retryCooldownAfterSilence)
            if !hasAudibleSamples && !isKnownAudibleSignature {
                globalSilentCooldownUntil = now.addingTimeInterval(retryCooldownAfterSilentRenderer)
                if let signature {
                    suppressedSilentSignature = signature
                    requiresSilentSignatureReset = true
                }
            }

            stopCaptureLocked(reason: "output became silent", backoffUntil: retryCaptureAfter)
            return
        }

        let externalOutputInUse = observation.hasExternalOutput
        if externalOutputInUse {
            pendingStopWorkItem?.cancel()
            pendingStopWorkItem = nil
        }

        if SystemAudioProbePolicy.shouldAttemptCapture(
            now: now,
            hasExternalOutput: externalOutputInUse,
            phase: phase,
            retryCaptureAfter: retryCaptureAfter,
            stableOutputObservedSince: stableOutputObservedSince,
            minimumStableObservation: minimumStableObservationBeforeProbe,
            outputSignature: observation.signature,
            suppressedSilentSignature: suppressedSilentSignature,
            requiresSilentSignatureReset: requiresSilentSignatureReset,
            knownAudibleSignatures: knownAudibleSignatures,
            globalSilentCooldownUntil: globalSilentCooldownUntil
        ) {
            requestCaptureStartLocked(observation: observation)
        } else if !externalOutputInUse && phase == .capturing && pendingStopWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.checkIdleStopLocked()
            }
            pendingStopWorkItem = workItem
            stateQueue.asyncAfter(deadline: .now() + 1.5, execute: workItem)
        }
    }

    private func checkIdleStopLocked() {
        pendingStopWorkItem = nil
        guard !isExternalProcessUsingOutput() else { return }
        stopCaptureLocked(reason: "output went idle", backoffUntil: .distantPast)
    }

    private func isExternalProcessUsingOutput() -> Bool {
        currentOutputObservation().hasExternalOutput
    }

    private func currentOutputObservation() -> OutputObservation {
        let processes = AudioProcessInspector.fetchProcesses()
        if !processes.isEmpty {
            let hasExternalOutput = SystemAudioUsageEvaluator.hasExternalProcessUsingOutputDevice(
                processes,
                outputDeviceID: outputDeviceID,
                currentPID: currentPID
            )
            let signature = SystemAudioUsageEvaluator.canonicalSignature(
                processes,
                outputDeviceID: outputDeviceID,
                currentPID: currentPID
            )

            return OutputObservation(
                hasExternalOutput: hasExternalOutput,
                signature: signature
            )
        }

        return OutputObservation(hasExternalOutput: false, signature: nil)
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

    // MARK: - Capture control

    private func requestCaptureStartLocked(observation: OutputObservation) {
        guard isMonitoring, phase == .idle else { return }
        guard Date() >= retryCaptureAfter else {
            phase = .backingOff
            return
        }
        guard let candidateSignature = observation.signature else { return }
        guard CGPreflightScreenCaptureAccess() else {
            retryCaptureAfter = Date().addingTimeInterval(retryCooldownAfterPermissionFailure)
            phase = .backingOff
            logger.info("SystemAudio: no screen recording permission, backing off")
            return
        }

        phase = .arming
        currentCandidateSignature = candidateSignature
        captureStartedAt = Date()
        lastAudibleAt = nil
        hasAudibleSamples = false
        audioFormat = makeCaptureAudioFormat()
        startNewSegment()

        logger.info("SystemAudio: arming capture for signature \(candidateSignature, privacy: .public)")

        Task { [weak self] in
            guard let self else { return }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    await self.withStateQueue {
                        self.failCaptureStartLocked(
                            reason: "no display found",
                            backoffUntil: Date().addingTimeInterval(self.retryCooldownAfterError)
                        )
                    }
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.width = 2
                config.height = 2
                config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                config.sampleRate = 48000
                config.channelCount = 1

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.stateQueue)

                let shouldProceed = await self.withStateQueue { () -> Bool in
                    guard self.isMonitoring,
                          self.phase == .arming,
                          self.currentCandidateSignature == candidateSignature else {
                        return false
                    }
                    self.stream = stream
                    return true
                }
                guard shouldProceed else {
                    try? await stream.stopCapture()
                    return
                }

                try await stream.startCapture()
                await self.withStateQueue {
                    self.completeCaptureStartLocked(signature: candidateSignature)
                }
            } catch {
                await self.withStateQueue {
                    self.failCaptureStartLocked(
                        reason: error.localizedDescription,
                        backoffUntil: Date().addingTimeInterval(self.retryCooldownAfterError)
                    )
                }
            }
        }
    }

    private func completeCaptureStartLocked(signature: String) {
        guard phase == .arming, currentCandidateSignature == signature else { return }
        phase = .capturing
        captureStartedAt = Date()
        lastAudibleAt = nil
        hasAudibleSamples = false
        scheduleSegmentTimerLocked()
        logger.info("SystemAudio: capture started for signature \(signature, privacy: .public)")
    }

    private func failCaptureStartLocked(reason: String, backoffUntil: Date) {
        stream = nil
        retryCaptureAfter = max(retryCaptureAfter, backoffUntil)
        phase = .backingOff
        captureStartedAt = nil
        currentCandidateSignature = nil
        cleanupCurrentSegmentFile()
        logger.error("SystemAudio: failed to start: \(reason)")
    }

    private func stopCaptureLocked(reason: String, backoffUntil: Date) {
        guard phase == .capturing || phase == .arming || phase == .backingOff else { return }

        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        cancelTimer(&segmentTimer)

        let capturedStream = stream
        stream = nil
        let path = currentFilePath
        let shouldPersistAudibleSegment = hasAudibleSamples

        currentFile = nil
        currentFilePath = nil
        captureStartedAt = nil
        lastAudibleAt = nil
        hasAudibleSamples = false
        retryCaptureAfter = max(retryCaptureAfter, backoffUntil)

        if let path {
            if shouldPersistAudibleSegment {
                transcribeAndCleanup(path: path, source: "system")
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        }

        currentCandidateSignature = nil
        phase = .stopping

        guard let capturedStream else {
            finishStreamShutdownLocked()
            logger.info("SystemAudio: \(reason) — capture stopped")
            return
        }

        awaitingStreamShutdown = true
        Task { [weak self] in
            guard let self else { return }
            try? await capturedStream.stopCapture()
            await self.withStateQueue {
                self.finishStreamShutdownLocked()
            }
        }

        logger.info("SystemAudio: \(reason) — stopping active stream")
    }

    // MARK: - Private

    private func makeCaptureAudioFormat() -> AVAudioFormat? {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        return AVAudioFormat(settings: audioSettings)
    }

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
        guard phase == .capturing else { return }
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

    private func clearSilentSignatureSuppression() {
        suppressedSilentSignature = nil
        requiresSilentSignatureReset = false
    }

    private func refreshOutputDeviceIfNeeded() {
        guard let deviceID = resolveDefaultOutputDevice(), deviceID != outputDeviceID else {
            return
        }

        outputDeviceID = deviceID
        stableOutputSignature = nil
        stableOutputObservedSince = nil
        retryCaptureAfter = .distantPast
        globalSilentCooldownUntil = .distantPast
        currentCandidateSignature = nil
        knownAudibleSignatures.removeAll()
        clearSilentSignatureSuppression()
        logger.info("SystemAudio: switched to output device \(deviceID)")
    }

    private func updateSilentCandidateRearm(_ observation: OutputObservation) {
        guard requiresSilentSignatureReset else { return }
        guard let suppressedSilentSignature else {
            clearSilentSignatureSuppression()
            return
        }

        if !observation.hasExternalOutput || observation.signature != suppressedSilentSignature {
            clearSilentSignatureSuppression()
        }
    }

    private func updateStableOutputObservation(_ observation: OutputObservation, now: Date) {
        guard observation.hasExternalOutput else {
            stableOutputSignature = nil
            stableOutputObservedSince = nil
            return
        }

        let signature = observation.signature ?? "device-\(outputDeviceID)"
        if stableOutputSignature == signature {
            return
        }

        stableOutputSignature = signature
        stableOutputObservedSince = now
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

    private func scheduleStatePollTimerLocked() {
        cancelTimer(&statePollTimer)
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkOutputStateLocked()
        }
        timer.resume()
        statePollTimer = timer
    }

    private func scheduleSegmentTimerLocked() {
        cancelTimer(&segmentTimer)
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + segmentDuration, repeating: segmentDuration)
        timer.setEventHandler { [weak self] in
            self?.rotateSegment()
        }
        timer.resume()
        segmentTimer = timer
    }

    private func finishStreamShutdownLocked() {
        if awaitingStreamShutdown {
            awaitingStreamShutdown = false
        }

        phase = Date() >= retryCaptureAfter ? .idle : .backingOff
    }

    private func markAudibleSampleDetected(now: Date) {
        lastAudibleAt = now
        if !hasAudibleSamples, let signature = currentCandidateSignature {
            knownAudibleSignatures.insert(signature)
        }
        hasAudibleSamples = true
    }

    private func cancelTimer(_ timer: inout DispatchSourceTimer?) {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    private func syncOnStateQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil {
            return body()
        }
        return stateQueue.sync(execute: body)
    }

    private func withStateQueue<T>(_ body: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            stateQueue.async {
                continuation.resume(returning: body())
            }
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
        stateQueue.async {
            self.logger.error("SystemAudio: stream stopped with error: \(error.localizedDescription)")
            self.retryCaptureAfter = max(self.retryCaptureAfter, Date().addingTimeInterval(self.retryCooldownAfterError))

            if self.phase != .stopping {
                self.stopCaptureLocked(reason: "stream error", backoffUntil: self.retryCaptureAfter)
            } else {
                self.finishStreamShutdownLocked()
            }
        }
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
                markAudibleSampleDetected(now: Date())
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
