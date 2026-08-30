import Foundation
import Security

/// Grux-worldwide credentials vault. Namespaced string keys (e.g.
/// "social/<brand>/<platform>/<field>", "api-keys/<name>", "service-logins/<name>").
/// Separate Keychain service from KeychainStore so the closed Key enum and its
/// callers are untouched. Same accessibility (AfterFirstUnlock) so Grux can read
/// at login. Values are never logged, never written to disk in plaintext.
enum Vault {
    static let service = "com.gruxai.grux.vault"

    @discardableResult
    static func set(_ path: String, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: path,
        ]
        var find = base; find[kSecMatchLimit as String] = kSecMatchLimitOne
        if KeychainStore.copyMatching(find, nil) == errSecSuccess {
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            return SecItemUpdate(base as CFDictionary, attrs as CFDictionary) == errSecSuccess
        }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ path: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: path,
            kSecReturnData as String: true,
            // A read never prompts. See KeychainStore.neverPrompt for why.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard KeychainStore.copyMatching(q, &item) == errSecSuccess,
              let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    static func delete(_ path: String) -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: path,
        ]
        let s = SecItemDelete(q as CFDictionary)
        return s == errSecSuccess || s == errSecItemNotFound
    }

    /// Account names (paths) only, never values. For UI listing of stored creds.
    static func list(prefix: String = "") -> [String] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            // A read never prompts. See KeychainStore.neverPrompt for why.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        guard KeychainStore.copyMatching(q, &items) == errSecSuccess,
              let arr = items as? [[String: Any]] else { return [] }
        return arr.compactMap { $0[kSecAttrAccount as String] as? String }
            .filter { prefix.isEmpty || $0.hasPrefix(prefix) }
            .sorted()
    }
}
