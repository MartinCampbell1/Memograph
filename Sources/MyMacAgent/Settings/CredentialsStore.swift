import Foundation
import LocalAuthentication
import Security

protocol CredentialsStore: Sendable {
    func hasValue(for key: String) -> Bool
    func string(for key: String) -> String?
    func set(_ value: String, for key: String)
    func removeValue(for key: String)
}

final class PreferencesCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let namespace: String

    init(defaults: UserDefaults = .standard, namespace: String = "com.memograph.credentials.") {
        self.defaults = defaults
        self.namespace = namespace
    }

    func hasValue(for key: String) -> Bool {
        guard let value = defaults.string(forKey: namespacedKey(key)) else {
            return false
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func string(for key: String) -> String? {
        defaults.string(forKey: namespacedKey(key))
    }

    func set(_ value: String, for key: String) {
        defaults.set(value, forKey: namespacedKey(key))
    }

    func removeValue(for key: String) {
        defaults.removeObject(forKey: namespacedKey(key))
    }

    private func namespacedKey(_ key: String) -> String {
        namespace + key
    }
}

final class KeychainCredentialsStore: CredentialsStore, @unchecked Sendable {
    private let service: String

    init(service: String) {
        self.service = service
    }

    func hasValue(for key: String) -> Bool {
        var query = baseQuery(for: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnAttributes as String] = true
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func string(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    func set(_ value: String, for key: String) {
        let encodedValue = Data(value.utf8)
        let query = baseQuery(for: key)
        let attributes = [kSecValueData as String: encodedValue]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        var newItem = query
        newItem[kSecValueData as String] = encodedValue
        SecItemAdd(newItem as CFDictionary, nil)
    }

    func removeValue(for key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}

final class InMemoryCredentialsStore: CredentialsStore, @unchecked Sendable {
    private var values: [String: String] = [:]

    func hasValue(for key: String) -> Bool {
        values[key] != nil
    }

    func string(for key: String) -> String? {
        values[key]
    }

    func set(_ value: String, for key: String) {
        values[key] = value
    }

    func removeValue(for key: String) {
        values.removeValue(forKey: key)
    }
}

struct NoOpCredentialsStore: CredentialsStore {
    func hasValue(for key: String) -> Bool { false }
    func string(for key: String) -> String? { nil }
    func set(_ value: String, for key: String) {}
    func removeValue(for key: String) {}
}
