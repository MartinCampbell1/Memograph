import Darwin
import Foundation
import os

final class AdvisoryBridgeClient: @unchecked Sendable {
    private let primaryServer: AdvisoryBridgeServerProtocol?
    private let fallbackServer: AdvisoryBridgeServerProtocol
    private let mode: AdvisoryBridgeMode
    private let supervisor: AdvisorySidecarSupervisor?
    private let retryAttempts: Int
    private var settings: AppSettings
    private let accountSyncQueue = DispatchQueue(label: "com.memograph.advisor.accountSync")
    private var recentExecutionHealth: AdvisoryBridgeHealth?
    private var recentExecutionHealthValidUntil: Date?

    init(
        settings: AppSettings = AppSettings(),
        primaryServer: AdvisoryBridgeServerProtocol? = nil,
        fallbackServer: AdvisoryBridgeServerProtocol = LocalAdvisoryBridgeStub(),
        sidecarEnvironmentOverrides: [String: String] = [:]
    ) {
        self.mode = settings.advisoryBridgeMode
        self.fallbackServer = fallbackServer
        self.retryAttempts = max(1, settings.advisorySidecarRetryAttempts)
        var effectiveEnvironmentOverrides = sidecarEnvironmentOverrides
        if !settings.advisorySidecarProviderOrder.isEmpty {
            effectiveEnvironmentOverrides["MEMOGRAPH_ADVISOR_PROVIDER_ORDER"] = settings.advisorySidecarProviderOrder.joined(separator: ",")
        }
        effectiveEnvironmentOverrides["MEMOGRAPH_ADVISOR_MAX_RECIPE_RETRIES"] = String(max(1, settings.advisorySidecarRetryAttempts))
        effectiveEnvironmentOverrides["MEMOGRAPH_ADVISOR_PROVIDER_COOLDOWN_SECONDS"] = String(max(5, settings.advisorySidecarProviderCooldownSeconds))
        effectiveEnvironmentOverrides["MEMOGRAPH_ADVISOR_PROFILES_DIR"] = settings.advisoryCLIProfilesPath
        if !settings.advisorySelectedClaudeAccount.isEmpty {
            effectiveEnvironmentOverrides["MEMOGRAPH_ADVISOR_PROFILE_CLAUDE"] = settings.advisorySelectedClaudeAccount
        }
        if !settings.advisorySelectedGeminiAccount.isEmpty {
            effectiveEnvironmentOverrides["MEMOGRAPH_ADVISOR_PROFILE_GEMINI"] = settings.advisorySelectedGeminiAccount
        }
        if !settings.advisorySelectedCodexAccount.isEmpty {
            effectiveEnvironmentOverrides["MEMOGRAPH_ADVISOR_PROFILE_CODEX"] = settings.advisorySelectedCodexAccount
        }
        if let primaryServer {
            self.primaryServer = primaryServer
            self.supervisor = nil
        } else if settings.advisoryBridgeMode == .stubOnly {
            self.primaryServer = nil
            self.supervisor = nil
        } else {
            let runtimeStatus = AdvisorySidecarRuntimeResolver.resolve()
            let socketPath = AdvisorySidecarSocketPathResolver.resolve(settings.advisorySidecarSocketPath)
            self.primaryServer = JSONRPCAdvisoryBridgeServer(
                socketPath: socketPath,
                defaultTimeoutSeconds: settings.advisorySidecarTimeoutSeconds
            )
            self.supervisor = AdvisorySidecarSupervisorRegistry.shared.sharedSupervisor(
                autoStart: settings.advisorySidecarAutoStart,
                socketPath: socketPath,
                healthCheckIntervalSeconds: settings.advisorySidecarHealthCheckIntervalSeconds,
                maxConsecutiveFailures: settings.advisorySidecarMaxConsecutiveFailures,
                runtimeStatus: runtimeStatus,
                probeTimeoutSeconds: settings.advisorySidecarProviderProbeTimeoutSeconds,
                environmentOverrides: effectiveEnvironmentOverrides
            )
        }
        self.settings = settings
    }

    init(
        primaryServer: AdvisoryBridgeServerProtocol?,
        fallbackServer: AdvisoryBridgeServerProtocol = LocalAdvisoryBridgeStub(),
        mode: AdvisoryBridgeMode,
        retryAttempts: Int = 2
    ) {
        self.primaryServer = primaryServer
        self.fallbackServer = fallbackServer
        self.mode = mode
        self.supervisor = nil
        self.retryAttempts = max(1, retryAttempts)
        self.settings = AppSettings()
    }

    func health(forceRefresh: Bool = false) -> AdvisoryBridgeHealth {
        supervisor?.prepareForHealthCheck()
        switch mode {
        case .stubOnly:
            return forceRefresh ? fallbackServer.refreshHealth() : fallbackServer.health()
        case .requireSidecar:
            let health = fetchHealth(from: primaryServer, forceRefresh: forceRefresh) ?? AdvisoryBridgeHealth(
                runtimeName: "memograph-advisor",
                status: "unavailable",
                providerName: "sidecar_jsonrpc_uds",
                transport: "jsonrpc_uds",
                recommendedAction: "memograph-advisor недоступен. Проверь sidecar process и provider sessions."
            )
            let resolved = preferredRecentExecutionHealth(over: health, forceRefresh: forceRefresh)
            supervisor?.record(health: resolved)
            return resolved
        case .preferSidecar:
            guard let primaryServer else {
                return fallbackHealth(status: "fallback_stub")
            }
            let primaryHealth = forceRefresh ? primaryServer.refreshHealth() : primaryServer.health()
            let resolved = preferredRecentExecutionHealth(over: primaryHealth, forceRefresh: forceRefresh)
            supervisor?.record(health: resolved)
            if resolved.status == "ok" {
                return resolved
            }
            return fallbackHealth(status: "fallback_stub", attemptedPrimaryHealth: resolved)
        }
    }

    func runtimeSnapshot(forceRefresh: Bool = false) -> AdvisoryBridgeRuntimeSnapshot {
        let currentHealth = health(forceRefresh: forceRefresh)
        let supervisorSnapshot = supervisor?.snapshot(currentHealth: currentHealth)
        let effectiveStatus = effectiveStatus(
            mode: mode,
            health: currentHealth,
            supervisor: supervisorSnapshot
        )
        let fallbackActive = currentHealth.status == "fallback_stub" || mode == .stubOnly
        return AdvisoryBridgeRuntimeSnapshot(
            mode: mode,
            bridgeHealth: currentHealth,
            effectiveStatus: effectiveStatus,
            fallbackActive: fallbackActive,
            supervisorStatus: supervisorSnapshot?.status,
            consecutiveFailures: supervisorSnapshot?.consecutiveFailures ?? 0,
            autoStartEnabled: supervisorSnapshot?.autoStartEnabled ?? false,
            socketPresent: supervisorSnapshot?.socketPresent ?? false,
            lastError: supervisorSnapshot?.lastError ?? currentHealth.lastError ?? currentHealth.statusDetail,
            recommendedAction: supervisorSnapshot?.recommendedAction ?? currentHealth.recommendedAction,
            updatedAt: Date()
        )
    }

    func accounts(forceRefresh: Bool = false) throws -> AdvisoryProviderAccountsSnapshot {
        supervisor?.prepareForHealthCheck()
        guard let primaryServer else {
            throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
        }
        return try primaryServer.accounts(forceRefresh: forceRefresh)
    }

    func openLogin(providerName: String) throws -> AdvisoryProviderAccountActionResponse {
        supervisor?.prepareForExecution()
        guard let primaryServer else {
            throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
        }
        return try primaryServer.openLogin(providerName: providerName)
    }

    func importCurrentSession(providerName: String, accountName: String? = nil) throws -> AdvisoryProviderAccountActionResponse {
        supervisor?.prepareForExecution()
        guard let primaryServer else {
            throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
        }
        return try primaryServer.importCurrentSession(providerName: providerName, accountName: accountName)
    }

    func reauthorize(providerName: String, accountName: String) throws -> AdvisoryProviderAccountActionResponse {
        supervisor?.prepareForExecution()
        guard let primaryServer else {
            throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
        }
        return try primaryServer.reauthorize(providerName: providerName, accountName: accountName)
    }

    func setAccountLabel(providerName: String, accountName: String, label: String) throws -> AdvisoryProviderAccountActionResponse {
        supervisor?.prepareForExecution()
        guard let primaryServer else {
            throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
        }
        return try primaryServer.setAccountLabel(providerName: providerName, accountName: accountName, label: label)
    }

    func setPreferredAccount(providerName: String, accountName: String) throws -> AdvisoryProviderAccountActionResponse {
        supervisor?.prepareForExecution()
        guard let primaryServer else {
            throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
        }
        let response = try primaryServer.setPreferredAccount(providerName: providerName, accountName: accountName)
        accountSyncQueue.sync {
            self.writePreferredAccount(provider: providerName, accountName: accountName)
        }
        return response
    }

    /// Queries the sidecar for its current preferred accounts and updates AppSettings
    /// for any provider where the sidecar's selection differs from the stored preference.
    func syncPreferredAccountFromSidecar() {
        guard let snapshot = try? accounts(forceRefresh: false) else { return }
        accountSyncQueue.sync {
            for (provider, accountName) in snapshot.preferredAccounts where !accountName.isEmpty {
                let stored = self.storedPreferredAccount(for: provider)
                guard stored != accountName else { continue }
                self.writePreferredAccount(provider: provider, accountName: accountName)
            }
        }
    }

