import Foundation

enum AdvisoryAccessProfile: String, CaseIterable, Codable, Identifiable {
    case conservative
    case balanced
    case deepContext = "deep_context"
    case fullResearchMode = "full_research_mode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .deepContext: return "Deep context"
        case .fullResearchMode: return "Full research"
        }
    }
}

enum AdvisoryProactivityMode: String, CaseIterable, Codable, Identifiable {
    case manualOnly = "manual_only"
    case ambient

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manualOnly: return "Manual only"
        case .ambient: return "Ambient"
        }
    }
}

enum AdvisoryBridgeMode: String, CaseIterable, Codable, Identifiable {
    case stubOnly = "stub_only"
    case preferSidecar = "prefer_sidecar"
    case requireSidecar = "require_sidecar"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stubOnly: return "Stub only"
        case .preferSidecar: return "Prefer sidecar"
        case .requireSidecar: return "Require sidecar"
        }
    }
}

enum AdvisoryDomain: String, CaseIterable, Codable, Identifiable {
    case continuity
    case writingExpression = "writing_expression"
    case research
    case focus
    case social
    case health
    case decisions
    case lifeAdmin = "life_admin"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .continuity: return "Continuity"
        case .writingExpression: return "Writing"
        case .research: return "Research"
        case .focus: return "Focus"
        case .social: return "Social"
        case .health: return "Health"
        case .decisions: return "Decisions"
        case .lifeAdmin: return "Life Admin"
        }
    }

    var defaultBaseWeight: Double {
        switch self {
        case .continuity: return 1.0
        case .writingExpression: return 0.82
        case .research: return 0.8
        case .focus: return 0.78
        case .social: return 0.6
        case .health: return 0.58
        case .decisions: return 0.74
        case .lifeAdmin: return 0.68
        }
    }

    var defaultDailySlotBudget: Double {
        switch self {
        case .continuity: return 2.0
        case .writingExpression: return 1.0
        case .research: return 1.0
        case .focus: return 1.0
        case .social: return 0.5
        case .health: return 0.5
        case .decisions: return 1.0
        case .lifeAdmin: return 1.0
        }
    }

    var supportedArtifactKinds: [AdvisoryArtifactKind] {
        switch self {
        case .continuity:
            return [.resumeCard, .reflectionCard, .weeklyReview]
        case .writingExpression:
            return [.tweetSeed, .noteSeed, .threadSeed]
        case .research:
            return [.researchDirection, .explorationSeed]
        case .focus:
            return [.focusIntervention, .patternNotice]
        case .social:
            return [.socialNudge]
        case .health:
            return [.healthReflection]
        case .decisions:
            return [.decisionReminder, .missedSignal]
        case .lifeAdmin:
            return [.lifeAdminReminder, .decisionReminder]
        }
    }

    var suggestedEnrichmentSources: [AdvisoryEnrichmentSource] {
        switch self {
        case .continuity:
            return [.notes, .calendar, .reminders]
        case .writingExpression:
            return [.notes, .webResearch, .calendar, .reminders]
        case .research:
            return [.notes, .webResearch, .calendar, .reminders]
        case .focus:
            return [.wearable, .calendar, .reminders]
        case .social:
            return [.calendar, .reminders, .wearable]
        case .health:
            return [.wearable, .calendar, .reminders]
        case .decisions:
            return [.reminders, .calendar, .webResearch]
        case .lifeAdmin:
            return [.reminders, .calendar]
        }
    }
}

enum AdvisoryThreadKind: String, CaseIterable, Codable {
    case project
    case question
    case interest
    case person
    case commitment
    case theme
}

enum AdvisoryThreadStatus: String, CaseIterable, Codable {
    case active
    case stalled
    case parked
    case resolved
}

enum ContinuityItemKind: String, CaseIterable, Codable {
    case openLoop = "open_loop"
    case decision
    case question
    case commitment
    case blockedItem = "blocked_item"
}

enum ContinuityItemStatus: String, CaseIterable, Codable {
    case open
    case stabilizing
    case parked
    case resolved
}

