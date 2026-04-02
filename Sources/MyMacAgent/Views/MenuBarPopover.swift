import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow
    @State private var isPaused = false

    private enum RuntimeStatus {
        case paused
        case running
        case limited([String])

        var title: String {
            switch self {
            case .paused:
                return "Paused"
            case .running:
                return "Running"
            case .limited(let reasons):
                return reasons.count == 1 ? "Limited" : "Needs Setup"
            }
        }

        var icon: String {
            switch self {
            case .paused:
                return "pause.circle.fill"
            case .running:
                return "checkmark.circle.fill"
            case .limited:
                return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .paused:
                return .orange
            case .running:
                return .green
            case .limited:
                return .yellow
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MemographGlyph()
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Memograph")
                        .font(.headline)

                    Label(runtimeStatus.title, systemImage: runtimeStatus.icon)
                        .foregroundStyle(runtimeStatus.tint)
                        .font(.caption)
                }
            }

            if case .limited(let reasons) = runtimeStatus {
                Text(reasons.joined(separator: " + "))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if !permissionsManager.screenRecordingGranted {
                        Button("Enable Screen") {
                            permissionsManager.openScreenRecordingSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !permissionsManager.accessibilityGranted {
                        Button("Enable AX") {
                            permissionsManager.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
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
        .frame(width: 260)
        .onAppear {
            permissionsManager.checkAll()
            isPaused = AppSettings().globalPause
        }
    }

    private var runtimeStatus: RuntimeStatus {
        if isPaused {
            return .paused
        }

        var reasons: [String] = []
        if !permissionsManager.screenRecordingGranted {
            reasons.append("Screen Recording missing")
        }
        if !permissionsManager.accessibilityGranted {
            reasons.append("Accessibility missing")
        }

        return reasons.isEmpty ? .running : .limited(reasons)
    }
}

extension Notification.Name {
    static let captureToggled = Notification.Name("captureToggled")
    static let settingsDidChange = Notification.Name("settingsDidChange")
    static let deleteAllLocalDataRequested = Notification.Name("deleteAllLocalDataRequested")
}
