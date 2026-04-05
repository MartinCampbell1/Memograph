import Darwin
import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryBridgeClientTests {
    @Test("Prefer sidecar reports degraded fallback when provider session is expired")
    func preferSidecarFallbackSnapshot() throws {
        let primary = StaticHealthBridgeServer(
            bridgeHealth: AdvisoryBridgeHealth(
                runtimeName: "memograph-advisor",
                status: "session_expired",
                providerName: "sidecar_jsonrpc_uds",
                transport: "jsonrpc_uds",
                statusDetail: "Claude CLI session expired",
                lastError: "Claude CLI session expired",
                recommendedAction: "Provider session expired. Перелогинь CLI provider для memograph-advisor."
            )
        )
        let client = AdvisoryBridgeClient(
            primaryServer: primary,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .preferSidecar
        )

        let snapshot = client.runtimeSnapshot()

        #expect(snapshot.effectiveStatus == "session_expired")
        #expect(snapshot.fallbackActive)
        #expect(snapshot.lastError == "Claude CLI session expired")
        #expect(snapshot.recommendedAction?.contains("Перелогинь CLI provider") == true)
    }

    @Test("Require sidecar reports unavailable when no provider is available")
    func requireSidecarUnavailableSnapshot() throws {
        let primary = StaticHealthBridgeServer(
            bridgeHealth: AdvisoryBridgeHealth(
                runtimeName: "memograph-advisor",
                status: "no_provider",
                providerName: "sidecar_jsonrpc_uds",
                transport: "jsonrpc_uds",
                statusDetail: "No provider available",
                lastError: "No provider available",
                recommendedAction: "No provider available. Проверь Claude/Gemini/Codex subscriptions или routing sidecar."
            )
        )
        let client = AdvisoryBridgeClient(
            primaryServer: primary,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .requireSidecar
        )

        let snapshot = client.runtimeSnapshot()

        #expect(snapshot.effectiveStatus == "no_provider")
        #expect(!snapshot.fallbackActive)
        #expect(snapshot.statusLines.contains(where: { $0.contains("No provider available") }))
    }

    @Test("Busy runtime remains busy instead of collapsing into transport failure")
    func busyRuntimeRemainsBusy() throws {
        let primary = StaticHealthBridgeServer(
            bridgeHealth: AdvisoryBridgeHealth(
                runtimeName: "memograph-advisor",
                status: "busy",
                providerName: "sidecar_jsonrpc_uds",
                transport: "jsonrpc_uds",
                statusDetail: "Provider auth check in progress",
                lastError: "Provider auth check in progress"
            )
        )
        let client = AdvisoryBridgeClient(
            primaryServer: primary,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .requireSidecar
        )

        let snapshot = client.runtimeSnapshot()

        #expect(snapshot.effectiveStatus == "busy")
        #expect(snapshot.title.contains("busy"))
        #expect(snapshot.statusLines.contains(where: { $0.contains("busy") }))
        #expect(!snapshot.statusLines.contains(where: { $0.contains("transport failure") }))
    }

    @Test("Stub only runtime snapshot stays nominal")
    func stubOnlySnapshot() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let snapshot = client.runtimeSnapshot()

        #expect(snapshot.effectiveStatus == "stub_only")
        #expect(snapshot.isNominal)
        #expect(snapshot.statusLines.contains(where: { $0.contains("local stub only") }))
    }

    @Test("Long advisory socket paths are normalized to a UDS-safe path")
    func normalizesLongSocketPaths() {
        let longPath = "/var/folders/test/\(String(repeating: "nested-segment-", count: 10))memograph-advisor.sock"
        let resolved = AdvisorySidecarSocketPathResolver.resolve(longPath)

        #expect(resolved != longPath)
        #expect(resolved.hasPrefix("/tmp/memograph-advisor-"))
        #expect(resolved.utf8.count < 100)
    }

    @Test("UDS read timeout normalizes to timeout instead of transport failure")
    func udsReadTimeoutNormalizesToTimeout() throws {
        let socketPath = temporarySocketPath()
        let server = try StallingUnixSocketServer(socketPath: socketPath)
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let bridge = JSONRPCAdvisoryBridgeServer(socketPath: socketPath, defaultTimeoutSeconds: 1)
        let resultQueue = DispatchQueue(label: "memograph.tests.uds.read-timeout")
        let group = DispatchGroup()
        var health: AdvisoryBridgeHealth?
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let response = bridge.health()
            resultQueue.sync {
                health = response
            }
            group.leave()
        }

        #expect(server.waitUntilAccepted(timeoutSeconds: 2))
        #expect(group.wait(timeout: .now() + 5) == .success)
        let resolvedHealth = try #require(resultQueue.sync { health })

        #expect(resolvedHealth.status == "timeout")
        #expect(resolvedHealth.recommendedAction?.contains("не ответил вовремя") == true)
    }

    @Test("Stale UDS socket with no listener normalizes to transport failure")
    func udsConnectFailureNormalizesToTransportFailure() throws {
        let socketPath = temporarySocketPath()
        try makeStaleUnixSocketFile(at: socketPath)
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let bridge = JSONRPCAdvisoryBridgeServer(socketPath: socketPath, defaultTimeoutSeconds: 1)
        let health = bridge.health()

        #expect(health.status == "transport_failure")
        #expect(health.recommendedAction?.contains("Проверь socket") == true)
        #expect(health.lastError?.contains("connect") == true || health.statusDetail?.contains("connect") == true)
    }

    @Test("Prefer sidecar auto-starts real memograph-advisor and executes continuity resume")
    func autoStartsRealSidecarAndExecutesRecipe() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)

        #expect(!execution.usedFallback)
        #expect(execution.activeHealth.status == "ok")
        #expect(artifact.kind == .resumeCard)
        #expect(artifact.domain == .continuity)
        #expect(artifact.language == "ru")
        #expect(artifact.body.contains("главная нить"))
    }

    @Test("Real sidecar health publishes provider diagnostics")
    func realSidecarHealthPublishesProviderDiagnostics() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let snapshot = client.runtimeSnapshot()
        #expect(snapshot.bridgeHealth.activeProviderName == "claude")
        #expect(snapshot.bridgeHealth.providerStatuses.contains(where: {
            $0.providerName == "claude" && $0.status == "ok"
        }))
        #expect(snapshot.providerStatusLines.contains(where: { $0.contains("Claude") }))
    }

    @Test("Real sidecar health publishes provider account identity and supported actions")
    func realSidecarHealthPublishesProviderAccountIdentity() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER_STATUSES": #"{"claude":{"status":"ok","detail":"Claude fake ready.","accountIdentity":"person@example.com","accountDetail":"max · claude.ai","sessionDetected":true,"binaryPresent":true}}"#
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let snapshot = client.runtimeSnapshot(forceRefresh: true)
        let claude = snapshot.bridgeHealth.providerStatuses.first(where: { $0.providerName == "claude" })

        #expect(claude?.accountIdentity == "person@example.com")
        #expect(claude?.accountDetail == "max · claude.ai")
        #expect(claude?.configDirectory?.hasSuffix(".claude") == true)
        #expect(claude?.supportedActions.contains(.relogin) == true)
        #expect(claude?.supportedActions.contains(.logout) == true)
    }

    @Test("Targeted auth check uses provider account RPC instead of global health refresh")
    func targetedAuthCheckUsesProviderAccountRpc() throws {
        let server = RecordingAuthCheckBridgeServer()
        let client = AdvisoryBridgeClient(
            primaryServer: server,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .requireSidecar
        )

        let result = client.checkProviderAuth(provider: "claude", accountName: "acc2", forceRefresh: true)

        #expect(result.verified)
        #expect(result.status == "ok")
        #expect(result.accountName == "acc2")
        #expect(server.authCheckCallCount == 1)
        #expect(server.lastAuthCheckProviderName == "claude")
        #expect(server.lastAuthCheckAccountName == "acc2")
        #expect(server.lastAuthCheckForceRefresh)
        #expect(server.healthCallCount == 1)
        #expect(server.refreshHealthCallCount == 0)
    }

    @Test("Stop sidecar terminates an externally owned pidfile process")
    func stopSidecarTerminatesExternalPidOwner() throws {
        let context = try makeSettingsContext(mode: .requireSidecar)
        defer { context.cleanup() }

        let socketPath = AdvisorySidecarSocketPathResolver.resolve(context.settings.advisorySidecarSocketPath)
        let launched = try ExternalSidecarHandle(
            socketPath: socketPath,
            environment: ["MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"]
        )
        defer { launched.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: ["MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"]
        )

        let externalPID = try #require(launched.pid)
        client.stopSidecar()

        let stopped = waitUntil(timeoutSeconds: 5) {
            !processIsAlive(externalPID) && readLivePID(from: launched.pidfilePath) == nil
        }

        #expect(stopped)
    }

    @Test("Restart sidecar replaces an externally owned pidfile process")
    func restartSidecarReplacesExternalPidOwner() throws {
        let context = try makeSettingsContext(mode: .requireSidecar)
        defer { context.cleanup() }

        let socketPath = AdvisorySidecarSocketPathResolver.resolve(context.settings.advisorySidecarSocketPath)
        let launched = try ExternalSidecarHandle(
            socketPath: socketPath,
            environment: ["MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"]
        )
        defer { launched.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: ["MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"]
        )

        let oldPID = try #require(launched.pid)
        client.restartSidecar()

        let replaced = waitUntil(timeoutSeconds: 8) {
            guard let currentPID = readLivePID(from: launched.pidfilePath) else { return false }
            return currentPID != oldPID
                && !processIsAlive(oldPID)
                && client.runtimeSnapshot().effectiveStatus == "ready"
        }

        #expect(replaced)
    }

    @Test("Detached sidecar janitor escalates cleanup for a SIGTERM-ignoring orphan")
    func cleanupDetachedSidecarsEscalatesForOrphanOwner() throws {
        let context = try makeSettingsContext(mode: .requireSidecar)
        defer { context.cleanup() }

        let socketPath = AdvisorySidecarSocketPathResolver.resolve(context.settings.advisorySidecarSocketPath)
        let launched = try ExternalSidecarHandle(
            socketPath: socketPath,
            environment: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude",
                "MEMOGRAPH_ADVISOR_IGNORE_SIGTERM": "1"
            ]
        )
        defer { launched.cleanup() }

        let orphanPID = try #require(launched.pid)
        AdvisoryBridgeClient.cleanupDetachedSidecars()

        let cleaned = waitUntil(timeoutSeconds: 6) {
            !processIsAlive(orphanPID) && readLivePID(from: launched.pidfilePath) == nil
        }

        #expect(cleaned)
    }

    @Test("Recover after re-login keeps a live sidecar instead of forcing restart")
    func recoverAfterReloginKeepsLiveRuntime() throws {
        let context = try makeSettingsContext(mode: .requireSidecar)
        defer { context.cleanup() }

        let profilesRoot = try makeAdvisoryProfilesFixture(provider: "claude", accountName: "acc1")
        defer { try? FileManager.default.removeItem(at: profilesRoot) }

        var settings = context.settings
        settings.advisoryCLIProfilesPath = profilesRoot.path

        let client = AdvisoryBridgeClient(
            settings: settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: ["MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let pidfilePath = AdvisorySidecarSocketPathResolver.resolve(settings.advisorySidecarSocketPath) + ".pid"
        let beforePID = try #require(readLivePID(from: pidfilePath))
        let result = client.recoverAfterRelogin(provider: "claude", accountName: "acc1")
        let afterPID = try #require(readLivePID(from: pidfilePath))

        #expect(beforePID == afterPID)
        #expect(result.accountName == "acc1")
    }

    @Test("Startup watchdog recovers from a delayed first launch without manual restart")
    func startupWatchdogRecoversDelayedFirstLaunch() throws {
        let context = try makeSettingsContext(mode: .requireSidecar)
        defer { context.cleanup() }

        let markerURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("memograph-advisor-startup-delay-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude",
                "MEMOGRAPH_ADVISOR_STARTUP_GRACE_SECONDS": "1",
                "MEMOGRAPH_ADVISOR_STARTUP_DELAY_SECONDS": "3",
                "MEMOGRAPH_ADVISOR_STARTUP_DELAY_ONCE_FILE": markerURL.path
            ]
        )
        defer { client.stopSidecar() }

        let recovered = waitUntil(timeoutSeconds: 10) {
            client.runtimeSnapshot(forceRefresh: true).effectiveStatus == "ready"
        }

        #expect(recovered)
    }

    @Test("Stub continuity resume uses external enrichment anchors and timing")
    func stubContinuityResumeUsesExternalEnrichmentAnchors() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeEnrichedContinuityRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .resumeCard)
        #expect(artifact.body.contains("Из заметок здесь уже держится опора"))
        #expect(artifact.body.contains("внешний anchor"))
        #expect(metadata.noteAnchorTitle == "Morning bridge checklist")
        #expect(metadata.enrichmentSources.contains(.calendar))
        #expect(metadata.enrichmentSources.contains(.reminders))
        #expect(metadata.sourceAnchors.contains(where: { $0.contains("Calendar: Advisory standup") }))
        #expect(metadata.sourceAnchors.contains(where: { $0.contains("Reminders: Re-run bridge smoke test") }))
        #expect(metadata.timingWindow?.contains("напоминанием") == true)
    }

    @Test("Real sidecar continuity resume uses external enrichment anchors and timing")
    func realSidecarContinuityResumeUsesExternalEnrichmentAnchors() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeEnrichedContinuityRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect(artifact.kind == .resumeCard)
        #expect(metadata.enrichmentSources.contains(.reminders))
        #expect(metadata.timingWindow?.contains("напоминанием") == true)
    }

    @Test("Require sidecar surfaces no-provider degraded state from real memograph-advisor")
    func realSidecarNoProviderDegradedState() throws {
        let context = try makeSettingsContext(mode: .requireSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FORCE_STATUS": "no_provider",
                "MEMOGRAPH_ADVISOR_FORCE_DETAIL": "No provider available"
            ]
        )
        defer { client.stopSidecar() }

        let degraded = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().bridgeHealth.status == "no_provider"
        }
        #expect(degraded)

        let snapshot = client.runtimeSnapshot()
        #expect(snapshot.bridgeHealth.status == "no_provider")
        #expect(snapshot.effectiveStatus == "no_provider" || snapshot.effectiveStatus == "unavailable")
        #expect(!snapshot.fallbackActive)
        #expect(snapshot.recommendedAction?.contains("No provider available") == true)

        do {
            _ = try client.executeRecipe(makeRecipeRequest())
            Issue.record("Expected require_sidecar execution to fail when no provider is available.")
        } catch {
            #expect(error.localizedDescription.contains("no_provider"))
        }
    }

    @Test("Runtime snapshot carries provider diagnostics")
    func runtimeSnapshotCarriesProviderDiagnostics() throws {
        let primary = StaticHealthBridgeServer(
            bridgeHealth: AdvisoryBridgeHealth(
                runtimeName: "memograph-advisor",
                status: "ok",
                providerName: "sidecar_jsonrpc_uds",
                transport: "jsonrpc_uds",
                statusDetail: "Claude selected",
                lastError: nil,
                recommendedAction: nil,
                activeProviderName: "claude",
                providerOrder: ["claude", "gemini", "codex"],
                availableProviders: ["claude", "gemini"],
                providerStatuses: [
                    AdvisoryProviderDiagnostic(
                        providerName: "claude",
                        status: "ok",
                        detail: "Claude session verified.",
                        binaryPresent: true,
                        sessionDetected: true,
                        priority: 0
                    ),
                    AdvisoryProviderDiagnostic(
                        providerName: "gemini",
                        status: "session_expired",
                        detail: "Gemini session expired.",
                        binaryPresent: true,
                        sessionDetected: true,
                        priority: 1
                    )
                ],
                checkedAt: "2026-04-05T09:15:00Z"
            )
        )
        let client = AdvisoryBridgeClient(
            primaryServer: primary,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .preferSidecar
        )

        let snapshot = client.runtimeSnapshot()

        #expect(snapshot.bridgeHealth.activeProviderName == "claude")
        #expect(snapshot.bridgeHealth.providerOrder == ["claude", "gemini", "codex"])
        #expect(snapshot.bridgeHealth.providerStatuses.count == 2)
        #expect(snapshot.providerStatusLines.contains(where: { $0.contains("Claude") && $0.contains("selected") }))
        #expect(snapshot.providerStatusLines.contains(where: { $0.contains("Gemini") && $0.contains("session expired") }))
    }

    @Test("Real sidecar honors configured provider order")
    func realSidecarHonorsConfiguredProviderOrder() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        var settings = context.settings
        settings.advisorySidecarProviderOrder = ["gemini", "claude"]

        let client = AdvisoryBridgeClient(
            settings: settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let snapshot = client.runtimeSnapshot()
        #expect(snapshot.bridgeHealth.providerOrder == ["gemini", "claude"])
        #expect(snapshot.bridgeHealth.activeProviderName == "claude")
    }

    @Test("Real sidecar rotates to the next provider after a transient run failure")
    func realSidecarRotatesProviderAfterTransientFailure() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        var settings = context.settings
        settings.advisorySidecarProviderOrder = ["claude", "gemini"]
        settings.advisorySidecarRetryAttempts = 2
        settings.advisorySidecarProviderCooldownSeconds = 2

        let client = AdvisoryBridgeClient(
            settings: settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER_STATUSES": #"{"claude":{"status":"ok","detail":"Claude fake ready."},"gemini":{"status":"ok","detail":"Gemini fake ready."}}"#,
                "MEMOGRAPH_ADVISOR_FAKE_RUN_FAILURES": #"{"claude":[{"status":"timeout","detail":"Claude fake run timeout.","cooldownSeconds":2}]}"#
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().bridgeHealth.activeProviderName == "claude"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeRecipeRequest())
        let snapshot = client.runtimeSnapshot()
        let claudeStatus = snapshot.bridgeHealth.providerStatuses.first(where: { $0.providerName == "claude" })

        #expect(!execution.usedFallback)
        #expect(execution.activeHealth.activeProviderName == "gemini")
        #expect(snapshot.bridgeHealth.activeProviderName == "gemini")
        #expect(claudeStatus?.status == "timeout")
        #expect((claudeStatus?.cooldownRemainingSeconds ?? 0) > 0)
    }

    @Test("Require sidecar retries transient primary failure before succeeding")
    func requireSidecarRetriesTransientPrimaryFailure() throws {
        let request = makeRecipeRequest()
        let primary = SequenceBridgeServer(
            healthSequence: [makeHealthyBridgeHealth()],
            runSequence: [
                .failure(AdvisoryBridgeError.transportFailure("timed out while reading advisory sidecar response")),
                .success(AdvisoryRecipeResult(
                    runId: request.runId,
                    artifactProposals: [],
                    continuityProposals: []
                ))
            ]
        )
        let client = AdvisoryBridgeClient(
            primaryServer: primary,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .requireSidecar,
            retryAttempts: 2
        )

        let execution = try client.executeRecipe(request)

        #expect(!execution.usedFallback)
        #expect(primary.runInvocations == 2)
        #expect(execution.activeHealth.status == "ok")
    }

    @Test("Prefer sidecar falls back after exhausting retry budget on transient failures")
    func preferSidecarFallsBackAfterRetryBudget() throws {
        let request = makeRecipeRequest()
        let primary = SequenceBridgeServer(
            healthSequence: [makeHealthyBridgeHealth()],
            runSequence: [
                .failure(AdvisoryBridgeError.transportFailure("timed out while reading advisory sidecar response")),
                .failure(AdvisoryBridgeError.transportFailure("timed out while reading advisory sidecar response"))
            ]
        )
        let client = AdvisoryBridgeClient(
            primaryServer: primary,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .preferSidecar,
            retryAttempts: 2
        )

        let execution = try client.executeRecipe(request)

        #expect(execution.usedFallback)
        #expect(primary.runInvocations == 2)
        #expect(execution.activeHealth.status == "fallback_stub")
    }

    @Test("Runtime resolver reports missing Python as an explicit preflight state")
    func runtimeResolverReportsMissingPython() {
        let result = AdvisorySidecarRuntimeResolver.resolve(
            fileManager: .default,
            bundle: .main,
            environment: ["PATH": "/definitely-missing"],
            preferredPythonCandidates: [
                "/definitely-missing/python3",
                "/still-missing/python3"
            ]
        )

        guard case .missingPython(let detail) = result else {
            Issue.record("Expected missingPython runtime status.")
            return
        }
        #expect(detail.contains("python3"))
    }

    @Test("Stub writing seed uses persona-aware tweet seed with angle evidence and alternatives")
    func stubWritingSeedUsesPersonaAwareTweetFormat() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(
            makeWritingRecipeRequest(
                preferredAngles: ["mini_framework", "question", "lesson_learned"],
                twitterVoiceExamples: ["Short grounded post", "Builder note with one sharp line"],
                avoidTopics: [],
                allowProvocation: false
            )
        )
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryWritingArtifactMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .tweetSeed)
        #expect(artifact.body.contains("Angle: mini_framework"))
        #expect(artifact.body.contains("Evidence pack:"))
        #expect(artifact.body.contains("Alternative angles:"))
        #expect(artifact.body.contains("Voice examples:"))
        #expect(artifact.body.contains("Черновой заход:"))
        #expect(metadata.primaryAngle == .miniFramework)
        #expect(metadata.alternativeAngles == [.question, .lessonLearned])
        #expect(metadata.voiceExamples == ["Short grounded post", "Builder note with one sharp line"])
        #expect(metadata.evidencePack.count == 3)
    }

    @Test("Writing seed respects avoidTopics and suppresses blocked content")
    func writingSeedRespectsAvoidTopics() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(
            makeWritingRecipeRequest(
                preferredAngles: ["observation", "question"],
                twitterVoiceExamples: [],
                avoidTopics: ["growth hacks"],
                allowProvocation: false,
                activeEntities: ["growth hacks", "Memograph"],
                threadTitle: "Growth hacks for Memograph"
            )
        )

        #expect(result.artifactProposals.isEmpty)
    }

    @Test("Real sidecar writing seed matches persona-aware tweet format")
    func realSidecarWritingSeedUsesPersonaFormat() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(
            makeWritingRecipeRequest(
                preferredAngles: ["contrarian_take", "question", "mini_framework"],
                twitterVoiceExamples: ["Sharp but grounded builder post"],
                avoidTopics: [],
                allowProvocation: false
            )
        )
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryWritingArtifactMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect(artifact.kind == .tweetSeed)
        #expect(artifact.body.contains("Angle: contrarian_take"))
        #expect(artifact.body.contains("Alternative angles:"))
        #expect(artifact.body.contains("Voice examples:"))
        #expect(metadata.primaryAngle == .contrarianTake)
        #expect(metadata.alternativeAngles == [.question, .miniFramework])
        #expect(metadata.voiceExamples == ["Sharp but grounded builder post"])
    }

    @Test("Research direction uses notes enrichment in stub mode")
    func stubResearchDirectionUsesNotesEnrichment() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeResearchRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)

        #expect(artifact.kind == .researchDirection)
        #expect(artifact.body.contains("Из заметок уже резонирует"))
        #expect(artifact.body.contains("Memograph Continuity Note"))
    }

    @Test("Real sidecar research direction uses notes enrichment")
    func realSidecarResearchDirectionUsesNotesEnrichment() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeResearchRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)

        #expect(artifact.kind == .researchDirection)
        #expect(artifact.body.contains("Из заметок уже резонирует"))
        #expect(artifact.body.contains("Memograph Continuity Note"))
    }

    @Test("Stub research direction stays grounded when web enrichment is embedded")
    func stubResearchDirectionUsesWebEnrichment() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeWebGroundedResearchRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .researchDirection)
        #expect(artifact.body.contains("browser context"))
        #expect(metadata.enrichmentSources.contains(.webResearch))
        #expect(metadata.sourceAnchors.contains(where: { $0.contains("Web: Attention market explainer") }))
        #expect(metadata.timingWindow?.contains("окна") == true || metadata.timingWindow?.contains("календар") == true)
    }

    @Test("Real sidecar research direction stays grounded when web enrichment is embedded")
    func realSidecarResearchDirectionUsesWebEnrichment() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeWebGroundedResearchRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect(artifact.kind == .researchDirection)
        #expect(metadata.enrichmentSources.contains(.webResearch))
    }

    @Test("Stub research direction widens to exploration seed without embedded notes")
    func stubResearchDirectionWidensToExplorationSeed() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeExplorationResearchRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .explorationSeed)
        #expect(artifact.title.contains("Exploration seed"))
        #expect(artifact.body.contains("exploration seed"))
        #expect(metadata.focusQuestion?.contains("недоказанным") == true)
        #expect(metadata.evidencePack.count == 3)
        #expect(metadata.actionSteps.count == 3)
    }

    @Test("Real sidecar research direction widens to exploration seed without embedded notes")
    func realSidecarResearchDirectionWidensToExplorationSeed() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeExplorationResearchRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect(artifact.kind == .explorationSeed)
        #expect(metadata.actionSteps.count == 3)
    }

    @Test("Stub focus reflection widens to focus intervention for fragmented context")
    func stubFocusReflectionWidensToIntervention() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeFocusRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .focusIntervention)
        #expect(artifact.body.contains("focus intervention"))
        #expect(metadata.patternName == "Focus Intervention")
        #expect(metadata.actionSteps.count == 3)
    }

    @Test("Real sidecar focus reflection widens to focus intervention for fragmented context")
    func realSidecarFocusReflectionWidensToIntervention() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeFocusRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)

        #expect(!execution.usedFallback)
        #expect(artifact.kind == .focusIntervention)
    }

    @Test("Stub manual focus pull gets user-invoked threshold bonus")
    func stubManualFocusPullUsesThresholdBonus() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeLowSignalManualFocusRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .focusIntervention || artifact.kind == .patternNotice)
        #expect(metadata.enrichmentSources.contains(.wearable))
        #expect(artifact.body.contains("rhythm"))
    }

    @Test("Real sidecar manual focus pull gets user-invoked threshold bonus")
    func realSidecarManualFocusPullUsesThresholdBonus() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeLowSignalManualFocusRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect(metadata.enrichmentSources.contains(.wearable))
    }

    @Test("Stub social signal uses web and reminder anchors")
    func stubSocialSignalUsesEnrichmentAnchors() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeSocialRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .socialNudge)
        #expect(artifact.body.contains("browser context"))
        #expect(metadata.enrichmentSources.contains(.webResearch))
        #expect(metadata.enrichmentSources.contains(.reminders))
        #expect(metadata.timingWindow?.contains("transition") == true)
    }

    @Test("Real sidecar social signal uses web and reminder anchors")
    func realSidecarSocialSignalUsesEnrichmentAnchors() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeSocialRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect(artifact.kind == .socialNudge)
        #expect(metadata.enrichmentSources.contains(.webResearch))
    }

    @Test("Stub decision review widens to missed signal without explicit decision item")
    func stubDecisionReviewWidensToMissedSignal() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeDecisionRecipeRequest(includeExplicitDecision: false))
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .missedSignal)
        #expect(artifact.body.contains("missed signal"))
        #expect(metadata.patternName == "Missed Signal")
        #expect(metadata.decisionText?.isEmpty == false)
    }

    @Test("Real sidecar decision review widens to missed signal without explicit decision item")
    func realSidecarDecisionReviewWidensToMissedSignal() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeDecisionRecipeRequest(includeExplicitDecision: false))
        let artifact = try #require(execution.result.artifactProposals.first)

        #expect(!execution.usedFallback)
        #expect(artifact.kind == .missedSignal)
    }

    @Test("Stub decision review uses reminder anchor when available")
    func stubDecisionReviewUsesReminderAnchor() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeDecisionRecipeRequest(includeExplicitDecision: false, includeReminderAnchor: true))
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.body.contains("operational anchor"))
        #expect(metadata.enrichmentSources.contains(.reminders))
        #expect(metadata.timingWindow?.contains("transition") == true)
    }

    @Test("Stub life admin review uses reminder anchor and timing")
    func stubLifeAdminReviewUsesReminderAnchor() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeLifeAdminRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .lifeAdminReminder)
        #expect(metadata.candidateTask == "Pay contractor invoice")
        #expect(metadata.enrichmentSources.contains(.reminders))
        #expect(metadata.sourceAnchors.contains(where: { $0.contains("Pay contractor invoice") }))
        #expect(metadata.timingWindow?.contains("transition") == true)
    }

    @Test("Stub health pulse uses wearable rhythm enrichment when available")
    func stubHealthPulseUsesWearableRhythm() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeHealthRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .healthReflection)
        #expect(artifact.body.contains("rhythm"))
        #expect(metadata.enrichmentSources.contains(.wearable))
        #expect(metadata.sourceAnchors.contains(where: { $0.contains("High cognitive load window") }))
    }

    @Test("Real sidecar health pulse uses wearable rhythm enrichment when available")
    func realSidecarHealthPulseUsesWearableRhythm() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeHealthRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect(metadata.enrichmentSources.contains(.wearable))
    }

    @Test("Stub tweet-from-thread uses thread packet continuity anchors")
    func stubTweetFromThreadUsesThreadPacket() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeThreadWritingRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryWritingArtifactMetadata.self, from: artifact.metadataJson))

        #expect([.tweetSeed, .threadSeed, .noteSeed].contains(artifact.kind))
        #expect(artifact.body.contains("Continuity anchor:"))
        #expect(artifact.body.contains("Alternative angles:"))
        #expect(artifact.body.contains("Note anchor:"))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.notes))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.webResearch))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.reminders))
        #expect(metadata.sourceAnchors.contains(where: { $0.contains("Thread notes scratchpad") }))
        #expect(metadata.timingWindow?.contains("transition") == true)
    }

    @Test("Real sidecar tweet-from-thread uses thread packet continuity anchors")
    func realSidecarTweetFromThreadUsesThreadPacket() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeThreadWritingRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryWritingArtifactMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect([.tweetSeed, .threadSeed, .noteSeed].contains(artifact.kind))
        #expect(artifact.body.contains("Continuity anchor:"))
        #expect(artifact.body.contains("Context anchor:"))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.notes))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.webResearch))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.reminders))
        #expect(metadata.timingWindow?.contains("transition") == true)
    }

    @Test("Stub weekly reflection returns weekly review artifact")
    func stubWeeklyReflectionReturnsWeeklyReview() throws {
        let client = AdvisoryBridgeClient(
            primaryServer: nil,
            fallbackServer: LocalAdvisoryBridgeStub(),
            mode: .stubOnly
        )

        let result = try client.runRecipe(makeWeeklyReviewRecipeRequest())
        let artifact = try #require(result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(artifact.kind == .weeklyReview)
        #expect(artifact.body.contains("weekly anchor"))
        #expect(artifact.body.contains("return point"))
        #expect(artifact.body.contains("Из заметок"))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.notes))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.webResearch))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.calendar))
        #expect(metadata.patternName == "Continuity kept resurfacing")
        #expect(metadata.timingWindow?.contains("окна") == true)
    }

    @Test("Real sidecar weekly reflection returns weekly review artifact")
    func realSidecarWeeklyReflectionReturnsWeeklyReview() throws {
        let context = try makeSettingsContext(mode: .preferSidecar)
        defer { context.cleanup() }

        let client = AdvisoryBridgeClient(
            settings: context.settings,
            fallbackServer: LocalAdvisoryBridgeStub(),
            sidecarEnvironmentOverrides: [
                "MEMOGRAPH_ADVISOR_FAKE_PROVIDER": "claude"
            ]
        )
        defer { client.stopSidecar() }

        let ready = waitUntil(timeoutSeconds: 5) {
            client.runtimeSnapshot().effectiveStatus == "ready"
        }
        #expect(ready)

        let execution = try client.executeRecipe(makeWeeklyReviewRecipeRequest())
        let artifact = try #require(execution.result.artifactProposals.first)
        let metadata = try #require(AdvisorySupport.decode(AdvisoryArtifactGuidanceMetadata.self, from: artifact.metadataJson))

        #expect(!execution.usedFallback)
        #expect(artifact.kind == .weeklyReview)
        #expect(artifact.body.contains("weekly anchor"))
        #expect(artifact.body.contains("Во внешнем контексте"))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.notes))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.webResearch))
        #expect(metadata.enrichmentSources.contains(AdvisoryEnrichmentSource.calendar))
        #expect(metadata.sourceAnchors.contains(where: { $0.contains("Calendar: Weekly planning") }))
    }
}

