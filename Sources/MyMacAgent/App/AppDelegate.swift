import AppKit
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger.app
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
    // Phase 4
    private var retentionWorker: RetentionWorker?
    // Phase 5 — Vision + Audio
    private var visionAnalyzer: VisionAnalyzer?
    private var audioTranscriber: AudioTranscriber?
    private var audioCaptureEngine: AudioCaptureEngine?
    private var systemAudioEngine: SystemAudioCaptureEngine?
    private var retentionTimer: Timer?
    private var autoSummaryTimer: Timer?
    private var captureHashTracker = CaptureHashTracker()
    private let captureGate = CaptureGate(maxConcurrent: 1)
    private var privacyGuard = PrivacyGuard.fromSettings()

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        autoSummaryTimer?.invalidate()
        autoSummaryTimer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
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
    }

    private func initializeDatabase() {
        do {
            let settings = AppSettings()
            try AppPaths.ensureBaseDirectories(settings: settings)
            let dbPath = AppPaths.databaseURL(settings: settings).path
            let db = try DatabaseManager(path: dbPath)
            let runner = MigrationRunner(db: db, migrations: [
                V001_InitialSchema.migration,
                V002_AudioTranscripts.migration
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
        logger.info("Phase 3 components initialized (fusion, summary, export)")
    }

    private func initializePhase4() {
        guard let db = databaseManager else { return }

        let settings = AppSettings()
        retentionWorker = RetentionWorker(db: db, retentionDays: settings.retentionDays)

        // Run retention daily
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                try? self?.retentionWorker?.runAll()
            }
        }

        // Run once on startup
        try? retentionWorker?.runAll()

        // Auto-generate summary every hour if user is active
        autoSummaryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.autoGenerateSummaryIfActive()
            }
        }

        logger.info("Phase 4 initialized (retention, hourly auto-summary)")
    }

    private func initializePhase5() {
        guard let db = databaseManager else { return }
        let transcriber = AudioTranscriber(db: db)
        try? transcriber.ensureTable()
        audioTranscriber = transcriber
        visionAnalyzer = VisionAnalyzer(db: db)
        configureAudioEngines(forceRestart: true)

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
        // Only generate if user was active (not idle) and we have an API key
        guard let idleDetector, !idleDetector.isIdle else {
            logger.info("Skipping auto-summary: user is idle")
            return
        }
        let settings = AppSettings()
        guard settings.resolvedSummaryProvider != .disabled else {
            logger.info("Skipping auto-summary: summary provider is disabled")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())

        generateDailySummary(for: today, apiKey: settings.externalAPIKey)
        logger.info("Auto-summary triggered for \(today)")
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

        guard privacyGuard.shouldCapture(
            bundleId: appInfo.bundleId,
            windowTitle: windowMonitor?.currentWindowTitle
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

                // 3. Save to disk
                let captureDir = AppPaths.capturesDirectoryURL()
                try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
                let imagePath = try captureEngine.saveToDisk(result: captureResult, directory: captureDir.path)

                // 4. Persist capture record
                let captureId = UUID().uuidString
                let now = ISO8601DateFormatter().string(from: Date())
                try db.execute("""
                    INSERT INTO captures (id, session_id, timestamp, capture_type, image_path,
                        width, height, visual_hash, sampling_mode)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, params: [
                    .text(captureId), .text(sessionId), .text(now),
                    .text("window"), .text(imagePath),
                    .integer(Int64(captureResult.width)), .integer(Int64(captureResult.height)),
                    hash.map { .text($0) } ?? .null, .text(mode.rawValue)
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
                let visualDiff: Double = hash.map { hashTracker.computeDiff(currentHash: $0, sessionId: sessionId) } ?? 1.0

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
                        windowTitle: self.windowMonitor?.currentWindowTitle,
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
        let analyzer = visionAnalyzer
        Task { @MainActor in
            do {
                let settings = AppSettings()
                guard let client = LLMClient.client(for: settings, apiKeyOverride: apiKey) else {
                    logger.info("Skipping summary generation: no configured summary provider")
                    return
                }
                if let analyzer {
                    let count = try await analyzer.analyzeAllLowReadability(for: date)
                    if count > 0 {
                        logger.info("Analyzed \(count) low-readability screenshots before summary")
                    }
                }
                guard let summarizer = dailySummarizer else { return }
                let summary = try await summarizer.summarize(for: date, using: client)
                if let exporter = obsidianExporter {
                    let path = try exporter.exportDailyNote(summary: summary)
                    logger.info("Daily note exported to \(path)")
                }
            } catch {
                logger.error("Daily summary failed: \(error.localizedDescription)")
            }
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

        if settings.systemAudioCaptureEnabled && systemAudioEngine == nil {
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
        }

        configureAudioEngines(forceRestart: true)
    }

    @objc
    private func handleDeleteAllLocalData() {
        let settings = AppSettings()

        autoSummaryTimer?.invalidate()
        autoSummaryTimer = nil
        retentionTimer?.invalidate()
        retentionTimer = nil
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
