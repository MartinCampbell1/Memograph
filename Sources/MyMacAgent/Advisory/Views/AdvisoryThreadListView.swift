import SwiftUI

struct AdvisoryThreadListView: View {
    let threads: [AdvisoryThreadRecord]
    let selectedThreadId: String?
    let onSelectThread: (String) -> Void
    let onCreateThread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Threads")
                    .font(.headline)
                Spacer()
                Button("Создать", action: onCreateThread)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if threads.isEmpty {
                Text("Пока нет устойчивых нитей. Можно создать manual thread, если хочешь явно вести отдельный контекст.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(threads) { thread in
                    Button {
                        onSelectThread(thread.id)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 6) {
                                    Text(thread.displayTitle)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    if thread.userPinned {
                                        Image(systemName: "pin.fill")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text("\(threadStatusLabel(thread.status)) · \(thread.kind.rawValue) · \(ObsidianExporter.formatDuration(minutes: thread.totalActiveMinutes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let summary = thread.summary, !summary.isEmpty {
                                    Text(AdvisorySupport.cleanedSnippet(summary, maxLength: 110))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(Int(thread.importanceScore * 100))%")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedThreadId == thread.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func threadStatusLabel(_ status: AdvisoryThreadStatus) -> String {
        switch status {
        case .active: return "active"
        case .stalled: return "stalled"
        case .parked: return "parked"
        case .resolved: return "resolved"
        }
    }
}
