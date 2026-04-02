import Foundation

struct DailySummaryRecord {
    let date: String
    let summaryText: String?
    let topAppsJson: String?
    let topTopicsJson: String?
    let aiSessionsJson: String?
    let contextSwitchesJson: String?
    let unfinishedItemsJson: String?
    let suggestedNotesJson: String?
    let generatedAt: String?
    let modelName: String?
    let tokenUsageInput: Int
    let tokenUsageOutput: Int
    let generationStatus: String?

    init(date: String, summaryText: String?, topAppsJson: String?,
         topTopicsJson: String?, aiSessionsJson: String?,
         contextSwitchesJson: String?, unfinishedItemsJson: String?,
         suggestedNotesJson: String?, generatedAt: String?,
         modelName: String?, tokenUsageInput: Int, tokenUsageOutput: Int,
         generationStatus: String?) {
        self.date = date; self.summaryText = summaryText
        self.topAppsJson = topAppsJson; self.topTopicsJson = topTopicsJson
        self.aiSessionsJson = aiSessionsJson
        self.contextSwitchesJson = contextSwitchesJson
        self.unfinishedItemsJson = unfinishedItemsJson
        self.suggestedNotesJson = suggestedNotesJson
        self.generatedAt = generatedAt; self.modelName = modelName
        self.tokenUsageInput = tokenUsageInput
        self.tokenUsageOutput = tokenUsageOutput
        self.generationStatus = generationStatus
    }

    init?(row: SQLiteRow) {
        guard let date = row["date"]?.textValue else { return nil }
        self.date = date
        self.summaryText = row["summary_text"]?.textValue
        self.topAppsJson = row["top_apps_json"]?.textValue
        self.topTopicsJson = row["top_topics_json"]?.textValue
        self.aiSessionsJson = row["ai_sessions_json"]?.textValue
        self.contextSwitchesJson = row["context_switches_json"]?.textValue
        self.unfinishedItemsJson = row["unfinished_items_json"]?.textValue
        self.suggestedNotesJson = row["suggested_notes_json"]?.textValue
        self.generatedAt = row["generated_at"]?.textValue
        self.modelName = row["model_name"]?.textValue
        self.tokenUsageInput = row["token_usage_input"]?.intValue.flatMap { Int($0) } ?? 0
        self.tokenUsageOutput = row["token_usage_output"]?.intValue.flatMap { Int($0) } ?? 0
        self.generationStatus = row["generation_status"]?.textValue
    }
}