private struct StaticHealthBridgeServer: AdvisoryBridgeServerProtocol {
    let bridgeHealth: AdvisoryBridgeHealth

    func health() -> AdvisoryBridgeHealth { bridgeHealth }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
    }

    func cancelRun(runId: String) {}
}

private final class SequenceBridgeServer: AdvisoryBridgeServerProtocol {
    private let healthSequence: [AdvisoryBridgeHealth]
    private let runSequence: [Result<AdvisoryRecipeResult, Error>]
    private var healthIndex = 0
    private var runIndex = 0
    private(set) var runInvocations = 0

    init(
        healthSequence: [AdvisoryBridgeHealth],
        runSequence: [Result<AdvisoryRecipeResult, Error>]
    ) {
        self.healthSequence = healthSequence
        self.runSequence = runSequence
    }

    func health() -> AdvisoryBridgeHealth {
        guard !healthSequence.isEmpty else {
            return makeHealthyBridgeHealth()
        }
        let health = healthSequence[min(healthIndex, healthSequence.count - 1)]
        if healthIndex < healthSequence.count - 1 {
            healthIndex += 1
        }
        return health
    }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        runInvocations += 1
        guard !runSequence.isEmpty else {
            return AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
        }
        let result = runSequence[min(runIndex, runSequence.count - 1)]
        if runIndex < runSequence.count - 1 {
            runIndex += 1
        }
        return try result.get()
    }

    func cancelRun(runId: String) {}
}

