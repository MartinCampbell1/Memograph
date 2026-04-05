import Foundation

struct AttentionTimingPolicy {
    func focusStateFit(
        for artifact: AdvisoryArtifactRecord,
        dayContext: AdvisoryDayContext
    ) -> Double {
        let base: Double
        switch dayContext.focusState {
        case .deepWork:
            switch artifact.domain {
            case .continuity: base = 0.16
            case .writingExpression: base = 0.08
            case .research: base = 0.14
            case .focus: base = 0.12
            case .social: base = 0.05
            case .health: base = 0.06
            case .decisions: base = 0.08
            case .lifeAdmin: base = 0.04
            }
        case .idleReturn:
            switch artifact.domain {
            case .continuity: base = 0.94
            case .writingExpression: base = 0.42
            case .research: base = 0.48
            case .focus: base = 0.32
            case .social: base = 0.18
            case .health: base = 0.26
            case .decisions: base = 0.62
            case .lifeAdmin: base = 0.54
            }
        case .transition:
            switch artifact.domain {
            case .continuity: base = 0.84
            case .writingExpression: base = 0.52
            case .research: base = 0.48
            case .focus: base = 0.60
            case .social: base = 0.28
            case .health: base = 0.40
            case .decisions: base = 0.74
            case .lifeAdmin: base = 0.70
            }
        case .fragmented:
            switch artifact.domain {
            case .continuity: base = 0.64
            case .writingExpression: base = 0.24
            case .research: base = 0.22
            case .focus: base = 0.96
            case .social: base = 0.12
            case .health: base = 0.58
            case .decisions: base = 0.40
            case .lifeAdmin: base = 0.30
            }
        case .browsing:
            switch artifact.domain {
            case .continuity: base = 0.56
            case .writingExpression: base = 0.70
            case .research: base = 0.76
            case .focus: base = 0.22
            case .social: base = 0.46
            case .health: base = 0.34
            case .decisions: base = 0.50
            case .lifeAdmin: base = 0.46
            }
        }

        let adjusted = base + triggerAffinity(for: artifact, dayContext: dayContext)
        return min(1.0, max(0.05, adjusted))
    }

    func domainSlotBudgetMultiplier(
        for domain: AdvisoryDomain,
        dayContext: AdvisoryDayContext
    ) -> Double {
        switch dayContext.focusState {
        case .deepWork:
            switch domain {
            case .continuity: return 0.20
            case .research: return 0.15
            case .focus: return 0.12
            default: return 0.05
            }
        case .idleReturn:
            switch domain {
            case .continuity: return 1.35
            case .decisions: return 1.00
            case .lifeAdmin: return 0.90
            case .research: return 0.75
            case .writingExpression: return 0.55
            case .focus: return 0.45
            case .health: return 0.40
            case .social: return 0.25
            }
        case .transition:
            switch domain {
            case .continuity: return 1.20
            case .decisions: return 1.15
            case .lifeAdmin: return 1.05
            case .focus: return 0.95
            case .writingExpression: return 0.70
            case .research: return 0.65
            case .health: return 0.55
            case .social: return 0.35
            }
        case .fragmented:
            switch domain {
            case .focus: return 1.45
            case .continuity: return 0.95
            case .health: return 0.80
            case .decisions: return 0.70
            case .lifeAdmin: return 0.55
            case .writingExpression: return 0.38
            case .research: return 0.32
            case .social: return 0.18
            }
        case .browsing:
            switch domain {
            case .research: return 1.00
            case .writingExpression: return 0.95
            case .continuity: return 0.82
            case .decisions: return 0.75
            case .social: return 0.68
            case .lifeAdmin: return 0.62
            case .health: return 0.50
            case .focus: return 0.35
            }
        }
    }

    func adaptiveMinGapMinutes(
        for dayContext: AdvisoryDayContext,
        guidance: GuidanceProfile
    ) -> Int {
        let base = max(15, guidance.minGapMinutes)
        switch dayContext.focusState {
        case .deepWork:
            return max(90, base * 2)
        case .idleReturn:
            return max(15, Int(Double(base) * 0.55))
        case .transition:
            return max(20, Int(Double(base) * 0.65))
        case .fragmented:
            return max(25, Int(Double(base) * 0.75))
        case .browsing:
            return max(55, base)
        }
    }

