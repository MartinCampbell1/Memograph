import Foundation
import os

final class AdvisoryArtifactStore {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport
    private let now: () -> Date
    private let logger = Logger.advisory

    init(
        db: DatabaseManager,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.now = now
    }

    @discardableResult
    func upsertThread(_ candidate: AdvisoryThreadCandidate) throws -> AdvisoryThreadRecord {
        let id = candidate.id ?? AdvisorySupport.stableIdentifier(
            prefix: "advthr",
            components: [candidate.slug, candidate.kind.rawValue]
        )
        let timestamp = dateSupport.isoString(from: now())

        if let existing = try thread(forSlug: candidate.slug) {
            let mergedSource = mergeDistinct(existing.source, candidate.source)
            let mergedSummary = candidate.summary ?? existing.summary
            let confidence = max(existing.confidence, candidate.confidence)
            let firstSeenAt = minTimestamp(existing.firstSeenAt, candidate.firstSeenAt)
            let lastActiveAt = maxTimestamp(existing.lastActiveAt, candidate.lastActiveAt)
            let totalActiveMinutes = max(existing.totalActiveMinutes, candidate.totalActiveMinutes)
            let importanceScore = max(existing.importanceScore, candidate.importanceScore)
            let parentThreadId = candidate.parentThreadId ?? existing.parentThreadId

            try db.execute("""
                UPDATE advisory_threads
                SET title = ?, kind = ?, status = ?, confidence = ?, first_seen_at = ?, last_active_at = ?,
                    parent_thread_id = ?, total_active_minutes = ?, importance_score = ?,
                    source = ?, summary = ?, updated_at = ?
                WHERE id = ?
            """, params: [
                .text(candidate.title),
                .text(candidate.kind.rawValue),
                .text(candidate.status.rawValue),
                .real(confidence),
                firstSeenAt.map(SQLiteValue.text) ?? .null,
                lastActiveAt.map(SQLiteValue.text) ?? .null,
                parentThreadId.map(SQLiteValue.text) ?? .null,
                .integer(Int64(totalActiveMinutes)),
                .real(importanceScore),
                mergedSource.map(SQLiteValue.text) ?? .null,
                mergedSummary.map(SQLiteValue.text) ?? .null,
                .text(timestamp),
                .text(existing.id)
            ])
            return try thread(id: existing.id) ?? existing
        }

        try db.execute("""
            INSERT INTO advisory_threads
                (id, title, slug, kind, status, confidence, user_pinned, user_title_override, parent_thread_id,
                 first_seen_at, last_active_at, total_active_minutes, last_artifact_at, importance_score,
                 source, summary, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            .text(candidate.title),
            .text(candidate.slug),
            .text(candidate.kind.rawValue),
            .text(candidate.status.rawValue),
            .real(candidate.confidence),
            .integer(0),
            .null,
            candidate.parentThreadId.map(SQLiteValue.text) ?? .null,
            .text(candidate.firstSeenAt),
            .text(candidate.lastActiveAt),
            .integer(Int64(candidate.totalActiveMinutes)),
            .null,
            .real(candidate.importanceScore),
            .text(candidate.source),
            candidate.summary.map(SQLiteValue.text) ?? .null,
            .text(timestamp),
            .text(timestamp)
        ])

        logger.info("Advisory thread upserted: \(candidate.title)")
        return try thread(id: id)!
    }

    @discardableResult
    func upsertThreadEvidence(
        threadId: String,
        evidence: [AdvisoryThreadEvidenceCandidate]
    ) throws -> [AdvisoryThreadEvidenceRecord] {
        guard !evidence.isEmpty else { return [] }
        let timestamp = dateSupport.isoString(from: now())

        for item in evidence {
            let id = item.id ?? AdvisorySupport.stableIdentifier(
                prefix: "advev",
                components: [threadId, item.evidenceKind, item.evidenceRef]
            )
            try db.execute("""
                INSERT INTO advisory_thread_evidence
                    (id, thread_id, evidence_kind, evidence_ref, weight, created_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(thread_id, evidence_kind, evidence_ref)
                DO UPDATE SET weight = excluded.weight
            """, params: [
                .text(id),
                .text(threadId),
                .text(item.evidenceKind),
                .text(item.evidenceRef),
                .real(item.weight),
                .text(item.createdAt ?? timestamp)
            ])
        }

        return try threadEvidence(threadId: threadId)
    }

    @discardableResult
    func upsertContinuityItem(_ candidate: ContinuityItemCandidate) throws -> ContinuityItemRecord {
        let id = candidate.id ?? AdvisorySupport.stableIdentifier(
            prefix: "cont",
            components: [candidate.threadId ?? "-", candidate.kind.rawValue, AdvisorySupport.slug(for: candidate.title)]
        )
        let timestamp = dateSupport.isoString(from: now())

        if let existing = try continuityItem(id: id) {
            let confidence = max(existing.confidence, candidate.confidence)
            let updatedAt = candidate.updatedAt ?? timestamp
            let status = existing.status == .resolved ? existing.status : candidate.status
            try db.execute("""
                UPDATE continuity_items
                SET thread_id = ?, kind = ?, title = ?, body = ?, status = ?, confidence = ?,
                    source_packet_id = ?, updated_at = ?, resolved_at = ?
                WHERE id = ?
            """, params: [
                candidate.threadId.map(SQLiteValue.text) ?? .null,
                .text(candidate.kind.rawValue),
                .text(candidate.title),
                candidate.body.map(SQLiteValue.text) ?? .null,
                .text(status.rawValue),
                .real(confidence),
                candidate.sourcePacketId.map(SQLiteValue.text) ?? .null,
                .text(updatedAt),
                candidate.resolvedAt.map(SQLiteValue.text) ?? .null,
                .text(id)
            ])
            return try continuityItem(id: id) ?? existing
        }

        try db.execute("""
            INSERT INTO continuity_items
                (id, thread_id, kind, title, body, status, confidence, source_packet_id, created_at, updated_at, resolved_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            candidate.threadId.map(SQLiteValue.text) ?? .null,
            .text(candidate.kind.rawValue),
            .text(candidate.title),
            candidate.body.map(SQLiteValue.text) ?? .null,
            .text(candidate.status.rawValue),
            .real(candidate.confidence),
            candidate.sourcePacketId.map(SQLiteValue.text) ?? .null,
            .text(candidate.createdAt ?? timestamp),
            .text(candidate.updatedAt ?? timestamp),
            candidate.resolvedAt.map(SQLiteValue.text) ?? .null
        ])

        return try continuityItem(id: id)!
    }

    @discardableResult
    func savePacket<T: AdvisoryPacketPayload>(_ packet: T) throws -> AdvisoryPacketRecord {
        let payloadJson = AdvisorySupport.encodeJSONString(packet) ?? "{}"
        let timestamp = dateSupport.isoString(from: now())
        try db.execute("""
            INSERT INTO advisory_packets
                (id, packet_version, kind, trigger_kind, window_started_at, window_ended_at, payload_json,
                 language, access_level_granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                payload_json = excluded.payload_json,
                language = excluded.language,
                access_level_granted = excluded.access_level_granted
        """, params: [
            .text(packet.packetId),
            .text(packet.packetVersion),
            .text(packet.kind.rawValue),
            .text(packet.triggerKind.rawValue),
            packet.windowStartedAt.map(SQLiteValue.text) ?? .null,
            packet.windowEndedAt.map(SQLiteValue.text) ?? .null,
            .text(payloadJson),
            .text(packet.language),
            .text(packet.accessLevelGranted.rawValue),
            .text(timestamp)
        ])
        return try packetRecord(id: packet.packetId)!
    }

    @discardableResult
    func upsertArtifact(_ candidate: AdvisoryArtifactCandidate) throws -> AdvisoryArtifactRecord {
        let id = candidate.id ?? AdvisorySupport.stableIdentifier(
            prefix: "advart",
            components: [
                candidate.domain.rawValue,
                candidate.kind.rawValue,
                candidate.threadId ?? "-",
                candidate.sourcePacketId,
                AdvisorySupport.slug(for: candidate.title)
            ]
        )
        let timestamp = dateSupport.isoString(from: now())

        if let existing = try artifact(id: id) {
            try db.execute("""
                UPDATE advisory_artifacts
                SET domain = ?, kind = ?, title = ?, body = ?, thread_id = ?, source_packet_id = ?, source_recipe = ?,
                    confidence = ?, why_now = ?, evidence_json = ?, metadata_json = ?, language = ?, expires_at = ?
                WHERE id = ?
            """, params: [
                .text(candidate.domain.rawValue),
                .text(candidate.kind.rawValue),
                .text(candidate.title),
                .text(candidate.body),
                candidate.threadId.map(SQLiteValue.text) ?? .null,
                .text(candidate.sourcePacketId),
                .text(candidate.sourceRecipe),
                .real(candidate.confidence),
                candidate.whyNow.map(SQLiteValue.text) ?? .null,
                candidate.evidenceJson.map(SQLiteValue.text) ?? .null,
                candidate.metadataJson.map(SQLiteValue.text) ?? .null,
                .text(candidate.language),
                candidate.expiresAt.map(SQLiteValue.text) ?? .null,
                .text(id)
            ])
            if let threadId = candidate.threadId {
                try touchThreadArtifact(threadId: threadId, at: candidate.surfacedAt ?? candidate.createdAt ?? timestamp)
            }
            return try artifact(id: id) ?? existing
        }

        try db.execute("""
            INSERT INTO advisory_artifacts
                (id, domain, kind, title, body, thread_id, source_packet_id, source_recipe, confidence,
                 why_now, evidence_json, metadata_json, language, status, market_score, created_at, surfaced_at, expires_at,
                 attention_vector_json, market_context_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            .text(candidate.domain.rawValue),
            .text(candidate.kind.rawValue),
            .text(candidate.title),
            .text(candidate.body),
            candidate.threadId.map(SQLiteValue.text) ?? .null,
            .text(candidate.sourcePacketId),
            .text(candidate.sourceRecipe),
            .real(candidate.confidence),
            candidate.whyNow.map(SQLiteValue.text) ?? .null,
            candidate.evidenceJson.map(SQLiteValue.text) ?? .null,
            candidate.metadataJson.map(SQLiteValue.text) ?? .null,
            .text(candidate.language),
            .text(candidate.status.rawValue),
            .real(0),
            .text(candidate.createdAt ?? timestamp),
            candidate.surfacedAt.map(SQLiteValue.text) ?? .null,
            candidate.expiresAt.map(SQLiteValue.text) ?? .null,
            .null,
            .null
        ])

        if let threadId = candidate.threadId {
            try touchThreadArtifact(threadId: threadId, at: candidate.surfacedAt ?? candidate.createdAt ?? timestamp)
        }

        return try artifact(id: id)!
    }

    func updateArtifactMarketState(
        artifactId: String,
        status: AdvisoryArtifactStatus,
        marketScore: Double,
        attentionVectorJson: String? = nil,
        marketContextJson: String? = nil,
        surfacedAt: String? = nil
    ) throws {
        try db.execute("""
            UPDATE advisory_artifacts
            SET status = ?, market_score = ?, attention_vector_json = ?, market_context_json = ?,
                surfaced_at = COALESCE(?, surfaced_at)
            WHERE id = ?
        """, params: [
            .text(status.rawValue),
            .real(marketScore),
            attentionVectorJson.map(SQLiteValue.text) ?? .null,
            marketContextJson.map(SQLiteValue.text) ?? .null,
            surfacedAt.map(SQLiteValue.text) ?? .null,
            .text(artifactId)
        ])
    }

    @discardableResult
    func recordFeedback(
        artifactId: String,
        kind: AdvisoryArtifactFeedbackKind,
        notes: String? = nil
    ) throws -> AdvisoryArtifactFeedbackRecord {
        let timestamp = dateSupport.isoString(from: now())
        let id = AdvisorySupport.stableIdentifier(
            prefix: "advfb",
            components: [artifactId, kind.rawValue, timestamp]
        )
        try db.execute("""
            INSERT INTO advisory_artifact_feedback (id, artifact_id, feedback_kind, notes, created_at)
            VALUES (?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            .text(artifactId),
            .text(kind.rawValue),
            notes.map(SQLiteValue.text) ?? .null,
            .text(timestamp)
        ])
        return try feedback(id: id)!
    }

    @discardableResult
    func recordRun(
        recipeName: String,
        recipeDomain: AdvisoryDomain,
        packetId: String?,
        triggerKind: AdvisoryTriggerKind,
        runtimeName: String,
        providerName: String,
        accessLevelRequested: AdvisoryAccessProfile,
        accessLevelGranted: AdvisoryAccessProfile,
        status: AdvisoryRunStatus,
        outputArtifactIds: [String],
        errorText: String? = nil
    ) throws -> AdvisoryRunRecord {
        let timestamp = dateSupport.isoString(from: now())
        let id = AdvisorySupport.stableIdentifier(
            prefix: "advrun",
            components: [recipeName, packetId ?? "-", status.rawValue, providerName, timestamp, UUID().uuidString]
        )
        try db.execute("""
            INSERT INTO advisory_runs
                (id, recipe_name, recipe_domain, packet_id, trigger_kind, runtime_name, provider_name, access_level_requested,
                 access_level_granted, status, output_artifact_ids_json, error_text, started_at, finished_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            .text(recipeName),
            .text(recipeDomain.rawValue),
            packetId.map(SQLiteValue.text) ?? .null,
            .text(triggerKind.rawValue),
            .text(runtimeName),
            .text(providerName),
            .text(accessLevelRequested.rawValue),
            .text(accessLevelGranted.rawValue),
            .text(status.rawValue),
            AdvisorySupport.encodeJSONString(outputArtifactIds).map(SQLiteValue.text) ?? .null,
            errorText.map(SQLiteValue.text) ?? .null,
            .text(timestamp),
            .text(timestamp)
        ])
        return try run(id: id)!
    }

    @discardableResult
    func recordEvidenceRequest(
        runId: String,
        requestedLevel: AdvisoryAccessProfile,
        reason: String,
        evidenceKinds: [String],
        granted: Bool
    ) throws -> AdvisoryEvidenceRequestRecord {
        let timestamp = dateSupport.isoString(from: now())
        let id = AdvisorySupport.stableIdentifier(
            prefix: "adveq",
            components: [runId, requestedLevel.rawValue, reason, timestamp]
        )
        try db.execute("""
            INSERT INTO advisory_evidence_requests
                (id, run_id, requested_level, reason, evidence_kinds_json, granted, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """, params: [
            .text(id),
            .text(runId),
            .text(requestedLevel.rawValue),
            .text(reason),
            AdvisorySupport.encodeJSONString(evidenceKinds).map(SQLiteValue.text) ?? .null,
            .integer(granted ? 1 : 0),
            .text(timestamp)
        ])
        return try evidenceRequest(id: id)!
    }

    func thread(id: String) throws -> AdvisoryThreadRecord? {
        try db.query("SELECT * FROM advisory_threads WHERE id = ? LIMIT 1", params: [.text(id)])
            .first
            .flatMap(AdvisoryThreadRecord.init(row:))
    }

    func thread(forSlug slug: String) throws -> AdvisoryThreadRecord? {
        try db.query("SELECT * FROM advisory_threads WHERE slug = ? LIMIT 1", params: [.text(slug)])
            .first
            .flatMap(AdvisoryThreadRecord.init(row:))
    }

    @discardableResult
    func createManualThread(
        title: String,
        kind: AdvisoryThreadKind,
        status: AdvisoryThreadStatus = .active,
        summary: String? = nil,
        parentThreadId: String? = nil
    ) throws -> AdvisoryThreadRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw DatabaseError.executeFailed("Thread title cannot be empty")
        }

        let trimmedSummary = summary?.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSlug = AdvisorySupport.slug(for: trimmedTitle)
        let slugSeed = baseSlug.isEmpty ? "thread" : baseSlug
        if let existing = try thread(forSlug: slugSeed),
           existing.parentThreadId == parentThreadId {
            return existing
        }

        let slug = try nextAvailableThreadSlug(base: slugSeed)
        let timestamp = dateSupport.isoString(from: now())
        let candidate = AdvisoryThreadCandidate(
            id: nil,
            title: trimmedTitle,
            slug: slug,
            kind: kind,
            status: status,
            confidence: 0.56,
            firstSeenAt: timestamp,
            lastActiveAt: timestamp,
            source: "manual",
            summary: trimmedSummary?.isEmpty == false ? trimmedSummary : nil,
            parentThreadId: parentThreadId,
            totalActiveMinutes: 0,
            importanceScore: parentThreadId == nil ? 0.18 : 0.14
        )
        return try upsertThread(candidate)
    }

    @discardableResult
    func setThreadPinned(
        threadId: String,
        isPinned: Bool
    ) throws -> AdvisoryThreadRecord? {
        try db.execute("""
            UPDATE advisory_threads
            SET user_pinned = ?, updated_at = ?
            WHERE id = ?
        """, params: [
            .integer(isPinned ? 1 : 0),
            .text(dateSupport.isoString(from: now())),
            .text(threadId)
        ])
        return try thread(id: threadId)
    }

    @discardableResult
    func setThreadStatus(
        threadId: String,
        status: AdvisoryThreadStatus
    ) throws -> AdvisoryThreadRecord? {
        try db.execute("""
            UPDATE advisory_threads
            SET status = ?, updated_at = ?
            WHERE id = ?
        """, params: [
            .text(status.rawValue),
            .text(dateSupport.isoString(from: now())),
            .text(threadId)
        ])
        return try thread(id: threadId)
    }

    @discardableResult
    func setThreadParent(
        threadId: String,
        parentThreadId: String?
    ) throws -> AdvisoryThreadRecord? {
        if let parentThreadId, parentThreadId == threadId {
            throw DatabaseError.executeFailed("Thread cannot be its own parent")
        }
        try db.execute("""
            UPDATE advisory_threads
            SET parent_thread_id = ?, updated_at = ?
            WHERE id = ?
        """, params: [
            parentThreadId.map(SQLiteValue.text) ?? .null,
            .text(dateSupport.isoString(from: now())),
            .text(threadId)
        ])
        return try thread(id: threadId)
    }

    @discardableResult
    func renameThread(
        threadId: String,
        userTitleOverride: String?
    ) throws -> AdvisoryThreadRecord? {
        let trimmedOverride = userTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        try db.execute("""
            UPDATE advisory_threads
            SET user_title_override = ?, updated_at = ?
            WHERE id = ?
        """, params: [
            trimmedOverride.flatMap { $0.isEmpty ? nil : $0 }.map(SQLiteValue.text) ?? .null,
            .text(dateSupport.isoString(from: now())),
            .text(threadId)
        ])
        return try thread(id: threadId)
    }

    @discardableResult
    func mergeThread(
        sourceThreadId: String,
        into targetThreadId: String
    ) throws -> AdvisoryThreadRecord? {
        guard sourceThreadId != targetThreadId else {
            throw DatabaseError.executeFailed("Cannot merge a thread into itself")
        }
        guard let source = try thread(id: sourceThreadId),
              let target = try thread(id: targetThreadId) else {
            throw DatabaseError.executeFailed("Missing source or target thread for merge")
        }

        let timestamp = dateSupport.isoString(from: now())
        let sourceEvidence = try threadEvidence(threadId: sourceThreadId)
        if !sourceEvidence.isEmpty {
            _ = try upsertThreadEvidence(
                threadId: targetThreadId,
                evidence: sourceEvidence.map { evidence in
                    AdvisoryThreadEvidenceCandidate(
                        id: nil,
                        evidenceKind: evidence.evidenceKind,
                        evidenceRef: evidence.evidenceRef,
                        weight: evidence.weight,
                        createdAt: evidence.createdAt
                    )
                }
            )
            try db.execute("""
                DELETE FROM advisory_thread_evidence
                WHERE thread_id = ?
            """, params: [.text(sourceThreadId)])
        }

        try db.execute("""
            UPDATE continuity_items
            SET thread_id = ?, updated_at = ?
            WHERE thread_id = ?
        """, params: [
            .text(targetThreadId),
            .text(timestamp),
            .text(sourceThreadId)
        ])

        try db.execute("""
            UPDATE advisory_artifacts
            SET thread_id = ?
            WHERE thread_id = ?
        """, params: [
            .text(targetThreadId),
            .text(sourceThreadId)
        ])

        try db.execute("""
            UPDATE advisory_threads
            SET parent_thread_id = ?, updated_at = ?
            WHERE parent_thread_id = ? AND id != ?
        """, params: [
            .text(targetThreadId),
            .text(timestamp),
            .text(sourceThreadId),
            .text(targetThreadId)
        ])

        let mergedSummary = mergeDistinct(target.summary, source.summary)
        let mergedSource = mergeDistinct(target.source, source.source)
        let mergedConfidence = max(target.confidence, source.confidence)
        let mergedFirstSeenAt = minTimestamp(target.firstSeenAt, source.firstSeenAt)
        let mergedLastActiveAt = maxTimestamp(target.lastActiveAt, source.lastActiveAt)
        let mergedLastArtifactAt = maxTimestamp(target.lastArtifactAt, source.lastArtifactAt)
        let mergedImportance = max(target.importanceScore, source.importanceScore)
        let mergedMinutes = max(target.totalActiveMinutes, source.totalActiveMinutes)
        try db.execute("""
            UPDATE advisory_threads
            SET confidence = ?, first_seen_at = ?, last_active_at = ?, total_active_minutes = ?,
                last_artifact_at = ?, importance_score = ?, source = ?, summary = ?, updated_at = ?
            WHERE id = ?
        """, params: [
            .real(mergedConfidence),
            mergedFirstSeenAt.map(SQLiteValue.text) ?? .null,
            mergedLastActiveAt.map(SQLiteValue.text) ?? .null,
            .integer(Int64(mergedMinutes)),
            mergedLastArtifactAt.map(SQLiteValue.text) ?? .null,
            .real(mergedImportance),
            mergedSource.map(SQLiteValue.text) ?? .null,
            mergedSummary.map(SQLiteValue.text) ?? .null,
            .text(timestamp),
            .text(targetThreadId)
        ])

        let mergeSummary = [
            source.summary,
            "Merged into \(target.displayTitle)."
        ]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " ")

        try db.execute("""
            UPDATE advisory_threads
            SET status = ?, parent_thread_id = ?, user_pinned = 0, summary = ?, updated_at = ?
            WHERE id = ?
        """, params: [
            .text(AdvisoryThreadStatus.resolved.rawValue),
            .text(targetThreadId),
            mergeSummary.isEmpty ? .null : .text(mergeSummary),
            .text(timestamp),
            .text(sourceThreadId)
        ])

        return try thread(id: targetThreadId)
    }

    func threads(ids: [String]) throws -> [String: AdvisoryThreadRecord] {
        guard !ids.isEmpty else { return [:] }
        let sqlIds = ids.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        let rows = try db.query("SELECT * FROM advisory_threads WHERE id IN (\(sqlIds))")
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            AdvisoryThreadRecord(row: row).map { ($0.id, $0) }
        })
    }

    func listThreads(
        statuses: [AdvisoryThreadStatus]? = nil,
        limit: Int = 20
    ) throws -> [AdvisoryThreadRecord] {
        var sql = "SELECT * FROM advisory_threads"
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            sql += " WHERE status IN (\(values))"
        }
        sql += """
             ORDER BY
                user_pinned DESC,
                CASE status
                    WHEN 'active' THEN 0
                    WHEN 'stalled' THEN 1
                    WHEN 'parked' THEN 2
                    WHEN 'resolved' THEN 3
                    ELSE 4
                END,
                importance_score DESC,
                COALESCE(last_active_at, first_seen_at) DESC
             LIMIT \(max(1, limit))
            """
        return try db.query(sql).compactMap(AdvisoryThreadRecord.init(row:))
    }

    func countThreads(
        statuses: [AdvisoryThreadStatus]? = nil
    ) throws -> Int {
        var sql = "SELECT COUNT(*) AS count FROM advisory_threads"
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            sql += " WHERE status IN (\(values))"
        }
        return try db.query(sql).first?["count"]?.intValue.flatMap(Int.init) ?? 0
    }

    func childThreads(
        parentThreadId: String,
        limit: Int = 20
    ) throws -> [AdvisoryThreadRecord] {
        try db.query("""
            SELECT * FROM advisory_threads
            WHERE parent_thread_id = ?
            ORDER BY user_pinned DESC, importance_score DESC, COALESCE(last_active_at, first_seen_at) DESC
            LIMIT \(max(1, limit))
        """, params: [.text(parentThreadId)]).compactMap(AdvisoryThreadRecord.init(row:))
    }

    func threadEvidence(threadId: String) throws -> [AdvisoryThreadEvidenceRecord] {
        try db.query("""
            SELECT * FROM advisory_thread_evidence
            WHERE thread_id = ?
            ORDER BY weight DESC, created_at DESC
        """, params: [.text(threadId)]).compactMap(AdvisoryThreadEvidenceRecord.init(row:))
    }

    func continuityItem(id: String) throws -> ContinuityItemRecord? {
        try db.query("SELECT * FROM continuity_items WHERE id = ? LIMIT 1", params: [.text(id)])
            .first
            .flatMap(ContinuityItemRecord.init(row:))
    }

    func listContinuityItems(
        statuses: [ContinuityItemStatus]? = nil,
        limit: Int = 20
    ) throws -> [ContinuityItemRecord] {
        var sql = "SELECT * FROM continuity_items"
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            sql += " WHERE status IN (\(values))"
        }
        sql += " ORDER BY confidence DESC, updated_at DESC LIMIT \(max(1, limit))"
        return try db.query(sql).compactMap(ContinuityItemRecord.init(row:))
    }

    func countContinuityItems(
        statuses: [ContinuityItemStatus]? = nil,
        threadId: String? = nil
    ) throws -> Int {
        var clauses: [String] = []
        var params: [SQLiteValue] = []
        if let threadId {
            clauses.append("thread_id = ?")
            params.append(.text(threadId))
        }
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            clauses.append("status IN (\(values))")
        }
        var sql = "SELECT COUNT(*) AS count FROM continuity_items"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        return try db.query(sql, params: params).first?["count"]?.intValue.flatMap(Int.init) ?? 0
    }

    func continuityItemsForThread(
        threadId: String,
        statuses: [ContinuityItemStatus]? = nil,
        limit: Int = 20
    ) throws -> [ContinuityItemRecord] {
        var sql = "SELECT * FROM continuity_items WHERE thread_id = ?"
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            sql += " AND status IN (\(values))"
        }
        sql += """
             ORDER BY
                CASE status
                    WHEN 'open' THEN 0
                    WHEN 'stabilizing' THEN 1
                    WHEN 'parked' THEN 2
                    WHEN 'resolved' THEN 3
                    ELSE 4
                END,
                confidence DESC,
                updated_at DESC
             LIMIT \(max(1, limit))
            """
        return try db.query(sql, params: [.text(threadId)]).compactMap(ContinuityItemRecord.init(row:))
    }

    @discardableResult
    func updateContinuityItemStatus(
        itemId: String,
        status: ContinuityItemStatus
    ) throws -> ContinuityItemRecord? {
        let resolvedAt: SQLiteValue = status == .resolved
            ? .text(dateSupport.isoString(from: now()))
            : .null
        try db.execute("""
            UPDATE continuity_items
            SET status = ?, updated_at = ?, resolved_at = CASE
                    WHEN ? IS NULL AND status != 'resolved' THEN resolved_at
                    ELSE ?
                END
            WHERE id = ?
        """, params: [
            .text(status.rawValue),
            .text(dateSupport.isoString(from: now())),
            resolvedAt,
            resolvedAt,
            .text(itemId)
        ])
        return try continuityItem(id: itemId)
    }

    func packetRecord(id: String) throws -> AdvisoryPacketRecord? {
        try db.query("SELECT * FROM advisory_packets WHERE id = ? LIMIT 1", params: [.text(id)])
            .first
            .flatMap(AdvisoryPacketRecord.init(row:))
    }

    func artifact(id: String) throws -> AdvisoryArtifactRecord? {
        try db.query("SELECT * FROM advisory_artifacts WHERE id = ? LIMIT 1", params: [.text(id)])
            .first
            .flatMap(AdvisoryArtifactRecord.init(row:))
    }

    func artifacts(ids: [String]) throws -> [String: AdvisoryArtifactRecord] {
        guard !ids.isEmpty else { return [:] }
        let sqlIds = ids.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        let rows = try db.query("SELECT * FROM advisory_artifacts WHERE id IN (\(sqlIds))")
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            AdvisoryArtifactRecord(row: row).map { ($0.id, $0) }
        })
    }

    func listArtifacts(
        statuses: [AdvisoryArtifactStatus]? = nil,
        kind: AdvisoryArtifactKind? = nil,
        domain: AdvisoryDomain? = nil,
        limit: Int = 20
    ) throws -> [AdvisoryArtifactRecord] {
        var clauses: [String] = []
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            clauses.append("status IN (\(values))")
        }
        if let kind {
            clauses.append("kind = '\(kind.rawValue)'")
        }
        if let domain {
            clauses.append("domain = '\(domain.rawValue)'")
        }

        var sql = "SELECT * FROM advisory_artifacts"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += """
             ORDER BY
                CASE status
                    WHEN 'surfaced' THEN 0
                    WHEN 'accepted' THEN 1
                    WHEN 'queued' THEN 2
                    WHEN 'candidate' THEN 3
                    WHEN 'dismissed' THEN 4
                    WHEN 'expired' THEN 5
                    WHEN 'muted' THEN 6
                    ELSE 7
                END,
                COALESCE(surfaced_at, created_at) DESC,
                market_score DESC
             LIMIT \(max(1, limit))
            """
        return try db.query(sql).compactMap(AdvisoryArtifactRecord.init(row:))
    }

    func artifactStatusSummaries(
        statuses: [AdvisoryArtifactStatus]? = nil
    ) throws -> [AdvisoryArtifactStatusSummary] {
        var sql = """
            SELECT domain, status, COUNT(*) AS count
            FROM advisory_artifacts
        """
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            sql += " WHERE status IN (\(values))"
        }
        sql += " GROUP BY domain, status"

        return try db.query(sql).compactMap { row in
            guard let domainRaw = row["domain"]?.textValue,
                  let statusRaw = row["status"]?.textValue,
                  let domain = AdvisoryDomain(rawValue: domainRaw),
                  let status = AdvisoryArtifactStatus(rawValue: statusRaw) else {
                return nil
            }
            return AdvisoryArtifactStatusSummary(
                domain: domain,
                status: status,
                count: row["count"]?.intValue.flatMap(Int.init) ?? 0
            )
        }
    }

    func latestArtifact(
        kind: AdvisoryArtifactKind? = nil,
        statuses: [AdvisoryArtifactStatus]? = nil
    ) throws -> AdvisoryArtifactRecord? {
        try listArtifacts(statuses: statuses, kind: kind, limit: 1).first
    }

    func artifactsForPacket(
        _ packetId: String,
        statuses: [AdvisoryArtifactStatus]? = nil,
        sourceRecipe: String? = nil
    ) throws -> [AdvisoryArtifactRecord] {
        var sql = "SELECT * FROM advisory_artifacts WHERE source_packet_id = ?"
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            sql += " AND status IN (\(values))"
        }
        if let sourceRecipe {
            sql += " AND source_recipe = '\(sourceRecipe.replacingOccurrences(of: "'", with: "''"))'"
        }
        sql += """
             ORDER BY
                CASE status
                    WHEN 'surfaced' THEN 0
                    WHEN 'accepted' THEN 1
                    WHEN 'queued' THEN 2
                    WHEN 'candidate' THEN 3
                    WHEN 'dismissed' THEN 4
                    WHEN 'expired' THEN 5
                    WHEN 'muted' THEN 6
                    ELSE 7
                END,
                COALESCE(surfaced_at, created_at) DESC,
                market_score DESC
            """
        return try db.query(sql, params: [.text(packetId)]).compactMap(AdvisoryArtifactRecord.init(row:))
    }

    func artifactsForThread(
        _ threadId: String,
        statuses: [AdvisoryArtifactStatus]? = nil,
        limit: Int = 20
    ) throws -> [AdvisoryArtifactRecord] {
        var sql = "SELECT * FROM advisory_artifacts WHERE thread_id = ?"
        if let statuses, !statuses.isEmpty {
            let values = statuses.map { "'\($0.rawValue)'" }.joined(separator: ",")
            sql += " AND status IN (\(values))"
        }
        sql += """
             ORDER BY
                CASE status
                    WHEN 'surfaced' THEN 0
                    WHEN 'accepted' THEN 1
                    WHEN 'queued' THEN 2
                    WHEN 'candidate' THEN 3
                    WHEN 'dismissed' THEN 4
                    WHEN 'expired' THEN 5
                    WHEN 'muted' THEN 6
                    ELSE 7
                END,
                COALESCE(surfaced_at, created_at) DESC,
                market_score DESC
             LIMIT \(max(1, limit))
            """
        return try db.query(sql, params: [.text(threadId)]).compactMap(AdvisoryArtifactRecord.init(row:))
    }

    func feedback(id: String) throws -> AdvisoryArtifactFeedbackRecord? {
        try db.query("SELECT * FROM advisory_artifact_feedback WHERE id = ? LIMIT 1", params: [.text(id)])
            .first
            .flatMap(AdvisoryArtifactFeedbackRecord.init(row:))
    }

    func listFeedback(limit: Int = 100) throws -> [AdvisoryArtifactFeedbackRecord] {
        try db.query("""
            SELECT * FROM advisory_artifact_feedback
            ORDER BY created_at DESC
            LIMIT \(max(1, limit))
        """).compactMap(AdvisoryArtifactFeedbackRecord.init(row:))
    }

    func listFeedback(
        artifactIds: [String],
        limit: Int = 100
    ) throws -> [AdvisoryArtifactFeedbackRecord] {
        guard !artifactIds.isEmpty else { return [] }
        let sqlIds = artifactIds.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
        return try db.query("""
            SELECT * FROM advisory_artifact_feedback
            WHERE artifact_id IN (\(sqlIds))
            ORDER BY created_at DESC
            LIMIT \(max(1, limit))
        """).compactMap(AdvisoryArtifactFeedbackRecord.init(row:))
    }

    func run(id: String) throws -> AdvisoryRunRecord? {
        try db.query("SELECT * FROM advisory_runs WHERE id = ? LIMIT 1", params: [.text(id)])
            .first
            .flatMap(AdvisoryRunRecord.init(row:))
    }

    func evidenceRequest(id: String) throws -> AdvisoryEvidenceRequestRecord? {
        try db.query("SELECT * FROM advisory_evidence_requests WHERE id = ? LIMIT 1", params: [.text(id)])
            .first
            .flatMap(AdvisoryEvidenceRequestRecord.init(row:))
    }

    func updateThreadIntelligence(
        threadId: String,
        status: AdvisoryThreadStatus,
        parentThreadId: String?,
        totalActiveMinutes: Int,
        lastArtifactAt: String?,
        importanceScore: Double
    ) throws {
        try db.execute("""
            UPDATE advisory_threads
            SET status = ?, parent_thread_id = ?, total_active_minutes = ?, last_artifact_at = ?,
                importance_score = ?, updated_at = ?
            WHERE id = ?
        """, params: [
            .text(status.rawValue),
            parentThreadId.map(SQLiteValue.text) ?? .null,
            .integer(Int64(max(0, totalActiveMinutes))),
            lastArtifactAt.map(SQLiteValue.text) ?? .null,
            .real(min(1.0, max(0.0, importanceScore))),
            .text(dateSupport.isoString(from: now())),
            .text(threadId)
        ])
    }

    private func mergeDistinct(_ lhs: String?, _ rhs: String?) -> String? {
        let values = AdvisorySupport.dedupe([lhs, rhs].compactMap { $0 })
        guard !values.isEmpty else { return nil }
        return values.joined(separator: " + ")
    }

    private func minTimestamp(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (.none, .none): return nil
        case let (.some(value), .none), let (.none, .some(value)): return value
        case let (.some(left), .some(right)): return left < right ? left : right
        }
    }

    private func maxTimestamp(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case (.none, .none): return nil
        case let (.some(value), .none), let (.none, .some(value)): return value
        case let (.some(left), .some(right)): return left > right ? left : right
        }
    }

    private func nextAvailableThreadSlug(base: String) throws -> String {
        var candidate = base
        var suffix = 2
        while try thread(forSlug: candidate) != nil {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    private func touchThreadArtifact(threadId: String, at timestamp: String) throws {
        try db.execute("""
            UPDATE advisory_threads
            SET last_artifact_at = CASE
                    WHEN last_artifact_at IS NULL THEN ?
                    WHEN last_artifact_at < ? THEN ?
                    ELSE last_artifact_at
                END,
                updated_at = ?
            WHERE id = ?
        """, params: [
            .text(timestamp),
            .text(timestamp),
            .text(timestamp),
            .text(dateSupport.isoString(from: now())),
            .text(threadId)
        ])
    }
}
