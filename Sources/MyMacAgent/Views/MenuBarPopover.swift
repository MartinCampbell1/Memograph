import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow
    @State private var isPaused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyMacAgent")
                .font(.headline)

            if isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else {
                Label("Running", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            Divider()

            Button(isPaused ? "Resume Tracking" : "Pause Tracking") {
                isPaused.toggle()
                UserDefaults.standard.set(isPaused, forKey: "captureGlobalPause")
                NotificationCenter.default.post(name: .captureToggled, object: nil)
            }

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
        .frame(width: 230)
        .onAppear {
            isPaused = UserDefaults.standard.bool(forKey: "captureGlobalPause")
        }
    }
}

extension Notification.Name {
    static let captureToggled = Notification.Name("captureToggled")
}
