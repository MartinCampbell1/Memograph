import SwiftUI

struct PermissionsView: View {
    @ObservedObject var manager: PermissionsManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions Required")
                .font(.title2)
                .fontWeight(.semibold)

            Text("MyMacAgent needs the following permissions to track your activity.")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                permissionRow(
                    title: "Screen Recording",
                    description: "Capture window contents for OCR and visual logging",
                    granted: manager.screenRecordingGranted,
                    action: manager.openScreenRecordingPrefs
                )

                permissionRow(
                    title: "Accessibility",
                    description: "Read window titles and focused UI elements",
                    granted: manager.accessibilityGranted,
                    action: manager.requestAccessibility
                )
            }

            HStack {
                Spacer()
                Button("Refresh Status") { manager.checkAll() }
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
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundStyle(granted ? .green : .red)
                    Text(title).fontWeight(.medium)
                }
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Grant") { action() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(granted ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
        )
    }
}
