import Foundation

struct AdvisoryArtifactQuickAction: Identifiable, Equatable {
    let id: String
    let label: String
    let detail: String
    let continuityKind: ContinuityItemKind
    let title: String
    let body: String?
    let threadId: String?
}

struct AdvisoryArtifactQuickActionOutcome: Equatable {
    let artifact: AdvisoryArtifactRecord
    let action: AdvisoryArtifactQuickAction
    let continuityItem: ContinuityItemRecord
    let reusedExistingItem: Bool
}

extension AdvisoryArtifactRecord {
    var quickActions: [AdvisoryArtifactQuickAction] {
        guard isQuickActionEligible else { return [] }
        return AdvisoryArtifactQuickActionBuilder.quickActions(for: self)
    }

    private var isQuickActionEligible: Bool {
        switch status {
        case .dismissed, .expired, .muted:
            return false
        case .candidate, .queued, .surfaced, .accepted:
            return true
        }
    }
}

private enum AdvisoryArtifactQuickActionBuilder {
    static func quickActions(for artifact: AdvisoryArtifactRecord) -> [AdvisoryArtifactQuickAction] {
        var actions: [AdvisoryArtifactQuickAction] = []
        if let guidance = artifact.guidanceMetadata {
            actions.append(contentsOf: guidanceActions(for: artifact, guidance: guidance))
        }
        return dedupe(actions).prefix(2).map { $0 }
    }

    private static func guidanceActions(
        for artifact: AdvisoryArtifactRecord,
        guidance: AdvisoryArtifactGuidanceMetadata
    ) -> [AdvisoryArtifactQuickAction] {
        switch artifact.domain {
        case .continuity:
            return [
                makeAction(
                    artifact: artifact,
                    label: "Сохранить точку возврата",
                    detail: guidance.continuityAnchor,
                    continuityKind: .commitment,
                    bodyCandidates: [guidance.summary, guidance.openLoop, artifact.whyNow]
                ),
                makeAction(
                    artifact: artifact,
                    label: "Сохранить open loop",
                    detail: guidance.openLoop,
                    continuityKind: .openLoop,
                    bodyCandidates: [guidance.summary, guidance.continuityAnchor, artifact.whyNow]
                ),
                makeAction(
                    artifact: artifact,
                    label: "Сохранить следующий шаг",
                    detail: guidance.actionSteps.first,
                    continuityKind: .commitment,
                    bodyCandidates: [guidance.summary, guidance.openLoop, guidance.continuityAnchor]
                )
            ].compactMap { $0 }
        case .writingExpression:
            return []
        case .research:
            return [
                makeAction(
                    artifact: artifact,
                    label: "Сохранить вопрос",
                    detail: guidance.focusQuestion,
                    continuityKind: .question,
                    bodyCandidates: [guidance.summary, guidance.noteAnchorSnippet, artifact.whyNow]
                ),
                makeAction(
                    artifact: artifact,
                    label: "Сохранить следующий шаг",
                    detail: guidance.actionSteps.first,
                    continuityKind: .commitment,
                    bodyCandidates: [guidance.summary, guidance.focusQuestion, artifact.whyNow]
                )
            ].compactMap { $0 }
        case .focus:
            return [
                makeAction(
                    artifact: artifact,
                    label: "Сохранить мягкий reset",
                    detail: guidance.actionSteps.first,
                    continuityKind: .blockedItem,
                    bodyCandidates: [guidance.summary, artifact.whyNow]
                )
            ].compactMap { $0 }
        case .social:
            return [
                makeAction(
                    artifact: artifact,
                    label: "Сохранить мягкий пинг",
                    detail: guidance.candidateTask ?? guidance.actionSteps.first,
                    continuityKind: .commitment,
                    bodyCandidates: [guidance.summary, artifact.whyNow]
                )
            ].compactMap { $0 }
        case .health:
            return [
                makeAction(
                    artifact: artifact,
                    label: "Сохранить бережный check-in",
                    detail: guidance.actionSteps.first,
                    continuityKind: .commitment,
                    bodyCandidates: [guidance.summary, artifact.whyNow]
                )
            ].compactMap { $0 }
        case .decisions:
            return [
                makeAction(
                    artifact: artifact,
                    label: "Сохранить decision edge",
                    detail: guidance.decisionText,
                    continuityKind: .decision,
                    bodyCandidates: [guidance.summary, guidance.candidateTask, artifact.whyNow]
                ),
                makeAction(
                    artifact: artifact,
                    label: "Сохранить следующий шаг",
                    detail: guidance.candidateTask ?? guidance.actionSteps.first,
                    continuityKind: .commitment,
                    bodyCandidates: [guidance.summary, guidance.decisionText, artifact.whyNow]
                )
            ].compactMap { $0 }
        case .lifeAdmin:
            return [
                makeAction(
                    artifact: artifact,
                    label: "Сохранить admin tail",
                    detail: guidance.openLoop,
                    continuityKind: .blockedItem,
                    bodyCandidates: [guidance.summary, guidance.candidateTask, artifact.whyNow]
                ),
                makeAction(
                    artifact: artifact,
                    label: "Сохранить следующий шаг",
                    detail: guidance.candidateTask ?? guidance.actionSteps.first,
                    continuityKind: .commitment,
                    bodyCandidates: [guidance.summary, guidance.openLoop, artifact.whyNow]
                )
            ].compactMap { $0 }
        }
    }
    private static func makeAction(
        artifact: AdvisoryArtifactRecord,
        label: String,
        detail: String?,
        continuityKind: ContinuityItemKind,
        bodyCandidates: [String?]
    ) -> AdvisoryArtifactQuickAction? {
        guard let title = cleaned(detail) else { return nil }
        let body = bodyText(
            candidates: bodyCandidates,
            excluding: title
        )
        return AdvisoryArtifactQuickAction(
            id: AdvisorySupport.stableIdentifier(
                prefix: "advaction",
                components: [artifact.id, continuityKind.rawValue, title]
            ),
            label: label,
            detail: title,
            continuityKind: continuityKind,
            title: title,
            body: body,
            threadId: artifact.threadId
        )
    }

    private static func bodyText(
        candidates: [String?],
        excluding title: String
    ) -> String? {
        let snippets = candidates.compactMap(cleaned).filter {
            $0.caseInsensitiveCompare(title) != .orderedSame
        }
        guard !snippets.isEmpty else { return nil }
        return AdvisorySupport.cleanedSnippet(
            AdvisorySupport.dedupe(snippets).joined(separator: " "),
            maxLength: 220
        )
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = AdvisorySupport.cleanedSnippet(value, maxLength: 160)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func dedupe(_ actions: [AdvisoryArtifactQuickAction]) -> [AdvisoryArtifactQuickAction] {
        var seen = Set<String>()
        var result: [AdvisoryArtifactQuickAction] = []
        for action in actions {
            let key = [
                action.continuityKind.rawValue,
                AdvisorySupport.slug(for: action.title)
            ].joined(separator: "|")
            guard seen.insert(key).inserted else { continue }
            result.append(action)
        }
        return result
    }
}
