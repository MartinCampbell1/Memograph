import Foundation

struct FeedbackShapingPolicy {
    private let rollingWindowDays = 21.0

    func summarize(
        for candidate: AdvisoryArtifactRecord,
        feedback: [AdvisoryArtifactFeedbackRecord],
        artifactsById: [String: AdvisoryArtifactRecord],
        now: Date,
        dateSupport: LocalDateSupport
    ) -> FeedbackShapingSummary {
        let cutoff = now.addingTimeInterval(-(rollingWindowDays * 24 * 3600))
        var modifier = 0.0
        var cooldownPenalty = 0.0
        var mutePenalty = 0.0
        var groundingPenalty = 0.0
        var tonePenalty = 0.0
        var reasonCodes: [String] = []

        for item in feedback {
            guard let historical = artifactsById[item.artifactId],
                  let createdAt = item.createdAt.flatMap(dateSupport.parseDateTime),
                  createdAt >= cutoff else {
                continue
            }

            let relevance = relevance(of: item.feedbackKind, candidate: candidate, historical: historical)
            guard relevance > 0 else { continue }

            let ageHours = max(0, now.timeIntervalSince(createdAt) / 3600)
            let temporalWeight = temporalWeight(ageHours: ageHours)
            let weight = min(1.0, max(0.05, relevance * temporalWeight))

            switch item.feedbackKind {
            case .useful:
                modifier += 0.08 * weight
                appendReason("useful", to: &reasonCodes)
            case .moreLikeThis:
                modifier += 0.12 * weight
                appendReason("more_like_this", to: &reasonCodes)
            case .tooObvious:
                modifier -= 0.1 * weight
                appendReason("too_obvious", to: &reasonCodes)
            case .tooBossy:
                tonePenalty += 0.16 * weight
                appendReason("too_bossy", to: &reasonCodes)
            case .wrong:
                groundingPenalty += 0.18 * weight
                appendReason("wrong", to: &reasonCodes)
            case .notNow:
                cooldownPenalty += notNowPenalty(ageHours: ageHours, relevance: relevance)
                appendReason("not_now", to: &reasonCodes)
            case .muteKind:
                mutePenalty += muteSuppressionPenalty(for: candidate, historical: historical, ageHours: ageHours)
                appendReason("mute_kind", to: &reasonCodes)
            }
        }

        return FeedbackShapingSummary(
            modifier: min(0.3, max(-0.3, modifier)),
            cooldownPenalty: min(0.8, max(0, cooldownPenalty)),
            mutePenalty: min(1.0, max(0, mutePenalty)),
            groundingPenalty: min(0.35, max(0, groundingPenalty)),
            tonePenalty: min(0.3, max(0, tonePenalty)),
            reasonCodes: reasonCodes
        )
    }

    private func relevance(
        of feedbackKind: AdvisoryArtifactFeedbackKind,
        candidate: AdvisoryArtifactRecord,
        historical: AdvisoryArtifactRecord
    ) -> Double {
        if candidate.id == historical.id {
            return 1.0
        }

        let sameTitle = AdvisorySupport.slug(for: candidate.title) == AdvisorySupport.slug(for: historical.title)
        let sameThread = candidate.threadId != nil && candidate.threadId == historical.threadId
        let sameKind = candidate.kind == historical.kind
        let sameRecipe = candidate.sourceRecipe != nil && candidate.sourceRecipe == historical.sourceRecipe
        let sameDomain = candidate.domain == historical.domain

        var relevance = 0.0
        if sameTitle { relevance += 0.34 }
        if sameThread { relevance += 0.32 }
        if sameKind { relevance += 0.24 }
        if sameRecipe { relevance += 0.18 }
        if sameDomain { relevance += 0.14 }

        switch feedbackKind {
        case .muteKind:
            if sameKind { return 1.0 }
            if sameDomain { return 0.55 }
            return 0
        case .notNow:
            return min(1.0, relevance + (sameThread ? 0.08 : 0))
        default:
            return min(1.0, relevance)
        }
    }

    private func temporalWeight(ageHours: Double) -> Double {
        switch ageHours {
        case ..<24: return 1.0
        case ..<72: return 0.85
        case ..<168: return 0.65
        case ..<336: return 0.5
        default: return 0.35
        }
    }

    private func notNowPenalty(ageHours: Double, relevance: Double) -> Double {
        let suppressionWindowHours = relevance >= 0.65 ? 36.0 : 18.0
        if ageHours < suppressionWindowHours {
            let freshness = 1.0 - (ageHours / suppressionWindowHours)
            return (0.18 + freshness * 0.42) * max(0.35, relevance)
        }

        let tailWindowHours = suppressionWindowHours + 96.0
        guard ageHours < tailWindowHours else { return 0 }
        let tail = 1.0 - ((ageHours - suppressionWindowHours) / (tailWindowHours - suppressionWindowHours))
        return 0.1 * max(0.25, relevance) * tail
    }

    private func muteSuppressionPenalty(
        for candidate: AdvisoryArtifactRecord,
        historical: AdvisoryArtifactRecord,
        ageHours: Double
    ) -> Double {
        let sameKind = candidate.kind == historical.kind
        let sameDomain = candidate.domain == historical.domain
        guard sameKind || sameDomain else { return 0 }

        let windowHours = sameKind ? 96.0 : 48.0
        guard ageHours < windowHours else { return 0 }
        let freshness = 1.0 - (ageHours / windowHours)
        return (sameKind ? 0.9 : 0.55) * freshness
    }

    private func appendReason(_ reason: String, to reasons: inout [String]) {
        guard !reasons.contains(reason) else { return }
        reasons.append(reason)
    }
}