    func executeRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryBridgeExecution {
        supervisor?.prepareForExecution()
        switch mode {
        case .stubOnly:
            return try executeOnFallback(request)
        case .requireSidecar:
            guard let primaryServer else {
                throw AdvisoryBridgeError.unavailable("Advisory sidecar is required but no sidecar bridge is configured.")
            }
            let primaryHealth = refreshPrimaryHealth(on: primaryServer)
            do {
                return try executePrimary(
                    request,
                    on: primaryServer,
                    initialHealth: primaryHealth
                )
            } catch let failure as PrimaryExecutionFailure {
                throw AdvisoryBridgeError.unavailable(failure.message)
            }
        case .preferSidecar:
            guard let primaryServer else {
                return try executeOnFallback(request)
            }
            let primaryHealth = refreshPrimaryHealth(on: primaryServer)
            do {
                return try executePrimary(
                    request,
                    on: primaryServer,
                    initialHealth: primaryHealth
                )
            } catch let failure as PrimaryExecutionFailure {
                return try executeFallback(
                    request,
                    attemptedPrimaryHealth: failure.health,
                    primaryFailure: failure.message
                )
            }
        }
    }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        try executeRecipe(request).result
    }

    func cancelRun(runId: String) {
        primaryServer?.cancelRun(runId: runId)
        fallbackServer.cancelRun(runId: runId)
    }

    func stopSidecar() {
        supervisor?.shutdown()
    }

    func restartSidecar() {
        supervisor?.restart()
    }

    /// Called after a re-login action completes. Resets failure state for the
    /// provider, restarts sidecar, and verifies health recovery.
    /// Returns the post-recovery auth check result with per-provider verification.
    @discardableResult
    func recoverAfterRelogin(provider: String, accountName: String? = nil) -> AdvisoryProviderAuthCheckResult {
        supervisor?.recordSuccess()
        let currentRuntime = runtimeSnapshot(forceRefresh: true)
        let normalizedStatus = AdvisoryBridgeStatusInterpreter.normalizedStatus(currentRuntime.effectiveStatus)
        if runtimeRestartRequired(for: normalizedStatus) {
            restartSidecar()
            Thread.sleep(forTimeInterval: 2)
        }
        let authCheck = checkProviderAuth(provider: provider, accountName: accountName, forceRefresh: true)
        if authCheck.verified {
            supervisor?.recordSuccess()
        }
        return authCheck
    }

    /// Runs a targeted auth check for a specific provider.
    func checkProviderAuth(provider: String, accountName: String? = nil, forceRefresh: Bool = true) -> AdvisoryProviderAuthCheckResult {
        guard let primaryServer else {
            let freshHealth = health(forceRefresh: forceRefresh)
            let verified = isProviderVerified(provider: provider, accountName: accountName, in: freshHealth)
            return AdvisoryProviderAuthCheckResult(
                provider: provider,
                accountName: accountName,
                verified: verified,
                status: freshHealth.status,
                detail: freshHealth.statusDetail ?? freshHealth.lastError,
                lastVerifiedAt: Date(),
                health: freshHealth
            )
        }

        do {
            let response = try primaryServer.authCheck(
                providerName: provider,
                accountName: accountName,
                forceRefresh: forceRefresh
            )
            let runtimeHealth = health(forceRefresh: false)
            return AdvisoryProviderAuthCheckResult(
                provider: provider,
                accountName: response.accountName ?? accountName,
                verified: response.verified,
                status: response.status,
                detail: response.detail,
                lastVerifiedAt: Date(),
                health: runtimeHealth
            )
        } catch {
            let runtimeHealth = health(forceRefresh: false)
            return AdvisoryProviderAuthCheckResult(
                provider: provider,
                accountName: accountName,
                verified: false,
                status: AdvisoryBridgeStatusInterpreter.normalizedStatus(error.localizedDescription),
                detail: error.localizedDescription,
                lastVerifiedAt: Date(),
                health: runtimeHealth
            )
        }
    }

    private func isProviderVerified(
        provider: String,
        accountName: String?,
        in health: AdvisoryBridgeHealth
    ) -> Bool {
        let providerLower = provider.lowercased()
        if let diagnostic = health.providerStatuses.first(where: { $0.providerName.lowercased() == providerLower }) {
            return diagnostic.status == "ok"
        }
        return health.status == "ok"
    }

    private func runtimeRestartRequired(for status: String) -> Bool {
        switch status {
        case "socket_missing", "transport_failure", "unavailable", "hung_start":
            return true
        default:
            return false
        }
    }

    static func shutdownAllManagedSidecars() {
        AdvisorySidecarSupervisorRegistry.shared.shutdownAll()
    }

    static func cleanupDetachedSidecars(keepingSocketPath: String? = nil) {
        AdvisorySidecarProcessJanitor.cleanup(keepingSocketPath: keepingSocketPath)
    }

    private func executeOnFallback(_ request: AdvisoryRecipeRequest) throws -> AdvisoryBridgeExecution {
        try executeFallback(request, attemptedPrimaryHealth: nil, primaryFailure: nil)
    }

    private func fetchHealth(
        from server: AdvisoryBridgeServerProtocol?,
        forceRefresh: Bool
    ) -> AdvisoryBridgeHealth? {
        guard let server else { return nil }
        return forceRefresh ? server.refreshHealth() : server.health()
    }

    private func executeFallback(
        _ request: AdvisoryRecipeRequest,
        attemptedPrimaryHealth: AdvisoryBridgeHealth?,
        primaryFailure: String?
    ) throws -> AdvisoryBridgeExecution {
        do {
            let result = try fallbackServer.runRecipe(request)
            return AdvisoryBridgeExecution(
                result: result,
                activeHealth: fallbackHealth(
                    status: primaryFailure == nil ? "ok" : "fallback_stub",
                    attemptedPrimaryHealth: attemptedPrimaryHealth
                ),
                attemptedPrimaryHealth: attemptedPrimaryHealth,
                usedFallback: primaryFailure != nil,
                primaryFailure: primaryFailure
            )
        } catch {
            if let primaryFailure {
                throw AdvisoryBridgeError.transportFailure("\(primaryFailure) Fallback bridge also failed: \(error.localizedDescription)")
            }
            throw error
        }
    }

    private func executePrimary(
        _ request: AdvisoryRecipeRequest,
        on primaryServer: AdvisoryBridgeServerProtocol,
        initialHealth: AdvisoryBridgeHealth
    ) throws -> AdvisoryBridgeExecution {
        var currentHealth = initialHealth
        var remainingAttempts = max(1, retryAttempts)
        let firstHealth = initialHealth

        while true {
            guard currentHealth.status == "ok" else {
                let reason = currentHealth.lastError
                    ?? currentHealth.statusDetail
                    ?? "Advisory sidecar is unavailable (\(currentHealth.status))."
                supervisor?.recordFailure(reason: reason)
                guard remainingAttempts > 1, shouldRetryPrimary(for: currentHealth.status) else {
                    throw PrimaryExecutionFailure(
                        message: "Advisory sidecar is unavailable (\(currentHealth.status)).",
                        health: currentHealth
                    )
                }
                remainingAttempts -= 1
                preparePrimaryRetry(for: currentHealth.status)
                currentHealth = refreshPrimaryHealth(on: primaryServer)
                continue
            }

            do {
                let result = try primaryServer.runRecipe(request)
                supervisor?.recordSuccess()
                syncPreferredAccountFromSidecar()
                let activeHealth = refreshPostExecutionHealth(
                    on: primaryServer,
                    fallback: currentHealth
                )
                rememberRecentExecutionHealth(activeHealth)
                return AdvisoryBridgeExecution(
                    result: result,
                    activeHealth: activeHealth,
                    attemptedPrimaryHealth: firstHealth,
                    usedFallback: false,
                    primaryFailure: nil
                )
            } catch {
                let status = AdvisoryBridgeStatusInterpreter.normalizedStatus(error.localizedDescription)
                supervisor?.recordFailure(reason: error.localizedDescription)
                let recoveredHealth = refreshPrimaryHealth(
                    on: primaryServer,
                    fallback: currentHealth,
                    forceRefresh: true
                )
                guard remainingAttempts > 1, shouldRetryPrimary(for: status) else {
                    throw PrimaryExecutionFailure(
                        message: error.localizedDescription,
                        health: recoveredHealth
                    )
                }
                remainingAttempts -= 1
                preparePrimaryRetry(for: status)
                currentHealth = recoveredHealth
            }
        }
    }

    private func refreshPostExecutionHealth(
        on primaryServer: AdvisoryBridgeServerProtocol,
        fallback: AdvisoryBridgeHealth
    ) -> AdvisoryBridgeHealth {
        let cachedHealth = refreshPrimaryHealth(
            on: primaryServer,
            fallback: nil,
            forceRefresh: false
        )
        if cachedHealth.status == "ok" {
            return cachedHealth
        }

        let refreshedHealth = refreshPrimaryHealth(
            on: primaryServer,
            fallback: nil,
            forceRefresh: true
        )
        if refreshedHealth.status == "ok" {
            return refreshedHealth
        }

        return fallback.status == "ok" ? fallback : refreshedHealth
    }

    private func storedPreferredAccount(for provider: String) -> String {
        switch provider.lowercased() {
        case "claude": return settings.advisorySelectedClaudeAccount
        case "gemini": return settings.advisorySelectedGeminiAccount
        case "codex": return settings.advisorySelectedCodexAccount
        default: return ""
        }
    }

    private func writePreferredAccount(provider: String, accountName: String) {
        switch provider.lowercased() {
        case "claude": settings.advisorySelectedClaudeAccount = accountName
        case "gemini": settings.advisorySelectedGeminiAccount = accountName
        case "codex": settings.advisorySelectedCodexAccount = accountName
        default: break
        }
    }

    private func shouldRetryPrimary(for status: String) -> Bool {
        switch AdvisoryBridgeStatusInterpreter.normalizedStatus(status) {
        case "timeout", "busy", "transport_failure", "socket_missing", "starting", "unavailable":
            return true
        default:
            return false
        }
    }

    private func rememberRecentExecutionHealth(_ health: AdvisoryBridgeHealth) {
        recentExecutionHealth = health
        recentExecutionHealthValidUntil = Date().addingTimeInterval(10)
    }

    private func preferredRecentExecutionHealth(
        over health: AdvisoryBridgeHealth,
        forceRefresh: Bool
    ) -> AdvisoryBridgeHealth {
        guard !forceRefresh else {
            recentExecutionHealth = nil
            recentExecutionHealthValidUntil = nil
            return health
        }
        guard
            let override = recentExecutionHealth,
            let validUntil = recentExecutionHealthValidUntil,
            validUntil > Date(),
            override.status == "ok",
            health.status == "ok",
            override.activeProviderName != nil,
            override.activeProviderName != health.activeProviderName,
            override.providerStatuses.contains(where: {
                $0.status != "ok" || ($0.cooldownRemainingSeconds ?? 0) > 0
            })
        else {
            return health
        }
        return override
    }

    private func preparePrimaryRetry(for status: String) {
        switch AdvisoryBridgeStatusInterpreter.normalizedStatus(status) {
        case "socket_missing", "transport_failure", "hung_start":
            // Transport-level failure — sidecar likely dead, restart is appropriate
            supervisor?.restart()
        case "timeout", "busy", "starting", "unavailable":
            // Timeout may mean sidecar is busy, not dead — don't kill it
            supervisor?.prepareForExecution()
        default:
            break
        }
    }

    private func refreshPrimaryHealth(
        on primaryServer: AdvisoryBridgeServerProtocol,
        fallback: AdvisoryBridgeHealth? = nil,
        forceRefresh: Bool = false
    ) -> AdvisoryBridgeHealth {
        let health = forceRefresh ? primaryServer.refreshHealth() : primaryServer.health()
        supervisor?.record(health: health)
        if forceRefresh || health.status == "ok" || fallback == nil {
            return health
        }
        if fallback?.status == "ok" {
            return fallback!
        }
        return health
    }

    private func fallbackHealth(
        status: String,
        attemptedPrimaryHealth: AdvisoryBridgeHealth? = nil
    ) -> AdvisoryBridgeHealth {
        let base = fallbackServer.health()
        return AdvisoryBridgeHealth(
            runtimeName: base.runtimeName,
            status: status,
            providerName: base.providerName,
            transport: base.transport,
            statusDetail: attemptedPrimaryHealth?.statusDetail ?? attemptedPrimaryHealth?.status,
            lastError: attemptedPrimaryHealth?.lastError,
            recommendedAction: attemptedPrimaryHealth?.recommendedAction,
            activeProviderName: attemptedPrimaryHealth?.activeProviderName,
            providerOrder: attemptedPrimaryHealth?.providerOrder ?? [],
            availableProviders: attemptedPrimaryHealth?.availableProviders ?? [],
            providerStatuses: attemptedPrimaryHealth?.providerStatuses ?? [],
            checkedAt: attemptedPrimaryHealth?.checkedAt
        )
    }

    private func effectiveStatus(
        mode: AdvisoryBridgeMode,
        health: AdvisoryBridgeHealth,
        supervisor: AdvisorySidecarSupervisorSnapshot?
    ) -> String {
        switch mode {
        case .stubOnly:
            return "stub_only"
        case .preferSidecar:
            if health.status == "ok" {
                return "ready"
            }
            if health.status == "fallback_stub" {
                let degradedStatus = AdvisoryBridgeStatusInterpreter.normalizedStatus(
                    health.lastError ?? health.statusDetail ?? ""
                )
                switch degradedStatus {
                case "session_expired", "no_provider", "timeout", "busy", "transport_failure", "socket_missing", "hung_start":
                    return degradedStatus
                default:
                    break
                }
                if let supervisor, supervisor.status == "starting" {
                    return "starting"
                }
                if let supervisor, supervisor.status == "backoff" {
                    return "backoff"
                }
                return "fallback"
            }
            let normalized = AdvisoryBridgeStatusInterpreter.normalizedStatus(health.status)
            switch normalized {
            case "session_expired", "no_provider", "timeout", "busy", "transport_failure", "socket_missing", "hung_start":
                return normalized
            default:
                return supervisor?.status ?? "fallback"
            }
        case .requireSidecar:
            if health.status == "ok" {
                return "ready"
            }
            let normalized = AdvisoryBridgeStatusInterpreter.normalizedStatus(health.status)
            switch normalized {
            case "session_expired", "no_provider", "timeout", "busy", "transport_failure", "socket_missing", "hung_start":
                return normalized
            default:
                return supervisor?.status ?? normalized
            }
        }
    }
}

