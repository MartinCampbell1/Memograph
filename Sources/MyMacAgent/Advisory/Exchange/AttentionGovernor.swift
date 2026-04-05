import Foundation

struct AttentionGovernor {
    private let timingPolicy = AttentionTimingPolicy()
    private let coldStartPolicy = AdvisoryColdStartPolicy()

    func buildDomainStates(
        candidates: [AdvisoryArtifactRecord],
        recentSurfaced: [AdvisoryArtifactRecord],
        guidance: GuidanceProfile,
        dayContext: AdvisoryDayContext,
        now: Date,
        dateSupport: LocalDateSupport
    ) -> [AdvisoryDomain: DomainAttentionState] {
        let surfacedToday = recentSurfaced.filter {
            guard let timestamp = $0.surfacedAt ?? $0.createdAt,
                  let date = dateSupport.parseDateTime(timestamp) else {
                return false
            }
            return dateSupport.localDateString(from: date) == dayContext.localDate
        }

        let candidateCounts = Dictionary(grouping: candidates, by: \.domain).mapValues(\.count)
        let surfacedCounts = Dictionary(grouping: surfacedToday, by: \.domain).mapValues(\.count)

        return Dictionary(uniqueKeysWithValues: guidance.enabledDomains.map { domain in
            let demand = demand(for: domain, dayContext: dayContext, candidateCount: candidateCounts[domain] ?? 0)
            let fatigue = fatigue(for: domain, recentSurfaced: recentSurfaced, now: now, dateSupport: dateSupport, guidance: guidance)
            let surfacedCount = surfacedCounts[domain] ?? 0
            let slotBudget = domainSlotBudget(for: domain, dayContext: dayContext)
            let remainingBudgetFactor = remainingBudgetFactor(slotBudget: slotBudget, surfacedTodayCount: surfacedCount)
            let balancePressure = balancePressure(
                domain: domain,
                surfacedTodayByDomain: surfacedCounts,
                candidateCount: candidateCounts[domain] ?? 0
            )
            let focusBudgetMultiplier = timingPolicy.domainSlotBudgetMultiplier(for: domain, dayContext: dayContext)
            let allocationWeight = min(1.35, max(0.01, domain.defaultBaseWeight + demand * 0.42 + balancePressure * 0.22 + remainingBudgetFactor * 0.18 + (focusBudgetMultiplier - 1.0) * 0.18 - fatigue * 0.4))
            let state = DomainAttentionState(
                domain: domain,
                demand: demand,
                fatigue: fatigue,
                balancePressure: balancePressure,
                surfacedTodayCount: surfacedCount,
                slotBudget: slotBudget,
                remainingBudgetFactor: remainingBudgetFactor,
                allocationWeight: allocationWeight,
                reason: reason(
                    domain: domain,
                    demand: demand,
                    fatigue: fatigue,
                    balancePressure: balancePressure,
                    remainingBudgetFactor: remainingBudgetFactor,
                    slotBudget: slotBudget,
                    surfacedTodayCount: surfacedCount
                )
            )
            return (domain, state)
        })
    }

    func select(
        evaluated: [MarketEvaluatedArtifact],
        dayContext: AdvisoryDayContext,
        domainStates: [AdvisoryDomain: DomainAttentionState],
        recentSurfaced: [AdvisoryArtifactRecord],
        guidance: GuidanceProfile,
        evaluator: AttentionMarketEvaluator,
        now: Date,
        dateSupport: LocalDateSupport
    ) -> AttentionMarketSelection {
        let grouped = Dictionary(grouping: evaluated, by: { $0.artifact.domain })
        let orderedDomains = domainStates.values.sorted { lhs, rhs in
            if lhs.allocationWeight == rhs.allocationWeight {
                return lhs.domain.rawValue < rhs.domain.rawValue
            }
            return lhs.allocationWeight > rhs.allocationWeight
        }

        let maxSurfaced = dayContext.triggerKind.isUserInvoked ? 2 : 1
        var surfaced: [MarketEvaluatedArtifact] = []
        var queued: [MarketEvaluatedArtifact] = []
        var dismissed: [MarketEvaluatedArtifact] = []

        for state in orderedDomains {
            guard let domainCandidates = grouped[state.domain], !domainCandidates.isEmpty else { continue }
            let rankedCandidates = domainCandidates.sorted { lhs, rhs in lhs.domainRank < rhs.domainRank }
            let respectsCooldown = respectsDomainCooldown(
                domain: state.domain,
                recentSurfaced: recentSurfaced,
                guidance: guidance,
                now: now,
                dateSupport: dateSupport
            )
            let withinDomainBudget = dayContext.triggerKind.isUserInvoked || state.remainingBudgetFactor > 0
            var surfacedDomainChampion = false

            for candidate in rankedCandidates {
                let proactiveEligible = dayContext.triggerKind.isUserInvoked || candidate.marketContext.proactiveEligible
                if !surfacedDomainChampion
                    && surfaced.count < maxSurfaced
                    && evaluator.isSelectable(candidate)
                    && respectsCooldown
                    && withinDomainBudget
                    && proactiveEligible {
                    surfaced.append(candidate)
                    surfacedDomainChampion = true
                    continue
                }
                if evaluator.isSelectable(candidate) || evaluator.shouldRemainLatent(candidate) {
                    queued.append(candidate)
                } else {
                    dismissed.append(candidate)
                }
            }
        }

        if surfaced.isEmpty,
           dayContext.triggerKind.isUserInvoked,
           let fallback = orderedDomains
            .compactMap({ grouped[$0.domain]?.sorted { $0.domainRank < $1.domainRank }.first })
            .first {
            surfaced.append(fallback)
            queued.removeAll { $0.artifact.id == fallback.artifact.id }
        }

        return AttentionMarketSelection(
            surfaced: surfaced,
            queued: queued,
            dismissed: dismissed,
            domainStates: orderedDomains
        )
    }

