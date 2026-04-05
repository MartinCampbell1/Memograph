import Foundation
import os

final class AdvisoryEngine {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport
    private let settings: AppSettings
    private let threadDetector: ThreadDetector
    private let threadMaintenanceEngine: ThreadMaintenanceEngine
    private let continuitySignalBuilder: ContinuitySignalBuilder
    private let reflectionPacketBuilder: ReflectionPacketBuilder
    private let threadPacketBuilder: ThreadPacketBuilder
    private let weeklyPacketBuilder: WeeklyPacketBuilder
    private let enrichmentContextBuilder: AdvisoryEnrichmentContextBuilder
    private let store: AdvisoryArtifactStore
    private let exchange: AdvisoryExchange
    private let bridge: AdvisoryBridgeClient
    private let coldStartPolicy = AdvisoryColdStartPolicy()
    private let logger = Logger.advisory

    init(
        db: DatabaseManager,
        timeZone: TimeZone = .autoupdatingCurrent,
        settings: AppSettings = AppSettings(),
        bridge: AdvisoryBridgeClient = AdvisoryBridgeClient(),
        enrichmentContextBuilder: AdvisoryEnrichmentContextBuilder? = nil
    ) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
        self.settings = settings
        self.store = AdvisoryArtifactStore(db: db, timeZone: timeZone)
        self.threadDetector = ThreadDetector(db: db, timeZone: timeZone)
        self.threadMaintenanceEngine = ThreadMaintenanceEngine(db: db, store: self.store, timeZone: timeZone)
        self.continuitySignalBuilder = ContinuitySignalBuilder(timeZone: timeZone)
        self.reflectionPacketBuilder = ReflectionPacketBuilder(settings: settings, timeZone: timeZone)
        self.threadPacketBuilder = ThreadPacketBuilder(settings: settings, timeZone: timeZone)
        self.weeklyPacketBuilder = WeeklyPacketBuilder(settings: settings, timeZone: timeZone)
        self.enrichmentContextBuilder = enrichmentContextBuilder
            ?? AdvisoryEnrichmentContextBuilder(db: db, settings: settings, timeZone: timeZone)
        self.exchange = AdvisoryExchange(store: store, settings: settings, timeZone: timeZone)
        self.bridge = bridge
    }

    @discardableResult
    func runAdvisorySweep(
        for localDate: String,
        triggerKind: AdvisoryTriggerKind = .userInvokedLost
    ) throws -> [AdvisoryArtifactRecord] {
        guard settings.advisoryEnabled else { return [] }
        let executionContext = try buildReflectionExecutionContext(
            localDate: localDate,
            triggerKind: triggerKind
        )
        let packet = executionContext.packet
        let dayContext = executionContext.dayContext
        _ = try store.savePacket(packet)

        let packetBoundContinuity = executionContext.continuityCandidates.map { item in
            ContinuityItemCandidate(
                id: item.id,
                threadId: item.threadId,
                kind: item.kind,
                title: item.title,
                body: item.body,
                status: item.status,
                confidence: item.confidence,
                sourcePacketId: packet.packetId,
                createdAt: item.createdAt,
                updatedAt: item.updatedAt,
                resolvedAt: item.resolvedAt
            )
        }
        for item in packetBoundContinuity {
            _ = try store.upsertContinuityItem(item)
        }

        let existingArtifacts = try store.artifactsForPacket(
            packet.packetId,
            statuses: [.surfaced, .queued, .candidate]
        )
        if !existingArtifacts.isEmpty {
            return existingArtifacts
        }

        let recipeSpecs = recipePlan(packet: packet, dayContext: dayContext)
        var persistedArtifacts: [AdvisoryArtifactRecord] = []
        for spec in recipeSpecs {
            let runId = AdvisorySupport.stableIdentifier(
                prefix: "recipe",
                components: [spec.name, packet.packetId, triggerKind.rawValue]
            )
            let request = AdvisoryRecipeRequest(
                runId: runId,
                recipeName: spec.name,
                packet: .reflection(packet),
                accessLevel: settings.advisoryAccessProfile,
                timeoutSeconds: settings.advisorySidecarTimeoutSeconds
            )

            let execution: AdvisoryBridgeExecution
            do {
                execution = try bridge.executeRecipe(request)
            } catch {
                logger.error("Advisory recipe \(spec.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                let health = bridge.health()
                if let failedRun = try? store.recordRun(
                    recipeName: spec.name,
                    recipeDomain: spec.domain,
                    packetId: packet.packetId,
                    triggerKind: triggerKind,
                    runtimeName: health.runtimeName,
                    providerName: health.providerName,
                    accessLevelRequested: settings.advisoryAccessProfile,
                    accessLevelGranted: settings.advisoryAccessProfile,
                    status: .failed,
                    outputArtifactIds: [],
                    errorText: error.localizedDescription
                ) {
                    recordPreloadedEvidenceRequest(
                        packet: .reflection(packet),
                        runId: failedRun.id,
                        recipeName: spec.name
                    )
                }
                continue
            }

            if let primaryFailure = execution.primaryFailure,
               let attempted = execution.attemptedPrimaryHealth {
                if let failedAttemptRun = try? store.recordRun(
                    recipeName: spec.name,
                    recipeDomain: spec.domain,
                    packetId: packet.packetId,
                    triggerKind: triggerKind,
                    runtimeName: attempted.runtimeName,
                    providerName: attempted.providerName,
                    accessLevelRequested: settings.advisoryAccessProfile,
                    accessLevelGranted: settings.advisoryAccessProfile,
                    status: .failed,
                    outputArtifactIds: [],
                    errorText: primaryFailure
                ) {
                    recordPreloadedEvidenceRequest(
                        packet: .reflection(packet),
                        runId: failedAttemptRun.id,
                        recipeName: spec.name
                    )
                }
            }

            let result = execution.result

            for item in result.continuityProposals {
                let proposal = ContinuityItemCandidate(
                    id: item.id,
                    threadId: item.threadId,
                    kind: item.kind,
                    title: item.title,
                    body: item.body,
                    status: item.status,
                    confidence: item.confidence,
                    sourcePacketId: packet.packetId,
                    createdAt: item.createdAt,
                    updatedAt: item.updatedAt,
                    resolvedAt: item.resolvedAt
                )
                _ = try store.upsertContinuityItem(proposal)
            }

            let proposals = try result.artifactProposals.map { try store.upsertArtifact($0) }
            persistedArtifacts.append(contentsOf: proposals)
            let successRun = try store.recordRun(
                recipeName: spec.name,
                recipeDomain: spec.domain,
                packetId: packet.packetId,
                triggerKind: triggerKind,
                runtimeName: execution.activeHealth.runtimeName,
                providerName: execution.activeHealth.providerName,
                accessLevelRequested: settings.advisoryAccessProfile,
                accessLevelGranted: settings.advisoryAccessProfile,
                status: .success,
                outputArtifactIds: proposals.map(\.id)
            )
            recordPreloadedEvidenceRequest(
                packet: .reflection(packet),
                runId: successRun.id,
                recipeName: spec.name
            )
        }

        let uniqueArtifacts = Dictionary(uniqueKeysWithValues: persistedArtifacts.map { ($0.id, $0) }).map(\.value)
        return try exchange.evaluateAndSurface(
            candidateArtifacts: uniqueArtifacts,
            triggerKind: triggerKind,
            dayContext: dayContext
        )
    }

    func generateResumeArtifact(
        for localDate: String,
        triggerKind: AdvisoryTriggerKind = .userInvokedLost
    ) throws -> AdvisoryArtifactRecord? {
        let surfaced = try runAdvisorySweep(for: localDate, triggerKind: triggerKind)
        if let surfacedResume = surfaced.first(where: { $0.kind == .resumeCard }) {
            return surfacedResume
        }
        if let continuity = surfaced.first(where: { $0.domain == .continuity }) {
            return continuity
        }
        if let surfacedFirst = surfaced.first {
            return surfacedFirst
        }
        let queuedResume = try store.latestArtifact(kind: .resumeCard, statuses: [.queued, .candidate])
        if let queuedResume {
            return queuedResume
        }
        let queuedContinuity = try store.listArtifacts(
            statuses: [.queued, .candidate],
            domain: .continuity,
            limit: 1
        ).first
        if let queuedContinuity {
            return queuedContinuity
        }
        return try store.latestArtifact(statuses: [.queued, .candidate])
    }

    func latestResumeArtifactCached() throws -> AdvisoryArtifactRecord? {
        let statuses: [AdvisoryArtifactStatus] = [.surfaced, .accepted, .queued, .candidate]
        if let surfacedResume = try store.latestArtifact(kind: .resumeCard, statuses: statuses) {
            return surfacedResume
        }
        if let continuity = try store.listArtifacts(
            statuses: statuses,
            domain: .continuity,
            limit: 1
        ).first {
            return continuity
        }
        return try store.latestArtifact(statuses: statuses)
    }

    func advisoryInbox(limit: Int = 8) throws -> [AdvisoryArtifactRecord] {
        try store.listArtifacts(statuses: [.surfaced, .queued, .candidate], limit: limit)
    }

    @discardableResult
    func generateDomainArtifact(
        for localDate: String,
        domain: AdvisoryDomain
    ) throws -> AdvisoryArtifactRecord? {
        guard settings.advisoryEnabled else { return nil }
        guard let action = AdvisoryRecipeCatalog.manualAction(for: domain),
              let recipeSpec = AdvisoryRecipeCatalog.spec(named: action.recipeName) else {
            return nil
        }

        let executionContext = try buildReflectionExecutionContext(
            localDate: localDate,
            triggerKind: action.triggerKind
        )
        let packet = manualDomainPacket(
            executionContext.packet,
            domain: domain
        )
        let dayContext = reflectionPacketBuilder.buildDayContext(
            packet: packet,
            threads: executionContext.threads,
            continuityItems: executionContext.continuityCandidates,
            sessions: executionContext.sessions,
            systemAgeDays: executionContext.dayContext.systemAgeDays,
            coldStartPhase: executionContext.dayContext.coldStartPhase
        )
        let artifacts = try executeSingleRecipe(
            packet: packet,
            requestPacket: .reflection(packet),
            recipeName: action.recipeName,
            recipeDomain: recipeSpec.domain,
            triggerKind: action.triggerKind,
            dayContext: dayContext,
            reuseExistingRecipeArtifactsOnly: true
        )

        if let preferred = preferredArtifact(in: artifacts, for: domain) {
            return preferred
        }
        return try store.listArtifacts(
            statuses: [.surfaced, .queued, .candidate],
            domain: domain,
            limit: 1
        ).first
    }

    func marketSnapshot(
        for localDate: String,
        artifactLimit: Int = 24
    ) throws -> AdvisoryMarketSnapshot {
        let artifacts = try store.listArtifacts(
            statuses: [.surfaced, .queued, .candidate],
            limit: artifactLimit
        )
        let enrichmentBundles = try enrichmentBundles(for: localDate)
        return AdvisorySurfaceSnapshotBuilder.build(
            artifacts: artifacts,
            enrichmentBundles: enrichmentBundles
        )
    }

    @discardableResult
    func applyFeedback(
        artifactId: String,
        kind: AdvisoryArtifactFeedbackKind,
        notes: String? = nil
    ) throws -> AdvisoryArtifactRecord {
        guard let artifact = try store.artifact(id: artifactId) else {
            throw DatabaseError.executeFailed("Artifact \(artifactId) is missing")
        }
        _ = try store.recordFeedback(artifactId: artifactId, kind: kind, notes: notes)
        try store.updateArtifactMarketState(
            artifactId: artifactId,
            status: kind.resultingArtifactStatus,
            marketScore: artifact.marketScore,
            attentionVectorJson: artifact.attentionVectorJson,
            marketContextJson: artifact.marketContextJson,
            surfacedAt: artifact.surfacedAt
        )
        guard let updated = try store.artifact(id: artifactId) else {
            throw DatabaseError.executeFailed("Artifact \(artifactId) disappeared after feedback")
        }
        return updated
    }

    func openContinuityItems(limit: Int = 6) throws -> [ContinuityItemRecord] {
        try store.listContinuityItems(statuses: [.open, .stabilizing], limit: limit)
    }

    func continuityItems(
        forThread threadId: String,
        limit: Int = 6
    ) throws -> [ContinuityItemRecord] {
        try store.continuityItemsForThread(
            threadId: threadId,
            statuses: [.open, .stabilizing, .parked],
            limit: limit
        )
    }

    @discardableResult
    func materializeArtifactQuickAction(
        artifactId: String,
        actionId: String
    ) throws -> AdvisoryArtifactQuickActionOutcome {
        guard let artifact = try store.artifact(id: artifactId) else {
            throw DatabaseError.executeFailed("Artifact \(artifactId) is missing")
        }
        guard let action = artifact.quickActions.first(where: { $0.id == actionId }) else {
            throw DatabaseError.executeFailed("Quick action \(actionId) is missing for artifact \(artifactId)")
        }

        let threadId = try effectiveThreadId(for: action.threadId ?? artifact.threadId)
        let baseId = AdvisorySupport.stableIdentifier(
            prefix: "contquick",
            components: [artifact.id, action.id, action.title]
        )
        let existing = try store.continuityItem(id: baseId)
        let continuityId: String
        if existing?.status == .resolved {
            continuityId = AdvisorySupport.stableIdentifier(
                prefix: "contquick",
                components: [baseId, dateSupport.isoString(from: Date())]
            )
        } else {
            continuityId = baseId
        }

        let continuityItem = try store.upsertContinuityItem(ContinuityItemCandidate(
            id: continuityId,
            threadId: threadId,
            kind: action.continuityKind,
            title: action.title,
            body: action.body,
            status: .open,
            confidence: max(0.55, artifact.confidence),
            sourcePacketId: artifact.sourcePacketId,
            createdAt: nil,
            updatedAt: nil,
            resolvedAt: nil
        ))
        return AdvisoryArtifactQuickActionOutcome(
            artifact: artifact,
            action: AdvisoryArtifactQuickAction(
                id: action.id,
                label: action.label,
                detail: action.detail,
                continuityKind: action.continuityKind,
                title: action.title,
                body: action.body,
                threadId: threadId
            ),
            continuityItem: continuityItem,
            reusedExistingItem: existing != nil && continuityId == baseId
        )
    }

    func thread(for id: String?) throws -> AdvisoryThreadRecord? {
        guard let id else { return nil }
        return try store.thread(id: id)
    }

    func threads(
        statuses: [AdvisoryThreadStatus]? = [.active, .stalled, .parked],
        limit: Int = 20
    ) throws -> [AdvisoryThreadRecord] {
        try store.listThreads(statuses: statuses, limit: limit)
    }

    func workspaceSnapshot(
        for localDate: String
    ) throws -> AdvisoryWorkspaceSnapshot {
        let context = try loadContext(localDate: localDate)
        let coldStart = try coldStartContext(for: localDate)
        let marketSnapshot = try marketSnapshot(for: localDate)
        let activeThreadCount = try store.countThreads(statuses: [.active, .stalled, .parked])
        let openContinuityCount = try store.countContinuityItems(statuses: [.open, .stabilizing])
        let dayContext = reflectionPacketBuilder.buildDayContext(
            localDate: localDate,
            triggerKind: .sessionEnd,
            activeThreadCount: activeThreadCount,
            openContinuityCount: openContinuityCount,
            sessions: context.sessions,
            systemAgeDays: coldStart.systemAgeDays,
            coldStartPhase: coldStart.phase,
            signalWeights: [:]
        )

        let statuses: [AdvisoryArtifactStatus] = [.surfaced, .queued, .candidate, .accepted, .muted]
        let summaries = try store.artifactStatusSummaries(statuses: statuses)
        let grouped = Dictionary(grouping: summaries, by: \.domain)

        let domainSummaries = AdvisoryDomain.allCases.compactMap { domain -> AdvisoryDomainArtifactSummary? in
            let rows = grouped[domain] ?? []
            let surfacedCount = rows.first(where: { $0.status == .surfaced })?.count ?? 0
            let queuedCount = rows.first(where: { $0.status == .queued })?.count ?? 0
            let candidateCount = rows.first(where: { $0.status == .candidate })?.count ?? 0
            let acceptedCount = rows.first(where: { $0.status == .accepted })?.count ?? 0
            let mutedCount = rows.first(where: { $0.status == .muted })?.count ?? 0
            guard surfacedCount + queuedCount + candidateCount + acceptedCount + mutedCount > 0 else {
                return nil
            }
            return AdvisoryDomainArtifactSummary(
                domain: domain,
                surfacedCount: surfacedCount,
                queuedCount: queuedCount,
                candidateCount: candidateCount,
                acceptedCount: acceptedCount,
                mutedCount: mutedCount
            )
        }

        return AdvisoryWorkspaceSnapshot(
            localDate: localDate,
            focusState: dayContext.focusState,
            coldStartPhase: coldStart.phase,
            attentionMode: settings.guidanceProfile.attentionMarketMode,
            systemAgeDays: coldStart.systemAgeDays,
            activeThreadCount: activeThreadCount,
            openContinuityCount: openContinuityCount,
            surfacedCount: summaries.filter { $0.status == .surfaced }.reduce(0) { $0 + $1.count },
            queuedCount: summaries.filter { $0.status == .queued }.reduce(0) { $0 + $1.count },
            candidateCount: summaries.filter { $0.status == .candidate }.reduce(0) { $0 + $1.count },
            acceptedCount: summaries.filter { $0.status == .accepted }.reduce(0) { $0 + $1.count },
            mutedCount: summaries.filter { $0.status == .muted }.reduce(0) { $0 + $1.count },
            enabledEnrichmentSources: settings.guidanceProfile.enabledEnrichmentSources,
            domainSummaries: domainSummaries,
            domainMarketSnapshots: marketSnapshot.domainSnapshots,
            enrichmentSourceStatuses: marketSnapshot.enrichmentSources
        )
    }

    func domainWorkspaceDetail(
        for localDate: String,
        domain: AdvisoryDomain,
        limit: Int = 8
    ) throws -> AdvisoryDomainWorkspaceDetail {
        let marketSnapshot = try marketSnapshot(for: localDate)
        let market = marketSnapshot.domainSnapshots.first(where: { $0.domain == domain })
            ?? AdvisoryDomainMarketSnapshot(
                domain: domain,
                surfacedCount: 0,
                queuedCount: 0,
                candidateCount: 0,
                allocationWeight: 0,
                demand: 0,
                fatigue: 0,
                remainingBudgetFactor: 0,
                proactiveEligible: false,
                leadArtifactTitle: nil,
                leadArtifactKind: nil
            )
        let artifacts = try store.listArtifacts(
            statuses: [.surfaced, .accepted, .queued, .candidate, .dismissed, .muted],
            domain: domain,
            limit: max(4, limit)
        ).sorted(by: artifactDisplayPriority)

        let relatedThreadIds = AdvisorySupport.dedupe(artifacts.compactMap(\.threadId))
        let threadsById = try store.threads(ids: relatedThreadIds)
        let relatedThreads = relatedThreadIds
            .compactMap { threadsById[$0] }
            .sorted(by: threadDisplayPriority)

        var continuityItems: [ContinuityItemRecord] = []
        for thread in relatedThreads.prefix(3) {
            continuityItems.append(contentsOf: try store.continuityItemsForThread(
                threadId: thread.id,
                statuses: [.open, .stabilizing, .parked],
                limit: 3
            ))
        }
        continuityItems = Array(Dictionary(uniqueKeysWithValues: continuityItems.map { ($0.id, $0) }).values)
            .sorted(by: continuityDisplayPriority)

        let feedback = try store.listFeedback(artifactIds: artifacts.map(\.id), limit: 24)
        let feedbackCounts = Dictionary(grouping: feedback, by: \.feedbackKind).mapValues(\.count)
        let feedbackSummaries = AdvisoryArtifactFeedbackKind.allCases.compactMap { kind -> AdvisoryDomainFeedbackSummary? in
            guard let count = feedbackCounts[kind], count > 0 else { return nil }
            return AdvisoryDomainFeedbackSummary(kind: kind, count: count)
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.kind.label < rhs.kind.label
            }
            return lhs.count > rhs.count
        }

        let groundingSources = observedGroundingSources(in: artifacts, domain: domain)
        let sourceAnchors = observedSourceAnchors(in: artifacts)
        let evidenceRefs = observedEvidenceRefs(in: artifacts)
        let enrichmentStatuses = marketSnapshot.enrichmentSources.filter {
            groundingSources.contains($0.source)
        }

        return AdvisoryDomainWorkspaceDetail(
            localDate: localDate,
            domain: domain,
            market: market,
            leadArtifact: artifacts.first,
            recentArtifacts: artifacts,
            relatedThreads: relatedThreads,
            continuityItems: continuityItems,
            feedbackSummaries: feedbackSummaries,
            recentFeedback: feedback,
            enrichmentStatuses: enrichmentStatuses,
            groundingSources: groundingSources,
            sourceAnchors: sourceAnchors,
            evidenceRefs: evidenceRefs
        )
    }

    func threadDetail(for id: String?) throws -> AdvisoryThreadDetailSnapshot? {
        guard let id,
              let threadRecord = try store.thread(id: id) else {
            return nil
        }
        let parentThread = try thread(for: threadRecord.parentThreadId)
        let childThreads = try store.childThreads(parentThreadId: threadRecord.id, limit: 12)
        let continuityItems = try store.continuityItemsForThread(
            threadId: threadRecord.id,
            statuses: [.open, .stabilizing, .parked, .resolved],
            limit: 12
        )
        let artifacts = try store.artifactsForThread(
            threadRecord.id,
            statuses: [.surfaced, .accepted, .queued, .candidate, .dismissed],
            limit: 12
        )
        let evidence = try store.threadEvidence(threadId: threadRecord.id)
        let maintenanceProposals = try threadMaintenanceEngine.proposals(
            for: threadRecord.id,
            referenceDate: dateSupport.currentLocalDateString()
        )
        return AdvisoryThreadDetailSnapshot(
            thread: threadRecord,
            parentThread: parentThread,
            childThreads: childThreads,
            continuityItems: continuityItems,
            artifacts: artifacts,
            evidence: evidence,
            maintenanceProposals: maintenanceProposals
        )
    }

    @discardableResult
    func createManualThread(
        title: String,
        kind: AdvisoryThreadKind,
        summary: String? = nil,
        parentThreadId: String? = nil
    ) throws -> AdvisoryThreadDetailSnapshot {
        let thread = try store.createManualThread(
            title: title,
            kind: kind,
            summary: summary,
            parentThreadId: parentThreadId
        )
        guard let detail = try threadDetail(for: thread.id) else {
            throw DatabaseError.executeFailed("Failed to load created thread \(thread.id)")
        }
        return detail
    }

    @discardableResult
    func renameThread(
        threadId: String,
        userTitleOverride: String?
    ) throws -> AdvisoryThreadDetailSnapshot {
        guard let thread = try store.renameThread(threadId: threadId, userTitleOverride: userTitleOverride),
              let detail = try threadDetail(for: thread.id) else {
            throw DatabaseError.executeFailed("Failed to rename thread \(threadId)")
        }
        return detail
    }

    @discardableResult
    func setThreadPinned(
        threadId: String,
        isPinned: Bool
    ) throws -> AdvisoryThreadDetailSnapshot {
        guard let thread = try store.setThreadPinned(threadId: threadId, isPinned: isPinned),
              let detail = try threadDetail(for: thread.id) else {
            throw DatabaseError.executeFailed("Failed to update pin state for thread \(threadId)")
        }
        return detail
    }

    @discardableResult
    func setThreadStatus(
        threadId: String,
        status: AdvisoryThreadStatus
    ) throws -> AdvisoryThreadDetailSnapshot {
        guard let thread = try store.setThreadStatus(threadId: threadId, status: status),
              let detail = try threadDetail(for: thread.id) else {
            throw DatabaseError.executeFailed("Failed to update thread status for \(threadId)")
        }
        return detail
    }

    @discardableResult
    func setThreadParent(
        threadId: String,
        parentThreadId: String?
    ) throws -> AdvisoryThreadDetailSnapshot {
        guard let thread = try store.setThreadParent(threadId: threadId, parentThreadId: parentThreadId),
              let detail = try threadDetail(for: thread.id) else {
            throw DatabaseError.executeFailed("Failed to update thread parent for \(threadId)")
        }
        return detail
    }

    @discardableResult
    func applyThreadMaintenanceProposal(
        threadId: String,
        proposal: AdvisoryThreadMaintenanceProposal
    ) throws -> AdvisoryThreadDetailSnapshot {
        let referenceDate = dateSupport.currentLocalDateString()
        switch proposal.kind {
        case .statusChange:
            guard let status = proposal.suggestedStatus else {
                throw DatabaseError.executeFailed("Missing suggested status")
            }
            _ = try store.setThreadStatus(threadId: threadId, status: status)
            _ = try threadMaintenanceEngine.refresh(referenceDate: referenceDate)
            guard let detail = try threadDetail(for: threadId) else {
                throw DatabaseError.executeFailed("Thread \(threadId) disappeared after status update")
            }
            return detail
        case .reparentUnderThread:
            guard let targetThreadId = proposal.targetThreadId else {
                throw DatabaseError.executeFailed("Missing target thread")
            }
            _ = try store.setThreadParent(threadId: threadId, parentThreadId: targetThreadId)
            _ = try threadMaintenanceEngine.refresh(referenceDate: referenceDate)
            guard let detail = try threadDetail(for: threadId) else {
                throw DatabaseError.executeFailed("Thread \(threadId) disappeared after reparent")
            }
            return detail
        case .mergeIntoThread:
            guard let targetThreadId = proposal.targetThreadId else {
                throw DatabaseError.executeFailed("Missing merge target thread")
            }
            _ = try store.mergeThread(sourceThreadId: threadId, into: targetThreadId)
            _ = try threadMaintenanceEngine.refresh(referenceDate: referenceDate)
            guard let detail = try threadDetail(for: targetThreadId) else {
                throw DatabaseError.executeFailed("Target thread \(targetThreadId) disappeared after merge")
            }
            return detail
        case .splitIntoSubthread:
            let title = proposal.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty else {
                throw DatabaseError.executeFailed("Missing sub-thread title")
            }
            _ = try store.createManualThread(
                title: title,
                kind: proposal.suggestedKind ?? .theme,
                status: .active,
                summary: proposal.suggestedSummary,
                parentThreadId: threadId
            )
            if let sourceContinuityItemId = proposal.sourceContinuityItemId {
                _ = try store.updateContinuityItemStatus(itemId: sourceContinuityItemId, status: .stabilizing)
            }
            _ = try threadMaintenanceEngine.refresh(referenceDate: referenceDate)
            guard let detail = try threadDetail(for: threadId) else {
                throw DatabaseError.executeFailed("Thread \(threadId) disappeared after split")
            }
            return detail
        }
    }

    func exportThreadToObsidian(threadId: String) throws -> String {
        let vaultPath = settings.obsidianVaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vaultPath.isEmpty else {
            throw DatabaseError.executeFailed("Obsidian vault path is not configured")
        }
        guard let detail = try threadDetail(for: threadId) else {
            throw DatabaseError.executeFailed("Thread \(threadId) is missing")
        }
        let exporter = ObsidianExporter(db: db, vaultPath: vaultPath, timeZone: dateSupport.timeZone)
        return try exporter.exportAdvisoryThread(detail)
    }

    @discardableResult
    func turnThreadIntoSignal(
        threadId: String,
        for localDate: String
    ) throws -> [AdvisoryArtifactRecord] {
        guard let detail = try threadDetail(for: threadId) else {
            return []
        }
        let context = try loadContext(localDate: localDate)
        let coldStart = try coldStartContext(for: localDate)
        let enrichment = try enrichmentContextBuilder.buildThreadEnrichment(
            window: context.window,
            detail: detail,
            sessions: context.sessions
        )
        let packet = threadPacketBuilder.build(
            triggerKind: .userInvokedWrite,
            window: context.window,
            detail: detail,
            sessions: context.sessions,
            enrichment: enrichment
        )
        let dayContext = reflectionPacketBuilder.buildDayContext(
            localDate: localDate,
            triggerKind: .userInvokedWrite,
            activeThreadCount: 1,
            openContinuityCount: detail.continuityItems.filter { $0.status == .open || $0.status == .stabilizing }.count,
            sessions: context.sessions,
            systemAgeDays: coldStart.systemAgeDays,
            coldStartPhase: coldStart.phase,
            signalWeights: Dictionary(uniqueKeysWithValues: packet.attentionSignals.map { ($0.name, $0.score) })
        )
        let artifacts = try executeSingleRecipe(
            packet: packet,
            requestPacket: .thread(packet),
            recipeName: "tweet_from_thread",
            recipeDomain: .writingExpression,
            triggerKind: .userInvokedWrite,
            dayContext: dayContext
        )
        if !artifacts.isEmpty {
            return artifacts
        }
        guard let fallback = ThreadWritingSeedComposer().compose(
            packet: packet,
            recipeName: "tweet_from_thread"
        ) else {
            return []
        }
        return [try store.upsertArtifact(fallback)]
    }

    @discardableResult
    func generateWeeklyReview(
        for localDate: String
    ) throws -> AdvisoryArtifactRecord? {
        let coldStart = try coldStartContext(for: localDate)
        let weeklyContext = try loadWeeklyContext(containing: localDate)
        let enrichment = try enrichmentContextBuilder.buildWeeklyEnrichment(
            window: weeklyContext.window,
            threads: weeklyContext.threads,
            continuityItems: weeklyContext.continuityItems,
            sessions: weeklyContext.sessions
        )
        let packet = weeklyPacketBuilder.build(
            triggerKind: .weeklyReview,
            weekDate: weeklyContext.window.date,
            windowStart: weeklyContext.window.start,
            windowEnd: weeklyContext.window.end,
            threads: weeklyContext.threads,
            continuityItems: weeklyContext.continuityItems,
            sessions: weeklyContext.sessions,
            enrichment: enrichment
        )
        let dayContext = reflectionPacketBuilder.buildDayContext(
            localDate: localDate,
            triggerKind: .weeklyReview,
            activeThreadCount: weeklyContext.threads.count,
            openContinuityCount: weeklyContext.continuityItems.filter { $0.status == .open || $0.status == .stabilizing }.count,
            sessions: weeklyContext.sessions,
            systemAgeDays: coldStart.systemAgeDays,
            coldStartPhase: coldStart.phase,
            signalWeights: Dictionary(uniqueKeysWithValues: packet.attentionSignals.map { ($0.name, $0.score) })
        )
        let artifacts = try executeSingleRecipe(
            packet: packet,
            requestPacket: .weekly(packet),
            recipeName: "weekly_reflection",
            recipeDomain: .continuity,
            triggerKind: .weeklyReview,
            dayContext: dayContext
        )
        if let selected = artifacts.first(where: { $0.kind == .weeklyReview }) ?? artifacts.first {
            return selected
        }
        guard let fallback = WeeklyReviewComposer().compose(
            packet: packet,
            recipeName: "weekly_reflection"
        ) else {
            return nil
        }
        return try store.upsertArtifact(fallback)
    }

    private func recipePlan(
        packet: ReflectionPacket,
        dayContext: AdvisoryDayContext
    ) -> [AdvisoryRecipeSpec] {
        let signals = Dictionary(uniqueKeysWithValues: packet.attentionSignals.map { ($0.name, $0.score) })
        return AdvisoryRecipeCatalog.all.filter { spec in
            guard settings.advisoryEnabledDomains.contains(spec.domain) else {
                return false
            }

            guard coldStartPolicy.allows(recipe: spec, dayContext: dayContext) else {
                return false
            }

            if spec.name == "thread_maintenance", packet.candidateThreadRefs.count < 2 {
                return false
            }

            let domainSignal = recipeSignal(for: spec, signals: signals)
            let minimumSignal = coldStartPolicy.adjustedMinimumSignal(
                for: spec,
                dayContext: dayContext
            )
            if packet.triggerKind.isUserInvoked && spec.userInvokedBonus {
                return domainSignal >= max(0.18, minimumSignal - 0.12)
            }
            return domainSignal >= minimumSignal
        }
    }

    private func recipeSignal(for spec: AdvisoryRecipeSpec, signals: [String: Double]) -> Double {
        if spec.name == "thread_maintenance" {
            return max(signals["thread_density"] ?? 0, (signals["continuity_pressure"] ?? 0) * 0.7)
        }
        return signal(for: spec.domain, signals: signals)
    }

    private func signal(for domain: AdvisoryDomain, signals: [String: Double]) -> Double {
        switch domain {
        case .continuity: return signals["continuity_pressure"] ?? 0
        case .writingExpression: return signals["expression_pull"] ?? 0
        case .research: return signals["research_pull"] ?? 0
        case .focus: return signals["focus_turbulence"] ?? 0
        case .social: return signals["social_pull"] ?? 0
        case .health: return signals["health_pressure"] ?? 0
        case .decisions: return signals["decision_density"] ?? 0
        case .lifeAdmin: return signals["life_admin_pressure"] ?? 0
        }
    }

    private func loadContext(localDate: String) throws -> (window: SummaryWindowDescriptor, summary: DailySummaryRecord?, sessions: [SessionData]) {
        guard let start = dateSupport.startOfLocalDay(for: localDate),
              let end = dateSupport.endOfLocalDay(for: localDate) else {
            throw DatabaseError.executeFailed("Invalid local advisory date \(localDate)")
        }
        let currentLocalDate = dateSupport.currentLocalDateString()
        let windowEnd = localDate == currentLocalDate ? min(Date(), end) : end
        let window = SummaryWindowDescriptor(date: localDate, start: start, end: windowEnd)

        let summarizer = DailySummarizer(db: db, timeZone: dateSupport.timeZone)
        let summary = try summarizer.summaryRecord(for: localDate)
        let sessions = try summarizer.collectSessionData(for: window)
        return (window, summary, sessions)
    }

    private func enrichmentBundles(
        for localDate: String
    ) throws -> [ReflectionEnrichmentBundle] {
        guard settings.advisoryEnabled else { return [] }
        do {
            return try buildReflectionExecutionContext(
                localDate: localDate,
                triggerKind: .sessionEnd
            ).packet.enrichment.bundles
        } catch {
            return []
        }
    }

    private func loadWeeklyContext(
        containing localDate: String
    ) throws -> (window: SummaryWindowDescriptor, threads: [AdvisoryThreadRecord], continuityItems: [ContinuityItemRecord], sessions: [SessionData]) {
        let calendar = weeklyCalendar()
        guard let selectedDate = dateSupport.startOfLocalDay(for: localDate),
              let weekInterval = calendar.dateInterval(of: .weekOfYear, for: selectedDate) else {
            throw DatabaseError.executeFailed("Invalid weekly advisory date \(localDate)")
        }

        let currentDayEnd = dateSupport.currentLocalDateString() == localDate ? Date() : weekInterval.end
        let windowEnd = min(currentDayEnd, weekInterval.end)
        let weekDate = dateSupport.localDateString(from: weekInterval.start)
        let window = SummaryWindowDescriptor(date: weekDate, start: weekInterval.start, end: windowEnd)
        let summarizer = DailySummarizer(db: db, timeZone: dateSupport.timeZone)
        let sessions = try summarizer.collectSessionData(for: window)
        let refreshedThreads = try threadMaintenanceEngine.refresh(referenceDate: localDate)
        let threads = refreshedThreads.isEmpty
            ? try store.listThreads(statuses: [.active, .stalled, .parked], limit: 8)
            : Array(refreshedThreads.prefix(8))
        let continuityItems = try store.listContinuityItems(statuses: [.open, .stabilizing, .parked], limit: 10)
        return (window, threads, continuityItems, sessions)
    }

    private func coldStartContext(for localDate: String) throws -> (systemAgeDays: Int, phase: AdvisoryColdStartPhase) {
        let summaryRow = try db.query("SELECT MIN(date) AS first_date FROM daily_summaries")
        let sessionRow = try db.query("SELECT MIN(started_at) AS first_started_at FROM sessions")

        let summaryDate = summaryRow.first?["first_date"]?.textValue
        let sessionStartedAt = sessionRow.first?["first_started_at"]?.textValue

        let earliestSummary = summaryDate.flatMap { dateSupport.startOfLocalDay(for: $0) }
        let earliestSession = sessionStartedAt.flatMap(dateSupport.parseDateTime)
        let anchorDate = [earliestSummary, earliestSession].compactMap { $0 }.min() ?? Date()

        guard let currentStart = dateSupport.startOfLocalDay(for: localDate) else {
            return (1, .bootstrap)
        }

        let ageDays = max(1, Calendar(identifier: .gregorian).dateComponents([.day], from: anchorDate, to: currentStart).day.map { $0 + 1 } ?? 1)
        let phase = coldStartPolicy.phase(for: ageDays)
        return (ageDays, phase)
    }

    private func selectThreadsForPacket(
        today: [AdvisoryThreadRecord],
        maintained: [AdvisoryThreadRecord]
    ) -> [AdvisoryThreadRecord] {
        var uniqueById: [String: AdvisoryThreadRecord] = [:]
        for thread in maintained + today {
            if let existing = uniqueById[thread.id] {
                uniqueById[thread.id] = preferredThread(existing, thread)
            } else {
                uniqueById[thread.id] = thread
            }
        }
        let unique = Array(uniqueById.values)
        return unique.sorted { lhs, rhs in
            if lhs.userPinned != rhs.userPinned {
                return lhs.userPinned && !rhs.userPinned
            }
            if lhs.importanceScore == rhs.importanceScore {
                if lhs.status == rhs.status {
                    return lhs.confidence > rhs.confidence
                }
                return threadStatusRank(lhs.status) < threadStatusRank(rhs.status)
            }
            return lhs.importanceScore > rhs.importanceScore
        }
    }

    private func threadStatusRank(_ status: AdvisoryThreadStatus) -> Int {
        switch status {
        case .active: return 0
        case .stalled: return 1
        case .parked: return 2
        case .resolved: return 3
        }
    }

    private func preferredThread(
        _ lhs: AdvisoryThreadRecord,
        _ rhs: AdvisoryThreadRecord
    ) -> AdvisoryThreadRecord {
        if lhs.userPinned != rhs.userPinned {
            return lhs.userPinned ? lhs : rhs
        }
        if lhs.importanceScore != rhs.importanceScore {
            return lhs.importanceScore > rhs.importanceScore ? lhs : rhs
        }
        if lhs.confidence != rhs.confidence {
            return lhs.confidence > rhs.confidence ? lhs : rhs
        }
        return (lhs.updatedAt ?? "") >= (rhs.updatedAt ?? "") ? lhs : rhs
    }

    private func executeSingleRecipe<T: AdvisoryPacketPayload>(
        packet: T,
        requestPacket: AdvisoryPacket,
        recipeName: String,
        recipeDomain: AdvisoryDomain,
        triggerKind: AdvisoryTriggerKind,
        dayContext: AdvisoryDayContext,
        reuseExistingRecipeArtifactsOnly: Bool = false
    ) throws -> [AdvisoryArtifactRecord] {
        _ = try store.savePacket(packet)

        let existingArtifacts = try store.artifactsForPacket(
            packet.packetId,
            statuses: [.surfaced, .queued, .candidate],
            sourceRecipe: reuseExistingRecipeArtifactsOnly ? recipeName : nil
        )
        if !existingArtifacts.isEmpty {
            return existingArtifacts
        }

        let request = AdvisoryRecipeRequest(
            runId: AdvisorySupport.stableIdentifier(
                prefix: "recipe",
                components: [recipeName, packet.packetId, triggerKind.rawValue]
            ),
            recipeName: recipeName,
            packet: requestPacket,
            accessLevel: settings.advisoryAccessProfile,
            timeoutSeconds: settings.advisorySidecarTimeoutSeconds
        )

        let execution: AdvisoryBridgeExecution
        do {
            execution = try bridge.executeRecipe(request)
        } catch {
            let health = bridge.health()
            let failedRun = try store.recordRun(
                recipeName: recipeName,
                recipeDomain: recipeDomain,
                packetId: packet.packetId,
                triggerKind: triggerKind,
                runtimeName: health.runtimeName,
                providerName: health.providerName,
                accessLevelRequested: settings.advisoryAccessProfile,
                accessLevelGranted: settings.advisoryAccessProfile,
                status: .failed,
                outputArtifactIds: [],
                errorText: error.localizedDescription
            )
            recordPreloadedEvidenceRequest(
                packet: requestPacket,
                runId: failedRun.id,
                recipeName: recipeName
            )
            throw error
        }

        if let primaryFailure = execution.primaryFailure,
           let attempted = execution.attemptedPrimaryHealth {
            let failedAttemptRun = try store.recordRun(
                recipeName: recipeName,
                recipeDomain: recipeDomain,
                packetId: packet.packetId,
                triggerKind: triggerKind,
                runtimeName: attempted.runtimeName,
                providerName: attempted.providerName,
                accessLevelRequested: settings.advisoryAccessProfile,
                accessLevelGranted: settings.advisoryAccessProfile,
                status: .failed,
                outputArtifactIds: [],
                errorText: primaryFailure
            )
            recordPreloadedEvidenceRequest(
                packet: requestPacket,
                runId: failedAttemptRun.id,
                recipeName: recipeName
            )
        }

        for item in execution.result.continuityProposals {
            _ = try store.upsertContinuityItem(item)
        }

        let proposals = try execution.result.artifactProposals.map { try store.upsertArtifact($0) }
        let successRun = try store.recordRun(
            recipeName: recipeName,
            recipeDomain: recipeDomain,
            packetId: packet.packetId,
            triggerKind: triggerKind,
            runtimeName: execution.activeHealth.runtimeName,
            providerName: execution.activeHealth.providerName,
            accessLevelRequested: settings.advisoryAccessProfile,
            accessLevelGranted: settings.advisoryAccessProfile,
            status: .success,
            outputArtifactIds: proposals.map(\.id)
        )
        recordPreloadedEvidenceRequest(
            packet: requestPacket,
            runId: successRun.id,
            recipeName: recipeName
        )

        let surfaced = try exchange.evaluateAndSurface(
            candidateArtifacts: proposals,
            triggerKind: triggerKind,
            dayContext: dayContext
        )
        if !surfaced.isEmpty {
            return surfaced
        }
        let latestById = try store.artifacts(ids: proposals.map(\.id))
        return proposals.compactMap { latestById[$0.id] ?? $0 }
    }

    private func weeklyCalendar() -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = dateSupport.timeZone
        return calendar
    }

    private func recordPreloadedEvidenceRequest(
        packet: AdvisoryPacket,
        runId: String,
        recipeName: String
    ) {
        let embeddedEnrichmentKinds = AdvisorySupport.dedupe(
            packetEnrichment(packet).bundles
                .filter { $0.availability == .embedded }
                .map(\.source.rawValue)
        )
        guard !embeddedEnrichmentKinds.isEmpty else {
            return
        }

        let requestedLevel = packetEnrichment(packet).bundles.contains(where: {
            $0.availability == .embedded && $0.tier == .l3Rich
        }) ? AdvisoryAccessProfile.fullResearchMode : AdvisoryAccessProfile.deepContext

        do {
            _ = try store.recordEvidenceRequest(
                runId: runId,
                requestedLevel: requestedLevel,
                reason: "Preloaded packet enrichment for \(recipeName)",
                evidenceKinds: embeddedEnrichmentKinds,
                granted: true
            )
        } catch {
            logger.error("Failed to record advisory evidence request for \(recipeName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func packetEnrichment(_ packet: AdvisoryPacket) -> ReflectionPacketEnrichment {
        switch packet {
        case .reflection(let reflection):
            return reflection.enrichment
        case .thread(let thread):
            return thread.enrichment
        case .weekly(let weekly):
            return weekly.enrichment
        }
    }

    private func buildReflectionExecutionContext(
        localDate: String,
        triggerKind: AdvisoryTriggerKind
    ) throws -> ReflectionExecutionContext {
        let context = try loadContext(localDate: localDate)
        guard context.summary != nil || !context.sessions.isEmpty else {
            throw DatabaseError.executeFailed("No advisory context for \(localDate)")
        }

        let detections = try threadDetector.detect(
            summary: context.summary,
            window: context.window,
            sessions: context.sessions
        )
        let todaysThreads = try detections.map { detection -> AdvisoryThreadRecord in
            let thread = try store.upsertThread(detection.thread)
            _ = try store.upsertThreadEvidence(threadId: thread.id, evidence: detection.evidence)
            return thread
        }
        let maintainedThreads = try threadMaintenanceEngine.refresh(referenceDate: localDate)
        let coldStart = try coldStartContext(for: localDate)
        let packetThreads = coldStartPolicy.filteredThreadsForPacket(
            selectThreadsForPacket(today: todaysThreads, maintained: maintainedThreads),
            phase: coldStart.phase
        )
        let continuityCandidates = coldStartPolicy.filteredContinuityItems(
            continuitySignalBuilder.build(
                summary: context.summary,
                window: context.window,
                sessions: context.sessions,
                threads: packetThreads
            ),
            phase: coldStart.phase
        )
        let enrichment = try enrichmentContextBuilder.buildReflectionEnrichment(
            window: context.window,
            summary: context.summary,
            threads: packetThreads,
            sessions: context.sessions
        )
        let packet = reflectionPacketBuilder.build(
            triggerKind: triggerKind,
            window: context.window,
            summary: context.summary,
            sessions: context.sessions,
            threads: packetThreads,
            continuityItems: continuityCandidates,
            enrichment: enrichment
        )
        let dayContext = reflectionPacketBuilder.buildDayContext(
            packet: packet,
            threads: packetThreads,
            continuityItems: continuityCandidates,
            sessions: context.sessions,
            systemAgeDays: coldStart.systemAgeDays,
            coldStartPhase: coldStart.phase
        )
        return ReflectionExecutionContext(
            window: context.window,
            summary: context.summary,
            sessions: context.sessions,
            threads: packetThreads,
            continuityCandidates: continuityCandidates,
            packet: packet,
            dayContext: dayContext
        )
    }

    private func manualDomainPacket(
        _ packet: ReflectionPacket,
        domain: AdvisoryDomain
    ) -> ReflectionPacket {
        guard let signalName = manualSignalName(for: domain) else {
            return packet
        }

        var signals = packet.attentionSignals
        let floor = manualSignalFloor(for: domain)
        if let index = signals.firstIndex(where: { $0.name == signalName }) {
            let signal = signals[index]
            signals[index] = ReflectionAttentionSignal(
                id: signal.id,
                name: signal.name,
                score: max(signal.score, floor),
                note: signal.note + " Manual domain pull requested."
            )
        } else {
            signals.append(
                ReflectionAttentionSignal(
                    id: AdvisorySupport.stableIdentifier(
                        prefix: "signal",
                        components: [packet.packetId, domain.rawValue, "manual"]
                    ),
                    name: signalName,
                    score: floor,
                    note: "Manual domain pull requested."
                )
            )
        }

        var confidenceHints = packet.confidenceHints
        confidenceHints[domain.rawValue] = max(confidenceHints[domain.rawValue] ?? 0, floor)

        return ReflectionPacket(
            packetId: packet.packetId,
            packetVersion: packet.packetVersion,
            kind: packet.kind,
            triggerKind: packet.triggerKind,
            timeWindow: packet.timeWindow,
            activeEntities: packet.activeEntities,
            candidateThreadRefs: packet.candidateThreadRefs,
            salientSessions: packet.salientSessions,
            candidateContinuityItems: packet.candidateContinuityItems,
            attentionSignals: signals,
            constraints: packet.constraints,
            language: packet.language,
            evidenceRefs: packet.evidenceRefs,
            confidenceHints: confidenceHints,
            accessLevelGranted: packet.accessLevelGranted,
            allowedTools: packet.allowedTools,
            providerConstraints: packet.providerConstraints,
            enrichment: packet.enrichment
        )
    }

    private func manualSignalName(for domain: AdvisoryDomain) -> String? {
        switch domain {
        case .continuity: return "continuity_pressure"
        case .writingExpression: return "expression_pull"
        case .research: return "research_pull"
        case .focus: return "focus_turbulence"
        case .social: return "social_pull"
        case .health: return "health_pressure"
        case .decisions: return "decision_density"
        case .lifeAdmin: return "life_admin_pressure"
        }
    }

    private func manualSignalFloor(for domain: AdvisoryDomain) -> Double {
        switch domain {
        case .continuity: return 0.32
        case .writingExpression: return 0.34
        case .research: return 0.3
        case .focus: return 0.28
        case .social: return 0.26
        case .health: return 0.32
        case .decisions: return 0.24
        case .lifeAdmin: return 0.22
        }
    }

    private func preferredArtifact(
        in artifacts: [AdvisoryArtifactRecord],
        for domain: AdvisoryDomain
    ) -> AdvisoryArtifactRecord? {
        let ranked = artifacts
            .filter { $0.domain == domain }
            .sorted(by: artifactDisplayPriority)
        return ranked.first ?? artifacts.first
    }

    private func artifactDisplayPriority(
        _ lhs: AdvisoryArtifactRecord,
        _ rhs: AdvisoryArtifactRecord
    ) -> Bool {
        if artifactStatusRank(lhs.status) == artifactStatusRank(rhs.status) {
            if lhs.marketScore == rhs.marketScore {
                return lhs.confidence > rhs.confidence
            }
            return lhs.marketScore > rhs.marketScore
        }
        return artifactStatusRank(lhs.status) < artifactStatusRank(rhs.status)
    }

    private func threadDisplayPriority(
        _ lhs: AdvisoryThreadRecord,
        _ rhs: AdvisoryThreadRecord
    ) -> Bool {
        if lhs.userPinned != rhs.userPinned {
            return lhs.userPinned && !rhs.userPinned
        }
        if lhs.importanceScore == rhs.importanceScore {
            return (lhs.lastActiveAt ?? lhs.firstSeenAt ?? "") > (rhs.lastActiveAt ?? rhs.firstSeenAt ?? "")
        }
        return lhs.importanceScore > rhs.importanceScore
    }

    private func continuityDisplayPriority(
        _ lhs: ContinuityItemRecord,
        _ rhs: ContinuityItemRecord
    ) -> Bool {
        if continuityStatusRank(lhs.status) == continuityStatusRank(rhs.status) {
            if lhs.confidence == rhs.confidence {
                return (lhs.updatedAt ?? lhs.createdAt ?? "") > (rhs.updatedAt ?? rhs.createdAt ?? "")
            }
            return lhs.confidence > rhs.confidence
        }
        return continuityStatusRank(lhs.status) < continuityStatusRank(rhs.status)
    }

    private func observedGroundingSources(
        in artifacts: [AdvisoryArtifactRecord],
        domain: AdvisoryDomain
    ) -> [AdvisoryEnrichmentSource] {
        let observed = dedupeEnrichmentSources(artifacts.flatMap { artifact in
            if let writing = artifact.writingMetadata {
                return writing.enrichmentSources
            }
            if let guidance = artifact.guidanceMetadata {
                return guidance.enrichmentSources
            }
            return []
        })
        if !observed.isEmpty {
            return observed
        }
        return domain.suggestedEnrichmentSources.filter(settings.guidanceProfile.enabledEnrichmentSources.contains)
    }

    private func observedSourceAnchors(
        in artifacts: [AdvisoryArtifactRecord]
    ) -> [String] {
        AdvisorySupport.dedupe(artifacts.flatMap { artifact in
            if let writing = artifact.writingMetadata {
                return writing.sourceAnchors
            }
            if let guidance = artifact.guidanceMetadata {
                return guidance.sourceAnchors
            }
            return []
        })
    }

    private func observedEvidenceRefs(
        in artifacts: [AdvisoryArtifactRecord]
    ) -> [String] {
        AdvisorySupport.dedupe(artifacts.flatMap(\.evidenceRefs))
    }

    private func dedupeEnrichmentSources(
        _ sources: [AdvisoryEnrichmentSource]
    ) -> [AdvisoryEnrichmentSource] {
        var seen: Set<AdvisoryEnrichmentSource> = []
        var ordered: [AdvisoryEnrichmentSource] = []
        for source in sources where seen.insert(source).inserted {
            ordered.append(source)
        }
        return ordered
    }

    private func artifactStatusRank(_ status: AdvisoryArtifactStatus) -> Int {
        switch status {
        case .surfaced: return 0
        case .accepted: return 1
        case .queued: return 2
        case .candidate: return 3
        case .dismissed: return 4
        case .expired: return 5
        case .muted: return 6
        }
    }

    private func continuityStatusRank(_ status: ContinuityItemStatus) -> Int {
        switch status {
        case .open: return 0
        case .stabilizing: return 1
        case .parked: return 2
        case .resolved: return 3
        }
    }

    private func effectiveThreadId(
        for threadId: String?
    ) throws -> String? {
        guard let threadId else { return nil }
        guard let thread = try store.thread(id: threadId) else {
            return threadId
        }
        if thread.status == .resolved {
            return thread.parentThreadId
        }
        return thread.id
    }
}

private struct ReflectionExecutionContext {
    let window: SummaryWindowDescriptor
    let summary: DailySummaryRecord?
    let sessions: [SessionData]
    let threads: [AdvisoryThreadRecord]
    let continuityCandidates: [ContinuityItemCandidate]
    let packet: ReflectionPacket
    let dayContext: AdvisoryDayContext
}
