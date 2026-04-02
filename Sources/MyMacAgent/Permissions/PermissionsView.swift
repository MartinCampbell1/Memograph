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
                granted: manager.accessibilityGranted
            )

            permissionRow(
                title: "Screen Recording",
                description: "Capture window contents for OCR",
                granted: manager.screenRecordingGranted
            )

            Text("Grant permissions in System Settings → Privacy & Security.\nRestart the app after changing permissions.")
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
    }

    private func permissionRow(title: String, description: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(granted ? "Granted" : "Not granted")
                .font(.caption)
                .foregroundStyle(granted ? .green : .red)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(granted ? Color.green.opacity(0.05) : Color.red.opacity(0.05)))
    }
}
