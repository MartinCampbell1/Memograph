struct WindowRecord {
    let id: Int64
    let appId: Int64
    let windowTitle: String?
    let windowRole: String?
    let firstSeenAt: String?
    let lastSeenAt: String?
    let fingerprint: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.intValue,
              let appId = row["app_id"]?.intValue else { return nil }
        self.id = id
        self.appId = appId
        self.windowTitle = row["window_title"]?.textValue
        self.windowRole = row["window_role"]?.textValue
        self.firstSeenAt = row["first_seen_at"]?.textValue
        self.lastSeenAt = row["last_seen_at"]?.textValue
        self.fingerprint = row["fingerprint"]?.textValue
    }
}
