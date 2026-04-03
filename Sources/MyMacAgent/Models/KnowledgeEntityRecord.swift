import Foundation

enum KnowledgeEntityType: String, CaseIterable, Codable {
    case project
    case tool
    case model
    case topic
    case site
    case person
    case issue
    case lesson

    var folderName: String {
        switch self {
        case .project: return "Projects"
        case .tool: return "Tools"
        case .model: return "Models"
        case .topic: return "Topics"
        case .site: return "Sites"
        case .person: return "People"
        case .issue: return "Issues"
        case .lesson: return "Lessons"
        }
    }
}

struct KnowledgeEntityRecord {
    let id: String
    let canonicalName: String
    let slug: String
    let entityType: KnowledgeEntityType
    let aliasesJson: String?
    let firstSeenAt: String?
    let lastSeenAt: String?

    init(
        id: String,
        canonicalName: String,
        slug: String,
        entityType: KnowledgeEntityType,
        aliasesJson: String?,
        firstSeenAt: String?,
        lastSeenAt: String?
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.slug = slug
        self.entityType = entityType
        self.aliasesJson = aliasesJson
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let canonicalName = row["canonical_name"]?.textValue,
              let slug = row["slug"]?.textValue,
              let entityTypeRaw = row["entity_type"]?.textValue,
              let entityType = KnowledgeEntityType(rawValue: entityTypeRaw) else {
            return nil
        }
        self.id = id
        self.canonicalName = canonicalName
        self.slug = slug
        self.entityType = entityType
        self.aliasesJson = row["aliases_json"]?.textValue
        self.firstSeenAt = row["first_seen_at"]?.textValue
        self.lastSeenAt = row["last_seen_at"]?.textValue
    }
}

struct KnowledgeClaimRecord {
    let id: String
    let windowStart: String?
    let windowEnd: String?
    let sourceSummaryDate: String?
    let sourceSummaryGeneratedAt: String?
    let subjectEntityId: String
    let predicate: String
    let objectText: String?
    let confidence: Double
    let qualifiersJson: String?
    let sourceKind: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let subjectEntityId = row["subject_entity_id"]?.textValue,
              let predicate = row["predicate"]?.textValue else {
            return nil
        }
        self.id = id
        self.windowStart = row["window_start"]?.textValue
        self.windowEnd = row["window_end"]?.textValue
        self.sourceSummaryDate = row["source_summary_date"]?.textValue
        self.sourceSummaryGeneratedAt = row["source_summary_generated_at"]?.textValue
        self.subjectEntityId = subjectEntityId
        self.predicate = predicate
        self.objectText = row["object_text"]?.textValue
        self.confidence = row["confidence"]?.realValue ?? 0.5
        self.qualifiersJson = row["qualifiers_json"]?.textValue
        self.sourceKind = row["source_kind"]?.textValue
    }
}

struct KnowledgeEdgeRecord {
    let id: String
    let fromEntityId: String
    let toEntityId: String
    let edgeType: String
    let weight: Double
    let supportingClaimIdsJson: String?
    let updatedAt: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let fromEntityId = row["from_entity_id"]?.textValue,
              let toEntityId = row["to_entity_id"]?.textValue,
              let edgeType = row["edge_type"]?.textValue else {
            return nil
        }
        self.id = id
        self.fromEntityId = fromEntityId
        self.toEntityId = toEntityId
        self.edgeType = edgeType
        self.weight = row["weight"]?.realValue ?? 1
        self.supportingClaimIdsJson = row["supporting_claim_ids_json"]?.textValue
        self.updatedAt = row["updated_at"]?.textValue
    }
}

struct KnowledgeNoteRecord {
    let id: String
    let noteType: String
    let title: String
    let bodyMarkdown: String
    let sourceDate: String?
    let tagsJson: String?
    let linksJson: String?
    let exportObsidianStatus: String?
    let exportNotionStatus: String?
    let createdAt: String?

    init(
        id: String,
        noteType: String,
        title: String,
        bodyMarkdown: String,
        sourceDate: String?,
        tagsJson: String?,
        linksJson: String?,
        exportObsidianStatus: String? = nil,
        exportNotionStatus: String? = nil,
        createdAt: String? = nil
    ) {
        self.id = id
        self.noteType = noteType
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.sourceDate = sourceDate
        self.tagsJson = tagsJson
        self.linksJson = linksJson
        self.exportObsidianStatus = exportObsidianStatus
        self.exportNotionStatus = exportNotionStatus
        self.createdAt = createdAt
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let noteType = row["note_type"]?.textValue,
              let title = row["title"]?.textValue,
              let bodyMarkdown = row["body_markdown"]?.textValue else {
            return nil
        }
        self.id = id
        self.noteType = noteType
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.sourceDate = row["source_date"]?.textValue
        self.tagsJson = row["tags_json"]?.textValue
        self.linksJson = row["links_json"]?.textValue
        self.exportObsidianStatus = row["export_obsidian_status"]?.textValue
        self.exportNotionStatus = row["export_notion_status"]?.textValue
        self.createdAt = row["created_at"]?.textValue
    }
}
