import SwiftUI

struct TimelineView: View {
    let db: DatabaseManager
    private let dateSupport = LocalDateSupport()
    @ObservedObject private var advisoryHealthMonitor = AdvisoryHealthMonitor.shared

    @State private var selectedDate: String = LocalDateSupport().currentLocalDateString()
    @State private var sessions: [TimelineSession] = []
    @State private var apps: [AppUsageSummary] = []
    @State private var dates: [String] = []
    @State private var searchText = ""
    @State private var searchResults: [ContextSnapshotRecord] = []
    @State private var advisoryArtifact: AdvisoryArtifactRecord?
    @State private var advisoryThread: AdvisoryThreadRecord?
    @State private var advisoryContinuityItems: [ContinuityItemRecord] = []
    @State private var advisoryInbox: [AdvisoryArtifactRecord] = []
    @State private var advisoryThreads: [AdvisoryThreadRecord] = []
    @State private var advisoryThreadsById: [String: AdvisoryThreadRecord] = [:]
    @State private var advisoryWorkspaceSnapshot: AdvisoryWorkspaceSnapshot?
    @State private var selectedDomainDetail: AdvisoryDomainWorkspaceDetail?
    @State private var selectedInboxDomain: AdvisoryDomain?
    @State private var runningDomainAction: AdvisoryDomain?
    @State private var selectedThreadId: String?
    @State private var selectedThreadDetail: AdvisoryThreadDetailSnapshot?
    @State private var advisoryStatusMessage: String?
    @State private var showCreateThreadSheet = false
    @State private var newThreadTitle = ""
    @State private var newThreadSummary = ""
    @State private var newThreadKindRaw = AdvisoryThreadKind.project.rawValue
    @State private var newThreadParentId: String?
    @State private var advisoryLoadToken = UUID()
    @State private var isApplyingSnapshot = false

    private struct AdvisoryLoadSnapshot {
        let artifact: AdvisoryArtifactRecord?
        let thread: AdvisoryThreadRecord?
        let continuityItems: [ContinuityItemRecord]
        let inbox: [AdvisoryArtifactRecord]
        let threads: [AdvisoryThreadRecord]
        let threadsById: [String: AdvisoryThreadRecord]
        let workspaceSnapshot: AdvisoryWorkspaceSnapshot?
        let selectedDomain: AdvisoryDomain?
        let selectedThreadId: String?
        let selectedThreadDetail: AdvisoryThreadDetailSnapshot?
        let selectedDomainDetail: AdvisoryDomainWorkspaceDetail?
    }

    var body: some View {
        HSplitView {
            List(dates, id: \.self, selection: $selectedDate) { date in
                Text(date)
            }
            .frame(minWidth: 120, maxWidth: 160)

            HSplitView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .center) {
                        Text("Timeline — \(selectedDate)")
                            .font(.title2).fontWeight(.semibold)
                        Spacer()
                        Button("Weekly Review") {
                            generateWeeklyReview()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    TextField("Search context for this day...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { performSearch() }

                    if !searchResults.isEmpty {
                        searchResultsView
                    } else {
                        timelineContentView
                    }
                }
                .padding()
                .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                threadInspectorPane
            }
        }
        .frame(minWidth: 1040, minHeight: 560)
        .sheet(isPresented: $showCreateThreadSheet) {
            createThreadSheet
        }
        .onAppear {
            advisoryHealthMonitor.startIfNeeded()
            advisoryHealthMonitor.refresh()
            loadData()
        }
        .onChange(of: selectedDate) { loadData() }
        .onChange(of: selectedThreadId) {
            guard !isApplyingSnapshot else { return }
            // If the snapshot already loaded the matching detail, skip re-fetch.
            if let selectedThreadId,
               selectedThreadDetail?.thread.id == selectedThreadId {
                return
            }
            advisoryLoadToken = UUID()
            loadSelectedThreadDetail()
        }
        .onChange(of: selectedInboxDomain) {
            guard !isApplyingSnapshot else { return }
            if let selectedInboxDomain,
               selectedDomainDetail?.domain == selectedInboxDomain {
                return
            }
            advisoryLoadToken = UUID()
            loadSelectedDomainDetail()
        }
    }

    private var timelineContentView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if advisoryHealthMonitor.snapshot.isDegraded {
                    advisoryRuntimeBanner
                }

