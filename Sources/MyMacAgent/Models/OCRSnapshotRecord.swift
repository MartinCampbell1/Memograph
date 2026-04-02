import Foundation

struct OCRSnapshotRecord {
    let id: String
    let sessionId: String
    let captureId: String
    let timestamp: String
    let provider: String
    let rawText: String?
    let normalizedText: String?
    let textHash: String?
    let confidence: Double
    let language: String?
    let processingMs: Int?
    let extractionStatus: String?

    var hasUsableText: Bool { confidence >= 0.3 && (normalizedText?.count ?? 0) > 0 }

    init(id: String, sessionId: String, captureId: String, timestamp: String,
         provider: String, rawText: String?, normalizedText: String?,
         textHash: String?, confidence: Double, language: String?,
         processingMs: Int?, extractionStatus: String?) {
        self.id = id; self.sessionId = sessionId; self.captureId = captureId
        self.timestamp = timestamp; self.provider = provider; self.rawText = rawText
        self.normalizedText = normalizedText; self.textHash = textHash
        self.confidence = confidence; self.language = language
        self.processingMs = processingMs; self.extractionStatus = extractionStatus
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let sessionId = row["session_id"]?.textValue,
              let captureId = row["capture_id"]?.textValue,
              let timestamp = row["timestamp"]?.textValue,
              let provider = row["provider"]?.textValue else { return nil }
        self.id = id; self.sessionId = sessionId; self.captureId = captureId
        self.timestamp = timestamp; self.provider = provider
        self.rawText = row["raw_text"]?.textValue
        self.normalizedText = row["normalized_text"]?.textValue
        self.textHash = row["text_hash"]?.textValue
        self.confidence = row["confidence"]?.realValue ?? 0
        self.language = row["language"]?.textValue
        self.processingMs = row["processing_ms"]?.intValue.flatMap { Int($0) }
        self.extractionStatus = row["extraction_status"]?.textValue
    }
}
