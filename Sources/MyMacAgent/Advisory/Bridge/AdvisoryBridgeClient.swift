import Darwin
import Foundation
import os

final class AdvisoryBridgeClient {
    private let primaryServer: AdvisoryBridgeServerProtocol?
    private let fallbackServer: AdvisoryBridgeServerProtocol
    private let mode: AdvisoryBridgeMode
    private let supervisor: AdvisorySidecarSupervisor?
    private let retryAttempts: Int

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
            supervisor?.record(health: health)
            return health
        case .preferSidecar:
            guard let primaryServer else {
                return fallbackHealth(status: "fallback_stub")
            }
            let primaryHealth = forceRefresh ? primaryServer.refreshHealth() : primaryServer.health()
            supervisor?.record(health: primaryHealth)
            if primaryHealth.status == "ok" {
                return primaryHealth
            }
            return fallbackHealth(status: "fallback_stub", attemptedPrimaryHealth: primaryHealth)
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
        return try primaryServer.setPreferredAccount(providerName: providerName, accountName: accountName)
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
                let activeHealth = refreshPrimaryHealth(on: primaryServer, fallback: currentHealth)
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
                let recoveredHealth = refreshPrimaryHealth(on: primaryServer, fallback: currentHealth)
                guard remainingAttempts > 1, shouldRetryPrimary(for: status) else {
                    throw PrimaryExecutionFailure(
                        message: error.localizedDescription,
                        health: recoveredHealth
                    )
                }
                remainingAttempts -= 1
                preparePrimaryRetry(for: status)
                currentHealth = refreshPrimaryHealth(on: primaryServer, fallback: recoveredHealth)
            }
        }
    }

    private func shouldRetryPrimary(for status: String) -> Bool {
        switch AdvisoryBridgeStatusInterpreter.normalizedStatus(status) {
        case "timeout", "transport_failure", "socket_missing", "starting", "unavailable":
            return true
        default:
            return false
        }
    }

    private func preparePrimaryRetry(for status: String) {
        switch AdvisoryBridgeStatusInterpreter.normalizedStatus(status) {
        case "timeout", "transport_failure", "socket_missing":
            supervisor?.restart()
        case "starting", "unavailable":
            supervisor?.prepareForExecution()
        default:
            break
        }
    }

    private func refreshPrimaryHealth(
        on primaryServer: AdvisoryBridgeServerProtocol,
        fallback: AdvisoryBridgeHealth? = nil
    ) -> AdvisoryBridgeHealth {
        let health = primaryServer.health()
        supervisor?.record(health: health)
        if health.status == "ok" || fallback == nil {
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
                case "session_expired", "no_provider", "timeout", "transport_failure", "socket_missing":
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
            return supervisor?.status ?? "fallback"
        case .requireSidecar:
            if health.status == "ok" {
                return "ready"
            }
            let normalized = AdvisoryBridgeStatusInterpreter.normalizedStatus(health.status)
            switch normalized {
            case "session_expired", "no_provider", "timeout", "transport_failure", "socket_missing":
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

private enum AdvisorySidecarProcessJanitor {
    static func cleanup(keepingSocketPath: String?) {
        let lines = runningSidecarLines()
        guard !lines.isEmpty else { return }

        for line in lines {
            guard let parsed = parse(line) else { continue }
            if let keepingSocketPath, parsed.socketPath == keepingSocketPath {
                continue
            }

            _ = kill(parsed.pid, SIGTERM)
            if let socketPath = parsed.socketPath,
               FileManager.default.fileExists(atPath: socketPath) {
                try? FileManager.default.removeItem(atPath: socketPath)
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
            process.waitUntilExit()
            guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
                return []
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
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
        case "timeout":
            return "memograph-advisor не ответил вовремя. Возможно, runtime перегружен."
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
    private var autoStart: Bool
    private let socketPath: String
    private var healthCheckIntervalSeconds: Int
    private var maxConsecutiveFailures: Int
    private var runtimeStatus: AdvisorySidecarRuntimeStatus
    private var probeTimeoutSeconds: Int
    private var environmentOverrides: [String: String]
    private let logger = Logger.advisory
    private let lock = NSLock()
    private var consecutiveFailures = 0
    private var lastHealthCheckAt: Date?
    private var lastStartAttemptAt: Date?
    private var lastKnownStatus = "socket_missing"
    private var lastError: String?
    private var process: Process?

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
        lock.unlock()
    }

    func prepareForHealthCheck() {
        guard shouldAttempt(now: Date(), force: false) else { return }
        ensureStarted()
    }

    func prepareForExecution() {
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
        lock.lock()
        runningProcess = process
        process = nil
        lastKnownStatus = "socket_missing"
        lastError = nil
        consecutiveFailures = 0
        lock.unlock()

        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
            _ = waitForExit(of: runningProcess, timeoutSeconds: 2)
            if runningProcess.isRunning {
                runningProcess.interrupt()
            }
        }
        if FileManager.default.fileExists(atPath: socketPath) {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
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
        let baseStatus = currentHealth.map { AdvisoryBridgeStatusInterpreter.normalizedStatus($0.status) } ?? lastKnownStatus
        let status: String
        let baseRuntimeError: String?
        switch currentRuntimeStatus {
        case .ready:
            baseRuntimeError = nil
        case .missingPython(let details), .missingScript(let details):
            baseRuntimeError = details
        }

        if processRunning && !socketPresent {
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
        guard autoStart else {
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
        if let lastStartAttemptAt, now.timeIntervalSince(lastStartAttemptAt) < Double(healthCheckIntervalSeconds) {
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
            self.lastKnownStatus = "starting"
            self.lastError = nil
            lock.unlock()
            _ = waitForSocketReady(timeoutSeconds: 3)
            logger.info("Attempted to auto-start advisory sidecar at \(self.socketPath, privacy: .public)")
        } catch {
            lock.lock()
            consecutiveFailures = min(failureBudget, consecutiveFailures + 1)
            lastKnownStatus = AdvisoryBridgeStatusInterpreter.normalizedStatus(error.localizedDescription)
            lastError = error.localizedDescription
            lock.unlock()
            logger.error("Failed to auto-start advisory sidecar: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleTermination(_ process: Process) {
        let reason = "memograph-advisor exited (\(process.terminationReason.rawValue):\(process.terminationStatus))"
        lock.lock()
        if self.process === process {
            self.process = nil
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

    private func waitForExit(
        of process: Process,
        timeoutSeconds: TimeInterval
    ) -> Bool {
        guard process.isRunning else { return true }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + timeoutSeconds)
        if result == .timedOut {
            process.terminationHandler = nil
        }
        return !process.isRunning
    }

    private func countsAsFailureStatus(_ status: String) -> Bool {
        restartableStatus(status)
    }

    private func restartableStatus(_ status: String) -> Bool {
        switch status {
        case "socket_missing", "transport_failure", "timeout", "unavailable", "backoff":
            return true
        default:
            return false
        }
    }
}

final class LocalAdvisoryBridgeStub: AdvisoryBridgeServerProtocol {
    func health() -> AdvisoryBridgeHealth {
        AdvisoryBridgeHealth(
            runtimeName: "memograph-advisor-stub",
            status: "ok",
            providerName: "local_stub",
            transport: "in_process"
        )
    }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        switch request.recipeName {
        case "continuity_resume":
            return continuityResume(request)
        case "thread_maintenance":
            return threadMaintenance(request)
        case "writing_seed":
            return writingSeed(request)
        case "tweet_from_thread":
            return tweetFromThread(request)
        case "research_direction":
            return researchDirection(request)
        case "weekly_reflection":
            return weeklyReflection(request)
        case "focus_reflection":
            return focusReflection(request)
        case "social_signal":
            return socialSignal(request)
        case "health_pulse":
            return healthPulse(request)
        case "decision_review":
            return decisionReview(request)
        case "life_admin_review":
            return lifeAdminReview(request)
        default:
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }
    }

    func cancelRun(runId: String) {}

    private func continuityResume(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        let packet = request.packet
        guard let primaryThread = packet.candidateThreadRefs.first else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }

        let note = notesEnrichment(in: packet).first
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let timingWindow = timingWindowHint(
            calendar: calendar,
            reminder: reminder,
            trigger: packet.triggerKind,
            preferTransition: packet.triggerKind != .morningResume
        )
        let relevantItems = packet.candidateContinuityItems
            .filter { $0.threadId == nil || $0.threadId == primaryThread.id }
        let openLoopText = relevantItems.first?.title ?? "нить пока больше чувствуется, чем сформулирована"
        let decisionText = relevantItems.first(where: { $0.kind == .decision })?.body
        let continuations = suggestedContinuations(thread: primaryThread, items: relevantItems, sessions: packet.salientSessions)

        var bodyLines: [String] = []
        bodyLines.append("Я заметил, что главная нить сейчас: \(primaryThread.title).")
        if let summary = primaryThread.summary, !summary.isEmpty {
            bodyLines.append("Где остановился: \(summary)")
        }
        bodyLines.append("Похоже, незакрытый узел здесь: \(openLoopText).")
        if let decisionText, !decisionText.isEmpty {
            bodyLines.append("Что уже решено: \(AdvisorySupport.cleanedSnippet(decisionText, maxLength: 160))")
        }
        if let note {
            bodyLines.append("Из заметок здесь уже держится опора: «\(note.title)» — \(note.snippet)")
        }
        if let reminder {
            bodyLines.append("Есть и внешний anchor: \(enrichmentAnchor(for: reminder)).")
        } else if let calendar {
            bodyLines.append("Есть и внешний anchor: \(enrichmentAnchor(for: calendar)).")
        }
        if let timingWindow, !timingWindow.isEmpty {
            bodyLines.append("По timing fit мягче всего возвращаться \(timingWindow).")
        }
        bodyLines.append("Если хочешь продолжить, вот 3 хороших входа:")
        for (index, option) in continuations.enumerated() {
            bodyLines.append("\(index + 1). \(option)")
        }

        let evidenceRefs = AdvisorySupport.encodeJSONString(
            packet.evidenceRefs.prefix(8).map { $0 }
        )
        let artifact = AdvisoryArtifactCandidate(
            id: nil,
            domain: .continuity,
            kind: .resumeCard,
            title: "Вернуться в \(primaryThread.title)",
            body: bodyLines.joined(separator: "\n"),
            threadId: primaryThread.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: min(0.95, max(0.55, primaryThread.confidence)),
            whyNow: whyNow(trigger: packet.triggerKind),
            evidenceJson: evidenceRefs,
            metadataJson: guidanceMetadata(
                summary: primaryThread.summary,
                evidencePack: packet.evidenceRefs.prefix(3).map { $0 },
                actionSteps: continuations,
                continuityAnchor: continuations.first,
                openLoop: openLoopText,
                decisionText: decisionText,
                noteAnchorTitle: note?.title,
                noteAnchorSnippet: note?.snippet,
                patternName: "Resume Me",
                sourceAnchors: enrichmentAnchors(from: [note, calendar, reminder]),
                enrichmentSources: enrichmentSources(from: [note, calendar, reminder]),
                timingWindow: timingWindow
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )

        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func threadMaintenance(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        let packet = request.packet
        guard packet.candidateThreadRefs.count >= 2 else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }

        let parentRelations = packet.candidateThreadRefs.compactMap { thread -> String? in
            guard let parentId = thread.parentThreadId,
                  let parent = packet.candidateThreadRefs.first(where: { $0.id == parentId }) else {
                return nil
            }
            return "Похоже, «\(thread.title)» лучше воспринимать как подпоток нити «\(parent.title)»."
        }

        let stalledThreads = packet.candidateThreadRefs.filter { $0.status == .stalled || $0.status == .parked }
        let broadThread = packet.candidateThreadRefs
            .filter { $0.parentThreadId == nil }
            .sorted { lhs, rhs in lhs.totalActiveMinutes > rhs.totalActiveMinutes }
            .first(where: { $0.totalActiveMinutes >= 150 })

        var bodyLines = [
            "Похоже, thread layer просит тихого обслуживания, не срочного cleanup.",
            "Это не про наведение порядка ради порядка, а про то, чтобы завтра утром вход обратно был дешевле."
        ]

        if !parentRelations.isEmpty {
            bodyLines.append("Возможные merge / nesting moves:")
            for (index, relation) in parentRelations.prefix(2).enumerated() {
                bodyLines.append("\(index + 1). \(relation)")
            }
        }

        if let broadThread {
            bodyLines.append("Нить «\(broadThread.title)» уже выглядит слишком широкой; возможно, внутри неё созрел отдельный sub-thread.")
        }

        if !stalledThreads.isEmpty {
            bodyLines.append("Кандидаты на park/archive: \(stalledThreads.prefix(2).map(\.title).joined(separator: ", ")).")
        }

        bodyLines.append("Если захочешь пройтись мягко:")
        bodyLines.append("1. Склеить явные overlap-нитки, но не терять evidence.")
        bodyLines.append("2. Узкие подпотоки отметить как children, а не держать рядом как дубли.")
        bodyLines.append("3. Старые нити без движения перевести в parked или resolved, чтобы они не шумели в Resume Me.")

        let artifact = AdvisoryArtifactCandidate(
            id: nil,
            domain: .continuity,
            kind: .reflectionCard,
            title: "Нити просят maintenance",
            body: bodyLines.joined(separator: "\n"),
            threadId: packet.candidateThreadRefs.first?.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: min(0.86, 0.48 + max(signal(named: "thread_density", in: packet), signal(named: "continuity_pressure", in: packet)) * 0.28),
            whyNow: "Thread maintenance имеет смысл только когда уже видны устойчивые нити, а не в cold start bootstrap.",
            evidenceJson: AdvisorySupport.encodeJSONString(packet.evidenceRefs.prefix(8).map { $0 }),
            metadataJson: guidanceMetadata(
                summary: "Thread layer просит maintenance.",
                evidencePack: packet.evidenceRefs.prefix(3).map { $0 },
                actionSteps: [
                    "Склеить overlap-нитки без потери evidence.",
                    "Узкие подпотоки отметить как children.",
                    "Старые тихие нити перевести в parked или resolved."
                ],
                patternName: "Thread Maintenance"
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func writingSeed(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        guard let packet = request.packet.reflection else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }
        if let artifact = WritingSeedComposer().compose(
            packet: packet,
            recipeName: request.recipeName
        ) {
            return AdvisoryRecipeResult(
                runId: request.runId,
                artifactProposals: [artifact],
                continuityProposals: []
            )
        }
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
    }

    private func tweetFromThread(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        guard let packet = request.packet.thread else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }
        if let artifact = ThreadWritingSeedComposer().compose(
            packet: packet,
            recipeName: request.recipeName
        ) {
            return AdvisoryRecipeResult(
                runId: request.runId,
                artifactProposals: [artifact],
                continuityProposals: []
            )
        }
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
    }

    private func weeklyReflection(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        guard let packet = request.packet.weekly else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }
        guard let artifact = WeeklyReviewComposer().compose(packet: packet, recipeName: request.recipeName) else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func researchDirection(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        let packet = request.packet
        let researchPull = signal(named: "research_pull", in: packet)
        guard researchPull >= adjustedMinimumSignal(0.3, in: packet, floor: 0.12) else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }

        let note = notesEnrichment(in: packet).first
        let webResearch = enrichmentItem(for: .webResearch, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let timingWindow = timingWindowHint(
            calendar: calendar,
            reminder: nil,
            trigger: packet.triggerKind,
            preferTransition: false
        )
        let topic = webResearch?.title
            ?? packet.activeEntities.dropFirst().first
            ?? packet.activeEntities.first
            ?? "текущая нить"
        let thread = packet.candidateThreadRefs.first
        let focusQuestion = "Что именно в \(topic) остаётся недоказанным или плохо объяснённым?"
        let actionSteps = [
            "Сформулировать один рабочий вопрос.",
            "Собрать 2 контрастных примера из текущего контекста.",
            "Зафиксировать, что изменится в нити \(thread?.title ?? topic), если ответ подтвердится."
        ]
        let kind: AdvisoryArtifactKind = note == nil && webResearch == nil && researchPull >= 0.7 ? .explorationSeed : .researchDirection
        var bodyLines = [
            kind == .explorationSeed
                ? "Здесь уже назрел exploration seed вокруг \(topic), но без требования сразу всё доказать."
                : "Похоже, здесь есть исследовательская тяга вокруг \(topic).",
            kind == .explorationSeed
                ? "Хороший следующий ход: открыть узкое exploration window и посмотреть, какая гипотеза вообще выдерживает реальный контекст."
                : "Хорошее исследовательское направление сейчас: не расширять поле, а проверить один узкий вопрос, который снимет неопределённость.",
            "Фокус вопроса: \(focusQuestion)"
        ]
        if let note {
            bodyLines.append("Из заметок уже резонирует: «\(note.title)» — \(note.snippet)")
        }
        if let webResearch {
            bodyLines.append("Из browser context уже тянется: «\(webResearch.title)» — \(webResearch.snippet)")
        }
        if let timingWindow, kind == .researchDirection {
            bodyLines.append("Если брать это без спешки, лучшее окно здесь \(timingWindow).")
        }
        bodyLines.append("Если захочешь копнуть:")
        for (index, step) in actionSteps.enumerated() {
            bodyLines.append("\(index + 1). \(step)")
        }

        let artifact = AdvisoryArtifactCandidate(
            id: nil,
            domain: .research,
            kind: kind,
            title: kind == .explorationSeed ? "Exploration seed: \(topic)" : "Исследовательское направление: \(topic)",
            body: bodyLines.joined(separator: "\n"),
            threadId: thread?.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: min(0.86, 0.5 + researchPull * 0.34),
            whyNow: "Research signal уже повторился достаточно, чтобы дать направление, а не просто curiosity noise.",
            evidenceJson: AdvisorySupport.encodeJSONString(packet.evidenceRefs.prefix(8).map { $0 }),
            metadataJson: guidanceMetadata(
                summary: kind == .explorationSeed ? "Exploration window around \(topic)." : "Research direction around \(topic).",
                evidencePack: packet.evidenceRefs.prefix(3).map { $0 },
                actionSteps: actionSteps,
                focusQuestion: focusQuestion,
                noteAnchorTitle: note?.title,
                noteAnchorSnippet: note?.snippet,
                sourceAnchors: enrichmentAnchors(from: [note, webResearch, calendar]),
                enrichmentSources: enrichmentSources(from: [note, webResearch, calendar]),
                timingWindow: timingWindow
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func focusReflection(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        let packet = request.packet
        let focusTurbulence = signal(named: "focus_turbulence", in: packet)
        guard focusTurbulence >= adjustedMinimumSignal(0.32, in: packet, floor: 0.2) else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }
        let fragmentation = signal(named: "fragmentation", in: packet)
        let kind: AdvisoryArtifactKind = fragmentation >= 0.55 || packet.triggerKind == .focusBreakNatural ? .focusIntervention : .patternNotice
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let rhythm = enrichmentItem(for: .wearable, in: packet)
        let timingWindow = timingWindowHint(
            calendar: calendar,
            reminder: reminder,
            trigger: packet.triggerKind,
            preferTransition: true
        )
        let actionSteps = [
            "Вернуться в уже тёплую нить, а не открывать новую.",
            "Сузить следующий шаг до одного проверяемого результата.",
            "Отложить побочные идеи в note seed вместо немедленного переключения."
        ]

        var lines = [
            "Я заметил, что день выглядит фрагментированным сильнее обычного.",
            "Похоже, re-entry cost сейчас растёт не из-за сложности одной нити, а из-за частых входов и выходов между ними.",
            kind == .focusIntervention
                ? "Похоже, сейчас полезнее мягкая focus intervention, а не ещё один анализ паттерна."
                : "Самый мягкий фокус-сдвиг здесь: выбрать одну нить как anchor и не добавлять новых контекстов до первого завершённого мини-шага.",
        ]
        if let rhythm {
            lines.append("И по rhythm context видно: \(enrichmentAnchor(for: rhythm)).")
        }
        if let reminder {
            lines.append("Из внешнего контекста сейчас заметен transition anchor: \(enrichmentAnchor(for: reminder)).")
        } else if let calendar {
            lines.append("Из внешнего контекста сейчас заметен transition anchor: \(enrichmentAnchor(for: calendar)).")
        }
        if let timingWindow, !timingWindow.isEmpty {
            lines.append("Если делать мягкий reset, лучше всего делать его \(timingWindow).")
        }
        lines.append("Хорошие входы:")
        lines.append("1. \(actionSteps[0])")
        lines.append("2. \(actionSteps[1])")
        lines.append("3. \(actionSteps[2])")
        let body = lines.joined(separator: "\n")

        let artifact = AdvisoryArtifactCandidate(
            id: nil,
            domain: .focus,
            kind: kind,
            title: kind == .focusIntervention ? "Сделать один мягкий focus reset" : "Паттерн дня: растущий re-entry cost",
            body: body,
            threadId: packet.candidateThreadRefs.first?.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: min(0.84, 0.5 + focusTurbulence * 0.28),
            whyNow: "Focus domain поднялся из контекста дня, а не из абстрактного coaching.",
            evidenceJson: AdvisorySupport.encodeJSONString(packet.evidenceRefs.prefix(8).map { $0 }),
            metadataJson: guidanceMetadata(
                summary: "Re-entry cost is rising.",
                evidencePack: packet.evidenceRefs.prefix(3).map { $0 },
                actionSteps: actionSteps,
                patternName: kind == .focusIntervention ? "Focus Intervention" : "Pattern Notice",
                sourceAnchors: enrichmentAnchors(from: [rhythm, calendar, reminder]),
                enrichmentSources: enrichmentSources(from: [rhythm, calendar, reminder]),
                timingWindow: timingWindow
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func socialSignal(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        let packet = request.packet
        guard signal(named: "social_pull", in: packet) >= adjustedMinimumSignal(0.34, in: packet, floor: 0.2) else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }

        let webResearch = enrichmentItem(for: .webResearch, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let angle = webResearch?.title ?? packet.activeEntities.prefix(2).joined(separator: " + ")
        let primaryAngle = preferredAngle(
            in: packet,
            fallback: packet.constraints.allowProvocation ? "provocation" : "observation"
        )
        let alternatives = alternativeAngles(in: packet, excluding: preferredAngle(in: packet, fallback: "observation"))
        let actionSteps = [
            "Один observation.",
            "Один implication.",
            "Один открытый вопрос."
        ]
        let timingWindow = timingWindowHint(
            calendar: calendar,
            reminder: reminder,
            trigger: packet.triggerKind,
            preferTransition: true
        )
        var bodyLines = [
            "Из сегодняшнего контекста может получиться social signal, но без ощущения forced posting.",
            "Угол: \(angle.isEmpty ? "одна конкретная рабочая нить" : angle).",
            "Почему это может сработать: здесь уже есть lived evidence и не нужно выдумывать позицию.",
            "Primary angle: \(primaryAngle).",
            "Alternative angles: \(alternatives.joined(separator: " | ")).",
            "Evidence pack: \(packet.evidenceRefs.prefix(3).joined(separator: ", ")).",
        ]
        if let webResearch {
            bodyLines.append("Материал уже grounded в browser context: «\(webResearch.title)» — \(webResearch.snippet)")
        }
        if let reminder {
            bodyLines.append("Есть и мягкий внешний anchor: \(enrichmentAnchor(for: reminder)).")
        } else if let calendar {
            bodyLines.append("Есть и мягкий внешний anchor: \(enrichmentAnchor(for: calendar)).")
        }
        if let timingWindow, !timingWindow.isEmpty {
            bodyLines.append("По timing fit лучше всего смотреть на это \(timingWindow).")
        }
        bodyLines.append("Черновой вход:")
        bodyLines.append("\"Поймал интересную нить: ...\"")
        bodyLines.append("Дальше можно дать 1 observation, 1 implication и 1 открытый вопрос.")
        let body = bodyLines.joined(separator: "\n")

        let artifact = AdvisoryArtifactCandidate(
            id: nil,
            domain: .social,
            kind: .socialNudge,
            title: "Social signal из текущей нити",
            body: body,
            threadId: packet.candidateThreadRefs.first?.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: min(0.8, 0.45 + signal(named: "social_pull", in: packet) * 0.3),
            whyNow: "Social candidate заземлён в сегодняшнем материале, а не в пустой контентной повинности.",
            evidenceJson: AdvisorySupport.encodeJSONString(packet.evidenceRefs.prefix(8).map { $0 }),
            metadataJson: guidanceMetadata(
                summary: "Grounded social signal from today.",
                primaryAngle: primaryAngle,
                alternativeAngles: alternatives,
                evidencePack: packet.evidenceRefs.prefix(3).map { $0 },
                actionSteps: actionSteps,
                sourceAnchors: enrichmentAnchors(from: [webResearch, calendar, reminder]),
                enrichmentSources: enrichmentSources(from: [webResearch, calendar, reminder]),
                timingWindow: timingWindow
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func healthPulse(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        let packet = request.packet
        guard signal(named: "health_pressure", in: packet) >= adjustedMinimumSignal(0.42, in: packet, floor: 0.24) else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }

        let calendar = enrichmentItem(for: .calendar, in: packet)
        let reminder = enrichmentItem(for: .reminders, in: packet)
        let rhythm = enrichmentItem(for: .wearable, in: packet)
        let timingWindow = timingWindowHint(
            calendar: calendar,
            reminder: reminder,
            trigger: packet.triggerKind,
            preferTransition: true
        )
        var bodyLines = [
            "По косвенным сигналам день выглядит более рваным и тяжёлым по ритму.",
            "Это не диагноз и не score, а мягкое замечание: возможно, полезнее уменьшить стоимость следующего входа, чем форсировать глубину.",
        ]
        if let rhythm {
            bodyLines.append("И по rhythm layer уже видно: \(enrichmentAnchor(for: rhythm)).")
        }
        if let reminder {
            bodyLines.append("Снаружи тоже виден нагрузочный anchor: \(enrichmentAnchor(for: reminder)).")
        } else if let calendar {
            bodyLines.append("Снаружи тоже виден нагрузочный anchor: \(enrichmentAnchor(for: calendar)).")
        }
        if let timingWindow, !timingWindow.isEmpty {
            bodyLines.append("Если делать мягкий сдвиг, лучше искать его \(timingWindow).")
        }
        bodyLines.append("Если хочешь бережный сдвиг:")
        bodyLines.append("1. Выбрать самую тёплую нить.")
        bodyLines.append("2. Сделать один короткий проход вместо большого блока.")
        bodyLines.append("3. Оставить себе явный return point на потом.")
        let body = bodyLines.joined(separator: "\n")

        let artifact = AdvisoryArtifactCandidate(
            id: nil,
            domain: .health,
            kind: .healthReflection,
            title: "Ритм дня выглядит перегруженным",
            body: body,
            threadId: packet.candidateThreadRefs.first?.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: min(0.74, 0.42 + signal(named: "health_pressure", in: packet) * 0.24),
            whyNow: "Health domain включается только при заметном косвенном signal, без морализаторства.",
            evidenceJson: AdvisorySupport.encodeJSONString(packet.evidenceRefs.prefix(8).map { $0 }),
            metadataJson: guidanceMetadata(
                summary: "Day rhythm looks overloaded.",
                evidencePack: packet.evidenceRefs.prefix(3).map { $0 },
                actionSteps: [
                    "Выбрать самую тёплую нить.",
                    "Сделать один короткий проход вместо большого блока.",
                    "Оставить себе явный return point на потом."
                ],
                patternName: "Health Reflection",
                sourceAnchors: enrichmentAnchors(from: [rhythm, calendar, reminder]),
                enrichmentSources: enrichmentSources(from: [rhythm, calendar, reminder]),
                timingWindow: timingWindow
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func decisionReview(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        let packet = request.packet
        let decisionDensity = signal(named: "decision_density", in: packet)
        guard decisionDensity >= adjustedMinimumSignal(0.24, in: packet, floor: 0.16) else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }

        let reminder = enrichmentItem(for: .reminders, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let timingWindow = timingWindowHint(
            calendar: calendar,
            reminder: reminder,
            trigger: packet.triggerKind,
            preferTransition: true
        )
        let explicitDecision = packet.candidateContinuityItems.first(where: { $0.kind == .decision })
        let decision = explicitDecision?.body
            ?? explicitDecision?.title
            ?? reminder?.title
            ?? calendar?.title
            ?? packet.candidateContinuityItems.first?.title
            ?? packet.candidateThreadRefs.first?.summary
            ?? "в дне есть несколько развилок, которые лучше зафиксировать явно"
        let kind: AdvisoryArtifactKind = explicitDecision == nil ? .missedSignal : .decisionReminder
        let actionSteps = explicitDecision == nil
            ? [
                "Назвать развилку одним предложением.",
                "Записать, какой implicit выбор уже случился.",
                "Решить, нужно ли его закрепить явно."
            ]
            : [
                "Что именно было выбрано.",
                "Что было отвергнуто и почему.",
                "Какой следующий эффект это создаёт для текущей нити."
            ]
        var bodyLines = [
            kind == .missedSignal
                ? "Похоже, здесь есть missed signal: развилка уже влияет на день, но ещё не названа явно."
                : "Похоже, здесь уже образовалось решение, которое лучше не держать только в голове.",
            "Что стоит зафиксировать: \(AdvisorySupport.cleanedSnippet(decision, maxLength: 170)).",
        ]
        if let reminder {
            bodyLines.append("Есть и внешний operational anchor: \(enrichmentAnchor(for: reminder)).")
        } else if let calendar {
            bodyLines.append("Есть и внешний operational anchor: \(enrichmentAnchor(for: calendar)).")
        }
        if let timingWindow, !timingWindow.isEmpty {
            bodyLines.append("Хорошее окно для такой фиксации \(timingWindow).")
        }
        bodyLines.append("Хороший формат фиксации:")
        bodyLines.append("1. \(actionSteps[0])")
        bodyLines.append("2. \(actionSteps[1])")
        bodyLines.append("3. \(actionSteps[2])")
        let body = bodyLines.joined(separator: "\n")

        let artifact = AdvisoryArtifactCandidate(
            id: nil,
            domain: .decisions,
            kind: kind,
            title: kind == .missedSignal ? "Назвать пропущенный decision signal" : "Зафиксировать решение, пока оно свежее",
            body: body,
            threadId: packet.candidateThreadRefs.first?.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: min(0.83, 0.48 + decisionDensity * 0.3),
            whyNow: "Decision domain важен, пока развилка ещё связана с реальным evidence сегодняшнего дня.",
            evidenceJson: AdvisorySupport.encodeJSONString(packet.evidenceRefs.prefix(8).map { $0 }),
            metadataJson: guidanceMetadata(
                summary: kind == .missedSignal ? "Implicit decision signal detected." : "Decision worth fixing explicitly.",
                evidencePack: packet.evidenceRefs.prefix(3).map { $0 },
                actionSteps: actionSteps,
                decisionText: decision,
                patternName: kind == .missedSignal ? "Missed Signal" : "Decision Reminder",
                sourceAnchors: enrichmentAnchors(from: [reminder, calendar]),
                enrichmentSources: enrichmentSources(from: [reminder, calendar]),
                timingWindow: timingWindow
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func lifeAdminReview(_ request: AdvisoryRecipeRequest) -> AdvisoryRecipeResult {
        let packet = request.packet
        guard signal(named: "life_admin_pressure", in: packet) >= adjustedMinimumSignal(0.22, in: packet, floor: 0.14) else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }

        let reminderItem = enrichmentItem(for: .reminders, in: packet)
        let calendar = enrichmentItem(for: .calendar, in: packet)
        let timingWindow = timingWindowHint(
            calendar: calendar,
            reminder: reminderItem,
            trigger: packet.triggerKind,
            preferTransition: true
        )
        let reminder = reminderItem?.title
            ?? packet.candidateContinuityItems.first?.title
            ?? packet.activeEntities.dropFirst().first
            ?? "несколько административных хвостов"
        let actionSteps = [
            "Сформулировать один micro-task.",
            "Привязать его к следующему transition, а не в deep work.",
            "Оставить явный done-state."
        ]
        var bodyLines = [
            "Похоже, здесь есть life admin хвост, который лучше не держать фоном.",
            "Самый вероятный кандидат: \(reminder).",
            "Это не urgent pressure, а мягкое напоминание, чтобы хвост не продолжал съедать внимание.",
        ]
        if let reminderItem {
            bodyLines.append("Самый явный внешний anchor из reminders: \(enrichmentAnchor(for: reminderItem)).")
        } else if let calendar {
            bodyLines.append("Есть подходящий transition anchor: \(enrichmentAnchor(for: calendar)).")
        }
        if let timingWindow, !timingWindow.isEmpty {
            bodyLines.append("Мягче всего делать это \(timingWindow).")
        }
        bodyLines.append("Если захочешь закрыть аккуратно:")
        bodyLines.append("1. \(actionSteps[0])")
        bodyLines.append("2. \(actionSteps[1])")
        bodyLines.append("3. \(actionSteps[2])")
        let body = bodyLines.joined(separator: "\n")

        let artifact = AdvisoryArtifactCandidate(
            id: nil,
            domain: .lifeAdmin,
            kind: .lifeAdminReminder,
            title: "Тихий admin хвост просит явной фиксации",
            body: body,
            threadId: packet.candidateThreadRefs.first?.id,
            sourcePacketId: packet.packetId,
            sourceRecipe: request.recipeName,
            confidence: min(0.8, 0.46 + signal(named: "life_admin_pressure", in: packet) * 0.3),
            whyNow: "Life admin лучше поднимать в transition, пока он не превращается в фоновый шум.",
            evidenceJson: AdvisorySupport.encodeJSONString(packet.evidenceRefs.prefix(8).map { $0 }),
            metadataJson: guidanceMetadata(
                summary: "Quiet life admin tail detected.",
                evidencePack: packet.evidenceRefs.prefix(3).map { $0 },
                actionSteps: actionSteps,
                candidateTask: reminder,
                patternName: "Life Admin Reminder",
                sourceAnchors: enrichmentAnchors(from: [reminderItem, calendar]),
                enrichmentSources: enrichmentSources(from: [reminderItem, calendar]),
                timingWindow: timingWindow
            ),
            language: packet.language,
            status: .candidate,
            createdAt: nil,
            surfacedAt: nil,
            expiresAt: nil
        )
        return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [artifact], continuityProposals: [])
    }

    private func suggestedContinuations(
        thread: ReflectionThreadRef,
        items: [ReflectionContinuityItemRef],
        sessions: [ReflectionSalientSession]
    ) -> [String] {
        var options: [String] = []
        if let firstItem = items.first {
            options.append("Вернуться к узкому вопросу «\(firstItem.title)» и быстро зафиксировать следующий сдвиг.")
        }
        if let session = sessions.first(where: { ($0.evidenceSnippet ?? "").localizedCaseInsensitiveContains(thread.title) }) {
            let anchor = session.windowTitle ?? session.appName
            options.append("Открыть \(anchor) и восстановить контекст от последнего заметного фрагмента.")
        }
        options.append("Собрать короткий memo по нитке \(thread.title): что уже ясно, что ещё не закрыто.")

        while options.count < 3 {
            options.append("Проверить, где здесь следующий минимальный шаг без расширения контекста.")
        }
        return Array(options.prefix(3))
    }

    private func whyNow(trigger: AdvisoryTriggerKind) -> String {
        switch trigger {
        case .morningResume:
            return "С утра continuity value выше, пока нить ещё легко поднять."
        case .reentryAfterIdle:
            return "После паузы дешевле сначала вернуться в сильную нить, чем собирать контекст заново."
        case .userInvokedLost:
            return "Запрос был ручным, значит полезнее не новая идея, а лучший вход обратно."
        default:
            return "Сейчас здесь достаточно сигнала и опоры на evidence."
        }
    }

    private func signal(named name: String, in packet: AdvisoryPacket) -> Double {
        packet.attentionSignals.first(where: { $0.name == name })?.score ?? 0
    }

    private func adjustedMinimumSignal(
        _ base: Double,
        in packet: AdvisoryPacket,
        floor: Double
    ) -> Double {
        guard packet.triggerKind.isUserInvoked else {
            return base
        }
        return max(floor, base - 0.12)
    }

    private func notesEnrichment(in packet: AdvisoryPacket) -> [ReflectionEnrichmentItem] {
        enrichmentItems(for: .notes, in: packet)
    }

    private func enrichmentItems(
        for source: AdvisoryEnrichmentSource,
        in packet: AdvisoryPacket
    ) -> [ReflectionEnrichmentItem] {
        packet.enrichment.bundles
            .first(where: { $0.source == source && $0.availability == .embedded })?
            .items ?? []
    }

    private func enrichmentItem(
        for source: AdvisoryEnrichmentSource,
        in packet: AdvisoryPacket
    ) -> ReflectionEnrichmentItem? {
        enrichmentItems(for: source, in: packet).first
    }

    private func enrichmentAnchor(for item: ReflectionEnrichmentItem) -> String {
        let snippet = AdvisorySupport.cleanedSnippet(item.snippet, maxLength: 110)
        if snippet.isEmpty {
            return "\(item.source.label): \(item.title)"
        }
        return "\(item.source.label): \(item.title) — \(snippet)"
    }

    private func enrichmentAnchors(from items: [ReflectionEnrichmentItem?]) -> [String] {
        AdvisorySupport.dedupe(items.compactMap { $0 }.map(enrichmentAnchor(for:)))
    }

    private func enrichmentSources(from items: [ReflectionEnrichmentItem?]) -> [AdvisoryEnrichmentSource] {
        var seen: Set<AdvisoryEnrichmentSource> = []
        var sources: [AdvisoryEnrichmentSource] = []
        for source in items.compactMap({ $0?.source }) where seen.insert(source).inserted {
            sources.append(source)
        }
        return sources
    }

    private func timingWindowHint(
        calendar: ReflectionEnrichmentItem?,
        reminder: ReflectionEnrichmentItem?,
        trigger: AdvisoryTriggerKind,
        preferTransition: Bool
    ) -> String? {
        if let reminder {
            return preferTransition
                ? "в следующий transition вокруг «\(reminder.title)»"
                : "рядом с напоминанием «\(reminder.title)»"
        }
        guard let calendar else { return nil }
        switch trigger {
        case .morningResume:
            return "до ближайшего календарного блока «\(calendar.title)»"
        case .reentryAfterIdle, .focusBreakNatural:
            return "в коротком окне рядом с «\(calendar.title)»"
        default:
            return preferTransition
                ? "в следующем transition вокруг «\(calendar.title)»"
                : "вокруг окна «\(calendar.title)»"
        }
    }

    private func guidanceMetadata(
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
    ) -> String? {
        AdvisorySupport.encodeJSONString(
            AdvisoryArtifactGuidanceMetadata(
                summary: summary,
                primaryAngle: primaryAngle,
                alternativeAngles: alternativeAngles,
                evidencePack: evidencePack,
                actionSteps: actionSteps,
                focusQuestion: focusQuestion,
                continuityAnchor: continuityAnchor,
                openLoop: openLoop,
                decisionText: decisionText,
                candidateTask: candidateTask,
                noteAnchorTitle: noteAnchorTitle,
                noteAnchorSnippet: noteAnchorSnippet,
                patternName: patternName,
                sourceAnchors: sourceAnchors,
                enrichmentSources: enrichmentSources,
                timingWindow: timingWindow
            )
        )
    }

    private func preferredAngle(
        in packet: AdvisoryPacket,
        fallback: String
    ) -> String {
        packet.constraints.preferredAngles.first ?? fallback
    }

    private func alternativeAngles(
        in packet: AdvisoryPacket,
        excluding primaryAngle: String
    ) -> [String] {
        let candidates = packet.constraints.preferredAngles.filter { $0 != primaryAngle }
        if candidates.isEmpty {
            return ["question", "lesson_learned"].filter { $0 != primaryAngle }
        }
        return Array(candidates.prefix(2))
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
        return try call(
            method: "advisor.runRecipe",
            params: request,
            timeoutSeconds: request.timeoutSeconds
        )
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
            timeoutSeconds: min(6, defaultTimeoutSeconds)
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
        try writeAll(fd: fd, data: framedPayload)
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

    private static func writeAll(fd: Int32, data: Data) throws {
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
