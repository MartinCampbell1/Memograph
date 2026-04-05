import Foundation

enum AdvisoryProviderSessionAction: String, Codable, CaseIterable, Identifiable {
    case runAuthCheck = "run_auth_check"
    case login
    case relogin
    case logout
    case addAccount = "add_account"
    case switchAccount = "switch_account"
    case openConfigDir = "open_config_dir"
    case openCLI = "open_cli"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .runAuthCheck:
            return "Run auth check"
        case .login:
            return "Login"
        case .relogin:
            return "Re-login"
        case .logout:
            return "Logout"
        case .addAccount:
            return "Add account"
        case .switchAccount:
            return "Switch account"
        case .openConfigDir:
            return "Open config dir"
        case .openCLI:
            return "Open CLI"
        }
    }
}

struct AdvisoryProviderDiagnostic: Codable, Equatable, Identifiable {
    let providerName: String
    let status: String
    let detail: String?
    let binaryPresent: Bool
    let sessionDetected: Bool
    let priority: Int
    let cooldownRemainingSeconds: Int?
    let accountIdentity: String?
    let accountDetail: String?
    let configDirectory: String?
    let supportedActions: [AdvisoryProviderSessionAction]
    let failureCount: Int?
    let runnable: Bool?
    let lastCheckedAt: String?

    init(
        providerName: String,
        status: String,
        detail: String?,
        binaryPresent: Bool,
        sessionDetected: Bool,
        priority: Int,
        cooldownRemainingSeconds: Int? = nil,
        accountIdentity: String? = nil,
        accountDetail: String? = nil,
        configDirectory: String? = nil,
        supportedActions: [AdvisoryProviderSessionAction] = [],
        failureCount: Int? = nil,
        runnable: Bool? = nil,
        lastCheckedAt: String? = nil
    ) {
        self.providerName = providerName
        self.status = status
        self.detail = detail
        self.binaryPresent = binaryPresent
        self.sessionDetected = sessionDetected
        self.priority = priority
        self.cooldownRemainingSeconds = cooldownRemainingSeconds
        self.accountIdentity = accountIdentity
        self.accountDetail = accountDetail
        self.configDirectory = configDirectory
        self.supportedActions = supportedActions
        self.failureCount = failureCount
        self.runnable = runnable
        self.lastCheckedAt = lastCheckedAt
    }

    var id: String { providerName }

    var displayName: String {
        providerName.capitalized
    }

    var statusLabel: String {
        switch status {
        case "ok":
            return "ready"
        case "busy":
            return "busy"
        case "session_expired":
            return "session expired"
        case "session_missing":
            return "session missing"
        case "binary_missing":
            return "binary missing"
        case "cooldown":
            return "cooling down"
        case "not_checked":
            return "not checked"
        default:
            return status.replacingOccurrences(of: "_", with: " ")
        }
    }

    func supports(_ action: AdvisoryProviderSessionAction) -> Bool {
        supportedActions.contains(action)
    }
}

struct AdvisoryBridgeHealth: Codable, Equatable {
    let runtimeName: String
    let status: String
    let providerName: String
    let transport: String
    let statusDetail: String?
    let lastError: String?
    let recommendedAction: String?
    let activeProviderName: String?
    let providerOrder: [String]
    let availableProviders: [String]
    let providerStatuses: [AdvisoryProviderDiagnostic]
    let checkedAt: String?
    let runtimeHealthTier: String?       // "ok" | "degraded" | "unavailable"
    let providerHealthTier: String?      // "ok" | "no_runnable" | "session_expired" | "cooldown"

