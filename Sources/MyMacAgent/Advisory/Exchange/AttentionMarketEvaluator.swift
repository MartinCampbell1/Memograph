import Foundation

// Evaluates candidates inside each domain; cross-domain allocation happens in AttentionGovernor.
struct AttentionMarketEvaluator {
    private let feedbackPolicy = FeedbackShapingPolicy()
    private let timingPolicy = AttentionTimingPolicy()

    func evaluate(
        candidates: [AdvisoryArtifactRecord],
        recentSurfaced: [AdvisoryArtifactRecord],
        feedback: [AdvisoryArtifactFeedbackRecord],
        feedbackArtifactsById: [String: AdvisoryArtifactRecord],
        threadsById: [String: AdvisoryThreadRecord],
        guidance: GuidanceProfile,
        dayContext: AdvisoryDayContext,
        domainStates: [AdvisoryDomain: DomainAttentionState],
        now: Date,
        dateSupport: LocalDateSupport
    ) -> [MarketEvaluatedArtifact] {
        let byDomain = Dictionary(grouping: candidates, by: \.domain)
        var evaluated: [MarketEvaluatedArtifact] = []

        for (domain, domainCandidates) in byDomain {
            let state = domainStates[domain] ?? DomainAttentionState(
                domain: domain,
                demand: domain.defaultBaseWeight,
                fatigue: 0,
                balancePressure: 0,
                surfacedTodayCount: 0,
                slotBudget: domain.defaultDailySlotBudget,
                remainingBudgetFactor: 1,
                allocationWeight: domain.defaultBaseWeight,
                reason: "default"
            )

            let adaptiveGapMinutes = timingPolicy.adaptiveMinGapMinutes(for: dayContext, guidance: guidance)
            let vectors = domainCandidates.map { artifact -> (AdvisoryArtifactRecord, ArtifactAttentionVector, Double, Bool) in
                let vector = buildVector(
                    artifact: artifact,
                    recentSurfaced: recentSurfaced,
                    feedback: feedback,
                    feedbackArtifactsById: feedbackArtifactsById,
                    thread: artifact.threadId.flatMap { threadsById[$0] },
                    guidance: guidance,
                    dayContext: dayContext,
                    domainState: state,
                    now: now,
                    dateSupport: dateSupport
                )
                let readinessSignal = readinessSignal(for: vector)
                let proactiveEligible = proactiveEligibility(
                    for: artifact,
                    vector: vector,
                    dayContext: dayContext
                )
                return (artifact, vector, readinessSignal, proactiveEligible)
            }

            let rankedInDomain = vectors.sorted { lhs, rhs in
                compare(lhs: lhs.1, rhs: rhs.1, lhsReadiness: lhs.2, rhsReadiness: rhs.2)
            }

            for (index, tuple) in rankedInDomain.enumerated() {
                let context = AttentionMarketContext(
                    domain: domain,
                    readinessSignal: tuple.2,
                    domainAllocationWeight: state.allocationWeight,
                    domainDemand: state.demand,
                    domainFatigue: state.fatigue,
                    domainBalancePressure: state.balancePressure,
                    domainRemainingBudgetFactor: state.remainingBudgetFactor,
                    focusState: dayContext.focusState,
                    proactiveEligible: tuple.3,
                    adaptiveGapMinutes: adaptiveGapMinutes,
                    timingSuppressionPenalty: tuple.1.threadCooldownPenalty,
                    feedbackModifier: tuple.1.feedbackModifier,
                    feedbackSuppressionPenalty: tuple.1.cooldownPenalty + tuple.1.mutePenalty + tuple.1.groundingPenalty + tuple.1.tonePenalty,
                    feedbackReasonCodes: tuple.1.feedbackReasonCodes
                )
                evaluated.append(MarketEvaluatedArtifact(
                    artifact: tuple.0,
                    attentionVector: tuple.1,
                    marketContext: context,
                    domainRank: index + 1
                ))
            }
        }

        return evaluated
    }

    func isSelectable(_ evaluated: MarketEvaluatedArtifact) -> Bool {
        let vector = evaluated.attentionVector
        let grounding = max(0, min(vector.confidence, vector.evidenceStrength) - vector.groundingPenalty)
        return grounding >= 0.38
            && vector.mutePenalty < 0.75
            && vector.cooldownPenalty < 0.68
            && (vector.urgency >= 0.34 || vector.novelty >= 0.42 || vector.timingFit >= 0.4)
            && evaluated.marketContext.readinessSignal >= 0.36
    }

    func shouldRemainLatent(_ evaluated: MarketEvaluatedArtifact) -> Bool {
        let vector = evaluated.attentionVector
        let grounding = max(0, min(vector.confidence, vector.evidenceStrength) - vector.groundingPenalty)
        if evaluated.marketContext.readinessSignal >= 0.22 {
            return true
        }
        if grounding >= 0.38
            && (vector.threadCooldownPenalty >= 0.18
                || vector.cooldownPenalty >= 0.18
                || vector.mutePenalty >= 0.18
                || vector.repetitionPenalty >= 0.18) {
            return true
        }
        return vector.timingFit >= 0.4 || vector.focusStateFit >= 0.42
    }

