import Foundation

struct AdvisoryDomainFeedbackSummary: Identifiable, Equatable {
    let kind: AdvisoryArtifactFeedbackKind
    let count: Int

    var id: String { kind.rawValue }
}

struct AdvisoryDomainWorkspaceDetail: Equatable {
    let localDate: String
    let domain: AdvisoryDomain
    let market: AdvisoryDomainMarketSnapshot
    let leadArtifact: AdvisoryArtifactRecord?
    let recentArtifacts: [AdvisoryArtifactRecord]
    let relatedThreads: [AdvisoryThreadRecord]
    let continuityItems: [ContinuityItemRecord]
    let feedbackSummaries: [AdvisoryDomainFeedbackSummary]
    let recentFeedback: [AdvisoryArtifactFeedbackRecord]
    let enrichmentStatuses: [AdvisoryEnrichmentSourceStatusSnapshot]
    let groundingSources: [AdvisoryEnrichmentSource]
    let sourceAnchors: [String]
    let evidenceRefs: [String]

    var isQuiet: Bool {
        leadArtifact == nil && market.activeArtifactCount == 0
    }
}
