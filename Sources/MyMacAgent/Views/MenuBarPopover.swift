import SwiftUI

struct MenuBarPopover: View {
    @ObservedObject var permissionsManager: PermissionsManager
    let db: DatabaseManager?
    let onOpenTimeline: (() -> Void)?
    let onOpenSettings: (() -> Void)?
    let onOpenAccounts: (() -> Void)?
    @ObservedObject private var audioHealthMonitor = AudioHealthMonitor.shared
    @ObservedObject private var advisoryHealthMonitor = AdvisoryHealthMonitor.shared
    @State private var isPaused = false
    @State private var resumeArtifact: AdvisoryArtifactRecord?
    @State private var resumeThread: AdvisoryThreadRecord?
    @State private var resumeSurfaceLoading = false
    @State private var resumeSurfaceLoadedAt: Date?
    @State private var resumeSurfaceToken = UUID()

    private enum RuntimeStatus {
        case paused
        case running
        case limited([String])

        var title: String {
            switch self {
            case .paused:
                return "Paused"
            case .running:
                return "Running"
            case .limited(let reasons):
                return reasons.count == 1 ? "Limited" : "Needs Setup"
            }
        }

        var icon: String {
            switch self {
            case .paused:
                return "pause.circle.fill"
            case .running:
                return "checkmark.circle.fill"
            case .limited:
                return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .paused:
                return .orange
            case .running:
                return .green
            case .limited:
                return .yellow
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MemographGlyph()
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Memograph")
                        .font(.headline)

                    Label(runtimeStatus.title, systemImage: runtimeStatus.icon)
                        .foregroundStyle(runtimeStatus.tint)
                        .font(.caption)
                }
            }

            if case .limited(let reasons) = runtimeStatus {
                Text(reasons.joined(separator: " + "))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if !permissionsManager.screenRecordingGranted {
                        Button("Enable Screen") {
                            permissionsManager.openScreenRecordingSettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if !permissionsManager.accessibilityGranted {
                        Button("Enable AX") {
                            permissionsManager.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if !audioHealthMonitor.snapshot.statusLines.isEmpty,
               (audioHealthMonitor.snapshot.pendingJobs > 0
                || audioHealthMonitor.snapshot.cloudTranscriptionDelayed
                || audioHealthMonitor.snapshot.systemAudioThrottled) {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(audioHealthMonitor.snapshot.statusLines.prefix(3), id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if advisoryHealthMonitor.snapshot.isDegraded {
                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text(advisoryHealthMonitor.snapshot.statusTitle)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(advisoryHealthMonitor.snapshot.statusLines.prefix(2), id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    AdvisoryProviderDiagnosticsView(
                        providerStatuses: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.providerStatuses,
                        activeProviderName: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.activeProviderName,
                        checkedAt: advisoryHealthMonitor.snapshot.runtimeSnapshot.bridgeHealth.checkedAt,
                        compact: true
                    )
                    Button("Accounts & Sessions") {
                        openAccounts()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let resumeArtifact {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Resume Me")
                        .font(.caption.weight(.semibold))
                    Text(resumeThread?.displayTitle ?? resumeArtifact.title)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(AdvisorySupport.cleanedSnippet(resumeArtifact.body, maxLength: 160))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let quickAction = resumeArtifact.quickActions.first {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Следующий мягкий шаг")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(quickAction.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button("Open Resume Me") {
                        openTimeline()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if resumeSurfaceLoading {
                Divider()

                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading Resume Me…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button(isPaused ? "Resume Tracking" : "Pause Tracking") {
                isPaused.toggle()
                var settings = AppSettings()
                settings.globalPause = isPaused
                NotificationCenter.default.post(name: .captureToggled, object: nil)
                NotificationCenter.default.post(name: .settingsDidChange, object: nil)
            }

            Button("Open Timeline") {
                openTimeline()
            }

            Button("Settings") {
                openSettings()
            }

            Button("Accounts & Sessions") {
                openAccounts()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
        .onAppear {
            permissionsManager.checkAll()
            isPaused = AppSettings().globalPause
            advisoryHealthMonitor.startIfNeeded()
            advisoryHealthMonitor.refresh()
            loadResumeSurfaceIfNeeded()
        }
        .onDisappear {
            resumeSurfaceToken = UUID()
        }
    }

    private var runtimeStatus: RuntimeStatus {
        if isPaused {
            return .paused
        }

        var reasons: [String] = []
        if !permissionsManager.screenRecordingGranted {
            reasons.append("Screen Recording missing")
        }
        if !permissionsManager.accessibilityGranted {
            reasons.append("Accessibility missing")
        }

        return reasons.isEmpty ? .running : .limited(reasons)
    }

    private func openTimeline() {
        if let onOpenTimeline {
            onOpenTimeline()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(#selector(AppDelegate.showTimelineWindowFromMenuBar), to: nil, from: nil)
    }

    private func openSettings() {
        if let onOpenSettings {
            onOpenSettings()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(#selector(AppDelegate.showSettingsWindowFromMenuBar), to: nil, from: nil)
    }

    private func openAccounts() {
        if let onOpenAccounts {
            onOpenAccounts()
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(#selector(AppDelegate.showAccountsWindowFromMenuBar), to: nil, from: nil)
    }

    private func loadResumeSurfaceIfNeeded(force: Bool = false) {
        guard let db else {
            resumeArtifact = nil
            resumeThread = nil
            resumeSurfaceLoading = false
            resumeSurfaceLoadedAt = nil
            return
        }

        guard !resumeSurfaceLoading else { return }
        if !force,
           let resumeSurfaceLoadedAt,
           Date().timeIntervalSince(resumeSurfaceLoadedAt) < 45,
           resumeArtifact != nil {
            return
        }
        resumeSurfaceLoading = true
        let requestToken = UUID()
        resumeSurfaceToken = requestToken

        let database = db
        DispatchQueue.global(qos: .utility).async {
            let engine = AdvisoryEngine(db: database)
            let artifact = try? engine.latestResumeArtifactCached()
            let thread = try? engine.thread(for: artifact?.threadId)

            DispatchQueue.main.async {
                guard resumeSurfaceToken == requestToken else { return }
                resumeArtifact = artifact
                resumeThread = thread
                resumeSurfaceLoading = false
                resumeSurfaceLoadedAt = Date()
            }
        }
    }
}

extension Notification.Name {
    static let captureToggled = Notification.Name("captureToggled")
    static let settingsDidChange = Notification.Name("settingsDidChange")
    static let deleteAllLocalDataRequested = Notification.Name("deleteAllLocalDataRequested")
}