    init(
        runtimeName: String,
        status: String,
        providerName: String,
        transport: String,
        statusDetail: String? = nil,
        lastError: String? = nil,
        recommendedAction: String? = nil,
        activeProviderName: String? = nil,
        providerOrder: [String] = [],
        availableProviders: [String] = [],
        providerStatuses: [AdvisoryProviderDiagnostic] = [],
        checkedAt: String? = nil,
        runtimeHealthTier: String? = nil,
        providerHealthTier: String? = nil
    ) {
        self.runtimeName = runtimeName
        self.status = status
        self.providerName = providerName
        self.transport = transport
        self.statusDetail = statusDetail
        self.lastError = lastError
        self.recommendedAction = recommendedAction
        self.activeProviderName = activeProviderName
        self.providerOrder = providerOrder
        self.availableProviders = availableProviders
        self.providerStatuses = providerStatuses
        self.checkedAt = checkedAt
        self.runtimeHealthTier = runtimeHealthTier
        self.providerHealthTier = providerHealthTier
    }
}

struct AdvisoryBridgeRuntimeSnapshot: Equatable {
    let mode: AdvisoryBridgeMode
    let bridgeHealth: AdvisoryBridgeHealth
    let effectiveStatus: String
    let fallbackActive: Bool
    let supervisorStatus: String?
    let consecutiveFailures: Int
    let autoStartEnabled: Bool
    let socketPresent: Bool
    let lastError: String?
    let recommendedAction: String?
    let updatedAt: Date

    var isNominal: Bool {
        effectiveStatus == "ready" || effectiveStatus == "stub_only"
    }

    var isDegraded: Bool {
        !isNominal
    }

    /// Summary of the sidecar runtime health tier (dead / starting / degraded / ready).
    var runtimeStatusSummary: String {
        switch effectiveStatus {
        case "ready":
            return "Runtime: ready"
        case "stub_only":
            return "Runtime: stub only"
        case "starting":
            return "Runtime: starting"
        case "backoff":
            return "Runtime: backing off"
        case "timeout":
            return "Runtime: timed out"
        case "busy":
            return "Runtime: busy"
        case "transport_failure":
            return "Runtime: transport failure"
        case "fallback":
            return "Runtime: degraded (fallback)"
        default:
            return "Runtime: \(effectiveStatus.replacingOccurrences(of: "_", with: " "))"
        }
    }

    /// Summary of the best available provider health tier (none / degraded / ready).
    ///
    /// When the sidecar runtime is unreachable the provider statuses list will
    /// be empty because the sidecar cannot report them. In that case the summary
    /// falls back to the filesystem-based CLI profiles inventory so the UI does
    /// not incorrectly claim "none configured" while account cards are visible.
    var providerStatusSummary: String {
        let statuses = bridgeHealth.providerStatuses
        if statuses.isEmpty {
            // Runtime is down or returned no provider info — check filesystem inventory.
            let inventoryCount = Self.filesystemAccountCount()
            if inventoryCount > 0 {
                return "Provider inventory: \(inventoryCount) account\(inventoryCount == 1 ? "" : "s") found, runtime verification unavailable"
            }
            return "Provider: none configured"
        }
        if let active = bridgeHealth.activeProviderName, !active.isEmpty {
            return "Provider: \(active) active"
        }
        let hasReady = statuses.contains { $0.status == "ok" }
        if hasReady {
            return "Provider: available"
        }
        let hasDegraded = statuses.contains { $0.status == "session_expired" || $0.status == "session_missing" }
        if hasDegraded {
            return "Provider: session needed"
        }
        return "Provider: unavailable"
    }

    /// Counts accounts visible in the filesystem CLI profiles inventory.
    /// This is intentionally a lightweight, synchronous check so the UI
    /// can distinguish "no accounts at all" from "accounts exist but the
    /// runtime cannot verify them right now".
    private static func filesystemAccountCount() -> Int {
        let settings = AppSettings()
        let profiles = AdvisoryCLIProfilesStore.discoverProfiles(
            profilesPath: settings.advisoryCLIProfilesPath,
            selectedAccounts: AdvisoryCLIProfilesStore.selectedAccounts(settings: settings)
        )
        return profiles.values.reduce(0) { $0 + $1.count }
    }