enum AdvisoryArtifactKind: String, CaseIterable, Codable {
    case resumeCard = "resume_card"
    case reflectionCard = "reflection_card"
    case tweetSeed = "tweet_seed"
    case threadSeed = "thread_seed"
    case noteSeed = "note_seed"
    case researchDirection = "research_direction"
    case patternNotice = "pattern_notice"
    case weeklyReview = "weekly_review"
    case socialNudge = "social_nudge"
    case healthReflection = "health_reflection"
    case lifeAdminReminder = "life_admin_reminder"
    case focusIntervention = "focus_intervention"
    case decisionReminder = "decision_reminder"
    case explorationSeed = "exploration_seed"
    case missedSignal = "missed_signal"
}

enum AdvisoryWritingAngle: String, CaseIterable, Codable, Identifiable {
    case observation
    case contrarianTake = "contrarian_take"
    case question
    case miniFramework = "mini_framework"
    case lessonLearned = "lesson_learned"
    case provocation

    var id: String { rawValue }

    var label: String {
        switch self {
        case .observation: return "Observation"
        case .contrarianTake: return "Contrarian Take"
        case .question: return "Question"
        case .miniFramework: return "Mini Framework"
        case .lessonLearned: return "Lesson Learned"
        case .provocation: return "Provocation"
        }
    }

    static func normalizedList(
        from rawValues: [String],
        allowProvocation: Bool
    ) -> [AdvisoryWritingAngle] {
        var values = AdvisorySupport.dedupe(
            rawValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        ).compactMap(Self.init(rawValue:))
        if !allowProvocation {
            values.removeAll { $0 == .provocation }
        }
        if values.isEmpty {
            values = [.observation, .question, .lessonLearned, .miniFramework]
        }
        if allowProvocation, !values.contains(.provocation) {
            values.append(.provocation)
        }
        return values
    }
}

struct AdvisoryWritingArtifactMetadata: Codable, Equatable {
    let primaryAngle: AdvisoryWritingAngle
    let alternativeAngles: [AdvisoryWritingAngle]
    let evidencePack: [String]
    let voiceExamples: [String]
    let avoidTopics: [String]
    let personaDescription: String
    let suggestedOpenings: [String]
    let continuityAnchor: String?
    let sourceAnchors: [String]
    let enrichmentSources: [AdvisoryEnrichmentSource]
    let timingWindow: String?

    init(
        primaryAngle: AdvisoryWritingAngle,
        alternativeAngles: [AdvisoryWritingAngle],
        evidencePack: [String],
        voiceExamples: [String],
        avoidTopics: [String],
        personaDescription: String,
        suggestedOpenings: [String],
        continuityAnchor: String?,
        sourceAnchors: [String] = [],
        enrichmentSources: [AdvisoryEnrichmentSource] = [],
        timingWindow: String? = nil
    ) {
        self.primaryAngle = primaryAngle
        self.alternativeAngles = alternativeAngles
        self.evidencePack = evidencePack
        self.voiceExamples = voiceExamples
        self.avoidTopics = avoidTopics
        self.personaDescription = personaDescription
        self.suggestedOpenings = suggestedOpenings
        self.continuityAnchor = continuityAnchor
        self.sourceAnchors = sourceAnchors
        self.enrichmentSources = enrichmentSources
        self.timingWindow = timingWindow
    }

    private enum CodingKeys: String, CodingKey {
        case primaryAngle
        case alternativeAngles
        case evidencePack
        case voiceExamples
        case avoidTopics
        case personaDescription
        case suggestedOpenings
        case continuityAnchor
        case sourceAnchors
        case enrichmentSources
        case timingWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primaryAngle = try container.decode(AdvisoryWritingAngle.self, forKey: .primaryAngle)
        alternativeAngles = try container.decodeIfPresent([AdvisoryWritingAngle].self, forKey: .alternativeAngles) ?? []
        evidencePack = try container.decodeIfPresent([String].self, forKey: .evidencePack) ?? []
        voiceExamples = try container.decodeIfPresent([String].self, forKey: .voiceExamples) ?? []
        avoidTopics = try container.decodeIfPresent([String].self, forKey: .avoidTopics) ?? []
        personaDescription = try container.decode(String.self, forKey: .personaDescription)
        suggestedOpenings = try container.decodeIfPresent([String].self, forKey: .suggestedOpenings) ?? []
        continuityAnchor = try container.decodeIfPresent(String.self, forKey: .continuityAnchor)
        sourceAnchors = try container.decodeIfPresent([String].self, forKey: .sourceAnchors) ?? []
        enrichmentSources = try container.decodeIfPresent([AdvisoryEnrichmentSource].self, forKey: .enrichmentSources) ?? []
        timingWindow = try container.decodeIfPresent(String.self, forKey: .timingWindow)
    }
}

