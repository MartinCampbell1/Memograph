import Testing
import Foundation
@testable import MyMacAgent

struct AudioCaptureEngineTests {
    @Test("Initializes with default settings")
    func initializes() {
        let db = DatabaseManager.forTesting()
        let transcriber = AudioTranscriber(db: db)
        let session = SessionManager(db: db)
        let engine = AudioCaptureEngine(transcriber: transcriber, sessionManager: session)
        #expect(!engine.recording)
    }

    @Test("Custom segment duration")
    func customDuration() {
        let db = DatabaseManager.forTesting()
        let transcriber = AudioTranscriber(db: db)
        let session = SessionManager(db: db)
        let engine = AudioCaptureEngine(
            transcriber: transcriber,
            sessionManager: session,
            segmentDuration: 60
        )
        #expect(!engine.recording)
    }

    @Test("Custom audio directory")
    func customDir() {
        let db = DatabaseManager.forTesting()
        let transcriber = AudioTranscriber(db: db)
        let session = SessionManager(db: db)
        let tmpDir = NSTemporaryDirectory() + "audio_test_\(UUID().uuidString)"
        let engine = AudioCaptureEngine(
            transcriber: transcriber,
            sessionManager: session,
            audioDir: tmpDir
        )
        #expect(!engine.recording)
    }
}
