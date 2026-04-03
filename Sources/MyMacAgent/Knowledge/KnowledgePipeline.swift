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
    private let normalizer: EntityNormalizer
    private let logger = Logger.knowledge

    init(db: DatabaseManager, timeZone: TimeZone = .autoupdatingCurrent) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.normalizer = EntityNormalizer()
        self.extractor = ClaimExtractor(normalizer: normalizer, timeZone: timeZone)
        self.compiler = KnowledgeCompiler(db: db, timeZone: timeZone, normalizer: normalizer)
    }

    @discardableResult
    func process(
        summary: DailySummaryRecord,
        window: SummaryWindowDescriptor,
        sessions: [SessionData],
        exporter: ObsidianExporter? = nil
    ) throws -> KnowledgePipelineResult {
        let extraction = extractor.extract(summary: summary, window: window, sessions: sessions)
        guard !extraction.entities.isEmpty else {
            return KnowledgePipelineResult(entityCount: 0, claimCount: 0, edgeCount: 0, noteCount: 0)
        }

        var persistedEntities: [String: KnowledgeEntityRecord] = [:]
        for entity in extraction.entities {
            let persisted = try upsertEntity(entity, seenAt: window.end)
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

        var noteCount = 0
        for entity in persistedEntities.values {
            guard let note = try compiler.compileNote(for: entity.id, sourceDate: summary.date) else {
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
        }

        logger.info("Knowledge pipeline persisted \(persistedEntities.count) entities, \(extraction.claims.count) claims, \(extraction.edges.count) edges")
        return KnowledgePipelineResult(
            entityCount: persistedEntities.count,
            claimCount: extraction.claims.count,
            edgeCount: extraction.edges.count,
            noteCount: noteCount
        )
    }

    private func upsertEntity(_ entity: KnowledgeEntityCandidate, seenAt: Date) throws -> KnowledgeEntityRecord {
        let seenAtString = dateSupport.isoString(from: seenAt)
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
            let firstSeen = minTimestamp(existing.firstSeenAt, seenAtString)
            let lastSeen = maxTimestamp(existing.lastSeenAt, seenAtString)

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
            .text(seenAtString),
            .text(seenAtString)
        ])

        return KnowledgeEntityRecord(
            id: id,
            canonicalName: entity.canonicalName,
            slug: slug,
            entityType: entity.entityType,
            aliasesJson: aliasesJson,
            firstSeenAt: seenAtString,
            lastSeenAt: seenAtString
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
        let orderedIds = [fromEntityId, toEntityId].sorted()
        let edgeId = stableIdentifier(prefix: "kbedge", components: orderedIds + [edge.edgeType])
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
                .text(orderedIds[0]),
                .text(orderedIds[1]),
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
