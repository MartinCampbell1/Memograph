import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var permissionsManager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyMacAgent")
                .font(.headline)

            if permissionsManager.allGranted {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("Permissions needed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)

                Button("Open Settings") {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
                .font(.caption)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 250)
    }
}
