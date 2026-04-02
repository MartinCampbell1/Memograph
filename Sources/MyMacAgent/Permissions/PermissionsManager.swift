import AppKit
import AVFoundation
import os

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false

    private let logger = Logger.permissions

    var allGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    /// Silent check only — never triggers system dialogs
    func checkAll() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        logger.info("Permissions refreshed")
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneGranted = granted
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
    }
}
