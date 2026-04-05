import Combine
import Foundation

struct AdvisoryHealthSnapshot: Equatable {
    var runtimeSnapshot = AdvisoryBridgeRuntimeSnapshot(
        mode: .preferSidecar,
        bridgeHealth: AdvisoryBridgeHealth(
            runtimeName: "memograph-advisor",
            status: "unavailable",
            providerName: "sidecar_jsonrpc_uds",
            transport: "jsonrpc_uds"
        ),
        effectiveStatus: "unavailable",
        fallbackActive: false,
        supervisorStatus: nil,
        consecutiveFailures: 0,
        autoStartEnabled: false,
        socketPresent: false,
        lastError: nil,
        recommendedAction: nil,
        updatedAt: .distantPast
    )

    var isDegraded: Bool {
        runtimeSnapshot.isDegraded
    }

    var statusTitle: String {
        runtimeSnapshot.title
    }

    var statusLines: [String] {
        runtimeSnapshot.statusLines
    }
}

final class AdvisoryHealthMonitor: ObservableObject, @unchecked Sendable {
    static let shared = AdvisoryHealthMonitor()

    @Published private(set) var snapshot = AdvisoryHealthSnapshot()

    private var timer: Timer?
    private var settingsObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "memograph.advisory.health", qos: .utility)
    private let lock = NSLock()
    private var refreshInFlight = false
    private var pendingForceRefresh = false
    private var started = false

    private init() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
            self?.scheduleTimer()
        }
    }

    func startIfNeeded() {
        lock.lock()
        guard !started else {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()
        refresh()
        scheduleTimer()
    }

    deinit {
        timer?.invalidate()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
    }

    func refresh(forceRefresh: Bool = false) {
        lock.lock()
        pendingForceRefresh = pendingForceRefresh || forceRefresh
        guard !refreshInFlight else {
            lock.unlock()
            return
        }
        refreshInFlight = true
        let effectiveForceRefresh = pendingForceRefresh
        pendingForceRefresh = false
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let bridge = AdvisoryBridgeClient(settings: AppSettings())
            let runtimeSnapshot = bridge.runtimeSnapshot(forceRefresh: effectiveForceRefresh)
            DispatchQueue.main.async {
                self.publish(AdvisoryHealthSnapshot(runtimeSnapshot: runtimeSnapshot))
                self.finishRefresh()
            }
        }
    }

    func restartSidecar() {
        queue.async { [weak self] in
            let bridge = AdvisoryBridgeClient(settings: AppSettings())
            bridge.restartSidecar()
            self?.refresh()
        }
    }

    func stopSidecar() {
        queue.async { [weak self] in
            let bridge = AdvisoryBridgeClient(settings: AppSettings())
            bridge.stopSidecar()
            self?.refresh()
        }
    }

    private func publish(_ snapshot: AdvisoryHealthSnapshot) {
        self.snapshot = snapshot
    }

    private func finishRefresh() {
        lock.lock()
        let shouldRefreshAgain = pendingForceRefresh
        refreshInFlight = false
        lock.unlock()

        if shouldRefreshAgain {
            refresh(forceRefresh: true)
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let settings = AppSettings()
        let interval = TimeInterval(max(10, min(60, settings.advisorySidecarHealthCheckIntervalSeconds)))
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
}