    var title: String {
        switch effectiveStatus {
        case "ready":
            return "Advisory sidecar ready"
        case "stub_only":
            return "Advisory stub only"
        case "busy":
            return "Advisory sidecar busy"
        case "session_expired":
            return "Advisory provider session expired"
        case "no_provider":
            return "Advisory has no provider"
        case "timeout":
            return "Advisory sidecar timed out"
        case "transport_failure":
            return "Advisory transport failed"
        case "fallback":
            return "Advisory degraded"
        case "starting":
            return "Advisory sidecar starting"
        case "backoff":
            return "Advisory sidecar backing off"
        default:
            return "Advisory limited"
        }
    }

    var providerStatusLines: [String] {
        bridgeHealth.providerStatuses
            .sorted { $0.priority < $1.priority }
            .map { diagnostic in
                let prefix = bridgeHealth.activeProviderName == diagnostic.providerName ? "selected" : diagnostic.statusLabel
                if let detail = diagnostic.detail, !detail.isEmpty {
                    return "\(diagnostic.displayName): \(prefix) · \(detail)"
                }
                return "\(diagnostic.displayName): \(prefix)"
            }
    }

    var statusLines: [String] {
        var lines: [String] = []
        switch effectiveStatus {
        case "ready":
            lines.append("advisor: sidecar ready")
        case "stub_only":
            lines.append("advisor: local stub only")
        case "busy":
            lines.append("advisor: sidecar busy, advisory will retry")
        case "session_expired":
            lines.append("advisor: provider session expired, работает degraded path")
        case "no_provider":
            lines.append("advisor: sidecar без доступного provider")
        case "timeout":
            lines.append("advisor: sidecar timed out, advisory ограничен")
        case "transport_failure":
            lines.append("advisor: transport failure, advisory ограничен")
        case "fallback":
            lines.append("advisor: sidecar недоступен, работает fallback")
        case "starting":
            lines.append("advisor: sidecar запускается")
        case "backoff":
            lines.append("advisor: sidecar ушёл в backoff")
        default:
            lines.append("advisor: advisory временно ограничен")
        }

        if fallbackActive {
            lines.append("advisor fallback active")
        }
        if let supervisorStatus, !supervisorStatus.isEmpty, supervisorStatus != effectiveStatus {
            lines.append("supervisor: \(supervisorStatus)")
        }
        if bridgeHealth.providerName != "local_stub" {
            lines.append("provider: \(bridgeHealth.providerName)")
        }
        if let activeProviderName = bridgeHealth.activeProviderName, !activeProviderName.isEmpty {
            lines.append("active provider: \(activeProviderName)")
        }
        if !bridgeHealth.availableProviders.isEmpty {
            lines.append("available providers: \(bridgeHealth.availableProviders.joined(separator: ", "))")
        } else if bridgeHealth.providerStatuses.contains(where: { $0.binaryPresent || $0.sessionDetected }) {
            let unavailable = bridgeHealth.providerStatuses
                .sorted { $0.priority < $1.priority }
                .prefix(2)
                .map { "\($0.providerName): \($0.statusLabel)" }
            if !unavailable.isEmpty {
                lines.append("providers: \(unavailable.joined(separator: " · "))")
            }
        }
        if consecutiveFailures > 0 {
            lines.append("sidecar failures: \(consecutiveFailures)")
        }
        if let lastError, !lastError.isEmpty {
            lines.append("advisor error: \(lastError)")
        }
        if let recommendedAction, !recommendedAction.isEmpty {
            lines.append(recommendedAction)
        }
        return lines
    }
}

struct AdvisoryRecipeRequest: Codable {
    let runId: String
    let recipeName: String
    let packet: AdvisoryPacket
    let accessLevel: AdvisoryAccessProfile
    let timeoutSeconds: Int
}

struct AdvisoryRecipeResult: Codable {
    let runId: String
    let artifactProposals: [AdvisoryArtifactCandidate]
    let continuityProposals: [ContinuityItemCandidate]
    var source: String?  // "sidecar" | "stub" — nil treated as "sidecar" for backward compat
}

