struct AppRecord {
    let id: Int64
    let bundleId: String?
    let appName: String
    let category: String?
    let createdAt: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.intValue,
              let appName = row["app_name"]?.textValue else { return nil }
        self.id = id
        self.bundleId = row["bundle_id"]?.textValue
        self.appName = appName
        self.category = row["category"]?.textValue
        self.createdAt = row["created_at"]?.textValue
    }
}
