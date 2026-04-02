import os

extension Logger {
    private static let subsystem = "com.martin.mymacagent"

    nonisolated(unsafe) static let app = Logger(subsystem: subsystem, category: "app")
    nonisolated(unsafe) static let database = Logger(subsystem: subsystem, category: "database")
    nonisolated(unsafe) static let monitor = Logger(subsystem: subsystem, category: "monitor")
    nonisolated(unsafe) static let session = Logger(subsystem: subsystem, category: "session")
    nonisolated(unsafe) static let capture = Logger(subsystem: subsystem, category: "capture")
    nonisolated(unsafe) static let permissions = Logger(subsystem: subsystem, category: "permissions")
    nonisolated(unsafe) static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
    nonisolated(unsafe) static let ocr = Logger(subsystem: subsystem, category: "ocr")
    nonisolated(unsafe) static let policy = Logger(subsystem: subsystem, category: "policy")
}
