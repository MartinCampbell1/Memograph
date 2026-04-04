import Foundation

enum KnowledgeReviewDecisionKind: String, Codable {
    case promoteToLesson = "promote-to-lesson"
    case consolidate = "consolidate"
    case suppress = "suppress"
}

enum KnowledgeReviewDecisionStatus: String, Codable {
    case pending
    case apply
    case dismiss
}

struct KnowledgeReviewDecisionRecord: Codable, Equatable {
    let key: String
    let kind: KnowledgeReviewDecisionKind
    let status: KnowledgeReviewDecisionStatus
    let title: String
    let path: String
    let recordedAt: String?

    init(
        key: String,
        kind: KnowledgeReviewDecisionKind,
        status: KnowledgeReviewDecisionStatus,
        title: String,
        path: String,
        recordedAt: String? = nil
    ) {
        self.key = key
        self.kind = kind
        self.status = status
        self.title = title
        self.path = path
        self.recordedAt = recordedAt
    }
}
