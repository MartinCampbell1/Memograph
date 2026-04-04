import Foundation

enum KnowledgeReviewDecisionKind: String, Codable {
    case promoteToLesson = "promote-to-lesson"
    case consolidate = "consolidate"
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
}
