import Foundation
import os

final class PrivacyGuard {
    private let blacklistedBundleIds: Set<String>
    private let blacklistedWindowPatterns: [String]
    private let metadataOnlyBundleIds: Set<String>
    private var isPaused = false
    private let logger = Logger.app

    init(
        blacklistedBundleIds: [String] = [],
        blacklistedWindowPatterns: [String] = [],
        metadataOnlyBundleIds: [String] = []
    ) {
        self.blacklistedBundleIds = Set(blacklistedBundleIds)
        self.blacklistedWindowPatterns = blacklistedWindowPatterns.map { $0.lowercased() }
        self.metadataOnlyBundleIds = Set(metadataOnlyBundleIds)
    }

    static func withDefaults() -> PrivacyGuard {
        PrivacyGuard(
            blacklistedBundleIds: [
                "com.apple.keychainaccess",
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.lastpass.LastPass",
                "com.bitwarden.desktop",
                "com.dashlane.Dashlane"
            ],
            blacklistedWindowPatterns: [
                "password", "private browsing", "incognito",
                "1password", "keychain", "credential"
            ],
            metadataOnlyBundleIds: [
                "com.apple.MobileSMS",
                "com.tinyspeck.slackmacgap"
            ]
        )
    }

    static func fromSettings(_ settings: AppSettings = AppSettings()) -> PrivacyGuard {
        let guard_ = PrivacyGuard(
            blacklistedBundleIds: settings.blacklistedBundleIds,
            blacklistedWindowPatterns: settings.blacklistedWindowPatterns,
            metadataOnlyBundleIds: settings.metadataOnlyBundleIds
        )

        if settings.globalPause || settings.startPaused {
            guard_.pause()
        }

        return guard_
    }

    func shouldCapture(bundleId: String, windowTitle: String? = nil) -> Bool {
        if isPaused { return false }
        if blacklistedBundleIds.contains(bundleId) { return false }
        if let title = windowTitle?.lowercased() {
            for pattern in blacklistedWindowPatterns {
                if title.contains(pattern) { return false }
            }
        }
        return true
    }

    func shouldOCR(bundleId: String) -> Bool {
        !metadataOnlyBundleIds.contains(bundleId)
    }

    func pause() {
        isPaused = true
        logger.info("Privacy: capture paused")
    }

    func resume() {
        isPaused = false
        logger.info("Privacy: capture resumed")
    }

    var paused: Bool { isPaused }
}
