import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryColdStartPolicyTests {
    @Test("Cold start phase boundaries follow explicit day bands")
    func phaseBoundaries() {
        let policy = AdvisoryColdStartPolicy()

        #expect(policy.phase(for: 1) == .bootstrap)
        #expect(policy.phase(for: 3) == .bootstrap)
        #expect(policy.phase(for: 4) == .earlyThreads)
        #expect(policy.phase(for: 7) == .earlyThreads)
        #expect(policy.phase(for: 8) == .operational)
        #expect(policy.phase(for: 27) == .operational)
        #expect(policy.phase(for: 28) == .mature)
    }

    @Test("Bootstrap allows only continuity resume and raises signal threshold")
    func bootstrapGatesRecipes() throws {
        let policy = AdvisoryColdStartPolicy()
        let context = makeDayContext(phase: .bootstrap, trigger: .userInvokedWrite)
        let continuity = try #require(AdvisoryRecipeCatalog.all.first { $0.name == "continuity_resume" })
        let writing = try #require(AdvisoryRecipeCatalog.all.first { $0.name == "writing_seed" })

        #expect(policy.allows(recipe: continuity, dayContext: context))
        #expect(!policy.allows(recipe: writing, dayContext: context))
        #expect(policy.adjustedMinimumSignal(for: continuity, dayContext: context) > continuity.minimumSignal)
        #expect(policy.adjustedMinimumSignal(for: writing, dayContext: context) == 1.0)
    }

    @Test("Early threads phase keeps a small daily budget and only narrow domain caps")
    func earlyThreadsBudgets() {
        let defaults = UserDefaults(suiteName: "cold_start_policy_early_\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults, credentialsStore: InMemoryCredentialsStore())
        let policy = AdvisoryColdStartPolicy()
        let context = makeDayContext(phase: .earlyThreads, trigger: .sessionEnd)

        #expect(policy.effectiveDailyBudget(guidance: settings.guidanceProfile, dayContext: context) == 2)
        #expect(policy.domainBudgetCap(for: .continuity, dayContext: context) == 1.0)
        #expect(policy.domainBudgetCap(for: .research, dayContext: context) == 0.5)
        #expect(policy.domainBudgetCap(for: .focus, dayContext: context) == 0.5)
        #expect(policy.domainBudgetCap(for: .social, dayContext: context) == 0)
        #expect(policy.domainBudgetCap(for: .health, dayContext: context) == 0)
    }

    @Test("Operational phase still suppresses rich social-health domains until mature")
    func operationalVsMatureDomainRamp() throws {
        let policy = AdvisoryColdStartPolicy()
        let operational = makeDayContext(phase: .operational, trigger: .sessionEnd)
        let mature = makeDayContext(phase: .mature, trigger: .sessionEnd)
        let threadMaintenance = try #require(AdvisoryRecipeCatalog.all.first { $0.name == "thread_maintenance" })

        #expect(!policy.allows(recipe: threadMaintenance, dayContext: operational))
        #expect(policy.allows(recipe: threadMaintenance, dayContext: mature))
        #expect(policy.domainBudgetCap(for: .social, dayContext: operational) == 0)
        #expect(policy.domainBudgetCap(for: .health, dayContext: operational) == 0)
        #expect(policy.domainBudgetCap(for: .social, dayContext: mature) == nil)
        #expect(policy.domainBudgetCap(for: .health, dayContext: mature) == nil)
    }

    @Test("Bootstrap thread filtering is stricter but still keeps one fallback thread")
    func bootstrapThreadFiltering() {
        let policy = AdvisoryColdStartPolicy()
        let weakThreads = [
            makeThreadRecord(id: "thread-1", title: "Loose idea", confidence: 0.31, totalActiveMinutes: 8, importanceScore: 0.28),
            makeThreadRecord(id: "thread-2", title: "Another weak idea", confidence: 0.27, totalActiveMinutes: 6, importanceScore: 0.22)
        ]
        let strongThreads = [
            makeThreadRecord(id: "thread-3", title: "Pinned thread", confidence: 0.34, totalActiveMinutes: 5, importanceScore: 0.18, userPinned: true),
            makeThreadRecord(id: "thread-4", title: "Real project", confidence: 0.76, totalActiveMinutes: 42, importanceScore: 0.74)
        ]

        let weakFiltered = policy.filteredThreadsForPacket(weakThreads, phase: .bootstrap)
        let strongFiltered = policy.filteredThreadsForPacket(strongThreads, phase: .bootstrap)

        #expect(weakFiltered.count == 1)
        #expect(weakFiltered.first?.id == "thread-1")
        #expect(strongFiltered.count == 2)
        #expect(strongFiltered.map(\.id) == ["thread-3", "thread-4"])
    }
}

private func makeDayContext(
    phase: AdvisoryColdStartPhase,
    trigger: AdvisoryTriggerKind
) -> AdvisoryDayContext {
    AdvisoryDayContext(
        localDate: "2026-04-04",
        triggerKind: trigger,
        activeThreadCount: 2,
        openContinuityCount: 2,
        focusState: .transition,
        systemAgeDays: 5,
        coldStartPhase: phase,
        signalWeights: [
            "continuity_pressure": 0.74,
            "thread_density": 0.62,
            "research_pull": 0.58,
            "focus_turbulence": 0.49,
            "social_pull": 0.55,
            "health_pressure": 0.51
        ]
    )
}

private func makeThreadRecord(
    id: String,
    title: String,
    confidence: Double,
    totalActiveMinutes: Int,
    importanceScore: Double,
    userPinned: Bool = false,
    status: AdvisoryThreadStatus = .active
) -> AdvisoryThreadRecord {
    AdvisoryThreadRecord(row: [
        "id": .text(id),
        "title": .text(title),
        "slug": .text(AdvisorySupport.slug(for: title)),
        "kind": .text(AdvisoryThreadKind.project.rawValue),
        "status": .text(status.rawValue),
        "confidence": .real(confidence),
        "user_pinned": .integer(userPinned ? 1 : 0),
        "total_active_minutes": .integer(Int64(totalActiveMinutes)),
        "importance_score": .real(importanceScore)
    ])!
}
