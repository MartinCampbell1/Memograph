import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryProviderSessionControlTests {
    @Test("Claude session control plans re-login logout and config actions")
    func claudePlans() throws {
        let diagnostic = AdvisoryProviderDiagnostic(
            providerName: "claude",
            status: "ok",
            detail: "lazydroid@yahoo.com",
            binaryPresent: true,
            sessionDetected: true,
            priority: 0,
            accountIdentity: "lazydroid@yahoo.com",
            accountDetail: "max · claude.ai",
            configDirectory: "/Users/test/.claude",
            supportedActions: [.runAuthCheck, .login, .relogin, .logout, .openConfigDir],
            failureCount: 0,
            runnable: true,
            lastCheckedAt: "2026-04-05T08:00:00Z"
        )

        let primary = AdvisoryProviderSessionControl.preferredInteractiveAction(for: diagnostic)
        let relogin = AdvisoryProviderSessionControl.plan(for: diagnostic, action: .relogin)
        let logout = AdvisoryProviderSessionControl.plan(for: diagnostic, action: .logout)
        let config = AdvisoryProviderSessionControl.plan(for: diagnostic, action: .openConfigDir)

        #expect(primary == .relogin)
        #expect(relogin?.kind == .terminalCommand(["claude", "auth", "login"]))
        #expect(logout?.kind == .terminalCommand(["claude", "auth", "logout"]))
        #expect(config?.kind == .openDirectory("/Users/test/.claude"))
    }

    @Test("Codex and Gemini expose only supported interactive actions")
    func codexAndGeminiPlans() throws {
        let codex = AdvisoryProviderDiagnostic(
            providerName: "codex",
            status: "session_missing",
            detail: "No detectable session marker.",
            binaryPresent: true,
            sessionDetected: false,
            priority: 1,
            configDirectory: "/Users/test/.codex",
            supportedActions: [.runAuthCheck, .login, .relogin, .openConfigDir],
            failureCount: 0,
            runnable: false,
            lastCheckedAt: "2026-04-05T08:01:00Z"
        )
        let gemini = AdvisoryProviderDiagnostic(
            providerName: "gemini",
            status: "ok",
            detail: "Gemini session verified.",
            binaryPresent: true,
            sessionDetected: true,
            priority: 2,
            configDirectory: "/Users/test/.config/gemini",
            supportedActions: [.runAuthCheck, .openCLI, .openConfigDir],
            failureCount: 0,
            runnable: true,
            lastCheckedAt: "2026-04-05T08:02:00Z"
        )

        #expect(AdvisoryProviderSessionControl.preferredInteractiveAction(for: codex) == .login)
        #expect(AdvisoryProviderSessionControl.plan(for: codex, action: .login)?.kind == .terminalCommand(["codex", "login"]))
        #expect(AdvisoryProviderSessionControl.plan(for: codex, action: .logout) == nil)

        #expect(AdvisoryProviderSessionControl.preferredInteractiveAction(for: gemini) == .openCLI)
        #expect(AdvisoryProviderSessionControl.plan(for: gemini, action: .openCLI)?.kind == .terminalCommand(["gemini"]))
        #expect(AdvisoryProviderSessionControl.plan(for: gemini, action: .login) == nil)
    }
}

struct AdvisoryBridgeRefreshTests {
    @Test("Force refresh uses refreshHealth instead of cached health")
    func forceRefreshUsesRefreshHealth() throws {
        let server = RefreshAwareBridgeServer()
        let client = AdvisoryBridgeClient(
            primaryServer: server,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .requireSidecar
        )

        let stale = client.runtimeSnapshot()
        let fresh = client.runtimeSnapshot(forceRefresh: true)

        #expect(stale.bridgeHealth.status == "session_missing")
        #expect(fresh.bridgeHealth.status == "ok")
        #expect(server.refreshCount == 1)
    }
}

private final class RefreshAwareBridgeServer: AdvisoryBridgeServerProtocol {
    private(set) var refreshCount = 0

    func health() -> AdvisoryBridgeHealth {
        AdvisoryBridgeHealth(
            runtimeName: "memograph-advisor",
            status: "session_missing",
            providerName: "sidecar_jsonrpc_uds",
            transport: "jsonrpc_uds"
        )
    }

    func refreshHealth() -> AdvisoryBridgeHealth {
        refreshCount += 1
        return AdvisoryBridgeHealth(
            runtimeName: "memograph-advisor",
            status: "ok",
            providerName: "claude_cli",
            transport: "jsonrpc_uds",
            activeProviderName: "claude"
        )
    }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
    }

    func cancelRun(runId: String) {}
}