private struct PrimaryExecutionFailure: Error {
    let message: String
    let health: AdvisoryBridgeHealth
}

private final class AdvisorySidecarSupervisorRegistry: @unchecked Sendable {
    static let shared = AdvisorySidecarSupervisorRegistry()

    private var supervisors: [String: AdvisorySidecarSupervisor] = [:]
    private let lock = NSLock()

    func sharedSupervisor(
        autoStart: Bool,
        socketPath: String,
        healthCheckIntervalSeconds: Int,
        maxConsecutiveFailures: Int,
        runtimeStatus: AdvisorySidecarRuntimeStatus,
        probeTimeoutSeconds: Int,
        environmentOverrides: [String: String]
    ) -> AdvisorySidecarSupervisor {
        let key = socketPath
        lock.lock()
        defer { lock.unlock() }
        if let existing = supervisors[key] {
            existing.updateConfiguration(
                autoStart: autoStart,
                healthCheckIntervalSeconds: healthCheckIntervalSeconds,
                maxConsecutiveFailures: maxConsecutiveFailures,
                runtimeStatus: runtimeStatus,
                probeTimeoutSeconds: probeTimeoutSeconds,
                environmentOverrides: environmentOverrides
            )
            return existing
        }
        let created = AdvisorySidecarSupervisor(
            autoStart: autoStart,
            socketPath: socketPath,
            healthCheckIntervalSeconds: healthCheckIntervalSeconds,
            maxConsecutiveFailures: maxConsecutiveFailures,
            runtimeStatus: runtimeStatus,
            probeTimeoutSeconds: probeTimeoutSeconds,
            environmentOverrides: environmentOverrides
        )
        supervisors[key] = created
        return created
    }

    func shutdownAll() {
        lock.lock()
        let currentSupervisors = Array(supervisors.values)
        supervisors.removeAll()
        lock.unlock()

        for supervisor in currentSupervisors {
            supervisor.shutdown()
        }
    }
}

private struct AdvisorySidecarPidfileRecord {
    let pid: pid_t
    let socketPath: String?
    let startedAt: String?
    let instanceID: String?
}

private struct AdvisorySidecarPidfilePayload: Decodable {
    let pid: Int32
    let socketPath: String?
    let startedAt: String?
    let instanceID: String?

    enum CodingKeys: String, CodingKey {
        case pid
        case socketPath = "socket_path"
        case startedAt = "started_at"
        case instanceID = "instance_id"
    }
}

private enum AdvisorySidecarProcessJanitor {
    static func cleanup(keepingSocketPath: String?) {
        let lines = runningSidecarLines()
        guard !lines.isEmpty else { return }

        for line in lines {
            guard let parsed = parse(line) else { continue }
            let pidfilePath = parsed.socketPath.map { $0 + ".pid" }
            let pidfileRecord = pidfilePath.flatMap(readPidfileRecord(atPath:))
            let ownedSocketPath = pidfileRecord?.socketPath ?? parsed.socketPath
            if let keepingSocketPath, ownedSocketPath == keepingSocketPath {
                continue
            }

            let ownerPID = pidfileRecord?.pid ?? parsed.pid
            let stopped = terminatePID(ownerPID, reason: "janitor cleanup")
            if stopped, let ownedSocketPath {
                cleanupArtifacts(
                    socketPath: ownedSocketPath,
                    pidfilePath: ownedSocketPath + ".pid",
                    expectedPID: ownerPID
                )
            }
        }
    }

    private static func runningSidecarLines() -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-fal", "memograph_advisor.py"]
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                return []
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            return text
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    private static func parse(_ line: String) -> (pid: pid_t, socketPath: String?)? {
        let pieces = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let pidText = pieces.first,
              let pid = Int32(pidText) else {
            return nil
        }

        let command = pieces.count > 1 ? String(pieces[1]) : ""
        guard command.contains("memograph_advisor.py") else {
            return nil
        }

        let socketPath: String?
        if let range = command.range(of: "--socket ") {
            let suffix = command[range.upperBound...]
            socketPath = suffix.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init)
        } else {
            socketPath = nil
        }