    func threadCooldownPenalty(
        for artifact: AdvisoryArtifactRecord,
        recentSurfaced: [AdvisoryArtifactRecord],
        guidance: GuidanceProfile,
        dayContext: AdvisoryDayContext,
        now: Date,
        dateSupport: LocalDateSupport
    ) -> Double {
        guard let threadId = artifact.threadId else { return 0 }
        guard !dayContext.triggerKind.isUserInvoked else { return 0 }

        let windowHours = max(1, guidance.perThreadCooldownHours)
        let cutoff = now.addingTimeInterval(-Double(windowHours) * 3600)
        let recentSameThread = recentSurfaced.compactMap { surfaced -> Date? in
            guard surfaced.threadId == threadId else { return nil }
            return (surfaced.surfacedAt ?? surfaced.createdAt).flatMap(dateSupport.parseDateTime)
        }
        .filter { $0 >= cutoff }
        .sorted(by: >)

        guard let latest = recentSameThread.first else { return 0 }
        let freshness = 1.0 - min(1.0, now.timeIntervalSince(latest) / Double(windowHours * 3600))
        let repeatedPressure = min(0.22, Double(max(0, recentSameThread.count - 1)) * 0.12)
        let continuityReentryEase =
            artifact.domain == .continuity
            && (dayContext.focusState == .idleReturn
                || dayContext.triggerKind == .morningResume
                || dayContext.triggerKind == .reentryAfterIdle)
        let basePenalty = continuityReentryEase ? 0.56 : 0.72
        return min(0.92, max(0, basePenalty * freshness + repeatedPressure))
    }

    func isProactivelyEligible(
        _ artifact: AdvisoryArtifactRecord,
        dayContext: AdvisoryDayContext
    ) -> Bool {
        switch dayContext.focusState {
        case .deepWork:
            return false
        case .idleReturn:
            return [.continuity, .decisions, .lifeAdmin, .research].contains(artifact.domain)
        case .transition:
            return artifact.domain != .social
        case .fragmented:
            return [.focus, .continuity, .health].contains(artifact.domain)
        case .browsing:
            return artifact.domain != .focus || artifact.kind == .patternNotice
        }
    }

    private func triggerAffinity(
        for artifact: AdvisoryArtifactRecord,
        dayContext: AdvisoryDayContext
    ) -> Double {
        switch dayContext.triggerKind {
        case .morningResume:
            switch artifact.domain {
            case .continuity: return 0.12
            case .decisions, .lifeAdmin: return 0.06
            case .social: return -0.08
            default: return 0
            }
        case .reentryAfterIdle:
            switch artifact.domain {
            case .continuity: return 0.14
            case .decisions, .lifeAdmin: return 0.08
            case .social: return -0.10
            default: return 0
            }
        case .focusBreakNatural:
            switch artifact.domain {
            case .continuity, .decisions, .lifeAdmin: return 0.10
            case .focus: return 0.08
            case .social: return -0.08
            default: return 0
            }
        case .sessionEnd:
            switch artifact.domain {
            case .focus: return 0.06
            case .research: return 0.04
            case .social: return -0.04
            default: return 0
            }
        case .endOfDay:
            switch artifact.domain {
            case .continuity, .health, .decisions: return 0.08
            default: return 0
            }
        case .weeklyReview:
            switch artifact.domain {
            case .continuity: return 0.10
            case .health: return 0.06
            case .writingExpression, .research: return 0.05
            default: return 0
            }
        case .userInvokedWrite:
            switch artifact.domain {
            case .writingExpression: return 0.16
            case .social: return 0.08
            default: return 0
            }
        case .userInvokedLost:
            switch artifact.domain {
            case .continuity: return 0.14
            case .focus: return 0.10
            case .decisions: return 0.05
            default: return 0
            }
        case .threadResurfaced:
            switch artifact.domain {
            case .continuity: return 0.10
            case .writingExpression: return 0.08
            case .research: return 0.05
            default: return 0
            }
        case .researchBurstComplete:
            switch artifact.domain {
            case .research: return 0.14
            case .writingExpression: return 0.08
            default: return 0
            }
        }
    }
}
