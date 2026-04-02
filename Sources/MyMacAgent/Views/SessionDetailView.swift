import SwiftUI

struct SessionDetailView: View {
    let db: DatabaseManager
    let session: TimelineSession
    @State private var contexts: [ContextSnapshotRecord] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    Text(session.appName).font(.title2).fontWeight(.semibold)
                    if session.uncertaintyMode != "normal" {
                        Text(session.uncertaintyMode)
                            .font(.caption)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.orange.opacity(0.2)))
                    }
                }

                Text("Duration: \(ObsidianExporter.formatDuration(minutes: session.durationMinutes))")
                    .foregroundStyle(.secondary)

                Divider()

                // Context snapshots
                Text("Context Snapshots (\(contexts.count))").font(.headline)

                ForEach(contexts, id: \.id) { ctx in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(ctx.windowTitle ?? "Untitled").fontWeight(.medium)
                            Spacer()
                            Text(ctx.textSource ?? "")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let text = ctx.mergedText {
                            Text(String(text.prefix(500)))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(8)
                        }
                        HStack {
                            Text("Readability: \(String(format: "%.0f%%", ctx.readableScore * 100))")
                            Text("Uncertainty: \(String(format: "%.0f%%", ctx.uncertaintyScore * 100))")
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
        .onAppear { loadContexts() }
    }

    private func loadContexts() {
        let provider = TimelineDataProvider(db: db)
        contexts = (try? provider.contextSnapshotsForSession(session.sessionId)) ?? []
    }
}
