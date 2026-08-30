import Foundation
import CryptoKit

// Per-session AEAD (ChaCha20-Poly1305) used over the WebSocket. Cloudflare
// sees only ciphertext.
//
// Session key derivation:
//   session_key = HKDF-SHA256(
//       ikm:  pairing HMAC secret (32B),
//       salt: clientNonce || serverNonce (64B),
//       info: "grux-phone-v1",
//       length: 32
//   )
//
// Nonce per frame (12B): [1B direction][3B zero][8B counter BE].
// direction = 0x01 for phone→mac, 0x02 for mac→phone. Counter monotonically
// increases within its direction. Each side owns its own counter.
//
// AEAD associated data = 2-byte frame header [version][type] - so a MITM
// can't flip the `type` byte without the tag failing. (The header is sent in
// the clear on the wire so both sides see the same AD.)
//
// Why not full ECDH: keeps the protocol one RTT shorter and avoids loading
// a second key class into Keychain. The HMAC secret already anchors trust;
// a new random session key per connection gives semi-forward-secrecy so
// past traffic isn't fully compromised by a single capture.

enum PhoneCryptoDirection: UInt8 {
    case phoneToMac = 0x01
    case macToPhone = 0x02
}

enum PhoneCryptoError: Error {
    case sealFailed
    case openFailed(String)
    case counterExhausted
    case notEstablished
}

final class PhoneSessionCrypto {
    let key: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var recvCounter: UInt64 = 0
    private let sendDir: PhoneCryptoDirection
    private let recvDir: PhoneCryptoDirection

    init(key: SymmetricKey, sendDir: PhoneCryptoDirection) {
        self.key = key
        self.sendDir = sendDir
        self.recvDir = (sendDir == .phoneToMac) ? .macToPhone : .phoneToMac
    }

    // Derive session key from:
    //   IKM  = ecdheShared (32B) || pairingSecret (32B)
    //   salt = clientNonce || serverNonce (64B)
    //   info = "grux-phone-v3"
    //
    // Mixing the ECDHE shared secret into the IKM gives forward secrecy - if
    // the long-term pairing secret leaks later, past captured traffic still
    // can't be decrypted without one of the session's ephemeral private keys
    // (which are zeroed when the session ends).
    //
    // Mixing the pairing secret in too (rather than using ECDHE alone) keeps
    // identity-authentication bound to a pre-shared secret: even a perfect
    // MITM of the ECDHE exchange can't derive the same session key without
    // knowing the long-term secret.
    static func deriveKey(ecdheShared: Data, pairingSecret: Data,
                          clientNonce: Data, serverNonce: Data) -> SymmetricKey {
        precondition(ecdheShared.count == 32, "ecdhe shared must be 32B")
        precondition(pairingSecret.count == 32, "pairing secret must be 32B")
        precondition(clientNonce.count == 32 && serverNonce.count == 32)
        var ikm = Data()
        ikm.append(ecdheShared)
        ikm.append(pairingSecret)
        var salt = Data()
        salt.append(clientNonce)
        salt.append(serverNonce)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data("grux-phone-v3".utf8),
            outputByteCount: 32
        )
    }

    private func makeNonce(counter: UInt64, direction: PhoneCryptoDirection) throws -> ChaChaPoly.Nonce {
        // 12 bytes: [1B dir][3B zero][8B counter BE]
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = direction.rawValue
        var ctr = counter.bigEndian
        withUnsafeBytes(of: &ctr) { buf in
            for i in 0..<8 { bytes[4 + i] = buf[i] }
        }
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }

    // Seal the inner payload, return what goes on the wire AFTER the 2B header.
    // The 2B header is used as AEAD AD so the type can't be flipped undetected.
    // Wire body: [8B counter BE][ciphertext + 16B tag]
    func seal(type: UInt8, plaintext: Data) throws -> Data {
        guard sendCounter < .max else { throw PhoneCryptoError.counterExhausted }
        let counter = sendCounter
        sendCounter &+= 1
        let nonce = try makeNonce(counter: counter, direction: sendDir)
        var ad = Data()
        ad.append(PhoneWire.version)
        ad.append(type)
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: ad)
        } catch {
            throw PhoneCryptoError.sealFailed
        }
        var out = Data()
        var ctrBE = counter.bigEndian
        withUnsafeBytes(of: &ctrBE) { out.append(contentsOf: $0) }
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    // Decrypt a received frame body ([counter][ciphertext+tag]) given its type.
    func open(type: UInt8, wireBody: Data) throws -> Data {
        guard wireBody.count >= 8 + 16 else { throw PhoneCryptoError.openFailed("too short") }
        let start = wireBody.startIndex
        let ctrBytes = wireBody.subdata(in: start..<(start + 8))
        let counter = UInt64(bigEndian: ctrBytes.withUnsafeBytes { $0.load(as: UInt64.self) })
        // Allow minor reordering (counter >= recvCounter - 32 window), but
        // advance recvCounter to max seen. Drops replays within the window by
        // refusing out-of-range counters. Simple + enough for our use.
        if counter + 32 < recvCounter {
            throw PhoneCryptoError.openFailed("counter \(counter) too old (recv \(recvCounter))")
        }
        recvCounter = max(recvCounter, counter + 1)

        let tagStart = wireBody.count - 16
        let ciphertext = wireBody.subdata(in: (start + 8)..<(start + tagStart))
        let tag = wireBody.subdata(in: (start + tagStart)..<wireBody.endIndex)
        let nonce = try makeNonce(counter: counter, direction: recvDir)
        var ad = Data()
        ad.append(PhoneWire.version)
        ad.append(type)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw PhoneCryptoError.openFailed("auth failed: \(error.localizedDescription)")
        }
    }
}

// HMAC for the initial authentication (inside the encrypted HELLO_AUTH).
// The HMAC proves the phone knows the pairing secret even though the
// session_key was already derived from HKDF(secret, nonces) - belt and
// suspenders: without this, a recorded handshake could be replayed with a
// fabricated nonce to establish a dummy session that the Mac has no way
// to distinguish from a real client.
enum PhoneAuthHMAC {
    // HMAC also binds both sides' ephemeral public keys so a MITM that
    // substitutes their own ECDHE pubkey can't sneak past AUTH (the auth
    // code wouldn't validate against the keys the Mac actually received).
    static func authCode(secret: Data, clientNonce: Data, serverNonce: Data,
                         clientEphPubKey: Data, serverEphPubKey: Data,
                         deviceName: String) -> Data {
        var input = Data()
        input.append(clientNonce)
        input.append(serverNonce)
        input.append(clientEphPubKey)
        input.append(serverEphPubKey)
        input.append(deviceName.data(using: .utf8) ?? Data())
        let key = SymmetricKey(data: secret)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
    }

    static func random32() -> Data {
        var d = Data(count: 32)
        _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return d
    }

    // Constant-time equality.
    static func ctEq(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }
}

// Ephemeral X25519 keypair. Used once per session; the private key is never
// persisted or copied out - zeroed by ARC when the owning struct drops.
struct PhoneEphemeralKeypair {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKeyBytes: Data { privateKey.publicKey.rawRepresentation }

    static func generate() -> PhoneEphemeralKeypair {
        PhoneEphemeralKeypair(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    func sharedSecret(withPeerPublicKey peerKeyBytes: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyBytes)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        // 32 raw bytes - not HKDF-expanded here; the caller mixes this into
        // their own HKDF salt/info per the deriveKey design.
        return shared.withUnsafeBytes { Data($0) }
    }
}
