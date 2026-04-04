import Foundation

struct KnowledgeMergeOverlayRecord: Codable, Equatable {
    let id: String
    let appliedAt: String
    let sourceEntityId: String
    let sourceTitle: String
    let sourceAliases: [String]
    let sourceOverview: String?
    let preservedSignals: [String]
    let targetEntityId: String
    let targetTitle: String
    let targetRelativePath: String

    static func stableID(sourceEntityId: String, targetEntityId: String) -> String {
        "merge|\(sourceEntityId)|\(targetEntityId)"
    }

    init(
        id: String? = nil,
        appliedAt: String,
        sourceEntityId: String,
        sourceTitle: String,
        sourceAliases: [String],
        sourceOverview: String?,
        preservedSignals: [String],
        targetEntityId: String,
        targetTitle: String,
        targetRelativePath: String
    ) {
        self.id = id ?? Self.stableID(sourceEntityId: sourceEntityId, targetEntityId: targetEntityId)
        self.appliedAt = appliedAt
        self.sourceEntityId = sourceEntityId
        self.sourceTitle = sourceTitle
        self.sourceAliases = sourceAliases
        self.sourceOverview = sourceOverview
        self.preservedSignals = preservedSignals
        self.targetEntityId = targetEntityId
        self.targetTitle = targetTitle
        self.targetRelativePath = targetRelativePath
    }
}
