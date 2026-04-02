import Foundation

struct ContextSnapshotRecord {
    let id: String
    let sessionId: String
    let timestamp: String
    let appName: String?
    let bundleId: String?
    let windowTitle: String?
    let textSource: String?
    let mergedText: String?
    let mergedTextHash: String?
    let topicHint: String?
    let readableScore: Double
    let uncertaintyScore: Double
    let sourceCaptureId: String?
    let sourceAxId: String?
    let sourceOcrId: String?

    init(id: String, sessionId: String, timestamp: String,
         appName: String?, bundleId: String?, windowTitle: String?,
         textSource: String?, mergedText: String?, mergedTextHash: String?,
         topicHint: String?, readableScore: Double, uncertaintyScore: Double,
         sourceCaptureId: String?, sourceAxId: String?, sourceOcrId: String?) {
        self.id = id; self.sessionId = sessionId; self.timestamp = timestamp
        self.appName = appName; self.bundleId = bundleId; self.windowTitle = windowTitle
        self.textSource = textSource; self.mergedText = mergedText
        self.mergedTextHash = mergedTextHash; self.topicHint = topicHint
        self.readableScore = readableScore; self.uncertaintyScore = uncertaintyScore
        self.sourceCaptureId = sourceCaptureId; self.sourceAxId = sourceAxId
        self.sourceOcrId = sourceOcrId
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let sessionId = row["session_id"]?.textValue,
              let timestamp = row["timestamp"]?.textValue else { return nil }
        self.id = id; self.sessionId = sessionId; self.timestamp = timestamp
        self.appName = row["app_name"]?.textValue
        self.bundleId = row["bundle_id"]?.textValue
        self.windowTitle = row["window_title"]?.textValue
        self.textSource = row["text_source"]?.textValue
        self.mergedText = row["merged_text"]?.textValue
        self.mergedTextHash = row["merged_text_hash"]?.textValue
        self.topicHint = row["topic_hint"]?.textValue
        self.readableScore = row["readable_score"]?.realValue ?? 0
        self.uncertaintyScore = row["uncertainty_score"]?.realValue ?? 0
        self.sourceCaptureId = row["source_capture_id"]?.textValue
        self.sourceAxId = row["source_ax_id"]?.textValue
        self.sourceOcrId = row["source_ocr_id"]?.textValue
    }
}
