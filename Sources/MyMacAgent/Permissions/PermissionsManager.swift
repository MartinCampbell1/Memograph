import AppKit
import os

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var accessibilityGranted = false

    private let logger = Logger.permissions
    private var hasChecked = false

    var allGranted: Bool {
        screenRecordingGranted && accessibilityGranted
    }

    /// Silent check only — never triggers system dialogs
    func checkAll() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        hasChecked = true
        logger.info("Permissions: accessibility=\(self.accessibilityGranted) screenRecording=\(self.screenRecordingGranted)")
    }
}