struct AdvisoryArtifactGuidanceMetadata: Codable, Equatable {
    let summary: String?
    let primaryAngle: String?
    let alternativeAngles: [String]
    let evidencePack: [String]
    let actionSteps: [String]
    let focusQuestion: String?
    let continuityAnchor: String?
    let openLoop: String?
    let decisionText: String?
    let candidateTask: String?
    let noteAnchorTitle: String?
    let noteAnchorSnippet: String?
    let patternName: String?
    let sourceAnchors: [String]
    let enrichmentSources: [AdvisoryEnrichmentSource]
    let timingWindow: String?

    init(
        summary: String? = nil,
        primaryAngle: String? = nil,
        alternativeAngles: [String] = [],
        evidencePack: [String] = [],
        actionSteps: [String] = [],
        focusQuestion: String? = nil,
        continuityAnchor: String? = nil,
        openLoop: String? = nil,
        decisionText: String? = nil,
        candidateTask: String? = nil,
        noteAnchorTitle: String? = nil,
        noteAnchorSnippet: String? = nil,
        patternName: String? = nil,
        sourceAnchors: [String] = [],
        enrichmentSources: [AdvisoryEnrichmentSource] = [],
        timingWindow: String? = nil
    ) {
        self.summary = summary
        self.primaryAngle = primaryAngle
        self.alternativeAngles = alternativeAngles
        self.evidencePack = evidencePack
        self.actionSteps = actionSteps
        self.focusQuestion = focusQuestion
        self.continuityAnchor = continuityAnchor
        self.openLoop = openLoop
        self.decisionText = decisionText
        self.candidateTask = candidateTask
        self.noteAnchorTitle = noteAnchorTitle
        self.noteAnchorSnippet = noteAnchorSnippet
        self.patternName = patternName
        self.sourceAnchors = sourceAnchors
        self.enrichmentSources = enrichmentSources
        self.timingWindow = timingWindow
    }

    private enum CodingKeys: String, CodingKey {
        case summary
        case primaryAngle
        case alternativeAngles
        case evidencePack
        case actionSteps
        case focusQuestion
        case continuityAnchor
        case openLoop
        case decisionText
        case candidateTask
        case noteAnchorTitle
        case noteAnchorSnippet
        case patternName
        case sourceAnchors
        case enrichmentSources
        case timingWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        primaryAngle = try container.decodeIfPresent(String.self, forKey: .primaryAngle)
        alternativeAngles = try container.decodeIfPresent([String].self, forKey: .alternativeAngles) ?? []
        evidencePack = try container.decodeIfPresent([String].self, forKey: .evidencePack) ?? []
        actionSteps = try container.decodeIfPresent([String].self, forKey: .actionSteps) ?? []
        focusQuestion = try container.decodeIfPresent(String.self, forKey: .focusQuestion)
        continuityAnchor = try container.decodeIfPresent(String.self, forKey: .continuityAnchor)
        openLoop = try container.decodeIfPresent(String.self, forKey: .openLoop)
        decisionText = try container.decodeIfPresent(String.self, forKey: .decisionText)
        candidateTask = try container.decodeIfPresent(String.self, forKey: .candidateTask)
        noteAnchorTitle = try container.decodeIfPresent(String.self, forKey: .noteAnchorTitle)
        noteAnchorSnippet = try container.decodeIfPresent(String.self, forKey: .noteAnchorSnippet)
        patternName = try container.decodeIfPresent(String.self, forKey: .patternName)
        sourceAnchors = try container.decodeIfPresent([String].self, forKey: .sourceAnchors) ?? []
        enrichmentSources = try container.decodeIfPresent([AdvisoryEnrichmentSource].self, forKey: .enrichmentSources) ?? []
        timingWindow = try container.decodeIfPresent(String.self, forKey: .timingWindow)
    }
}

