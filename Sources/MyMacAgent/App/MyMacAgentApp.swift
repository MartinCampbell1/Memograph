import SwiftUI

@MainActor
@main
struct MyMacAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var permissionsManager = PermissionsManager()

    var body: some Scene {
        MenuBarExtra("MyMacAgent", systemImage: "brain.head.profile") {
            MenuBarPopover(permissionsManager: permissionsManager)
        }
        .menuBarExtraStyle(.window)

        Settings {
            if permissionsManager.allGranted {
                SettingsView()
            } else {
                PermissionsView(manager: permissionsManager)
            }
        }
    }
}
