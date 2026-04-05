import SwiftUI

struct AdvisoryActionPanelView: View {
    let snapshot: AdvisoryWorkspaceSnapshot
    let topArtifactsByDomain: [AdvisoryDomain: AdvisoryArtifactRecord]
    var selectedDomain: AdvisoryDomain? = nil
    var runningDomain: AdvisoryDomain? = nil
    var onRunDomainAction: (AdvisoryDomain) -> Void
    var onSelectDomain: ((AdvisoryDomain?) -> Void)? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 200), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Advisor Surfaces")
                        .font(.headline)
                    Text("Ручной pull по core-доменам: continuity resume, writing seed, weekly reflection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(snapshot.advisorGuidanceLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selectedDomain != nil, let onSelectDomain {
                    Button("Clear focus") {
                        onSelectDomain(nil)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(recommendationItems, id: \.action.id) { item in
                    domainCard(for: item.action, recommendation: item.recommendation)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    @ViewBuilder
    private func domainCard(
        for action: AdvisoryManualRecipeSpec,
        recommendation: AdvisoryManualPullRecommendation
    ) -> some View {
        let market = snapshot.domainMarketSnapshots.first(where: { $0.domain == action.domain })
        let artifact = topArtifactsByDomain[action.domain]
        let isSelected = selectedDomain == action.domain
        let isRunning = runningDomain == action.domain
        let isPrimaryRecommendation = snapshot.topManualPullRecommendation?.domain == action.domain
        let accent = color(for: action.domain)

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol(for: action.domain))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(action.domain.label)
                        .font(.subheadline.weight(.semibold))
                    Text(action.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let market {
                    Text(statusChip(for: market, recommendation: recommendation))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(chipColor(for: recommendation, accent: accent).opacity(0.12)))
                        .foregroundStyle(chipColor(for: recommendation, accent: accent))
                }
            }

            Text(action.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(recommendation.headline)
                .font(.caption.weight(.medium))
                .foregroundStyle(isPrimaryRecommendation ? accent : .primary)
                .fixedSize(horizontal: false, vertical: true)

            if let artifact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(artifact.title)
                        .font(.caption.weight(.medium))
                    Text(AdvisorySupport.cleanedSnippet(artifact.body, maxLength: 90))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(recommendation.reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let market {
                Text(statusDetail(for: market, recommendation: recommendation))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Пока без заметного surfaced signal в этом домене.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(isRunning ? "Running…" : "Pull") {
                    onRunDomainAction(action.domain)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRunning)

                if let onSelectDomain {
                    Button(isSelected ? "Selected" : "Inspect") {
                        onSelectDomain(action.domain)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accent.opacity(isSelected || isPrimaryRecommendation ? 0.12 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(isSelected || isPrimaryRecommendation ? 0.3 : 0.12), lineWidth: 1)
        )
    }

    private var recommendationItems: [(action: AdvisoryManualRecipeSpec, recommendation: AdvisoryManualPullRecommendation)] {
        let actionsByDomain = Dictionary(uniqueKeysWithValues: AdvisoryRecipeCatalog.v1ManualDomainActions.map { ($0.domain, $0) })
        return snapshot.manualPullRecommendations.compactMap { recommendation in
            guard let action = actionsByDomain[recommendation.domain] else { return nil }
            return (action, recommendation)
        }
    }

    private func statusChip(
        for snapshot: AdvisoryDomainMarketSnapshot,
        recommendation: AdvisoryManualPullRecommendation
    ) -> String {
        if snapshot.surfacedCount > 0 {
            return recommendation.tier == .bestNow ? "Best now" : "\(snapshot.surfacedCount) now"
        }
        if recommendation.tier != .quiet {
            return recommendation.tier.label
        }
        if snapshot.queuedCount > 0 {
            return "\(snapshot.queuedCount) queued"
        }
        if snapshot.candidateCount > 0 {
            return "\(snapshot.candidateCount) candidates"
        }
        return "quiet"
    }

    private func statusDetail(
        for snapshot: AdvisoryDomainMarketSnapshot,
        recommendation: AdvisoryManualPullRecommendation
    ) -> String {
        if let leadArtifactTitle = snapshot.leadArtifactTitle, !leadArtifactTitle.isEmpty {
            return "\(recommendation.reason) Lead: \(leadArtifactTitle)"
        }
        return recommendation.reason
    }

    private func chipColor(for recommendation: AdvisoryManualPullRecommendation, accent: Color) -> Color {
        switch recommendation.tier {
        case .bestNow:
            return accent
        case .goodWindow:
            return .green
        case .waitForWindow:
            return .orange
        case .deepWorkSuppressed:
            return .secondary
        case .coolingDown:
            return .red
        case .quiet:
            return .secondary
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }

    private func color(for domain: AdvisoryDomain) -> Color {
        switch domain {
        case .continuity: return .accentColor
        case .writingExpression: return .indigo
        case .research: return .blue
        case .focus: return .orange
        case .social: return .pink
        case .health: return .green
        case .decisions: return .red
        case .lifeAdmin: return .brown
        }
    }

    private func symbol(for domain: AdvisoryDomain) -> String {
        switch domain {
        case .continuity: return "arrow.clockwise.circle"
        case .writingExpression: return "text.bubble"
        case .research: return "magnifyingglass"
        case .focus: return "scope"
        case .social: return "person.2"
        case .health: return "heart.text.square"
        case .decisions: return "arrow.triangle.branch"
        case .lifeAdmin: return "checklist"
        }
    }
}
