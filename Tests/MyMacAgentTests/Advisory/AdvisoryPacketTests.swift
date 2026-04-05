import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryPacketTests {
    @Test("AdvisoryPacket round-trips reflection thread and weekly payloads")
    func advisoryPacketRoundTrip() throws {
        let reflection = AdvisoryPacket.reflection(
            ReflectionPacket(
                packetId: "packet-reflection",
                packetVersion: "v2.reflection.1",
                kind: .reflection,
                triggerKind: .sessionEnd,
                timeWindow: ReflectionPacketTimeWindow(
                    localDate: "2026-04-04",
                    start: "2026-04-04T08:00:00Z",
                    end: "2026-04-04T09:00:00Z"
                ),
                activeEntities: ["Memograph"],
                candidateThreadRefs: [],
                salientSessions: [],
                candidateContinuityItems: [],
                attentionSignals: [],
                constraints: makeConstraints(),
                language: "ru",
                evidenceRefs: ["summary:2026-04-04"],
                confidenceHints: [:],
                accessLevelGranted: .balanced,
                allowedTools: [],
                providerConstraints: [],
                enrichment: ReflectionPacketEnrichment(phase: .phase1Memograph, bundles: [])
            )
        )
        let thread = AdvisoryPacket.thread(
            ThreadPacket(
                packetId: "packet-thread",
                packetVersion: "v2.thread.1",
                kind: .thread,
                triggerKind: .userInvokedWrite,
                timeWindow: ReflectionPacketTimeWindow(
                    localDate: "2026-04-04",
                    start: "2026-04-04T10:00:00Z",
                    end: "2026-04-04T11:00:00Z"
                ),
                thread: ReflectionThreadRef(
                    id: "thread-1",
                    title: "Thread packet",
                    kind: .project,
                    status: .active,
                    confidence: 0.8,
                    lastActiveAt: nil,
                    parentThreadId: nil,
                    totalActiveMinutes: 90,
                    importanceScore: 0.7,
                    summary: nil
                ),
                recentEvidence: [],
                linkedItems: [],
                continuityState: ThreadPacketContinuityState(
                    openItemCount: 1,
                    parkedItemCount: 0,
                    resolvedItemCount: 0,
                    suggestedEntryPoint: "Return here",
                    latestArtifactTitle: nil
                ),
                attentionSignals: [],
                constraints: makeConstraints(),
                language: "ru",
                evidenceRefs: ["thread:thread-1"],
                confidenceHints: [:],
                accessLevelGranted: .balanced,
                allowedTools: [],
                providerConstraints: [],
                enrichment: ReflectionPacketEnrichment(phase: .phase1Memograph, bundles: [])
            )
        )
        let weekly = AdvisoryPacket.weekly(
            WeeklyPacket(
                packetId: "packet-weekly",
                packetVersion: "v2.weekly.1",
                kind: .weekly,
                triggerKind: .weeklyReview,
                timeWindow: ReflectionPacketTimeWindow(
                    localDate: "2026-03-30",
                    start: "2026-03-30T00:00:00Z",
                    end: "2026-04-05T23:59:59Z"
                ),
                threadRollup: [],
                patterns: [],
                continuityItems: [],
                attentionSignals: [],
                constraints: makeConstraints(),
                language: "ru",
                evidenceRefs: ["thread:thread-1"],
                confidenceHints: [:],
                accessLevelGranted: .balanced,
                allowedTools: [],
                providerConstraints: [],
                enrichment: ReflectionPacketEnrichment(phase: .phase1Memograph, bundles: [])
            )
        )

        for packet in [reflection, thread, weekly] {
            let data = try JSONEncoder().encode(packet)
            let decoded = try JSONDecoder().decode(AdvisoryPacket.self, from: data)
            #expect(decoded == packet)
        }
    }

    private func makeConstraints() -> ReflectionPacketConstraints {
        ReflectionPacketConstraints(
            toneMode: "soft_optional",
            writingStyle: "grounded",
            allowScreenshotEscalation: false,
            allowMCPEnrichment: false,
            enrichmentPhase: .phase1Memograph,
            enabledEnrichmentSources: [.notes],
            enabledDomains: AdvisoryDomain.allCases,
            attentionMode: "ambient",
            twitterVoiceExamples: [],
            preferredAngles: ["observation"],
            avoidTopics: [],
            contentPersonaDescription: "Grounded builder voice.",
            allowProvocation: false
        )
    }
}
