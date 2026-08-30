import Foundation
import Security

// iOS Keychain wrapper, stores the paired Mac's host, port, and 32-byte
// shared secret. Separate from any personal data; if the user uninstalls the
// app, iOS wipes this automatically.
//
// All writes use `kSecAttrAccessibleAfterFirstUnlock` so background audio
// can resume streaming after the device reboots (the background-audio
// entitlement keeps the app alive, but Keychain reads would otherwise fail
// until the user unlocks).
enum PhoneKeychain {
    static let service = "com.dcj.gruxphone"

    enum Key: String {
        case pairingSecretB64
        case macHost
        case macPort
        case macDisplayName
    }

    @discardableResult
    static func set(_ key: Key, _ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        var find = base
        find[kSecReturnData as String] = false
        find[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(find as CFDictionary, nil)
        if status == errSecSuccess {
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            return SecItemUpdate(base as CFDictionary, attrs as CFDictionary) == errSecSuccess
        }
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    static func get(_ key: Key) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func isPaired() -> Bool {
        // v2 stores the full wss:// URL in .macHost and leaves .macPort empty.
        // Only the secret + host are required.
        !get(.pairingSecretB64).isEmpty && !get(.macHost).isEmpty
    }

    static func clearPairing() {
        delete(.pairingSecretB64)
        delete(.macHost)
        delete(.macPort)
        delete(.macDisplayName)
    }
}
