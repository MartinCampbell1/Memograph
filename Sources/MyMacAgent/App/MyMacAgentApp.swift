import SwiftUI

@main
@MainActor
struct MyMacAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("MyMacAgent", systemImage: "brain.head.profile") {
            MenuBarPopover()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}
