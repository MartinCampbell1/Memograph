enum UncertaintyMode: String {
    case normal
    case degraded
    case highUncertainty = "high_uncertainty"
    case recovery
}

struct Session {
    let id: String
    let appId: Int64
    let windowId: Int64?
    let sessionType: String?
    let startedAt: String
    let endedAt: String?
    let activeDurationMs: Int64
    let idleDurationMs: Int64
    let confidenceScore: Double
    let uncertaintyMode: UncertaintyMode
    let topTopic: String?
    let isAiRelated: Bool
    let summaryStatus: String

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let appId = row["app_id"]?.intValue,
              let startedAt = row["started_at"]?.textValue else { return nil }
        self.id = id
        self.appId = appId
        self.windowId = row["window_id"]?.intValue
        self.sessionType = row["session_type"]?.textValue
        self.startedAt = startedAt
        self.endedAt = row["ended_at"]?.textValue
        self.activeDurationMs = row["active_duration_ms"]?.intValue ?? 0
        self.idleDurationMs = row["idle_duration_ms"]?.intValue ?? 0
        self.confidenceScore = row["confidence_score"]?.realValue ?? 0
        self.uncertaintyMode = UncertaintyMode(rawValue: row["uncertainty_mode"]?.textValue ?? "normal") ?? .normal
        self.topTopic = row["top_topic"]?.textValue
        self.isAiRelated = (row["is_ai_related"]?.intValue ?? 0) != 0
        self.summaryStatus = row["summary_status"]?.textValue ?? "pending"
    }
}
