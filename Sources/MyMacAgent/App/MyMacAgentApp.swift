import SwiftUI

@MainActor
@main
struct MyMacAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var permissionsManager = PermissionsManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(permissionsManager: permissionsManager)
        } label: {
            MemographGlyph()
        }
        .menuBarExtraStyle(.window)

        Window("Timeline", id: "timeline") {
            if let db = appDelegate.databaseManager {
                TimelineView(db: db)
            } else {
                Text("Database not ready")
            }
        }

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .defaultSize(width: 920, height: 760)
        .windowResizability(.contentSize)
    }
}
