import Foundation

enum AdvisoryThreadMaintenanceProposalKind: String, Codable, Equatable {
    case statusChange = "status_change"
    case reparentUnderThread = "reparent_under_thread"
    case mergeIntoThread = "merge_into_thread"
    case splitIntoSubthread = "split_into_subthread"
}

struct AdvisoryThreadMaintenanceProposal: Identifiable, Equatable, Codable {
    let id: String
    let kind: AdvisoryThreadMaintenanceProposalKind
    let title: String
    let rationale: String
    let confidence: Double
    let targetThreadId: String?
    let targetThreadTitle: String?
    let suggestedStatus: AdvisoryThreadStatus?
    let suggestedTitle: String?
    let suggestedSummary: String?
    let suggestedKind: AdvisoryThreadKind?
    let sourceContinuityItemId: String?
}

struct AdvisoryThreadDetailSnapshot: Equatable {
    let thread: AdvisoryThreadRecord
    let parentThread: AdvisoryThreadRecord?
    let childThreads: [AdvisoryThreadRecord]
    let continuityItems: [ContinuityItemRecord]
    let artifacts: [AdvisoryArtifactRecord]
    let evidence: [AdvisoryThreadEvidenceRecord]
    let maintenanceProposals: [AdvisoryThreadMaintenanceProposal]

    init(
        thread: AdvisoryThreadRecord,
        parentThread: AdvisoryThreadRecord?,
        childThreads: [AdvisoryThreadRecord],
        continuityItems: [ContinuityItemRecord],
        artifacts: [AdvisoryArtifactRecord],
        evidence: [AdvisoryThreadEvidenceRecord],
        maintenanceProposals: [AdvisoryThreadMaintenanceProposal] = []
    ) {
        self.thread = thread
        self.parentThread = parentThread
        self.childThreads = childThreads
        self.continuityItems = continuityItems
        self.artifacts = artifacts
        self.evidence = evidence
        self.maintenanceProposals = maintenanceProposals
    }
}