struct AdvisoryBridgeExecution {
    let result: AdvisoryRecipeResult
    let activeHealth: AdvisoryBridgeHealth
    let attemptedPrimaryHealth: AdvisoryBridgeHealth?
    let usedFallback: Bool
    let primaryFailure: String?
}

struct AdvisoryProviderAuthCheckResult {
    let provider: String
    let accountName: String?
    let verified: Bool
    let status: String
    let detail: String?
    let lastVerifiedAt: Date
    let health: AdvisoryBridgeHealth
}

struct AdvisoryProviderAuthCheckResponse: Codable, Equatable {
    let providerName: String
    let accountName: String?
    let verified: Bool
    let status: String
    let detail: String?
    let checkedAt: String?
}

enum AdvisoryBridgeError: LocalizedError {
    case unavailable(String)
    case transportFailure(String)
    case invalidResponse(String)
    case sidecarFailure(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message),
             let .transportFailure(message),
             let .invalidResponse(message),
             let .sidecarFailure(message):
            return message
        }
    }
}

protocol AdvisoryBridgeServerProtocol {
    func health() -> AdvisoryBridgeHealth
    func refreshHealth() -> AdvisoryBridgeHealth
    func authCheck(providerName: String, accountName: String?, forceRefresh: Bool) throws -> AdvisoryProviderAuthCheckResponse
    func accounts(forceRefresh: Bool) throws -> AdvisoryProviderAccountsSnapshot
    func openLogin(providerName: String) throws -> AdvisoryProviderAccountActionResponse
    func importCurrentSession(providerName: String, accountName: String?) throws -> AdvisoryProviderAccountActionResponse
    func reauthorize(providerName: String, accountName: String) throws -> AdvisoryProviderAccountActionResponse
    func setAccountLabel(providerName: String, accountName: String, label: String) throws -> AdvisoryProviderAccountActionResponse
    func setPreferredAccount(providerName: String, accountName: String) throws -> AdvisoryProviderAccountActionResponse
    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult
    func cancelRun(runId: String)
}

extension AdvisoryBridgeServerProtocol {
    func refreshHealth() -> AdvisoryBridgeHealth {
        health()
    }

    func authCheck(providerName: String, accountName: String?, forceRefresh: Bool) throws -> AdvisoryProviderAuthCheckResponse {
        let runtimeHealth = forceRefresh ? refreshHealth() : health()
        let providerLower = providerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let providerDiagnostic = runtimeHealth.providerStatuses.first(where: { $0.providerName.lowercased() == providerLower })
        let status = providerDiagnostic?.status ?? runtimeHealth.status
        let detail = providerDiagnostic?.detail ?? runtimeHealth.statusDetail ?? runtimeHealth.lastError
        return AdvisoryProviderAuthCheckResponse(
            providerName: providerName,
            accountName: accountName,
            verified: status == "ok",
            status: status,
            detail: detail,
            checkedAt: runtimeHealth.checkedAt
        )
    }

    func accounts(forceRefresh _: Bool) throws -> AdvisoryProviderAccountsSnapshot {
        .empty
    }

    func openLogin(providerName _: String) throws -> AdvisoryProviderAccountActionResponse {
        throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
    }

    func importCurrentSession(providerName _: String, accountName _: String?) throws -> AdvisoryProviderAccountActionResponse {
        throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
    }

    func reauthorize(providerName _: String, accountName _: String) throws -> AdvisoryProviderAccountActionResponse {
        throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
    }

    func setAccountLabel(providerName _: String, accountName _: String, label _: String) throws -> AdvisoryProviderAccountActionResponse {
        throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
    }

    func setPreferredAccount(providerName _: String, accountName _: String) throws -> AdvisoryProviderAccountActionResponse {
        throw AdvisoryBridgeError.unavailable("Accounts control requires memograph-advisor.")
    }
}