private func makeHealthyBridgeHealth(activeProviderName: String? = "claude") -> AdvisoryBridgeHealth {
    AdvisoryBridgeHealth(
        runtimeName: "memograph-advisor",
        status: "ok",
        providerName: "sidecar_jsonrpc_uds",
        transport: "jsonrpc_uds",
        statusDetail: activeProviderName.map { "\($0) selected" },
        activeProviderName: activeProviderName,
        providerOrder: ["claude", "gemini", "codex"],
        availableProviders: activeProviderName.map { [$0] } ?? []
    )
}

private struct AdvisoryBridgeTestSettingsContext {
    let settings: AppSettings
    let cleanup: () -> Void
}

private func makeSettingsContext(mode: AdvisoryBridgeMode) throws -> AdvisoryBridgeTestSettingsContext {
    let suiteName = "AdvisoryBridgeClientTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)

    let socketPath = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("memograph-advisor-\(UUID().uuidString).sock")

    var settings = AppSettings(
        defaults: defaults,
        credentialsStore: NoOpCredentialsStore(),
        legacyCredentialsStore: NoOpCredentialsStore()
    )
    settings.advisoryBridgeMode = mode
    settings.advisorySidecarAutoStart = true
    settings.advisorySidecarSocketPath = socketPath
    settings.advisorySidecarTimeoutSeconds = 5
    settings.advisorySidecarHealthCheckIntervalSeconds = 1
    settings.advisorySidecarMaxConsecutiveFailures = 2
    settings.advisorySidecarRetryAttempts = 2
    settings.advisorySidecarProviderCooldownSeconds = 1

    let normalizedSocketPath = AdvisorySidecarSocketPathResolver.resolve(socketPath)

    return AdvisoryBridgeTestSettingsContext(
        settings: settings,
        cleanup: {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(atPath: socketPath)
            if normalizedSocketPath != socketPath {
                try? FileManager.default.removeItem(atPath: normalizedSocketPath)
            }
        }
    )
}

