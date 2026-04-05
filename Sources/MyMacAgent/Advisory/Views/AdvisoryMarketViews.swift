import SwiftUI

struct AdvisoryMarketSnapshotView: View {
    let snapshot: AdvisoryMarketSnapshot
    var selectedDomain: AdvisoryDomain? = nil
    var onSelectDomain: ((AdvisoryDomain?) -> Void)? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 180), spacing: 10)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attention Market")
                        .font(.headline)
                    Text(summaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(visibleDomainSnapshots) { domainSnapshot in
                    AdvisoryDomainMarketCard(snapshot: domainSnapshot)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(selectedDomain == domainSnapshot.domain ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1.5)
                        )
                        .onTapGesture {
                            guard let onSelectDomain else { return }
                            onSelectDomain(selectedDomain == domainSnapshot.domain ? nil : domainSnapshot.domain)
                        }
                }
            }
        }
    }

    private var summaryLine: String {
        "Surfaced \(snapshot.surfacedCount) · Queued \(snapshot.queuedCount) · Candidate \(snapshot.candidateCount)"
    }

    private var visibleDomainSnapshots: [AdvisoryDomainMarketSnapshot] {
        let active = snapshot.domainSnapshots.filter {
            $0.activeArtifactCount > 0 || $0.leadArtifactTitle != nil
        }
        return active.isEmpty ? Array(snapshot.domainSnapshots.prefix(4)) : active
    }
}

private struct AdvisoryDomainMarketCard: View {
    let snapshot: AdvisoryDomainMarketSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.domain.label)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(slotLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let leadArtifactTitle = snapshot.leadArtifactTitle,
               !leadArtifactTitle.isEmpty {
                Text(leadArtifactTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accentColor)
                    .lineLimit(2)
            } else {
                Text("Пока без активных candidates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                statPill("Demand", value: snapshot.demand)
                statPill("Budget", value: snapshot.remainingBudgetFactor)
                if snapshot.fatigue > 0.12 {
                    statPill("Fatigue", value: snapshot.fatigue)
                }
            }

            Text(readinessLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(countLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    private var accentColor: Color {
        switch snapshot.domain {
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

    private var slotLine: String {
        snapshot.proactiveEligible ? "eligible" : "latent"
    }

    private var countLine: String {
        "Now \(snapshot.surfacedCount) · queued \(snapshot.queuedCount) · candidate \(snapshot.candidateCount)"
    }

    private var readinessLine: String {
        if snapshot.activeArtifactCount == 0 {
            switch snapshot.domain {
            case .focus:
                return "Focus ждёт fragmented state или transition, не лезет просто так."
            case .research:
                return "Research latent: лучше всплывать только когда есть спокойное окно на exploration."
            case .social:
                return "Social остаётся тихим, пока нет естественного окна на reply или ping."
            case .health:
                return "Health держится мягко и не должен звучать как директива."
            case .decisions:
                return "Decision layer молчит, пока unresolved edge не станет плотнее."
            case .lifeAdmin:
                return "Life admin ждёт более дешёвого operational окна."
            case .continuity:
                return "Continuity пока не сформировала новый return point."
            case .writingExpression:
                return "Writing lane latent: нет достаточно grounded angle."
            }
        }
        if !snapshot.proactiveEligible {
            if snapshot.remainingBudgetFactor < 0.25 {
                return "Budget почти исчерпан, поэтому домен держится latent."
            }
            if snapshot.fatigue > 0.3 {
                return "Fatigue/repetition control сейчас притушает этот домен."
            }
            switch snapshot.domain {
            case .focus:
                return "Focus signal есть, но governor ждёт более дешёвого окна."
            case .research:
                return "Research виден, но пока не лучший момент тащить его в верхнюю поверхность."
            case .lifeAdmin:
                return "Life admin есть в фоне, но лучше не пушить его вне transition."
            default:
                return "Сигнал есть, но governor держит этот полюс latent."
            }
        }
        if snapshot.demand > 0.65 {
            return "Этот полюс реально тянет внимание сегодня."
        }
        return "У домена есть live candidates, но pacing остаётся ambient."
    }

    private func statPill(_ title: String, value: Double) -> some View {
        Text("\(title) \(Int((max(0, min(1, value)) * 100).rounded()))%")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }
}

struct AdvisoryEnrichmentStatusView: View {
    let sources: [AdvisoryEnrichmentSourceStatusSnapshot]
    var showHeader: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showHeader {
                Text("Enrichment Sources")
                    .font(.headline)
            }

            ForEach(sources) { source in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(source.source.label)
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(availabilityLabel(source.availability))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(availabilityTint(source.availability).opacity(0.12)))
                            .foregroundStyle(availabilityTint(source.availability))
                    }
                    Text(runtimeLine(source))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(source.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !source.sampleTitles.isEmpty {
                        Text("Examples: \(source.sampleTitles.joined(separator: " · "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    private func availabilityLabel(_ availability: AdvisoryEnrichmentAvailability) -> String {
        switch availability {
        case .embedded: return "Live"
        case .deferred: return "Deferred"
        case .unavailable: return "Unavailable"
        case .disabled: return "Disabled"
        }
    }

    private func availabilityTint(_ availability: AdvisoryEnrichmentAvailability) -> Color {
        switch availability {
        case .embedded: return .green
        case .deferred: return .orange
        case .unavailable: return .secondary
        case .disabled: return .purple
        }
    }

    private func runtimeLine(_ source: AdvisoryEnrichmentSourceStatusSnapshot) -> String {
        var parts = [source.runtimeKind.label]
        if !source.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(source.providerLabel)
        }
        if source.isFallback {
            parts.append("fallback")
        }
        if source.itemCount > 0 {
            parts.append("\(source.itemCount) items")
        }
        return parts.joined(separator: " · ")
    }
}
