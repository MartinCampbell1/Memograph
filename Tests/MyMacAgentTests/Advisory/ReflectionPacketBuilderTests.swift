import Foundation
import Testing
@testable import MyMacAgent

struct ReflectionPacketBuilderTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let emptyEnrichment = ReflectionPacketEnrichment(phase: .phase1Memograph, bundles: [])

    @Test("Long dominant session maps to deep work")
    func longDominantSessionMapsToDeepWork() {
        let builder = ReflectionPacketBuilder(
            settings: AppSettings(defaults: UserDefaults(suiteName: "packet_builder_deep_\(UUID().uuidString)")!, credentialsStore: InMemoryCredentialsStore()),
            timeZone: utc
        )
        let sessions = [
            SessionData(
                sessionId: "sess-deep",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Memograph advisory"],
                startedAt: "2026-04-04T08:00:00Z",
                endedAt: "2026-04-04T09:45:00Z",
                durationMs: 105 * 60_000,
                uncertaintyMode: "normal",
                contextTexts: ["Implementing advisory exchange"]
            ),
            SessionData(
                sessionId: "sess-deep-2",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Tests"],
                startedAt: "2026-04-04T09:45:00Z",
                endedAt: "2026-04-04T09:55:00Z",
                durationMs: 10 * 60_000,
                uncertaintyMode: "normal",
                contextTexts: ["Reviewing tests"]
            )
        ]

        let packet = builder.build(
            triggerKind: .sessionEnd,
            window: SummaryWindowDescriptor(
                date: "2026-04-04",
                start: ISO8601DateFormatter().date(from: "2026-04-04T08:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-04-04T10:00:00Z")!
            ),
            summary: nil,
            sessions: sessions,
            threads: [],
            continuityItems: [],
            enrichment: emptyEnrichment
        )
        let context = builder.buildDayContext(
            packet: packet,
            threads: [],
            continuityItems: [],
            sessions: sessions,
            systemAgeDays: 12,
            coldStartPhase: .operational
        )

        #expect(context.focusState == .deepWork)
    }

    @Test("Switch-heavy short sessions map to fragmented")
    func switchHeavySessionsMapToFragmented() {
        let builder = ReflectionPacketBuilder(
            settings: AppSettings(defaults: UserDefaults(suiteName: "packet_builder_fragmented_\(UUID().uuidString)")!, credentialsStore: InMemoryCredentialsStore()),
            timeZone: utc
        )
        let sessions = [
            SessionData(sessionId: "sess-1", appName: "Safari", bundleId: "com.apple.Safari", windowTitles: ["Docs"], startedAt: "2026-04-04T08:00:00Z", endedAt: "2026-04-04T08:08:00Z", durationMs: 8 * 60_000, uncertaintyMode: "normal", contextTexts: ["docs"]),
            SessionData(sessionId: "sess-2", appName: "Telegram", bundleId: "ru.keepcoder.Telegram", windowTitles: ["Chat"], startedAt: "2026-04-04T08:08:00Z", endedAt: "2026-04-04T08:14:00Z", durationMs: 6 * 60_000, uncertaintyMode: "normal", contextTexts: ["messages"]),
            SessionData(sessionId: "sess-3", appName: "Finder", bundleId: "com.apple.finder", windowTitles: ["Files"], startedAt: "2026-04-04T08:14:00Z", endedAt: "2026-04-04T08:20:00Z", durationMs: 6 * 60_000, uncertaintyMode: "degraded", contextTexts: ["files"]),
            SessionData(sessionId: "sess-4", appName: "Codex", bundleId: "com.openai.codex", windowTitles: ["Repo"], startedAt: "2026-04-04T08:20:00Z", endedAt: "2026-04-04T08:28:00Z", durationMs: 8 * 60_000, uncertaintyMode: "normal", contextTexts: ["repo"]),
            SessionData(sessionId: "sess-5", appName: "Safari", bundleId: "com.apple.Safari", windowTitles: ["Issue"], startedAt: "2026-04-04T08:28:00Z", endedAt: "2026-04-04T08:35:00Z", durationMs: 7 * 60_000, uncertaintyMode: "degraded", contextTexts: ["issue"]),
            SessionData(sessionId: "sess-6", appName: "Mail", bundleId: "com.apple.mail", windowTitles: ["Inbox"], startedAt: "2026-04-04T08:35:00Z", endedAt: "2026-04-04T08:41:00Z", durationMs: 6 * 60_000, uncertaintyMode: "normal", contextTexts: ["mail"])
        ]

        let packet = builder.build(
            triggerKind: .sessionEnd,
            window: SummaryWindowDescriptor(
                date: "2026-04-04",
                start: ISO8601DateFormatter().date(from: "2026-04-04T08:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-04-04T08:45:00Z")!
            ),
            summary: nil,
            sessions: sessions,
            threads: [],
            continuityItems: [],
            enrichment: emptyEnrichment
        )
        let context = builder.buildDayContext(
            packet: packet,
            threads: [],
            continuityItems: [],
            sessions: sessions,
            systemAgeDays: 12,
            coldStartPhase: .operational
        )

        #expect(context.focusState == .fragmented)
    }

    @Test("Natural focus break stays in transition")
    func focusBreakNaturalMapsToTransition() {
        let builder = ReflectionPacketBuilder(
            settings: AppSettings(defaults: UserDefaults(suiteName: "packet_builder_transition_\(UUID().uuidString)")!, credentialsStore: InMemoryCredentialsStore()),
            timeZone: utc
        )
        let sessions = [
            SessionData(
                sessionId: "sess-break",
                appName: "Codex",
                bundleId: "com.openai.codex",
                windowTitles: ["Refactor"],
                startedAt: "2026-04-04T10:00:00Z",
                endedAt: "2026-04-04T10:40:00Z",
                durationMs: 40 * 60_000,
                uncertaintyMode: "normal",
                contextTexts: ["Refactor in progress"]
            )
        ]

        let packet = builder.build(
            triggerKind: .focusBreakNatural,
            window: SummaryWindowDescriptor(
                date: "2026-04-04",
                start: ISO8601DateFormatter().date(from: "2026-04-04T10:00:00Z")!,
                end: ISO8601DateFormatter().date(from: "2026-04-04T10:45:00Z")!
            ),
            summary: nil,
            sessions: sessions,
            threads: [],
            continuityItems: [],
            enrichment: emptyEnrichment
        )
        let context = builder.buildDayContext(
            packet: packet,
            threads: [],
            continuityItems: [],
            sessions: sessions,
            systemAgeDays: 12,
            coldStartPhase: .operational
        )

        #expect(context.focusState == .transition)
    }
}
