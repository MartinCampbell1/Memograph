import SwiftUI

struct AdvisoryOverviewView: View {
    let snapshot: AdvisoryWorkspaceSnapshot
    var selectedDomain: AdvisoryDomain? = nil
    var onSelectDomain: ((AdvisoryDomain?) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advisor")
                        .font(.headline)
                    Text(summaryLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(snapshot.advisorGuidanceLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    metricBadge("\(snapshot.surfacedCount) now")
                    metricBadge("\(snapshot.pendingCount) queued")
                }
            }

            HStack(spacing: 8) {
                contextBadge("focus: \(focusStateLabel(snapshot.focusState))")
                contextBadge("phase: \(coldStartLabel(snapshot.coldStartPhase))")
                contextBadge(snapshot.attentionMode)
            }

            AdvisoryMarketSnapshotView(
                snapshot: snapshot.marketSnapshot,
                selectedDomain: selectedDomain,
                onSelectDomain: onSelectDomain
            )

            if !snapshot.enrichmentSourceStatuses.isEmpty {
                DisclosureGroup("Enrichment sources") {
                    AdvisoryEnrichmentStatusView(
                        sources: snapshot.enrichmentSourceStatuses,
                        showHeader: false
                    )
                        .padding(.top, 8)
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }

    private var summaryLine: String {
        "\(snapshot.activeThreadCount) threads · \(snapshot.openContinuityCount) open loops · system age \(snapshot.systemAgeDays)d"
    }

    private func metricBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }

    private func contextBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func focusStateLabel(_ state: AdvisoryFocusState) -> String {
        switch state {
        case .deepWork: return "deep work"
        case .browsing: return "browsing"
        case .transition: return "transition"
        case .idleReturn: return "idle return"
        case .fragmented: return "fragmented"
        }
    }

    private func coldStartLabel(_ phase: AdvisoryColdStartPhase) -> String {
        switch phase {
        case .bootstrap: return "bootstrap"
        case .earlyThreads: return "early threads"
        case .operational: return "operational"
        case .mature: return "mature"
        }
    }
}

private struct FlowRow<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    let data: Data
    let id: KeyPath<Data.Element, ID>
    @ViewBuilder let content: (Data.Element) -> Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(data), id: id) { item in
                content(item)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
