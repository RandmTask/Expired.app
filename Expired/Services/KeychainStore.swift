import Foundation
import Security

/// Minimal Keychain wrapper for secrets that must stay on this device only.
///
/// API keys are per-device and must never live in UserDefaults, the synced
/// SwiftData store, CloudKit, or the app binary. Items use
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so they are never included
/// in an iCloud Keychain sync or an encrypted device backup transfer.
enum KeychainStore {
    private static let service = "com.swiftstudio.Expired.apiKeys"

    /// Stores `value` for `account`. An empty string clears the item.
    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// Returns the stored value for `account`, or an empty string if none.
    static func get(_ account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return "" }
        return string
    }
}
