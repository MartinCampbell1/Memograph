import SwiftUI

@MainActor
@main
struct MyMacAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var permissionsManager = PermissionsManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarPopover(
                permissionsManager: permissionsManager,
                db: appDelegate.databaseManager
            )
        } label: {
            HStack(spacing: 4) {
                MemographGlyph()
                Text("Mem")
                    .font(.caption2.weight(.semibold))
            }
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Timeline", id: "timeline") {
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

        // Accounts now opens the main Settings window with tab 6 via notification
        // No separate window needed — prevents "stuck with no back button" issue
    }
}
