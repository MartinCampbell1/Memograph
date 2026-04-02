import Foundation

struct AXSnapshotRecord {
    let id: String
    let sessionId: String
    let captureId: String?
    let timestamp: String
    let focusedRole: String?
    let focusedSubrole: String?
    let focusedTitle: String?
    let focusedValue: String?
    let selectedText: String?
    let textLen: Int
    let extractionStatus: String?

    var hasUsableText: Bool { textLen > 0 }
    var totalTextLength: Int { textLen }

    init(id: String, sessionId: String, captureId: String?, timestamp: String,
         focusedRole: String?, focusedSubrole: String?, focusedTitle: String?,
         focusedValue: String?, selectedText: String?, textLen: Int, extractionStatus: String?) {
        self.id = id; self.sessionId = sessionId; self.captureId = captureId
        self.timestamp = timestamp; self.focusedRole = focusedRole
        self.focusedSubrole = focusedSubrole; self.focusedTitle = focusedTitle
        self.focusedValue = focusedValue; self.selectedText = selectedText
        self.textLen = textLen; self.extractionStatus = extractionStatus
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let sessionId = row["session_id"]?.textValue,
              let timestamp = row["timestamp"]?.textValue else { return nil }
        self.id = id; self.sessionId = sessionId
        self.captureId = row["capture_id"]?.textValue
        self.timestamp = timestamp
        self.focusedRole = row["focused_role"]?.textValue
        self.focusedSubrole = row["focused_subrole"]?.textValue
        self.focusedTitle = row["focused_title"]?.textValue
        self.focusedValue = row["focused_value"]?.textValue
        self.selectedText = row["selected_text"]?.textValue
        self.textLen = row["text_len"]?.intValue.flatMap { Int($0) } ?? 0
        self.extractionStatus = row["extraction_status"]?.textValue
    }
}
