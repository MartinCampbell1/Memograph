enum AppRuleType: String {
    case excludeCapture = "exclude_capture"
    case excludeOcr = "exclude_ocr"
    case highFrequencyCapture = "high_frequency_capture"
    case metadataOnly = "metadata_only"
    case privacyMask = "privacy_mask"
    case aiChatHint = "ai_chat_hint"
}

struct AppRule {
    let id: Int64
    let bundleId: String?
    let ruleType: AppRuleType
    let ruleValue: String
    let enabled: Bool

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.intValue,
              let ruleTypeStr = row["rule_type"]?.textValue,
              let ruleType = AppRuleType(rawValue: ruleTypeStr),
              let ruleValue = row["rule_value"]?.textValue else { return nil }
        self.id = id
        self.bundleId = row["bundle_id"]?.textValue
        self.ruleType = ruleType
        self.ruleValue = ruleValue
        self.enabled = (row["enabled"]?.intValue ?? 1) != 0
    }
}
