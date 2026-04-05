import Foundation

protocol AdvisoryPacketPayload: Encodable {
    var packetId: String { get }
    var packetVersion: String { get }
    var kind: AdvisoryPacketKind { get }
    var triggerKind: AdvisoryTriggerKind { get }
    var language: String { get }
    var accessLevelGranted: AdvisoryAccessProfile { get }
    var windowStartedAt: String? { get }
    var windowEndedAt: String? { get }
}

struct ReflectionPacketTimeWindow: Codable, Equatable {
    let localDate: String
    let start: String
    let end: String
}

struct ReflectionThreadRef: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let kind: AdvisoryThreadKind
    let status: AdvisoryThreadStatus
    let confidence: Double
    let lastActiveAt: String?
    let parentThreadId: String?
    let totalActiveMinutes: Int
    let importanceScore: Double
    let summary: String?
}

struct ReflectionSalientSession: Codable, Equatable, Identifiable {
    let id: String
    let appName: String
    let startedAt: String
    let endedAt: String?
    let durationMinutes: Int
    let windowTitle: String?
    let evidenceSnippet: String?
}

struct ReflectionContinuityItemRef: Codable, Equatable, Identifiable {
    let id: String
    let threadId: String?
    let kind: ContinuityItemKind
    let title: String
    let body: String?
    let confidence: Double
}

struct ReflectionAttentionSignal: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let score: Double
    let note: String
}

struct ReflectionEnrichmentItem: Codable, Equatable, Identifiable {
    let id: String
    let source: AdvisoryEnrichmentSource
    let title: String
    let snippet: String
    let relevance: Double
    let evidenceRefs: [String]
    let sourceRef: String?
}

struct ReflectionEnrichmentBundle: Codable, Equatable, Identifiable {
    let id: String
    let source: AdvisoryEnrichmentSource
    let tier: AdvisoryEvidenceTier
    let availability: AdvisoryEnrichmentAvailability
    let runtimeKind: AdvisoryEnrichmentRuntimeKind
    let providerLabel: String
    let isFallback: Bool
    let note: String
    let items: [ReflectionEnrichmentItem]

    init(
        id: String,
        source: AdvisoryEnrichmentSource,
        tier: AdvisoryEvidenceTier,
        availability: AdvisoryEnrichmentAvailability,
        runtimeKind: AdvisoryEnrichmentRuntimeKind = .stagedPlaceholder,
        providerLabel: String? = nil,
        isFallback: Bool = false,
        note: String,
        items: [ReflectionEnrichmentItem]
    ) {
        self.id = id
        self.source = source
        self.tier = tier
        self.availability = availability
        self.runtimeKind = runtimeKind
        self.providerLabel = providerLabel ?? source.label
        self.isFallback = isFallback
        self.note = note
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case tier
        case availability
        case runtimeKind
        case providerLabel
        case isFallback
        case note
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        source = try container.decode(AdvisoryEnrichmentSource.self, forKey: .source)
        tier = try container.decode(AdvisoryEvidenceTier.self, forKey: .tier)
        availability = try container.decode(AdvisoryEnrichmentAvailability.self, forKey: .availability)
        runtimeKind = try container.decodeIfPresent(AdvisoryEnrichmentRuntimeKind.self, forKey: .runtimeKind)
            ?? (source == .notes ? .memographDerived : .stagedPlaceholder)
        providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel) ?? source.label
        isFallback = try container.decodeIfPresent(Bool.self, forKey: .isFallback) ?? false
        note = try container.decode(String.self, forKey: .note)
        items = try container.decodeIfPresent([ReflectionEnrichmentItem].self, forKey: .items) ?? []
    }
}

struct ReflectionPacketEnrichment: Codable, Equatable {
    let phase: AdvisoryEnrichmentPhase
    let bundles: [ReflectionEnrichmentBundle]
}

struct ReflectionPacketConstraints: Codable, Equatable {
    let toneMode: String
    let writingStyle: String
    let allowScreenshotEscalation: Bool
    let allowMCPEnrichment: Bool
    let enrichmentPhase: AdvisoryEnrichmentPhase
    let enabledEnrichmentSources: [AdvisoryEnrichmentSource]
    let enabledDomains: [AdvisoryDomain]
    let attentionMode: String
    let twitterVoiceExamples: [String]
    let preferredAngles: [String]
    let avoidTopics: [String]
    let contentPersonaDescription: String
    let allowProvocation: Bool
}

