import Foundation
#if canImport(EventKit)
import EventKit
#endif

struct AdvisoryEnrichmentBuildContext {
    let window: SummaryWindowDescriptor
    let summary: DailySummaryRecord?
    let threads: [AdvisoryThreadRecord]
    let sessions: [SessionData]
    let keywords: [String]
    let settings: AppSettings
    let dateSupport: LocalDateSupport
    let db: DatabaseManager
}

protocol AdvisoryExternalEnrichmentProviding {
    var source: AdvisoryEnrichmentSource { get }
    var runtimeKind: AdvisoryEnrichmentRuntimeKind { get }
    var providerLabel: String { get }
    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle
}

extension AdvisoryExternalEnrichmentProviding {
    var runtimeKind: AdvisoryEnrichmentRuntimeKind { .connectorBacked }
    var providerLabel: String { source.label }
}

final class AdvisoryCalendarEnrichmentProvider: AdvisoryExternalEnrichmentProviding {
    struct Snapshot {
        let identifier: String
        let title: String
        let notes: String?
        let location: String?
        let startDate: Date
        let endDate: Date
    }

    let source: AdvisoryEnrichmentSource = .calendar
    let runtimeKind: AdvisoryEnrichmentRuntimeKind = .localConnector
    let providerLabel = "EventKit"
    private let loader: ((AdvisoryEnrichmentBuildContext) throws -> [Snapshot])?

    init(loader: ((AdvisoryEnrichmentBuildContext) throws -> [Snapshot])? = nil) {
        self.loader = loader
    }

    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle {
        #if canImport(EventKit)
        let status = eventAuthorizationStatus()
        guard authorizationAllowsReading(status) else {
            return ReflectionEnrichmentBundle(
                id: source.rawValue,
                source: source,
                tier: .l2Structured,
                availability: .unavailable,
                runtimeKind: runtimeKind,
                providerLabel: providerLabel,
                note: authorizationNote(for: status, domain: "Calendar"),
                items: []
            )
        }
        #endif
        let snapshots = try loader?(context) ?? loadEventKitSnapshots(context: context)
        let items = snapshots
            .map { snapshot in
                ReflectionEnrichmentItem(
                    id: AdvisorySupport.stableIdentifier(
                        prefix: "advenrich",
                        components: [source.rawValue, snapshot.identifier, snapshot.title]
                    ),
                    source: source,
                    title: snapshot.title,
                    snippet: calendarSnippet(for: snapshot, dateSupport: context.dateSupport),
                    relevance: calendarRelevance(snapshot: snapshot, keywords: context.keywords),
                    evidenceRefs: ["calendar_event:\(snapshot.identifier)"],
                    sourceRef: "calendar_event:\(snapshot.identifier)"
                )
            }
            .sorted { lhs, rhs in
                if lhs.relevance == rhs.relevance {
                    return lhs.title < rhs.title
                }
                return lhs.relevance > rhs.relevance
            }
            .prefix(max(1, context.settings.advisoryEnrichmentMaxItemsPerSource))

        let note = items.isEmpty
            ? "Calendar access is available, but no nearby events matched the current advisory context."
            : "Read-only calendar context attached from local EventKit."

        return ReflectionEnrichmentBundle(
            id: source.rawValue,
            source: source,
            tier: .l2Structured,
            availability: .embedded,
            runtimeKind: runtimeKind,
            providerLabel: providerLabel,
            note: note,
            items: Array(items)
        )
    }

    private func loadEventKitSnapshots(
        context: AdvisoryEnrichmentBuildContext
    ) throws -> [Snapshot] {
        #if canImport(EventKit)
        let eventStore = EKEventStore()
        let lookaheadHours = max(1, context.settings.advisoryCalendarLookaheadHours)
        let predicate = eventStore.predicateForEvents(
            withStart: context.window.start,
            end: context.window.end.addingTimeInterval(Double(lookaheadHours) * 3600),
            calendars: nil
        )
        let events = eventStore.events(matching: predicate)
        return events.map { event in
            Snapshot(
                identifier: event.eventIdentifier,
                title: event.title.isEmpty ? "Untitled calendar event" : event.title,
                notes: event.notes,
                location: event.location,
                startDate: event.startDate,
                endDate: event.endDate
            )
        }
        #else
        return []
        #endif
    }