private func makeRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "continuity_resume",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2",
            kind: .reflection,
            triggerKind: .morningResume,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T08:00:00+08:00",
                end: "2026-04-04T09:15:00+08:00"
            ),
            activeEntities: ["Memograph", "advisory"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-memograph-advisor",
                    title: "Memograph Advisory Sidecar",
                    kind: .project,
                    status: .active,
                    confidence: 0.88,
                    lastActiveAt: "2026-04-04T09:10:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 210,
                    importanceScore: 0.82,
                    summary: "Был начат реальный resilient bridge для advisory sidecar."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-advisor-1",
                    appName: "Xcode",
                    startedAt: "2026-04-04T08:05:00+08:00",
                    endedAt: "2026-04-04T09:00:00+08:00",
                    durationMinutes: 55,
                    windowTitle: "AdvisoryBridgeClient.swift",
                    evidenceSnippet: "Работа над JSON-RPC bridge и lifecycle supervisor."
                )
            ],
            candidateContinuityItems: [
                ReflectionContinuityItemRef(
                    id: "continuity-open-loop",
                    threadId: "thread-memograph-advisor",
                    kind: .openLoop,
                    title: "Проверить real sidecar auto-start и degraded режимы",
                    body: "Нужно прогнать live bridge tests вместо одних static mocks.",
                    confidence: 0.84
                ),
                ReflectionContinuityItemRef(
                    id: "continuity-decision",
                    threadId: "thread-memograph-advisor",
                    kind: .decision,
                    title: "Bridge transport",
                    body: "UDS + JSON-RPC, sidecar process должен быть отдельным.",
                    confidence: 0.79
                )
            ],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-continuity",
                    name: "continuity_pressure",
                    score: 0.81,
                    note: "Есть незакрытый P0 по real bridge lifecycle."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: false,
                enrichmentPhase: .phase1Memograph,
                enabledEnrichmentSources: [.notes],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation", "lesson_learned"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: ["thread:thread-memograph-advisor", "session:session-advisor-1"],
            confidenceHints: ["continuity": 0.82],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: [],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase1Memograph,
                bundles: []
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeEnrichedContinuityRecipeRequest() -> AdvisoryRecipeRequest {
    let request = makeRecipeRequest()
    guard case .reflection(let packet) = request.packet else {
        fatalError("Expected reflection packet for continuity request.")
    }

    let enrichedPacket = ReflectionPacket(
        packetId: packet.packetId,
        packetVersion: packet.packetVersion,
        kind: packet.kind,
        triggerKind: packet.triggerKind,
        timeWindow: packet.timeWindow,
        activeEntities: packet.activeEntities,
        candidateThreadRefs: packet.candidateThreadRefs,
        salientSessions: packet.salientSessions,
        candidateContinuityItems: packet.candidateContinuityItems,
        attentionSignals: packet.attentionSignals,
        constraints: ReflectionPacketConstraints(
            toneMode: packet.constraints.toneMode,
            writingStyle: packet.constraints.writingStyle,
            allowScreenshotEscalation: packet.constraints.allowScreenshotEscalation,
            allowMCPEnrichment: true,
            enrichmentPhase: .phase2ReadOnly,
            enabledEnrichmentSources: [.notes, .calendar, .reminders],
            enabledDomains: packet.constraints.enabledDomains,
            attentionMode: packet.constraints.attentionMode,
            twitterVoiceExamples: packet.constraints.twitterVoiceExamples,
            preferredAngles: packet.constraints.preferredAngles,
            avoidTopics: packet.constraints.avoidTopics,
            contentPersonaDescription: packet.constraints.contentPersonaDescription,
            allowProvocation: packet.constraints.allowProvocation
        ),
        language: packet.language,
        evidenceRefs: packet.evidenceRefs + ["knowledge_note:note-morning-bridge", "calendar_event:adv-standup", "reminder:bridge-smoke-test"],
        confidenceHints: packet.confidenceHints,
        accessLevelGranted: packet.accessLevelGranted,
        allowedTools: packet.allowedTools,
        providerConstraints: packet.providerConstraints,
        enrichment: ReflectionPacketEnrichment(
            phase: .phase2ReadOnly,
            bundles: [
                makeEmbeddedEnrichmentBundle(
                    source: .notes,
                    title: "Morning bridge checklist",
                    snippet: "Keep the sidecar resume entry point short: health, latest failure, one next move.",
                    evidenceRefs: ["knowledge_note:note-morning-bridge"],
                    sourceRef: "knowledge_note:note-morning-bridge"
                ),
                makeEmbeddedEnrichmentBundle(
                    source: .calendar,
                    title: "Advisory standup",
                    snippet: "2026-04-04 09:30 - 10:00 • Quick sidecar review with runtime notes.",
                    evidenceRefs: ["calendar_event:adv-standup"],
                    sourceRef: "calendar_event:adv-standup"
                ),
                makeEmbeddedEnrichmentBundle(
                    source: .reminders,
                    title: "Re-run bridge smoke test",
                    snippet: "Due 2026-04-04 09:20 • Check prefer_sidecar and degraded fallback.",
                    evidenceRefs: ["reminder:bridge-smoke-test"],
                    sourceRef: "reminder:bridge-smoke-test"
                )
            ]
        )
    )

    return AdvisoryRecipeRequest(
        runId: request.runId,
        recipeName: request.recipeName,
        packet: .reflection(enrichedPacket),
        accessLevel: request.accessLevel,
        timeoutSeconds: request.timeoutSeconds
    )
}

