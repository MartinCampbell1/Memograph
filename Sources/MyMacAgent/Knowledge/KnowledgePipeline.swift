import CryptoKit
import Foundation
import os

struct KnowledgePipelineResult {
    let entityCount: Int
    let claimCount: Int
    let edgeCount: Int
    let noteCount: Int
}

final class KnowledgePipeline {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport
    private let extractor: ClaimExtractor
    private let compiler: KnowledgeCompiler
    private let maintenance: KnowledgeMaintenance
    private let normalizer: EntityNormalizer
    private let graphShaper: GraphShaper
    private let settings: AppSettings
    private let logger = Logger.knowledge

    init(db: DatabaseManager, timeZone: TimeZone = .autoupdatingCurrent, settings: AppSettings = AppSettings()) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.settings = settings
        self.normalizer = EntityNormalizer(settings: settings)
        self.extractor = ClaimExtractor(normalizer: normalizer, timeZone: timeZone)
        self.compiler = KnowledgeCompiler(
            db: db,
            timeZone: timeZone,
            normalizer: normalizer,
            settings: settings
        )
        self.maintenance = KnowledgeMaintenance(db: db, timeZone: timeZone)
        self.graphShaper = GraphShaper()
    }

    @discardableResult
    func process(
        summary: DailySummaryRecord,
        window: SummaryWindowDescriptor,
        sessions: [SessionData],
        exporter: ObsidianExporter? = nil,
        materialize: Bool = true
    ) throws -> KnowledgePipelineResult {
        let extraction = extractor.extract(summary: summary, window: window, sessions: sessions)
        guard !extraction.entities.isEmpty else {
            return KnowledgePipelineResult(entityCount: 0, claimCount: 0, edgeCount: 0, noteCount: 0)
        }

        var persistedEntities: [String: KnowledgeEntityRecord] = [:]
        for entity in extraction.entities {
            let persisted = try upsertEntity(
                entity,
                windowStart: window.start,
                windowEnd: window.end
            )
            persistedEntities[entity.stableKey] = persisted
        }

        var claimIdsBySubject: [String: [String]] = [:]
        for claim in extraction.claims {
            guard let subject = persistedEntities[claim.subjectKey] else { continue }
            let claimId = try upsertClaim(
                claim,
                subjectEntity: subject,
                summary: summary,
                window: window
            )
            claimIdsBySubject[claim.subjectKey, default: []].append(claimId)
        }

        for edge in extraction.edges {
            guard let from = persistedEntities[edge.fromKey],
                  let to = persistedEntities[edge.toKey] else {
                continue
            }
            let support = (claimIdsBySubject[edge.fromKey] ?? []) + (claimIdsBySubject[edge.toKey] ?? [])
            try upsertEdge(edge, fromEntityId: from.id, toEntityId: to.id, supportingClaimIds: support)
        }

        let noteCount: Int
        if materialize {
            noteCount = try syncMaterializedKnowledge(exporter: exporter, sourceDateOverrideByEntityId:
                Dictionary(uniqueKeysWithValues: persistedEntities.values.map { ($0.id, summary.date) })
            )
        } else {
            noteCount = 0
        }

        logger.info("Knowledge pipeline persisted \(persistedEntities.count) entities, \(extraction.claims.count) claims, \(extraction.edges.count) edges")
        return KnowledgePipelineResult(
            entityCount: persistedEntities.count,
            claimCount: extraction.claims.count,
            edgeCount: extraction.edges.count,
            noteCount: noteCount
        )
    }

    @discardableResult
    func syncMaterializedKnowledge(
        exporter: ObsidianExporter? = nil,
        sourceDateOverrideByEntityId: [String: String] = [:]
    ) throws -> Int {
        let metrics = try loadEntityMetrics()
        let materializedIds = resolvedMaterializedEntityIds(from: metrics)

        let existingNotes = try db.query("SELECT * FROM knowledge_notes").compactMap(KnowledgeNoteRecord.init(row:))
        let existingNoteByEntityId = Dictionary(uniqueKeysWithValues: existingNotes.compactMap { note in
            note.id.hasPrefix("knowledge:") ? (String(note.id.dropFirst("knowledge:".count)), note) : nil
        })

        for note in existingNotes {
            let entityId = note.id.hasPrefix("knowledge:") ? String(note.id.dropFirst("knowledge:".count)) : nil
            guard let entityId, !materializedIds.contains(entityId) else { continue }
            if let exporter {
                try? exporter.deleteKnowledgeNote(note)
            }
            try db.execute("DELETE FROM knowledge_notes WHERE id = ?", params: [.text(note.id)])
        }

        var noteCount = 0
        for metric in metrics where materializedIds.contains(metric.entity.id) {
            let sourceDate = sourceDateOverrideByEntityId[metric.entity.id]
                ?? existingNoteByEntityId[metric.entity.id]?.sourceDate
            guard let note = try compiler.compileNote(
                for: metric.entity.id,
                sourceDate: sourceDate,
                allowedEntityIds: materializedIds
            ) else {
                continue
            }
            try compiler.persist(note: note)
            if let exporter {
                _ = try? exporter.exportKnowledgeNote(note)
            }
            noteCount += 1
        }

        if let exporter {
            let indexMarkdown = try compiler.buildIndexMarkdown()
            _ = try? exporter.exportKnowledgeIndex(indexMarkdown)
            _ = try? exporter.exportKnowledgeAppliedHistory(settings.knowledgeAppliedActions)

            let maintenanceArtifacts = try buildMaintenanceArtifacts(metrics: metrics, materializedEntityIds: materializedIds)
            _ = try? exporter.exportKnowledgeMaintenance(maintenanceArtifacts.markdown)
            _ = try? exporter.syncKnowledgeDraftArtifacts(maintenanceArtifacts.draftArtifacts)
        }

        return noteCount
    }

    func buildMaintenanceArtifacts() throws -> KnowledgeMaintenanceArtifacts {
        let metrics = try loadEntityMetrics()
        let materializedIds = resolvedMaterializedEntityIds(from: metrics)
        return try buildMaintenanceArtifacts(metrics: metrics, materializedEntityIds: materializedIds)
    }

    func resetKnowledgeStore(exporter: ObsidianExporter? = nil) throws {
        if let exporter {
            let notes = try db.query("SELECT * FROM knowledge_notes").compactMap(KnowledgeNoteRecord.init(row:))
            for note in notes {
                try? exporter.deleteKnowledgeNote(note)
            }
        }

        try db.execute("DELETE FROM knowledge_notes")
        try db.execute("DELETE FROM knowledge_edges")
        try db.execute("DELETE FROM knowledge_claims")
        try db.execute("DELETE FROM knowledge_entities")
    }

    private func upsertEntity(
        _ entity: KnowledgeEntityCandidate,
        windowStart: Date,
        windowEnd: Date
    ) throws -> KnowledgeEntityRecord {
        let firstSeenString = dateSupport.isoString(from: windowStart)
        let lastSeenString = dateSupport.isoString(from: windowEnd)
        let slug = normalizer.slug(for: entity.canonicalName)
        let aliasesJson = jsonString(Array(entity.aliases).sorted())
        let existingRows = try db.query("""
            SELECT *
            FROM knowledge_entities
            WHERE entity_type = ? AND canonical_name = ?
            LIMIT 1
        """, params: [.text(entity.entityType.rawValue), .text(entity.canonicalName)])

        if var existing = existingRows.first.flatMap(KnowledgeEntityRecord.init(row:)) {
            let mergedAliases = mergeAliases(existing.aliasesJson, incoming: entity.aliases)
            let firstSeen = minTimestamp(existing.firstSeenAt, firstSeenString)
            let lastSeen = maxTimestamp(existing.lastSeenAt, lastSeenString)

            try db.execute("""
                UPDATE knowledge_entities
                SET slug = ?, aliases_json = ?, first_seen_at = ?, last_seen_at = ?
                WHERE id = ?
            """, params: [
                .text(slug),
                mergedAliases.map(SQLiteValue.text) ?? .null,
                firstSeen.map(SQLiteValue.text) ?? .null,
                lastSeen.map(SQLiteValue.text) ?? .null,
                .text(existing.id)
            ])

            existing = KnowledgeEntityRecord(
                id: existing.id,
                canonicalName: existing.canonicalName,
                slug: slug,
                entityType: existing.entityType,
                aliasesJson: mergedAliases,
                firstSeenAt: firstSeen,
                lastSeenAt: lastSeen
            )
            return existing
        }

        let id = stableIdentifier(prefix: "kbe", components: [entity.entityType.rawValue, entity.canonicalName])
        try db.execute("""
            INSERT INTO knowledge_entities
                (id, canonical_name, slug, entity_type, aliases_json, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            .text(entity.canonicalName),
            .text(slug),
            .text(entity.entityType.rawValue),
            aliasesJson.map(SQLiteValue.text) ?? .null,
            .text(firstSeenString),
            .text(lastSeenString)
        ])

        return KnowledgeEntityRecord(
            id: id,
            canonicalName: entity.canonicalName,
            slug: slug,
            entityType: entity.entityType,
            aliasesJson: aliasesJson,
            firstSeenAt: firstSeenString,
            lastSeenAt: lastSeenString
        )
    }

    private func upsertClaim(
        _ claim: KnowledgeClaimCandidate,
        subjectEntity: KnowledgeEntityRecord,
        summary: DailySummaryRecord,
        window: SummaryWindowDescriptor
    ) throws -> String {
        let claimId = stableIdentifier(prefix: "kbclm", components: [
            subjectEntity.id,
            claim.predicate,
            claim.objectText ?? "",
            dateSupport.isoString(from: window.start),
            dateSupport.isoString(from: window.end)
        ])

        try db.execute("""
            INSERT OR REPLACE INTO knowledge_claims
                (id, window_start, window_end, source_summary_date, source_summary_generated_at,
                 subject_entity_id, predicate, object_text, confidence, qualifiers_json, source_kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(claimId),
            .text(dateSupport.isoString(from: window.start)),
            .text(dateSupport.isoString(from: window.end)),
            .text(summary.date),
            summary.generatedAt.map(SQLiteValue.text) ?? .null,
            .text(subjectEntity.id),
            .text(claim.predicate),
            claim.objectText.map(SQLiteValue.text) ?? .null,
            .real(claim.confidence),
            jsonString(claim.qualifiers).map(SQLiteValue.text) ?? .null,
            .text(claim.sourceKind)
        ])
        return claimId
    }

    private func upsertEdge(
        _ edge: KnowledgeEdgeCandidate,
        fromEntityId: String,
        toEntityId: String,
        supportingClaimIds: [String]
    ) throws {
        let edgeId = stableIdentifier(prefix: "kbedge", components: [fromEntityId, toEntityId, edge.edgeType])
        let existingRows = try db.query(
            "SELECT * FROM knowledge_edges WHERE id = ? LIMIT 1",
            params: [.text(edgeId)]
        )

        let nowString = dateSupport.isoString(from: Date())
        if let existing = existingRows.first.flatMap(KnowledgeEdgeRecord.init(row:)) {
            let mergedSupportIds = mergeSupportIds(
                existing.supportingClaimIdsJson,
                incoming: supportingClaimIds
            )
            let supportJson = jsonString(mergedSupportIds)
            let weight = mergedSupportIds.isEmpty ? max(existing.weight, edge.weight) : Double(mergedSupportIds.count)
            try db.execute("""
                UPDATE knowledge_edges
                SET weight = ?, supporting_claim_ids_json = ?, updated_at = ?
                WHERE id = ?
            """, params: [
                .real(weight),
                supportJson.map(SQLiteValue.text) ?? .null,
                .text(nowString),
                .text(edgeId)
            ])
        } else {
            let initialSupportIds = Array(Set(supportingClaimIds)).sorted()
            let supportJson = jsonString(initialSupportIds)
            let weight = initialSupportIds.isEmpty ? edge.weight : Double(initialSupportIds.count)
            try db.execute("""
                INSERT INTO knowledge_edges
                    (id, from_entity_id, to_entity_id, edge_type, weight, supporting_claim_ids_json, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, params: [
                .text(edgeId),
                .text(fromEntityId),
                .text(toEntityId),
                .text(edge.edgeType),
                .real(weight),
                supportJson.map(SQLiteValue.text) ?? .null,
                .text(nowString)
            ])
        }
    }

    private func stableIdentifier(prefix: String, components: [String]) -> String {
        let payload = components.joined(separator: "|")
        let digest = SHA256.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)_\(hex)"
    }

    private func jsonString(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func mergeAliases(_ existingJson: String?, incoming: Set<String>) -> String? {
        var values = incoming
        if let existingJson,
           let data = existingJson.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] {
            values.formUnion(decoded)
        }
        return jsonString(Array(values).sorted())
    }

    private func mergeSupportIds(_ existingJson: String?, incoming: [String]) -> [String] {
        var values = Set(incoming)
        if let existingJson,
           let data = existingJson.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String] {
            values.formUnion(decoded)
        }
        return Array(values).sorted()
    }

    private func resolvedMaterializedEntityIds(from metrics: [KnowledgeEntityMetrics]) -> Set<String> {
        let materializedIds = graphShaper.materializedEntityIds(from: metrics)
        let suppressedEntityIds = Set(settings.knowledgeSuppressedEntityIds)
        guard !suppressedEntityIds.isEmpty else { return materializedIds }
        return materializedIds.subtracting(suppressedEntityIds)
    }

    private func buildMaintenanceArtifacts(
        metrics: [KnowledgeEntityMetrics],
        materializedEntityIds: Set<String>
    ) throws -> KnowledgeMaintenanceArtifacts {
        try maintenance.buildArtifacts(
            metrics: metrics,
            materializedEntityIds: materializedEntityIds,
            graphShaper: graphShaper,
            appliedActions: settings.knowledgeAppliedActions,
            aliasOverrides: settings.knowledgeAliasOverrides,
            reviewDecisions: settings.knowledgeReviewDecisions
        )
    }

    private func loadEntityMetrics() throws -> [KnowledgeEntityMetrics] {
        let entities = try db.query("""
            SELECT *
            FROM knowledge_entities
            ORDER BY entity_type, canonical_name
        """).compactMap(KnowledgeEntityRecord.init(row:))

        let claimCountRows = try db.query("""
            SELECT subject_entity_id, COUNT(*) AS claim_count
            FROM knowledge_claims
            GROUP BY subject_entity_id
        """)
        var claimCounts: [String: Int] = [:]
        for row in claimCountRows {
            guard let entityId = row["subject_entity_id"]?.textValue else { continue }
            claimCounts[entityId] = Int(row["claim_count"]?.intValue ?? 0)
        }

        let entityTypeById = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0.entityType) })
        let edgeRows = try db.query("""
            SELECT from_entity_id, to_entity_id, edge_type
            FROM knowledge_edges
        """)
        var typedEdgeCounts: [String: Int] = [:]
        var coOccurrenceEdgeCounts: [String: Int] = [:]
        var projectRelationCounts: [String: Int] = [:]

        for row in edgeRows {
            guard let fromEntityId = row["from_entity_id"]?.textValue,
                  let toEntityId = row["to_entity_id"]?.textValue,
                  let edgeType = row["edge_type"]?.textValue else {
                continue
            }

            if edgeType == "co_occurs_with" {
                coOccurrenceEdgeCounts[fromEntityId, default: 0] += 1
                coOccurrenceEdgeCounts[toEntityId, default: 0] += 1
            } else {
                typedEdgeCounts[fromEntityId, default: 0] += 1
                typedEdgeCounts[toEntityId, default: 0] += 1
            }

            if entityTypeById[toEntityId] == .project {
                projectRelationCounts[fromEntityId, default: 0] += 1
            }
            if entityTypeById[fromEntityId] == .project {
                projectRelationCounts[toEntityId, default: 0] += 1
            }
        }

        return entities.map { entity in
            KnowledgeEntityMetrics(
                entity: entity,
                claimCount: claimCounts[entity.id] ?? 0,
                typedEdgeCount: typedEdgeCounts[entity.id] ?? 0,
                coOccurrenceEdgeCount: coOccurrenceEdgeCounts[entity.id] ?? 0,
                projectRelationCount: projectRelationCounts[entity.id] ?? 0
            )
        }
    }

    private func minTimestamp(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (.none, .none): return nil
        case (.some(let lhs), .none): return lhs
        case (.none, .some(let rhs)): return rhs
        case (.some(let lhs), .some(let rhs)): return lhs < rhs ? lhs : rhs
        }
    }

    private func maxTimestamp(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (.none, .none): return nil
        case (.some(let lhs), .none): return lhs
        case (.none, .some(let rhs)): return rhs
        case (.some(let lhs), .some(let rhs)): return lhs > rhs ? lhs : rhs
        }
    }
}