    #if canImport(EventKit)
    private func eventAuthorizationStatus() -> EKAuthorizationStatus {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .event)
        }
        return EKEventStore.authorizationStatus(for: .event)
    }

    private func authorizationAllowsReading(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        // `authorized` is the pre-macOS 14 read access state.
        return status.rawValue == 3
    }

    private func authorizationNote(
        for status: EKAuthorizationStatus,
        domain: String
    ) -> String {
        switch status {
        case .notDetermined:
            return "\(domain) access has not been granted yet."
        case .restricted, .denied:
            return "\(domain) access is unavailable under current privacy permissions."
        case .writeOnly:
            return "\(domain) access is write-only, so advisory cannot read it."
        default:
            return "\(domain) access is currently unavailable."
        }
    }
    #endif

    private func calendarSnippet(
        for snapshot: Snapshot,
        dateSupport: LocalDateSupport
    ) -> String {
        let start = dateSupport.localDateTimeString(from: snapshot.startDate)
        let end = dateSupport.localDateTimeString(from: snapshot.endDate)
        let location = snapshot.location.flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        let notes = snapshot.notes.map { AdvisorySupport.cleanedSnippet($0, maxLength: 120) }
        return [start + " - " + end, location, notes].compactMap { $0 }.joined(separator: " • ")
    }

    private func calendarRelevance(
        snapshot: Snapshot,
        keywords: [String]
    ) -> Double {
        let haystack = [snapshot.title, snapshot.notes ?? "", snapshot.location ?? ""].joined(separator: " ")
        var score = enrichmentKeywordScore(text: haystack, keywords: keywords)
        let minutesUntilStart = snapshot.startDate.timeIntervalSinceNow / 60
        if minutesUntilStart >= -180 && minutesUntilStart <= 360 {
            score += 0.22
        }
        return min(1.0, score)
    }
}

final class AdvisoryRemindersEnrichmentProvider: AdvisoryExternalEnrichmentProviding {
    struct Snapshot {
        let identifier: String
        let title: String
        let notes: String?
        let dueDate: Date?
        let listTitle: String?
    }

    let source: AdvisoryEnrichmentSource = .reminders
    let runtimeKind: AdvisoryEnrichmentRuntimeKind = .localConnector
    let providerLabel = "EventKit"
    private let loader: ((AdvisoryEnrichmentBuildContext) throws -> [Snapshot])?

    init(loader: ((AdvisoryEnrichmentBuildContext) throws -> [Snapshot])? = nil) {
        self.loader = loader
    }

    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle {
        #if canImport(EventKit)
        let status = reminderAuthorizationStatus()
        guard authorizationAllowsReading(status) else {
            return ReflectionEnrichmentBundle(
                id: source.rawValue,
                source: source,
                tier: .l2Structured,
                availability: .unavailable,
                runtimeKind: runtimeKind,
                providerLabel: providerLabel,
                note: authorizationNote(for: status, domain: "Reminders"),
                items: []
            )
        }
        #endif
        let snapshots = try loader?(context) ?? loadReminderSnapshots(context: context)
        let items = snapshots
            .map { snapshot in
                ReflectionEnrichmentItem(
                    id: AdvisorySupport.stableIdentifier(
                        prefix: "advenrich",
                        components: [source.rawValue, snapshot.identifier, snapshot.title]
                    ),
                    source: source,
                    title: snapshot.title,
                    snippet: reminderSnippet(for: snapshot, dateSupport: context.dateSupport),
                    relevance: reminderRelevance(snapshot: snapshot, keywords: context.keywords),
                    evidenceRefs: ["reminder:\(snapshot.identifier)"],
                    sourceRef: "reminder:\(snapshot.identifier)"
                )
            }
            .sorted { lhs, rhs in
                if lhs.relevance == rhs.relevance {
                    return lhs.title < rhs.title
                }
                return lhs.relevance > rhs.relevance
            }
            .prefix(max(1, context.settings.advisoryEnrichmentMaxItemsPerSource))

        let note = items.isEmpty
            ? "Reminders access is available, but no active reminders matched the current advisory context."
            : "Read-only reminders context attached from local EventKit."

        return ReflectionEnrichmentBundle(
            id: source.rawValue,
            source: source,
            tier: .l2Structured,
            availability: .embedded,
            runtimeKind: runtimeKind,
            providerLabel: providerLabel,
            note: note,
            items: Array(items)
        )
    }

