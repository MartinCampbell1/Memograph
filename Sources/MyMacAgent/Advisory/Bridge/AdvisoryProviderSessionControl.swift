import AppKit
import Foundation

enum AdvisoryProviderSessionActionPlanKind: Equatable {
    case refreshOnly
    case openDirectory(String)
    case terminalCommand([String])
}

struct AdvisoryProviderSessionActionPlan: Equatable {
    let providerName: String
    /// The specific account being acted on (e.g. "acc1"). When set, recovery
    /// polling validates this exact account rather than any account for the provider.
    let accountName: String?
    let action: AdvisoryProviderSessionAction
    let kind: AdvisoryProviderSessionActionPlanKind
    let guidance: String
    let environment: [String: String]

    init(
        providerName: String,
        accountName: String? = nil,
        action: AdvisoryProviderSessionAction,
        kind: AdvisoryProviderSessionActionPlanKind,
        guidance: String,
        environment: [String: String] = [:]
    ) {
        self.providerName = providerName
        self.accountName = accountName
        self.action = action
        self.kind = kind
        self.guidance = guidance
        self.environment = environment
    }
}

enum AdvisoryProviderSessionControlError: LocalizedError {
    case unsupportedAction(String)
    case missingConfigDirectory(String)
    case failedToLaunch(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedAction(message),
             let .missingConfigDirectory(message),
             let .failedToLaunch(message):
            return message
        }
    }
}

enum AdvisoryProviderSessionControl {
    static func plan(
        for diagnostic: AdvisoryProviderDiagnostic,
        action: AdvisoryProviderSessionAction
    ) -> AdvisoryProviderSessionActionPlan? {
        guard diagnostic.supports(action) || action == .runAuthCheck else {
            return nil
        }

        switch action {
        case .runAuthCheck:
            return AdvisoryProviderSessionActionPlan(
                providerName: diagnostic.providerName,
                action: action,
                kind: .refreshOnly,
                guidance: "Running fresh auth check for \(diagnostic.displayName)."
            )
        case .openConfigDir:
            guard let path = diagnostic.configDirectory, !path.isEmpty else {
                return nil
            }
            return AdvisoryProviderSessionActionPlan(
                providerName: diagnostic.providerName,
                action: action,
                kind: .openDirectory(path),
                guidance: "Opening \(diagnostic.displayName) config directory."
            )
        case .login, .relogin, .logout, .addAccount, .switchAccount, .openCLI:
            guard let command = command(for: diagnostic.providerName, action: action) else {
                return nil
            }
            return AdvisoryProviderSessionActionPlan(
                providerName: diagnostic.providerName,
                action: action,
                kind: .terminalCommand(command),
                guidance: guidance(for: diagnostic.providerName, action: action)
            )
        }
    }

    static func launch(_ plan: AdvisoryProviderSessionActionPlan) throws {
        switch plan.kind {
        case .refreshOnly:
            return
        case let .openDirectory(path):
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case let .terminalCommand(command):
            try launchCommandInTerminal(command: command, environment: plan.environment)
        }
    }

    /// Launch the plan and monitor for session recovery of the **target provider**.
    /// Polls the target provider's account status every 3s via the accounts RPC.
    /// Calls completion(true) when the target provider has a verified/available account,
    /// or completion(false) on timeout.
    static func launchAndMonitorRecovery(
        _ plan: AdvisoryProviderSessionActionPlan,
        bridge: AdvisoryBridgeClient,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        do {
            try launch(plan)
        } catch {
            completion(false)
            return
        }

        let providerName = plan.providerName
        let targetAccountName = plan.accountName
        // Poll on a background queue — bridge methods are internally synchronized
        DispatchQueue.global(qos: .utility).async {
            let timeout: TimeInterval = 120
            let startTime = Date()
            var sidecarRestarted = false

            while Date().timeIntervalSince(startTime) < timeout {
                Thread.sleep(forTimeInterval: 3)

                // Check the TARGET account's status via accounts RPC, not global
                // health. Global health may already be "ok" (e.g. Claude is fine)
                // while the provider being re-logged-in (e.g. Gemini) hasn't recovered.
                // When accountName is specified, only that exact account counts.
                guard let snapshot = try? bridge.accounts(forceRefresh: true) else {
                    // Accounts RPC failed. Distinguish "sidecar is dead" from
                    // "sidecar is alive but busy" before taking destructive action.
                    let health = bridge.health(forceRefresh: false)
                    let status = health.status.lowercased()
                    if !sidecarRestarted && (status == "socket_missing" || status == "transport_failure") {
                        // Sidecar truly unreachable — restart once to clear backoff
                        bridge.restartSidecar()
                        sidecarRestarted = true
                    }
                    // If sidecar is reachable but busy/slow, just keep polling
                    continue
                }

                let providerAccounts = snapshot.accounts(for: providerName)
                let targetRecovered: Bool
                if let targetAccountName {
                    // Specific account — only that one must be available
                    targetRecovered = providerAccounts.contains {
                        $0.accountName == targetAccountName && $0.available
                    }
                } else {
                    // No specific account — any available account counts
                    targetRecovered = providerAccounts.contains { $0.available }
                }

                if targetRecovered {
                    let recovered = bridge.recoverAfterRelogin(provider: providerName)
                    completion(recovered.status == "ok")
                    return
                }
            }
            completion(false)
        }
    }

