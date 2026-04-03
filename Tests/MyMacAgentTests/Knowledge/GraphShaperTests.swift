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

    @Test("Suppresses helper tools and misclassified lesson-like models")
    func suppressesHelperToolsAndNoisyModels() {
        let shaper = GraphShaper()
        let metrics = [
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "tool-1",
                    canonicalName: "UserNotificationCenter",
                    slug: "usernotificationcenter",
                    entityType: .tool,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 5
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "tool-2",
                    canonicalName: "Safari",
                    slug: "safari",
                    entityType: .tool,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 2
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "model-1",
                    canonicalName: "Gemini 3 Flash Preview Benchmarks",
                    slug: "gemini-3-flash-preview-benchmarks",
                    entityType: .model,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 3
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "model-2",
                    canonicalName: "Gemini 3 Flash Preview",
                    slug: "gemini-3-flash-preview",
                    entityType: .model,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 3
            )
        ]

        let ids = shaper.materializedEntityIds(from: metrics)

        #expect(!ids.contains("tool-1"))
        #expect(ids.contains("tool-2"))
        #expect(!ids.contains("model-1"))
        #expect(ids.contains("model-2"))
    }

    @Test("Suppresses versioned tool variants and generic lessons when a stronger sibling exists")
    func suppressesVersionedToolsAndGenericLessons() {
        let shaper = GraphShaper()
        let metrics = [
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "tool-1",
                    canonicalName: "Claude Code",
                    slug: "claude-code",
                    entityType: .tool,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 2
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "tool-2",
                    canonicalName: "Claude Code v2.1.90",
                    slug: "claude-code-v2-1-90",
                    entityType: .tool,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 2
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "lesson-1",
                    canonicalName: "VRAM requirements",
                    slug: "vram-requirements",
                    entityType: .lesson,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "lesson-2",
                    canonicalName: "VRAM Requirements for Agentic AI",
                    slug: "vram-requirements-for-agentic-ai",
                    entityType: .lesson,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 2
            )
        ]

        let ids = shaper.materializedEntityIds(from: metrics)

        #expect(ids.contains("tool-1"))
        #expect(!ids.contains("tool-2"))
        #expect(!ids.contains("lesson-1"))
        #expect(ids.contains("lesson-2"))
    }

    @Test("Auto-demotes broad generic lessons connected to too many projects")
    func autoDemotesBroadGenericLessons() {
        let shaper = GraphShaper()
        let metrics = [
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "lesson-1",
                    canonicalName: "LM Studio Local Inference Setup",
                    slug: "lm-studio-local-inference-setup",
                    entityType: .lesson,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1,
                typedEdgeCount: 3,
                coOccurrenceEdgeCount: 4,
                projectRelationCount: 3
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "lesson-2",
                    canonicalName: "macOS System Audio Capture Guide",
                    slug: "macos-system-audio-capture-guide",
                    entityType: .lesson,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 3,
                typedEdgeCount: 3,
                coOccurrenceEdgeCount: 2,
                projectRelationCount: 2
            )
        ]

        let ids = shaper.materializedEntityIds(from: metrics)

        #expect(!ids.contains("lesson-1"))
        #expect(ids.contains("lesson-2"))
    }

    @Test("Materializes durable one-off topics while suppressing topic artifacts")
    func materializesDurableTopicsAndSuppressesArtifacts() {
        let shaper = GraphShaper()
        let metrics = [
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-1",
                    canonicalName: "Accessibility Permissions",
                    slug: "accessibility-permissions",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-2",
                    canonicalName: "System Audio Capture",
                    slug: "system-audio-capture",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-3",
                    canonicalName: "FounderOS_Knowledge_Base_Amendment.md",
                    slug: "founderos-knowledge-base-amendment-md",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-4",
                    canonicalName: "Screenpipe vs Screencap",
                    slug: "screenpipe-vs-screencap",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1
            )
        ]

        let ids = shaper.materializedEntityIds(from: metrics)

        #expect(ids.contains("topic-1"))
        #expect(ids.contains("topic-2"))
        #expect(!ids.contains("topic-3"))
        #expect(!ids.contains("topic-4"))
    }

    @Test("Suppresses weak non-durable topics dominated by co-occurrence noise")
    func suppressesWeakTopicsDominatedByCoOccurrence() {
        let shaper = GraphShaper()
        let metrics = [
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-1",
                    canonicalName: "Apple Notes",
                    slug: "apple-notes",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 2,
                typedEdgeCount: 0,
                coOccurrenceEdgeCount: 18
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-2",
                    canonicalName: "System Audio Capture",
                    slug: "system-audio-capture",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1,
                typedEdgeCount: 1,
                coOccurrenceEdgeCount: 25
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-3",
                    canonicalName: "Local LLM",
                    slug: "local-llm",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 3,
                typedEdgeCount: 2,
                coOccurrenceEdgeCount: 14
            )
        ]

        let ids = shaper.materializedEntityIds(from: metrics)

        #expect(!ids.contains("topic-1"))
        #expect(ids.contains("topic-2"))
        #expect(ids.contains("topic-3"))
    }

    @Test("Keeps durable topics even when a more specific lesson exists")
    func keepsDurableTopicsAlongsideLessons() {
        let shaper = GraphShaper()
        let metrics = [
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "topic-1",
                    canonicalName: "Screen Recording",
                    slug: "screen-recording",
                    entityType: .topic,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 1
            ),
            KnowledgeEntityMetrics(
                entity: KnowledgeEntityRecord(
                    id: "lesson-1",
                    canonicalName: "macOS Screen Recording Permissions Guide",
                    slug: "macos-screen-recording-permissions-guide",
                    entityType: .lesson,
                    aliasesJson: nil,
                    firstSeenAt: nil,
                    lastSeenAt: nil
                ),
                claimCount: 2
            )
        ]

        let ids = shaper.materializedEntityIds(from: metrics)

        #expect(ids.contains("topic-1"))
        #expect(ids.contains("lesson-1"))
    }
}
