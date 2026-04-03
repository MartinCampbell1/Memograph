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
            AudioProcessInfo(pid: currentPID, outputDeviceIDs: [21], isRunningOutput: true),
            AudioProcessInfo(pid: currentPID + 1, outputDeviceIDs: [21], isRunningOutput: true)
        ]

        #expect(
            SystemAudioUsageEvaluator.hasExternalProcessUsingOutputDevice(
                processes,
                outputDeviceID: 21,
                currentPID: currentPID
            )
        )
    }
}
