enum SessionEventType: String {
    case appActivated = "app_activated"
    case windowChanged = "window_changed"
    case captureTaken = "capture_taken"
    case ocrRequested = "ocr_requested"
    case ocrCompleted = "ocr_completed"
    case axSnapshotTaken = "ax_snapshot_taken"
    case modeChanged = "mode_changed"
    case summaryGenerated = "summary_generated"
    case exportCompleted = "export_completed"
    case idleStarted = "idle_started"
    case idleEnded = "idle_ended"
}

struct SessionEvent {
    let id: Int64
    let sessionId: String
    let eventType: SessionEventType
    let timestamp: String
    let payloadJson: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.intValue,
              let sessionId = row["session_id"]?.textValue,
              let eventTypeStr = row["event_type"]?.textValue,
              let eventType = SessionEventType(rawValue: eventTypeStr),
              let timestamp = row["timestamp"]?.textValue else { return nil }
        self.id = id
        self.sessionId = sessionId
        self.eventType = eventType
        self.timestamp = timestamp
        self.payloadJson = row["payload_json"]?.textValue
    }
}
