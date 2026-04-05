import Foundation

struct ArtifactAttentionVector: Codable, Equatable {
    let confidence: Double
    let evidenceStrength: Double
    let novelty: Double
    let urgency: Double
    let timingFit: Double
    let focusStateFit: Double
    let fatiguePenalty: Double
    let repetitionPenalty: Double
    let threadCooldownPenalty: Double
    let categoryBalanceLift: Double
    let feedbackModifier: Double
    let cooldownPenalty: Double
    let mutePenalty: Double
    let groundingPenalty: Double
    let tonePenalty: Double
    let feedbackReasonCodes: [String]
}

struct FeedbackShapingSummary: Codable, Equatable {
    let modifier: Double
    let cooldownPenalty: Double
    let mutePenalty: Double
    let groundingPenalty: Double
    let tonePenalty: Double
    let reasonCodes: [String]
}

struct AdvisoryDayContext: Codable, Equatable {
    let localDate: String
    let triggerKind: AdvisoryTriggerKind
    let activeThreadCount: Int
    let openContinuityCount: Int
    let focusState: AdvisoryFocusState
    let systemAgeDays: Int
    let coldStartPhase: AdvisoryColdStartPhase
    let signalWeights: [String: Double]
}

struct DomainAttentionState: Codable, Equatable, Identifiable {
    let domain: AdvisoryDomain
    let demand: Double
    let fatigue: Double
    let balancePressure: Double
    let surfacedTodayCount: Int
    let slotBudget: Double
    let remainingBudgetFactor: Double
    let allocationWeight: Double
    let reason: String

    var id: String { domain.rawValue }
}

struct AttentionMarketContext: Codable, Equatable {
    let domain: AdvisoryDomain
    let readinessSignal: Double
    let domainAllocationWeight: Double
    let domainDemand: Double
    let domainFatigue: Double
    let domainBalancePressure: Double
    let domainRemainingBudgetFactor: Double
    let focusState: AdvisoryFocusState
    let proactiveEligible: Bool
    let adaptiveGapMinutes: Int
    let timingSuppressionPenalty: Double
    let feedbackModifier: Double
    let feedbackSuppressionPenalty: Double
    let feedbackReasonCodes: [String]
}

struct MarketEvaluatedArtifact {
    let artifact: AdvisoryArtifactRecord
    let attentionVector: ArtifactAttentionVector
    let marketContext: AttentionMarketContext
    let domainRank: Int
}

struct AttentionMarketSelection {
    let surfaced: [MarketEvaluatedArtifact]
    let queued: [MarketEvaluatedArtifact]
    let dismissed: [MarketEvaluatedArtifact]
    let domainStates: [DomainAttentionState]
}

struct AdvisoryDomainMarketSnapshot: Identifiable, Equatable {
    let domain: AdvisoryDomain
    let surfacedCount: Int
    let queuedCount: Int
    let candidateCount: Int
    let allocationWeight: Double
    let demand: Double
    let fatigue: Double
    let remainingBudgetFactor: Double
    let proactiveEligible: Bool
    let leadArtifactTitle: String?
    let leadArtifactKind: AdvisoryArtifactKind?

    var id: String { domain.rawValue }
    var activeArtifactCount: Int { surfacedCount + queuedCount + candidateCount }
}

struct AdvisoryEnrichmentSourceStatusSnapshot: Identifiable, Equatable {
    let source: AdvisoryEnrichmentSource
    let availability: AdvisoryEnrichmentAvailability
    let runtimeKind: AdvisoryEnrichmentRuntimeKind
    let providerLabel: String
    let isFallback: Bool
    let itemCount: Int
    let note: String
    let sampleTitles: [String]

    var id: String { source.rawValue }
}

struct AdvisoryMarketSnapshot: Equatable {
    let surfacedCount: Int
    let queuedCount: Int
    let candidateCount: Int
    let domainSnapshots: [AdvisoryDomainMarketSnapshot]
    let enrichmentSources: [AdvisoryEnrichmentSourceStatusSnapshot]
}

