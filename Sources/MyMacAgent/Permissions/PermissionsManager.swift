import AppKit
@preconcurrency import ScreenCaptureKit
import os

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false

    private let logger = Logger.permissions

    var allGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    func checkAll() {
        checkAccessibility()
        Task { await checkScreenRecording() }
    }

    func checkAccessibility() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func requestAccessibility() {
        // Use the documented string value of kAXTrustedCheckOptionPrompt to avoid
        // Swift 6 concurrency errors with the C global (CFStringRef extern var).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    func checkScreenRecording() async {
        do {
            _ = try await SCShareableContent.current
            screenRecordingGranted = true
        } catch {
            screenRecordingGranted = false
        }
    }

    func openScreenRecordingPrefs() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func openAccessibilityPrefs() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
