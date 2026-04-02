import SwiftUI

struct PermissionsView: View {
    @ObservedObject var manager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.title2)
                .fontWeight(.semibold)

            permissionRow(
                title: "Accessibility",
                description: "Read window titles and focused UI elements",
                granted: manager.accessibilityGranted,
                actionTitle: manager.accessibilityGranted ? "Open Settings" : "Grant Access",
                action: {
                    if manager.accessibilityGranted {
                        manager.openAccessibilitySettings()
                    } else {
                        manager.requestAccessibility()
                    }
                }
            )

            permissionRow(
                title: "Screen Recording",
                description: "Capture window contents for OCR",
                granted: manager.screenRecordingGranted,
                actionTitle: "Open Settings",
                action: {
                    manager.openScreenRecordingSettings()
                }
            )

            permissionRow(
                title: "Microphone",
                description: "Optional, only for experimental audio transcription",
                granted: manager.microphoneGranted,
                actionTitle: manager.microphoneGranted ? "Open Settings" : "Request Access",
                action: {
                    if manager.microphoneGranted {
                        manager.openMicrophoneSettings()
                    } else {
                        Task { await manager.requestMicrophone() }
                    }
                }
            )

            Text("The app degrades gracefully when permissions are denied: screenshots, accessibility context and audio are all optional.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Re-check") {
                    manager.checkAll()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear { manager.checkAll() }
    }

    private func permissionRow(
        title: String,
        description: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(granted ? "Granted" : "Not granted")
                    .font(.caption)
                    .foregroundStyle(granted ? .green : .red)
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(granted ? Color.green.opacity(0.05) : Color.red.opacity(0.05)))
    }
}