private func makeEmbeddedEnrichmentBundle(
    source: AdvisoryEnrichmentSource,
    title: String,
    snippet: String,
    evidenceRefs: [String],
    sourceRef: String,
    relevance: Double = 0.86
) -> ReflectionEnrichmentBundle {
    ReflectionEnrichmentBundle(
        id: source.rawValue,
        source: source,
        tier: .l2Structured,
        availability: .embedded,
        note: "Embedded test enrichment for \(source.rawValue).",
        items: [
            ReflectionEnrichmentItem(
                id: "item-\(AdvisorySupport.slug(for: "\(source.rawValue)-\(title)"))",
                source: source,
                title: title,
                snippet: snippet,
                relevance: relevance,
                evidenceRefs: evidenceRefs,
                sourceRef: sourceRef
            )
        ]
    )
}

private func makeWritingRecipeRequest(
    preferredAngles: [String],
    twitterVoiceExamples: [String],
    avoidTopics: [String],
    allowProvocation: Bool,
    activeEntities: [String] = ["Memograph", "writing"],
    threadTitle: String = "Memograph Writing System"
) -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "writing_seed",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2",
            kind: .reflection,
            triggerKind: .userInvokedWrite,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T10:00:00+08:00",
                end: "2026-04-04T11:00:00+08:00"
            ),
            activeEntities: activeEntities,
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-writing-system",
                    title: threadTitle,
                    kind: .project,
                    status: .active,
                    confidence: 0.84,
                    lastActiveAt: "2026-04-04T10:52:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 230,
                    importanceScore: 0.85,
                    summary: "Нить про persona-aware advisory writing и tweet seeds."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-writing-1",
                    appName: "Codex",
                    startedAt: "2026-04-04T10:00:00+08:00",
                    endedAt: "2026-04-04T10:50:00+08:00",
                    durationMinutes: 50,
                    windowTitle: "WritingSeedComposer.swift",
                    evidenceSnippet: "Работа над persona-aware writing advisory."
                )
            ],
            candidateContinuityItems: [
                ReflectionContinuityItemRef(
                    id: "continuity-writing",
                    threadId: "thread-writing-system",
                    kind: .openLoop,
                    title: "Сделать writing seed менее generic",
                    body: "Нужны angle, evidence pack и alternative angles.",
                    confidence: 0.82
                )
            ],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-expression",
                    name: "expression_pull",
                    score: 0.88,
                    note: "День тянет в writing artifacts."
                ),
                ReflectionAttentionSignal(
                    id: "signal-social",
                    name: "social_pull",
                    score: 0.44,
                    note: "Есть шанс на хороший tweet seed."
                ),
                ReflectionAttentionSignal(
                    id: "signal-thread-density",
                    name: "thread_density",
                    score: 0.78,
                    note: "Нить уже достаточно плотная."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: false,
                enrichmentPhase: .phase1Memograph,
                enabledEnrichmentSources: [.notes],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: twitterVoiceExamples,
                preferredAngles: preferredAngles,
                avoidTopics: avoidTopics,
                contentPersonaDescription: "Grounded builder voice. Sharp, compact, evidence-led.",
                allowProvocation: allowProvocation
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-writing-system",
                "session:session-writing-1",
                "summary:2026-04-04"
            ],
            confidenceHints: ["writing": 0.86],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: [],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase1Memograph,
                bundles: []
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeResearchRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "research_direction",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: .sessionEnd,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T12:00:00+08:00",
                end: "2026-04-04T12:40:00+08:00"
            ),
            activeEntities: ["Memograph", "continuity"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-continuity",
                    title: "Memograph Continuity",
                    kind: .project,
                    status: .active,
                    confidence: 0.81,
                    lastActiveAt: "2026-04-04T12:35:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 185,
                    importanceScore: 0.83,
                    summary: "Cross-day continuity and resume flow."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-research-1",
                    appName: "Codex",
                    startedAt: "2026-04-04T12:00:00+08:00",
                    endedAt: "2026-04-04T12:35:00+08:00",
                    durationMinutes: 35,
                    windowTitle: "AdvisoryEnrichmentContextBuilder.swift",
                    evidenceSnippet: "Building phase-aware notes enrichment for advisory packets."
                )
            ],
            candidateContinuityItems: [],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-research",
                    name: "research_pull",
                    score: 0.74,
                    note: "There is enough research pull to justify a direction."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: true,
                enrichmentPhase: .phase2ReadOnly,
                enabledEnrichmentSources: [.notes, .calendar, .reminders, .webResearch],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-continuity",
                "session:session-research-1",
                "knowledge_note:note-continuity"
            ],
            confidenceHints: ["research": 0.74],
            accessLevelGranted: .deepContext,
            allowedTools: ["knowledge.lookup"],
            providerConstraints: ["mcp_optional"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase2ReadOnly,
                bundles: [
                    ReflectionEnrichmentBundle(
                        id: "notes",
                        source: .notes,
                        tier: .l2Structured,
                        availability: .embedded,
                        note: "Memograph-derived note fragments attached as L2 structured context.",
                        items: [
                            ReflectionEnrichmentItem(
                                id: "note-item-1",
                                source: .notes,
                                title: "Memograph Continuity Note",
                                snippet: "Resume Me works better when threads keep a clear return point across days.",
                                relevance: 0.88,
                                evidenceRefs: ["knowledge_note:note-continuity"],
                                sourceRef: "knowledge_note:note-continuity"
                            )
                        ]
                    ),
                    ReflectionEnrichmentBundle(
                        id: "calendar",
                        source: .calendar,
                        tier: .l2Structured,
                        availability: .unavailable,
                        note: "Connector scaffold exists, but this enricher is not wired in Memograph core yet.",
                        items: []
                    )
                ]
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeExplorationResearchRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "research_direction",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: .sessionEnd,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T12:40:00+08:00",
                end: "2026-04-04T13:10:00+08:00"
            ),
            activeEntities: ["attention market"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-attention-market",
                    title: "Memograph Attention Market",
                    kind: .project,
                    status: .active,
                    confidence: 0.83,
                    lastActiveAt: "2026-04-04T13:05:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 160,
                    importanceScore: 0.79,
                    summary: "Нить про domain budgets и ambient advisory pacing."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-exploration-1",
                    appName: "Codex",
                    startedAt: "2026-04-04T12:40:00+08:00",
                    endedAt: "2026-04-04T13:05:00+08:00",
                    durationMinutes: 25,
                    windowTitle: "AttentionGovernor.swift",
                    evidenceSnippet: "Смотрю, как доменные бюджеты влияют на advisory pacing."
                )
            ],
            candidateContinuityItems: [],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-research-exploration",
                    name: "research_pull",
                    score: 0.82,
                    note: "Research pull is high even without embedded notes."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: false,
                enrichmentPhase: .phase1Memograph,
                enabledEnrichmentSources: [],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-attention-market",
                "session:session-exploration-1",
                "summary:2026-04-04"
            ],
            confidenceHints: ["research": 0.82],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase1Memograph,
                bundles: []
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeWebGroundedResearchRecipeRequest() -> AdvisoryRecipeRequest {
    let request = makeExplorationResearchRecipeRequest()
    guard case .reflection(let packet) = request.packet else {
        fatalError("Expected reflection packet for research request.")
    }

    let enrichedPacket = ReflectionPacket(
        packetId: packet.packetId,
        packetVersion: packet.packetVersion,
        kind: packet.kind,
        triggerKind: packet.triggerKind,
        timeWindow: packet.timeWindow,
        activeEntities: ["attention market", "continuity"],
        candidateThreadRefs: packet.candidateThreadRefs,
        salientSessions: packet.salientSessions,
        candidateContinuityItems: packet.candidateContinuityItems,
        attentionSignals: packet.attentionSignals,
        constraints: ReflectionPacketConstraints(
            toneMode: packet.constraints.toneMode,
            writingStyle: packet.constraints.writingStyle,
            allowScreenshotEscalation: packet.constraints.allowScreenshotEscalation,
            allowMCPEnrichment: true,
            enrichmentPhase: .phase2ReadOnly,
            enabledEnrichmentSources: [.calendar, .webResearch],
            enabledDomains: packet.constraints.enabledDomains,
            attentionMode: packet.constraints.attentionMode,
            twitterVoiceExamples: packet.constraints.twitterVoiceExamples,
            preferredAngles: packet.constraints.preferredAngles,
            avoidTopics: packet.constraints.avoidTopics,
            contentPersonaDescription: packet.constraints.contentPersonaDescription,
            allowProvocation: packet.constraints.allowProvocation
        ),
        language: packet.language,
        evidenceRefs: packet.evidenceRefs + ["context_snapshot:web-attention-market", "calendar_event:research-block"],
        confidenceHints: packet.confidenceHints,
        accessLevelGranted: packet.accessLevelGranted,
        allowedTools: packet.allowedTools,
        providerConstraints: packet.providerConstraints,
        enrichment: ReflectionPacketEnrichment(
            phase: .phase2ReadOnly,
            bundles: [
                makeEmbeddedEnrichmentBundle(
                    source: .webResearch,
                    title: "Attention market explainer",
                    snippet: "Arc • Contrasting attention allocation models across categories and timing fit.",
                    evidenceRefs: ["context_snapshot:web-attention-market"],
                    sourceRef: "context_snapshot:web-attention-market"
                ),
                makeEmbeddedEnrichmentBundle(
                    source: .calendar,
                    title: "Research block",
                    snippet: "2026-04-04 14:00 - 14:45 • Quiet time reserved for packet experiments.",
                    evidenceRefs: ["calendar_event:research-block"],
                    sourceRef: "calendar_event:research-block"
                )
            ]
        )
    )

    return AdvisoryRecipeRequest(
        runId: request.runId,
        recipeName: request.recipeName,
        packet: .reflection(enrichedPacket),
        accessLevel: request.accessLevel,
        timeoutSeconds: request.timeoutSeconds
    )
}