    static func launchCommandInTerminal(
        command: [String],
        environment: [String: String] = [:],
        workingDirectory: String? = nil
    ) throws {
        try launchInTerminal(
            command: command,
            environment: environment,
            workingDirectory: workingDirectory ?? NSHomeDirectory()
        )
    }

    static func preferredInteractiveAction(
        for diagnostic: AdvisoryProviderDiagnostic
    ) -> AdvisoryProviderSessionAction? {
        if diagnostic.supports(.relogin), diagnostic.sessionDetected || diagnostic.accountIdentity != nil {
            return .relogin
        }
        if diagnostic.supports(.login) {
            return .login
        }
        if diagnostic.supports(.openCLI) {
            return .openCLI
        }
        return nil
    }

    static func command(
        forProvider providerName: String,
        action: AdvisoryProviderSessionAction
    ) -> [String]? {
        command(for: providerName, action: action)
    }

    private static func command(
        for providerName: String,
        action: AdvisoryProviderSessionAction
    ) -> [String]? {
        switch (providerName.lowercased(), action) {
        case ("claude", .login), ("claude", .relogin):
            return ["claude", "auth", "login"]
        case ("claude", .logout):
            return ["claude", "auth", "logout"]
        case ("codex", .login), ("codex", .relogin):
            return ["codex", "login"]
        case ("gemini", .openCLI):
            return ["gemini"]
        default:
            return nil
        }
    }

    private static func guidance(
        for providerName: String,
        action: AdvisoryProviderSessionAction
    ) -> String {
        switch (providerName.lowercased(), action) {
        case ("claude", .login), ("claude", .relogin):
            return "Claude login flow opened in Terminal. Finish the browser flow, then run auth check."
        case ("claude", .logout):
            return "Claude logout command opened in Terminal."
        case ("codex", .login), ("codex", .relogin):
            return "Codex login flow opened in Terminal. Finish the browser flow, then run auth check."
        case ("gemini", .openCLI):
            return "Gemini CLI opened in Terminal. Complete login there if prompted, then run auth check."
        default:
            return "Interactive provider action opened in Terminal."
        }
    }

    private static func launchInTerminal(
        command: [String],
        environment: [String: String],
        workingDirectory: String
    ) throws {
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("memograph-provider-\(UUID().uuidString).command")
        let shellCommand = command.map(shellQuoted).joined(separator: " ")
        let exports = environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellQuoted($0.value))" }
        let script = [
            "#!/bin/zsh",
            "cd \(shellQuoted(workingDirectory))",
            exports.joined(separator: "\n"),
            shellCommand,
            "status=$?",
            "echo",
            "echo \"Exit status: $status\"",
            "echo \"Press Enter to keep the shell open.\"",
            "read",
            "exec \"$SHELL\" -l"
        ].joined(separator: "\n")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: scriptURL.path
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", "Terminal", scriptURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw AdvisoryProviderSessionControlError.failedToLaunch("Failed to open Terminal for provider action.")
            }
        } catch let error as AdvisoryProviderSessionControlError {
            throw error
        } catch {
            throw AdvisoryProviderSessionControlError.failedToLaunch(error.localizedDescription)
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        if value.isEmpty {
            return "''"
        }
        let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}
