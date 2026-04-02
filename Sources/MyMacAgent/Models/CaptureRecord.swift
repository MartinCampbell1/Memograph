struct CaptureRecord {
    let id: String
    let sessionId: String
    let timestamp: String
    let captureType: String
    let imagePath: String?
    let thumbPath: String?
    let width: Int?
    let height: Int?
    let fileSizeBytes: Int?
    let visualHash: String?
    let perceptualHash: String?
    let diffScore: Double
    let samplingMode: String?
    let retained: Bool

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let sessionId = row["session_id"]?.textValue,
              let timestamp = row["timestamp"]?.textValue,
              let captureType = row["capture_type"]?.textValue else { return nil }
        self.id = id
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.captureType = captureType
        self.imagePath = row["image_path"]?.textValue
        self.thumbPath = row["thumb_path"]?.textValue
        self.width = row["width"]?.intValue.flatMap { Int(exactly: $0) }
        self.height = row["height"]?.intValue.flatMap { Int(exactly: $0) }
        self.fileSizeBytes = row["file_size_bytes"]?.intValue.flatMap { Int(exactly: $0) }
        self.visualHash = row["visual_hash"]?.textValue
        self.perceptualHash = row["perceptual_hash"]?.textValue
        self.diffScore = row["diff_score"]?.realValue ?? 0
        self.samplingMode = row["sampling_mode"]?.textValue
        self.retained = (row["retained"]?.intValue ?? 1) != 0
    }
}