    private func loadReminderSnapshots(
        context: AdvisoryEnrichmentBuildContext
    ) throws -> [Snapshot] {
        #if canImport(EventKit)
        let eventStore = EKEventStore()
        let horizonDays = max(1, context.settings.advisoryReminderHorizonDays)
        let endDate = context.window.end.addingTimeInterval(Double(horizonDays) * 86_400)
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: context.window.start,
            ending: endDate,
            calendars: nil
        )

        var fetched: [EKReminder] = []
        let semaphore = DispatchSemaphore(value: 0)
        eventStore.fetchReminders(matching: predicate) { reminders in
            fetched = reminders ?? []
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)

        return fetched.map { reminder in
            Snapshot(
                identifier: reminder.calendarItemIdentifier,
                title: reminder.title.isEmpty ? "Untitled reminder" : reminder.title,
                notes: reminder.notes,
                dueDate: reminder.dueDateComponents.flatMap {
                    var adjusted = $0
                    adjusted.timeZone = adjusted.timeZone ?? context.dateSupport.timeZone
                    return Calendar(identifier: .gregorian).date(from: adjusted)
                },
                listTitle: reminder.calendar.title
            )
        }
        #else
        return []
        #endif
    }

    #if canImport(EventKit)
    private func reminderAuthorizationStatus() -> EKAuthorizationStatus {
        if #available(macOS 14.0, *) {
            return EKEventStore.authorizationStatus(for: .reminder)
        }
        return EKEventStore.authorizationStatus(for: .reminder)
    }

    private func authorizationAllowsReading(_ status: EKAuthorizationStatus) -> Bool {
        if #available(macOS 14.0, *) {
            return status == .fullAccess
        }
        // `authorized` is the pre-macOS 14 read access state.
        return status.rawValue == 3
    }

    private func authorizationNote(
        for status: EKAuthorizationStatus,
        domain: String
    ) -> String {
        switch status {
        case .notDetermined:
            return "\(domain) access has not been granted yet."
        case .restricted, .denied:
            return "\(domain) access is unavailable under current privacy permissions."
        case .writeOnly:
            return "\(domain) access is write-only, so advisory cannot read it."
        default:
            return "\(domain) access is currently unavailable."
        }
    }
    #endif

    private func reminderSnippet(
        for snapshot: Snapshot,
        dateSupport: LocalDateSupport
    ) -> String {
        let dueText = snapshot.dueDate.map { "Due \(dateSupport.localDateTimeString(from: $0))" } ?? "No due date"
        let notes = snapshot.notes.map { AdvisorySupport.cleanedSnippet($0, maxLength: 120) }
        return [dueText, snapshot.listTitle, notes].compactMap { $0 }.joined(separator: " • ")
    }

    private func reminderRelevance(
        snapshot: Snapshot,
        keywords: [String]
    ) -> Double {
        let haystack = [snapshot.title, snapshot.notes ?? "", snapshot.listTitle ?? ""].joined(separator: " ")
        var score = enrichmentKeywordScore(text: haystack, keywords: keywords)
        if let dueDate = snapshot.dueDate {
            let daysAway = abs(dueDate.timeIntervalSinceNow / 86_400)
            if daysAway <= 2 {
                score += 0.2
            }
        } else {
            score += 0.06
        }
        return min(1.0, score)
    }
}

