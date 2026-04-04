import Foundation

struct KnowledgeAliasOverrideRecord: Codable, Equatable {
    let id: String
    let sourceName: String
    let canonicalName: String
    let entityType: KnowledgeEntityType
    let reason: String
    let appliedAt: String

    static func stableID(
        sourceName: String,
        canonicalName: String,
        entityType: KnowledgeEntityType
    ) -> String {
        "alias|\(entityType.rawValue)|\(sourceName.lowercased())|\(canonicalName.lowercased())"
    }

    init(
        id: String? = nil,
        sourceName: String,
        canonicalName: String,
        entityType: KnowledgeEntityType,
        reason: String,
        appliedAt: String
    ) {
        self.id = id ?? Self.stableID(
            sourceName: sourceName,
            canonicalName: canonicalName,
            entityType: entityType
        )
        self.sourceName = sourceName
        self.canonicalName = canonicalName
        self.entityType = entityType
        self.reason = reason
        self.appliedAt = appliedAt
    }
}
