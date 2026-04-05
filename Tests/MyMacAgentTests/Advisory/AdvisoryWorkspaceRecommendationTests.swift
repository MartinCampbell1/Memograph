import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryWorkspaceRecommendationTests {
    @Test("Deep work suppresses non-focus manual pulls")
    func deepWorkSuppressesNonFocusPulls() throws {
        let snapshot = makeSnapshot(
            focusState: .deepWork,
            overrides: [
                .research: market(
                    domain: .research,
                    queuedCount: 1,
                    demand: 0.78,
                    fatigue: 0.12,
                    remainingBudgetFactor: 0.84,
                    proactiveEligible: true,
                    leadArtifactTitle: "Research direction"
                )
            ]
        )

        let research = try #require(snapshot.manualPullRecommendations.first(where: { $0.domain == .research }))
        #expect(research.tier == .deepWorkSuppressed)
        #expect(snapshot.topManualPullRecommendation == nil)
        #expect(snapshot.advisorGuidanceLine.contains("deep work"))
    }

    @Test("Fragmented focus becomes best manual pull")
    func fragmentedFocusBecomesBestManualPull() {
        let snapshot = makeSnapshot(
            focusState: .fragmented,
            overrides: [
                .focus: market(
                    domain: .focus,
                    queuedCount: 1,
                    demand: 0.74,
                    fatigue: 0.08,
                    remainingBudgetFactor: 0.88,
                    proactiveEligible: true,
                    leadArtifactTitle: "Focus intervention"
                ),
                .research: market(
                    domain: .research,
                    queuedCount: 1,
                    demand: 0.58,
                    fatigue: 0.14,
                    remainingBudgetFactor: 0.76,
                    proactiveEligible: true,
                    leadArtifactTitle: "Research direction"
                )
            ]
        )

        #expect(snapshot.topManualPullRecommendation?.domain == .focus)
        #expect(snapshot.topManualPullRecommendation?.tier == .bestNow)
        #expect(snapshot.advisorGuidanceLine.contains("Focus"))
    }

    @Test("Transition research pull is recommended before quieter domains")
    func transitionResearchPullIsRecommended() throws {
        let snapshot = makeSnapshot(
            focusState: .transition,
            overrides: [
                .research: market(
                    domain: .research,
                    queuedCount: 1,
                    demand: 0.66,
                    fatigue: 0.1,
                    remainingBudgetFactor: 0.82,
                    proactiveEligible: true,
                    leadArtifactTitle: "Research direction"
                ),
                .lifeAdmin: market(
                    domain: .lifeAdmin,
                    queuedCount: 1,
                    demand: 0.34,
                    fatigue: 0.08,
                    remainingBudgetFactor: 0.74,
                    proactiveEligible: false,
                    leadArtifactTitle: "Life admin reminder"
                )
            ]
        )

        let research = try #require(snapshot.manualPullRecommendations.first(where: { $0.domain == .research }))
        #expect(research.tier == .bestNow)
        #expect(snapshot.topManualPullRecommendation?.domain == .research)
        #expect(snapshot.advisorGuidanceLine.contains("Research"))
    }

    @Test("High fatigue pushes a domain into cooling down")
    func highFatigueCoolsDownDomain() throws {
        let snapshot = makeSnapshot(
            focusState: .browsing,
            overrides: [
                .social: market(
                    domain: .social,
                    queuedCount: 1,
                    demand: 0.64,
                    fatigue: 0.42,
                    remainingBudgetFactor: 0.64,
                    proactiveEligible: true,
                    leadArtifactTitle: "Social nudge"
                )
            ]
        )

        let social = try #require(snapshot.manualPullRecommendations.first(where: { $0.domain == .social }))
        #expect(social.tier == .coolingDown)
    }

    private func makeSnapshot(
        focusState: AdvisoryFocusState,
        overrides: [AdvisoryDomain: AdvisoryDomainMarketSnapshot]
    ) -> AdvisoryWorkspaceSnapshot {
        let domainSnapshots = AdvisoryDomain.allCases.map { domain in
            overrides[domain] ?? market(domain: domain)
        }

        return AdvisoryWorkspaceSnapshot(
            localDate: "2026-04-05",
            focusState: focusState,
            coldStartPhase: .operational,
            attentionMode: "ambient",
            systemAgeDays: 21,
            activeThreadCount: 4,
            openContinuityCount: 3,
            surfacedCount: domainSnapshots.reduce(0) { $0 + $1.surfacedCount },
            queuedCount: domainSnapshots.reduce(0) { $0 + $1.queuedCount },
            candidateCount: domainSnapshots.reduce(0) { $0 + $1.candidateCount },
            acceptedCount: 0,
            mutedCount: 0,
            enabledEnrichmentSources: [.notes, .calendar, .reminders, .webResearch],
            domainSummaries: [],
            domainMarketSnapshots: domainSnapshots,
            enrichmentSourceStatuses: []
        )
    }

    private func market(
        domain: AdvisoryDomain,
        surfacedCount: Int = 0,
        queuedCount: Int = 0,
        candidateCount: Int = 0,
        allocationWeight: Double = 0.4,
        demand: Double = 0.0,
        fatigue: Double = 0.0,
        remainingBudgetFactor: Double = 1.0,
        proactiveEligible: Bool = false,
        leadArtifactTitle: String? = nil
    ) -> AdvisoryDomainMarketSnapshot {
        AdvisoryDomainMarketSnapshot(
            domain: domain,
            surfacedCount: surfacedCount,
            queuedCount: queuedCount,
            candidateCount: candidateCount,
            allocationWeight: allocationWeight,
            demand: demand,
            fatigue: fatigue,
            remainingBudgetFactor: remainingBudgetFactor,
            proactiveEligible: proactiveEligible,
            leadArtifactTitle: leadArtifactTitle,
            leadArtifactKind: nil
        )
    }
}
