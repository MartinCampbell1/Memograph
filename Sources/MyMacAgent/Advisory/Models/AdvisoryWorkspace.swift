import Foundation

enum AdvisoryManualPullTier: String, Equatable {
    case bestNow = "best_now"
    case goodWindow = "good_window"
    case waitForWindow = "wait_for_window"
    case deepWorkSuppressed = "deep_work_suppressed"
    case coolingDown = "cooling_down"
    case quiet

    var sortRank: Int {
        switch self {
        case .bestNow: return 0
        case .goodWindow: return 1
        case .waitForWindow: return 2
        case .deepWorkSuppressed: return 3
        case .coolingDown: return 4
        case .quiet: return 5
        }
    }

    var label: String {
        switch self {
        case .bestNow: return "Best now"
        case .goodWindow: return "Good window"
        case .waitForWindow: return "Later"
        case .deepWorkSuppressed: return "Deep work"
        case .coolingDown: return "Cooling down"
        case .quiet: return "Quiet"
        }
    }
}

struct AdvisoryManualPullRecommendation: Identifiable, Equatable {
    let domain: AdvisoryDomain
    let tier: AdvisoryManualPullTier
    let headline: String
    let reason: String
    let suggestedArtifactTitle: String?
    let demand: Double
    let remainingBudgetFactor: Double
    let fatigue: Double
    let activeArtifactCount: Int

    var id: String { domain.rawValue }
}

struct AdvisoryArtifactStatusSummary: Equatable {
    let domain: AdvisoryDomain
    let status: AdvisoryArtifactStatus
    let count: Int
}

struct AdvisoryDomainArtifactSummary: Identifiable, Equatable {
    let domain: AdvisoryDomain
    let surfacedCount: Int
    let queuedCount: Int
    let candidateCount: Int
    let acceptedCount: Int
    let mutedCount: Int

    var id: String { domain.rawValue }

    var pendingCount: Int {
        queuedCount + candidateCount
    }

    var visibleCount: Int {
        surfacedCount + pendingCount
    }
}

struct AdvisoryWorkspaceSnapshot: Equatable {
    let localDate: String
    let focusState: AdvisoryFocusState
    let coldStartPhase: AdvisoryColdStartPhase
    let attentionMode: String
    let systemAgeDays: Int
    let activeThreadCount: Int
    let openContinuityCount: Int
    let surfacedCount: Int
    let queuedCount: Int
    let candidateCount: Int
    let acceptedCount: Int
    let mutedCount: Int
    let enabledEnrichmentSources: [AdvisoryEnrichmentSource]
    let domainSummaries: [AdvisoryDomainArtifactSummary]
    let domainMarketSnapshots: [AdvisoryDomainMarketSnapshot]
    let enrichmentSourceStatuses: [AdvisoryEnrichmentSourceStatusSnapshot]

    var pendingCount: Int {
        queuedCount + candidateCount
    }

    var marketSnapshot: AdvisoryMarketSnapshot {
        AdvisoryMarketSnapshot(
            surfacedCount: surfacedCount,
            queuedCount: queuedCount,
            candidateCount: candidateCount,
            domainSnapshots: domainMarketSnapshots,
            enrichmentSources: enrichmentSourceStatuses
        )
    }

    var activeDomainSummaries: [AdvisoryDomainArtifactSummary] {
        domainSummaries
            .filter { $0.visibleCount > 0 || $0.acceptedCount > 0 }
            .sorted { lhs, rhs in
                if lhs.visibleCount == rhs.visibleCount {
                    return lhs.domain.defaultBaseWeight > rhs.domain.defaultBaseWeight
                }
                return lhs.visibleCount > rhs.visibleCount
            }
    }

    var manualPullRecommendations: [AdvisoryManualPullRecommendation] {
        manualPullDomains
            .compactMap { domain in
                guard let market = domainMarketSnapshots.first(where: { $0.domain == domain }) else {
                    return nil
                }
                return recommendation(for: market)
            }
            .sorted { lhs, rhs in
                if lhs.tier.sortRank == rhs.tier.sortRank {
                    let lhsScore = recommendationScore(lhs)
                    let rhsScore = recommendationScore(rhs)
                    if lhsScore == rhsScore {
                        return lhs.domain.defaultBaseWeight > rhs.domain.defaultBaseWeight
                    }
                    return lhsScore > rhsScore
                }
                return lhs.tier.sortRank < rhs.tier.sortRank
            }
    }

    var topManualPullRecommendation: AdvisoryManualPullRecommendation? {
        manualPullRecommendations.first(where: {
            $0.tier == .bestNow || $0.tier == .goodWindow
        })
    }

