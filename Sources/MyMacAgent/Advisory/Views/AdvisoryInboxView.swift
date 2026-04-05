import SwiftUI

private struct AdvisoryInboxSection: Identifiable {
    let domain: AdvisoryDomain
    let artifacts: [AdvisoryArtifactRecord]

    var id: String { domain.rawValue }
}

struct AdvisoryInboxView: View {
    let artifacts: [AdvisoryArtifactRecord]
    var threadsById: [String: AdvisoryThreadRecord] = [:]
    var marketSnapshot: AdvisoryMarketSnapshot? = nil
    var selectedDomain: AdvisoryDomain? = nil
    var onClearDomainFilter: (() -> Void)? = nil
    var onOpenThread: ((String) -> Void)? = nil
    var onQuickAction: ((String, AdvisoryArtifactQuickAction) -> Void)? = nil
    var onFeedback: ((String, AdvisoryArtifactFeedbackKind) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedDomain.map { "Advisory Inbox · \($0.label)" } ?? "Advisory Inbox")
                    .font(.headline)
                Spacer()
                if selectedDomain != nil, let onClearDomainFilter {
                    Button("All domains") {
                        onClearDomainFilter()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }

            if artifacts.isEmpty {
                Text(emptyStateText)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groupedArtifacts) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if selectedDomain == nil {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(section.domain.label)
                                    .font(.subheadline.weight(.semibold))
                                if let line = domainSummaryLine(for: section.domain) {
                                    Text(line)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        ForEach(section.artifacts) { artifact in
                            AdvisoryArtifactCardView(
                                artifact: artifact,
                                thread: artifact.threadId.flatMap { threadsById[$0] },
                                maxBodyLength: 180,
                                maxSteps: 2,
                                onOpenThread: onOpenThread,
                                onQuickAction: { action in
                                    onQuickAction?(artifact.id, action)
                                },
                                onFeedback: { kind in
                                    onFeedback?(artifact.id, kind)
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private var groupedArtifacts: [AdvisoryInboxSection] {
        let grouped = Dictionary(grouping: artifacts, by: \.domain)
        return grouped.keys
            .sorted { lhs, rhs in
                if lhs.defaultBaseWeight == rhs.defaultBaseWeight {
                    return lhs.label < rhs.label
                }
                return lhs.defaultBaseWeight > rhs.defaultBaseWeight
            }
            .map { domain in
                let domainArtifacts = (grouped[domain] ?? []).sorted(by: artifactPriority)
                return AdvisoryInboxSection(domain: domain, artifacts: domainArtifacts)
            }
    }

    private var emptyStateText: String {
        guard let selectedDomain else {
            return "Пока нет advisory artifacts с достаточным сигналом."
        }
        return domainSummaryLine(for: selectedDomain)
            ?? "Для этого домена сейчас нет surfaced или queued artifacts."
    }

    private func domainSummaryLine(for domain: AdvisoryDomain) -> String? {
        guard let snapshot = marketSnapshot?.domainSnapshots.first(where: { $0.domain == domain }) else {
            return nil
        }
        if snapshot.activeArtifactCount == 0 {
            switch domain {
            case .focus:
                return "Focus domain сейчас latent и ждёт более дешёвого transition окна."
            case .research:
                return "Research остаётся latent, пока не появится спокойное окно на exploration."
            case .social:
                return "Social живёт мягко и не должен лезть без явного окна."
            case .health:
                return "Health остаётся quiet, пока сигнал не станет сильнее и grounded."
            case .decisions:
                return "Decision layer пока не видит достаточно плотного unresolved edge."
            case .lifeAdmin:
                return "Life admin ждёт более дешёвого operational окна."
            case .continuity:
                return "Continuity пока не сформировала новый visible return point."
            case .writingExpression:
                return "Writing lane latent: пока нет достаточно grounded angle."
            }
        }
        if !snapshot.proactiveEligible {
            if snapshot.remainingBudgetFactor < 0.25 {
                return "Домен виден, но дневной budget почти потрачен, поэтому новые артефакты держатся latent."
            }
            if snapshot.fatigue > 0.3 {
                return "Домен временно притушен fatigue/repetition control."
            }
            return "Сигнал есть, но governor пока держит этот домен latent."
        }
        return "Домен сейчас активен в attention market и имеет live candidates."
    }

    private func artifactPriority(
        _ lhs: AdvisoryArtifactRecord,
        _ rhs: AdvisoryArtifactRecord
    ) -> Bool {
        if lhs.status == rhs.status {
            let lhsScore = lhs.marketContext?.readinessSignal ?? lhs.marketScore
            let rhsScore = rhs.marketContext?.readinessSignal ?? rhs.marketScore
            if lhsScore == rhsScore {
                return lhs.confidence > rhs.confidence
            }
            return lhsScore > rhsScore
        }
        return statusRank(lhs.status) < statusRank(rhs.status)
    }

    private func statusRank(_ status: AdvisoryArtifactStatus) -> Int {
        switch status {
        case .surfaced: return 0
        case .queued: return 1
        case .candidate: return 2
        case .accepted: return 3
        case .muted: return 4
        case .dismissed: return 5
        case .expired: return 6
        }
    }
}
