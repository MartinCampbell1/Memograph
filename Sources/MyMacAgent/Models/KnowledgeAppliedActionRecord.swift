import Foundation

enum KnowledgeAppliedActionKind: String, Codable {
    case lessonPromotion
    case lessonRedirect
    case redirect
    case mergeOverlay
}

struct KnowledgeAppliedActionRecord: Codable, Equatable {
    let id: String
    let appliedAt: String
    let kind: KnowledgeAppliedActionKind
    let title: String
    let sourceEntityId: String?
    let applyTargetRelativePath: String
    let appliedPath: String
    let backupPath: String?
    let targetTitle: String?

    static func stableID(kind: KnowledgeAppliedActionKind, applyTargetRelativePath: String) -> String {
        "\(kind.rawValue)|\(applyTargetRelativePath)"
    }

    init(
        id: String? = nil,
        appliedAt: String,
        kind: KnowledgeAppliedActionKind,
        title: String,
        sourceEntityId: String?,
        applyTargetRelativePath: String,
        appliedPath: String,
        backupPath: String? = nil,
        targetTitle: String? = nil
    ) {
        self.id = id ?? Self.stableID(kind: kind, applyTargetRelativePath: applyTargetRelativePath)
        self.appliedAt = appliedAt
        self.kind = kind
        self.title = title
        self.sourceEntityId = sourceEntityId
        self.applyTargetRelativePath = applyTargetRelativePath
        self.appliedPath = appliedPath
        self.backupPath = backupPath
        self.targetTitle = targetTitle
    }
}