    var advisorGuidanceLine: String {
        if let topManualPullRecommendation {
            switch topManualPullRecommendation.tier {
            case .bestNow:
                return "Лучший ручной pull сейчас: \(topManualPullRecommendation.domain.label). \(topManualPullRecommendation.headline)"
            case .goodWindow:
                return "Если нужен ручной вход, самый дешёвый полюс сейчас: \(topManualPullRecommendation.domain.label)."
            default:
                break
            }
        }

        if focusState == .deepWork {
            return "Сейчас лучше не дёргать advisor лишний раз: deep work suppresses почти все ручные pulls."
        }
        if let waiting = manualPullRecommendations.first(where: { $0.tier == .waitForWindow }) {
            return "Сильного ручного pull нет, но \(waiting.domain.label) выглядит как следующий спокойный вход."
        }
        return "Advisor остаётся ambient: если сейчас ничего не тянет, это нормально."
    }

    private var manualPullDomains: [AdvisoryDomain] {
        [.writingExpression, .research, .focus, .social, .health, .decisions, .lifeAdmin]
    }

    private func recommendation(for market: AdvisoryDomainMarketSnapshot) -> AdvisoryManualPullRecommendation {
        let activeCount = market.activeArtifactCount
        let suggestedArtifactTitle = market.leadArtifactTitle

        if focusState == .deepWork && market.domain != .focus {
            return AdvisoryManualPullRecommendation(
                domain: market.domain,
                tier: .deepWorkSuppressed,
                headline: "Сейчас это лучше держать latent.",
                reason: deepWorkSuppressionReason(for: market.domain),
                suggestedArtifactTitle: suggestedArtifactTitle,
                demand: market.demand,
                remainingBudgetFactor: market.remainingBudgetFactor,
                fatigue: market.fatigue,
                activeArtifactCount: activeCount
            )
        }

        if activeCount == 0 && market.demand < 0.18 {
            return AdvisoryManualPullRecommendation(
                domain: market.domain,
                tier: .quiet,
                headline: "Тут пока нет достаточно плотного сигнала.",
                reason: quietReason(for: market.domain),
                suggestedArtifactTitle: suggestedArtifactTitle,
                demand: market.demand,
                remainingBudgetFactor: market.remainingBudgetFactor,
                fatigue: market.fatigue,
                activeArtifactCount: activeCount
            )
        }

        if market.fatigue >= 0.34 || market.remainingBudgetFactor <= 0.16 {
            return AdvisoryManualPullRecommendation(
                domain: market.domain,
                tier: .coolingDown,
                headline: "Сигнал есть, но этот домен лучше не дожимать.",
                reason: coolingReason(for: market),
                suggestedArtifactTitle: suggestedArtifactTitle,
                demand: market.demand,
                remainingBudgetFactor: market.remainingBudgetFactor,
                fatigue: market.fatigue,
                activeArtifactCount: activeCount
            )
        }

        if market.proactiveEligible && market.demand >= bestNowDemandFloor(for: market.domain) {
            return AdvisoryManualPullRecommendation(
                domain: market.domain,
                tier: .bestNow,
                headline: bestNowHeadline(for: market.domain, leadArtifactTitle: suggestedArtifactTitle),
                reason: "Demand \(percent(market.demand)) · budget \(percent(market.remainingBudgetFactor)) · fatigue \(percent(market.fatigue)).",
                suggestedArtifactTitle: suggestedArtifactTitle,
                demand: market.demand,
                remainingBudgetFactor: market.remainingBudgetFactor,
                fatigue: market.fatigue,
                activeArtifactCount: activeCount
            )
        }

        if market.proactiveEligible || activeCount > 0 || market.demand >= 0.24 {
            return AdvisoryManualPullRecommendation(
                domain: market.domain,
                tier: .goodWindow,
                headline: goodWindowHeadline(for: market.domain),
                reason: "Сигнал уже собран, но advisor всё ещё держит pacing мягким.",
                suggestedArtifactTitle: suggestedArtifactTitle,
                demand: market.demand,
                remainingBudgetFactor: market.remainingBudgetFactor,
                fatigue: market.fatigue,
                activeArtifactCount: activeCount
            )
        }

        return AdvisoryManualPullRecommendation(
            domain: market.domain,
            tier: .waitForWindow,
            headline: waitingHeadline(for: market.domain),
            reason: waitingReason(for: market.domain, focusState: focusState),
            suggestedArtifactTitle: suggestedArtifactTitle,
            demand: market.demand,
            remainingBudgetFactor: market.remainingBudgetFactor,
            fatigue: market.fatigue,
            activeArtifactCount: activeCount
        )
    }

    private func recommendationScore(_ recommendation: AdvisoryManualPullRecommendation) -> Double {
        recommendation.demand
            + recommendation.remainingBudgetFactor * 0.35
            + Double(recommendation.activeArtifactCount) * 0.06
            - recommendation.fatigue * 0.4
    }

    private func bestNowDemandFloor(for domain: AdvisoryDomain) -> Double {
        switch domain {
        case .focus:
            return focusState == .fragmented ? 0.48 : 0.56
        case .research:
            return 0.52
        case .writingExpression:
            return 0.58
        case .social, .health:
            return 0.62
        case .decisions, .lifeAdmin:
            return 0.46
        case .continuity:
            return 0.5
        }
    }

