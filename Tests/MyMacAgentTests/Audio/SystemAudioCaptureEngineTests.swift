import Foundation
import Testing
@testable import MyMacAgent

struct SystemAudioCaptureEngineTests {
    @Test("Initializes with default settings")
    func initializes() {
        let db = DatabaseManager.forTesting()
        let transcriber = AudioTranscriber(db: db)
        let session = SessionManager(db: db)
        let engine = SystemAudioCaptureEngine(transcriber: transcriber, sessionManager: session)
        #expect(!engine.recording)
    }

    @Test("Custom audio directory")
    func customDirectory() {
        let db = DatabaseManager.forTesting()
        let transcriber = AudioTranscriber(db: db)
        let session = SessionManager(db: db)
        let tmpDir = NSTemporaryDirectory() + "system_audio_test_\(UUID().uuidString)"
        let engine = SystemAudioCaptureEngine(
            transcriber: transcriber,
            sessionManager: session,
            audioDir: tmpDir
        )
        #expect(!engine.recording)
    }
}

struct MicrophoneUsageEvaluatorTests {
    @Test("Ignores current process when only our app uses the mic")
    func ignoresCurrentProcess() {
        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let processes = [
            AudioProcessInfo(pid: currentPID, inputDeviceIDs: [11], isRunningInput: true)
        ]

        #expect(
            !MicrophoneUsageEvaluator.hasExternalProcessUsingInputDevice(
                processes,
                inputDeviceID: 11,
                currentPID: currentPID
            )
        )
    }

    @Test("Detects another process on the same input device")
    func detectsExternalProcess() {
        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let processes = [
            AudioProcessInfo(pid: currentPID, inputDeviceIDs: [11], isRunningInput: true),
            AudioProcessInfo(pid: currentPID + 1, inputDeviceIDs: [11], isRunningInput: true)
        ]

        #expect(
            MicrophoneUsageEvaluator.hasExternalProcessUsingInputDevice(
                processes,
                inputDeviceID: 11,
                currentPID: currentPID
            )
        )
    }
}