enum AdvisoryArtifactStatus: String, CaseIterable, Codable {
    case candidate
    case queued
    case surfaced
    case dismissed
    case expired
    case accepted
    case muted
}

enum AdvisoryArtifactFeedbackKind: String, CaseIterable, Codable {
    case useful
    case tooObvious = "too_obvious"
    case tooBossy = "too_bossy"
    case wrong
    case notNow = "not_now"
    case muteKind = "mute_kind"
    case moreLikeThis = "more_like_this"

    var label: String {
        switch self {
        case .useful: return "Useful"
        case .tooObvious: return "Too Obvious"
        case .tooBossy: return "Too Bossy"
        case .wrong: return "Wrong"
        case .notNow: return "Not Now"
        case .muteKind: return "Mute Kind"
        case .moreLikeThis: return "More Like This"
        }
    }

    var resultingArtifactStatus: AdvisoryArtifactStatus {
        switch self {
        case .useful, .moreLikeThis:
            return .accepted
        case .muteKind:
            return .muted
        case .tooObvious, .tooBossy, .wrong, .notNow:
            return .dismissed
        }
    }
}

enum AdvisoryPacketKind: String, CaseIterable, Codable {
    case reflection
    case thread
    case weekly
}

enum AdvisoryTriggerKind: String, CaseIterable, Codable {
    case morningResume = "morning_resume"
    case reentryAfterIdle = "reentry_after_idle"
    case threadResurfaced = "thread_resurfaced"
    case researchBurstComplete = "research_burst_complete"
    case sessionEnd = "session_end"
    case endOfDay = "end_of_day"
    case weeklyReview = "weekly_review"
    case userInvokedLost = "user_invoked_lost"
    case userInvokedWrite = "user_invoked_write"
    case focusBreakNatural = "focus_break_natural"

    var isUserInvoked: Bool {
        switch self {
        case .userInvokedLost, .userInvokedWrite:
            return true
        default:
            return false
        }
    }
}

enum AdvisoryFocusState: String, CaseIterable, Codable, Identifiable {
    case deepWork = "deep_work"
    case browsing
    case transition
    case idleReturn = "idle_return"
    case fragmented

    var id: String { rawValue }
}

enum AdvisoryColdStartPhase: String, CaseIterable, Codable, Identifiable {
    case bootstrap
    case earlyThreads = "early_threads"
    case operational
    case mature

    var id: String { rawValue }
}

enum AdvisoryEnrichmentPhase: String, CaseIterable, Codable, Identifiable {
    case phase1Memograph = "phase1_memograph"
    case phase2ReadOnly = "phase2_readonly"
    case phase3Expanded = "phase3_expanded"

    var id: String { rawValue }

    var rolloutRank: Int {
        switch self {
        case .phase1Memograph: return 1
        case .phase2ReadOnly: return 2
        case .phase3Expanded: return 3
        }
    }

    var label: String {
        switch self {
        case .phase1Memograph: return "Phase 1"
        case .phase2ReadOnly: return "Phase 2"
        case .phase3Expanded: return "Phase 3"
        }
    }

    func supports(_ source: AdvisoryEnrichmentSource) -> Bool {
        rolloutRank >= source.minimumPhase.rolloutRank
    }
}

enum AdvisoryEnrichmentSource: String, CaseIterable, Codable, Identifiable, Hashable {
    case notes
    case calendar
    case reminders
    case webResearch = "web_research"
    case wearable

    var id: String { rawValue }

    var label: String {
        switch self {
        case .notes: return "Notes"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .webResearch: return "Web"
        case .wearable: return "Wearable / Rhythm"
        }
    }

    var minimumPhase: AdvisoryEnrichmentPhase {
        switch self {
        case .notes:
            return .phase1Memograph
        case .calendar, .reminders, .webResearch:
            return .phase2ReadOnly
        case .wearable:
            return .phase3Expanded
        }
    }