    private func bestNowHeadline(
        for domain: AdvisoryDomain,
        leadArtifactTitle: String?
    ) -> String {
        if let leadArtifactTitle, !leadArtifactTitle.isEmpty {
            return "Сейчас это самый дешёвый ручной вход: \(leadArtifactTitle)"
        }
        switch domain {
        case .writingExpression:
            return "Сейчас уже есть grounded angle, который можно безопасно поднять."
        case .research:
            return "Research angle уже достаточно тёплый и не требует долгого прогрева."
        case .focus:
            return "Focus signal сейчас скорее поможет, чем отвлечёт."
        case .social:
            return "Есть живой social nudge, но без давления."
        case .health:
            return "Есть мягкий health signal, который лучше ловить именно сейчас."
        case .decisions:
            return "Decision edge уже достаточно явный, чтобы назвать его прямо."
        case .lifeAdmin:
            return "Это хороший момент поднять один admin tail, пока он дешёвый."
        case .continuity:
            return "Continuity остаётся самым дешёвым входом обратно в контекст."
        }
    }

    private func goodWindowHeadline(for domain: AdvisoryDomain) -> String {
        switch domain {
        case .writingExpression:
            return "Если нужен writing pull, этот домен уже достаточно grounded."
        case .research:
            return "Research можно тянуть вручную без ощущения шума."
        case .focus:
            return "Focus pull сейчас не идеален, но уже безопасен."
        case .social:
            return "Social можно открыть вручную, если окно реально есть."
        case .health:
            return "Health check уже не будет выглядеть случайным."
        case .decisions:
            return "Decision review уже соберётся без лишнего натягивания."
        case .lifeAdmin:
            return "Life admin можно поднять вручную, если хочется зачистить хвосты."
        case .continuity:
            return "Continuity готова к ручному входу."
        }
    }

    private func waitingHeadline(for domain: AdvisoryDomain) -> String {
        switch domain {
        case .focus:
            return "Лучше дождаться transition или fragmented окна."
        case .research:
            return "Лучше дождаться спокойного окна на exploration."
        case .social:
            return "Лучше дождаться естественного reply окна."
        case .health:
            return "Лучше дождаться более мягкого pacing окна."
        case .decisions:
            return "Лучше дождаться чуть более явного unresolved edge."
        case .lifeAdmin:
            return "Лучше дождаться дешёвого operational окна."
        case .writingExpression:
            return "Лучше дождаться более плотного angle."
        case .continuity:
            return "Лучше дождаться более явного return point."
        }
    }

    private func waitingReason(
        for domain: AdvisoryDomain,
        focusState: AdvisoryFocusState
    ) -> String {
        switch focusState {
        case .transition, .idleReturn:
            return "\(domain.label) уже виден на горизонте, но сигнал пока ещё не стал достаточно плотным."
        case .fragmented:
            return "Сейчас внимание и так рваное, поэтому этот домен лучше не добавлять без явной пользы."
        case .deepWork:
            return "Даже если сигнал есть, deep work всё равно делает этот pull дорогим."
        case .browsing:
            return "Домен пока живёт в фоне и не просит отдельного ручного входа."
        }
    }

    private func deepWorkSuppressionReason(for domain: AdvisoryDomain) -> String {
        switch domain {
        case .research:
            return "Research pull сейчас почти наверняка увеличит переключение контекста."
        case .social:
            return "Social лучше не открывать поверх deep work без явной причины."
        case .health:
            return "Health layer остаётся мягким и не должен перебивать deep work."
        case .decisions:
            return "Decision review в deep work легко превращается в unnecessary branch."
        case .lifeAdmin:
            return "Life admin сейчас слишком дорог по re-entry cost."
        case .writingExpression:
            return "Writing pull сейчас скорее утащит в другой полюс, чем поможет."
        case .focus:
            return "Focus — единственный домен, который может быть уместен даже поверх deep work."
        case .continuity:
            return "Continuity не должен шуметь поверх deep work без явного re-entry trigger."
        }
    }

    private func quietReason(for domain: AdvisoryDomain) -> String {
        switch domain {
        case .research:
            return "Research lane пока реально quiet, а не скрыт governor’ом."
        case .focus:
            return "Focus layer не видит явного fragmentation pressure."
        case .social:
            return "Social сейчас не тянет внимание и это нормально."
        case .health:
            return "Health layer не должен изобретать сигнал из пустоты."
        case .decisions:
            return "Decision layer пока не видит плотной развилки."
        case .lifeAdmin:
            return "Life admin не собрался в явный operational tail."
        case .writingExpression:
            return "Writing lane пока без достаточно grounded angle."
        case .continuity:
            return "Continuity пока без нового return point."
        }
    }

    private func coolingReason(for market: AdvisoryDomainMarketSnapshot) -> String {
        if market.remainingBudgetFactor <= 0.16 {
            return "Дневной budget у этого полюса почти исчерпан."
        }
        return "Fatigue/repetition control уже начал притушать этот домен."
    }

    private func percent(_ value: Double) -> String {
        "\(Int((max(0, min(1, value)) * 100).rounded()))%"
    }
}
