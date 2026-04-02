import os

extension Logger {
    private static let subsystem = "com.martin.mymacagent"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let monitor = Logger(subsystem: subsystem, category: "monitor")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