enum AdvisorySurfaceSnapshotBuilder {
    static func build(
        artifacts: [AdvisoryArtifactRecord],
        enrichmentBundles: [ReflectionEnrichmentBundle]
    ) -> AdvisoryMarketSnapshot {
        let relevantArtifacts = artifacts.filter { [.surfaced, .queued, .candidate].contains($0.status) }
        let domainSnapshots = AdvisoryDomain.allCases.map { domain in
            let domainArtifacts = relevantArtifacts.filter { $0.domain == domain }
            let surfacedCount = domainArtifacts.filter { $0.status == .surfaced }.count
            let queuedCount = domainArtifacts.filter { $0.status == .queued }.count
            let candidateCount = domainArtifacts.filter { $0.status == .candidate }.count
            let leadArtifact = domainArtifacts.sorted(by: artifactPriority).first
            let leadContext = leadArtifact?.marketContext

            return AdvisoryDomainMarketSnapshot(
                domain: domain,
                surfacedCount: surfacedCount,
                queuedCount: queuedCount,
                candidateCount: candidateCount,
                allocationWeight: leadContext?.domainAllocationWeight ?? 0,
                demand: leadContext?.domainDemand ?? 0,
                fatigue: leadContext?.domainFatigue ?? 0,
                remainingBudgetFactor: leadContext?.domainRemainingBudgetFactor ?? 0,
                proactiveEligible: leadContext?.proactiveEligible ?? false,
                leadArtifactTitle: leadArtifact?.title,
                leadArtifactKind: leadArtifact?.kind
            )
        }
        .sorted { lhs, rhs in
            if lhs.activeArtifactCount == rhs.activeArtifactCount {
                if lhs.allocationWeight == rhs.allocationWeight {
                    return lhs.domain.defaultBaseWeight > rhs.domain.defaultBaseWeight
                }
                return lhs.allocationWeight > rhs.allocationWeight
            }
            return lhs.activeArtifactCount > rhs.activeArtifactCount
        }

        let sourceSnapshots = AdvisoryEnrichmentSource.allCases.map { source in
            let bundle = enrichmentBundles.first(where: { $0.source == source })
            return AdvisoryEnrichmentSourceStatusSnapshot(
                source: source,
                availability: bundle?.availability ?? .unavailable,
                runtimeKind: bundle?.runtimeKind ?? .stagedPlaceholder,
                providerLabel: bundle?.providerLabel ?? source.label,
                isFallback: bundle?.isFallback ?? false,
                itemCount: bundle?.items.count ?? 0,
                note: bundle?.note ?? "No enrichment status available yet.",
                sampleTitles: Array((bundle?.items ?? []).prefix(2).map(\.title))
            )
        }

        return AdvisoryMarketSnapshot(
            surfacedCount: relevantArtifacts.filter { $0.status == .surfaced }.count,
            queuedCount: relevantArtifacts.filter { $0.status == .queued }.count,
            candidateCount: relevantArtifacts.filter { $0.status == .candidate }.count,
            domainSnapshots: domainSnapshots,
            enrichmentSources: sourceSnapshots
        )
    }

    private static func artifactPriority(
        _ lhs: AdvisoryArtifactRecord,
        _ rhs: AdvisoryArtifactRecord
    ) -> Bool {
        let lhsRank = statusRank(lhs.status)
        let rhsRank = statusRank(rhs.status)
        if lhsRank == rhsRank {
            let lhsWeight = lhs.marketContext?.domainAllocationWeight ?? lhs.confidence
            let rhsWeight = rhs.marketContext?.domainAllocationWeight ?? rhs.confidence
            if lhsWeight == rhsWeight {
                return lhs.confidence > rhs.confidence
            }
            return lhsWeight > rhsWeight
        }
        return lhsRank < rhsRank
    }

    private static func statusRank(_ status: AdvisoryArtifactStatus) -> Int {
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
