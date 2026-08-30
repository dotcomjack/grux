import Foundation

// Pairing secret storage + access, plus the small helper for retrieving the
// listener's advertised port and Mac hostname for the QR.
//
// Pairing model:
//   1. First run: generate a 32-byte random secret, stash in Keychain under
//      KeychainStore.Key.phonePairingSecret.
//   2. User opens "Pair iPhone" window; UI encodes grux-pair:// URL with the
//      base64url secret + hostname.local + listener port + Mac display name.
//   3. Phone scans QR, stores the secret in its own iOS Keychain.
//   4. On every connection, phone sends HELLO_AUTH (nonce || HMAC(secret, nonce||name)).
//   5. Mac recomputes HMAC, constant-time compares. Pass → AUTH_OK, fail → AUTH_FAIL + close.
//
// Rotation: "Reset pairing" in Settings deletes the secret; next pair generates
// a new one. Old phones bound to the stale secret stop authenticating.
enum PhonePairing {
    static var isConfigured: Bool {
        KeychainStore.exists(.phonePairingSecret)
    }

    // Returns the 32-byte secret, creating one if it doesn't already exist.
    // Idempotent - safe to call on every launch.
    @discardableResult
    static func ensureSecret() -> Data {
        if let existing = secret() { return existing }
        let fresh = PhoneAuthHMAC.random32()
        _ = KeychainStore.set(.phonePairingSecret, fresh.base64EncodedString())
        return fresh
    }

    // Fetch the current secret, or nil if never configured.
    static func secret() -> Data? {
        let b64 = KeychainStore.get(.phonePairingSecret)
        guard !b64.isEmpty, let data = Data(base64Encoded: b64), data.count == 32 else { return nil }
        return data
    }

    // "Reset pairing" - deletes the secret; future HELLO_AUTH will regenerate
    // on next pair. Existing connections aren't dropped here; PhoneReceiverService
    // does that on the same tick when it observes the Keychain change.
    @discardableResult
    static func reset() -> Bool {
        KeychainStore.delete(.phonePairingSecret)
    }

    // Constant-time equality for HMAC compare. `Data ==` bails on the first
    // differing byte; HMAC compares MUST be timing-independent. CryptoKit's
    // types hide their backing bytes, so we do it manually here.
    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count {
            diff |= a[a.startIndex + i] ^ b[b.startIndex + i]
        }
        return diff == 0
    }

    // Best-effort Mac hostname for the QR - mDNS "<computer>.local" form is
    // what the phone's Bonjour resolver (or manual URL fallback) will hit.
    static func localHostname() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count) == 0, let raw = String(cString: buf, encoding: .utf8) else {
            return "grux-mac.local"
        }
        // Most macs return "name.local" already; if not, append it so resolving
        // from the phone doesn't hit unicast DNS.
        return raw.hasSuffix(".local") ? raw : raw + ".local"
    }

    static func displayName() -> String {
        ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: ".lan", with: "")
    }
}