private func makeFocusRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "focus_reflection",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: .focusBreakNatural,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T15:00:00+08:00",
                end: "2026-04-04T15:30:00+08:00"
            ),
            activeEntities: ["Memograph", "focus"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-focus",
                    title: "Focus-aware advisory timing",
                    kind: .theme,
                    status: .active,
                    confidence: 0.78,
                    lastActiveAt: "2026-04-04T15:28:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 110,
                    importanceScore: 0.73,
                    summary: "Нить про deep_work suppression и fragmented recovery."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-focus-1",
                    appName: "Codex",
                    startedAt: "2026-04-04T15:00:00+08:00",
                    endedAt: "2026-04-04T15:25:00+08:00",
                    durationMinutes: 25,
                    windowTitle: "AttentionTimingPolicy.swift",
                    evidenceSnippet: "Смотрю, как fragmented state должен менять surfacing."
                )
            ],
            candidateContinuityItems: [],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-focus-turbulence",
                    name: "focus_turbulence",
                    score: 0.76,
                    note: "Focus turbulence is high."
                ),
                ReflectionAttentionSignal(
                    id: "signal-fragmentation",
                    name: "fragmentation",
                    score: 0.62,
                    note: "Fragmentation is high enough for intervention."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: false,
                enrichmentPhase: .phase1Memograph,
                enabledEnrichmentSources: [],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-focus",
                "session:session-focus-1",
                "summary:2026-04-04"
            ],
            confidenceHints: ["focus": 0.76],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase1Memograph,
                bundles: []
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeLowSignalManualFocusRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "focus_reflection",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: .userInvokedWrite,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T15:30:00+08:00",
                end: "2026-04-04T15:50:00+08:00"
            ),
            activeEntities: ["Memograph", "focus"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-focus-manual",
                    title: "Manual focus check",
                    kind: .theme,
                    status: .active,
                    confidence: 0.72,
                    lastActiveAt: "2026-04-04T15:48:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 75,
                    importanceScore: 0.66,
                    summary: "Нить про мягкий ручной focus pull."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-focus-manual-1",
                    appName: "Codex",
                    startedAt: "2026-04-04T15:30:00+08:00",
                    endedAt: "2026-04-04T15:48:00+08:00",
                    durationMinutes: 18,
                    windowTitle: "TimelineView.swift",
                    evidenceSnippet: "Manual focus check from timeline."
                )
            ],
            candidateContinuityItems: [],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-focus-turbulence-low",
                    name: "focus_turbulence",
                    score: 0.25,
                    note: "Below ambient threshold, but manual pull should still allow a soft check."
                ),
                ReflectionAttentionSignal(
                    id: "signal-fragmentation-low",
                    name: "fragmentation",
                    score: 0.57,
                    note: "Fragmentation is still visible."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: true,
                enrichmentPhase: .phase3Expanded,
                enabledEnrichmentSources: [.wearable, .reminders],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-focus-manual",
                "session:session-focus-manual-1",
                "wearable:fragmented-manual"
            ],
            confidenceHints: ["focus": 0.25],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase3Expanded,
                bundles: [
                    makeEmbeddedEnrichmentBundle(
                        source: .wearable,
                        title: "Fragmented work blocks",
                        snippet: "5 short sessions across 4 apps. Re-entry cost likely rising.",
                        evidenceRefs: ["wearable:fragmented-manual"],
                        sourceRef: "wearable:fragmented-manual"
                    ),
                    makeEmbeddedEnrichmentBundle(
                        source: .reminders,
                        title: "Reset before next call",
                        snippet: "Due 2026-04-04 16:00 • Leave one clean return point.",
                        evidenceRefs: ["reminder:focus-reset"],
                        sourceRef: "reminder:focus-reset"
                    )
                ]
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeHealthRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "health_pulse",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: .userInvokedWrite,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T20:00:00+08:00",
                end: "2026-04-04T22:10:00+08:00"
            ),
            activeEntities: ["health", "rhythm"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-health-rhythm",
                    title: "Day rhythm",
                    kind: .theme,
                    status: .active,
                    confidence: 0.74,
                    lastActiveAt: "2026-04-04T22:05:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 90,
                    importanceScore: 0.61,
                    summary: "Нить про перегруженный ритм дня."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-health-1",
                    appName: "Codex",
                    startedAt: "2026-04-04T20:30:00+08:00",
                    endedAt: "2026-04-04T22:05:00+08:00",
                    durationMinutes: 95,
                    windowTitle: "AdvisoryHealthMonitor.swift",
                    evidenceSnippet: "Wrapping late with advisory runtime changes."
                )
            ],
            candidateContinuityItems: [],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-health-pressure",
                    name: "health_pressure",
                    score: 0.44,
                    note: "Health pressure is above the explicit pulse threshold."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: true,
                enrichmentPhase: .phase3Expanded,
                enabledEnrichmentSources: [.wearable, .calendar],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-health-rhythm",
                "session:session-health-1",
                "wearable:late-work-stretch"
            ],
            confidenceHints: ["health": 0.44],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase3Expanded,
                bundles: [
                    makeEmbeddedEnrichmentBundle(
                        source: .wearable,
                        title: "High cognitive load window",
                        snippet: "Total active time 230 min, longest stretch 95 min.",
                        evidenceRefs: ["wearable:late-work-stretch"],
                        sourceRef: "wearable:late-work-stretch"
                    ),
                    makeEmbeddedEnrichmentBundle(
                        source: .calendar,
                        title: "Evening wrap-up",
                        snippet: "2026-04-04 22:15 - 22:30 • Leave a return point and stop cleanly.",
                        evidenceRefs: ["calendar:evening-wrap"],
                        sourceRef: "calendar:evening-wrap"
                    )
                ]
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeSocialRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "social_signal",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: .sessionEnd,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T18:10:00+08:00",
                end: "2026-04-04T18:40:00+08:00"
            ),
            activeEntities: ["attention market", "social"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-social-signal",
                    title: "Attention market writing",
                    kind: .theme,
                    status: .active,
                    confidence: 0.79,
                    lastActiveAt: "2026-04-04T18:35:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 95,
                    importanceScore: 0.71,
                    summary: "Нить про то, как advisory candidates конкурируют за внимание."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-social-1",
                    appName: "Arc",
                    startedAt: "2026-04-04T18:10:00+08:00",
                    endedAt: "2026-04-04T18:35:00+08:00",
                    durationMinutes: 25,
                    windowTitle: "Attention market explainer",
                    evidenceSnippet: "Looking at examples of category-aware attention allocation."
                )
            ],
            candidateContinuityItems: [],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-social-pull",
                    name: "social_pull",
                    score: 0.72,
                    note: "There is enough grounded social pull."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: true,
                enrichmentPhase: .phase2ReadOnly,
                enabledEnrichmentSources: [.webResearch, .reminders],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation", "question"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-social-signal",
                "session:session-social-1",
                "context_snapshot:web-social-1",
                "reminder:social-follow-up"
            ],
            confidenceHints: ["social": 0.72],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase2ReadOnly,
                bundles: [
                    makeEmbeddedEnrichmentBundle(
                        source: .webResearch,
                        title: "Attention market explainer",
                        snippet: "Arc • Examples of multi-polar ranking and attention budgets.",
                        evidenceRefs: ["context_snapshot:web-social-1"],
                        sourceRef: "context_snapshot:web-social-1"
                    ),
                    makeEmbeddedEnrichmentBundle(
                        source: .reminders,
                        title: "Send note to Nikita",
                        snippet: "Due 2026-04-04 19:00 • Share the attention market draft when it feels clean.",
                        evidenceRefs: ["reminder:social-follow-up"],
                        sourceRef: "reminder:social-follow-up"
                    )
                ]
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeDecisionRecipeRequest(
    includeExplicitDecision: Bool,
    includeReminderAnchor: Bool = false
) -> AdvisoryRecipeRequest {
    let continuityItems: [ReflectionContinuityItemRef] = includeExplicitDecision ? [
        ReflectionContinuityItemRef(
            id: "decision-item",
            threadId: "thread-decisions",
            kind: .decision,
            title: "Decision about packet escalation",
            body: "Оставляем packet-first и делаем controlled escalation.",
            confidence: 0.8
        )
    ] : []

    return AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "decision_review",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: .sessionEnd,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T16:00:00+08:00",
                end: "2026-04-04T16:45:00+08:00"
            ),
            activeEntities: ["Memograph", "decisions"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-decisions",
                    title: "Advisory decision history",
                    kind: .project,
                    status: .active,
                    confidence: 0.82,
                    lastActiveAt: "2026-04-04T16:40:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 140,
                    importanceScore: 0.77,
                    summary: "Нить про explicit decision capture и missed signals."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-decision-1",
                    appName: "Codex",
                    startedAt: "2026-04-04T16:00:00+08:00",
                    endedAt: "2026-04-04T16:40:00+08:00",
                    durationMinutes: 40,
                    windowTitle: "DecisionHistorian.swift",
                    evidenceSnippet: "Пытаюсь не терять implicit choices по advisory system."
                )
            ],
            candidateContinuityItems: continuityItems,
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-decision-density",
                    name: "decision_density",
                    score: 0.68,
                    note: "Decision density is high enough to justify a reminder."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: false,
                enrichmentPhase: .phase1Memograph,
                enabledEnrichmentSources: [],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-decisions",
                "session:session-decision-1",
                "summary:2026-04-04"
            ] + (includeReminderAnchor ? ["reminder:decision-follow-up"] : []),
            confidenceHints: ["decisions": 0.68],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: includeReminderAnchor ? .phase2ReadOnly : .phase1Memograph,
                bundles: includeReminderAnchor ? [
                    makeEmbeddedEnrichmentBundle(
                        source: .reminders,
                        title: "Confirm packet escalation rule",
                        snippet: "Due 2026-04-04 17:15 • Decide whether reminder-based escalation stays soft.",
                        evidenceRefs: ["reminder:decision-follow-up"],
                        sourceRef: "reminder:decision-follow-up"
                    )
                ] : []
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeLifeAdminRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "life_admin_review",
        packet: .reflection(ReflectionPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.reflection.3",
            kind: .reflection,
            triggerKind: .sessionEnd,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T19:10:00+08:00",
                end: "2026-04-04T19:25:00+08:00"
            ),
            activeEntities: ["finance", "admin"],
            candidateThreadRefs: [
                ReflectionThreadRef(
                    id: "thread-admin-tail",
                    title: "Life admin tails",
                    kind: .commitment,
                    status: .active,
                    confidence: 0.7,
                    lastActiveAt: "2026-04-04T19:20:00+08:00",
                    parentThreadId: nil,
                    totalActiveMinutes: 40,
                    importanceScore: 0.56,
                    summary: "Нить про тихие admin хвосты, которые лучше парковать явно."
                )
            ],
            salientSessions: [
                ReflectionSalientSession(
                    id: "session-admin-1",
                    appName: "Reminders",
                    startedAt: "2026-04-04T19:10:00+08:00",
                    endedAt: "2026-04-04T19:18:00+08:00",
                    durationMinutes: 8,
                    windowTitle: "Invoices",
                    evidenceSnippet: "Saw the invoice tail again while wrapping up the day."
                )
            ],
            candidateContinuityItems: [],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "signal-life-admin",
                    name: "life_admin_pressure",
                    score: 0.64,
                    note: "There is a visible admin tail worth parking."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: true,
                enrichmentPhase: .phase2ReadOnly,
                enabledEnrichmentSources: [.reminders],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-admin-tail",
                "session:session-admin-1",
                "reminder:admin-invoice"
            ],
            confidenceHints: ["life_admin": 0.64],
            accessLevelGranted: .deepContext,
            allowedTools: [],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase2ReadOnly,
                bundles: [
                    makeEmbeddedEnrichmentBundle(
                        source: .reminders,
                        title: "Pay contractor invoice",
                        snippet: "Due 2026-04-04 20:00 • Close the invoice before tomorrow morning.",
                        evidenceRefs: ["reminder:admin-invoice"],
                        sourceRef: "reminder:admin-invoice"
                    )
                ]
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeThreadWritingRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "tweet_from_thread",
        packet: .thread(ThreadPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.thread.1",
            kind: .thread,
            triggerKind: .userInvokedWrite,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-04-04",
                start: "2026-04-04T13:00:00+08:00",
                end: "2026-04-04T13:45:00+08:00"
            ),
            thread: ReflectionThreadRef(
                id: "thread-deep-thread",
                title: "Memograph Advisory Market",
                kind: .project,
                status: .active,
                confidence: 0.87,
                lastActiveAt: "2026-04-04T13:40:00+08:00",
                parentThreadId: nil,
                totalActiveMinutes: 240,
                importanceScore: 0.86,
                summary: "Нить про attention market, weekly review и thread-level writing signals."
            ),
            recentEvidence: [
                ThreadPacketEvidence(
                    id: "thread-evidence-1",
                    evidenceKind: "session",
                    evidenceRef: "session:session-thread-1",
                    snippet: "Designing thread and weekly packet flows.",
                    weight: 0.84
                )
            ],
            linkedItems: [
                ReflectionContinuityItemRef(
                    id: "thread-open-loop",
                    threadId: "thread-deep-thread",
                    kind: .openLoop,
                    title: "Закрыть packet-kind-aware routing",
                    body: "Нужно протянуть thread packet через stub и sidecar.",
                    confidence: 0.81
                )
            ],
            continuityState: ThreadPacketContinuityState(
                openItemCount: 1,
                parkedItemCount: 0,
                resolvedItemCount: 0,
                suggestedEntryPoint: "Открыть ThreadPacketBuilder.swift и довести routing до конца.",
                latestArtifactTitle: "Собрать writing seed"
            ),
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "thread-expression",
                    name: "expression_pull",
                    score: 0.82,
                    note: "Нить уже достаточно плотная для writing output."
                ),
                ReflectionAttentionSignal(
                    id: "thread-density",
                    name: "thread_density",
                    score: 0.8,
                    note: "Нить выглядит устойчивой."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: true,
                enrichmentPhase: .phase2ReadOnly,
                enabledEnrichmentSources: [.notes, .webResearch, .reminders],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: ["Short grounded post"],
                preferredAngles: ["lesson_learned", "mini_framework"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice. Sharp, compact, evidence-led.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-deep-thread",
                "session:session-thread-1"
            ],
            confidenceHints: [
                "thread:thread-deep-thread": 0.87,
                "expression": 0.82
            ],
            accessLevelGranted: .deepContext,
            allowedTools: ["timeline.search"],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase2ReadOnly,
                bundles: [
                    makeEmbeddedEnrichmentBundle(
                        source: .notes,
                        title: "Thread notes scratchpad",
                        snippet: "Weekly and thread packet flows need packet-specific enrichment routing.",
                        evidenceRefs: ["knowledge_note:thread-notes"],
                        sourceRef: "knowledge_note:thread-notes"
                    ),
                    makeEmbeddedEnrichmentBundle(
                        source: .webResearch,
                        title: "Attention market explainer",
                        snippet: "Category-aware attention markets work better than single-ranker queues.",
                        evidenceRefs: ["web_research:attention-market"],
                        sourceRef: "web_research:attention-market"
                    ),
                    makeEmbeddedEnrichmentBundle(
                        source: .reminders,
                        title: "Ship thread packet routing",
                        snippet: "Close thread packet routing before tomorrow's review.",
                        evidenceRefs: ["reminder:thread-routing"],
                        sourceRef: "reminder:thread-routing"
                    )
                ]
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private func makeWeeklyReviewRecipeRequest() -> AdvisoryRecipeRequest {
    AdvisoryRecipeRequest(
        runId: "run-\(UUID().uuidString)",
        recipeName: "weekly_reflection",
        packet: .weekly(WeeklyPacket(
            packetId: "packet-\(UUID().uuidString)",
            packetVersion: "v2.weekly.1",
            kind: .weekly,
            triggerKind: .weeklyReview,
            timeWindow: ReflectionPacketTimeWindow(
                localDate: "2026-03-30",
                start: "2026-03-30T00:00:00+08:00",
                end: "2026-04-05T23:59:59+08:00"
            ),
            threadRollup: [
                WeeklyThreadRollup(
                    id: "thread-weekly-1",
                    title: "Memograph Advisory Sidecar",
                    status: .active,
                    importanceScore: 0.88,
                    totalActiveMinutes: 320,
                    summary: "Неделю держала нить про sidecar, packets и weekly review.",
                    openItemCount: 2,
                    artifactCount: 3
                ),
                WeeklyThreadRollup(
                    id: "thread-weekly-2",
                    title: "Audio queue health",
                    status: .stalled,
                    importanceScore: 0.64,
                    totalActiveMinutes: 90,
                    summary: "Вторая нить про audio throttling и backlog health.",
                    openItemCount: 1,
                    artifactCount: 1
                )
            ],
            patterns: [
                WeeklyPattern(
                    id: "pattern-1",
                    title: "Continuity kept resurfacing",
                    summary: "Несколько нитей возвращались через разные дни, и weekly synthesis уже grounded.",
                    confidence: 0.79
                )
            ],
            continuityItems: [
                ReflectionContinuityItemRef(
                    id: "weekly-loop-1",
                    threadId: "thread-weekly-1",
                    kind: .openLoop,
                    title: "Добить weekly review flow",
                    body: nil,
                    confidence: 0.76
                )
            ],
            attentionSignals: [
                ReflectionAttentionSignal(
                    id: "weekly-continuity",
                    name: "continuity_pressure",
                    score: 0.78,
                    note: "Week-level continuity pressure is visible."
                ),
                ReflectionAttentionSignal(
                    id: "weekly-thread-density",
                    name: "thread_density",
                    score: 0.74,
                    note: "Несколько нитей тянули неделю."
                )
            ],
            constraints: ReflectionPacketConstraints(
                toneMode: "soft_optional",
                writingStyle: "grounded",
                allowScreenshotEscalation: false,
                allowMCPEnrichment: true,
                enrichmentPhase: .phase2ReadOnly,
                enabledEnrichmentSources: [.notes, .calendar, .webResearch],
                enabledDomains: AdvisoryDomain.allCases,
                attentionMode: "ambient",
                twitterVoiceExamples: [],
                preferredAngles: ["observation"],
                avoidTopics: [],
                contentPersonaDescription: "Grounded builder voice.",
                allowProvocation: false
            ),
            language: "ru",
            evidenceRefs: [
                "thread:thread-weekly-1",
                "thread:thread-weekly-2",
                "continuity:weekly-loop-1"
            ],
            confidenceHints: [
                "thread:thread-weekly-1": 0.88
            ],
            accessLevelGranted: .deepContext,
            allowedTools: ["timeline.search"],
            providerConstraints: ["external_cli_remote_allowed"],
            enrichment: ReflectionPacketEnrichment(
                phase: .phase2ReadOnly,
                bundles: [
                    makeEmbeddedEnrichmentBundle(
                        source: .notes,
                        title: "Weekly synthesis note",
                        snippet: "Weekly review works best when the main thread and return point stay visible together.",
                        evidenceRefs: ["knowledge_note:weekly-synthesis"],
                        sourceRef: "knowledge_note:weekly-synthesis"
                    ),
                    makeEmbeddedEnrichmentBundle(
                        source: .webResearch,
                        title: "Weekly review framing",
                        snippet: "A weekly anchor should reduce Monday re-entry cost rather than summarize everything.",
                        evidenceRefs: ["web_research:weekly-framing"],
                        sourceRef: "web_research:weekly-framing"
                    ),
                    makeEmbeddedEnrichmentBundle(
                        source: .calendar,
                        title: "Weekly planning",
                        snippet: "Monday planning block at 09:00 local time.",
                        evidenceRefs: ["calendar:weekly-planning"],
                        sourceRef: "calendar:weekly-planning"
                    )
                ]
            )
        )),
        accessLevel: .deepContext,
        timeoutSeconds: 5
    )
}

private final class RecordingAuthCheckBridgeServer: AdvisoryBridgeServerProtocol {
    private(set) var authCheckCallCount = 0
    private(set) var healthCallCount = 0
    private(set) var refreshHealthCallCount = 0
    private(set) var lastAuthCheckProviderName: String?
    private(set) var lastAuthCheckAccountName: String?
    private(set) var lastAuthCheckForceRefresh = false

    func health() -> AdvisoryBridgeHealth {
        healthCallCount += 1
        return AdvisoryBridgeHealth(
            runtimeName: "memograph-advisor",
            status: "ok",
            providerName: "sidecar_jsonrpc_uds",
            transport: "jsonrpc_uds",
            statusDetail: "claude ready",
            activeProviderName: "claude",
            providerStatuses: [
                AdvisoryProviderDiagnostic(
                    providerName: "claude",
                    status: "ok",
                    detail: "claude ready",
                    binaryPresent: true,
                    sessionDetected: true,
                    priority: 0
                )
            ]
        )
    }

    func refreshHealth() -> AdvisoryBridgeHealth {
        refreshHealthCallCount += 1
        return health()
    }

    func authCheck(providerName: String, accountName: String?, forceRefresh: Bool) throws -> AdvisoryProviderAuthCheckResponse {
        authCheckCallCount += 1
        lastAuthCheckProviderName = providerName
        lastAuthCheckAccountName = accountName
        lastAuthCheckForceRefresh = forceRefresh
        return AdvisoryProviderAuthCheckResponse(
            providerName: providerName,
            accountName: accountName,
            verified: accountName == "acc2",
            status: accountName == "acc2" ? "ok" : "session_missing",
            detail: accountName == "acc2" ? "Account acc2 verified." : "Account not ready.",
            checkedAt: "2026-04-05T08:30:00Z"
        )
    }

    func runRecipe(_ request: AdvisoryRecipeRequest) throws -> AdvisoryRecipeResult {
        AdvisoryRecipeResult(runId: request.runId, artifactProposals: [], continuityProposals: [])
    }

    func cancelRun(runId: String) {}
}

private final class StallingUnixSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let listenFD: Int32
    private let acceptQueue = DispatchQueue(label: "memograph.tests.uds.accept")
    private let acceptedSemaphore = DispatchSemaphore(value: 0)
    private let stopSemaphore = DispatchSemaphore(value: 0)
    private var acceptedFD: Int32 = -1
    private let lock = NSLock()
    private var stopped = false

    init(socketPath: String) throws {
        self.socketPath = socketPath
        try? FileManager.default.removeItem(atPath: socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        try socketPath.withCString { pathPointer in
            let pathLength = strlen(pathPointer)
            let maxLength = MemoryLayout.size(ofValue: address.sun_path)
            guard pathLength < maxLength else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: [NSLocalizedDescriptionKey: "Socket path too long."])
            }
            withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
                rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
                memcpy(rawBuffer.baseAddress, pathPointer, pathLength)
            }
        }

        var addressCopy = address
        let bindResult = withUnsafePointer(to: &addressCopy) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = String(cString: strerror(errno))
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: error])
        }

        guard listen(fd, 1) == 0 else {
            let error = String(cString: strerror(errno))
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: error])
        }

        self.listenFD = fd

        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func waitUntilAccepted(timeoutSeconds: TimeInterval) -> Bool {
        acceptedSemaphore.wait(timeout: .now() + timeoutSeconds) == .success
    }

    func stop() {
        lock.lock()
        if stopped {
            lock.unlock()
            return
        }
        stopped = true
        let acceptedFD = self.acceptedFD
        self.acceptedFD = -1
        lock.unlock()

        if acceptedFD >= 0 {
            close(acceptedFD)
        }
        close(listenFD)
        try? FileManager.default.removeItem(atPath: socketPath)
        stopSemaphore.signal()
    }

    private func acceptLoop() {
        var clientAddress = sockaddr()
        var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
        let fd = accept(listenFD, &clientAddress, &clientLength)
        if fd < 0 {
            acceptedSemaphore.signal()
            return
        }

        lock.lock()
        acceptedFD = fd
        lock.unlock()
        acceptedSemaphore.signal()
        _ = stopSemaphore.wait(timeout: .distantFuture)
        close(fd)
    }
}

