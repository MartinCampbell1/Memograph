import Testing
import Foundation
@testable import MyMacAgent

struct PrivacyGuardTests {
    @Test("Blocks blacklisted bundle IDs")
    func blocksBlacklisted() {
        let guard_ = PrivacyGuard(blacklistedBundleIds: ["com.apple.keychainaccess", "com.1password.1password"])
        #expect(!guard_.shouldCapture(bundleId: "com.apple.keychainaccess"))
        #expect(!guard_.shouldCapture(bundleId: "com.1password.1password"))
        #expect(guard_.shouldCapture(bundleId: "com.apple.Safari"))
    }

    @Test("Blocks by window title pattern")
    func blocksWindowTitle() {
        let guard_ = PrivacyGuard(blacklistedBundleIds: [], blacklistedWindowPatterns: ["password", "private", "incognito"])
        #expect(!guard_.shouldCapture(bundleId: "com.test", windowTitle: "Enter Password"))
        #expect(!guard_.shouldCapture(bundleId: "com.test", windowTitle: "Private Browsing"))
        #expect(guard_.shouldCapture(bundleId: "com.test", windowTitle: "My Document"))
    }

    @Test("Paused state blocks all capture")
    func pauseBlocks() {
        let guard_ = PrivacyGuard(blacklistedBundleIds: [])
        #expect(guard_.shouldCapture(bundleId: "com.test"))
        guard_.pause()
        #expect(!guard_.shouldCapture(bundleId: "com.test"))
        guard_.resume()
        #expect(guard_.shouldCapture(bundleId: "com.test"))
    }

    @Test("Default blacklist includes common sensitive apps")
    func defaultBlacklist() {
        let guard_ = PrivacyGuard.withDefaults()
        #expect(!guard_.shouldCapture(bundleId: "com.apple.keychainaccess"))
        #expect(!guard_.shouldCapture(bundleId: "com.1password.1password"))
        #expect(guard_.shouldCapture(bundleId: "com.apple.Safari"))
    }

    @Test("Metadata-only mode allows capture but blocks OCR")
    func metadataOnly() {
        let guard_ = PrivacyGuard(blacklistedBundleIds: [], metadataOnlyBundleIds: ["com.apple.MobileSMS"])
        #expect(guard_.shouldCapture(bundleId: "com.apple.MobileSMS"))
        #expect(!guard_.shouldOCR(bundleId: "com.apple.MobileSMS"))
        #expect(guard_.shouldOCR(bundleId: "com.apple.Safari"))
    }
}
