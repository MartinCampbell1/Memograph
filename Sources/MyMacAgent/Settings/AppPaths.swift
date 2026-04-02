import Foundation

enum AppPaths {
    static let dataFolderName = "MyMacAgent"
    static let databaseFileName = "mymacagent.db"

    static func defaultDataDirectoryPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(dataFolderName, isDirectory: true).path
    }

    static func dataDirectoryURL(settings: AppSettings = AppSettings()) -> URL {
        URL(fileURLWithPath: settings.dataDirectoryPath, isDirectory: true)
    }

    static func databaseURL(settings: AppSettings = AppSettings()) -> URL {
        dataDirectoryURL(settings: settings).appendingPathComponent(databaseFileName)
    }

    static func capturesDirectoryURL(settings: AppSettings = AppSettings()) -> URL {
        dataDirectoryURL(settings: settings).appendingPathComponent("captures", isDirectory: true)
    }

    static func audioDirectoryURL(settings: AppSettings = AppSettings()) -> URL {
        dataDirectoryURL(settings: settings).appendingPathComponent("audio", isDirectory: true)
    }

    static func systemAudioDirectoryURL(settings: AppSettings = AppSettings()) -> URL {
        dataDirectoryURL(settings: settings).appendingPathComponent("system_audio", isDirectory: true)
    }

    static func ensureBaseDirectories(settings: AppSettings = AppSettings()) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: dataDirectoryURL(settings: settings), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: capturesDirectoryURL(settings: settings), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: audioDirectoryURL(settings: settings), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: systemAudioDirectoryURL(settings: settings), withIntermediateDirectories: true)
    }

    static func removeAllLocalData(settings: AppSettings = AppSettings()) throws {
        let rootURL = dataDirectoryURL(settings: settings)
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
    }
}
