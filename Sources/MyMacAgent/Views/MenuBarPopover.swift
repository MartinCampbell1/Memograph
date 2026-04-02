import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow
    @State private var isPaused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memograph")
                .font(.headline)

            if isPaused {
                Label("Paused", systemImage: "pause.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            } else if !permissionsManager.screenRecordingGranted && !permissionsManager.accessibilityGranted {
                Label("No permissions", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            } else if !permissionsManager.screenRecordingGranted || !permissionsManager.accessibilityGranted {
                Label("Degraded", systemImage: "eye.slash")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            } else {
                Label("Running", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            }

            Divider()

            Button(isPaused ? "Resume Tracking" : "Pause Tracking") {
                isPaused.toggle()
                var settings = AppSettings()
                settings.globalPause = isPaused
                NotificationCenter.default.post(name: .captureToggled, object: nil)
                NotificationCenter.default.post(name: .settingsDidChange, object: nil)
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
            permissionsManager.checkAll()
            isPaused = AppSettings().globalPause
        }
    }
}

extension Notification.Name {
    static let captureToggled = Notification.Name("captureToggled")
    static let settingsDidChange = Notification.Name("settingsDidChange")
    static let deleteAllLocalDataRequested = Notification.Name("deleteAllLocalDataRequested")
}