private func temporarySocketPath() -> String {
    "/tmp/memograph-advisor-\(UUID().uuidString).sock"
}

private final class ExternalSidecarHandle {
    let socketPath: String
    let pidfilePath: String
    private let process: Process

    init(socketPath: String, environment: [String: String]) throws {
        self.socketPath = socketPath
        self.pidfilePath = socketPath + ".pid"

        guard case let .ready(runtime) = AdvisorySidecarRuntimeResolver.resolve() else {
            throw NSError(
                domain: "AdvisoryBridgeClientTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Python runtime for memograph-advisor is unavailable."]
            )
        }

        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidfilePath)

        let process = Process()
        process.executableURL = runtime.executableURL
        process.arguments = runtime.launchArgumentsPrefix + [
            runtime.scriptPath,
            "--socket",
            socketPath,
            "--probe-timeout-seconds",
            "1"
        ]
        process.environment = ProcessInfo.processInfo.environment
            .merging(runtime.baseEnvironment) { _, new in new }
            .merging(environment) { _, new in new }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process

        let ready = waitUntil(timeoutSeconds: 5) {
            FileManager.default.fileExists(atPath: socketPath) && readLivePID(from: self.pidfilePath) != nil
        }
        guard ready else {
            cleanup()
            throw NSError(
                domain: "AdvisoryBridgeClientTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Externally launched sidecar did not become ready in time."]
            )
        }
    }

    var pid: pid_t? {
        readLivePID(from: pidfilePath)
    }

    func cleanup() {
        if process.isRunning {
            process.terminate()
            _ = waitUntil(timeoutSeconds: 2) {
                !process.isRunning
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: pidfilePath)
    }
}