    private func buildVector(
        artifact: AdvisoryArtifactRecord,
        recentSurfaced: [AdvisoryArtifactRecord],
        feedback: [AdvisoryArtifactFeedbackRecord],
        feedbackArtifactsById: [String: AdvisoryArtifactRecord],
        thread: AdvisoryThreadRecord?,
        guidance: GuidanceProfile,
        dayContext: AdvisoryDayContext,
        domainState: DomainAttentionState,
        now: Date,
        dateSupport: LocalDateSupport
    ) -> ArtifactAttentionVector {
        let evidenceStrength = min(1.0, Double(artifact.evidenceRefs.count) / 5.0)
        let novelty = novelty(for: artifact, recentSurfaced: recentSurfaced)
        let urgency = urgency(for: artifact, thread: thread, dayContext: dayContext)
        let focusStateFit = timingPolicy.focusStateFit(for: artifact, dayContext: dayContext)
        let timingFit = timingFit(
            for: artifact,
            dayContext: dayContext,
            focusStateFit: focusStateFit,
            recentSurfaced: recentSurfaced,
            now: now,
            dateSupport: dateSupport
        )
        let fatiguePenalty = min(0.45, domainState.fatigue * 0.55)
        let repetitionPenalty = repetitionPenalty(for: artifact, recentSurfaced: recentSurfaced, now: now, dateSupport: dateSupport)
        let threadCooldownPenalty = timingPolicy.threadCooldownPenalty(
            for: artifact,
            recentSurfaced: recentSurfaced,
            guidance: guidance,
            dayContext: dayContext,
            now: now,
            dateSupport: dateSupport
        )
        let categoryBalanceLift = max(0, domainState.balancePressure) * 0.35
        let feedbackShaping = feedbackPolicy.summarize(
            for: artifact,
            feedback: feedback,
            artifactsById: feedbackArtifactsById,
            now: now,
            dateSupport: dateSupport
        )

        return ArtifactAttentionVector(
            confidence: artifact.confidence,
            evidenceStrength: evidenceStrength,
            novelty: novelty,
            urgency: urgency,
            timingFit: timingFit,
            focusStateFit: focusStateFit,
            fatiguePenalty: fatiguePenalty,
            repetitionPenalty: repetitionPenalty,
            threadCooldownPenalty: threadCooldownPenalty,
            categoryBalanceLift: categoryBalanceLift,
            feedbackModifier: feedbackShaping.modifier,
            cooldownPenalty: feedbackShaping.cooldownPenalty,
            mutePenalty: feedbackShaping.mutePenalty,
            groundingPenalty: feedbackShaping.groundingPenalty,
            tonePenalty: feedbackShaping.tonePenalty,
            feedbackReasonCodes: feedbackShaping.reasonCodes
        )
    }

    private func readinessSignal(for vector: ArtifactAttentionVector) -> Double {
        let positive =
            vector.confidence * 0.24
            + vector.evidenceStrength * 0.2
            + vector.novelty * 0.13
            + vector.urgency * 0.15
            + vector.timingFit * 0.11
            + vector.focusStateFit * 0.1
            + vector.categoryBalanceLift * 0.08
            + max(0, vector.feedbackModifier) * 0.1
        let penalties =
            vector.fatiguePenalty * 0.4
            + vector.repetitionPenalty * 0.3
            + vector.threadCooldownPenalty * 0.5
            + vector.cooldownPenalty * 0.55
            + vector.mutePenalty * 0.75
            + vector.groundingPenalty * 0.45
            + vector.tonePenalty * 0.2
            + max(0, -vector.feedbackModifier) * 0.35
        return min(1.0, max(0.0, positive - penalties))
    }

    private func compare(
        lhs: ArtifactAttentionVector,
        rhs: ArtifactAttentionVector,
        lhsReadiness: Double,
        rhsReadiness: Double
    ) -> Bool {
        let lhsGrounding = min(lhs.confidence, lhs.evidenceStrength)
        let rhsGrounding = min(rhs.confidence, rhs.evidenceStrength)
        if abs(lhsGrounding - rhsGrounding) > 0.06 {
            return lhsGrounding > rhsGrounding
        }
        if abs(lhs.urgency - rhs.urgency) > 0.08 {
            return lhs.urgency > rhs.urgency
        }
        if abs(lhs.novelty - rhs.novelty) > 0.08 {
            return lhs.novelty > rhs.novelty
        }
        if abs(lhs.timingFit - rhs.timingFit) > 0.08 {
            return lhs.timingFit > rhs.timingFit
        }
        if abs(lhs.focusStateFit - rhs.focusStateFit) > 0.08 {
            return lhs.focusStateFit > rhs.focusStateFit
        }
        if abs(lhs.threadCooldownPenalty - rhs.threadCooldownPenalty) > 0.08 {
            return lhs.threadCooldownPenalty < rhs.threadCooldownPenalty
        }
        if abs(lhs.categoryBalanceLift - rhs.categoryBalanceLift) > 0.05 {
            return lhs.categoryBalanceLift > rhs.categoryBalanceLift
        }
        if abs(lhs.feedbackModifier - rhs.feedbackModifier) > 0.05 {
            return lhs.feedbackModifier > rhs.feedbackModifier
        }
        return lhsReadiness > rhsReadiness
    }

