import SwiftUI

struct ResumeCardView: View {
    let artifact: AdvisoryArtifactRecord
    let thread: AdvisoryThreadRecord?
    let continuityItems: [ContinuityItemRecord]
    var onOpenThread: (() -> Void)? = nil
    var onQuickAction: ((AdvisoryArtifactQuickAction) -> Void)? = nil
    var onFeedback: ((AdvisoryArtifactFeedbackKind) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(surfaceTitle)
                        .font(.headline)
                    Text(surfaceHeadline)
                        .font(.title3.weight(.semibold))
                    if let surfaceSubheadline {
                        Text(surfaceSubheadline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(artifact.domain.label)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(accentColor.opacity(0.12)))
                    if artifact.status == .surfaced {
                        Text("Surfaced")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(accentColor.opacity(0.18)))
                    }
                }
            }

            if let onOpenThread, thread != nil {
                Button("Открыть нить", action: onOpenThread)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            Text(artifact.body)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            AdvisoryArtifactQuickActionsView(
                artifact: artifact,
                emphasized: true,
                onMaterializeAction: onQuickAction
            )
            AdvisoryArtifactMetadataSummaryView(artifact: artifact)
            AdvisoryArtifactCardViewAttentionOnly(artifact: artifact)

            if artifact.domain == .continuity && !continuityItems.isEmpty {
                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Open loops")
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(continuityItems.prefix(3))) { item in
                        Text("• \(item.title)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let whyNow = artifact.whyNow, !whyNow.isEmpty {
                Divider()
                Text(whyNow)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AdvisoryArtifactFeedbackBar(artifact: artifact, onFeedback: onFeedback)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(accentColor.opacity(0.14), lineWidth: 1)
        )
    }

    private var surfaceTitle: String {
        artifact.domain == .continuity ? "Resume Me" : "Advisor Now"
    }

    private var surfaceHeadline: String {
        thread?.displayTitle ?? artifact.title
    }

    private var surfaceSubheadline: String? {
        switch artifact.domain {
        case .continuity:
            return "Мягкий вход обратно в контекст."
        case .research:
            return "Похоже, сейчас есть живой research angle, но без жёсткого push."
        case .focus:
            return "Сигнал скорее про pacing и re-entry cost, чем про productivity pressure."
        case .social:
            return "Небольшой social nudge, если окно реально есть."
        case .health:
            return "Наблюдение про темп и бережность, не директива."
        case .decisions:
            return "Незакрытый decision edge снова всплыл."
        case .lifeAdmin:
            return "Видимый life-admin tail, который лучше не делать невидимым."
        case .writingExpression:
            return "Похоже, здесь есть content angle, который уже grounded в контексте."
        }
    }

    private var accentColor: Color {
        switch artifact.domain {
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
}

private struct AdvisoryArtifactCardViewAttentionOnly: View {
    let artifact: AdvisoryArtifactRecord

    var body: some View {
        if let market = artifact.marketContext {
            Text("Attention: demand \(percent(market.domainDemand)) · budget \(percent(market.domainRemainingBudgetFactor))\(market.domainFatigue > 0.18 ? " · fatigue \(percent(market.domainFatigue))" : "")")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }
}
