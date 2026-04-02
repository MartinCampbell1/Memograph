import Testing
@testable import MyMacAgent

struct ModelTests {
    @Test("AppRecord from row")
    func appRecordFromRow() {
        let row: SQLiteRow = [
            "id": .integer(1),
            "bundle_id": .text("com.apple.Safari"),
            "app_name": .text("Safari"),
            "category": .null,
            "created_at": .text("2026-04-02T10:00:00Z")
        ]
        let app = AppRecord(row: row)
        #expect(app != nil)
        #expect(app?.id == 1)
        #expect(app?.bundleId == "com.apple.Safari")
        #expect(app?.appName == "Safari")
        #expect(app?.category == nil)
    }

    @Test("Session from row")
    func sessionFromRow() {
        let row: SQLiteRow = [
            "id": .text("sess-1"), "app_id": .integer(1), "window_id": .integer(2),
            "started_at": .text("2026-04-02T10:00:00Z"), "ended_at": .null,
            "active_duration_ms": .integer(5000), "idle_duration_ms": .integer(0),
            "uncertainty_mode": .text("normal"), "summary_status": .text("pending"),
            "confidence_score": .real(0), "top_topic": .null, "is_ai_related": .integer(0)
        ]
        let session = Session(row: row)
        #expect(session != nil)
        #expect(session?.id == "sess-1")
        #expect(session?.activeDurationMs == 5000)
        #expect(session?.uncertaintyMode == .normal)
    }

    @Test("SessionEventType raw values")
    func sessionEventTypes() {
        #expect(SessionEventType.appActivated.rawValue == "app_activated")
        #expect(SessionEventType.windowChanged.rawValue == "window_changed")
        #expect(SessionEventType.captureTaken.rawValue == "capture_taken")
        #expect(SessionEventType.modeChanged.rawValue == "mode_changed")
        #expect(SessionEventType.idleStarted.rawValue == "idle_started")
        #expect(SessionEventType.idleEnded.rawValue == "idle_ended")
    }

    @Test("UncertaintyMode from string")
    func uncertaintyModes() {
        #expect(UncertaintyMode(rawValue: "normal") == .normal)
        #expect(UncertaintyMode(rawValue: "degraded") == .degraded)
        #expect(UncertaintyMode(rawValue: "high_uncertainty") == .highUncertainty)
        #expect(UncertaintyMode(rawValue: "recovery") == .recovery)
    }

    @Test("CaptureRecord from row")
    func captureRecordFromRow() {
        let row: SQLiteRow = [
            "id": .text("cap-1"), "session_id": .text("sess-1"),
            "timestamp": .text("2026-04-02T10:00:00Z"), "capture_type": .text("window"),
            "image_path": .text("/tmp/cap.png"), "width": .integer(1920),
            "height": .integer(1080), "file_size_bytes": .integer(50000),
            "visual_hash": .text("abc123"), "diff_score": .real(0.05),
            "sampling_mode": .text("normal"), "retained": .integer(1),
            "thumb_path": .null, "perceptual_hash": .null
        ]
        let capture = CaptureRecord(row: row)
        #expect(capture != nil)
        #expect(capture?.id == "cap-1")
        #expect(capture?.width == 1920)
        #expect(capture?.diffScore == 0.05)
    }
}
