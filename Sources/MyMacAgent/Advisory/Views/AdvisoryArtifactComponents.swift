import SwiftUI

struct AdvisoryArtifactCardView: View {
    let artifact: AdvisoryArtifactRecord
    var thread: AdvisoryThreadRecord? = nil
    var maxBodyLength: Int = 200
    var maxSteps: Int = 3
    var onOpenThread: ((String) -> Void)? = nil
    var onQuickAction: ((AdvisoryArtifactQuickAction) -> Void)? = nil
    var onFeedback: ((AdvisoryArtifactFeedbackKind) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbolName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(artifact.title)
                        .font(.subheadline.weight(.semibold))
                    Text("\(artifact.domain.label) · \(kindLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(statusLabel)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(accentColor.opacity(0.12)))
                    .foregroundStyle(accentColor)
            }

            if let highlightLine, !highlightLine.isEmpty {
                Text(highlightLine)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(accentColor)
            }

            Text(AdvisorySupport.cleanedSnippet(artifact.body, maxLength: maxBodyLength))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AdvisoryArtifactMetadataSummaryView(artifact: artifact, maxSteps: maxSteps)
            AdvisoryArtifactQuickActionsView(
                artifact: artifact,
                onMaterializeAction: onQuickAction
            )
            AdvisoryAttentionReasonView(artifact: artifact)

            if let whyNow = artifact.whyNow, !whyNow.isEmpty {
                Text(whyNow)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                if let threadId = artifact.threadId,
                   let thread,
                   let onOpenThread {
                    Button("Открыть нить: \(thread.displayTitle)") {
                        onOpenThread(threadId)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                Spacer()
            }

            AdvisoryArtifactFeedbackBar(artifact: artifact, onFeedback: onFeedback)
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

    private var highlightLine: String? {
        if let guidance = artifact.guidanceMetadata {
            switch artifact.domain {
            case .research:
                return guidance.focusQuestion ?? guidance.summary
            case .focus:
                return guidance.actionSteps.first ?? guidance.summary
            case .social:
                return guidance.candidateTask ?? guidance.summary
            case .health:
                return guidance.summary ?? guidance.actionSteps.first
            case .decisions, .lifeAdmin:
                return guidance.decisionText ?? guidance.candidateTask ?? guidance.openLoop
            case .continuity:
                return guidance.openLoop ?? guidance.summary
            case .writingExpression:
                return nil
            }
        }
        if let writing = artifact.writingMetadata {
            return writing.suggestedOpenings.first
        }
        return nil
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

    private var symbolName: String {
        switch artifact.kind {
        case .resumeCard: return "arrow.clockwise.circle"
        case .reflectionCard: return "rectangle.inset.filled.and.person.filled"
        case .tweetSeed: return "text.bubble"
        case .threadSeed: return "text.justify"
        case .noteSeed: return "note.text"
        case .researchDirection: return "magnifyingglass"
        case .patternNotice: return "waveform.path.ecg.text"
        case .weeklyReview: return "calendar.badge.clock"
        case .socialNudge: return "person.2"
        case .healthReflection: return "heart.text.square"
        case .lifeAdminReminder: return "checklist"
        case .focusIntervention: return "scope"
        case .decisionReminder: return "arrow.triangle.branch"
        case .explorationSeed: return "sparkles.magnifyingglass"
        case .missedSignal: return "exclamationmark.bubble"
        }
    }

    private var statusLabel: String {
        switch artifact.status {
        case .surfaced: return "Now"
        case .accepted: return "Accepted"
        case .queued: return "Queued"
        case .candidate: return "Candidate"
        case .dismissed: return "Dismissed"
        case .expired: return "Expired"
        case .muted: return "Muted"
        }
    }

    private var kindLabel: String {
        switch artifact.kind {
        case .resumeCard: return "Resume"
        case .reflectionCard: return "Reflection"
        case .tweetSeed: return "Tweet seed"
        case .threadSeed: return "Thread seed"
        case .noteSeed: return "Note seed"
        case .researchDirection: return "Research direction"
        case .patternNotice: return "Pattern notice"
        case .weeklyReview: return "Weekly review"
        case .socialNudge: return "Social nudge"
        case .healthReflection: return "Health reflection"
        case .lifeAdminReminder: return "Life admin"
        case .focusIntervention: return "Focus intervention"
        case .decisionReminder: return "Decision reminder"
        case .explorationSeed: return "Exploration seed"
        case .missedSignal: return "Missed signal"
        }
    }
}

struct AdvisoryArtifactQuickActionsView: View {
    let artifact: AdvisoryArtifactRecord
    var maxActions: Int = 2
    var emphasized: Bool = false
    var onMaterializeAction: ((AdvisoryArtifactQuickAction) -> Void)? = nil

    var body: some View {
        let actions = Array(artifact.quickActions.prefix(maxActions))
        if let onMaterializeAction, !actions.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(artifact.domain == .continuity ? "Быстрый возврат в контекст" : "Быстрые действия")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(accentColor)

                ForEach(actions) { action in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(action.label)
                                    .font((emphasized ? Font.caption.weight(.semibold) : Font.caption2.weight(.semibold)))
                                Text(continuityKindLabel(action.continuityKind))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(action.detail)
                                .font(emphasized ? .caption : .caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 10)
                        Button("Сохранить") {
                            onMaterializeAction(action)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(emphasized ? .small : .mini)
                    }
                    .padding(emphasized ? 10 : 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: emphasized ? 12 : 10, style: .continuous)
                            .fill(accentColor.opacity(emphasized ? 0.08 : 0.05))
                    )
                }
            }
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

    private func continuityKindLabel(_ kind: ContinuityItemKind) -> String {
        switch kind {
        case .openLoop: return "open loop"
        case .decision: return "решение"
        case .question: return "вопрос"
        case .commitment: return "следующий шаг"
        case .blockedItem: return "хвост"
        }
    }
}

private struct AdvisoryAttentionReasonView: View {
    let artifact: AdvisoryArtifactRecord

    var body: some View {
        let metrics = attentionHighlights
        if !metrics.isEmpty {
            Text(metrics.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var attentionHighlights: [String] {
        var highlights: [String] = []
        if let market = artifact.marketContext {
            if market.domainDemand > 0.1 {
                highlights.append("Demand \(percent(market.domainDemand))")
            }
            if market.domainRemainingBudgetFactor > 0.1 {
                highlights.append("Budget \(percent(market.domainRemainingBudgetFactor))")
            }
            if market.domainFatigue > 0.18 {
                highlights.append("Fatigue \(percent(market.domainFatigue))")
            }
        }
        if let vector = artifact.attentionVector {
            if vector.timingFit >= 0.45 {
                highlights.append("Timing \(percent(vector.timingFit))")
            }
            if vector.novelty >= 0.45 {
                highlights.append("Novelty \(percent(vector.novelty))")
            }
            if vector.urgency >= 0.45 {
                highlights.append("Urgency \(percent(vector.urgency))")
            }
            if vector.focusStateFit >= 0.45 {
                highlights.append("Focus fit \(percent(vector.focusStateFit))")
            }
        }
        return AdvisorySupport.dedupe(highlights)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }
}

struct AdvisoryArtifactMetadataSummaryView: View {
    let artifact: AdvisoryArtifactRecord
    var maxSteps: Int = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let writing = artifact.writingMetadata {
                writingSection(writing)
            } else if let guidance = artifact.guidanceMetadata {
                guidanceSection(guidance)
            }
        }
    }

    @ViewBuilder
    private func writingSection(_ writing: AdvisoryWritingArtifactMetadata) -> some View {
        advisoryGroup(title: "Writing angle", tint: .indigo) {
            advisoryLabelValue("Angle", writing.primaryAngle.label)
            if !writing.alternativeAngles.isEmpty {
                advisoryLabelValue("Alternatives", writing.alternativeAngles.map(\.label).joined(separator: " · "))
            }
            if let opening = writing.suggestedOpenings.first, !opening.isEmpty {
                Text(AdvisorySupport.cleanedSnippet(opening, maxLength: 120))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }

        if let continuityAnchor = writing.continuityAnchor, !continuityAnchor.isEmpty {
            advisoryGroup(title: "Continuity", tint: .accentColor) {
                advisoryLabelValue("Anchor", continuityAnchor)
            }
        }

        groundingSection(
            evidence: writing.evidencePack,
            noteAnchorTitle: nil,
            noteAnchorSnippet: nil,
            timingWindow: writing.timingWindow,
            enrichmentSources: writing.enrichmentSources,
            sourceAnchors: writing.sourceAnchors
        )
    }

    @ViewBuilder
    private func guidanceSection(_ guidance: AdvisoryArtifactGuidanceMetadata) -> some View {
        switch artifact.domain {
        case .continuity:
            advisoryGroup(title: guidance.patternName ?? "Continuity", tint: .accentColor) {
                if let openLoop = guidance.openLoop, !openLoop.isEmpty {
                    advisoryLabelValue("Open loop", openLoop)
                }
                if let continuityAnchor = guidance.continuityAnchor, !continuityAnchor.isEmpty {
                    advisoryLabelValue("Return point", continuityAnchor)
                }
                actionSteps(guidance.actionSteps)
            }
        case .writingExpression:
            EmptyView()
        case .research:
            advisoryGroup(title: guidance.patternName ?? "Research direction", tint: .blue) {
                if let focusQuestion = guidance.focusQuestion, !focusQuestion.isEmpty {
                    advisoryLabelValue("Question", focusQuestion)
                }
                if let summary = guidance.summary, !summary.isEmpty {
                    advisoryLabelValue("Why this angle", summary)
                }
                actionSteps(guidance.actionSteps)
            }
        case .focus:
            advisoryGroup(title: guidance.patternName ?? "Focus intervention", tint: .orange) {
                if let summary = guidance.summary, !summary.isEmpty {
                    advisoryLabelValue("Pattern", summary)
                }
                actionSteps(guidance.actionSteps)
            }
        case .social:
            advisoryGroup(title: guidance.patternName ?? "Social nudge", tint: .pink) {
                if let candidateTask = guidance.candidateTask, !candidateTask.isEmpty {
                    advisoryLabelValue("Nudge", candidateTask)
                }
                if let summary = guidance.summary, !summary.isEmpty {
                    advisoryLabelValue("Why this person/thread", summary)
                }
                actionSteps(guidance.actionSteps)
            }
        case .health:
            advisoryGroup(title: guidance.patternName ?? "Health reflection", tint: .green) {
                if let summary = guidance.summary, !summary.isEmpty {
                    advisoryLabelValue("Observe", summary)
                }
                actionSteps(guidance.actionSteps)
            }
        case .decisions:
            advisoryGroup(title: guidance.patternName ?? "Decision reminder", tint: .red) {
                if let decisionText = guidance.decisionText, !decisionText.isEmpty {
                    advisoryLabelValue("Decision edge", decisionText)
                }
                if let candidateTask = guidance.candidateTask, !candidateTask.isEmpty {
                    advisoryLabelValue("If you revisit", candidateTask)
                }
                actionSteps(guidance.actionSteps)
            }
        case .lifeAdmin:
            advisoryGroup(title: guidance.patternName ?? "Life admin reminder", tint: .brown) {
                if let candidateTask = guidance.candidateTask, !candidateTask.isEmpty {
                    advisoryLabelValue("Likely task", candidateTask)
                }
                if let openLoop = guidance.openLoop, !openLoop.isEmpty {
                    advisoryLabelValue("Admin tail", openLoop)
                }
                actionSteps(guidance.actionSteps)
            }
        }

        groundingSection(
            evidence: guidance.evidencePack,
            noteAnchorTitle: guidance.noteAnchorTitle,
            noteAnchorSnippet: guidance.noteAnchorSnippet,
            timingWindow: guidance.timingWindow,
            enrichmentSources: guidance.enrichmentSources,
            sourceAnchors: guidance.sourceAnchors
        )
    }

    @ViewBuilder
    private func groundingSection(
        evidence: [String],
        noteAnchorTitle: String?,
        noteAnchorSnippet: String?,
        timingWindow: String?,
        enrichmentSources: [AdvisoryEnrichmentSource],
        sourceAnchors: [String]
    ) -> some View {
        if !evidence.isEmpty
            || (noteAnchorTitle?.isEmpty == false)
            || (timingWindow?.isEmpty == false)
            || !enrichmentSources.isEmpty
            || !sourceAnchors.isEmpty {
            advisoryGroup(title: "Grounding", tint: .secondary) {
                if let noteAnchorTitle, !noteAnchorTitle.isEmpty {
                    let snippet = noteAnchorSnippet.map { " — \($0)" } ?? ""
                    advisoryLabelValue("Note", noteAnchorTitle + snippet)
                }
                if let timingWindow, !timingWindow.isEmpty {
                    advisoryLabelValue("Timing", timingWindow)
                }
                if !enrichmentSources.isEmpty {
                    advisoryLabelValue("Context", enrichmentSources.map(\.label).joined(separator: " · "))
                }
                if !sourceAnchors.isEmpty {
                    advisoryLabelValue("Source anchors", sourceAnchors.prefix(2).joined(separator: " · "), selectable: true)
                }
                if !evidence.isEmpty {
                    advisoryLabelValue("Evidence", evidence.prefix(3).joined(separator: ", "), selectable: true)
                }
            }
        }
    }

    @ViewBuilder
    private func actionSteps(_ steps: [String]) -> some View {
        if !steps.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text("Optional next")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                ForEach(Array(steps.prefix(maxSteps)), id: \.self) { step in
                    Text("• \(step)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func advisoryGroup<Content: View>(
        title: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(tint)
            content()
        }
    }

    private func advisoryLabelValue(
        _ label: String,
        _ value: String,
        selectable: Bool = false
    ) -> some View {
        Group {
            if selectable {
                Text("\(label): \(value)")
                    .textSelection(.enabled)
            } else {
                Text("\(label): \(value)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct AdvisoryArtifactFeedbackBar: View {
    let artifact: AdvisoryArtifactRecord
    var onFeedback: ((AdvisoryArtifactFeedbackKind) -> Void)? = nil

    var body: some View {
        if let onFeedback {
            HStack(spacing: 8) {
                feedbackButton(.useful, action: onFeedback)
                feedbackButton(.notNow, action: onFeedback)
                feedbackButton(.moreLikeThis, action: onFeedback)
                feedbackButton(.muteKind, action: onFeedback)
                Menu("More") {
                    Button(AdvisoryArtifactFeedbackKind.tooObvious.label) { onFeedback(.tooObvious) }
                    Button(AdvisoryArtifactFeedbackKind.tooBossy.label) { onFeedback(.tooBossy) }
                    Button(AdvisoryArtifactFeedbackKind.wrong.label) { onFeedback(.wrong) }
                }
                .font(.caption2)
            }
            Text("Useful boosts similar signals. Not now delays resurfacing. Mute kind suppresses this lane for a while.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func feedbackButton(
        _ kind: AdvisoryArtifactFeedbackKind,
        action: @escaping (AdvisoryArtifactFeedbackKind) -> Void
    ) -> some View {
        Button(kind.label) {
            action(kind)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .font(.caption2)
    }
}
