import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryHealthMonitorTests {
    @Test("Health monitor reuses one bridge until settings change")
    func reusesBridgeAcrossRefreshAndRecoveryFlows() async throws {
        let counter = BridgeInstanceCounter()
        let server = StableMonitorBridgeServer()
        let notificationCenter = NotificationCenter()
        let monitor = AdvisoryHealthMonitor(
            bridgeFactory: {
                counter.increment()
                return AdvisoryBridgeClient(
                    primaryServer: server,
                    fallbackServer: LocalAdvisoryBridgeStub(),
                    mode: .requireSidecar
                )
            },
            notificationCenter: notificationCenter
        )

        #expect(counter.current == 1)

        monitor.refresh(forceRefresh: true)
        try await Task.sleep(for: .milliseconds(200))

        let auth = await performAuthCheck(monitor, provider: "claude", accountName: "acc1")
        let recovery = await performRecovery(monitor, provider: "claude", accountName: "acc1")

        #expect(auth.verified)
        #expect(recovery.verified)
        #expect(counter.current == 1)
        #expect(server.authCheckCallCount >= 2)
        #expect(monitor.snapshot.runtimeSnapshot.bridgeHealth.status == "ok")

        notificationCenter.post(name: .settingsDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(200))

        #expect(counter.current == 2)
        #expect(monitor.snapshot.runtimeSnapshot.bridgeHealth.status == "ok")
    }
}

private func performAuthCheck(
    _ monitor: AdvisoryHealthMonitor,
    provider: String,
    accountName: String
) async -> (verified: Bool, verifiedAt: Date) {
    await withCheckedContinuation { continuation in
        monitor.checkProviderAuth(provider: provider, accountName: accountName) { verified, verifiedAt in
            continuation.resume(returning: (verified, verifiedAt))
        }
    }
}

private func performRecovery(
    _ monitor: AdvisoryHealthMonitor,
    provider: String,
    accountName: String
) async -> (verified: Bool, verifiedAt: Date) {
    await withCheckedContinuation { continuation in
        monitor.recoverAfterRelogin(provider: provider, accountName: accountName) { verified, verifiedAt in
            continuation.resume(returning: (verified, verifiedAt))
        }
    }
}

private final class BridgeInstanceCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

private final class StableMonitorBridgeServer: AdvisoryBridgeServerProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var authChecks = 0

    var authCheckCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return authChecks
    }

    func health() -> AdvisoryBridgeHealth {
        makeHealth(checkedAt: "2026-04-06T00:00:00Z")
    }

    func refreshHealth() -> AdvisoryBridgeHealth {
        makeHealth(checkedAt: "2026-04-06T00:00:01Z")
    }

    func authCheck(providerName: String, accountName: String?, forceRefresh: Bool) throws -> AdvisoryProviderAuthCheckResponse {
        lock.lock()
        authChecks += 1
        lock.unlock()
        return AdvisoryProviderAuthCheckResponse(
            providerName: providerName,
            accountName: accountName,
            verified: true,
            status: "ok",
            detail: forceRefresh ? "Fresh auth check succeeded." : "Cached auth check succeeded.",
            checkedAt: "2026-04-06T00:00:01Z"
        )
    }

    func runRecipe(_: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        throw AdvisoryBridgeError.unavailable("Not needed for AdvisoryHealthMonitorTests.")
    }

    func cancelRun(runId _: String) {}

    private func makeHealth(checkedAt: String) -> AdvisoryBridgeHealth {
        AdvisoryBridgeHealth(
            runtimeName: "memograph-advisor",
            status: "ok",
            providerName: "sidecar_jsonrpc_uds",
            transport: "jsonrpc_uds",
            statusDetail: "Runtime ready.",
            activeProviderName: "claude",
            providerOrder: ["claude"],
            availableProviders: ["claude"],
            providerStatuses: [
                AdvisoryProviderDiagnostic(
                    providerName: "claude",
                    status: "ok",
                    detail: "Provider ready.",
                    binaryPresent: true,
                    sessionDetected: true,
                    priority: 0
                )
            ],
            checkedAt: checkedAt,
            runtimeHealthTier: "ok",
            providerHealthTier: "ok"
        )
    }
}