    var rolloutDescription: String {
        switch self {
        case .notes:
            return "Memograph-derived notes and suggested knowledge fragments."
        case .calendar:
            return "Read-only EventKit calendar windows and nearby commitments."
        case .reminders:
            return "Read-only reminders/tasks context from local EventKit."
        case .webResearch:
            return "Browser-derived research context and exploration traces."
        case .wearable:
            return "Health-derived rhythm signals; currently from Memograph activity, with room for future wearable inputs."
        }
    }
}

enum AdvisoryEnrichmentAvailability: String, CaseIterable, Codable {
    case embedded
    case deferred
    case unavailable
    case disabled
}

enum AdvisoryEnrichmentRuntimeKind: String, CaseIterable, Codable {
    case memographDerived = "memograph_derived"
    case localConnector = "local_connector"
    case timelineDerived = "timeline_derived"
    case connectorBacked = "connector_backed"
    case stagedPlaceholder = "staged_placeholder"

    var label: String {
        switch self {
        case .memographDerived: return "Memograph"
        case .localConnector: return "Local Connector"
        case .timelineDerived: return "Derived"
        case .connectorBacked: return "Connector"
        case .stagedPlaceholder: return "Staged"
        }
    }
}

enum AdvisoryEvidenceTier: String, CaseIterable, Codable {
    case l1Summary = "l1_summary"
    case l2Structured = "l2_structured"
    case l3Rich = "l3_rich"
}

enum AdvisoryRunStatus: String, CaseIterable, Codable {
    case running
    case success
    case failed
    case cancelled
}

struct GuidanceProfile: Codable, Equatable {
    let language: String
    let toneMode: String
    let assertivenessLevel: Double
    let allowProactiveAdvice: Bool
    let proactivityMode: AdvisoryProactivityMode
    let dailyAttentionBudget: Int
    let hardDailyCap: Int
    let minGapMinutes: Int
    let perThreadCooldownHours: Int
    let perKindFatigueCooldownHours: Int
    let writingStyle: String
    let allowScreenshotEscalation: Bool
    let allowExternalCLIProviders: Bool
    let allowMCPEnrichment: Bool
    let enrichmentPhase: AdvisoryEnrichmentPhase
    let enabledEnrichmentSources: [AdvisoryEnrichmentSource]
    let enabledDomains: [AdvisoryDomain]
    let attentionMarketMode: String
    let twitterVoiceExamples: [String]
    let preferredAngles: [String]
    let avoidTopics: [String]
    let contentPersonaDescription: String
    let allowProvocation: Bool
}

struct AdvisoryThreadCandidate: Codable, Equatable {
    let id: String?
    let title: String
    let slug: String
    let kind: AdvisoryThreadKind
    let status: AdvisoryThreadStatus
    let confidence: Double
    let firstSeenAt: String
    let lastActiveAt: String
    let source: String
    let summary: String?
    let parentThreadId: String?
    let totalActiveMinutes: Int
    let importanceScore: Double
}

struct AdvisoryThreadEvidenceCandidate: Codable, Equatable {
    let id: String?
    let evidenceKind: String
    let evidenceRef: String
    let weight: Double
    let createdAt: String?
}

struct AdvisoryThreadDetection: Codable, Equatable {
    let thread: AdvisoryThreadCandidate
    let evidence: [AdvisoryThreadEvidenceCandidate]
}

struct ContinuityItemCandidate: Codable, Equatable {
    let id: String?
    let threadId: String?
    let kind: ContinuityItemKind
    let title: String
    let body: String?
    let status: ContinuityItemStatus
    let confidence: Double
    let sourcePacketId: String?
    let createdAt: String?
    let updatedAt: String?
    let resolvedAt: String?
}

struct AdvisoryArtifactCandidate: Codable, Equatable {
    let id: String?
    let domain: AdvisoryDomain
    let kind: AdvisoryArtifactKind
    let title: String
    let body: String
    let threadId: String?
    let sourcePacketId: String
    let sourceRecipe: String
    let confidence: Double
    let whyNow: String?
    let evidenceJson: String?
    let metadataJson: String?
    let language: String
    let status: AdvisoryArtifactStatus
    let createdAt: String?
    let surfacedAt: String?
    let expiresAt: String?

