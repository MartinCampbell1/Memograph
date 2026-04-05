import Foundation

struct AdvisoryCLIAccountProfile: Identifiable, Equatable {
    let providerName: String
    let accountName: String
    let path: String
    let configDirectory: String
    let label: String
    let identityHint: String
    let sessionDetected: Bool
    let isSelected: Bool

    var id: String { "\(providerName):\(accountName)" }

    var displayName: String {
        if !label.isEmpty {
            return label
        }
        if !identityHint.isEmpty {
            return identityHint
        }
        return accountName
    }
}

enum AdvisoryCLIProfilesStoreError: LocalizedError {
    case unsupportedProvider(String)
    case missingCurrentSession(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedProvider(provider):
            return "Unsupported provider: \(provider)"
        case let .missingCurrentSession(provider):
            return "No active \(provider) session was found in the current CLI home."
        }
    }
}

enum AdvisoryCLIProfilesStore {
    static let defaultProfilesPath = (NSHomeDirectory() as NSString).appendingPathComponent(".cli-profiles")

    static func discoverProfiles(
        profilesPath: String = defaultProfilesPath,
        selectedAccounts: [String: String] = [:],
        fileManager: FileManager = .default
    ) -> [String: [AdvisoryCLIAccountProfile]] {
        let root = URL(fileURLWithPath: expandedProfilesPath(profilesPath), isDirectory: true)
        let metadata = loadAccountMetadata(profilesPath: profilesPath, fileManager: fileManager)
        var profiles: [String: [AdvisoryCLIAccountProfile]] = [:]

        for provider in supportedProviders {
            let providerDirectory = root.appendingPathComponent(provider, isDirectory: true)
            guard let children = try? fileManager.contentsOfDirectory(
                at: providerDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let rows = children
                .filter { url in
                    guard url.lastPathComponent.hasPrefix("acc") else { return false }
                    return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { accountURL in
                    makeProfile(
                        provider: provider,
                        accountURL: accountURL,
                        label: metadata[provider]?[accountURL.lastPathComponent]?["label"] ?? "",
                        selectedAccountName: selectedAccounts[provider],
                        fileManager: fileManager
                    )
                }

            if !rows.isEmpty {
                profiles[provider] = rows
            }
        }

        return profiles
    }

    static func createNextProfile(
        provider: String,
        profilesPath: String = defaultProfilesPath,
        fileManager: FileManager = .default
    ) throws -> AdvisoryCLIAccountProfile {
        try prepareProfile(
            provider: provider,
            profilesPath: profilesPath,
            accountName: nextAccountName(provider: provider, profilesPath: profilesPath, fileManager: fileManager),
            fileManager: fileManager
        )
    }

    static func importCurrentSession(
        provider: String,
        profilesPath: String = defaultProfilesPath,
        homePath: String = NSHomeDirectory(),
        accountName: String? = nil,
        fileManager: FileManager = .default
    ) throws -> AdvisoryCLIAccountProfile {
        let normalizedProvider = provider.lowercased()
        guard supportedProviders.contains(normalizedProvider) else {
            throw AdvisoryCLIProfilesStoreError.unsupportedProvider(provider)
        }

        let sourceRoot = providerSourceDirectory(provider: normalizedProvider, homePath: homePath)
        guard currentSessionExists(provider: normalizedProvider, homePath: homePath, fileManager: fileManager) else {
            throw AdvisoryCLIProfilesStoreError.missingCurrentSession(normalizedProvider)
        }

        let resolvedAccountName = normalizedAccountName(
            accountName,
            fallback: nextAccountName(provider: normalizedProvider, profilesPath: profilesPath, fileManager: fileManager)
        )
        let destination = try prepareProfile(
            provider: normalizedProvider,
            profilesPath: profilesPath,
            accountName: resolvedAccountName,
            fileManager: fileManager
        )
        let destinationRoot = URL(fileURLWithPath: destination.path, isDirectory: true)

        switch normalizedProvider {
        case "codex":
            try replaceDirectory(
                from: sourceRoot,
                to: destinationRoot,
                fileManager: fileManager
            )
        case "claude":
            let source = sourceRoot.appendingPathComponent(".claude", isDirectory: true)
            let target = destinationRoot.appendingPathComponent("home/.claude", isDirectory: true)
            try replaceDirectory(from: source, to: target, fileManager: fileManager)
        case "gemini":
            let candidates = [".gemini", ".config/gemini"]
            var copied = false
            for candidate in candidates {
                let source = sourceRoot.appendingPathComponent(candidate, isDirectory: true)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let target = destinationRoot.appendingPathComponent("home/\(candidate)", isDirectory: true)
                try replaceDirectory(from: source, to: target, fileManager: fileManager)
                copied = true
                break
            }
            if !copied {
                throw AdvisoryCLIProfilesStoreError.missingCurrentSession(normalizedProvider)
            }
        default:
            throw AdvisoryCLIProfilesStoreError.unsupportedProvider(normalizedProvider)
        }

        return discoverProfiles(
            profilesPath: profilesPath,
            selectedAccounts: [:],
            fileManager: fileManager
        )[normalizedProvider]?.first(where: { $0.accountName == resolvedAccountName })
            ?? destination
    }

    static func loginEnvironment(
        provider: String,
        profilePath: String,
        realHomePath: String = NSHomeDirectory()
    ) -> [String: String] {
        let normalizedProvider = provider.lowercased()
        let profileRoot = URL(fileURLWithPath: profilePath, isDirectory: true)
        switch normalizedProvider {
        case "codex":
            return [
                "CODEX_HOME": profileRoot.path
            ]
        case "claude":
            return [
                "HOME": profileRoot.appendingPathComponent("home", isDirectory: true).path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ]
        case "gemini":
            var environment = [
                "HOME": profileRoot.appendingPathComponent("home", isDirectory: true).path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? ""
            ]
            let nvmDirectory = URL(fileURLWithPath: realHomePath, isDirectory: true)
                .appendingPathComponent(".nvm", isDirectory: true)
            if FileManager.default.fileExists(atPath: nvmDirectory.path) {
                environment["NVM_DIR"] = nvmDirectory.path
            }
            return environment
        default:
            return [:]
        }
    }

    static func selectedAccounts(settings: AppSettings = AppSettings()) -> [String: String] {
        var selected: [String: String] = [:]
        if !settings.advisorySelectedClaudeAccount.isEmpty {
            selected["claude"] = settings.advisorySelectedClaudeAccount
        }
        if !settings.advisorySelectedGeminiAccount.isEmpty {
            selected["gemini"] = settings.advisorySelectedGeminiAccount
        }
        if !settings.advisorySelectedCodexAccount.isEmpty {
            selected["codex"] = settings.advisorySelectedCodexAccount
        }
        return selected
    }

    static func setPreferredAccount(
        provider: String,
        accountName: String,
        profilesPath: String = defaultProfilesPath,
        fileManager: FileManager = .default
    ) throws {
        let normalizedProvider = provider.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAccountName = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard supportedProviders.contains(normalizedProvider), !normalizedAccountName.isEmpty else {
            throw AdvisoryCLIProfilesStoreError.unsupportedProvider(provider)
        }

        let root = URL(fileURLWithPath: expandedProfilesPath(profilesPath), isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: nil)
        let path = preferredAccountsURL(profilesPath: profilesPath)
        var preferredAccounts = loadPreferredAccounts(profilesPath: profilesPath, fileManager: fileManager)
        preferredAccounts[normalizedProvider] = normalizedAccountName
        let payload = ["preferredAccounts": preferredAccounts]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
    }

    private static let supportedProviders = ["claude", "gemini", "codex"]

    private static func makeProfile(
        provider: String,
        accountURL: URL,
        label: String,
        selectedAccountName: String?,
        fileManager: FileManager
    ) -> AdvisoryCLIAccountProfile? {
        let sessionDetected = sessionExists(
            provider: provider,
            accountURL: accountURL,
            fileManager: fileManager
        )
        let configDirectory = configDirectoryPath(provider: provider, accountURL: accountURL)
        return AdvisoryCLIAccountProfile(
            providerName: provider,
            accountName: accountURL.lastPathComponent,
            path: accountURL.path,
            configDirectory: configDirectory,
            label: label,
            identityHint: identityHint(provider: provider, accountURL: accountURL),
            sessionDetected: sessionDetected,
            isSelected: selectedAccountName == accountURL.lastPathComponent
        )
    }

    private static func prepareProfile(
        provider: String,
        profilesPath: String,
        accountName: String,
        fileManager: FileManager
    ) throws -> AdvisoryCLIAccountProfile {
        let normalizedProvider = provider.lowercased()
        guard supportedProviders.contains(normalizedProvider) else {
            throw AdvisoryCLIProfilesStoreError.unsupportedProvider(provider)
        }

        let providerDirectory = URL(fileURLWithPath: expandedProfilesPath(profilesPath), isDirectory: true)
            .appendingPathComponent(normalizedProvider, isDirectory: true)
        try fileManager.createDirectory(at: providerDirectory, withIntermediateDirectories: true, attributes: nil)

        let accountDirectory = providerDirectory.appendingPathComponent(accountName, isDirectory: true)
        if fileManager.fileExists(atPath: accountDirectory.path) {
            try fileManager.removeItem(at: accountDirectory)
        }
        try fileManager.createDirectory(at: accountDirectory, withIntermediateDirectories: true, attributes: nil)
        if normalizedProvider == "claude" || normalizedProvider == "gemini" {
            try fileManager.createDirectory(
                at: accountDirectory.appendingPathComponent("home", isDirectory: true),
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        return AdvisoryCLIAccountProfile(
            providerName: normalizedProvider,
            accountName: accountName,
            path: accountDirectory.path,
            configDirectory: configDirectoryPath(provider: normalizedProvider, accountURL: accountDirectory),
            label: "",
            identityHint: "",
            sessionDetected: false,
            isSelected: false
        )
    }

    private static func replaceDirectory(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.copyItem(at: source, to: destination)
    }

    private static func currentSessionExists(
        provider: String,
        homePath: String,
        fileManager: FileManager
    ) -> Bool {
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        switch provider {
        case "codex":
            let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
            return fileManager.fileExists(atPath: codexRoot.appendingPathComponent("auth.json").path)
                || fileManager.fileExists(atPath: codexRoot.appendingPathComponent("config.toml").path)
        case "claude":
            return fileManager.fileExists(atPath: home.appendingPathComponent(".claude", isDirectory: true).path)
        case "gemini":
            return fileManager.fileExists(atPath: home.appendingPathComponent(".gemini", isDirectory: true).path)
                || fileManager.fileExists(atPath: home.appendingPathComponent(".config/gemini", isDirectory: true).path)
        default:
            return false
        }
    }

    private static func providerSourceDirectory(provider: String, homePath: String) -> URL {
        let home = URL(fileURLWithPath: homePath, isDirectory: true)
        if provider == "codex" {
            return home.appendingPathComponent(".codex", isDirectory: true)
        }
        return home
    }

    private static func identityHint(provider: String, accountURL: URL) -> String {
        switch provider {
        case "claude":
            let credentialsURL = accountURL.appendingPathComponent("home/.claude/.credentials.json")
            guard
                let payload = readJSON(credentialsURL) as? [String: Any],
                let oauth = payload["claudeAiOauth"] as? [String: Any],
                let email = oauth["email"] as? String
            else {
                return ""
            }
            return email.trimmingCharacters(in: .whitespacesAndNewlines)
        case "gemini":
            let accountsURL = accountURL.appendingPathComponent("home/.gemini/google_accounts.json")
            guard
                let payload = readJSON(accountsURL) as? [String: Any],
                let active = payload["active"] as? String
            else {
                return ""
            }
            return active.trimmingCharacters(in: .whitespacesAndNewlines)
        case "codex":
            let authURL = accountURL.appendingPathComponent("auth.json")
            if let payload = readJSON(authURL) as? [String: Any] {
                if let email = payload["email"] as? String,
                   !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return email.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let user = payload["user"] as? String,
                   !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return user.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            // Try config.toml as fallback
            let configURL = accountURL.appendingPathComponent("config.toml")
            if let content = try? String(contentsOf: configURL, encoding: .utf8) {
                for line in content.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("email"), trimmed.contains("=") {
                        let value = trimmed.components(separatedBy: "=").dropFirst().joined(separator: "=")
                            .trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !value.isEmpty { return value }
                    }
                }
            }
            return ""
        default:
            return ""
        }
    }

    private static func loadAccountMetadata(
        profilesPath: String,
        fileManager: FileManager
    ) -> [String: [String: [String: String]]] {
        let path = URL(fileURLWithPath: expandedProfilesPath(profilesPath), isDirectory: true)
            .appendingPathComponent(".account-metadata.json")
        guard fileManager.fileExists(atPath: path.path),
              let payload = readJSON(path) as? [String: [String: [String: String]]] else {
            return [:]
        }
        return payload
    }

    private static func loadPreferredAccounts(
        profilesPath: String,
        fileManager: FileManager
    ) -> [String: String] {
        let path = preferredAccountsURL(profilesPath: profilesPath)
        guard fileManager.fileExists(atPath: path.path),
              let payload = readJSON(path) as? [String: Any],
              let preferred = payload["preferredAccounts"] as? [String: String] else {
            return [:]
        }
        return preferred
    }

    private static func nextAccountName(
        provider: String,
        profilesPath: String,
        fileManager: FileManager
    ) -> String {
        let providerDirectory = URL(fileURLWithPath: expandedProfilesPath(profilesPath), isDirectory: true)
            .appendingPathComponent(provider, isDirectory: true)
        guard let children = try? fileManager.contentsOfDirectory(
            at: providerDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "acc1"
        }
        let existing = children
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("acc") }
        return "acc\(existing.count + 1)"
    }

    private static func sessionExists(
        provider: String,
        accountURL: URL,
        fileManager: FileManager
    ) -> Bool {
        switch provider {
        case "codex":
            return fileManager.fileExists(atPath: accountURL.appendingPathComponent("auth.json").path)
                || fileManager.fileExists(atPath: accountURL.appendingPathComponent("config.toml").path)
        case "claude":
            return fileManager.fileExists(atPath: accountURL.appendingPathComponent("home/.claude").path)
        case "gemini":
            return fileManager.fileExists(atPath: accountURL.appendingPathComponent("home/.gemini").path)
                || fileManager.fileExists(atPath: accountURL.appendingPathComponent("home/.config/gemini").path)
        default:
            return false
        }
    }

    private static func configDirectoryPath(provider: String, accountURL: URL) -> String {
        switch provider {
        case "codex":
            return accountURL.path
        case "claude":
            return accountURL.appendingPathComponent("home/.claude").path
        case "gemini":
            let primary = accountURL.appendingPathComponent("home/.gemini").path
            if FileManager.default.fileExists(atPath: primary) {
                return primary
            }
            let xdg = accountURL.appendingPathComponent("home/.config/gemini").path
            if FileManager.default.fileExists(atPath: xdg) {
                return xdg
            }
            return primary
        default:
            return accountURL.path
        }
    }

    private static func expandedProfilesPath(_ profilesPath: String) -> String {
        let trimmed = profilesPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = trimmed.isEmpty ? defaultProfilesPath : trimmed
        return (raw as NSString).expandingTildeInPath
    }

    private static func preferredAccountsURL(profilesPath: String) -> URL {
        URL(fileURLWithPath: expandedProfilesPath(profilesPath), isDirectory: true)
            .appendingPathComponent(".memograph-account-preferences.json")
    }

    private static func normalizedAccountName(_ accountName: String?, fallback: String) -> String {
        let candidate = accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return candidate.isEmpty ? fallback : candidate
    }

    private static func readJSON(_ url: URL) -> Any? {
        guard
            let data = try? Data(contentsOf: url),
            let payload = try? JSONSerialization.jsonObject(with: data)
        else {
            return nil
        }
        return payload
    }
}
