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
    private var retentionTimer: Timer?
    private var autoSummaryTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("MyMacAgent launched")
        initializeDatabase()
        initializeMonitors()
        initializePhase2()
        initializePhase3()
        initializePhase4()
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
        if let sessionId = sessionManager?.currentSessionId {
            try? sessionManager?.endSession(sessionId)
        }
        logger.info("MyMacAgent terminating")
    }

    private func initializeDatabase() {
        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("MyMacAgent", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            let dbPath = dbDir.appendingPathComponent("mymacagent.db").path
            let db = try DatabaseManager(path: dbPath)
            let runner = MigrationRunner(db: db, migrations: [V001_InitialSchema.migration])
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
        let ollamaProvider = OllamaOCRProvider()
        let visionProvider = VisionOCRProvider()
        let ocrProvider = FallbackOCRProvider(primary: ollamaProvider, fallback: visionProvider)
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
        let vaultPath = UserDefaults.standard.string(forKey: "obsidianVaultPath")
            ?? NSHomeDirectory() + "/Documents/MyMacAgentVault"
        obsidianExporter = ObsidianExporter(db: db, vaultPath: vaultPath)
        logger.info("Phase 3 components initialized (fusion, summary, export)")
    }

    private func initializePhase4() {
        guard let db = databaseManager else { return }

        let settings = AppSettings()
        retentionWorker = RetentionWorker(db: db, retentionDays: settings.retentionDays)

        // Run retention daily
        retentionTimer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            try? self?.retentionWorker?.runAll()
        }

        // Run once on startup
        try? retentionWorker?.runAll()

        // Auto-generate summary every hour if user is active
        autoSummaryTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.autoGenerateSummaryIfActive()
        }

        logger.info("Phase 4 initialized (retention, hourly auto-summary)")
    }

    private func autoGenerateSummaryIfActive() {
        // Only generate if user was active (not idle) and we have an API key
        guard let idleDetector, !idleDetector.isIdle else {
            logger.info("Skipping auto-summary: user is idle")
            return
        }
        let settings = AppSettings()
        guard settings.hasApiKey else {
            logger.info("Skipping auto-summary: no API key configured")
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())

        generateDailySummary(for: today, apiKey: settings.openRouterApiKey)
        logger.info("Auto-summary triggered for \(today)")
    }

    private func performCapture(mode: UncertaintyMode) {
        guard let appInfo = appMonitor?.currentAppInfo,
              let sessionManager, let sessionId = sessionManager.currentSessionId,
              let captureEngine, let imageProcessor, let db = databaseManager else { return }

        // Capture Phase 2 + Phase 3 components by value to avoid self capture across isolation boundary
        let axEngine = accessibilityEngine
        let ocrPipe = ocrPipeline
        let policy = policyEngine
        let scheduler = captureScheduler
        let fusionEngine = contextFusionEngine
        let pid = appInfo.pid

        Task {
            do {
                // 1. Take screenshot
                let captureResult = try await captureEngine.captureWindow(pid: pid)

                // 2. Compute hash and diff
                let hash = imageProcessor.visualHash(image: captureResult.image)

                // 3. Save to disk
                let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                let captureDir = appSupport.appendingPathComponent("MyMacAgent/captures", isDirectory: true)
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
                let visualDiff: Double = hash != nil ? 0.5 : 0.5 // default: assume change

                if let policy, policy.shouldRunOCR(visualDiffScore: visualDiff, mode: mode) {
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
        Task { @MainActor in
            do {
                let settings = AppSettings()
                let key = apiKey ?? settings.openRouterApiKey
                let client = LLMClient(apiKey: key, model: settings.llmModel)
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
            let normalInput = ReadabilityInput(
                axTextLen: 0, ocrConfidence: 0, ocrTextLen: 0,
                visualChangeScore: 0, isCanvasLike: false
            )
            captureScheduler?.updateReadability(normalInput)
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
        let eventType: SessionEventType = isIdle ? .idleStarted : .idleEnded
        try? sessionManager.recordEvent(sessionId: sessionId, type: eventType, payload: nil)
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