final class AdvisoryWebResearchEnrichmentProvider: AdvisoryExternalEnrichmentProviding {
    private let db: DatabaseManager
    private let dateSupport: LocalDateSupport

    let source: AdvisoryEnrichmentSource = .webResearch
    let runtimeKind: AdvisoryEnrichmentRuntimeKind = .timelineDerived
    let providerLabel = "Timeline Browser Context"

    init(
        db: DatabaseManager,
        timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.db = db
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle {
        let lookbackDays = max(1, context.settings.advisoryWebResearchLookbackDays)
        let lookbackStart = context.window.start.addingTimeInterval(Double(-max(0, lookbackDays - 1)) * 86_400)
        let rows = try db.query("""
            SELECT *
            FROM context_snapshots
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY timestamp DESC
            LIMIT 60
        """, params: [
            .text(dateSupport.isoString(from: lookbackStart)),
            .text(dateSupport.isoString(from: context.window.end))
        ])
        let snapshots = rows.compactMap(ContextSnapshotRecord.init(row:))
            .filter(isBrowserContext(_:))
            .map { snapshot in
                ReflectionEnrichmentItem(
                    id: AdvisorySupport.stableIdentifier(
                        prefix: "advenrich",
                        components: [source.rawValue, snapshot.id, snapshot.windowTitle ?? snapshot.appName ?? "web"]
                    ),
                    source: source,
                    title: webTitle(for: snapshot),
                    snippet: webSnippet(for: snapshot),
                    relevance: webRelevance(snapshot: snapshot, keywords: context.keywords),
                    evidenceRefs: ["context_snapshot:\(snapshot.id)", "session:\(snapshot.sessionId)"],
                    sourceRef: "context_snapshot:\(snapshot.id)"
                )
            }
            .filter { $0.relevance > 0.1 }

        let deduped = dedupeItems(
            snapshots,
            key: { item in
                item.title.lowercased() + "::" + item.snippet.prefix(48).lowercased()
            }
        )
        let items = deduped
            .sorted { lhs, rhs in
                if lhs.relevance == rhs.relevance {
                    return lhs.title < rhs.title
                }
                return lhs.relevance > rhs.relevance
            }
            .prefix(max(1, context.settings.advisoryEnrichmentMaxItemsPerSource))

        let note = items.isEmpty
            ? "No recent browser research context matched the current advisory threads."
            : "Timeline-derived browser research context attached as staged web enrichment."

        return ReflectionEnrichmentBundle(
            id: source.rawValue,
            source: source,
            tier: .l2Structured,
            availability: .embedded,
            runtimeKind: runtimeKind,
            providerLabel: providerLabel,
            note: note,
            items: Array(items)
        )
    }

    private func isBrowserContext(_ snapshot: ContextSnapshotRecord) -> Bool {
        let haystack = [snapshot.bundleId ?? "", snapshot.appName ?? ""]
            .joined(separator: " ")
            .lowercased()
        return ["safari", "chrome", "arc", "firefox", "brave", "orion", "browser"]
            .contains(where: haystack.contains)
    }

    private func webTitle(for snapshot: ContextSnapshotRecord) -> String {
        if let windowTitle = snapshot.windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           !windowTitle.isEmpty {
            return windowTitle
        }
        if let topicHint = snapshot.topicHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !topicHint.isEmpty {
            return topicHint
        }
        return snapshot.appName ?? "Web research"
    }

    private func webSnippet(for snapshot: ContextSnapshotRecord) -> String {
        let timestamp = dateSupport.localDateTimeString(from: snapshot.timestamp)
        let app = snapshot.appName
        let snippet = snapshot.mergedText.map { AdvisorySupport.cleanedSnippet($0, maxLength: 150) }
        return [timestamp, app, snippet].compactMap { $0 }.joined(separator: " • ")
    }

    private func webRelevance(
        snapshot: ContextSnapshotRecord,
        keywords: [String]
    ) -> Double {
        let haystack = [
            snapshot.windowTitle ?? "",
            snapshot.mergedText ?? "",
            snapshot.topicHint ?? "",
            snapshot.appName ?? ""
        ].joined(separator: " ")
        var score = enrichmentKeywordScore(text: haystack, keywords: keywords)
        score += min(0.18, snapshot.readableScore * 0.18)
        return min(1.0, score)
    }
}

final class AdvisoryRhythmEnrichmentProvider: AdvisoryExternalEnrichmentProviding {
    let source: AdvisoryEnrichmentSource = .wearable
    let runtimeKind: AdvisoryEnrichmentRuntimeKind = .timelineDerived
    let providerLabel = "Memograph Rhythm"