    init(
        id: String? = nil,
        domain: AdvisoryDomain,
        kind: AdvisoryArtifactKind,
        title: String,
        body: String,
        threadId: String? = nil,
        sourcePacketId: String,
        sourceRecipe: String,
        confidence: Double,
        whyNow: String? = nil,
        evidenceJson: String? = nil,
        metadataJson: String? = nil,
        language: String,
        status: AdvisoryArtifactStatus,
        createdAt: String? = nil,
        surfacedAt: String? = nil,
        expiresAt: String? = nil
    ) {
        self.id = id
        self.domain = domain
        self.kind = kind
        self.title = title
        self.body = body
        self.threadId = threadId
        self.sourcePacketId = sourcePacketId
        self.sourceRecipe = sourceRecipe
        self.confidence = confidence
        self.whyNow = whyNow
        self.evidenceJson = evidenceJson
        self.metadataJson = metadataJson
        self.language = language
        self.status = status
        self.createdAt = createdAt
        self.surfacedAt = surfacedAt
        self.expiresAt = expiresAt
    }
}

struct AdvisoryThreadRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let slug: String
    let kind: AdvisoryThreadKind
    let status: AdvisoryThreadStatus
    let confidence: Double
    let userPinned: Bool
    let userTitleOverride: String?
    let parentThreadId: String?
    let firstSeenAt: String?
    let lastActiveAt: String?
    let totalActiveMinutes: Int
    let lastArtifactAt: String?
    let importanceScore: Double
    let source: String?
    let summary: String?
    let createdAt: String?
    let updatedAt: String?

    var displayTitle: String {
        if let userTitleOverride {
            let trimmed = userTitleOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return title
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let title = row["title"]?.textValue,
              let slug = row["slug"]?.textValue,
              let kindRaw = row["kind"]?.textValue,
              let statusRaw = row["status"]?.textValue,
              let kind = AdvisoryThreadKind(rawValue: kindRaw),
              let status = AdvisoryThreadStatus(rawValue: statusRaw) else {
            return nil
        }
        self.id = id
        self.title = title
        self.slug = slug
        self.kind = kind
        self.status = status
        self.confidence = row["confidence"]?.realValue ?? 0
        self.userPinned = (row["user_pinned"]?.intValue ?? 0) != 0
        self.userTitleOverride = row["user_title_override"]?.textValue
        self.parentThreadId = row["parent_thread_id"]?.textValue
        self.firstSeenAt = row["first_seen_at"]?.textValue
        self.lastActiveAt = row["last_active_at"]?.textValue
        self.totalActiveMinutes = row["total_active_minutes"]?.intValue.flatMap(Int.init) ?? 0
        self.lastArtifactAt = row["last_artifact_at"]?.textValue
        self.importanceScore = row["importance_score"]?.realValue ?? 0
        self.source = row["source"]?.textValue
        self.summary = row["summary"]?.textValue
        self.createdAt = row["created_at"]?.textValue
        self.updatedAt = row["updated_at"]?.textValue
    }
}

struct AdvisoryThreadEvidenceRecord: Identifiable, Equatable {
    let id: String
    let threadId: String
    let evidenceKind: String
    let evidenceRef: String
    let weight: Double
    let createdAt: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let threadId = row["thread_id"]?.textValue,
              let evidenceKind = row["evidence_kind"]?.textValue,
              let evidenceRef = row["evidence_ref"]?.textValue else {
            return nil
        }
        self.id = id
        self.threadId = threadId
        self.evidenceKind = evidenceKind
        self.evidenceRef = evidenceRef
        self.weight = row["weight"]?.realValue ?? 0
        self.createdAt = row["created_at"]?.textValue
    }
}

