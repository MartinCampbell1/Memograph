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

        Window("Timeline", id: "timeline") {
            if let db = appDelegate.databaseManager {
                TimelineView(db: db)
            } else {
                Text("Database not ready")
            }
        }

        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("General", systemImage: "gear") }
                PermissionsView(manager: permissionsManager)
                    .tabItem { Label("Permissions", systemImage: "lock.shield") }
            }
            .frame(width: 500, height: 400)
        }
    }
}
