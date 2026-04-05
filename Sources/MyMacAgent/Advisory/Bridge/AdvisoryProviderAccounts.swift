import Foundation

struct AdvisoryProviderAccountHealthSummary: Codable, Equatable {
    let total: Int
    let available: Int
    let onCooldown: Int

    static let empty = AdvisoryProviderAccountHealthSummary(total: 0, available: 0, onCooldown: 0)
}

struct AdvisoryProviderAccountRecord: Codable, Equatable, Identifiable {
    let providerName: String
    let accountName: String
    let label: String?
    let identity: String?
    let detail: String?
    let authState: String
    let available: Bool
    let preferred: Bool
    let binaryPresent: Bool
    let sessionDetected: Bool
    let cooldownRemainingSeconds: Int?
    let lastError: String?
    let requestsMade: Int
    let lastUsedAt: Int?
    let lastCheckedAt: String?
    let profilePath: String
    let configDirectory: String?

    var id: String { "\(providerName):\(accountName)" }

    var displayTitle: String {
        let trimmedLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedLabel.isEmpty {
            return trimmedLabel
        }
        let trimmedIdentity = identity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedIdentity.isEmpty {
            return trimmedIdentity
        }
        return accountName
    }

    var subtitle: String {
        let trimmedIdentity = identity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedIdentity.isEmpty, trimmedIdentity != displayTitle {
            return trimmedIdentity
        }
        let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedDetail.isEmpty {
            return trimmedDetail
        }
        return accountName
    }

    var statusLabel: String {
        switch authState {
        case "verified":
            return available ? "available" : "verified"
        case "error":
            return "auth error"
        default:
            return "not checked"
        }
    }
}

struct AdvisoryProviderAccountsSnapshot: Codable, Equatable {
    let profilesDirectory: String
    let checkedAt: String?
    let healthSummary: AdvisoryProviderAccountHealthSummary
    let accountsByProvider: [String: [AdvisoryProviderAccountRecord]]
    let preferredAccounts: [String: String]

    static let empty = AdvisoryProviderAccountsSnapshot(
        profilesDirectory: "",
        checkedAt: nil,
        healthSummary: .empty,
        accountsByProvider: [:],
        preferredAccounts: [:]
    )

    func accounts(for providerName: String) -> [AdvisoryProviderAccountRecord] {
        accountsByProvider[providerName, default: []]
            .sorted { lhs, rhs in
                if lhs.preferred != rhs.preferred {
                    return lhs.preferred && !rhs.preferred
                }
                if lhs.available != rhs.available {
                    return lhs.available && !rhs.available
                }
                return lhs.accountName < rhs.accountName
            }
    }
}

struct AdvisoryProviderAccountActionResponse: Codable, Equatable {
    let status: String
    let providerName: String
    let accountName: String?
    let command: String?
    let message: String
    let snapshot: AdvisoryProviderAccountsSnapshot?
}