struct SystemAudioUsageEvaluatorTests {
    @Test("Ignores current process when only our app uses the output device")
    func ignoresCurrentProcess() {
        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let processes = [
            AudioProcessInfo(pid: currentPID, outputDeviceIDs: [21], isRunningOutput: true)
        ]

        #expect(
            !SystemAudioUsageEvaluator.hasExternalProcessUsingOutputDevice(
                processes,
                outputDeviceID: 21,
                currentPID: currentPID
            )
        )
    }

    @Test("Detects another process on the same output device")
    func detectsExternalProcess() {
        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let processes = [
            AudioProcessInfo(pid: currentPID, bundleID: "com.memograph.app", outputDeviceIDs: [21], isRunningOutput: true),
            AudioProcessInfo(pid: currentPID + 1, bundleID: "com.apple.Safari", outputDeviceIDs: [21], isRunningOutput: true)
        ]

        #expect(
            SystemAudioUsageEvaluator.hasExternalProcessUsingOutputDevice(
                processes,
                outputDeviceID: 21,
                currentPID: currentPID
            )
        )
    }

    @Test("Ignores output helpers without bundle identifiers")
    func ignoresUnbundledHelpers() {
        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let processes = [
            AudioProcessInfo(pid: currentPID + 1, bundleID: nil, outputDeviceIDs: [21], isRunningOutput: true)
        ]

        #expect(
            !SystemAudioUsageEvaluator.hasExternalProcessUsingOutputDevice(
                processes,
                outputDeviceID: 21,
                currentPID: currentPID
            )
        )
    }

    @Test("Canonical output signature is stable across helper pid churn")
    func canonicalSignatureUsesBundleIDs() {
        let currentPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let processes = [
            AudioProcessInfo(pid: currentPID + 10, bundleID: "com.apple.WebKit.GPU", outputDeviceIDs: [21], isRunningOutput: true),
            AudioProcessInfo(pid: currentPID + 11, bundleID: "com.apple.WebKit.GPU", outputDeviceIDs: [21], isRunningOutput: true),
            AudioProcessInfo(pid: currentPID + 12, bundleID: nil, outputDeviceIDs: [21], isRunningOutput: true)
        ]

        #expect(
            SystemAudioUsageEvaluator.canonicalSignature(
                processes,
                outputDeviceID: 21,
                currentPID: currentPID
            ) == "com.apple.WebKit.GPU"
        )
    }

    @Test("Low-confidence helper signature maps back to the foreground app")
    func helperSignatureMapsToForegroundApp() {
        #expect(SystemAudioUsageEvaluator.isLowConfidenceSignature("com.apple.WebKit.GPU"))
        #expect(
            SystemAudioUsageEvaluator.hasFrontmostAffinity(
                "com.apple.WebKit.GPU",
                frontmostBundleID: "com.apple.Safari"
            )
        )
        #expect(
            !SystemAudioUsageEvaluator.hasFrontmostAffinity(
                "com.apple.WebKit.GPU",
                frontmostBundleID: "com.openai.codex"
            )
        )
    }

    @Test("Suppresses repeated probe for the same silent renderer signature")
    func suppressesRepeatedProbeForSameSignature() {
        let now = Date()

        #expect(
            !SystemAudioProbePolicy.shouldAttemptCapture(
                now: now,
                hasExternalOutput: true,
                phase: .idle,
                retryCaptureAfter: .distantPast,
                stableOutputObservedSince: now.addingTimeInterval(-5),
                minimumStableObservation: 3,
                outputSignature: "com.apple.WebKit.GPU",
                isLowConfidenceOutput: false,
                hasFrontmostAffinity: false,
                suppressedSilentSignature: "com.apple.WebKit.GPU",
                requiresSilentSignatureReset: true,
                knownAudibleSignatures: [],
                globalSilentCooldownUntil: .distantPast
            )
        )
    }

    @Test("Allows probe when renderer signature changes")
    func allowsProbeWhenSignatureChanges() {
        let now = Date()

        #expect(
            SystemAudioProbePolicy.shouldAttemptCapture(
                now: now,
                hasExternalOutput: true,
                phase: .idle,
                retryCaptureAfter: .distantPast,
                stableOutputObservedSince: now.addingTimeInterval(-5),
                minimumStableObservation: 3,
                outputSignature: "com.apple.Safari",
                isLowConfidenceOutput: false,
                hasFrontmostAffinity: false,
                suppressedSilentSignature: "com.apple.WebKit.GPU",
                requiresSilentSignatureReset: true,
                knownAudibleSignatures: [],
                globalSilentCooldownUntil: .distantPast
            )
        )
    }

    @Test("Keeps silent signatures blocked until they re-arm")
    func keepsSilentSignaturesBlockedUntilRearm() {
        let now = Date()

        #expect(
            !SystemAudioProbePolicy.shouldAttemptCapture(
                now: now,
                hasExternalOutput: true,
                phase: .idle,
                retryCaptureAfter: .distantPast,
                stableOutputObservedSince: now.addingTimeInterval(-5),
                minimumStableObservation: 3,
                outputSignature: "com.apple.WebKit.GPU",
                isLowConfidenceOutput: false,
                hasFrontmostAffinity: false,
                suppressedSilentSignature: "com.apple.WebKit.GPU",
                requiresSilentSignatureReset: true,
                knownAudibleSignatures: [],
                globalSilentCooldownUntil: .distantPast
            )
        )
    }

    @Test("Requires a stable output observation before probing")
    func requiresStableOutputObservation() {
        let now = Date()

        #expect(
            !SystemAudioProbePolicy.shouldAttemptCapture(
                now: now,
                hasExternalOutput: true,
                phase: .idle,
                retryCaptureAfter: .distantPast,
                stableOutputObservedSince: now.addingTimeInterval(-1),
                minimumStableObservation: 3,
                outputSignature: "com.apple.WebKit.GPU",
                isLowConfidenceOutput: false,
                hasFrontmostAffinity: false,
                suppressedSilentSignature: nil,
                requiresSilentSignatureReset: false,
                knownAudibleSignatures: [],
                globalSilentCooldownUntil: .distantPast
            )
        )
    }

    @Test("Honors a global silent cooldown even if signature changes")
    func honorsGlobalSilentCooldown() {
        let now = Date()

        #expect(
            !SystemAudioProbePolicy.shouldAttemptCapture(
                now: now,
                hasExternalOutput: true,
                phase: .idle,
                retryCaptureAfter: .distantPast,
                stableOutputObservedSince: now.addingTimeInterval(-5),
                minimumStableObservation: 3,
                outputSignature: "com.apple.Safari",
                isLowConfidenceOutput: false,
                hasFrontmostAffinity: false,
                suppressedSilentSignature: "com.apple.WebKit.GPU",
                requiresSilentSignatureReset: false,
                knownAudibleSignatures: [],
                globalSilentCooldownUntil: now.addingTimeInterval(10)
            )
        )
    }

    @Test("Allows known audible signature after cooldown once phase is idle")
    func allowsKnownAudibleSignature() {
        let now = Date()

        #expect(
            SystemAudioProbePolicy.shouldAttemptCapture(
                now: now,
                hasExternalOutput: true,
                phase: .idle,
                retryCaptureAfter: .distantPast,
                stableOutputObservedSince: now.addingTimeInterval(-12),
                minimumStableObservation: 3,
                outputSignature: "com.apple.Safari",
                isLowConfidenceOutput: false,
                hasFrontmostAffinity: false,
                suppressedSilentSignature: "com.apple.WebKit.GPU",
                requiresSilentSignatureReset: true,
                knownAudibleSignatures: ["com.apple.Safari"],
                globalSilentCooldownUntil: .distantPast
            )
        )
    }

    @Test("Blocks low-confidence helper output when the owning app is not foreground")
    func blocksLowConfidenceBackgroundHelper() {
        let now = Date()

        #expect(
            !SystemAudioProbePolicy.shouldAttemptCapture(
                now: now,
                hasExternalOutput: true,
                phase: .idle,
                retryCaptureAfter: .distantPast,
                stableOutputObservedSince: now.addingTimeInterval(-20),
                minimumStableObservation: 3,
                outputSignature: "com.apple.WebKit.GPU",
                isLowConfidenceOutput: true,
                hasFrontmostAffinity: false,
                suppressedSilentSignature: nil,
                requiresSilentSignatureReset: false,
                knownAudibleSignatures: [],
                globalSilentCooldownUntil: .distantPast
            )
        )
    }

    @Test("Allows low-confidence helper output once the owning app is foreground")
    func allowsLowConfidenceForegroundHelper() {
        let now = Date()

        #expect(
            SystemAudioProbePolicy.shouldAttemptCapture(
                now: now,
                hasExternalOutput: true,
                phase: .idle,
                retryCaptureAfter: .distantPast,
                stableOutputObservedSince: now.addingTimeInterval(-20),
                minimumStableObservation: 3,
                outputSignature: "com.apple.WebKit.GPU",
                isLowConfidenceOutput: true,
                hasFrontmostAffinity: true,
                suppressedSilentSignature: nil,
                requiresSilentSignatureReset: false,
                knownAudibleSignatures: [],
                globalSilentCooldownUntil: .distantPast
            )
        )
    }
}
