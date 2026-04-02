import AppKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger.app

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MyMacAgent launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("MyMacAgent terminating")
    }
}