    private func demand(
        for domain: AdvisoryDomain,
        dayContext: AdvisoryDayContext,
        candidateCount: Int
    ) -> Double {
        let signals = dayContext.signalWeights
        let signalDemand: Double
        switch domain {
        case .continuity:
            signalDemand = (signals["continuity_pressure"] ?? 0) * 0.7 + (signals["thread_density"] ?? 0) * 0.3
        case .writingExpression:
            signalDemand = (signals["expression_pull"] ?? 0) * 0.8 + (signals["thread_density"] ?? 0) * 0.2
        case .research:
            signalDemand = (signals["research_pull"] ?? 0) * 0.85 + (signals["continuity_pressure"] ?? 0) * 0.15
        case .focus:
            signalDemand = (signals["focus_turbulence"] ?? 0) * 0.9 + (signals["fragmentation"] ?? 0) * 0.1
        case .social:
            signalDemand = (signals["social_pull"] ?? 0) * 0.9 + (signals["expression_pull"] ?? 0) * 0.1
        case .health:
            signalDemand = (signals["health_pressure"] ?? 0) * 0.95
        case .decisions:
            signalDemand = (signals["decision_density"] ?? 0) * 0.85 + (signals["continuity_pressure"] ?? 0) * 0.15
        case .lifeAdmin:
            signalDemand = (signals["life_admin_pressure"] ?? 0) * 0.9 + (signals["decision_density"] ?? 0) * 0.1
        }
        let candidateLift = min(0.22, Double(candidateCount) * 0.07)
        let focusModifier: Double
        switch dayContext.focusState {
        case .deepWork:
            focusModifier = domain == .focus || domain == .social || domain == .lifeAdmin ? -0.45 : (domain == .continuity ? -0.15 : -0.05)
        case .idleReturn:
            focusModifier = domain == .continuity ? 0.18 : 0
        case .transition:
            focusModifier = domain == .continuity || domain == .decisions || domain == .lifeAdmin ? 0.08 : 0
        case .fragmented:
            focusModifier = domain == .focus ? 0.18 : 0
        case .browsing:
            focusModifier = 0
        }
        return min(1.0, max(0.0, signalDemand + candidateLift + focusModifier))
    }

    private func fatigue(
        for domain: AdvisoryDomain,
        recentSurfaced: [AdvisoryArtifactRecord],
        now: Date,
        dateSupport: LocalDateSupport,
        guidance: GuidanceProfile
    ) -> Double {
        let cutoff = now.addingTimeInterval(-Double(guidance.perKindFatigueCooldownHours) * 3600)
        let count = recentSurfaced.filter {
            guard $0.domain == domain,
                  let timestamp = $0.surfacedAt ?? $0.createdAt,
                  let date = dateSupport.parseDateTime(timestamp) else {
                return false
            }
            return date >= cutoff
        }.count
        return min(1.0, Double(count) * 0.28)
    }

    private func balancePressure(
        domain: AdvisoryDomain,
        surfacedTodayByDomain: [AdvisoryDomain: Int],
        candidateCount: Int
    ) -> Double {
        guard candidateCount > 0 else { return -0.2 }
        let current = surfacedTodayByDomain[domain] ?? 0
        let maxForOtherDomains = surfacedTodayByDomain.values.max() ?? 0
        if current == 0 {
            return maxForOtherDomains > 0 ? 0.22 : 0.12
        }
        if current < maxForOtherDomains {
            return 0.08
        }
        return -0.08
    }

    private func respectsDomainCooldown(
        domain: AdvisoryDomain,
        recentSurfaced: [AdvisoryArtifactRecord],
        guidance: GuidanceProfile,
        now: Date,
        dateSupport: LocalDateSupport
    ) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(guidance.perKindFatigueCooldownHours) * 3600)
        return !recentSurfaced.contains {
            $0.domain == domain
                && (($0.surfacedAt ?? $0.createdAt).flatMap(dateSupport.parseDateTime) ?? .distantPast) >= cutoff
        }
    }

    private func reason(
        domain: AdvisoryDomain,
        demand: Double,
        fatigue: Double,
        balancePressure: Double,
        remainingBudgetFactor: Double,
        slotBudget: Double,
        surfacedTodayCount: Int
    ) -> String {
        "\(domain.rawValue): demand=\(String(format: "%.2f", demand)) fatigue=\(String(format: "%.2f", fatigue)) balance=\(String(format: "%.2f", balancePressure)) budget=\(String(format: "%.2f", remainingBudgetFactor)) slots=\(surfacedTodayCount)/\(String(format: "%.1f", slotBudget))"
    }

    private func domainSlotBudget(
        for domain: AdvisoryDomain,
        dayContext: AdvisoryDayContext
    ) -> Double {
        let base = domain.defaultDailySlotBudget * timingPolicy.domainSlotBudgetMultiplier(for: domain, dayContext: dayContext)
        if let cap = coldStartPolicy.domainBudgetCap(for: domain, dayContext: dayContext) {
            return min(base, cap)
        }
        return base
    }

    private func remainingBudgetFactor(
        slotBudget: Double,
        surfacedTodayCount: Int
    ) -> Double {
        guard slotBudget > 0 else { return 0 }
        let remaining = max(0, slotBudget - Double(surfacedTodayCount))
        return min(1.0, remaining / max(0.5, slotBudget))
    }
}
