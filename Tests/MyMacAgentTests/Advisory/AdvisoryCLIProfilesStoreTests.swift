import Foundation
import Testing
@testable import MyMacAgent

struct AdvisoryCLIProfilesStoreTests {
    @Test("Discover profiles loads labels identity hints and selection")
    func discoverProfiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("advisory-profiles-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)

        let claudeAccount = root.appendingPathComponent("claude/acc2/home/.claude", isDirectory: true)
        try fileManager.createDirectory(at: claudeAccount, withIntermediateDirectories: true, attributes: nil)
        try """
        {
          "claudeAiOauth": {
            "email": "person@example.com"
          }
        }
        """.write(
            to: claudeAccount.appendingPathComponent(".credentials.json"),
            atomically: true,
            encoding: .utf8
        )
        try """
        {
          "claude": {
            "acc2": {
              "label": "main claude"
            }
          }
        }
        """.write(
            to: root.appendingPathComponent(".account-metadata.json"),
            atomically: true,
            encoding: .utf8
        )

        let profiles = AdvisoryCLIProfilesStore.discoverProfiles(
            profilesPath: root.path,
            selectedAccounts: ["claude": "acc2"]
        )

        let claude = try #require(profiles["claude"]?.first)
        #expect(claude.accountName == "acc2")
        #expect(claude.label == "main claude")
        #expect(claude.identityHint == "person@example.com")
        #expect(claude.sessionDetected)
        #expect(claude.isSelected)
    }

    @Test("Create next profile and login environment follow provider model")
    func createProfileAndEnvironment() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("advisory-create-\(UUID().uuidString)", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)

        let codex = try AdvisoryCLIProfilesStore.createNextProfile(
            provider: "codex",
            profilesPath: root.path
        )
        let gemini = try AdvisoryCLIProfilesStore.createNextProfile(
            provider: "gemini",
            profilesPath: root.path
        )

        #expect(codex.accountName == "acc1")
        #expect(fileManager.fileExists(atPath: codex.path))
        #expect(AdvisoryCLIProfilesStore.loginEnvironment(provider: "codex", profilePath: codex.path)["CODEX_HOME"] == codex.path)

        #expect(gemini.accountName == "acc1")
        #expect(fileManager.fileExists(atPath: (URL(fileURLWithPath: gemini.path).appendingPathComponent("home").path)))
        #expect(AdvisoryCLIProfilesStore.loginEnvironment(provider: "gemini", profilePath: gemini.path)["HOME"]?.hasSuffix("/home") == true)
    }
}
