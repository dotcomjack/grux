import Foundation
import CryptoKit

// BYTE-IDENTICAL copy of Grux-Mac's Sources/Grux/iPhone/PhoneCrypto.swift.

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

    static func deriveKey(ecdheShared: Data, pairingSecret: Data,
                          clientNonce: Data, serverNonce: Data) -> SymmetricKey {
        precondition(ecdheShared.count == 32)
        precondition(pairingSecret.count == 32)
        precondition(clientNonce.count == 32 && serverNonce.count == 32)
        var ikm = Data(); ikm.append(ecdheShared); ikm.append(pairingSecret)
        var salt = Data(); salt.append(clientNonce); salt.append(serverNonce)
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm), salt: salt,
            info: Data("grux-phone-v3".utf8), outputByteCount: 32
        )
    }

    private func makeNonce(counter: UInt64, direction: PhoneCryptoDirection) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        bytes[0] = direction.rawValue
        var ctr = counter.bigEndian
        withUnsafeBytes(of: &ctr) { buf in
            for i in 0..<8 { bytes[4 + i] = buf[i] }
        }
        return try ChaChaPoly.Nonce(data: Data(bytes))
    }

    func seal(type: UInt8, plaintext: Data) throws -> Data {
        guard sendCounter < .max else { throw PhoneCryptoError.counterExhausted }
        let counter = sendCounter
        sendCounter &+= 1
        let nonce = try makeNonce(counter: counter, direction: sendDir)
        var ad = Data()
        ad.append(PhoneWire.version)
        ad.append(type)
        let sealed: ChaChaPoly.SealedBox
        do { sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: ad) }
        catch { throw PhoneCryptoError.sealFailed }
        var out = Data()
        var ctrBE = counter.bigEndian
        withUnsafeBytes(of: &ctrBE) { out.append(contentsOf: $0) }
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    func open(type: UInt8, wireBody: Data) throws -> Data {
        guard wireBody.count >= 8 + 16 else { throw PhoneCryptoError.openFailed("too short") }
        let start = wireBody.startIndex
        let ctrBytes = wireBody.subdata(in: start..<(start + 8))
        let counter = UInt64(bigEndian: ctrBytes.withUnsafeBytes { $0.load(as: UInt64.self) })
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

enum PhoneAuthHMAC {
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

    static func ctEq(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<a.count { diff |= a[a.startIndex + i] ^ b[b.startIndex + i] }
        return diff == 0
    }
}

struct PhoneEphemeralKeypair {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    var publicKeyBytes: Data { privateKey.publicKey.rawRepresentation }

    static func generate() -> PhoneEphemeralKeypair {
        PhoneEphemeralKeypair(privateKey: Curve25519.KeyAgreement.PrivateKey())
    }

    func sharedSecret(withPeerPublicKey peerKeyBytes: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyBytes)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        return shared.withUnsafeBytes { Data($0) }
    }
}