                if let advisoryWorkspaceSnapshot {
                    AdvisoryOverviewView(
                        snapshot: advisoryWorkspaceSnapshot,
                        selectedDomain: selectedInboxDomain,
                        onSelectDomain: { selectedInboxDomain = $0 }
                    )

                    AdvisoryActionPanelView(
                        snapshot: advisoryWorkspaceSnapshot,
                        topArtifactsByDomain: topArtifactsByDomain,
                        selectedDomain: selectedInboxDomain,
                        runningDomain: runningDomainAction,
                        onRunDomainAction: runDomainAction(_:),
                        onSelectDomain: { selectedInboxDomain = $0 }
                    )
                }

                if let advisoryArtifact {
                    ResumeCardView(
                        artifact: advisoryArtifact,
                        thread: advisoryThread,
                        continuityItems: advisoryContinuityItems,
                        onOpenThread: advisoryThread.map { thread in
                            { selectThread(thread.id) }
                        },
                        onQuickAction: { action in
                            materializeArtifactQuickAction(
                                artifactId: advisoryArtifact.id,
                                action: action
                            )
                        },
                        onFeedback: { kind in
                            applyArtifactFeedback(artifactId: advisoryArtifact.id, kind: kind)
                        }
                    )
                }

                if !advisoryNowArtifacts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(selectedInboxDomain.map { "Advisor Now · \($0.label)" } ?? "Advisor Now")
                                .font(.headline)
                            Spacer()
                        }
                        Text("Сильные non-continuity сигналы, которые market уже пропустил наружу.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(advisoryNowArtifacts) { artifact in
                            AdvisoryArtifactCardView(
                                artifact: artifact,
                                thread: artifact.threadId.flatMap { advisoryThreadsById[$0] },
                                maxBodyLength: 180,
                                maxSteps: 2,
                                onOpenThread: selectThread(_:),
                                onQuickAction: { action in
                                    materializeArtifactQuickAction(artifactId: artifact.id, action: action)
                                },
                                onFeedback: { kind in
                                    applyArtifactFeedback(artifactId: artifact.id, kind: kind)
                                }
                            )
                        }
                    }
                }

                if let selectedDomainDetail {
                    Divider()
                    AdvisoryDomainWorkspaceView(
                        detail: selectedDomainDetail,
                        threadsById: advisoryThreadsById,
                        onRunAction: {
                            runDomainAction(selectedDomainDetail.domain)
                        },
                        onClearSelection: {
                            selectedInboxDomain = nil
                        },
                        onOpenThread: selectThread(_:),
                        onQuickAction: materializeArtifactQuickAction(artifactId:action:),
                        onFeedback: applyArtifactFeedback(artifactId:kind:)
                    )
                }

                AdvisoryThreadListView(
                    threads: advisoryThreads,
                    selectedThreadId: selectedThreadId,
                    onSelectThread: selectThread(_:),
                    onCreateThread: { presentCreateThread(parentThreadId: nil) }
                )

                if !advisoryLatentArtifacts.isEmpty || selectedInboxDomain != nil {
                    Divider()
                    AdvisoryInboxView(
                        artifacts: advisoryLatentArtifacts,
                        threadsById: advisoryThreadsById,
                        marketSnapshot: advisoryWorkspaceSnapshot?.marketSnapshot,
                        selectedDomain: selectedInboxDomain,
                        onClearDomainFilter: { selectedInboxDomain = nil },
                        onOpenThread: selectThread(_:),
                        onQuickAction: materializeArtifactQuickAction(artifactId:action:),
                        onFeedback: applyArtifactFeedback(artifactId:kind:)
                    )
                }

                if !apps.isEmpty {
                    Divider()
                    Text("Apps").font(.headline)
                    ForEach(apps, id: \.bundleId) { app in
                        HStack {
                            Text(app.appName).fontWeight(.medium)
                            Spacer()
                            Text(ObsidianExporter.formatDuration(minutes: app.totalMinutes))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                Text("Sessions").font(.headline)
                if sessions.isEmpty {
                    Text("No sessions recorded for this day yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions, id: \.sessionId) { session in
                        SessionRowView(session: session)
                    }
                }
            }
        }
    }

    private var advisoryRuntimeBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(advisoryHealthMonitor.snapshot.statusTitle)
                .font(.subheadline.weight(.semibold))
            ForEach(advisoryHealthMonitor.snapshot.statusLines.prefix(3), id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AdvisoryProviderDiagnosticsView(
                providerStatuses: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.providerStatuses,
                activeProviderName: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.activeProviderName,
                checkedAt: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.checkedAt,
                compact: true
            )
            HStack(spacing: 8) {
                Button("Refresh") {
                    advisoryHealthMonitor.refresh()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button("Restart sidecar") {
                    advisoryHealthMonitor.restartSidecar()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }

    private var threadInspectorPane: some View {
        Group {
            if let selectedThreadDetail {
                AdvisoryThreadInspectorView(
                    snapshot: selectedThreadDetail,
                    statusMessage: advisoryStatusMessage,
                    onRename: renameSelectedThread(to:),
                    onTogglePinned: toggleSelectedThreadPinned,
                    onSetStatus: setSelectedThreadStatus(_:),
                    onExport: exportSelectedThread,
                    onTurnIntoSignal: turnSelectedThreadIntoSignal,
                    onCreateSubthread: { presentCreateThread(parentThreadId: selectedThreadDetail.thread.id) },
                    onSelectThread: selectThread(_:),
                    onApplyMaintenanceProposal: applyMaintenanceProposal(_:),
                    onQuickAction: materializeArtifactQuickAction(artifactId:action:),
                    onFeedback: applyArtifactFeedback(artifactId:kind:)
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Thread Inspector")
                        .font(.headline)
                    Text("Выбери thread из Resume Me, Advisory Inbox или списка нитей, чтобы увидеть detail view.")
                        .foregroundStyle(.secondary)
                    if let advisoryStatusMessage, !advisoryStatusMessage.isEmpty {
                        Text(advisoryStatusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Создать thread") {
                        presentCreateThread(parentThreadId: nil)
                    }
                    .buttonStyle(.bordered)
                }
                .padding()
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private var searchResultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Search results for \"\(searchText)\"").font(.headline)
                ForEach(searchResults, id: \.id) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.appName ?? "Unknown").fontWeight(.medium)
                            Text(result.windowTitle ?? "").foregroundStyle(.secondary)
                            Spacer()
                            Text(dateSupport.localDateTimeString(from: result.timestamp))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let text = result.mergedText {
                            Text(String(text.prefix(200)))
                                .font(.caption)
                                .lineLimit(3)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                }
            }
        }
    }

    private var createThreadSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(newThreadParentId == nil ? "Создать thread" : "Создать sub-thread")
                .font(.title3.weight(.semibold))

            if let newThreadParentId,
               let parentThread = advisoryThreadsById[newThreadParentId] ?? selectedThreadDetail?.thread {
                Text("Parent: \(parentThread.displayTitle)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Название", text: $newThreadTitle)
                Picker("Kind", selection: $newThreadKindRaw) {
                    ForEach(AdvisoryThreadKind.allCases, id: \.rawValue) { kind in
                        Text(threadKindLabel(kind)).tag(kind.rawValue)
                    }
                }
                TextEditor(text: $newThreadSummary)
                    .frame(minHeight: 110)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showCreateThreadSheet = false
                }
                Button("Create") {
                    createThread()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var filteredAdvisoryInbox: [AdvisoryArtifactRecord] {
        guard let selectedInboxDomain else { return advisoryInbox }
        return advisoryInbox.filter { $0.domain == selectedInboxDomain }
    }

    private var advisoryNowArtifacts: [AdvisoryArtifactRecord] {
        filteredAdvisoryInbox.filter { $0.status == .surfaced }
    }

    private var advisoryLatentArtifacts: [AdvisoryArtifactRecord] {
        filteredAdvisoryInbox.filter { $0.status != .surfaced }
    }

    private var topArtifactsByDomain: [AdvisoryDomain: AdvisoryArtifactRecord] {
        let allArtifacts = [advisoryArtifact].compactMap { $0 } + advisoryInbox
        return Dictionary(grouping: allArtifacts, by: \.domain).compactMapValues { artifacts in
            artifacts.sorted { lhs, rhs in
                if artifactStatusRank(lhs.status) == artifactStatusRank(rhs.status) {
                    return lhs.marketScore > rhs.marketScore
                }
                return artifactStatusRank(lhs.status) < artifactStatusRank(rhs.status)
            }.first
        }
    }

    private func loadData() {
        let provider = TimelineDataProvider(db: db, timeZone: dateSupport.timeZone)
        let loadedDates = (try? provider.availableDates()) ?? []
        dates = loadedDates
        if let mostRecent = loadedDates.first, !loadedDates.contains(selectedDate) {
            selectedDate = mostRecent
            return
        }
        sessions = (try? provider.sessionsForDate(selectedDate)) ?? []
        apps = (try? provider.appSummaryForDate(selectedDate)) ?? []
        searchResults = []
        searchText = ""
        loadAdvisory(preferredThreadId: selectedThreadId)
    }

    private func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        let engine = SearchEngine(db: db, timeZone: dateSupport.timeZone)
        searchResults = (try? engine.searchByDate(query: searchText, date: selectedDate)) ?? []
    }

    private func loadAdvisory(preferredThreadId: String? = nil) {
        let requestDate = selectedDate
        let requestPreferredThreadId = preferredThreadId
        let requestSelectedDomain = selectedInboxDomain
        let requestToken = UUID()
        advisoryLoadToken = requestToken
        let database = db
        let timeZone = dateSupport.timeZone

        DispatchQueue.global(qos: .userInitiated).async {
            let snapshot = TimelineView.buildAdvisorySnapshot(
                db: database,
                timeZone: timeZone,
                localDate: requestDate,
                preferredThreadId: requestPreferredThreadId,
                selectedDomain: requestSelectedDomain
            )

            DispatchQueue.main.async {
                guard advisoryLoadToken == requestToken, selectedDate == requestDate else { return }
                applyAdvisorySnapshot(snapshot)
            }
        }
    }

    nonisolated private static func buildAdvisorySnapshot(
        db: DatabaseManager,
        timeZone: TimeZone,
        localDate: String,
        preferredThreadId: String?,
        selectedDomain: AdvisoryDomain?
    ) -> AdvisoryLoadSnapshot {
        let engine = AdvisoryEngine(db: db, timeZone: timeZone)
        let artifact = try? engine.generateResumeArtifact(for: localDate)
        let workspaceSnapshot = try? engine.workspaceSnapshot(for: localDate)
        let advisoryThread = try? engine.thread(for: artifact?.threadId)
        let continuityItems: [ContinuityItemRecord]
        if let threadId = advisoryThread?.id {
            continuityItems = (try? engine.continuityItems(forThread: threadId, limit: 3)) ?? []
        } else {
            continuityItems = (try? engine.openContinuityItems(limit: 3)) ?? []
        }
        let inbox = ((try? engine.advisoryInbox(limit: 16)) ?? [])
            .filter { $0.id != artifact?.id }

        var loadedThreads = (try? engine.threads(limit: 8)) ?? []
        if let advisoryThread,
           !loadedThreads.contains(where: { $0.id == advisoryThread.id }) {
            loadedThreads.insert(advisoryThread, at: 0)
        }

        let threadsById = Dictionary(uniqueKeysWithValues: loadedThreads.map { ($0.id, $0) })
        let resolvedSelectedDomain: AdvisoryDomain?
        if let selectedDomain,
           workspaceSnapshot?.marketSnapshot.domainSnapshots.contains(where: { $0.domain == selectedDomain }) == true {
            resolvedSelectedDomain = selectedDomain
        } else {
            resolvedSelectedDomain = nil
        }

        let fallbackSelection = preferredThreadId ?? advisoryThread?.id ?? loadedThreads.first?.id
        let resolvedSelectedThreadId: String?
        if let fallbackSelection,
           loadedThreads.contains(where: { $0.id == fallbackSelection }) || advisoryThread?.id == fallbackSelection {
            resolvedSelectedThreadId = fallbackSelection
        } else {
            resolvedSelectedThreadId = nil
        }

        let selectedThreadDetail = resolvedSelectedThreadId.flatMap { try? engine.threadDetail(for: $0) }
        let selectedDomainDetail = resolvedSelectedDomain.flatMap { try? engine.domainWorkspaceDetail(for: localDate, domain: $0) }

        return AdvisoryLoadSnapshot(
            artifact: artifact,
            thread: advisoryThread,
            continuityItems: continuityItems,
            inbox: inbox,
            threads: loadedThreads,
            threadsById: threadsById,
            workspaceSnapshot: workspaceSnapshot,
            selectedDomain: resolvedSelectedDomain,
            selectedThreadId: resolvedSelectedThreadId,
            selectedThreadDetail: selectedThreadDetail,
            selectedDomainDetail: selectedDomainDetail
        )
    }

    private func applyAdvisorySnapshot(_ snapshot: AdvisoryLoadSnapshot) {
        isApplyingSnapshot = true
        advisoryArtifact = snapshot.artifact
        advisoryWorkspaceSnapshot = snapshot.workspaceSnapshot
        advisoryThread = snapshot.thread
        advisoryContinuityItems = snapshot.continuityItems
        advisoryInbox = snapshot.inbox
        advisoryThreads = snapshot.threads
        advisoryThreadsById = snapshot.threadsById
        // Set pre-computed details BEFORE their corresponding selection IDs
        // so onChange handlers see the detail is already loaded and skip re-fetch.
        selectedThreadDetail = snapshot.selectedThreadDetail
        selectedDomainDetail = snapshot.selectedDomainDetail
        selectedInboxDomain = snapshot.selectedDomain
        selectedThreadId = snapshot.selectedThreadId
        isApplyingSnapshot = false
    }

    private func loadSelectedThreadDetail() {
        guard let threadId = selectedThreadId else {
            selectedThreadDetail = nil
            return
        }
        let database = db
        let timeZone = dateSupport.timeZone
        let token = advisoryLoadToken
        DispatchQueue.global(qos: .userInitiated).async {
            let detailEngine = AdvisoryEngine(db: database, timeZone: timeZone)
            let detail = try? detailEngine.threadDetail(for: threadId)
            DispatchQueue.main.async {
                guard advisoryLoadToken == token, selectedThreadId == threadId else { return }
                selectedThreadDetail = detail
                if let thread = detail?.thread {
                    advisoryThreadsById[thread.id] = thread
                }
            }
        }
    }

    private func loadSelectedDomainDetail() {
        guard let domain = selectedInboxDomain else {
            selectedDomainDetail = nil
            return
        }
        let database = db
        let timeZone = dateSupport.timeZone
        let date = selectedDate
        let token = advisoryLoadToken
        DispatchQueue.global(qos: .userInitiated).async {
            let detailEngine = AdvisoryEngine(db: database, timeZone: timeZone)
            let detail = try? detailEngine.domainWorkspaceDetail(for: date, domain: domain)
            DispatchQueue.main.async {
                guard advisoryLoadToken == token, selectedInboxDomain == domain else { return }
                selectedDomainDetail = detail
            }
        }
    }

    private func selectThread(_ threadId: String) {
        selectedThreadId = threadId
    }

    private func presentCreateThread(parentThreadId: String?) {
        newThreadParentId = parentThreadId
        newThreadTitle = ""
        newThreadSummary = ""
        newThreadKindRaw = AdvisoryThreadKind.project.rawValue
        advisoryStatusMessage = nil
        showCreateThreadSheet = true
    }

    private func createThread() {
        guard let kind = AdvisoryThreadKind(rawValue: newThreadKindRaw) else { return }
        let title = newThreadTitle
        let summary = newThreadSummary
        let parentId = newThreadParentId
        let database = db
        let timeZone = dateSupport.timeZone
        showCreateThreadSheet = false
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let detail = try engine.createManualThread(
                    title: title,
                    kind: kind,
                    summary: summary,
                    parentThreadId: parentId
                )
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Сохранил thread «\(detail.thread.displayTitle)»."
                    loadAdvisory(preferredThreadId: detail.thread.id)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось создать thread: \(error.localizedDescription)"
                }
            }
        }
    }

    private func renameSelectedThread(to titleOverride: String?) {
        guard let threadId = selectedThreadId else { return }
        let database = db
        let timeZone = dateSupport.timeZone
        let override = titleOverride
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let detail = try engine.renameThread(threadId: threadId, userTitleOverride: override)
                let effectiveTitle = detail.thread.displayTitle
                DispatchQueue.main.async {
                    advisoryStatusMessage = override == nil
                        ? "Вернул canonical title для «\(effectiveTitle)»."
                        : "Обновил display title для «\(effectiveTitle)»."
                    loadAdvisory(preferredThreadId: detail.thread.id)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось обновить название: \(error.localizedDescription)"
                }
            }
        }
    }

    private func toggleSelectedThreadPinned() {
        guard let snapshot = selectedThreadDetail else { return }
        let threadId = snapshot.thread.id
        let newPinned = !snapshot.thread.userPinned
        let database = db
        let timeZone = dateSupport.timeZone
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let detail = try engine.setThreadPinned(threadId: threadId, isPinned: newPinned)
                DispatchQueue.main.async {
                    advisoryStatusMessage = detail.thread.userPinned
                        ? "Закрепил thread «\(detail.thread.displayTitle)»."
                        : "Снял pin с thread «\(detail.thread.displayTitle)»."
                    loadAdvisory(preferredThreadId: detail.thread.id)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось обновить pin: \(error.localizedDescription)"
                }
            }
        }
    }

    private func setSelectedThreadStatus(_ status: AdvisoryThreadStatus) {
        guard let snapshot = selectedThreadDetail else { return }
        let threadId = snapshot.thread.id
        let database = db
        let timeZone = dateSupport.timeZone
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let detail = try engine.setThreadStatus(threadId: threadId, status: status)
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Обновил status для «\(detail.thread.displayTitle)»: \(status.rawValue)."
                    loadAdvisory(preferredThreadId: detail.thread.id)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось обновить status: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyMaintenanceProposal(_ proposal: AdvisoryThreadMaintenanceProposal) {
        guard let snapshot = selectedThreadDetail else { return }
        let threadId = snapshot.thread.id
        let database = db
        let timeZone = dateSupport.timeZone
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let detail = try engine.applyThreadMaintenanceProposal(
                    threadId: threadId,
                    proposal: proposal
                )
                DispatchQueue.main.async {
                    advisoryStatusMessage = maintenanceSuccessMessage(for: proposal, detail: detail)
                    loadAdvisory(preferredThreadId: detail.thread.id)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось применить maintenance move: \(error.localizedDescription)"
                }
            }
        }
    }

    private func exportSelectedThread() {
        guard let snapshot = selectedThreadDetail else { return }
        let threadId = snapshot.thread.id
        let database = db
        let timeZone = dateSupport.timeZone
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let path = try engine.exportThreadToObsidian(threadId: threadId)
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Экспортировал thread в Obsidian: \(path)"
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось экспортировать thread: \(error.localizedDescription)"
                }
            }
        }
    }

    private func turnSelectedThreadIntoSignal() {
        guard let snapshot = selectedThreadDetail else { return }
        let threadId = snapshot.thread.id
        let displayTitle = snapshot.thread.displayTitle
        let date = selectedDate
        let database = db
        let timeZone = dateSupport.timeZone
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let artifacts = try engine.turnThreadIntoSignal(threadId: threadId, for: date)
                DispatchQueue.main.async {
                    if let surfaced = artifacts.first {
                        advisoryStatusMessage = "Собрал signal по нити «\(displayTitle)»: \(surfaced.title)"
                    } else {
                        advisoryStatusMessage = "Для этой нити пока не собрался writing signal."
                    }
                    loadAdvisory(preferredThreadId: threadId)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось собрать signal: \(error.localizedDescription)"
                }
            }
        }
    }

    private func generateWeeklyReview() {
        let date = selectedDate
        let preferredThread = selectedThreadId
        let database = db
        let timeZone = dateSupport.timeZone
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let artifact = try engine.generateWeeklyReview(for: date)
                DispatchQueue.main.async {
                    if let artifact {
                        advisoryStatusMessage = "Собрал weekly review: \(artifact.title)"
                    } else {
                        advisoryStatusMessage = "Для этой недели пока не хватает материала для weekly review."
                    }
                    loadAdvisory(preferredThreadId: preferredThread)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось собрать weekly review: \(error.localizedDescription)"
                }
            }
        }
    }

    private func runDomainAction(_ domain: AdvisoryDomain) {
        runningDomainAction = domain
        let date = selectedDate
        let preferredThread = selectedThreadId
        let database = db
        let timeZone = dateSupport.timeZone
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let artifact = try engine.generateDomainArtifact(for: date, domain: domain)
                DispatchQueue.main.async {
                    runningDomainAction = nil
                    selectedInboxDomain = domain
                    if let artifact {
                        advisoryStatusMessage = "Собрал \(domain.label.lowercased()) signal: \(artifact.title)"
                        loadAdvisory(preferredThreadId: artifact.threadId ?? preferredThread)
                    } else {
                        advisoryStatusMessage = "Для домена \(domain.label.lowercased()) сейчас не набралось достаточно grounded signal."
                        loadAdvisory(preferredThreadId: preferredThread)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    runningDomainAction = nil
                    advisoryStatusMessage = "Не удалось собрать \(domain.label.lowercased()) signal: \(error.localizedDescription)"
                }
            }
        }
    }

    private func applyArtifactFeedback(
        artifactId: String,
        kind: AdvisoryArtifactFeedbackKind
    ) {
        let preferredThread = selectedThreadId
        let database = db
        let timeZone = dateSupport.timeZone
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let artifact = try engine.applyFeedback(artifactId: artifactId, kind: kind)
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Feedback saved for «\(artifact.title)»: \(kind.label)."
                    loadAdvisory(preferredThreadId: artifact.threadId ?? preferredThread)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось сохранить feedback: \(error.localizedDescription)"
                }
            }
        }
    }

    private func materializeArtifactQuickAction(
        artifactId: String,
        action: AdvisoryArtifactQuickAction
    ) {
        let preferredThread = selectedThreadId
        let database = db
        let timeZone = dateSupport.timeZone
        let actionId = action.id
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = AdvisoryEngine(db: database, timeZone: timeZone)
            do {
                let outcome = try engine.materializeArtifactQuickAction(
                    artifactId: artifactId,
                    actionId: actionId
                )
                DispatchQueue.main.async {
                    advisoryStatusMessage = outcome.reusedExistingItem
                        ? "Обновил continuity item: «\(outcome.continuityItem.title)»."
                        : "Сохранил в continuity: «\(outcome.continuityItem.title)»."
                    loadAdvisory(preferredThreadId: outcome.continuityItem.threadId ?? outcome.action.threadId ?? preferredThread)
                }
            } catch {
                DispatchQueue.main.async {
                    advisoryStatusMessage = "Не удалось сохранить quick action: \(error.localizedDescription)"
                }
            }
        }
    }

    private func advisoryEngine() -> AdvisoryEngine {
        AdvisoryEngine(db: db, timeZone: dateSupport.timeZone)
    }

    private func maintenanceSuccessMessage(
        for proposal: AdvisoryThreadMaintenanceProposal,
        detail: AdvisoryThreadDetailSnapshot
    ) -> String {
        switch proposal.kind {
        case .statusChange:
            return "Обновил thread status для «\(detail.thread.displayTitle)»."
        case .reparentUnderThread:
            return "Сделал «\(detail.thread.displayTitle)» подпотоком."
        case .mergeIntoThread:
            return "Склеил thread в «\(detail.thread.displayTitle)»."
        case .splitIntoSubthread:
            return "Создал sub-thread внутри «\(detail.thread.displayTitle)»."
        }
    }

    private func threadKindLabel(_ kind: AdvisoryThreadKind) -> String {
        switch kind {
        case .project: return "project"
        case .question: return "question"
        case .interest: return "interest"
        case .person: return "person"
        case .commitment: return "commitment"
        case .theme: return "theme"
        }
    }

    private func artifactStatusRank(_ status: AdvisoryArtifactStatus) -> Int {
        switch status {
        case .surfaced: return 0
        case .accepted: return 1
        case .queued: return 2
        case .candidate: return 3
        case .dismissed: return 4
        case .expired: return 5
        case .muted: return 6
        }
    }
}

struct SessionRowView: View {
    let session: TimelineSession
    private let dateSupport = LocalDateSupport()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(session.appName).fontWeight(.medium)
                    if session.uncertaintyMode != "normal" {
                        Text("(\(session.uncertaintyMode))")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(formatTime(session.startedAt))–\(session.endedAt.map { formatTime($0) } ?? "ongoing")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ObsidianExporter.formatDuration(minutes: session.durationMinutes))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ iso: String) -> String {
        dateSupport.localTimeString(from: iso)
    }
}
