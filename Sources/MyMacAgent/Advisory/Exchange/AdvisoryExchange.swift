import Foundation

final class AdvisoryExchange {
    private let store: AdvisoryArtifactStore
    private let settings: AppSettings
    private let dateSupport: LocalDateSupport
    private let evaluator = AttentionMarketEvaluator()
    private let governor = AttentionGovernor()
    private let timingPolicy = AttentionTimingPolicy()
    private let coldStartPolicy = AdvisoryColdStartPolicy()

    init(
        store: AdvisoryArtifactStore,
        settings: AppSettings = AppSettings(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.store = store
        self.settings = settings
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func evaluateAndSurface(
        candidateArtifacts: [AdvisoryArtifactRecord],
        triggerKind: AdvisoryTriggerKind,
        dayContext: AdvisoryDayContext,
        now: Date = Date()
    ) throws -> [AdvisoryArtifactRecord] {
        guard settings.advisoryEnabled, !candidateArtifacts.isEmpty else {
            return candidateArtifacts
        }

        let guidance = settings.guidanceProfile
        let recentSurfaced = try store.listArtifacts(statuses: [.surfaced, .accepted], limit: 50)
            .sorted { lhs, rhs in
                let lhsTimestamp = lhs.surfacedAt ?? lhs.createdAt ?? ""
                let rhsTimestamp = rhs.surfacedAt ?? rhs.createdAt ?? ""
                return lhsTimestamp > rhsTimestamp
            }
        let feedback = try store.listFeedback(limit: 200)
        let threadIds = candidateArtifacts.compactMap(\.threadId)
        let threadsById = try store.threads(ids: threadIds)
        let feedbackArtifactsById = try store.artifacts(
            ids: Array(Set(feedback.map(\.artifactId) + candidateArtifacts.map(\.id) + recentSurfaced.map(\.id)))
        )

        let domainStates = governor.buildDomainStates(
            candidates: candidateArtifacts,
            recentSurfaced: recentSurfaced,
            guidance: guidance,
            dayContext: dayContext,
            now: now,
            dateSupport: dateSupport
        )

        let evaluated = evaluator.evaluate(
            candidates: candidateArtifacts,
            recentSurfaced: recentSurfaced,
            feedback: feedback,
            feedbackArtifactsById: feedbackArtifactsById,
            threadsById: threadsById,
            guidance: guidance,
            dayContext: dayContext,
            domainStates: domainStates,
            now: now,
            dateSupport: dateSupport
        )

        let surfacedTodayCount = recentSurfaced.filter {
            guard let timestamp = $0.surfacedAt ?? $0.createdAt,
                  let date = dateSupport.parseDateTime(timestamp) else {
                return false
            }
            return dateSupport.localDateString(from: date) == dayContext.localDate
        }.count

        let lastSurfaceAt = recentSurfaced.first.flatMap { artifact in
            (artifact.surfacedAt ?? artifact.createdAt).flatMap(dateSupport.parseDateTime)
        }
        let adaptiveGapMinutes = timingPolicy.adaptiveMinGapMinutes(for: dayContext, guidance: guidance)
        let respectsGlobalGap =
            lastSurfaceAt.map { now.timeIntervalSince($0) / 60 >= Double(adaptiveGapMinutes) } ?? true

        let canSurfaceProactively =
            surfacedTodayCount < coldStartPolicy.effectiveDailyBudget(guidance: guidance, dayContext: dayContext)
            && surfacedTodayCount < guidance.hardDailyCap
            && respectsGlobalGap
            && coldStartPolicy.allowsProactiveSurface(dayContext: dayContext)

        let selection = governor.select(
            evaluated: evaluated,
            dayContext: dayContext,
            domainStates: domainStates,
            recentSurfaced: recentSurfaced,
            guidance: guidance,
            evaluator: evaluator,
            now: now,
            dateSupport: dateSupport
        )

        let allowSurface = triggerKind.isUserInvoked || (guidance.allowProactiveAdvice && canSurfaceProactively)
        let surfacedIds = allowSurface ? Set(selection.surfaced.map { $0.artifact.id }) : Set<String>()
        let queuedIds = Set(selection.queued.map { $0.artifact.id })

        for evaluatedArtifact in selection.surfaced + selection.queued + selection.dismissed {
            let targetStatus: AdvisoryArtifactStatus
            if surfacedIds.contains(evaluatedArtifact.artifact.id) {
                targetStatus = .surfaced
            } else if queuedIds.contains(evaluatedArtifact.artifact.id) || !allowSurface {
                targetStatus = .queued
            } else {
                targetStatus = .dismissed
            }

            try store.updateArtifactMarketState(
                artifactId: evaluatedArtifact.artifact.id,
                status: targetStatus,
                marketScore: evaluatedArtifact.marketContext.readinessSignal,
                attentionVectorJson: AdvisorySupport.encodeJSONString(evaluatedArtifact.attentionVector),
                marketContextJson: AdvisorySupport.encodeJSONString(evaluatedArtifact.marketContext),
                surfacedAt: surfacedIds.contains(evaluatedArtifact.artifact.id) ? dateSupport.isoString(from: now) : nil
            )
        }

        if allowSurface, !selection.surfaced.isEmpty {
            return try selection.surfaced.compactMap { try store.artifact(id: $0.artifact.id) }
        }

        let fallbackOrder = selection.queued + selection.surfaced + selection.dismissed
        return try fallbackOrder.compactMap { try store.artifact(id: $0.artifact.id) }
    }
}