struct ReflectionPacket: Codable, Equatable {
    let packetId: String
    let packetVersion: String
    let kind: AdvisoryPacketKind
    let triggerKind: AdvisoryTriggerKind
    let timeWindow: ReflectionPacketTimeWindow
    let activeEntities: [String]
    let candidateThreadRefs: [ReflectionThreadRef]
    let salientSessions: [ReflectionSalientSession]
    let candidateContinuityItems: [ReflectionContinuityItemRef]
    let attentionSignals: [ReflectionAttentionSignal]
    let constraints: ReflectionPacketConstraints
    let language: String
    let evidenceRefs: [String]
    let confidenceHints: [String: Double]
    let accessLevelGranted: AdvisoryAccessProfile
    let allowedTools: [String]
    let providerConstraints: [String]
    let enrichment: ReflectionPacketEnrichment
}

extension ReflectionPacket: AdvisoryPacketPayload {
    var windowStartedAt: String? { timeWindow.start }
    var windowEndedAt: String? { timeWindow.end }
}

struct ThreadPacketEvidence: Codable, Equatable, Identifiable {
    let id: String
    let evidenceKind: String
    let evidenceRef: String
    let snippet: String?
    let weight: Double
}

struct ThreadPacketContinuityState: Codable, Equatable {
    let openItemCount: Int
    let parkedItemCount: Int
    let resolvedItemCount: Int
    let suggestedEntryPoint: String?
    let latestArtifactTitle: String?
}

struct ThreadPacket: Codable, Equatable {
    let packetId: String
    let packetVersion: String
    let kind: AdvisoryPacketKind
    let triggerKind: AdvisoryTriggerKind
    let timeWindow: ReflectionPacketTimeWindow
    let thread: ReflectionThreadRef
    let recentEvidence: [ThreadPacketEvidence]
    let linkedItems: [ReflectionContinuityItemRef]
    let continuityState: ThreadPacketContinuityState
    let attentionSignals: [ReflectionAttentionSignal]
    let constraints: ReflectionPacketConstraints
    let language: String
    let evidenceRefs: [String]
    let confidenceHints: [String: Double]
    let accessLevelGranted: AdvisoryAccessProfile
    let allowedTools: [String]
    let providerConstraints: [String]
    let enrichment: ReflectionPacketEnrichment
}

extension ThreadPacket: AdvisoryPacketPayload {
    var windowStartedAt: String? { timeWindow.start }
    var windowEndedAt: String? { timeWindow.end }
}

struct WeeklyThreadRollup: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let status: AdvisoryThreadStatus
    let importanceScore: Double
    let totalActiveMinutes: Int
    let summary: String?
    let openItemCount: Int
    let artifactCount: Int
}

struct WeeklyPattern: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let confidence: Double
}

struct WeeklyPacket: Codable, Equatable {
    let packetId: String
    let packetVersion: String
    let kind: AdvisoryPacketKind
    let triggerKind: AdvisoryTriggerKind
    let timeWindow: ReflectionPacketTimeWindow
    let threadRollup: [WeeklyThreadRollup]
    let patterns: [WeeklyPattern]
    let continuityItems: [ReflectionContinuityItemRef]
    let attentionSignals: [ReflectionAttentionSignal]
    let constraints: ReflectionPacketConstraints
    let language: String
    let evidenceRefs: [String]
    let confidenceHints: [String: Double]
    let accessLevelGranted: AdvisoryAccessProfile
    let allowedTools: [String]
    let providerConstraints: [String]
    let enrichment: ReflectionPacketEnrichment
}

extension WeeklyPacket: AdvisoryPacketPayload {
    var windowStartedAt: String? { timeWindow.start }
    var windowEndedAt: String? { timeWindow.end }
}

enum AdvisoryPacket: Codable, Equatable {
    case reflection(ReflectionPacket)
    case thread(ThreadPacket)
    case weekly(WeeklyPacket)

