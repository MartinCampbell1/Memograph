import SwiftUI

struct AdvisoryDomainWorkspaceView: View {
    let detail: AdvisoryDomainWorkspaceDetail
    let threadsById: [String: AdvisoryThreadRecord]
    var onRunAction: (() -> Void)? = nil
    var onClearSelection: (() -> Void)? = nil
    var onOpenThread: ((String) -> Void)? = nil
    var onQuickAction: ((String, AdvisoryArtifactQuickAction) -> Void)? = nil
    var onFeedback: ((String, AdvisoryArtifactFeedbackKind) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let leadArtifact = detail.leadArtifact {
                AdvisoryArtifactCardView(
                    artifact: leadArtifact,
                    thread: leadArtifact.threadId.flatMap { threadsById[$0] },
                    maxBodyLength: 180,
                    maxSteps: 2,
                    onOpenThread: onOpenThread,
                    onQuickAction: { action in
                        onQuickAction?(leadArtifact.id, action)
                    },
                    onFeedback: { kind in
                        onFeedback?(leadArtifact.id, kind)
                    }
                )
            } else {
                quietState
            }

            if !detail.relatedThreads.isEmpty {
                threadSection
            }

            if !detail.continuityItems.isEmpty {
                continuitySection
            }

            if !detail.feedbackSummaries.isEmpty || !detail.recentFeedback.isEmpty {
                feedbackSection
            }

            if !detail.enrichmentStatuses.isEmpty || !detail.sourceAnchors.isEmpty || !detail.evidenceRefs.isEmpty {
                groundingSection
            }

            if recentArtifacts.count > 0 {
                recentArtifactsSection
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accentColor.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(accentColor.opacity(0.12), lineWidth: 1)
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(detail.domain.label) workspace")
                    .font(.headline)
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    metricPill("Demand", value: detail.market.demand)
                    metricPill("Budget", value: detail.market.remainingBudgetFactor)
                    if detail.market.fatigue > 0.12 {
                        metricPill("Fatigue", value: detail.market.fatigue)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                if let onRunAction {
                    Button("Pull") {
                        onRunAction()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                if let onClearSelection {
                    Button("Clear focus") {
                        onClearSelection()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var quietState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(quietTitle)
                .font(.subheadline.weight(.semibold))
            Text(quietBody)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private var threadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Related threads")
                .font(.subheadline.weight(.semibold))
            ForEach(detail.relatedThreads.prefix(4)) { thread in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(thread.displayTitle)
                            .font(.caption.weight(.medium))
                        Text(threadSummary(thread))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let onOpenThread {
                        Button("Open") {
                            onOpenThread(thread.id)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var continuitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open loops around this lane")
                .font(.subheadline.weight(.semibold))
            ForEach(detail.continuityItems.prefix(4)) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.caption.weight(.medium))
                    if let body = item.body, !body.isEmpty {
                        Text(AdvisorySupport.cleanedSnippet(body, maxLength: 120))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Feedback memory")
                .font(.subheadline.weight(.semibold))
            if !detail.feedbackSummaries.isEmpty {
                FlexibleFeedbackRow(items: detail.feedbackSummaries)
            }
            if !detail.recentFeedback.isEmpty {
                Text("Recent: \(detail.recentFeedback.prefix(3).map { $0.feedbackKind.label }.joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var groundingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Grounding")
                .font(.subheadline.weight(.semibold))
            if !detail.enrichmentStatuses.isEmpty {
                AdvisoryEnrichmentStatusView(
                    sources: detail.enrichmentStatuses,
                    showHeader: false
                )
            }
            if !detail.sourceAnchors.isEmpty {
                Text("Source anchors: \(detail.sourceAnchors.prefix(4).joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !detail.evidenceRefs.isEmpty {
                Text("Evidence refs: \(detail.evidenceRefs.prefix(4).joined(separator: " · "))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var recentArtifactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent in this lane")
                .font(.subheadline.weight(.semibold))
            ForEach(recentArtifacts.prefix(3)) { artifact in
                AdvisoryArtifactCardView(
                    artifact: artifact,
                    thread: artifact.threadId.flatMap { threadsById[$0] },
                    maxBodyLength: 140,
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

    private var recentArtifacts: [AdvisoryArtifactRecord] {
        guard let leadArtifact = detail.leadArtifact else { return detail.recentArtifacts }
        return detail.recentArtifacts.filter { $0.id != leadArtifact.id }
    }

    private var summaryLine: String {
        if detail.market.activeArtifactCount == 0 {
            return "Этот домен сейчас тихий, но остаётся частью общего attention market и не выпадает из advisor."
        }
        return "Now \(detail.market.surfacedCount) · queued \(detail.market.queuedCount) · candidate \(detail.market.candidateCount) · \(detail.groundingSources.map { $0.label }.joined(separator: " · "))"
    }

    private var quietTitle: String {
        switch detail.domain {
        case .social:
            return "Социальный домен держится тихо"
        case .health:
            return "Health layer не должен звучать шумно"
        case .decisions:
            return "Decision layer ждёт более явного edge"
        case .lifeAdmin:
            return "Life admin лучше всплывает в дешёвые operational окна"
        case .focus:
            return "Focus ждёт более подходящего момента"
        case .research:
            return "Research lane латентен, пока нет хорошего окна на exploration"
        case .continuity:
            return "Continuity пока не собрала новый return point"
        case .writingExpression:
            return "Writing lane ждёт более grounded angle"
        }
    }

    private var quietBody: String {
        if detail.groundingSources.isEmpty {
            return "Можно сделать ручной pull, но governor пока не видит достаточно evidence и timing fit для мягкого surfacing."
        }
        return "Market пока не дал этой линии выйти наверх. Доступные grounding sources: \(detail.groundingSources.map { $0.label }.joined(separator: " · "))."
    }

    private var accentColor: Color {
        switch detail.domain {
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

    private var symbolName: String {
        switch detail.domain {
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

    private func threadSummary(_ thread: AdvisoryThreadRecord) -> String {
        let parts = [
            thread.status.rawValue,
            thread.totalActiveMinutes > 0 ? "\(thread.totalActiveMinutes) min" : nil,
            thread.lastArtifactAt ?? thread.lastActiveAt
        ].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    private func metricPill(_ title: String, value: Double) -> some View {
        Text("\(title) \(Int((max(0, min(1, value)) * 100).rounded()))%")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
    }
}

private struct FlexibleFeedbackRow: View {
    let items: [AdvisoryDomainFeedbackSummary]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                Text("\(item.kind.label) · \(item.count)")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
        }
    }
}