    private func novelty(
        for artifact: AdvisoryArtifactRecord,
        recentSurfaced: [AdvisoryArtifactRecord]
    ) -> Double {
        let duplicate = recentSurfaced.contains {
            $0.domain == artifact.domain
                && AdvisorySupport.slug(for: $0.title) == AdvisorySupport.slug(for: artifact.title)
        }
        return duplicate ? 0.28 : 0.86
    }

    private func urgency(
        for artifact: AdvisoryArtifactRecord,
        thread: AdvisoryThreadRecord?,
        dayContext: AdvisoryDayContext
    ) -> Double {
        let signals = dayContext.signalWeights
        let domainDemand = signals[signalName(for: artifact.domain)] ?? artifact.domain.defaultBaseWeight * 0.5
        var urgency = domainDemand * 0.62

        if let thread, thread.status == .active {
            urgency += 0.08
        }
        if dayContext.triggerKind == .reentryAfterIdle || dayContext.triggerKind == .morningResume {
            urgency += artifact.domain == .continuity ? 0.14 : 0
        }
        if dayContext.triggerKind == .userInvokedWrite {
            urgency += artifact.domain == .writingExpression || artifact.domain == .social ? 0.12 : 0
        }
        if dayContext.triggerKind == .userInvokedLost {
            urgency += artifact.domain == .continuity || artifact.domain == .focus ? 0.1 : 0
        }
        return min(1.0, urgency)
    }

    private func timingFit(
        for artifact: AdvisoryArtifactRecord,
        dayContext: AdvisoryDayContext,
        focusStateFit: Double,
        recentSurfaced: [AdvisoryArtifactRecord],
        now: Date,
        dateSupport: LocalDateSupport
    ) -> Double {
        let demand = dayContext.signalWeights[signalName(for: artifact.domain)] ?? 0.45
        let recencyBase: Double
        guard let last = recentSurfaced.first(where: { $0.domain == artifact.domain })?.surfacedAt
                ?? recentSurfaced.first(where: { $0.domain == artifact.domain })?.createdAt,
              let lastDate = dateSupport.parseDateTime(last) else {
            recencyBase = 0.58
            return min(1.0, recencyBase * 0.54 + demand * 0.18 + focusStateFit * 0.28)
        }
        let hours = now.timeIntervalSince(lastDate) / 3600
        if hours >= 6 {
            recencyBase = 0.64
        } else if hours >= 2 {
            recencyBase = 0.50
        } else {
            recencyBase = 0.28
        }
        return min(1.0, recencyBase * 0.54 + demand * 0.18 + focusStateFit * 0.28)
    }

    private func repetitionPenalty(
        for artifact: AdvisoryArtifactRecord,
        recentSurfaced: [AdvisoryArtifactRecord],
        now: Date,
        dateSupport: LocalDateSupport
    ) -> Double {
        let recentSameThread = recentSurfaced.filter {
            guard let threadId = artifact.threadId, $0.threadId == threadId else { return false }
            guard let timestamp = $0.surfacedAt ?? $0.createdAt,
                  let date = dateSupport.parseDateTime(timestamp) else {
                return false
            }
            return now.timeIntervalSince(date) < 6 * 3600
        }
        let recentSameTitle = recentSurfaced.contains {
            AdvisorySupport.slug(for: $0.title) == AdvisorySupport.slug(for: artifact.title)
        }
        return min(0.5, Double(recentSameThread.count) * 0.16 + (recentSameTitle ? 0.12 : 0))
    }

    private func proactiveEligibility(
        for artifact: AdvisoryArtifactRecord,
        vector: ArtifactAttentionVector,
        dayContext: AdvisoryDayContext
    ) -> Bool {
        timingPolicy.isProactivelyEligible(artifact, dayContext: dayContext)
            && vector.focusStateFit >= 0.34
            && vector.timingFit >= 0.38
            && vector.threadCooldownPenalty < 0.45
    }

    private func signalName(for domain: AdvisoryDomain) -> String {
        switch domain {
        case .continuity: return "continuity_pressure"
        case .writingExpression: return "expression_pull"
        case .research: return "research_pull"
        case .focus: return "focus_turbulence"
        case .social: return "social_pull"
        case .health: return "health_pressure"
        case .decisions: return "decision_density"
        case .lifeAdmin: return "life_admin_pressure"
        }
    }
}