    private enum CodingKeys: String, CodingKey {
        case kind
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(AdvisoryPacketKind.self, forKey: .kind)
        switch kind {
        case .reflection:
            self = .reflection(try ReflectionPacket(from: decoder))
        case .thread:
            self = .thread(try ThreadPacket(from: decoder))
        case .weekly:
            self = .weekly(try WeeklyPacket(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .reflection(let packet):
            try packet.encode(to: encoder)
        case .thread(let packet):
            try packet.encode(to: encoder)
        case .weekly(let packet):
            try packet.encode(to: encoder)
        }
    }

    var packetId: String {
        switch self {
        case .reflection(let packet): return packet.packetId
        case .thread(let packet): return packet.packetId
        case .weekly(let packet): return packet.packetId
        }
    }

    var packetVersion: String {
        switch self {
        case .reflection(let packet): return packet.packetVersion
        case .thread(let packet): return packet.packetVersion
        case .weekly(let packet): return packet.packetVersion
        }
    }

    var kind: AdvisoryPacketKind {
        switch self {
        case .reflection(let packet): return packet.kind
        case .thread(let packet): return packet.kind
        case .weekly(let packet): return packet.kind
        }
    }

    var triggerKind: AdvisoryTriggerKind {
        switch self {
        case .reflection(let packet): return packet.triggerKind
        case .thread(let packet): return packet.triggerKind
        case .weekly(let packet): return packet.triggerKind
        }
    }

    var language: String {
        switch self {
        case .reflection(let packet): return packet.language
        case .thread(let packet): return packet.language
        case .weekly(let packet): return packet.language
        }
    }

    var accessLevelGranted: AdvisoryAccessProfile {
        switch self {
        case .reflection(let packet): return packet.accessLevelGranted
        case .thread(let packet): return packet.accessLevelGranted
        case .weekly(let packet): return packet.accessLevelGranted
        }
    }

    var windowStartedAt: String? {
        switch self {
        case .reflection(let packet): return packet.windowStartedAt
        case .thread(let packet): return packet.windowStartedAt
        case .weekly(let packet): return packet.windowStartedAt
        }
    }

    var windowEndedAt: String? {
        switch self {
        case .reflection(let packet): return packet.windowEndedAt
        case .thread(let packet): return packet.windowEndedAt
        case .weekly(let packet): return packet.windowEndedAt
        }
    }

    var evidenceRefs: [String] {
        switch self {
        case .reflection(let packet): return packet.evidenceRefs
        case .thread(let packet): return packet.evidenceRefs
        case .weekly(let packet): return packet.evidenceRefs
        }
    }

    var attentionSignals: [ReflectionAttentionSignal] {
        switch self {
        case .reflection(let packet): return packet.attentionSignals
        case .thread(let packet): return packet.attentionSignals
        case .weekly(let packet): return packet.attentionSignals
        }
    }

    var constraints: ReflectionPacketConstraints {
        switch self {
        case .reflection(let packet): return packet.constraints
        case .thread(let packet): return packet.constraints
        case .weekly(let packet): return packet.constraints
        }
    }

    var confidenceHints: [String: Double] {
        switch self {
        case .reflection(let packet): return packet.confidenceHints
        case .thread(let packet): return packet.confidenceHints
        case .weekly(let packet): return packet.confidenceHints
        }
    }

    var allowedTools: [String] {
        switch self {
        case .reflection(let packet): return packet.allowedTools
        case .thread(let packet): return packet.allowedTools
        case .weekly(let packet): return packet.allowedTools
        }
    }

    var providerConstraints: [String] {
        switch self {
        case .reflection(let packet): return packet.providerConstraints
        case .thread(let packet): return packet.providerConstraints
        case .weekly(let packet): return packet.providerConstraints
        }
    }

    var enrichment: ReflectionPacketEnrichment {
        switch self {
        case .reflection(let packet): return packet.enrichment
        case .thread(let packet): return packet.enrichment
        case .weekly(let packet): return packet.enrichment
        }
    }

    var activeEntities: [String] {
        switch self {
        case .reflection(let packet):
            return packet.activeEntities
        case .thread(let packet):
            return [packet.thread.title]
        case .weekly(let packet):
            return packet.threadRollup.map(\.title)
        }
    }

    var candidateThreadRefs: [ReflectionThreadRef] {
        switch self {
        case .reflection(let packet):
            return packet.candidateThreadRefs
        case .thread(let packet):
            return [packet.thread]
        case .weekly(let packet):
            return packet.threadRollup.map { thread in
                ReflectionThreadRef(
                    id: thread.id,
                    title: thread.title,
                    kind: .theme,
                    status: thread.status,
                    confidence: min(1.0, max(0.4, thread.importanceScore)),
                    lastActiveAt: nil,
                    parentThreadId: nil,
                    totalActiveMinutes: thread.totalActiveMinutes,
                    importanceScore: thread.importanceScore,
                    summary: thread.summary
                )
            }
        }
    }

    var candidateContinuityItems: [ReflectionContinuityItemRef] {
        switch self {
        case .reflection(let packet):
            return packet.candidateContinuityItems
        case .thread(let packet):
            return packet.linkedItems
        case .weekly(let packet):
            return packet.continuityItems
        }
    }

    var salientSessions: [ReflectionSalientSession] {
        switch self {
        case .reflection(let packet):
            return packet.salientSessions
        case .thread, .weekly:
            return []
        }
    }

    var reflection: ReflectionPacket? {
        if case .reflection(let packet) = self { return packet }
        return nil
    }

    var thread: ThreadPacket? {
        if case .thread(let packet) = self { return packet }
        return nil
    }

    var weekly: WeeklyPacket? {
        if case .weekly(let packet) = self { return packet }
        return nil
    }
}
