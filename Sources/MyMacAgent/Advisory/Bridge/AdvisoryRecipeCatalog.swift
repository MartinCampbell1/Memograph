import Foundation

struct AdvisoryRecipeSpec: Equatable {
    let name: String
    let domain: AdvisoryDomain
    let minimumSignal: Double
    let userInvokedBonus: Bool
}

struct AdvisoryManualRecipeSpec: Equatable, Identifiable {
    let domain: AdvisoryDomain
    let recipeName: String
    let title: String
    let summary: String
    let triggerKind: AdvisoryTriggerKind

    var id: String { domain.rawValue }
}

enum AdvisoryRecipeCatalog {
    static let v1Core: [AdvisoryRecipeSpec] = [
        AdvisoryRecipeSpec(name: "continuity_resume", domain: .continuity, minimumSignal: 0.22, userInvokedBonus: true),
        AdvisoryRecipeSpec(name: "tweet_from_thread", domain: .writingExpression, minimumSignal: 0.28, userInvokedBonus: true),
        AdvisoryRecipeSpec(name: "weekly_reflection", domain: .continuity, minimumSignal: 0.3, userInvokedBonus: true)
    ]

    static let extended: [AdvisoryRecipeSpec] = [
        AdvisoryRecipeSpec(name: "thread_maintenance", domain: .continuity, minimumSignal: 0.3, userInvokedBonus: true),
        AdvisoryRecipeSpec(name: "writing_seed", domain: .writingExpression, minimumSignal: 0.34, userInvokedBonus: true),
        AdvisoryRecipeSpec(name: "research_direction", domain: .research, minimumSignal: 0.32, userInvokedBonus: false),
        AdvisoryRecipeSpec(name: "focus_reflection", domain: .focus, minimumSignal: 0.36, userInvokedBonus: true),
        AdvisoryRecipeSpec(name: "social_signal", domain: .social, minimumSignal: 0.42, userInvokedBonus: true),
        AdvisoryRecipeSpec(name: "health_pulse", domain: .health, minimumSignal: 0.48, userInvokedBonus: false),
        AdvisoryRecipeSpec(name: "decision_review", domain: .decisions, minimumSignal: 0.28, userInvokedBonus: true),
        AdvisoryRecipeSpec(name: "life_admin_review", domain: .lifeAdmin, minimumSignal: 0.24, userInvokedBonus: true)
    ]

    static let all: [AdvisoryRecipeSpec] = v1Core + extended

    static let v1Domains: Set<AdvisoryDomain> = Set(v1Core.map(\.domain))

    static let manualDomainActions: [AdvisoryManualRecipeSpec] = [
        AdvisoryManualRecipeSpec(
            domain: .writingExpression,
            recipeName: "writing_seed",
            title: "Writing Seed",
            summary: "Поднять один grounded writing angle из текущего дня.",
            triggerKind: .userInvokedWrite
        ),
        AdvisoryManualRecipeSpec(
            domain: .research,
            recipeName: "research_direction",
            title: "Research Direction",
            summary: "Сузить вопрос и собрать один исследовательский next step.",
            triggerKind: .userInvokedWrite
        ),
        AdvisoryManualRecipeSpec(
            domain: .focus,
            recipeName: "focus_reflection",
            title: "Focus Check",
            summary: "Поймать re-entry cost, fragmentation и мягкий next move.",
            triggerKind: .userInvokedWrite
        ),
        AdvisoryManualRecipeSpec(
            domain: .social,
            recipeName: "social_signal",
            title: "Social Nudge",
            summary: "Посмотреть, есть ли из сегодняшнего материала живой social signal.",
            triggerKind: .userInvokedWrite
        ),
        AdvisoryManualRecipeSpec(
            domain: .health,
            recipeName: "health_pulse",
            title: "Health Pulse",
            summary: "Сделать мягкую проверку ритма дня без коучинга и диагноза.",
            triggerKind: .userInvokedWrite
        ),
        AdvisoryManualRecipeSpec(
            domain: .decisions,
            recipeName: "decision_review",
            title: "Decision Review",
            summary: "Проверить, не осталось ли развилок, которые лучше назвать явно.",
            triggerKind: .userInvokedWrite
        ),
        AdvisoryManualRecipeSpec(
            domain: .lifeAdmin,
            recipeName: "life_admin_review",
            title: "Life Admin",
            summary: "Поднять один тихий admin хвост, который продолжает есть внимание.",
            triggerKind: .userInvokedWrite
        )
    ]

    static let v1ManualDomainActions: [AdvisoryManualRecipeSpec] =
        manualDomainActions.filter { v1Domains.contains($0.domain) }

    static func spec(named name: String) -> AdvisoryRecipeSpec? {
        all.first(where: { $0.name == name })
    }

    static func manualAction(for domain: AdvisoryDomain) -> AdvisoryManualRecipeSpec? {
        manualDomainActions.first(where: { $0.domain == domain })
    }
}
