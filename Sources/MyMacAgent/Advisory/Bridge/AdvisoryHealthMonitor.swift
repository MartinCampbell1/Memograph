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
    private let notificationCenter: NotificationCenter
    private let queue = DispatchQueue(label: "memograph.advisory.health", qos: .utility)
    private let lock = NSLock()
    private let bridgeLock = NSLock()
    private let bridgeFactory: @Sendable () -> AdvisoryBridgeClient
    private var bridge: AdvisoryBridgeClient
    private var refreshInFlight = false
    private var pendingForceRefresh = false
    private var started = false

    init(
        bridgeFactory: @escaping @Sendable () -> AdvisoryBridgeClient = { AdvisoryBridgeClient(settings: AppSettings()) },
        notificationCenter: NotificationCenter = .default
    ) {
        self.bridgeFactory = bridgeFactory
        self.notificationCenter = notificationCenter
        self.bridge = bridgeFactory()
        settingsObserver = notificationCenter.addObserver(
            forName: .settingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.resetBridge()
            self?.refresh(forceRefresh: true)
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
            notificationCenter.removeObserver(settingsObserver)
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
            let runtimeSnapshot = self.withBridge {
                $0.runtimeSnapshot(forceRefresh: effectiveForceRefresh)
            }
            DispatchQueue.main.async {
                self.publish(AdvisoryHealthSnapshot(runtimeSnapshot: runtimeSnapshot))
                self.finishRefresh()
            }
        }
    }

    func restartSidecar() {
        queue.async { [weak self] in
            guard let self else { return }
            self.withBridge { $0.restartSidecar() }
            var runtimeSnapshot = self.withBridge {
                $0.runtimeSnapshot(forceRefresh: false)
            }
            if Self.restartGraceStatuses.contains(runtimeSnapshot.effectiveStatus) {
                Thread.sleep(forTimeInterval: 2)
                runtimeSnapshot = self.withBridge {
                    $0.runtimeSnapshot(forceRefresh: false)
                }
            }
            DispatchQueue.main.async {
                self.publish(AdvisoryHealthSnapshot(runtimeSnapshot: runtimeSnapshot))
            }
        }
    }

    func stopSidecar() {
        queue.async { [weak self] in
            self?.withBridge { $0.stopSidecar() }
            self?.refresh()
        }
    }

    /// Runs the full auth recovery cycle for a provider after re-login.
    /// The completion is always called on the main queue.
    func recoverAfterRelogin(
        provider: String,
        accountName: String? = nil,
        completion: @MainActor @escaping (Bool, Date) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.withBridge {
                $0.recoverAfterRelogin(provider: provider, accountName: accountName)
            }
            let verified = result.verified
            let verifiedAt = result.lastVerifiedAt
            let runtimeSnapshot = self.withBridge {
                $0.runtimeSnapshot(forceRefresh: true)
            }
            DispatchQueue.main.async {
                self.publish(AdvisoryHealthSnapshot(runtimeSnapshot: runtimeSnapshot))
                completion(verified, verifiedAt)
            }
        }
    }

    /// Runs a fresh auth check for a specific provider.
    /// The completion is always called on the main queue.
    func checkProviderAuth(
        provider: String,
        accountName: String? = nil,
        completion: @MainActor @escaping (Bool, Date) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.withBridge {
                $0.checkProviderAuth(provider: provider, accountName: accountName)
            }
            let verified = result.verified
            let verifiedAt = result.lastVerifiedAt
            let runtimeSnapshot = self.withBridge {
                $0.runtimeSnapshot(forceRefresh: true)
            }
            DispatchQueue.main.async {
                self.publish(AdvisoryHealthSnapshot(runtimeSnapshot: runtimeSnapshot))
                completion(verified, verifiedAt)
            }
        }
    }

    private func withBridge<T>(_ body: (AdvisoryBridgeClient) -> T) -> T {
        bridgeLock.lock()
        let bridge = self.bridge
        bridgeLock.unlock()
        return body(bridge)
    }

    private func resetBridge() {
        let replacement = bridgeFactory()
        bridgeLock.lock()
        bridge = replacement
        bridgeLock.unlock()
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

    private static let restartGraceStatuses: Set<String> = [
        "starting",
        "hung_start",
        "socket_missing",
        "transport_failure",
        "unavailable",
        "timeout"
    ]
}
