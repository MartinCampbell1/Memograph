import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger.app
    private let dateSupport = LocalDateSupport()
    private(set) var databaseManager: DatabaseManager?
    private var appMonitor: AppMonitor?
    private var windowMonitor: WindowMonitor?
    private var idleDetector: IdleDetector?
    private var sessionManager: SessionManager?
    private var captureEngine: ScreenCaptureEngine?
    private var imageProcessor: ImageProcessor?
    // Phase 2
    private var accessibilityEngine: AccessibilityContextEngine?
    private var ocrPipeline: OCRPipeline?
    private var policyEngine: CapturePolicyEngine?
    private var captureScheduler: CaptureScheduler?
    // Phase 3
    private var contextFusionEngine: ContextFusionEngine?
    private var dailySummarizer: DailySummarizer?
    private var obsidianExporter: ObsidianExporter?
    private var knowledgePipeline: KnowledgePipeline?
    // Phase 4
    private var retentionWorker: RetentionWorker?
    // Phase 5 — Vision + Audio
    private var visionAnalyzer: VisionAnalyzer?
    private var audioTranscriber: AudioTranscriber?
    private var audioCaptureEngine: AudioCaptureEngine?
    private var systemAudioEngine: SystemAudioCaptureEngine?
    private var retentionTimer: Timer?
    private var autoSummaryTimer: Timer?
    private var knowledgeMaintenanceTimer: Timer?
    private var captureHashTracker = CaptureHashTracker()
    private let captureGate = CaptureGate(maxConcurrent: 1)
    private var privacyGuard = PrivacyGuard.fromSettings()
    private var summaryWindowsInFlight = Set<String>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.applicationIconImage = AppIconArtwork.makeImage()

        if CommandLine.arguments.contains("--render-marketing-assets") {
            logger.info("Running marketing asset renderer")
            do {
                try MarketingAssetRenderer.run()
            } catch {
                logger.error("Marketing asset renderer failed: \(error.localizedDescription)")
                NSApp.terminate(nil)
                exit(1)
            }
            NSApp.terminate(nil)
            return
        }

        if let backfillArguments = parseBackfillWindowArguments() {
            logger.info("Running backfill window report renderer")
            initializeDatabase()
            initializePhase3()
            Task { @MainActor [weak self] in
                await self?.runBackfillWindowReport(arguments: backfillArguments)
            }
            return
        }

        if shouldRebuildKnowledgeGraph() {
            logger.info("Running knowledge graph rebuild")
            initializeDatabase()
            initializePhase3()
            Task { @MainActor [weak self] in
                await self?.runKnowledgeGraphRebuild()
            }
            return
        }

        if shouldApplyKnowledgeSafeActions() {
            logger.info("Running knowledge safe-action apply")
            initializeDatabase()
            initializePhase3()
            Task { @MainActor [weak self] in
                await self?.runKnowledgeSafeActionApply()
            }
            return
        }

        if shouldApplyKnowledgeReviewActions() {
            logger.info("Running knowledge review-action apply")
            initializeDatabase()
            initializePhase3()
            Task { @MainActor [weak self] in
                await self?.runKnowledgeReviewActionApply()
            }
            return
        }

        logger.info("MyMacAgent launched")
        registerObservers()
        initializeDatabase()
        initializeMonitors()
        initializePhase2()
        initializePhase3()
        initializePhase4()
        initializePhase5()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        autoSummaryTimer?.invalidate()
        autoSummaryTimer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
        knowledgeMaintenanceTimer?.invalidate()
        knowledgeMaintenanceTimer = nil
        captureScheduler?.stop()
        appMonitor?.stop()
        windowMonitor?.stop()
        idleDetector?.stop()
        audioCaptureEngine?.stop()
        systemAudioEngine?.stop()
        if let sessionId = sessionManager?.currentSessionId {
            try? sessionManager?.endSession(sessionId)
        }
        logger.info("MyMacAgent terminating")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return false }
        restorePrimaryWindows()
        return true
    }

    private func registerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSettingsChanged),
            name: .settingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeleteAllLocalData),
            name: .deleteAllLocalDataRequested,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    private func restorePrimaryWindows() {
        let candidateWindows = NSApp.windows.filter { window in
            !window.isVisible || window.isMiniaturized || !window.canBecomeKey
        }

        if candidateWindows.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in candidateWindows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func parseBackfillWindowArguments() -> (start: Date, end: Date)? {
        guard let flagIndex = CommandLine.arguments.firstIndex(of: "--generate-window-report"),
              CommandLine.arguments.count > flagIndex + 2 else {
            return nil
        }

        let parser = LocalDateSupport()
        guard let start = parser.parseDateTime(CommandLine.arguments[flagIndex + 1]),
              let end = parser.parseDateTime(CommandLine.arguments[flagIndex + 2]) else {
            return nil
        }

        return (start, end)
    }

    private func shouldRebuildKnowledgeGraph() -> Bool {
        CommandLine.arguments.contains("--rebuild-knowledge-graph")
    }

    private func shouldApplyKnowledgeSafeActions() -> Bool {
        CommandLine.arguments.contains("--apply-knowledge-safe-actions")
    }

    private func shouldApplyKnowledgeReviewActions() -> Bool {
        CommandLine.arguments.contains("--apply-knowledge-review-actions")
    }

    private func initializeDatabase() {
        do {
            let settings = AppSettings()
            try AppPaths.ensureBaseDirectories(settings: settings)
            let dbPath = AppPaths.databaseURL(settings: settings).path
            let db = try DatabaseManager(path: dbPath)
            let runner = MigrationRunner(db: db, migrations: [
                V001_InitialSchema.migration,
                V002_AudioTranscripts.migration,
                V003_PerformanceIndexes.migration,
                V004_AudioTranscriptDurability.migration,
                V005_KnowledgeGraph.migration
            ])
            try runner.runPending()
            databaseManager = db
            logger.info("Database initialized at \(dbPath)")
        } catch {
            logger.error("Database initialization failed: \(error.localizedDescription)")
        }
    }

    private func initializeMonitors() {
        guard let db = databaseManager else {
            logger.error("Cannot initialize monitors: database not ready")
            return
        }

        sessionManager = SessionManager(db: db)
        captureEngine = ScreenCaptureEngine()
        imageProcessor = ImageProcessor()

        let appMon = AppMonitor(db: db)
        appMon.delegate = self
        appMon.start()
        appMonitor = appMon

        let winMon = WindowMonitor(db: db)
        winMon.delegate = self
        windowMonitor = winMon

        let idle = IdleDetector()
        idle.delegate = self
        idle.start()
        idleDetector = idle

        logger.info("Monitors initialized")
    }

    private func initializePhase2() {
        guard let db = databaseManager else { return }

        accessibilityEngine = AccessibilityContextEngine()
        let ocrProvider = makeOCRProvider(settings: AppSettings())
        ocrPipeline = OCRPipeline(provider: ocrProvider, db: db)

        let policy = CapturePolicyEngine()
        policyEngine = policy

        let scheduler = CaptureScheduler(policyEngine: policy)
        scheduler.delegate = self
        scheduler.start()
        captureScheduler = scheduler

        logger.info("Phase 2 components initialized (AX, OCR, adaptive capture)")
    }

    private func initializePhase3() {
        guard let db = databaseManager else { return }
        contextFusionEngine = ContextFusionEngine()
        dailySummarizer = DailySummarizer(db: db)
        let vaultPath = AppSettings().obsidianVaultPath
        obsidianExporter = ObsidianExporter(db: db, vaultPath: vaultPath)
        knowledgePipeline = KnowledgePipeline(db: db)
        refreshKnowledgeAppliedActionHistory()
        refreshKnowledgeMergeOverlayHistory()
        refreshKnowledgeAliasOverrideHistory()
        logger.info("Phase 3 components initialized (fusion, summary, export)")
        performKnowledgeMaintenance(reason: "startup", force: true)
    }

    private func initializePhase4() {
        guard let db = databaseManager else { return }

        let settings = AppSettings()
        retentionWorker = RetentionWorker(db: db, retentionDays: settings.retentionDays)

        scheduleRetentionTimer()

        // Run once on startup
        try? retentionWorker?.runAll()

        scheduleAutoSummaryTimer()
        Task { @MainActor [weak self] in
            await self?.generatePendingDailySummaries(reason: "startup")
        }

        logger.info("Phase 4 initialized (retention, scheduled auto-summary)")
    }

    private func initializePhase5() {
        guard let db = databaseManager else { return }
        let transcriber = AudioTranscriber(db: db)
        try? transcriber.ensureTable()
        audioTranscriber = transcriber
        visionAnalyzer = VisionAnalyzer(db: db)
        configureAudioEngines(forceRestart: true)
        Task { @MainActor [weak self] in
            await self?.drainPendingAudioTranscriptions(reason: "startup")
        }

        logger.info("Phase 5 initialized (vision, mic audio, system audio)")
    }

    func toggleAudioCapture() {
        if let engine = audioCaptureEngine {
            if engine.recording {
                engine.stop()
            } else {
                engine.start()
            }
        }
    }

    var isAudioRecording: Bool { audioCaptureEngine?.recording ?? false }

    private func autoGenerateSummaryIfActive() {
        Task { @MainActor [weak self] in
            await self?.generatePendingDailySummaries(reason: "timer")
        }
    }

    private func performCapture(mode: UncertaintyMode) {
        // Global pause check
        guard !AppSettings().globalPause else { return }

        // Only attempt capture if we have Screen Recording permission
        guard CGPreflightScreenCaptureAccess() else {
            logger.info("Skipping capture: no screen recording permission")
            return
        }

        guard let appInfo = appMonitor?.currentAppInfo,
              let sessionManager, let sessionId = sessionManager.currentSessionId,
              let captureEngine, let imageProcessor, let db = databaseManager else { return }

        let currentWindowTitle = windowMonitor?.currentWindowTitle

        guard privacyGuard.shouldCapture(
            bundleId: appInfo.bundleId,
            windowTitle: currentWindowTitle
        ) else {
            logger.info("Skipping capture: blocked by privacy rules (\(appInfo.bundleId))")
            return
        }

        // Capture Phase 2 + Phase 3 components by value to avoid self capture across isolation boundary
        let axEngine = accessibilityEngine
        let ocrPipe = ocrPipeline
        let policy = policyEngine
        let scheduler = captureScheduler
        let fusionEngine = contextFusionEngine
        let pid = appInfo.pid
        let hashTracker = captureHashTracker
        let gate = captureGate
        let privGuard = privacyGuard

        Task {
            guard await gate.tryAcquire() else {
                Logger.capture.info("Skipping capture: previous still in progress")
                return
            }
            defer { Task { await gate.release() } }

            do {
                // 1. Take screenshot
                let captureResult = try await captureEngine.captureWindow(pid: pid)

                // 2. Compute hash and diff
                let hash = imageProcessor.visualHash(image: captureResult.image)
                let visualDiff: Double = hash.map {
                    hashTracker.computeDiff(currentHash: $0, sessionId: sessionId)
                } ?? 1.0

                // 3. Save to disk
                let captureDir = AppPaths.capturesDirectoryURL()
                try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
                let imagePath = try captureEngine.saveToDisk(result: captureResult, directory: captureDir.path)
                let fileSizeBytes = captureFileSize(atPath: imagePath)

                // 4. Persist capture record
                let captureId = UUID().uuidString
                let now = ISO8601DateFormatter().string(from: Date())
                try db.execute("""
                    INSERT INTO captures (id, session_id, timestamp, capture_type, image_path,
                        width, height, file_size_bytes, visual_hash, diff_score, sampling_mode)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, params: [
                    .text(captureId), .text(sessionId), .text(now),
                    .text("window"), .text(imagePath),
                    .integer(Int64(captureResult.width)), .integer(Int64(captureResult.height)),
                    .integer(fileSizeBytes),
                    hash.map { .text($0) } ?? .null,
                    .real(visualDiff),
                    .text(mode.rawValue)
                ])

                try sessionManager.recordEvent(sessionId: sessionId, type: .captureTaken, payload: nil)

                // 5. AX snapshot
                var axTextLen = 0
                var axSnapshot: AXSnapshotRecord?
                if let axEngine {
                    if let snapshot = axEngine.extract(pid: pid, sessionId: sessionId, captureId: captureId) {
                        try axEngine.persist(snapshot: snapshot, db: db)
                        axTextLen = snapshot.textLen
                        axSnapshot = snapshot
                        try sessionManager.recordEvent(sessionId: sessionId, type: .axSnapshotTaken, payload: nil)
                    }
                }

                // 6. OCR (if policy says to)
                var ocrConfidence = 0.0
                var ocrTextLen = 0
                var ocrSnapshot: OCRSnapshotRecord?

                if let policy, policy.shouldRunOCR(visualDiffScore: visualDiff, mode: mode),
                   privGuard.shouldOCR(bundleId: appInfo.bundleId) {
                    try sessionManager.recordEvent(sessionId: sessionId, type: .ocrRequested, payload: nil)
                    if let ocrPipe {
                        let ocrResult = try await ocrPipe.process(
                            image: captureResult.image, captureId: captureId, sessionId: sessionId
                        )
                        ocrConfidence = ocrResult.confidence
                        ocrTextLen = ocrResult.normalizedText?.count ?? 0
                        ocrSnapshot = ocrResult
                        try sessionManager.recordEvent(sessionId: sessionId, type: .ocrCompleted, payload: nil)
                    }
                }

                // 6.5 Context fusion
                if let fusionEngine, let db = databaseManager {
                    let readScore = ReadabilityScorer.score(ReadabilityInput(
                        axTextLen: axTextLen, ocrConfidence: ocrConfidence, ocrTextLen: ocrTextLen,
                        visualChangeScore: visualDiff, isCanvasLike: false
                    ))
                    let ctxSnapshot = fusionEngine.fuse(
                        sessionId: sessionId, captureId: captureId,
                        appName: appInfo.appName, bundleId: appInfo.bundleId,
                        windowTitle: currentWindowTitle,
                        ax: axSnapshot, ocr: ocrSnapshot,
                        readableScore: readScore, uncertaintyScore: 1.0 - readScore
                    )
                    try fusionEngine.persist(snapshot: ctxSnapshot, db: db)
                }

                // 7. Update readability score and mode
                let readabilityInput = ReadabilityInput(
                    axTextLen: axTextLen, ocrConfidence: ocrConfidence, ocrTextLen: ocrTextLen,
                    visualChangeScore: visualDiff, isCanvasLike: false
                )
                scheduler?.updateReadability(readabilityInput)

                // 8. Update session uncertainty mode if changed
                if let scheduler {
                    try sessionManager.updateUncertaintyMode(sessionId: sessionId, mode: scheduler.currentMode)
                }

            } catch {
                Logger.app.error("Capture failed: \(error.localizedDescription)")
            }
        }
    }

    func generateDailySummary(for date: String, apiKey: String? = nil) {
        Task { @MainActor in
            await runDailySummary(for: date, apiKey: apiKey)
        }
    }

    private func runDailySummary(for date: String, apiKey: String? = nil) async {
        guard let summarizer = dailySummarizer else {
            logger.error("Daily summary failed: summarizer is not initialized")
            return
        }

        guard let window = try? summarizer.summaryWindow(for: date) else {
            logger.error("Daily summary failed: could not derive window for \(date)")
            return
        }

        await runDailySummary(for: window, apiKey: apiKey)
    }

    private func runDailySummary(for window: SummaryWindowDescriptor, apiKey: String? = nil) async {
        let windowKey = summaryWindowKey(for: window)
        guard !summaryWindowsInFlight.contains(windowKey) else {
            logger.info("Skipping summary generation for \(windowKey): already running")
            return
        }

        summaryWindowsInFlight.insert(windowKey)
        defer { summaryWindowsInFlight.remove(windowKey) }

        guard let summarizer = dailySummarizer else {
            logger.error("Daily summary failed: summarizer is not initialized")
            return
        }

        await drainPendingAudioTranscriptions(reason: "summary")

        if let analyzer = visionAnalyzer {
            do {
                let count = try await analyzer.analyzeAllLowReadability(in: window)
                if count > 0 {
                    logger.info("Analyzed \(count) low-readability screenshots before summary")
                }
            } catch {
                logger.error("Vision pre-pass failed for \(window.date): \(error.localizedDescription)")
            }
        }

        let settings = AppSettings()
        let summary: DailySummaryRecord

        do {
            if let client = LLMClient.client(for: settings, apiKeyOverride: apiKey) {
                summary = try await summarizer.summarize(for: window, using: client)
            } else {
                logger.info("No summary provider configured for \(windowKey), writing local fallback report")
                summary = try summarizer.buildFallbackSummary(
                    for: window,
                    failureReason: "No configured summary provider"
                )
            }
        } catch {
            let sanitizedReason = sanitizedSummaryFailureReason(for: error)
            logger.error("Daily summary model step failed for \(windowKey): \(sanitizedReason, privacy: .public)")
            do {
                summary = try summarizer.buildFallbackSummary(
                    for: window,
                    failureReason: sanitizedReason
                )
            } catch {
                logger.error("Daily summary failed: \(error.localizedDescription)")
                return
            }
        }

        if let exporter = obsidianExporter {
            do {
                let path = try exporter.exportDailyNote(summary: summary)
                logger.info("Daily note exported to \(path)")
            } catch {
                logger.error("Daily summary export failed for \(windowKey): \(error.localizedDescription)")
                do {
                    try exporter.enqueueSummaryExport(summary, lastError: error.localizedDescription)
                } catch {
                    logger.error("Failed to enqueue summary export retry for \(windowKey): \(error.localizedDescription)")
                }
            }
        }

        do {
            let sessions = try summarizer.collectSessionData(for: window)
            if let knowledgePipeline {
                let result = try knowledgePipeline.process(
                    summary: summary,
                    window: window,
                    sessions: sessions,
                    exporter: obsidianExporter
                )
                if result.entityCount > 0 || result.noteCount > 0 {
                    logger.info("Knowledge graph updated for \(windowKey): \(result.entityCount) entities, \(result.noteCount) notes")
                }
            }
        } catch {
            logger.error("Knowledge graph update failed for \(windowKey): \(error.localizedDescription)")
        }

        scheduleAutoSummaryTimer()
    }

    private func generatePendingDailySummaries(reason: String) async {
        let settings = AppSettings()
        drainPendingSummaryExports(reason: reason)
        await drainPendingAudioTranscriptions(reason: reason)

        guard settings.resolvedSummaryProvider != .disabled else {
            logger.info("Skipping auto-summary: summary provider is disabled")
            return
        }
        guard let summarizer = dailySummarizer else { return }

        let today = dateSupport.currentLocalDateString()
        let lookbackDays = max(2, min(settings.retentionDays, 30))
        let dates = stride(from: lookbackDays - 1, through: 0, by: -1)
            .compactMap { dateSupport.offsetLocalDateString(today, by: -$0) }

        for date in dates {
            do {
                let windows = try summarizer.pendingSummaryWindows(
                    for: date,
                    currentLocalDate: today,
                    minimumIntervalMinutes: settings.summaryIntervalMinutes
                )

                for window in windows {
                    logger.info("Auto-summary catch-up (\(reason, privacy: .public)) for \(window.date) [\(self.dateSupport.localTimeString(from: window.start))-\(self.dateSupport.localTimeString(from: window.end))]")
                    await runDailySummary(for: window, apiKey: settings.externalAPIKey)
                }
            } catch {
                logger.error("Failed to evaluate summary schedule for \(date): \(error.localizedDescription)")
            }
        }
    }

    private func runBackfillWindowReport(arguments: (start: Date, end: Date)) async {
        defer {
            NSApp.terminate(nil)
        }

        guard let summarizer = dailySummarizer else {
            logger.error("Backfill window report failed: summarizer is not initialized")
            return
        }

        let settings = AppSettings()
        let localDate = dateSupport.localDateString(from: arguments.start)
        let window = summarizer.summaryWindow(for: localDate, start: arguments.start, end: arguments.end)
        let summary: DailySummaryRecord

        do {
            if let client = LLMClient.client(for: settings) {
                summary = try await summarizer.summarize(for: window, using: client, persist: false)
            } else {
                summary = try summarizer.buildFallbackSummary(
                    for: window,
                    failureReason: "No configured summary provider",
                    persist: false
                )
            }
        } catch {
            let sanitizedReason = sanitizedSummaryFailureReason(for: error)
            logger.error("Backfill model step failed for \(localDate): \(sanitizedReason, privacy: .public)")
            do {
                summary = try summarizer.buildFallbackSummary(
                    for: window,
                    failureReason: sanitizedReason,
                    persist: false
                )
            } catch {
                logger.error("Backfill fallback failed: \(error.localizedDescription)")
                return
            }
        }

        guard let exporter = obsidianExporter else {
            logger.error("Backfill export failed: exporter is not initialized")
            return
        }

        do {
            let path = try exporter.exportDailyNote(summary: summary)
            logger.info("Backfill window report exported to \(path)")
            let sessions = try summarizer.collectSessionData(for: window)
            if let knowledgePipeline {
                _ = try knowledgePipeline.process(
                    summary: summary,
                    window: window,
                    sessions: sessions,
                    exporter: exporter
                )
            }
            print(path)
        } catch {
            logger.error("Backfill export failed: \(error.localizedDescription)")
        }
    }

    private func runKnowledgeGraphRebuild() async {
        defer {
            NSApp.terminate(nil)
        }

        guard let db = databaseManager,
              let summarizer = dailySummarizer,
              let knowledgePipeline else {
            logger.error("Knowledge graph rebuild failed: phase 3 is not initialized")
            return
        }

        do {
            try knowledgePipeline.resetKnowledgeStore(exporter: obsidianExporter)

            let rows = try db.query("""
                SELECT *
                FROM daily_summaries
                ORDER BY COALESCE(generated_at, date), date
            """)

            var rebuiltWindows = 0
            for row in rows {
                guard let summary = DailySummaryRecord(row: row),
                      let window = summaryWindowDescriptor(from: summary) else {
                    continue
                }

                let sessions = try summarizer.collectSessionData(for: window)
                _ = try knowledgePipeline.process(
                    summary: summary,
                    window: window,
                    sessions: sessions,
                    exporter: nil,
                    materialize: false
                )
                rebuiltWindows += 1
            }

            let materializedCount = try knowledgePipeline.syncMaterializedKnowledge(exporter: obsidianExporter)
            logger.info("Knowledge graph rebuild finished: \(rebuiltWindows) windows, \(materializedCount) notes")
        } catch {
            logger.error("Knowledge graph rebuild failed: \(error.localizedDescription)")
        }
    }

    private func runKnowledgeSafeActionApply() async {
        defer {
            NSApp.terminate(nil)
        }

        guard let exporter = obsidianExporter,
              let knowledgePipeline else {
            logger.error("Knowledge safe-action apply failed: phase 3 is not initialized")
            return
        }

        do {
            let maintenanceArtifacts = try knowledgePipeline.buildMaintenanceArtifacts()
            let applyableArtifacts = maintenanceArtifacts.draftArtifacts.filter { $0.applyTargetRelativePath != nil }
            let mergeOverlayRecords = maintenanceArtifacts.draftArtifacts.compactMap {
                buildKnowledgeMergeOverlayRecord(from: $0, appliedAt: dateSupport.isoString(from: Date()))
            }
            guard !applyableArtifacts.isEmpty else {
                if !mergeOverlayRecords.isEmpty {
                    var settings = AppSettings()
                    let mergedSuppressedIds = Set(settings.knowledgeSuppressedEntityIds)
                        .union(maintenanceArtifacts.draftArtifacts.compactMap(\.suppressedEntityId))
                    settings.knowledgeSuppressedEntityIds = Array(mergedSuppressedIds).sorted()
                    settings.knowledgeMergeOverlays = mergedKnowledgeMergeOverlays(
                        existing: settings.knowledgeMergeOverlays,
                        incoming: mergeOverlayRecords
                    )
                    let mergeAppliedActions = mergeOverlayRecords.map(buildAppliedMergeActionRecord(from:))
                    settings.knowledgeAppliedActions = mergedKnowledgeAppliedActions(
                        existing: settings.knowledgeAppliedActions,
                        incoming: mergeAppliedActions
                    )
                    settings.knowledgeAliasOverrides = derivedKnowledgeAliasOverrides(from: settings)
                    rebuildKnowledgePipeline()
                    let activeKnowledgePipeline = self.knowledgePipeline ?? knowledgePipeline
                    _ = try? exporter.exportKnowledgeAppliedHistory(settings.knowledgeAppliedActions)
                    let materializedCount = try activeKnowledgePipeline.syncMaterializedKnowledge(exporter: exporter)
                    logger.info("Knowledge safe-action apply finished: \(mergeOverlayRecords.count) merge overlays applied, \(materializedCount) notes materialized")
                    for overlay in mergeOverlayRecords {
                        print(overlay.targetRelativePath)
                    }
                    return
                }

                logger.info("Knowledge safe-action apply skipped: no applyable drafts")
                print("No safe knowledge actions to apply.")
                return
            }

            var settings = AppSettings()
            let mergedSuppressedIds = Set(settings.knowledgeSuppressedEntityIds)
                .union(maintenanceArtifacts.draftArtifacts.compactMap(\.suppressedEntityId))
            settings.knowledgeSuppressedEntityIds = Array(mergedSuppressedIds).sorted()
            settings.knowledgeMergeOverlays = mergedKnowledgeMergeOverlays(
                existing: settings.knowledgeMergeOverlays,
                incoming: mergeOverlayRecords
            )

            _ = try knowledgePipeline.syncMaterializedKnowledge(exporter: exporter)
            let applyResults = try exporter.applyKnowledgeDraftArtifacts(applyableArtifacts)

            let appliedAt = dateSupport.isoString(from: Date())
            let appliedDraftRecords = applyResults.compactMap { buildAppliedActionRecord(from: $0, appliedAt: appliedAt) }
            let mergeAppliedActions = mergeOverlayRecords.map(buildAppliedMergeActionRecord(from:))
            let newRecords = appliedDraftRecords + mergeAppliedActions
            settings.knowledgeAppliedActions = mergedKnowledgeAppliedActions(
                existing: settings.knowledgeAppliedActions,
                incoming: newRecords
            )
            settings.knowledgeAliasOverrides = derivedKnowledgeAliasOverrides(from: settings)
            rebuildKnowledgePipeline()
            let activeKnowledgePipeline = self.knowledgePipeline ?? knowledgePipeline
            _ = try? exporter.exportKnowledgeAppliedHistory(settings.knowledgeAppliedActions)

            let materializedCount = try activeKnowledgePipeline.syncMaterializedKnowledge(exporter: exporter)
            logger.info("Knowledge safe-action apply finished: \(applyResults.count) files applied, \(mergeOverlayRecords.count) merge overlays stored, \(materializedCount) notes materialized")
            for result in applyResults {
                print(result.appliedPath)
            }
        } catch {
            logger.error("Knowledge safe-action apply failed: \(error.localizedDescription)")
        }
    }

    private func runKnowledgeReviewActionApply() async {
        defer {
            NSApp.terminate(nil)
        }

        guard let exporter = obsidianExporter,
              let knowledgePipeline else {
            logger.error("Knowledge review-action apply failed: phase 3 is not initialized")
            return
        }

        do {
            let approvedDecisions = exporter.discoverApprovedKnowledgeReviewDecisions()
            guard !approvedDecisions.isEmpty else {
                logger.info("Knowledge review-action apply skipped: no approved review decisions")
                print("No approved knowledge review decisions found.")
                return
            }

            let maintenanceArtifacts = try knowledgePipeline.buildMaintenanceArtifacts()
            let decisionsByKey = Dictionary(uniqueKeysWithValues: approvedDecisions.map { ($0.key, $0) })
            let selectedArtifacts = maintenanceArtifacts.draftArtifacts.filter { artifact in
                guard let reviewPacketKey = artifact.reviewPacketKey,
                      let reviewDecisionKind = artifact.reviewDecisionKind,
                      let decision = decisionsByKey[reviewPacketKey],
                      decision.kind == reviewDecisionKind else {
                    return false
                }
                return artifact.applyTargetRelativePath != nil || artifact.mergeOverlayDraft != nil
            }

            guard !selectedArtifacts.isEmpty else {
                logger.info("Knowledge review-action apply skipped: approved decisions had no actionable artifacts")
                print("No actionable knowledge review decisions found.")
                return
            }

            var settings = AppSettings()
            let mergedSuppressedIds = Set(settings.knowledgeSuppressedEntityIds)
                .union(selectedArtifacts.compactMap(\.suppressedEntityId))
            settings.knowledgeSuppressedEntityIds = Array(mergedSuppressedIds).sorted()

            let appliedAt = dateSupport.isoString(from: Date())
            let mergeOverlayRecords = selectedArtifacts.compactMap {
                buildKnowledgeMergeOverlayRecord(from: $0, appliedAt: appliedAt)
            }
            settings.knowledgeMergeOverlays = mergedKnowledgeMergeOverlays(
                existing: settings.knowledgeMergeOverlays,
                incoming: mergeOverlayRecords
            )

            _ = try knowledgePipeline.syncMaterializedKnowledge(exporter: exporter)
            let applyResults = try exporter.applyKnowledgeDraftArtifacts(selectedArtifacts)
            let appliedDraftRecords = applyResults.compactMap { buildAppliedActionRecord(from: $0, appliedAt: appliedAt) }
            let mergeAppliedActions = mergeOverlayRecords.map(buildAppliedMergeActionRecord(from:))
            settings.knowledgeAppliedActions = mergedKnowledgeAppliedActions(
                existing: settings.knowledgeAppliedActions,
                incoming: appliedDraftRecords + mergeAppliedActions
            )
            settings.knowledgeAliasOverrides = derivedKnowledgeAliasOverrides(from: settings)
            rebuildKnowledgePipeline()
            let activeKnowledgePipeline = self.knowledgePipeline ?? knowledgePipeline
            _ = try? exporter.exportKnowledgeAppliedHistory(settings.knowledgeAppliedActions)

            let materializedCount = try activeKnowledgePipeline.syncMaterializedKnowledge(exporter: exporter)
            logger.info("Knowledge review-action apply finished: \(approvedDecisions.count) approved decisions, \(applyResults.count) files applied, \(mergeOverlayRecords.count) merge overlays stored, \(materializedCount) notes materialized")
            for result in applyResults {
                print(result.appliedPath)
            }
        } catch {
            logger.error("Knowledge review-action apply failed: \(error.localizedDescription)")
        }
    }

    private func refreshKnowledgeAppliedActionHistory() {
        guard let exporter = obsidianExporter else { return }
        var settings = AppSettings()
        let discovered = exporter.discoverAppliedKnowledgeActions(existing: settings.knowledgeAppliedActions)
        guard discovered != settings.knowledgeAppliedActions else {
            _ = try? exporter.exportKnowledgeAppliedHistory(discovered)
            return
        }
        settings.knowledgeAppliedActions = discovered
        _ = try? exporter.exportKnowledgeAppliedHistory(discovered)
    }

    private func refreshKnowledgeMergeOverlayHistory() {
        guard let exporter = obsidianExporter else { return }
        var settings = AppSettings()
        let discovered = exporter.discoverKnowledgeMergeOverlays(
            existing: settings.knowledgeMergeOverlays,
            appliedActions: settings.knowledgeAppliedActions
        )
        let mergeAppliedActions = discovered.map(buildAppliedMergeActionRecord(from:))
        let nonMergeAppliedActions = settings.knowledgeAppliedActions.filter { $0.kind != .mergeOverlay }
        let mergedAppliedActions = mergedKnowledgeAppliedActions(
            existing: nonMergeAppliedActions,
            incoming: mergeAppliedActions
        )
        let overlaysChanged = discovered != settings.knowledgeMergeOverlays
        let appliedChanged = mergedAppliedActions != settings.knowledgeAppliedActions
        guard overlaysChanged || appliedChanged else { return }
        settings.knowledgeMergeOverlays = discovered
        settings.knowledgeAppliedActions = mergedAppliedActions
        _ = try? exporter.exportKnowledgeAppliedHistory(mergedAppliedActions)
    }

    private func refreshKnowledgeAliasOverrideHistory() {
        var settings = AppSettings()
        let derived = derivedKnowledgeAliasOverrides(from: settings)
        guard derived != settings.knowledgeAliasOverrides else { return }
        settings.knowledgeAliasOverrides = derived
        rebuildKnowledgePipeline()
    }

    private func buildAppliedActionRecord(
        from result: AppliedKnowledgeDraftResult,
        appliedAt: String
    ) -> KnowledgeAppliedActionRecord? {
        guard let applyTargetRelativePath = result.artifact.applyTargetRelativePath else {
            return nil
        }
        let kind: KnowledgeAppliedActionKind
        switch result.artifact.kind {
        case .applyReadyLesson:
            kind = .lessonPromotion
        case .applyReadyLessonRedirect:
            kind = .lessonRedirect
        case .applyReadyRedirect:
            kind = .redirect
        default:
            return nil
        }

        return KnowledgeAppliedActionRecord(
            appliedAt: appliedAt,
            kind: kind,
            title: result.artifact.title,
            sourceEntityId: result.artifact.suppressedEntityId,
            applyTargetRelativePath: applyTargetRelativePath,
            appliedPath: result.appliedPath,
            backupPath: result.backupPath
        )
    }

    private func buildKnowledgeMergeOverlayRecord(
        from artifact: KnowledgeDraftArtifact,
        appliedAt: String
    ) -> KnowledgeMergeOverlayRecord? {
        guard let draft = artifact.mergeOverlayDraft else { return nil }
        return KnowledgeMergeOverlayRecord(
            appliedAt: appliedAt,
            sourceEntityId: draft.sourceEntityId,
            sourceTitle: draft.sourceTitle,
            sourceAliases: draft.sourceAliases,
            sourceOverview: draft.sourceOverview,
            preservedSignals: draft.preservedSignals,
            targetEntityId: draft.targetEntityId,
            targetTitle: draft.targetTitle,
            targetRelativePath: draft.targetRelativePath
        )
    }

    private func buildAppliedMergeActionRecord(from overlay: KnowledgeMergeOverlayRecord) -> KnowledgeAppliedActionRecord {
        KnowledgeAppliedActionRecord(
            id: KnowledgeMergeOverlayRecord.stableID(
                sourceEntityId: overlay.sourceEntityId,
                targetEntityId: overlay.targetEntityId
            ),
            appliedAt: overlay.appliedAt,
            kind: .mergeOverlay,
            title: overlay.sourceTitle,
            sourceEntityId: overlay.sourceEntityId,
            applyTargetRelativePath: overlay.targetRelativePath,
            appliedPath: (AppSettings().obsidianVaultPath as NSString)
                .appendingPathComponent("Knowledge/\(overlay.targetRelativePath)"),
            targetTitle: overlay.targetTitle
        )
    }

    private func mergedKnowledgeAppliedActions(
        existing: [KnowledgeAppliedActionRecord],
        incoming: [KnowledgeAppliedActionRecord]
    ) -> [KnowledgeAppliedActionRecord] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for record in incoming {
            byId[record.id] = record
        }
        return byId.values.sorted { lhs, rhs in
            if lhs.appliedAt != rhs.appliedAt {
                return lhs.appliedAt < rhs.appliedAt
            }
            return lhs.id < rhs.id
        }
    }

    private func mergedKnowledgeMergeOverlays(
        existing: [KnowledgeMergeOverlayRecord],
        incoming: [KnowledgeMergeOverlayRecord]
    ) -> [KnowledgeMergeOverlayRecord] {
        var byId = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for overlay in incoming {
            byId[overlay.id] = overlay
        }
        return byId.values.sorted { lhs, rhs in
            if lhs.appliedAt != rhs.appliedAt {
                return lhs.appliedAt < rhs.appliedAt
            }
            return lhs.id < rhs.id
        }
    }

    private func derivedKnowledgeAliasOverrides(from settings: AppSettings) -> [KnowledgeAliasOverrideRecord] {
        var byId: [String: KnowledgeAliasOverrideRecord] = [:]

        for action in settings.knowledgeAppliedActions where action.kind == .lessonPromotion || action.kind == .lessonRedirect {
            let record = KnowledgeAliasOverrideRecord(
                sourceName: action.title,
                canonicalName: action.title,
                entityType: .lesson,
                reason: action.kind == .lessonPromotion ? "lessonPromotion" : "lessonRedirect",
                appliedAt: action.appliedAt
            )
            byId[record.id] = record
        }

        for overlay in settings.knowledgeMergeOverlays {
            guard let entityType = knowledgeEntityType(for: overlay.targetRelativePath) else { continue }
            for alias in Set([overlay.sourceTitle] + overlay.sourceAliases) {
                let record = KnowledgeAliasOverrideRecord(
                    sourceName: alias,
                    canonicalName: overlay.targetTitle,
                    entityType: entityType,
                    reason: "mergeOverlay",
                    appliedAt: overlay.appliedAt
                )
                byId[record.id] = record
            }
        }

        return byId.values.sorted { lhs, rhs in
            if lhs.appliedAt != rhs.appliedAt {
                return lhs.appliedAt < rhs.appliedAt
            }
            return lhs.id < rhs.id
        }
    }

    private func knowledgeEntityType(for relativePath: String) -> KnowledgeEntityType? {
        let folder = (relativePath as NSString).pathComponents.first ?? ""
        switch folder {
        case "Projects": return .project
        case "Tools": return .tool
        case "Models": return .model
        case "Topics": return .topic
        case "Sites": return .site
        case "People": return .person
        case "Issues": return .issue
        case "Lessons": return .lesson
        default: return nil
        }
    }

    private func rebuildKnowledgePipeline() {
        guard let db = databaseManager else { return }
        knowledgePipeline = KnowledgePipeline(db: db)
    }

    private func summaryWindowDescriptor(from summary: DailySummaryRecord) -> SummaryWindowDescriptor? {
        if let json = summary.contextSwitchesJson,
           let data = json.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let startString = object["window_start"] as? String,
           let endString = object["window_end"] as? String,
           let start = dateSupport.parseDateTime(startString),
           let end = dateSupport.parseDateTime(endString),
           end > start {
            return SummaryWindowDescriptor(date: summary.date, start: start, end: end)
        }

        guard let start = dateSupport.startOfLocalDay(for: summary.date),
              let end = dateSupport.endOfLocalDay(for: summary.date),
              end > start else {
            return nil
        }

        return SummaryWindowDescriptor(date: summary.date, start: start, end: end)
    }

    private func scheduleRetentionTimer() {
        retentionTimer?.invalidate()
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? self?.retentionWorker?.runAll()
            }
        }
    }

    private func scheduleAutoSummaryTimer() {
        autoSummaryTimer?.invalidate()
        let minutes = max(15, AppSettings().summaryIntervalMinutes)
        let interval = TimeInterval(minutes * 60)

        let delay = nextAutoSummaryDelay(interval: interval)
        autoSummaryTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoGenerateSummaryIfActive()
                self?.scheduleAutoSummaryTimer()
            }
        }
        autoSummaryTimer?.tolerance = min(60, max(5, delay * 0.1))
        logger.info("Auto-summary timer scheduled in \(Int(delay))s (interval \(minutes) minutes)")
    }

    private func nextAutoSummaryDelay(interval: TimeInterval) -> TimeInterval {
        let minimumDelay: TimeInterval = 5
        guard let summarizer = dailySummarizer else {
            return interval
        }

        do {
            let today = dateSupport.currentLocalDateString()
            let pendingWindows = try summarizer.pendingSummaryWindows(
                for: today,
                currentLocalDate: today,
                minimumIntervalMinutes: Int(interval / 60)
            )
            if !pendingWindows.isEmpty {
                return minimumDelay
            }

            if let coveredUntil = try summarizer.coveredUntil(for: today) {
                let dueAt = coveredUntil.addingTimeInterval(interval)
                return max(minimumDelay, dueAt.timeIntervalSinceNow)
            }

            if let startOfDay = dateSupport.startOfLocalDay(for: today) {
                let dueAt = startOfDay.addingTimeInterval(interval)
                return max(minimumDelay, dueAt.timeIntervalSinceNow)
            }
        } catch {
            logger.error("Failed to compute next auto-summary delay: \(error.localizedDescription)")
        }

        return interval
    }

    private func summaryWindowKey(for window: SummaryWindowDescriptor) -> String {
        [
            window.date,
            dateSupport.isoString(from: window.start),
            dateSupport.isoString(from: window.end)
        ].joined(separator: "|")
    }

    private func captureFileSize(atPath path: String) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func drainPendingSummaryExports(reason: String) {
        guard let exporter = obsidianExporter else { return }

        do {
            let drained = try exporter.drainQueuedExports()
            if drained > 0 {
                logger.info("Drained \(drained) queued Obsidian exports during \(reason, privacy: .public)")
            }

            let cleaned = try exporter.cleanupSyncQueueHistory()
            if cleaned > 0 {
                logger.info("Pruned \(cleaned) old sync queue rows during \(reason, privacy: .public)")
            }
        } catch {
            logger.error("Failed to drain queued Obsidian exports during \(reason): \(error.localizedDescription)")
        }
    }

    private func drainPendingAudioTranscriptions(reason: String) async {
        guard let transcriber = audioTranscriber else { return }

        do {
            let drained = try await transcriber.drainQueuedTranscriptions()
            if drained > 0 {
                logger.info("Drained \(drained) queued audio transcription job(s) during \(reason, privacy: .public)")
            }
        } catch {
            logger.error("Failed to drain queued audio transcriptions during \(reason): \(error.localizedDescription)")
        }
    }

    private func sanitizedSummaryFailureReason(for error: Error) -> String {
        guard let llmError = error as? LLMError else {
            return error.localizedDescription
        }

        switch llmError {
        case .httpError(let statusCode, _):
            return "HTTP \(statusCode)"
        case .invalidResponse:
            return "Invalid HTTP response"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .noApiKey:
            return "No API key configured"
        }
    }

    private func makeOCRProvider(settings: AppSettings) -> any OCRProvider {
        let ollamaProvider = OllamaOCRProvider(
            modelName: settings.ollamaModelName,
            baseURL: settings.ollamaBaseURL
        )
        let visionProvider = VisionOCRProvider()

        switch settings.ocrProvider {
        case .ollamaWithVisionFallback:
            return FallbackOCRProvider(primary: ollamaProvider, fallback: visionProvider)
        case .ollamaOnly:
            return ollamaProvider
        case .visionOnly:
            return visionProvider
        }
    }

    private func configureAudioEngines(forceRestart: Bool) {
        guard let sessionMgr = sessionManager,
              let transcriber = audioTranscriber else { return }

        let settings = AppSettings()
        if forceRestart {
            audioCaptureEngine?.stop()
            audioCaptureEngine = nil
            systemAudioEngine?.stop()
            systemAudioEngine = nil
        }

        let runtimeStatus = AudioRuntimeResolver.resolve(settings: settings)
        logger.info("Audio runtime: \(runtimeStatus.description)")

        if settings.microphoneCaptureEnabled && audioCaptureEngine == nil {
            let audioEngine = AudioCaptureEngine(
                transcriber: transcriber,
                sessionManager: sessionMgr,
                audioDir: AppPaths.audioDirectoryURL(settings: settings).path
            )
            audioEngine.start()
            audioCaptureEngine = audioEngine
        }

        if settings.resolvedSystemAudioCaptureEnabled && systemAudioEngine == nil {
            let systemAudio = SystemAudioCaptureEngine(
                transcriber: transcriber,
                sessionManager: sessionMgr,
                audioDir: AppPaths.systemAudioDirectoryURL(settings: settings).path
            )
            Task { await systemAudio.start() }
            systemAudioEngine = systemAudio
        }
    }

    @objc
    private func handleSettingsChanged() {
        let settings = AppSettings()
        privacyGuard = PrivacyGuard.fromSettings(settings)

        if let db = databaseManager {
            retentionWorker = RetentionWorker(db: db, retentionDays: settings.retentionDays)
            obsidianExporter = ObsidianExporter(db: db, vaultPath: settings.obsidianVaultPath)
            ocrPipeline = OCRPipeline(provider: makeOCRProvider(settings: settings), db: db)
            knowledgePipeline = KnowledgePipeline(db: db)
        }

        scheduleAutoSummaryTimer()
        performKnowledgeMaintenance(reason: "settings", force: true)
        configureAudioEngines(forceRestart: true)
        Task { @MainActor [weak self] in
            await self?.generatePendingDailySummaries(reason: "settings")
        }
    }

    @objc
    private func handleDeleteAllLocalData() {
        let settings = AppSettings()

        autoSummaryTimer?.invalidate()
        autoSummaryTimer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
        knowledgeMaintenanceTimer?.invalidate()
        knowledgeMaintenanceTimer = nil
        captureScheduler?.stop()
        appMonitor?.stop()
        windowMonitor?.stop()
        idleDetector?.stop()
        audioCaptureEngine?.stop()
        systemAudioEngine?.stop()

        audioCaptureEngine = nil
        systemAudioEngine = nil
        dailySummarizer = nil
        obsidianExporter = nil
        knowledgePipeline = nil
        visionAnalyzer = nil
        databaseManager = nil

        do {
            try AppPaths.removeAllLocalData(settings: settings)
            logger.info("Deleted all local data at \(settings.dataDirectoryPath)")
        } catch {
            logger.error("Failed to delete local data: \(error.localizedDescription)")
        }

        initializeDatabase()
        initializeMonitors()
        initializePhase2()
        initializePhase3()
        initializePhase4()
        initializePhase5()
    }

    @objc
    private func handleApplicationDidBecomeActive() {
        runKnowledgeMaintenanceIfDue(reason: "activation")
        Task { @MainActor [weak self] in
            await self?.generatePendingDailySummaries(reason: "activation")
        }
    }

    @objc
    private func handleSystemDidWake() {
        runKnowledgeMaintenanceIfDue(reason: "wake")
        Task { @MainActor [weak self] in
            await self?.generatePendingDailySummaries(reason: "wake")
        }
    }

    private func scheduleKnowledgeMaintenanceTimer() {
        knowledgeMaintenanceTimer?.invalidate()

        let settings = AppSettings()
        let hours = max(6, settings.knowledgeMaintenanceIntervalHours)
        let interval = TimeInterval(hours * 3600)
        let delay = nextKnowledgeMaintenanceDelay(interval: interval)

        knowledgeMaintenanceTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performKnowledgeMaintenance(reason: "timer", force: true)
            }
        }
        knowledgeMaintenanceTimer?.tolerance = min(600, max(60, delay * 0.1))
        logger.info("Knowledge maintenance timer scheduled in \(Int(delay))s (interval \(hours) hours)")
    }

    private func nextKnowledgeMaintenanceDelay(interval: TimeInterval) -> TimeInterval {
        let minimumDelay: TimeInterval = 30
        let settings = AppSettings()
        if let lastRun = settings.lastKnowledgeMaintenanceAt.flatMap(dateSupport.parseDateTime) {
            let dueAt = lastRun.addingTimeInterval(interval)
            return max(minimumDelay, dueAt.timeIntervalSinceNow)
        }
        return interval
    }

    private func runKnowledgeMaintenanceIfDue(reason: String) {
        let settings = AppSettings()
        let hours = max(6, settings.knowledgeMaintenanceIntervalHours)
        let interval = TimeInterval(hours * 3600)

        if let lastRun = settings.lastKnowledgeMaintenanceAt.flatMap(dateSupport.parseDateTime),
           Date().timeIntervalSince(lastRun) < interval {
            scheduleKnowledgeMaintenanceTimer()
            return
        }

        performKnowledgeMaintenance(reason: reason, force: true)
    }

    private func performKnowledgeMaintenance(reason: String, force: Bool) {
        guard let knowledgePipeline else { return }
        if !force {
            runKnowledgeMaintenanceIfDue(reason: reason)
            return
        }
        do {
            let materializedCount = try knowledgePipeline.syncMaterializedKnowledge(exporter: obsidianExporter)
            var settings = AppSettings()
            settings.lastKnowledgeMaintenanceAt = dateSupport.isoString(from: Date())
            if materializedCount > 0 {
                logger.info("Knowledge maintenance sync completed during \(reason, privacy: .public): \(materializedCount) notes")
            } else {
                logger.info("Knowledge maintenance sync completed during \(reason, privacy: .public): no materialized changes")
            }
        } catch {
            logger.error("Knowledge maintenance sync failed during \(reason): \(error.localizedDescription)")
        }
        scheduleKnowledgeMaintenanceTimer()
    }
}

// MARK: - AppMonitorDelegate
extension AppDelegate: @preconcurrency AppMonitorDelegate {
    func appMonitor(_ monitor: AppMonitor, didSwitchTo bundleId: String, appName: String, appId: Int64) {
        guard let sessionManager else { return }
        do {
            let sessionId = try sessionManager.switchSession(appId: appId, windowId: nil)
            try sessionManager.recordEvent(sessionId: sessionId, type: .appActivated, payload:
                "{\"bundle_id\":\"\(bundleId)\",\"app_name\":\"\(appName)\"}")
            if let pid = monitor.currentAppInfo?.pid {
                windowMonitor?.updateApp(appId: appId, pid: pid)
            }
            // Reset capture scheduler to normal mode for new app
            captureScheduler?.resetToNormal()
        } catch {
            logger.error("Failed to handle app switch: \(error.localizedDescription)")
        }
    }
}

// MARK: - WindowMonitorDelegate
extension AppDelegate: @preconcurrency WindowMonitorDelegate {
    func windowMonitor(_ monitor: WindowMonitor, didSwitchTo windowId: Int64, title: String?) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        do {
            try sessionManager.recordEvent(sessionId: sessionId, type: .windowChanged, payload:
                "{\"window_id\":\(windowId),\"title\":\"\(title ?? "")\"}")
        } catch {
            logger.error("Failed to record window change: \(error.localizedDescription)")
        }
    }
}

// MARK: - IdleDetectorDelegate
extension AppDelegate: @preconcurrency IdleDetectorDelegate {
    func idleDetector(_ detector: IdleDetector, didChangeIdleState isIdle: Bool) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        do {
            if isIdle {
                try sessionManager.markIdle(sessionId: sessionId)
            } else {
                try sessionManager.markActive(sessionId: sessionId)
            }
        } catch {
            logger.error("Failed to update idle state: \(error.localizedDescription)")
        }
    }
}

// MARK: - CaptureSchedulerDelegate
extension AppDelegate: @preconcurrency CaptureSchedulerDelegate {
    func captureScheduler(_ scheduler: CaptureScheduler, shouldCaptureWithMode mode: UncertaintyMode) {
        performCapture(mode: mode)
    }

    func captureScheduler(_ scheduler: CaptureScheduler, didChangeMode mode: UncertaintyMode) {
        guard let sessionManager, let sessionId = sessionManager.currentSessionId else { return }
        try? sessionManager.recordEvent(sessionId: sessionId, type: .modeChanged, payload:
            "{\"mode\":\"\(mode.rawValue)\"}")
        logger.info("Capture mode changed to \(mode.rawValue)")
    }
}
