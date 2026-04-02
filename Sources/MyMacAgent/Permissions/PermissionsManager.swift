import AppKit
import AVFoundation
import os

@MainActor
final class PermissionsManager: NSObject, ObservableObject {
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var legacyAppRunning = false

    private let logger = Logger.permissions

    var allGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handlePermissionRelevantAppChange),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handlePermissionRelevantAppChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        checkAll()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Silent check only — never triggers system dialogs
    func checkAll() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        legacyAppRunning = !NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.martin.mymacagent"
        ).isEmpty
        let statusLine = "Permissions refreshed: "
            + "AX=\(accessibilityGranted) "
            + "screen=\(screenRecordingGranted) "
            + "mic=\(microphoneGranted) "
            + "legacy=\(legacyAppRunning)"
        logger.info("\(statusLine, privacy: .public)")
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        scheduleRefresh()
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneGranted = granted
        scheduleRefresh()
    }

    func openAccessibilitySettings() {
        openSettingsPane("Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openSettingsPane("Privacy_ScreenCapture")
    }

    func openMicrophoneSettings() {
        openSettingsPane("Privacy_Microphone")
    }

    private func openSettingsPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
        scheduleRefresh()
    }

    func relaunchApp() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                self.logger.error("Failed to relaunch app: \(error.localizedDescription)")
                return
            }
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    func quitLegacyAppInstances() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.martin.mymacagent")
        for app in apps {
            if !app.terminate() {
                app.forceTerminate()
            }
        }
        scheduleRefresh()
    }

    func setPreviewStatus(
        screenRecordingGranted: Bool,
        accessibilityGranted: Bool,
        microphoneGranted: Bool
    ) {
        self.screenRecordingGranted = screenRecordingGranted
        self.accessibilityGranted = accessibilityGranted
        self.microphoneGranted = microphoneGranted
    }

    private func scheduleRefresh() {
        let delays: [TimeInterval] = [0.25, 1.0, 2.5, 5.0]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.checkAll()
            }
        }
    }

    @objc
    private func handlePermissionRelevantAppChange() {
        checkAll()
    }
}
