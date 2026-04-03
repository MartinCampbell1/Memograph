import Testing
@testable import MyMacAgent

struct GraphShaperTests {
    @Test("Suppresses generic one-off topics while keeping core durable entity types")
    func suppressesGenericOneOffTopics() {
        let shaper = GraphShaper()
        let metrics = [
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "project-1",
                    canonicalName: "Memograph",
                    slug: "memograph",
                    entityType: .project,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-1",
                    canonicalName: "AI",
                    slug: "ai",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 4
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-2",
                    canonicalName: "Claim Layer",
                    slug: "claim-layer",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 3
            )
        ]

        let ids = shaper.materializedEntityIds(from: metrics)

        #expect(ids.contains("project-1"))
        #expect(!ids.contains("topic-1"))
        #expect(!ids.contains("topic-2"))
    }

    @Test("Suppresses shorter topic when a more specific sibling exists")
    func suppressesShorterSiblingTopic() {
        let shaper = GraphShaper()
        let metrics = [
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-1",
                    canonicalName: "Flywheel",
                    slug: "flywheel",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 2
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-2",
                    canonicalName: "Flywheel Effect in Agentic AI",
                    slug: "flywheel-effect-in-agentic-ai",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 2
            )
        ]

        let ids = shaper.materializedEntityIds(from: metrics)

        #expect(!ids.contains("topic-1"))
        #expect(ids.contains("topic-2"))
    }
}
