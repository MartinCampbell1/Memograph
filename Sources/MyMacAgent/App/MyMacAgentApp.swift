import SwiftUI

@MainActor
@main
struct MyMacAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // App windows are managed explicitly from AppDelegate via AppKit.
        // Keeping scene-restored SwiftUI windows around caused stale Timeline
        // windows to reopen with "Database not ready" before the delegate
        // finished initialization.
        Settings {
            EmptyView()
        }
    }
}