        return (pid: pid, socketPath: socketPath)
    }

    private static func readPidfileRecord(atPath path: String) -> AdvisorySidecarPidfileRecord? {
        guard
            let contents = try? String(contentsOfFile: path, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !contents.isEmpty
        else {
            return nil
        }

        if let data = contents.data(using: .utf8),
           let payload = try? JSONDecoder().decode(AdvisorySidecarPidfilePayload.self, from: data),
           payload.pid > 0 {
            return AdvisorySidecarPidfileRecord(
                pid: payload.pid,
                socketPath: payload.socketPath,
                startedAt: payload.startedAt,
                instanceID: payload.instanceID
            )
        }

        guard let pid = Int32(contents), pid > 0 else {
            return nil
        }
        return AdvisorySidecarPidfileRecord(pid: pid, socketPath: nil, startedAt: nil, instanceID: nil)
    }

    private static func terminatePID(_ pid: pid_t, reason: String) -> Bool {
        guard pid > 1 else { return false }
        if !processIsAlive(pid) {
            return true
        }

        _ = Darwin.kill(pid, SIGTERM)
        if waitForExit(pid: pid, timeoutSeconds: 2) {
            return true
        }

        _ = Darwin.kill(pid, SIGKILL)
        return waitForExit(pid: pid, timeoutSeconds: 2)
    }

    private static func waitForExit(pid: pid_t, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !processIsAlive(pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !processIsAlive(pid)
    }

    private static func processIsAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private static func cleanupArtifacts(socketPath: String, pidfilePath: String, expectedPID: pid_t?) {
        if let expectedPID, processIsAlive(expectedPID) {
            return
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        if FileManager.default.fileExists(atPath: pidfilePath) {
            try? FileManager.default.removeItem(atPath: pidfilePath)
        }
    }
}

private struct AdvisorySidecarSupervisorSnapshot {
    let status: String
    let autoStartEnabled: Bool
    let socketPresent: Bool
    let processRunning: Bool
    let consecutiveFailures: Int
    let lastError: String?
    let recommendedAction: String?
}

private enum AdvisoryBridgeStatusInterpreter {
    static func normalizedStatus(_ rawStatus: String) -> String {
        let lower = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty {
            return "unavailable"
        }
        if lower == "ok" || lower == "ready" {
            return "ok"
        }
        if lower.contains("fallback") {
            return "fallback_stub"
        }
        if lower.contains("starting") {
            return "starting"
        }
        if lower.contains("hung") {
            return "hung_start"
        }
        if lower.contains("backoff") {
            return "backoff"
        }
        if lower.contains("session") && (lower.contains("expired") || lower.contains("missing")) {
            return "session_expired"
        }
        if lower.contains("binary") && lower.contains("missing") {
            return "no_provider"
        }
        if lower.contains("no_provider") || (lower.contains("no") && lower.contains("provider")) {
            return "no_provider"
        }
        if lower.contains("socket_missing") || (lower.contains("socket") && lower.contains("missing")) {
            return "socket_missing"
        }
        if lower.contains("timeout") || lower.contains("timed out") {
            return "timeout"
        }
        if lower.contains("busy") || lower.contains("refresh_in_progress") || lower.contains("in progress") {
            return "busy"
        }
        if lower.contains("transport") || lower.contains("connect") || lower.contains("broken pipe") {
            return "transport_failure"
        }
        if lower.contains("unavailable") {
            return "unavailable"
        }
        return lower.replacingOccurrences(of: " ", with: "_")
    }

    static func recommendedAction(
        for status: String,
        autoStartEnabled: Bool
    ) -> String? {
        switch normalizedStatus(status) {
        case "ok", "fallback_stub":
            return normalizedStatus(status) == "fallback_stub"
                ? "Memograph продолжает advisory в fallback режиме."
                : nil
        case "session_expired":
            return "Provider session expired. Перелогинь CLI provider для memograph-advisor."
        case "no_provider":
            return "No provider available. Проверь Claude/Gemini/Codex subscriptions или routing sidecar."
        case "socket_missing":
            return autoStartEnabled
                ? "memograph-advisor ещё не поднят. Memograph попробует запустить его автоматически."
                : "memograph-advisor не запущен. Подними sidecar вручную или включи auto-start."
        case "hung_start":
            return "memograph-advisor завис на старте до создания сокета. Его нужно перезапустить принудительно."
        case "timeout":
            return "memograph-advisor не ответил вовремя. Возможно, runtime перегружен."
        case "busy":
            return "memograph-advisor сейчас занят. Повтори проверку позже, не считая это transport failure."
        case "transport_failure":
            return "Связь с memograph-advisor сломалась. Проверь socket и sidecar process."
        case "backoff":
            return "Sidecar временно ушёл в backoff после повторяющихся сбоев."
        case "starting":
            return "Sidecar запускается. Advisory пока может работать через fallback."
        default:
            return "Advisory sidecar временно ограничен, но core Memograph продолжает работать."
        }
    }

    static func health(
        runtimeName: String,
        status rawStatus: String,
        providerName: String,
        transport: String,
        detail: String? = nil,
        lastError: String? = nil,
        autoStartEnabled: Bool = false,
        activeProviderName: String? = nil,
        providerOrder: [String] = [],
        availableProviders: [String] = [],
        providerStatuses: [AdvisoryProviderDiagnostic] = [],
        checkedAt: String? = nil,
        runtimeHealthTier: String? = nil,
        providerHealthTier: String? = nil
    ) -> AdvisoryBridgeHealth {
        let normalized = normalizedStatus(rawStatus)
        return AdvisoryBridgeHealth(
            runtimeName: runtimeName,
            status: normalized,
            providerName: providerName,
            transport: transport,
            statusDetail: detail,
            lastError: lastError,
            recommendedAction: recommendedAction(for: normalized, autoStartEnabled: autoStartEnabled),
            activeProviderName: activeProviderName,
            providerOrder: providerOrder,
            availableProviders: availableProviders,
            providerStatuses: providerStatuses,
            checkedAt: checkedAt,
            runtimeHealthTier: runtimeHealthTier,
            providerHealthTier: providerHealthTier
        )
    }

    static func health(
        from error: Error,
        runtimeName: String,
        providerName: String,
        transport: String,
        autoStartEnabled: Bool = false
    ) -> AdvisoryBridgeHealth {
        let message = error.localizedDescription
        return health(
            runtimeName: runtimeName,
            status: normalizedStatus(message),
            providerName: providerName,
            transport: transport,
            detail: message,
            lastError: message,
            autoStartEnabled: autoStartEnabled
        )
    }
}

private final class AdvisorySidecarSupervisor: @unchecked Sendable {
    private enum StartupState: Equatable {
        case stopped
        case starting
        case ready
        case hungStart
    }

    private var autoStart: Bool
    private let socketPath: String
    private var pidfilePath: String { socketPath + ".pid" }
    private var healthCheckIntervalSeconds: Int
    private var maxConsecutiveFailures: Int
    private var runtimeStatus: AdvisorySidecarRuntimeStatus
    private var probeTimeoutSeconds: Int
    private var environmentOverrides: [String: String]
    private var startupGracePeriod: TimeInterval
    private let logger = Logger.advisory
    private let lock = NSLock()
    private var consecutiveFailures = 0
    private var lastHealthCheckAt: Date?
    private var lastStartAttemptAt: Date?
    private var launchBeganAt: Date?
    private var lastKnownStatus = "socket_missing"
    private var lastError: String?
    private var process: Process?
    private var ignoredTerminationPIDs: Set<pid_t> = []

    init(
        autoStart: Bool,
        socketPath: String,
        healthCheckIntervalSeconds: Int,
        maxConsecutiveFailures: Int,
        runtimeStatus: AdvisorySidecarRuntimeStatus,
        probeTimeoutSeconds: Int,
        environmentOverrides: [String: String]
    ) {
        self.autoStart = autoStart
        self.socketPath = socketPath
        self.healthCheckIntervalSeconds = max(5, healthCheckIntervalSeconds)
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
        self.runtimeStatus = runtimeStatus
        self.probeTimeoutSeconds = max(2, probeTimeoutSeconds)
        self.environmentOverrides = environmentOverrides
        self.startupGracePeriod = Self.parseStartupGracePeriod(from: environmentOverrides)
    }

    func updateConfiguration(
        autoStart: Bool,
        healthCheckIntervalSeconds: Int,
        maxConsecutiveFailures: Int,
        runtimeStatus: AdvisorySidecarRuntimeStatus,
        probeTimeoutSeconds: Int,
        environmentOverrides: [String: String]
    ) {
        lock.lock()
        self.autoStart = autoStart
        self.healthCheckIntervalSeconds = max(5, healthCheckIntervalSeconds)
        self.maxConsecutiveFailures = max(1, maxConsecutiveFailures)
        self.runtimeStatus = runtimeStatus
        self.probeTimeoutSeconds = max(2, probeTimeoutSeconds)
        self.environmentOverrides = environmentOverrides
        self.startupGracePeriod = Self.parseStartupGracePeriod(from: environmentOverrides)
        lock.unlock()
    }

    func prepareForHealthCheck() {
        recoverHungStartIfNeeded(now: Date())
        guard shouldAttempt(now: Date(), force: false) else { return }
        ensureStarted()
    }

    func prepareForExecution() {
        recoverHungStartIfNeeded(now: Date())
        guard shouldAttempt(now: Date(), force: true) else { return }
        ensureStarted()
    }

    func record(health: AdvisoryBridgeHealth) {
        lock.lock()
        defer { lock.unlock() }
        lastHealthCheckAt = Date()
        lastKnownStatus = AdvisoryBridgeStatusInterpreter.normalizedStatus(health.status)
        lastError = health.lastError ?? health.statusDetail
        if health.status == "ok" {
            consecutiveFailures = 0
            launchBeganAt = nil
            lastError = nil
        } else if countsAsFailureStatus(lastKnownStatus) {
            consecutiveFailures = min(maxConsecutiveFailures, consecutiveFailures + 1)
        } else {
            consecutiveFailures = 0
        }
    }

    func recordSuccess() {
        lock.lock()
        consecutiveFailures = 0
        lastHealthCheckAt = Date()
        lastKnownStatus = "ok"
        launchBeganAt = nil
        lastError = nil
        lock.unlock()
    }

    func recordFailure(reason: String? = nil) {
        lock.lock()
        lastHealthCheckAt = Date()
        if let reason, !reason.isEmpty {
            lastError = reason
            lastKnownStatus = AdvisoryBridgeStatusInterpreter.normalizedStatus(reason)
        } else {
            lastKnownStatus = consecutiveFailures >= maxConsecutiveFailures ? "backoff" : "unavailable"
        }
        if countsAsFailureStatus(lastKnownStatus) {
            consecutiveFailures = min(maxConsecutiveFailures, consecutiveFailures + 1)
        } else {
            consecutiveFailures = 0
        }
        lock.unlock()
    }

    func shutdown() {
        let runningProcess: Process?
        let managedPID: pid_t?
        let externalPID: pid_t?
        lock.lock()
        runningProcess = process
        process = nil
        managedPID = runningProcess?.processIdentifier
        if let managedPID {
            ignoredTerminationPIDs.insert(managedPID)
        }
        externalPID = readLivePIDFromPidfile(excluding: managedPID)
        lastStartAttemptAt = nil
        launchBeganAt = nil
        lastKnownStatus = "socket_missing"
        lastError = nil
        consecutiveFailures = 0
        lock.unlock()

        if let runningProcess, runningProcess.isRunning {
            _ = terminateTrackedProcess(runningProcess, reason: "shutdown")
        }
        if let externalPID, externalPID != managedPID {
            _ = terminatePID(externalPID, reason: "shutdown orphan owner")
        }
        cleanupRuntimeArtifacts(expectedPID: externalPID ?? managedPID)
    }

    func restart() {
        shutdown()
        prepareForExecution()
    }

    func snapshot(currentHealth: AdvisoryBridgeHealth?) -> AdvisorySidecarSupervisorSnapshot {
        let socketPresent = FileManager.default.fileExists(atPath: socketPath)
        lock.lock()
        let processRunning = process?.isRunning ?? false
        let currentFailures = consecutiveFailures
        let currentError = lastError
        let autoStartEnabled = autoStart
        let failureBudget = maxConsecutiveFailures
        let currentRuntimeStatus = runtimeStatus
        let launchBeganAt = self.launchBeganAt
        let baseStatus = currentHealth.map { AdvisoryBridgeStatusInterpreter.normalizedStatus($0.status) } ?? lastKnownStatus
        let status: String
        let baseRuntimeError: String?
        switch currentRuntimeStatus {
        case .ready:
            baseRuntimeError = nil
        case .missingPython(let details), .missingScript(let details):
            baseRuntimeError = details
        }

        let startupState = currentStartupState(
            now: Date(),
            socketPresent: socketPresent,
            processRunning: processRunning,
            launchBeganAt: launchBeganAt
        )

        if startupState == .hungStart {
            status = "hung_start"
        } else if processRunning && !socketPresent {
            status = "starting"
        } else if baseRuntimeError != nil {
            status = "unavailable"
        } else if currentFailures >= failureBudget && baseStatus != "ok" {
            status = "backoff"
        } else if socketPresent && baseStatus == "socket_missing" {
            status = "unavailable"
        } else {
            status = baseStatus
        }
        lock.unlock()

        return AdvisorySidecarSupervisorSnapshot(
            status: status,
            autoStartEnabled: autoStartEnabled,
            socketPresent: socketPresent,
            processRunning: processRunning,
            consecutiveFailures: currentFailures,
            lastError: currentError ?? baseRuntimeError,
            recommendedAction: AdvisoryBridgeStatusInterpreter.recommendedAction(
                for: status,
                autoStartEnabled: autoStartEnabled
            )
        )
    }

    private func shouldAttempt(now: Date, force: Bool) -> Bool {
        let socketPresent = FileManager.default.fileExists(atPath: socketPath)
        lock.lock()
        defer { lock.unlock() }
        guard autoStart || force else {
            return false
        }
        if let process, process.isRunning {
            return false
        }
        if socketPresent {
            if !force {
                return false
            }
            if !restartableStatus(lastKnownStatus) {
                return false
            }
        }
        if !force && consecutiveFailures >= maxConsecutiveFailures {
            return false
        }
        if !force,
           let lastStartAttemptAt,
           now.timeIntervalSince(lastStartAttemptAt) < Double(healthCheckIntervalSeconds) {
            return false
        }
        return true
    }

    private func ensureStarted() {
        let runtimeStatus: AdvisorySidecarRuntimeStatus
        let probeTimeoutSeconds: Int
        let environmentOverrides: [String: String]
        let previousProcess: Process?
        let failureBudget: Int
        lock.lock()
        // If process is currently running, don't even proceed — prevents race
        // where two threads both read process=nil and both launch a new one
        if let existing = process, existing.isRunning {
            lastKnownStatus = "ok"
            lock.unlock()
            return
        }
        runtimeStatus = self.runtimeStatus
        probeTimeoutSeconds = self.probeTimeoutSeconds
        environmentOverrides = self.environmentOverrides
        lastStartAttemptAt = Date()
        previousProcess = process
        failureBudget = maxConsecutiveFailures
        lock.unlock()

        switch runtimeStatus {
        case .missingPython(let details), .missingScript(let details):
            lock.lock()
            lastKnownStatus = "unavailable"
            lastError = details
            lock.unlock()
            logger.error("Advisory sidecar runtime missing: \(details, privacy: .public)")
            return
        case .ready:
            break
        }

        do {
            // If we already have a running process, trust it — do not probe,
            // delete the socket, or launch a competing process.  The previous
            // probe-based path could time out when the sidecar was merely busy
            // (e.g. handling a long-running forceRefresh), leading to a race
            // where the socket was deleted and a second sidecar launched.
            if let previousProcess, previousProcess.isRunning {
                lock.lock()
                lastKnownStatus = "ok"
                lock.unlock()
                return
            }

            // Check pidfile for existing owner before probing or launching.
            // A live owner without a socket is only tolerated inside the startup grace window.
            if let pidfileRecord = readPidfileRecord() {
                if processIsAlive(pidfileRecord.pid) {
                    if FileManager.default.fileExists(atPath: socketPath) {
                        lock.lock()
                        lastKnownStatus = "ok"
                        lastError = nil
                        lock.unlock()
                        return
                    }

                    if pidfileIndicatesHungStart(pidfileRecord, now: Date()) {
                        _ = terminatePID(pidfileRecord.pid, reason: "startup watchdog: pidfile owner never created socket")
                        cleanupRuntimeArtifacts(expectedPID: pidfileRecord.pid)
                    } else {
                        lock.lock()
                        lastKnownStatus = "starting"
                        lastError = nil
                        lock.unlock()
                        return
                    }
                } else {
                    // Stale pidfile — process is dead, clean up
                    try? FileManager.default.removeItem(atPath: pidfilePath)
                }
            }

            let parentDirectory = (socketPath as NSString).deletingLastPathComponent
            if !parentDirectory.isEmpty {
                try FileManager.default.createDirectory(
                    atPath: parentDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            }

            if let previousProcess, !previousProcess.isRunning, FileManager.default.fileExists(atPath: socketPath) {
                // Process we launched is dead — safe to clean up its socket
                try? FileManager.default.removeItem(atPath: socketPath)
            } else if FileManager.default.fileExists(atPath: socketPath) {
                // Socket exists but we didn't launch the process (or it predates us).
                // Probe it — if responsive OR merely busy (timeout), do not delete.
                if probeExistingSocketIsResponsive() {
                    lock.lock()
                    lastKnownStatus = "ok"
                    lastError = nil
                    lock.unlock()
                    return
                }
                // Probe returned socket_missing / transport_failure / unavailable.
                // Check if another process owns this socket via connect attempt.
                // Only delete if connect truly fails (not just slow).
                let connectFd = socket(AF_UNIX, SOCK_STREAM, 0)
                var canConnect = false
                if connectFd >= 0 {
                    var address = sockaddr_un()
                    address.sun_family = sa_family_t(AF_UNIX)
                    socketPath.withCString { pathPointer in
                        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
                            memcpy(rawBuffer.baseAddress, pathPointer, strlen(pathPointer))
                        }
                    }
                    var addressCopy = address
                    let result = withUnsafePointer(to: &addressCopy) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            Darwin.connect(connectFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                        }
                    }
                    canConnect = result == 0
                    close(connectFd)
                }
                if canConnect {
                    // Socket is connectable — something is listening. Treat as busy.
                    lock.lock()
                    lastKnownStatus = "busy"
                    lastError = nil
                    lock.unlock()
                    return
                }
                // Socket is truly dead — remove and proceed to launch
                try? FileManager.default.removeItem(atPath: socketPath)
            }

            guard case let .ready(environment) = runtimeStatus else {
                return
            }
            let process = Process()
            process.executableURL = environment.executableURL
            process.arguments = environment.launchArgumentsPrefix + [
                environment.scriptPath,
                "--socket",
                socketPath,
                "--probe-timeout-seconds",
                String(probeTimeoutSeconds)
            ]
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment.baseEnvironment) { _, new in new }
                .merging(environmentOverrides) { _, new in new }
            process.standardInput = nil
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            process.terminationHandler = { [weak self] process in
                self?.handleTermination(process)
            }
            try process.run()
            lock.lock()
            self.process = process
            self.launchBeganAt = Date()
            self.lastKnownStatus = "starting"
            self.lastError = nil
            lock.unlock()
            _ = waitForSocketReady(timeoutSeconds: 3)
            logger.info("Attempted to auto-start advisory sidecar at \(self.socketPath, privacy: .public)")
            // Give sidecar time to complete initial provider probes before
            // the first health check. Without this, the 3s non-forceRefresh
            // timeout hits before probes finish → false "degraded" state.
            if probeExistingSocketIsResponsive() {
                lock.lock()
                lastKnownStatus = "ok"
                launchBeganAt = nil
                lastError = nil
                consecutiveFailures = 0
                lock.unlock()
            }
        } catch {
            lock.lock()
            consecutiveFailures = min(failureBudget, consecutiveFailures + 1)
            launchBeganAt = nil
            lastKnownStatus = AdvisoryBridgeStatusInterpreter.normalizedStatus(error.localizedDescription)
            lastError = error.localizedDescription
            lock.unlock()
            logger.error("Failed to auto-start advisory sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTermination(_ process: Process) {
        let processIdentifier = process.processIdentifier
        let reason = "memograph-advisor exited (\(process.terminationReason.rawValue):\(process.terminationStatus))"
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        launchBeganAt = nil
        if ignoredTerminationPIDs.remove(processIdentifier) != nil {
            lock.unlock()
            logger.info("memograph-advisor exit ignored for managed shutdown pid=\(processIdentifier, privacy: .public)")
            return
        }
        let failureBudget = maxConsecutiveFailures
        lastKnownStatus = AdvisoryBridgeStatusInterpreter.normalizedStatus(reason)
        lastError = reason
        consecutiveFailures = min(failureBudget, consecutiveFailures + 1)
        lock.unlock()
        logger.error("\(reason, privacy: .public)")
    }

    private func probeExistingSocketIsResponsive() -> Bool {
        // Use a generous timeout — sidecar may be busy with a long recipe run
        // or provider probe.  A slow response is not a dead process.
        let probe = JSONRPCAdvisoryBridgeServer(socketPath: socketPath, defaultTimeoutSeconds: 20)
        let health = probe.health()
        switch health.status {
        case "socket_missing", "transport_failure", "unavailable":
            return false
        default:
            // "timeout" means sidecar is likely busy, not dead — treat as alive
            return true
        }
    }

    private func waitForSocketReady(timeoutSeconds: TimeInterval) -> Bool {
        if FileManager.default.fileExists(atPath: socketPath) { return true }

        let semaphore = DispatchSemaphore(value: 0)
        let dirURL = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: Darwin.open(dirURL.path, O_EVTONLY),
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler {
            if FileManager.default.fileExists(atPath: self.socketPath) {
                semaphore.signal()
            }
        }
        source.setCancelHandler {
            Darwin.close(source.handle)
        }
        source.resume()

        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        source.cancel()

        if result == .success { return true }
        return FileManager.default.fileExists(atPath: socketPath)
    }

    private func readLivePIDFromPidfile(excluding managedPID: pid_t?) -> pid_t? {
        guard
            let pid = readPidfileRecord()?.pid,
            pid > 0,
            managedPID != pid,
            processIsAlive(pid)
        else {
            return nil
        }
        return pid
    }

    private func readPidfileRecord() -> AdvisorySidecarPidfileRecord? {
        guard
            let contents = try? String(contentsOfFile: pidfilePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !contents.isEmpty
        else {
            return nil
        }

        if let data = contents.data(using: .utf8),
           let payload = try? JSONDecoder().decode(AdvisorySidecarPidfilePayload.self, from: data),
           payload.pid > 0 {
            return AdvisorySidecarPidfileRecord(
                pid: payload.pid,
                socketPath: payload.socketPath,
                startedAt: payload.startedAt,
                instanceID: payload.instanceID
            )
        }

        guard let pid = Int32(contents), pid > 0 else {
            return nil
        }
        return AdvisorySidecarPidfileRecord(pid: pid, socketPath: nil, startedAt: nil, instanceID: nil)
    }

    private func terminateTrackedProcess(_ process: Process, reason: String) -> Bool {
        let pid = process.processIdentifier
        guard pid > 1 else { return !process.isRunning }
        return terminatePID(pid, reason: reason)
    }

    private func terminatePID(_ pid: pid_t, reason: String, timeoutSeconds: TimeInterval = 2) -> Bool {
        guard pid > 1 else { return false }
        if !processIsAlive(pid) {
            return true
        }

        _ = Darwin.kill(pid, SIGTERM)
        if waitForPIDToExit(pid, timeoutSeconds: timeoutSeconds) {
            return true
        }

        _ = Darwin.kill(pid, SIGKILL)
        let terminated = waitForPIDToExit(pid, timeoutSeconds: timeoutSeconds)
        if !terminated {
            logger.error("Failed to terminate advisory sidecar pid=\(pid, privacy: .public) reason=\(reason, privacy: .public)")
        }
        return terminated
    }

    private func waitForPIDToExit(_ pid: pid_t, timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if !processIsAlive(pid) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return !processIsAlive(pid)
    }

    private func cleanupRuntimeArtifacts(expectedPID: pid_t?) {
        if let expectedPID, processIsAlive(expectedPID) {
            return
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        try? FileManager.default.removeItem(atPath: pidfilePath)
    }

    private func pidfileIndicatesHungStart(_ record: AdvisorySidecarPidfileRecord, now: Date) -> Bool {
        guard let startedAt = record.startedAt else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        guard let startedDate = formatter.date(from: startedAt) else {
            return false
        }
        return now.timeIntervalSince(startedDate) > startupGracePeriod
    }

    private func recoverHungStartIfNeeded(now: Date) {
        let trackedProcess: Process?
        let managedPID: pid_t?
        let externalPID: pid_t?
        let reason: String

        lock.lock()
        let socketPresent = FileManager.default.fileExists(atPath: socketPath)
        let processRunning = process?.isRunning == true
        let startupState = currentStartupState(
            now: now,
            socketPresent: socketPresent,
            processRunning: processRunning,
            launchBeganAt: launchBeganAt
        )
        guard startupState == .hungStart else {
            lock.unlock()
            return
        }
        trackedProcess = process
        managedPID = trackedProcess?.processIdentifier
        if let managedPID {
            ignoredTerminationPIDs.insert(managedPID)
        }
        process = nil
        externalPID = readLivePIDFromPidfile(excluding: managedPID)
        launchBeganAt = nil
        lastStartAttemptAt = nil
        lastKnownStatus = "hung_start"
        reason = "startup watchdog: socket never appeared"
        lastError = reason
        consecutiveFailures = min(maxConsecutiveFailures, consecutiveFailures + 1)
        lock.unlock()

        if let trackedProcess, trackedProcess.isRunning {
            _ = terminateTrackedProcess(trackedProcess, reason: reason)
        }
        if let externalPID, externalPID != managedPID {
            _ = terminatePID(externalPID, reason: reason)
        }
        cleanupRuntimeArtifacts(expectedPID: externalPID ?? managedPID)
    }

    private func currentStartupState(
        now: Date,
        socketPresent: Bool,
        processRunning: Bool,
        launchBeganAt: Date?
    ) -> StartupState {
        if processRunning && socketPresent {
            return .ready
        }
        if processRunning,
           let launchBeganAt,
           now.timeIntervalSince(launchBeganAt) > startupGracePeriod {
            return .hungStart
        }
        if processRunning {
            return .starting
        }
        return .stopped
    }

    private static func parseStartupGracePeriod(from environmentOverrides: [String: String]) -> TimeInterval {
        guard
            let rawValue = environmentOverrides["MEMOGRAPH_ADVISOR_STARTUP_GRACE_SECONDS"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            let value = Double(rawValue),
            value >= 1
        else {
            return 15
        }
        return value
    }

    private func processIsAlive(_ pid: pid_t) -> Bool {
        Darwin.kill(pid, 0) == 0 || errno == EPERM
    }

    private func countsAsFailureStatus(_ status: String) -> Bool {
        restartableStatus(status)
    }

    private func restartableStatus(_ status: String) -> Bool {
        switch status {
        case "socket_missing", "transport_failure", "timeout", "unavailable", "backoff", "hung_start":
            return true
        default:
            return false
        }
    }
}

final class LocalAdvisoryBridgeStub: AdvisoryBridgeServerProtocol {
    private let heuristicRunner = AdvisoryLocalHeuristicRunner()

    func health() -> AdvisoryBridgeHealth {
        AdvisoryBridgeHealth(
            runtimeName: "memograph-advisor-stub",
            status: "ok",
            providerName: "local_stub",
            transport: "in_process",
            runtimeHealthTier: "ok",
            providerHealthTier: "stub_only"
        )
    }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        if let result = heuristicRunner.runRecipe(request) {
            return result
        }

        if let result = richFallbackResult(for: request) {
            return result
        }

        return AdvisoryRecipeResult(
            runId: request.runId,
            artifactProposals: [],
            continuityProposals: [],
            source: "stub"
        )
    }

    func cancelRun(runId: String) {}

}

private extension LocalAdvisoryBridgeStub {
    func richFallbackResult(for request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult? {
        switch request.packet {
        case .reflection(let packet):
            switch request.recipeName {
            case "continuity_resume":
                guard let proposal = composeContinuityResumeFallback(packet: packet, request: request) else { return nil }
                return makeResult(runId: request.runId, proposal: proposal)
            case "writing_seed":
                guard let proposal = WritingSeedComposer().compose(packet: packet, recipeName: request.recipeName) else { return nil }
                return makeResult(runId: request.runId, proposal: proposal)
            case "research_direction":
                guard let proposal = composeResearchDirectionFallback(packet: packet, request: request) else { return nil }
                return makeResult(runId: request.runId, proposal: proposal)
            case "focus_reflection":
                guard let proposal = composeFocusReflectionFallback(packet: packet, request: request) else { return nil }
                return makeResult(runId: request.runId, proposal: proposal)
            case "social_signal":
                guard let proposal = composeSocialSignalFallback(packet: packet, request: request) else { return nil }
                return makeResult(runId: request.runId, proposal: proposal)
            case "health_pulse":
                guard let proposal = composeHealthPulseFallback(packet: packet, request: request) else { return nil }
                return makeResult(runId: request.runId, proposal: proposal)
            case "decision_review":
                guard let proposal = composeDecisionReviewFallback(packet: packet, request: request) else { return nil }
                return makeResult(runId: request.runId, proposal: proposal)
            case "life_admin_review":
                guard let proposal = composeLifeAdminFallback(packet: packet, request: request) else { return nil }
                return makeResult(runId: request.runId, proposal: proposal)
            default:
                return nil
            }
        case .thread(let packet):
            guard request.recipeName == "tweet_from_thread",
                  let proposal = ThreadWritingSeedComposer().compose(packet: packet, recipeName: request.recipeName) else {
                return nil
            }
            return makeResult(runId: request.runId, proposal: proposal)
        case .weekly(let packet):
            guard request.recipeName == "weekly_reflection",
                  let proposal = WeeklyReviewComposer().compose(packet: packet, recipeName: request.recipeName) else {
                return nil
            }
            return makeResult(runId: request.runId, proposal: proposal)
        }
    }

    func makeResult(runId: String, proposal: AdvisoryArtifactCandidate) -> AdvisoryRecipeResult {
        AdvisoryRecipeResult(
            runId: runId,
            artifactProposals: [proposal],
            continuityProposals: [],
            source: "stub"
        )
    }

    func composeContinuityResumeFallback(
        packet: ReflectionPacket,
        request: AdvisoryRecipeRequest
    ) -> AdvisoryArtifactCandidate? {
        guard let thread = packet.candidateThreadRefs.first else { return nil }
        let note = enrichmentItem(for: .notes, in: packet)
        let web = enrichmentItem(for: .webResearch, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let openLoop = packet.candidateContinuityItems.first?.title ?? thread.summary ?? "нить пока больше чувствуется, чем сформулирована"
        let decisionText = packet.candidateContinuityItems.first(where: { $0.kind == .decision })?.body
        let timingWindow = timingWindowHint(calendar: calendar, reminder: reminder)

        var body = "Я заметил, что главная нить сейчас: \(thread.title).\n"
        body += "Где остановился: \(thread.summary ?? openLoop)\n"
        body += "Похоже, незакрытый узел здесь: \(openLoop)."
        if let decisionText, !decisionText.isEmpty {
            body += "\nЧто уже решено: \(AdvisorySupport.cleanedSnippet(decisionText, maxLength: 160))"
        }
        if let note {
            body += "\nИз заметок здесь уже держится опора: «\(note.title)» — \(note.snippet)"
        }
        if let reminder {
            body += "\nЕсть и внешний anchor: \(enrichmentAnchor(for: reminder))."
        } else if let calendar {
            body += "\nЕсть и внешний anchor: \(enrichmentAnchor(for: calendar))."
        }
        if let timingWindow, !timingWindow.isEmpty {
            body += "\nПо timing fit мягче всего возвращаться \(timingWindow)."
        }
        body += "\nЕсли хочешь продолжить, вот 3 хороших входа:"
        body += "\n1. Вернуться в \(thread.title) через open loop."
        body += "\n2. Зафиксировать return point рядом с заметкой или календарным окном."
        body += "\n3. Продолжить только после короткой сверки по следующим шагам."

        let metadata = AdvisoryArtifactGuidanceMetadata(
            summary: thread.summary,
            evidencePack: Array(packet.evidenceRefs.prefix(4)),
            actionSteps: [
                "Вернуться в \(thread.title) через open loop.",
                "Зафиксировать return point рядом с заметкой или календарным окном.",
                "Продолжить только после короткой сверки по следующим шагам."
            ],
            continuityAnchor: timingWindow,
            openLoop: openLoop,
            decisionText: decisionText,
            noteAnchorTitle: note?.title,
            noteAnchorSnippet: note?.snippet,
            sourceAnchors: sourceAnchors(from: [note, web, calendar, reminder]),
            enrichmentSources: enrichmentSources(from: [note, web, calendar, reminder]),
            timingWindow: timingWindow
        )

        return AdvisoryArtifactCandidate(
            domain: .continuity,
            kind: .resumeCard,
            title: "Вернуться в \(thread.title)",
            body: body,
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: 0.72,
            whyNow: "Стартовать лучше через уже видимый return point, а не через абстрактный restart.",
            evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
            metadataJson: AdvisorySupport.encodeJSONString(metadata),
            language: packet.language,
            status: .candidate
        )
    }

    func composeResearchDirectionFallback(
        packet: ReflectionPacket,
        request: AdvisoryRecipeRequest
    ) -> AdvisoryArtifactCandidate? {
        guard let thread = packet.candidateThreadRefs.first else { return nil }
        let note = enrichmentItem(for: .notes, in: packet)
        let web = enrichmentItem(for: .webResearch, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let evidencePack = Array(packet.evidenceRefs.prefix(3))
        let sourceAnchors = sourceAnchors(from: [note, web, calendar, reminder])
        let enrichmentSources = enrichmentSources(from: [note, web, calendar, reminder])
        let timingWindow = timingWindowHint(calendar: calendar, reminder: reminder)

        if note != nil || web != nil {
            var body = "Research direction вокруг \(thread.title) уже достаточно grounded.\n"
            body += "Из заметок уже резонирует: \(note.map { "«\($0.title)» — \($0.snippet)" } ?? "контекст уже заземлён")"
            if let web {
                body += "\nbrowser context подсказывает: \(enrichmentAnchor(for: web))"
            }
            if let timingWindow, !timingWindow.isEmpty {
                body += "\nСобирать следующий шаг лучше \(timingWindow)."
            }
            let metadata = AdvisoryArtifactGuidanceMetadata(
                summary: thread.summary ?? note?.snippet ?? web?.snippet,
                evidencePack: evidencePack,
                actionSteps: [
                    "Сформулировать один narrow question вокруг \(thread.title).",
                    "Проверить, не спорит ли он с заметкой или browser context.",
                    "Оставить один grounded next step."
                ],
                focusQuestion: "Что здесь остаётся недоказанным без следующего шага?",
                sourceAnchors: sourceAnchors,
                enrichmentSources: enrichmentSources,
                timingWindow: timingWindow
            )

            return AdvisoryArtifactCandidate(
                domain: .research,
                kind: .researchDirection,
                title: "Research direction: \(thread.title)",
                body: body,
                threadId: thread.id,
                sourcePacketId: packet.packetId,
                sourceRecipe: request.recipeName,
                confidence: 0.74,
                whyNow: "Исследовательский сигнал уже резонирует с заметками и/или browser context.",
                evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
                metadataJson: AdvisorySupport.encodeJSONString(metadata),
                language: packet.language,
                status: .candidate
            )
        }

        let kind: AdvisoryArtifactKind = .explorationSeed
        let focusQuestion = "Что здесь остаётся недоказанным и требует маленького exploration seed?"
        let body = [
            "Exploration seed вокруг \(thread.title) помогает не расплыться в абстракции.",
            "This exploration seed keeps the question grounded before it turns into a bigger research branch.",
            "Что остаётся недоказанным: \(focusQuestion)",
            "Следующий шаг лучше держать маленьким и проверяемым."
        ].joined(separator: "\n")
        let metadata = AdvisoryArtifactGuidanceMetadata(
            summary: thread.summary,
            evidencePack: evidencePack,
            actionSteps: [
                "Сформулировать один narrow question.",
                "Проверить его на ближайшем evidence.",
                "Оставить только один маленький next step."
            ],
            focusQuestion: focusQuestion,
            sourceAnchors: sourceAnchors,
            enrichmentSources: enrichmentSources,
            timingWindow: timingWindow
        )

        return AdvisoryArtifactCandidate(
            domain: .research,
            kind: kind,
            title: "Exploration seed: \(thread.title)",
            body: body,
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: 0.7,
            whyNow: "Research pull already exists, but there is not enough embedded context to narrow it further.",
            evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
            metadataJson: AdvisorySupport.encodeJSONString(metadata),
            language: packet.language,
            status: .candidate
        )
    }

    func composeFocusReflectionFallback(
        packet: ReflectionPacket,
        request: AdvisoryRecipeRequest
    ) -> AdvisoryArtifactCandidate? {
        guard let thread = packet.candidateThreadRefs.first else { return nil }
        let wearable = enrichmentItem(for: .wearable, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let timingWindow = timingWindowHint(calendar: calendar, reminder: reminder)
        let actionSteps = [
            "Сократить context switch и вернуть один clear return point.",
            "Оставить следующий шаг настолько маленьким, чтобы re-entry был дешёвым.",
            "Не тащить новую ветку, пока fragmentation не станет ниже."
        ]

        let bodyLines = [
            "focus intervention для \(thread.title) уже уместен, потому что fragmented context виден без лишней драматизации.",
            "Если смотреть на rhythm, сигнал достаточно конкретный, чтобы не игнорировать его.",
            "Оставь один return point и не раздувай вход обратно."
        ]

        let metadata = AdvisoryArtifactGuidanceMetadata(
            summary: thread.summary,
            actionSteps: actionSteps,
            focusQuestion: "Какой минимальный action снижает re-entry cost?",
            patternName: "Focus Intervention",
            sourceAnchors: sourceAnchors(from: [wearable, reminder, calendar]),
            enrichmentSources: enrichmentSources(from: [wearable, reminder, calendar]),
            timingWindow: timingWindow
        )

        return AdvisoryArtifactCandidate(
            domain: .focus,
            kind: .focusIntervention,
            title: "Focus intervention: \(thread.title)",
            body: bodyLines.joined(separator: "\n"),
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: 0.69,
            whyNow: "Fragmentation and re-entry cost are visible enough to call the intervention explicitly.",
            evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
            metadataJson: AdvisorySupport.encodeJSONString(metadata),
            language: packet.language,
            status: .candidate
        )
    }

    func composeSocialSignalFallback(
        packet: ReflectionPacket,
        request: AdvisoryRecipeRequest
    ) -> AdvisoryArtifactCandidate? {
        guard let thread = packet.candidateThreadRefs.first else { return nil }
        let web = enrichmentItem(for: .webResearch, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let timingWindow = timingWindowHint(calendar: nil, reminder: reminder)
        let metadata = AdvisoryArtifactGuidanceMetadata(
            summary: thread.summary,
            actionSteps: [
                "Собрать один grounded social signal.",
                "Проверить, не звучит ли он forced.",
                "Оставить короткий follow-up window."
            ],
            sourceAnchors: sourceAnchors(from: [web, reminder]),
            enrichmentSources: enrichmentSources(from: [web, reminder]),
            timingWindow: timingWindow
        )

        return AdvisoryArtifactCandidate(
            domain: .social,
            kind: .socialNudge,
            title: "Social nudge: \(thread.title)",
            body: [
                "browser context already gives enough grounding for a social nudge.",
                "The reminder anchor keeps this from turning into noise.",
                "Окно для ответа лучше держать в transition, а не в спешке."
            ].joined(separator: "\n"),
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: 0.71,
            whyNow: "Social signal is grounded in today's material and reminder timing.",
            evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
            metadataJson: AdvisorySupport.encodeJSONString(metadata),
            language: packet.language,
            status: .candidate
        )
    }

    func composeHealthPulseFallback(
        packet: ReflectionPacket,
        request: AdvisoryRecipeRequest
    ) -> AdvisoryArtifactCandidate? {
        guard let thread = packet.candidateThreadRefs.first else { return nil }
        let wearable = enrichmentItem(for: .wearable, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let timingWindow = timingWindowHint(calendar: calendar, reminder: nil)
        let metadata = AdvisoryArtifactGuidanceMetadata(
            summary: thread.summary,
            actionSteps: [
                "Назвать один заметный rhythm shift без морализаторства.",
                "Посмотреть, не вырос ли cognitive load.",
                "Оставить мягкий stop point на вечер."
            ],
            sourceAnchors: sourceAnchors(from: [wearable, calendar]),
            enrichmentSources: enrichmentSources(from: [wearable, calendar]),
            timingWindow: timingWindow
        )

        return AdvisoryArtifactCandidate(
            domain: .health,
            kind: .healthReflection,
            title: "Health pulse: \(thread.title)",
            body: [
                "rhythm уже заметно влияет на день, и это лучше назвать мягко.",
                "High cognitive load window даёт достаточно сигнала, чтобы не притворяться, будто всё ровно.",
                "Смысл не в диагнозе, а в том, чтобы увидеть ритм до перегруза."
            ].joined(separator: "\n"),
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: 0.68,
            whyNow: "Health pulse is grounded in rhythm rather than generic advice.",
            evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
            metadataJson: AdvisorySupport.encodeJSONString(metadata),
            language: packet.language,
            status: .candidate
        )
    }

    func composeDecisionReviewFallback(
        packet: ReflectionPacket,
        request: AdvisoryRecipeRequest
    ) -> AdvisoryArtifactCandidate? {
        guard let thread = packet.candidateThreadRefs.first else { return nil }
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let decision = packet.candidateContinuityItems.first(where: { $0.kind == .decision })
        let decisionText = decision?.body ?? thread.summary ?? packet.salientSessions.first?.evidenceSnippet ?? "Implicit decision still needs to be named."
        let timingWindow = timingWindowHint(calendar: nil, reminder: reminder)
        let kind: AdvisoryArtifactKind = decision != nil ? .decisionReminder : .missedSignal
        let patternName = decision != nil ? "Decision Reminder" : "Missed Signal"
        let metadata = AdvisoryArtifactGuidanceMetadata(
            summary: thread.summary,
            decisionText: decisionText,
            patternName: patternName,
            sourceAnchors: sourceAnchors(from: [reminder]),
            enrichmentSources: enrichmentSources(from: [reminder]),
            timingWindow: timingWindow
        )
        let body = [
            decision != nil
                ? "decision reminder: explicit choice already exists, so keep it visible."
                : "This looks like a missed signal: the decision is there, but it has not been named cleanly.",
            "operational anchor: \(decisionText)",
            reminder.map { "Reminder anchor: \($0.title) — \($0.snippet)" } ?? "Reminder anchor is not embedded yet."
        ].joined(separator: "\n")

        return AdvisoryArtifactCandidate(
            domain: .decisions,
            kind: kind,
            title: decision != nil ? "Decision reminder: \(thread.title)" : "Missed signal: \(thread.title)",
            body: body,
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: 0.67,
            whyNow: "Decision review should surface the unresolved edge before it gets buried.",
            evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
            metadataJson: AdvisorySupport.encodeJSONString(metadata),
            language: packet.language,
            status: .candidate
        )
    }

    func composeLifeAdminFallback(
        packet: ReflectionPacket,
        request: AdvisoryRecipeRequest
    ) -> AdvisoryArtifactCandidate? {
        guard let thread = packet.candidateThreadRefs.first else { return nil }
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let timingWindow = timingWindowHint(calendar: nil, reminder: reminder)
        let candidateTask = reminder?.title ?? thread.summary ?? "Life admin tail"
        let metadata = AdvisoryArtifactGuidanceMetadata(
            summary: thread.summary,
            candidateTask: candidateTask,
            sourceAnchors: sourceAnchors(from: [reminder]),
            enrichmentSources: enrichmentSources(from: [reminder]),
            timingWindow: timingWindow
        )

        return AdvisoryArtifactCandidate(
            domain: .lifeAdmin,
            kind: .lifeAdminReminder,
            title: "Life admin: \(candidateTask)",
            body: [
                "Life admin review keeps the tail visible instead of letting it stay ambient.",
                "Candidate task: \(candidateTask)",
                reminder.map { "Reminder anchor: \($0.title) — \($0.snippet)" } ?? "Reminder anchor is not embedded yet."
            ].joined(separator: "\n"),
            threadId: thread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: 0.66,
            whyNow: "A quiet admin tail is easier to close when it is named explicitly.",
            evidenceJson: AdvisorySupport.encodeJSONString(Array(packet.evidenceRefs.prefix(8))),
            metadataJson: AdvisorySupport.encodeJSONString(metadata),
            language: packet.language,
            status: .candidate
        )
    }

    func enrichmentItem(
        for source: AdvisoryEnrichmentSource,
        in packet: ReflectionPacket
    ) -> ReflectionEnrichmentItem? {
        packet.enrichment.bundles
            .first(where: { $0.source == source && $0.availability == .embedded })?
            .items
            .first
    }

    func enrichmentAnchor(for item: ReflectionEnrichmentItem) -> String {
        let snippet = AdvisorySupport.cleanedSnippet(item.snippet, maxLength: 110)
        return snippet.isEmpty ? "\(item.source.label): \(item.title)" : "\(item.source.label): \(item.title) — \(snippet)"
    }

    func sourceAnchors(from items: [ReflectionEnrichmentItem?]) -> [String] {
        AdvisorySupport.dedupe(items.compactMap { $0 }.map(enrichmentAnchor(for:)))
    }

    func enrichmentSources(from items: [ReflectionEnrichmentItem?]) -> [AdvisoryEnrichmentSource] {
        var seen: Set<AdvisoryEnrichmentSource> = []
        var result: [AdvisoryEnrichmentSource] = []
        for source in items.compactMap({ $0?.source }) where seen.insert(source).inserted {
            result.append(source)
        }
        return result
    }

    func timingWindowHint(
        calendar: ReflectionEnrichmentItem?,
        reminder: ReflectionEnrichmentItem?
    ) -> String? {
        if let reminder {
            return "в transition рядом с напоминанием «\(reminder.title)»"
        }
        guard let calendar else { return nil }
        return "вокруг окна «\(calendar.title)»"
    }
}

final class JSONRPCAdvisoryBridgeServer: AdvisoryBridgeServerProtocol {
    private let socketPath: String
    private let defaultTimeoutSeconds: Int
    private let runtimeName = "memograph-advisor"
    private let providerName = "sidecar_jsonrpc_uds"
    private let transportName = "jsonrpc_uds"

    init(socketPath: String, defaultTimeoutSeconds: Int) {
        self.socketPath = socketPath
        self.defaultTimeoutSeconds = max(1, defaultTimeoutSeconds)
    }

    func health() -> AdvisoryBridgeHealth {
        loadHealth(forceRefresh: false)
    }

    func refreshHealth() -> AdvisoryBridgeHealth {
        loadHealth(forceRefresh: true)
    }

    private func loadHealth(forceRefresh: Bool) -> AdvisoryBridgeHealth {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return unavailableHealth(status: "socket_missing")
        }

        do {
            let result: AdvisoryBridgeHealth = try call(
                method: "advisor.health",
                params: AdvisoryHealthParams(forceRefresh: forceRefresh),
                timeoutSeconds: forceRefresh ? max(15, defaultTimeoutSeconds) : min(3, defaultTimeoutSeconds)
            )
            return AdvisoryBridgeStatusInterpreter.health(
                runtimeName: result.runtimeName,
                status: result.status,
                providerName: result.providerName,
                transport: result.transport,
                detail: result.statusDetail,
                lastError: result.lastError,
                activeProviderName: result.activeProviderName,
                providerOrder: result.providerOrder,
                availableProviders: result.availableProviders,
                providerStatuses: result.providerStatuses,
                checkedAt: result.checkedAt,
                runtimeHealthTier: result.runtimeHealthTier,
                providerHealthTier: result.providerHealthTier
            )
        } catch {
            return AdvisoryBridgeStatusInterpreter.health(
                from: error,
                runtimeName: runtimeName,
                providerName: providerName,
                transport: transportName,
                autoStartEnabled: true
            )
        }
    }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw AdvisoryBridgeError.unavailable("Advisory sidecar socket is missing at \(socketPath).")
        }
        var result: AdvisoryRecipeResult = try call(
            method: "advisor.runRecipe",
            params: request,
            timeoutSeconds: request.timeoutSeconds
        )
        if result.source == nil {
            result.source = "sidecar"
        }
        return result
    }

    func cancelRun(runId: String) {
        _ = try? call(
            method: "advisor.cancelRun",
            params: AdvisoryCancelRunParams(runId: runId),
            timeoutSeconds: min(2, defaultTimeoutSeconds)
        ) as JSONRPCEmptyResult
    }

    func accounts(forceRefresh: Bool) throws -> AdvisoryProviderAccountsSnapshot {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw AdvisoryBridgeError.unavailable("Advisory sidecar socket is missing at \(socketPath).")
        }
        return try call(
            method: "advisor.accounts.list",
            params: AdvisoryAccountsParams(forceRefresh: forceRefresh),
            timeoutSeconds: forceRefresh ? max(30, defaultTimeoutSeconds) : min(6, defaultTimeoutSeconds)
        )
    }

    func openLogin(providerName: String) throws -> AdvisoryProviderAccountActionResponse {
        try call(
            method: "advisor.accounts.openLogin",
            params: AdvisoryProviderNameParams(providerName: providerName),
            timeoutSeconds: min(4, defaultTimeoutSeconds)
        )
    }

    func importCurrentSession(providerName: String, accountName: String?) throws -> AdvisoryProviderAccountActionResponse {
        try call(
            method: "advisor.accounts.importCurrentSession",
            params: AdvisoryImportCurrentSessionParams(providerName: providerName, accountName: accountName),
            timeoutSeconds: min(8, defaultTimeoutSeconds)
        )
    }

    func reauthorize(providerName: String, accountName: String) throws -> AdvisoryProviderAccountActionResponse {
        try call(
            method: "advisor.accounts.reauthorize",
            params: AdvisoryProviderAccountParams(providerName: providerName, accountName: accountName),
            timeoutSeconds: min(4, defaultTimeoutSeconds)
        )
    }

    func setAccountLabel(providerName: String, accountName: String, label: String) throws -> AdvisoryProviderAccountActionResponse {
        try call(
            method: "advisor.accounts.setLabel",
            params: AdvisoryProviderAccountLabelParams(
                providerName: providerName,
                accountName: accountName,
                label: label
            ),
            timeoutSeconds: min(4, defaultTimeoutSeconds)
        )
    }

    func setPreferredAccount(providerName: String, accountName: String) throws -> AdvisoryProviderAccountActionResponse {
        try call(
            method: "advisor.accounts.setPreferred",
            params: AdvisoryProviderAccountParams(providerName: providerName, accountName: accountName),
            timeoutSeconds: min(4, defaultTimeoutSeconds)
        )
    }

    func authCheck(providerName: String, accountName: String?, forceRefresh: Bool) throws -> AdvisoryProviderAuthCheckResponse {
        try call(
            method: "advisor.auth.checkProvider",
            params: AdvisoryAuthCheckParams(
                providerName: providerName,
                accountName: accountName,
                forceRefresh: forceRefresh
            ),
            timeoutSeconds: forceRefresh ? max(15, defaultTimeoutSeconds) : min(4, defaultTimeoutSeconds)
        )
    }

    private func call<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params,
        timeoutSeconds: Int
    ) throws -> Result {
        let requestId = AdvisorySupport.stableIdentifier(
            prefix: "rpc",
            components: [method, UUID().uuidString]
        )
        let envelope = JSONRPCRequestEnvelope(id: requestId, method: method, params: params)
        let encoder = JSONEncoder()
        let payload = try encoder.encode(envelope)
        let responseData = try UDSJSONRPCTransport.send(
            payload: payload,
            socketPath: socketPath,
            timeoutSeconds: max(1, timeoutSeconds)
        )

        let decoder = JSONDecoder()
        let response = try decoder.decode(JSONRPCResponseEnvelope<Result>.self, from: responseData)
        if let error = response.error {
            throw AdvisoryBridgeError.sidecarFailure("Advisory sidecar error \(error.code): \(error.message)")
        }
        guard let result = response.result else {
            throw AdvisoryBridgeError.invalidResponse("Advisory sidecar returned an empty JSON-RPC result for \(method).")
        }
        return result
    }

    private func unavailableHealth(status: String = "unavailable") -> AdvisoryBridgeHealth {
        AdvisoryBridgeStatusInterpreter.health(
            runtimeName: runtimeName,
            status: status,
            providerName: providerName,
            transport: transportName,
            detail: socketPath,
            autoStartEnabled: true
        )
    }
}

private struct AdvisoryCancelRunParams: Codable {
    let runId: String
}

private struct AdvisoryHealthParams: Codable {
    let forceRefresh: Bool
}

private struct AdvisoryAccountsParams: Codable {
    let forceRefresh: Bool
}

private struct AdvisoryProviderNameParams: Codable {
    let providerName: String
}

private struct AdvisoryProviderAccountParams: Codable {
    let providerName: String
    let accountName: String
}

private struct AdvisoryImportCurrentSessionParams: Codable {
    let providerName: String
    let accountName: String?
}

private struct AdvisoryProviderAccountLabelParams: Codable {
    let providerName: String
    let accountName: String
    let label: String
}

private struct AdvisoryAuthCheckParams: Codable {
    let providerName: String
    let accountName: String?
    let forceRefresh: Bool
}

private struct JSONRPCEmptyParams: Codable {}
private struct JSONRPCEmptyResult: Codable {}

private struct JSONRPCRequestEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id: String
    let method: String
    let params: Params
}

private struct JSONRPCResponseEnvelope<Result: Decodable>: Decodable {
    let jsonrpc: String
    let id: String?
    let result: Result?
    let error: JSONRPCErrorPayload?
}

private struct JSONRPCErrorPayload: Codable {
    let code: Int
    let message: String
}

private enum UDSJSONRPCTransport {
    static func send(
        payload: Data,
        socketPath: String,
        timeoutSeconds: Int
    ) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AdvisoryBridgeError.transportFailure("Failed to open advisory sidecar socket: \(systemErrorMessage())")
        }
        defer { close(fd) }

        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { pathPointer in
            let pathLength = strlen(pathPointer)
            let maxLength = MemoryLayout.size(ofValue: address.sun_path)
            guard pathLength < maxLength else {
                throw AdvisoryBridgeError.transportFailure("Advisory sidecar socket path is too long.")
            }

            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
                memcpy(rawBuffer.baseAddress, pathPointer, pathLength)
            }
        }

        // Validate socket file exists before attempting connect
        let fm = FileManager.default
        guard fm.fileExists(atPath: socketPath) else {
            throw AdvisoryBridgeError.unavailable("Advisory sidecar socket not found at \(socketPath)")
        }

        // Set non-blocking for connect with timeout
        let originalFlags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)

        var addressCopy = address
        let connectResult = withUnsafePointer(to: &addressCopy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult != 0 && errno != EINPROGRESS {
            throw AdvisoryBridgeError.unavailable("Failed to connect to advisory sidecar at \(socketPath): \(systemErrorMessage())")
        }

        if connectResult != 0 {
            // Wait for connect with poll timeout
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pfd, 1, Int32(timeoutSeconds * 1000))
            if pollResult <= 0 {
                throw AdvisoryBridgeError.unavailable("Connect to advisory sidecar at \(socketPath) timed out after \(timeoutSeconds)s.")
            }
            // Check for socket error
            var connectError: Int32 = 0
            var errorLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &connectError, &errorLen)
            guard connectError == 0 else {
                throw AdvisoryBridgeError.unavailable("Failed to connect to advisory sidecar at \(socketPath): \(String(cString: strerror(connectError)))")
            }
        }

        // Restore blocking mode for read/write
        _ = fcntl(fd, F_SETFL, originalFlags)

        var framedPayload = payload
        framedPayload.append(0x0A)
        try writeAll(fd: fd, data: framedPayload, timeoutSeconds: timeoutSeconds)
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let readCount = recv(fd, &buffer, buffer.count, 0)
            if readCount == 0 {
                break
            }
            if readCount < 0 {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    throw AdvisoryBridgeError.unavailable("Advisory sidecar response timed out after \(timeoutSeconds)s.")
                }
                throw AdvisoryBridgeError.transportFailure("Failed to read advisory sidecar response: \(systemErrorMessage())")
            }
            response.append(buffer, count: readCount)
            if buffer[..<readCount].contains(0x0A) {
                break
            }
        }

        let trimmed = response.trimmingTrailingWhitespaceAndNewline()
        guard !trimmed.isEmpty else {
            throw AdvisoryBridgeError.invalidResponse("Advisory sidecar returned an empty response.")
        }
        return trimmed
    }

    private static func writeAll(fd: Int32, data: Data, timeoutSeconds: Int) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            var pointer = baseAddress

            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        throw AdvisoryBridgeError.unavailable("Advisory sidecar request write timed out after \(timeoutSeconds)s.")
                    }
                    throw AdvisoryBridgeError.transportFailure("Failed to write advisory sidecar request: \(systemErrorMessage())")
                }
                remaining -= written
                pointer += written
            }
        }
    }

    private static func systemErrorMessage() -> String {
        String(cString: strerror(errno))
    }
}

private extension Data {
    func trimmingTrailingWhitespaceAndNewline() -> Data {
        var copy = self
        while let last = copy.last, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(last)) {
            copy.removeLast()
        }
        return copy
    }
}