struct ContinuityItemRecord: Identifiable, Equatable {
    let id: String
    let threadId: String?
    let kind: ContinuityItemKind
    let title: String
    let body: String?
    let status: ContinuityItemStatus
    let confidence: Double
    let sourcePacketId: String?
    let createdAt: String?
    let updatedAt: String?
    let resolvedAt: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let kindRaw = row["kind"]?.textValue,
              let statusRaw = row["status"]?.textValue,
              let title = row["title"]?.textValue,
              let kind = ContinuityItemKind(rawValue: kindRaw),
              let status = ContinuityItemStatus(rawValue: statusRaw) else {
            return nil
        }
        self.id = id
        self.threadId = row["thread_id"]?.textValue
        self.kind = kind
        self.title = title
        self.body = row["body"]?.textValue
        self.status = status
        self.confidence = row["confidence"]?.realValue ?? 0
        self.sourcePacketId = row["source_packet_id"]?.textValue
        self.createdAt = row["created_at"]?.textValue
        self.updatedAt = row["updated_at"]?.textValue
        self.resolvedAt = row["resolved_at"]?.textValue
    }
}

struct AdvisoryPacketRecord: Identifiable, Equatable {
    let id: String
    let packetVersion: String
    let kind: AdvisoryPacketKind
    let triggerKind: AdvisoryTriggerKind?
    let windowStartedAt: String?
    let windowEndedAt: String?
    let payloadJson: String
    let language: String?
    let accessLevelGranted: AdvisoryAccessProfile?
    let createdAt: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let packetVersion = row["packet_version"]?.textValue,
              let kindRaw = row["kind"]?.textValue,
              let payloadJson = row["payload_json"]?.textValue,
              let kind = AdvisoryPacketKind(rawValue: kindRaw) else {
            return nil
        }
        self.id = id
        self.packetVersion = packetVersion
        self.kind = kind
        self.triggerKind = row["trigger_kind"]?.textValue.flatMap(AdvisoryTriggerKind.init(rawValue:))
        self.windowStartedAt = row["window_started_at"]?.textValue
        self.windowEndedAt = row["window_ended_at"]?.textValue
        self.payloadJson = payloadJson
        self.language = row["language"]?.textValue
        self.accessLevelGranted = row["access_level_granted"]?.textValue.flatMap(AdvisoryAccessProfile.init(rawValue:))
        self.createdAt = row["created_at"]?.textValue
    }
}

struct AdvisoryArtifactRecord: Identifiable, Equatable {
    let id: String
    let domain: AdvisoryDomain
    let kind: AdvisoryArtifactKind
    let title: String
    let body: String
    let threadId: String?
    let sourcePacketId: String?
    let sourceRecipe: String?
    let confidence: Double
    let whyNow: String?
    let evidenceJson: String?
    let metadataJson: String?
    let language: String?
    let status: AdvisoryArtifactStatus
    let marketScore: Double
    let attentionVectorJson: String?
    let marketContextJson: String?
    let createdAt: String?
    let surfacedAt: String?
    let expiresAt: String?

    var evidenceRefs: [String] {
        AdvisorySupport.decodeStringArray(from: evidenceJson)
    }

    var writingMetadata: AdvisoryWritingArtifactMetadata? {
        AdvisorySupport.decode(AdvisoryWritingArtifactMetadata.self, from: metadataJson)
    }

    var guidanceMetadata: AdvisoryArtifactGuidanceMetadata? {
        AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: metadataJson)
    }

    var attentionVector: ArtifactAttentionVector? {
        AdvisorySupport.decode(ArtifactAttentionVector.self, from: attentionVectorJson)
    }

    var marketContext: AttentionMarketContext? {
        AdvisorySupport.decode(AttentionMarketContext.self, from: marketContextJson)
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let domainRaw = row["domain"]?.textValue,
              let kindRaw = row["kind"]?.textValue,
              let title = row["title"]?.textValue,
              let body = row["body"]?.textValue,
              let statusRaw = row["status"]?.textValue,
              let domain = AdvisoryDomain(rawValue: domainRaw),
              let kind = AdvisoryArtifactKind(rawValue: kindRaw),
              let status = AdvisoryArtifactStatus(rawValue: statusRaw) else {
            return nil
        }
        self.id = id
        self.domain = domain
        self.kind = kind
        self.title = title
        self.body = body
        self.threadId = row["thread_id"]?.textValue
        self.sourcePacketId = row["source_packet_id"]?.textValue
        self.sourceRecipe = row["source_recipe"]?.textValue
        self.confidence = row["confidence"]?.realValue ?? 0
        self.whyNow = row["why_now"]?.textValue
        self.evidenceJson = row["evidence_json"]?.textValue
        self.metadataJson = row["metadata_json"]?.textValue
        self.language = row["language"]?.textValue
        self.status = status
        self.marketScore = row["market_score"]?.realValue ?? 0
        self.attentionVectorJson = row["attention_vector_json"]?.textValue
        self.marketContextJson = row["market_context_json"]?.textValue
        self.createdAt = row["created_at"]?.textValue
        self.surfacedAt = row["surfaced_at"]?.textValue
        self.expiresAt = row["expires_at"]?.textValue
    }
}

