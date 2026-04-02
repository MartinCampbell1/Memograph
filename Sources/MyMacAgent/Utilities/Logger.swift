import os

extension Logger {
    private static let subsystem = "com.martin.mymacagent"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let database = Logger(subsystem: subsystem, category: "database")
    static let monitor = Logger(subsystem: subsystem, category: "monitor")
    static let session = Logger(subsystem: subsystem, category: "session")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let accessibility = Logger(subsystem: subsystem, category: "accessibility")
    static let ocr = Logger(subsystem: subsystem, category: "ocr")
    static let policy = Logger(subsystem: subsystem, category: "policy")
    static let fusion = Logger(subsystem: subsystem, category: "fusion")
    static let summary = Logger(subsystem: subsystem, category: "summary")
    static let export = Logger(subsystem: subsystem, category: "export")
}