    private let dateSupport: LocalDateSupport

    init(timeZone: TimeZone = .autoupdatingCurrent) {
        self.dateSupport = LocalDateSupport(timeZone: timeZone)
    }

    func buildBundle(context: AdvisoryEnrichmentBuildContext) throws -> ReflectionEnrichmentBundle {
        let sessions = context.sessions
        guard !sessions.isEmpty else {
            return ReflectionEnrichmentBundle(
                id: source.rawValue,
                source: source,
                tier: .l3Rich,
                availability: .embedded,
                runtimeKind: runtimeKind,
                providerLabel: providerLabel,
                note: "No health-derived rhythm signals crossed threshold for this window.",
                items: []
            )
        }

        var items: [ReflectionEnrichmentItem] = []

        if let fragmentation = fragmentedWorkItem(sessions: sessions) {
            items.append(fragmentation)
        }
        if let lateStretch = lateStretchItem(sessions: sessions) {
            items.append(lateStretch)
        }
        if let loadWindow = loadWindowItem(sessions: sessions) {
            items.append(loadWindow)
        }

        let deduped = dedupeItems(
            items,
            key: { $0.title.lowercased() + "::" + $0.snippet.prefix(48).lowercased() }
        )
        let note = deduped.isEmpty
            ? "No health-derived rhythm signals crossed threshold for this window."
            : "Health-derived rhythm signals attached from Memograph activity only. No wearable device telemetry is included."

        return ReflectionEnrichmentBundle(
            id: source.rawValue,
            source: source,
            tier: .l3Rich,
            availability: .embedded,
            runtimeKind: runtimeKind,
            providerLabel: providerLabel,
            note: note,
            items: Array(deduped.prefix(max(1, context.settings.advisoryEnrichmentMaxItemsPerSource)))
        )
    }

    private func fragmentedWorkItem(sessions: [SessionData]) -> ReflectionEnrichmentItem? {
        let sorted = sessions.sorted { $0.startedAt < $1.startedAt }
        let shortSessions = sorted.filter { durationMinutes(for: $0) <= 12 }
        let uniqueApps = Set(sorted.map(\.bundleId)).count
        let degradedCount = sorted.filter { $0.uncertaintyMode != "normal" }.count
        let fragmentationScore = min(
            1.0,
            (Double(shortSessions.count) * 0.08)
                + (Double(uniqueApps) * 0.05)
                + (Double(degradedCount) * 0.07)
        )
        guard shortSessions.count >= 4 || fragmentationScore >= 0.46 else {
            return nil
        }

        let evidence = Array(shortSessions.prefix(4).map { "session:\($0.sessionId)" })
        let snippet = "\(shortSessions.count) short sessions across \(uniqueApps) apps. Re-entry cost likely rising."
        return ReflectionEnrichmentItem(
            id: AdvisorySupport.stableIdentifier(
                prefix: "advenrich",
                components: [source.rawValue, "fragmented", sorted.first?.sessionId ?? "none"]
            ),
            source: source,
            title: "Fragmented work blocks",
            snippet: snippet,
            relevance: fragmentationScore,
            evidenceRefs: evidence,
            sourceRef: evidence.first
        )
    }