private func makeAdvisoryProfilesFixture(provider: String, accountName: String) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("advisory-profiles-\(UUID().uuidString)", isDirectory: true)
    let providerRoot = root.appendingPathComponent(provider, isDirectory: true)
    let accountRoot = providerRoot.appendingPathComponent(accountName, isDirectory: true)
    let homeRoot = accountRoot.appendingPathComponent("home", isDirectory: true)
    let claudeRoot = homeRoot.appendingPathComponent(".claude", isDirectory: true)

    try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
    let credentialsURL = claudeRoot.appendingPathComponent(".credentials.json")
    try #"{"claudeAiOauth":{"email":"person@example.com"}}"#.write(to: credentialsURL, atomically: true, encoding: .utf8)
    return root
}

private func makeStaleUnixSocketFile(at path: String) throws {
    try? FileManager.default.removeItem(atPath: path)

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    try path.withCString { pathPointer in
        let pathLength = strlen(pathPointer)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard pathLength < maxLength else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: [NSLocalizedDescriptionKey: "Socket path too long."])
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
            memcpy(rawBuffer.baseAddress, pathPointer, pathLength)
        }
    }

    var addressCopy = address
    let bindResult = withUnsafePointer(to: &addressCopy) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bindResult == 0 else {
        let error = String(cString: strerror(errno))
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: error])
    }

    guard listen(fd, 1) == 0 else {
        let error = String(cString: strerror(errno))
        close(fd)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: error])
    }

    close(fd)
}

private func waitUntil(timeoutSeconds: TimeInterval, check: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if check() {
            return true
        }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return check()
}

private func readLivePID(from pidfilePath: String) -> pid_t? {
    guard
        let pidString = try? String(contentsOfFile: pidfilePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
        let pid = readPID(fromPidfileContents: pidString),
        pid > 0,
        processIsAlive(pid)
    else {
        return nil
    }
    return pid
}

private func processIsAlive(_ pid: pid_t) -> Bool {
    Darwin.kill(pid, 0) == 0 || errno == EPERM
}

private func readPID(fromPidfileContents contents: String) -> pid_t? {
    if let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
        return pid
    }
    guard
        let data = contents.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let pid = object["pid"] as? Int
    else {
        return nil
    }
    return Int32(pid)
}
