import SwiftUI

struct MenuBarPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyMacAgent")
                .font(.headline)
            Text("Status: Starting...")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 250)
    }
}
