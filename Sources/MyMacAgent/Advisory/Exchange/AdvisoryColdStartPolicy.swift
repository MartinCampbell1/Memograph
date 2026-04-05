import Foundation

struct AdvisoryColdStartPolicy {
    func phase(for systemAgeDays: Int) -> AdvisoryColdStartPhase {
        switch max(1, systemAgeDays) {
        case 1...3:
            return .bootstrap
        case 4...7:
            return .earlyThreads
        case 8...27:
            return .operational
        default:
            return .mature
        }
    }

    func effectiveDailyBudget(
        guidance: GuidanceProfile,
        dayContext: AdvisoryDayContext
    ) -> Int {
        switch dayContext.coldStartPhase {
        case .bootstrap:
            return 0
        case .earlyThreads:
            return min(2, guidance.dailyAttentionBudget)
        case .operational:
            return guidance.dailyAttentionBudget
        case .mature:
            return min(guidance.hardDailyCap, max(guidance.dailyAttentionBudget, guidance.dailyAttentionBudget + 1))
        }
    }

    func allowsProactiveSurface(dayContext: AdvisoryDayContext) -> Bool {
        dayContext.coldStartPhase != .bootstrap
    }

    func adjustedMinimumSignal(
        for spec: AdvisoryRecipeSpec,
        dayContext: AdvisoryDayContext
    ) -> Double {
        let base = spec.minimumSignal
        switch dayContext.coldStartPhase {
        case .bootstrap:
            if spec.name == "continuity_resume" {
                return max(0.30, base + 0.06)
            }
            return 1.0
        case .earlyThreads:
            switch spec.domain {
            case .continuity:
                return max(0.24, base)
            case .research, .focus, .decisions, .lifeAdmin:
                return min(0.9, base + 0.06)
            case .writingExpression:
                return min(0.9, base + 0.10)
            case .social, .health:
                return min(0.95, base + 0.18)
            }
        case .operational:
            switch spec.domain {
            case .social, .health:
                return min(0.95, base + 0.12)
            case .writingExpression:
                return min(0.9, base + 0.04)
            default:
                return base
            }
        case .mature:
            return base
        }
    }

    func allows(
        recipe spec: AdvisoryRecipeSpec,
        dayContext: AdvisoryDayContext
    ) -> Bool {
        switch dayContext.coldStartPhase {
        case .bootstrap:
            return spec.name == "continuity_resume"
        case .earlyThreads:
            switch spec.name {
            case "continuity_resume", "research_direction", "focus_reflection", "decision_review", "life_admin_review":
                return true
            case "writing_seed":
                return dayContext.triggerKind == .userInvokedWrite
            default:
                return false
            }
        case .operational:
            switch spec.name {
            case "thread_maintenance":
                return false
            case "social_signal", "health_pulse":
                return dayContext.triggerKind.isUserInvoked
            default:
                return true
            }
        case .mature:
            return true
        }
    }

    func domainBudgetCap(
        for domain: AdvisoryDomain,
        dayContext: AdvisoryDayContext
    ) -> Double? {
        switch dayContext.coldStartPhase {
        case .bootstrap:
            return 0
        case .earlyThreads:
            switch domain {
            case .continuity:
                return 1.0
            case .research, .focus, .decisions, .lifeAdmin:
                return 0.5
            case .writingExpression, .social, .health:
                return 0
            }
        case .operational:
            switch domain {
            case .continuity, .writingExpression, .research, .focus, .decisions:
                return nil
            case .lifeAdmin:
                return 0.75
            case .social, .health:
                return 0
            }
        case .mature:
            return nil
        }
    }

    func filteredThreadsForPacket(_ threads: [AdvisoryThreadRecord], phase: AdvisoryColdStartPhase) -> [AdvisoryThreadRecord] {
        guard !threads.isEmpty else { return [] }

        let filtered: [AdvisoryThreadRecord]
        let limit: Int
        switch phase {
        case .bootstrap:
            filtered = threads.filter { thread in
                thread.userPinned
                    || (
                        thread.status == .active
                            && (thread.confidence >= 0.62
                                || thread.totalActiveMinutes >= 30
                                || thread.importanceScore >= 0.60)
                    )
            }
            limit = 3
        case .earlyThreads:
            filtered = threads.filter { thread in
                thread.userPinned
                    || (
                        thread.status != .resolved
                            && (thread.confidence >= 0.52
                                || thread.totalActiveMinutes >= 20
                                || thread.importanceScore >= 0.52)
                    )
            }
            limit = 4
        case .operational:
            filtered = threads
            limit = 6
        case .mature:
            filtered = threads
            limit = 8
        }

        if !filtered.isEmpty {
            return Array(filtered.prefix(limit))
        }
        return Array(threads.prefix(phase == .bootstrap ? 1 : min(2, limit)))
    }

    func filteredContinuityItems(_ items: [ContinuityItemCandidate], phase: AdvisoryColdStartPhase) -> [ContinuityItemCandidate] {
        guard !items.isEmpty else { return [] }

        let ranked = items.sorted { lhs, rhs in
            if continuityStatusRank(lhs.status) == continuityStatusRank(rhs.status) {
                return lhs.confidence > rhs.confidence
            }
            return continuityStatusRank(lhs.status) < continuityStatusRank(rhs.status)
        }

        switch phase {
        case .bootstrap:
            let filtered = ranked.filter { item in
                item.confidence >= 0.58 || item.kind == .openLoop || item.kind == .decision
            }
            return Array((filtered.isEmpty ? ranked : filtered).prefix(3))
        case .earlyThreads:
            let filtered = ranked.filter { item in
                item.confidence >= 0.48 || item.kind == .openLoop || item.kind == .decision
            }
            return Array((filtered.isEmpty ? ranked : filtered).prefix(4))
        case .operational:
            return Array(ranked.prefix(6))
        case .mature:
            return Array(ranked.prefix(8))
        }
    }

    private func continuityStatusRank(_ status: ContinuityItemStatus) -> Int {
        switch status {
        case .open:
            return 0
        case .stabilizing:
            return 1
        case .parked:
            return 2
        case .resolved:
            return 3
        }
    }
}
