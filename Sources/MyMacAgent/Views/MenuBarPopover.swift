import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyMacAgent")
                .font(.headline)

            Label("Running", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)

            Divider()

            Button("Open Timeline") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "timeline")
            }

            Button("Settings") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "settings")
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 220)
    }
}