struct AdvisoryArtifactFeedbackRecord: Identifiable, Equatable {
    let id: String
    let artifactId: String
    let feedbackKind: AdvisoryArtifactFeedbackKind
    let notes: String?
    let createdAt: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let artifactId = row["artifact_id"]?.textValue,
              let kindRaw = row["feedback_kind"]?.textValue,
              let kind = AdvisoryArtifactFeedbackKind(rawValue: kindRaw) else {
            return nil
        }
        self.id = id
        self.artifactId = artifactId
        self.feedbackKind = kind
        self.notes = row["notes"]?.textValue
        self.createdAt = row["created_at"]?.textValue
    }
}

struct AdvisoryRunRecord: Identifiable, Equatable {
    let id: String
    let recipeName: String
    let recipeDomain: AdvisoryDomain?
    let packetId: String?
    let triggerKind: AdvisoryTriggerKind?
    let runtimeName: String?
    let providerName: String?
    let accessLevelRequested: AdvisoryAccessProfile?
    let accessLevelGranted: AdvisoryAccessProfile?
    let status: AdvisoryRunStatus
    let outputArtifactIdsJson: String?
    let errorText: String?
    let startedAt: String?
    let finishedAt: String?

    var outputArtifactIds: [String] {
        AdvisorySupport.decodeStringArray(from: outputArtifactIdsJson)
    }

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let recipeName = row["recipe_name"]?.textValue,
              let statusRaw = row["status"]?.textValue,
              let status = AdvisoryRunStatus(rawValue: statusRaw) else {
            return nil
        }
        self.id = id
        self.recipeName = recipeName
        self.recipeDomain = row["recipe_domain"]?.textValue.flatMap(AdvisoryDomain.init(rawValue:))
        self.packetId = row["packet_id"]?.textValue
        self.triggerKind = row["trigger_kind"]?.textValue.flatMap(AdvisoryTriggerKind.init(rawValue:))
        self.runtimeName = row["runtime_name"]?.textValue
        self.providerName = row["provider_name"]?.textValue
        self.accessLevelRequested = row["access_level_requested"]?.textValue.flatMap(AdvisoryAccessProfile.init(rawValue:))
        self.accessLevelGranted = row["access_level_granted"]?.textValue.flatMap(AdvisoryAccessProfile.init(rawValue:))
        self.status = status
        self.outputArtifactIdsJson = row["output_artifact_ids_json"]?.textValue
        self.errorText = row["error_text"]?.textValue
        self.startedAt = row["started_at"]?.textValue
        self.finishedAt = row["finished_at"]?.textValue
    }
}

struct AdvisoryEvidenceRequestRecord: Identifiable, Equatable {
    let id: String
    let runId: String
    let requestedLevel: AdvisoryAccessProfile
    let reason: String?
    let evidenceKindsJson: String?
    let granted: Bool
    let createdAt: String?

    init?(row: SQLiteRow) {
        guard let id = row["id"]?.textValue,
              let runId = row["run_id"]?.textValue,
              let requestedLevelRaw = row["requested_level"]?.textValue,
              let requestedLevel = AdvisoryAccessProfile(rawValue: requestedLevelRaw) else {
            return nil
        }
        self.id = id
        self.runId = runId
        self.requestedLevel = requestedLevel
        self.reason = row["reason"]?.textValue
        self.evidenceKindsJson = row["evidence_kinds_json"]?.textValue
        self.granted = (row["granted"]?.intValue ?? 0) != 0
        self.createdAt = row["created_at"]?.textValue
    }
}