    private func lateStretchItem(sessions: [SessionData]) -> ReflectionEnrichmentItem? {
        let parsed = sessions.compactMap { session -> (SessionData, Date)? in
            let end = session.endedAt ?? session.startedAt
            guard let date = dateSupport.parseDateTime(end) else { return nil }
            return (session, date)
        }
        guard let latest = parsed.max(by: { $0.1 < $1.1 }) else {
            return nil
        }

        let lateHour = Calendar(identifier: .gregorian)
            .dateComponents(in: dateSupport.timeZone, from: latest.1)
            .hour ?? 0
        let eveningMinutes = sessions.reduce(into: 0) { partialResult, session in
            guard let start = dateSupport.parseDateTime(session.startedAt) else { return }
            let hour = Calendar(identifier: .gregorian)
                .dateComponents(in: dateSupport.timeZone, from: start)
                .hour ?? 0
            if hour >= 19 {
                partialResult += durationMinutes(for: session)
            }
        }

        let score = min(
            1.0,
            (lateHour >= 22 ? 0.62 : lateHour >= 21 ? 0.48 : 0.0)
                + min(0.28, Double(eveningMinutes) / 300.0)
        )
        guard score >= 0.42 else {
            return nil
        }

        let endLabel = dateSupport.localDateTimeString(from: latest.1)
        let evidence = ["session:\(latest.0.sessionId)"]
        return ReflectionEnrichmentItem(
            id: AdvisorySupport.stableIdentifier(
                prefix: "advenrich",
                components: [source.rawValue, "late_stretch", latest.0.sessionId]
            ),
            source: source,
            title: "Late work stretch",
            snippet: "Latest active stretch ended around \(endLabel). Evening activity reached \(eveningMinutes) min.",
            relevance: score,
            evidenceRefs: evidence,
            sourceRef: evidence.first
        )
    }

    private func loadWindowItem(sessions: [SessionData]) -> ReflectionEnrichmentItem? {
        let totalMinutes = sessions.reduce(0) { $0 + durationMinutes(for: $1) }
        let longest = sessions.max(by: { durationMinutes(for: $0) < durationMinutes(for: $1) })
        let longestMinutes = longest.map { durationMinutes(for: $0) } ?? 0
        let score = min(
            1.0,
            min(0.42, Double(totalMinutes) / 600.0) + min(0.32, Double(longestMinutes) / 240.0)
        )
        guard totalMinutes >= 180 || longestMinutes >= 95 else {
            return nil
        }

        let evidence = longest.map { ["session:\($0.sessionId)"] } ?? []
        return ReflectionEnrichmentItem(
            id: AdvisorySupport.stableIdentifier(
                prefix: "advenrich",
                components: [source.rawValue, "load_window", longest?.sessionId ?? "none"]
            ),
            source: source,
            title: "High cognitive load window",
            snippet: "Total active time \(totalMinutes) min, longest stretch \(longestMinutes) min.",
            relevance: score,
            evidenceRefs: evidence,
            sourceRef: evidence.first
        )
    }

    private func durationMinutes(for session: SessionData) -> Int {
        max(1, Int((Double(session.durationMs) / 60_000.0).rounded()))
    }
}

private func enrichmentKeywordScore(
    text: String,
    keywords: [String]
) -> Double {
    let haystack = text.lowercased()
    var score = 0.0
    for keyword in keywords.prefix(12) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { continue }
        let lowered = trimmed.lowercased()
        if haystack.contains(lowered) {
            score += haystack.contains(" \(lowered) ") ? 0.18 : 0.12
        }
    }
    return min(1.0, score)
}

private func dedupeItems<T>(
    _ items: [T],
    key: (T) -> String
) -> [T] {
    var seen: Set<String> = []
    var deduped: [T] = []
    for item in items {
        let identifier = key(item)
        if seen.contains(identifier) {
            continue
        }
        seen.insert(identifier)
        deduped.append(item)
    }
    return deduped
}
