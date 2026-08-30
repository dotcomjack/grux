import Foundation
import CryptoKit

// Wire format v2 - shared by Mac receiver (this file) and iOS companion
// (duplicated verbatim at GruxPhone/GruxPhone/PhoneProtocol.swift).
// If you edit one, edit the other. Byte-for-byte compatible.
//
// Transport: WebSocket binary messages (one PhoneFrame per WS message).
// Encryption: all non-handshake frames carry an AEAD-sealed payload.
//
// Framing (one WS binary message):
//   [1B version][1B type][payload…]
//
// Payload for SESSION_INIT / SESSION_READY: plaintext.
// Payload for every other type (under v2): AEAD ciphertext - see PhoneCrypto.
//
// The 2-byte header (version + type) is authenticated via AEAD "associated
// data" for non-handshake frames, so flipping the type byte won't sneak a
// different semantic past auth.
//
// Types:
//   0xF0 SESSION_INIT     phone → mac   plaintext { clientNonce[32] }
//   0xF1 SESSION_READY    mac → phone   plaintext { serverNonce[32] }
//   -- after handshake, all frames are AEAD-sealed --
//   0x01 HELLO_AUTH       phone → mac   enc { authHmac[32] || deviceNameUTF8 }
//   0x02 AUTH_OK          mac → phone   enc { }
//   0x03 AUTH_FAIL        mac → phone   enc { reasonUTF8 }
//   0x10 AUDIO_FRAME_16K  phone → mac   enc { seq[4] || numSamples[2] || PCM16LE }
//   0x11 LOCATION         phone → mac   enc { lat[8] || lon[8] || hAcc[8] || ts[8] }
//   0x20 PARTIAL_TX       mac → phone   enc { seq[4] || textUTF8 }
//   0x30 TTS_AUDIO_24K    mac → phone   enc { seq[4] || numSamples[2] || PCM16LE }
//   0x31 TTS_START        mac → phone   enc { estimatedMs[4] }  (phone mutes mic)
//   0x32 TTS_END          mac → phone   enc { }                 (phone unmutes mic)
//   0xFF BYE              either dir    enc { }
//
// Sample rates are fixed:  mic (phone→mac) = 16 kHz,  TTS (mac→phone) = 24 kHz.
// Both PCM16 little-endian interleaved, mono.

enum PhoneWire {
    // v3 adds X25519 ephemeral-keypair ECDHE to the session handshake so each
    // session has forward-secret keys - a future leak of the long-term HMAC
    // pairing secret can't retroactively decrypt captured traffic.
    static let version: UInt8 = 0x03
    static let maxPayloadBytes: Int = 512 * 1024

    enum MsgType: UInt8 {
        case sessionInit     = 0xF0
        case sessionReady    = 0xF1
        case helloAuth       = 0x01
        case authOK          = 0x02
        case authFail        = 0x03
        case audioFrame16k   = 0x10
        case location        = 0x11
        case partialTx       = 0x20
        case ttsAudio24k     = 0x30
        case ttsStart        = 0x31
        case ttsEnd          = 0x32
        case chatEnvelope    = 0x40   // JSON ChatEnvelope (Codable) payload
        case bye             = 0xFF
    }

    static let micSampleRate: Int = 16_000
    static let ttsSampleRate: Int = 24_000
    static let micFrameDurationMs: Int = 10           // 160 samples = 320B / frame
    static let ttsFrameDurationMs: Int = 20           // 480 samples = 960B / frame
    static let micSamplesPerFrame: Int = micSampleRate * micFrameDurationMs / 1000
    static let ttsSamplesPerFrame: Int = ttsSampleRate * ttsFrameDurationMs / 1000
}

struct PhoneFrame {
    let type: PhoneWire.MsgType
    let payload: Data     // already AEAD-ciphertext for non-handshake frames
}

enum PhoneFrameError: Error {
    case badVersion(UInt8)
    case unknownType(UInt8)
    case oversizedPayload(Int)
    case malformed(String)
    case cryptoFailed(String)
}

enum PhoneFrameCodec {
    // Encodes a single WS-binary-message-ready buffer.
    static func encode(type: PhoneWire.MsgType, payload: Data) -> Data {
        var out = Data(capacity: 2 + payload.count)
        out.append(PhoneWire.version)
        out.append(type.rawValue)
        out.append(payload)
        return out
    }

    static func decode(_ msg: Data) throws -> PhoneFrame {
        guard msg.count >= 2 else { throw PhoneFrameError.malformed("short frame") }
        let ver = msg[msg.startIndex]
        guard ver == PhoneWire.version else { throw PhoneFrameError.badVersion(ver) }
        let typeRaw = msg[msg.startIndex + 1]
        guard let type = PhoneWire.MsgType(rawValue: typeRaw) else {
            throw PhoneFrameError.unknownType(typeRaw)
        }
        let payload = msg.suffix(from: msg.startIndex + 2)
        return PhoneFrame(type: type, payload: Data(payload))
    }

    // Frames that skip encryption (pre-handshake).
    static var plaintextTypes: Set<PhoneWire.MsgType> {
        [.sessionInit, .sessionReady]
    }
}

// MARK: - Payload codecs (plain - these are the things that get sealed)

struct SessionInitPayload {
    let clientNonce: Data         // 32B random
    let clientEphPubKey: Data     // 32B X25519 ephemeral public key
    func encode() -> Data {
        precondition(clientNonce.count == 32 && clientEphPubKey.count == 32)
        var d = Data(); d.append(clientNonce); d.append(clientEphPubKey); return d
    }
    static func decode(_ d: Data) throws -> SessionInitPayload {
        guard d.count == 64 else { throw PhoneFrameError.malformed("session init != 64B") }
        let s = d.startIndex
        return SessionInitPayload(
            clientNonce: d.subdata(in: s..<(s + 32)),
            clientEphPubKey: d.subdata(in: (s + 32)..<(s + 64))
        )
    }
}

struct SessionReadyPayload {
    let serverNonce: Data         // 32B random
    let serverEphPubKey: Data     // 32B X25519 ephemeral public key
    func encode() -> Data {
        precondition(serverNonce.count == 32 && serverEphPubKey.count == 32)
        var d = Data(); d.append(serverNonce); d.append(serverEphPubKey); return d
    }
    static func decode(_ d: Data) throws -> SessionReadyPayload {
        guard d.count == 64 else { throw PhoneFrameError.malformed("session ready != 64B") }
        let s = d.startIndex
        return SessionReadyPayload(
            serverNonce: d.subdata(in: s..<(s + 32)),
            serverEphPubKey: d.subdata(in: (s + 32)..<(s + 64))
        )
    }
}

struct HelloAuthPayload {
    // authHmac = HMAC-SHA256(hmac_secret, clientNonce || serverNonce || deviceName)
    let authHmac: Data   // 32B
    let deviceName: String
    func encode() -> Data {
        precondition(authHmac.count == 32)
        var d = Data()
        d.append(authHmac)
        d.append(deviceName.data(using: .utf8) ?? Data())
        return d
    }
    static func decode(_ d: Data) throws -> HelloAuthPayload {
        guard d.count >= 32 else { throw PhoneFrameError.malformed("hello < 32B") }
        let hmac = d.subdata(in: d.startIndex..<(d.startIndex + 32))
        let name = String(data: d.suffix(from: d.startIndex + 32), encoding: .utf8) ?? ""
        return HelloAuthPayload(authHmac: hmac, deviceName: name)
    }
}

struct AudioFramePayload {
    let seq: UInt32
    let samples: [Int16]
    let sampleRate: Int   // 16_000 for mic, 24_000 for TTS
    func encode() -> Data {
        var d = Data()
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { d.append(contentsOf: $0) }
        var nBE = UInt16(samples.count).bigEndian
        withUnsafeBytes(of: &nBE) { d.append(contentsOf: $0) }
        samples.withUnsafeBufferPointer { buf in
            d.append(contentsOf: UnsafeRawBufferPointer(buf))
        }
        return d
    }
    static func decode(_ d: Data, sampleRate: Int) throws -> AudioFramePayload {
        guard d.count >= 6 else { throw PhoneFrameError.malformed("audio < 6B") }
        let start = d.startIndex
        let seq = UInt32(bigEndian: d.subdata(in: start..<(start + 4))
            .withUnsafeBytes { $0.load(as: UInt32.self) })
        let n = Int(UInt16(bigEndian: d.subdata(in: (start + 4)..<(start + 6))
            .withUnsafeBytes { $0.load(as: UInt16.self) }))
        guard d.count >= 6 + n * 2 else { throw PhoneFrameError.malformed("audio len mismatch") }
        let pcm = d.subdata(in: (start + 6)..<(start + 6 + n * 2))
        var samples = [Int16](repeating: 0, count: n)
        pcm.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            samples.withUnsafeMutableBufferPointer { dst -> Void in
                _ = memcpy(dst.baseAddress, base, n * 2)
            }
        }
        return AudioFramePayload(seq: seq, samples: samples, sampleRate: sampleRate)
    }
}

struct LocationPayload {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let unixSeconds: Double
    func encode() -> Data {
        var d = Data()
        for v in [latitude, longitude, horizontalAccuracy, unixSeconds] {
            var be = v.bitPattern.bigEndian
            withUnsafeBytes(of: &be) { d.append(contentsOf: $0) }
        }
        return d
    }
    static func decode(_ d: Data) throws -> LocationPayload {
        guard d.count == 32 else { throw PhoneFrameError.malformed("loc != 32B") }
        func readDouble(_ offset: Int) -> Double {
            let slice = d.subdata(in: (d.startIndex + offset)..<(d.startIndex + offset + 8))
            let bits = UInt64(bigEndian: slice.withUnsafeBytes { $0.load(as: UInt64.self) })
            return Double(bitPattern: bits)
        }
        return LocationPayload(latitude: readDouble(0), longitude: readDouble(8),
                               horizontalAccuracy: readDouble(16), unixSeconds: readDouble(24))
    }
}

// MARK: - Pairing URL (v2)

enum PhonePairingURL {
    static let scheme = "grux-pair"

    struct Info {
        let secretBase64URL: String
        let wssURL: String        // full wss://…/ws
        let name: String

        var url: URL {
            var c = URLComponents()
            c.scheme = scheme
            c.host = "v2"
            c.queryItems = [
                URLQueryItem(name: "secret", value: secretBase64URL),
                URLQueryItem(name: "wss", value: wssURL),
                URLQueryItem(name: "name", value: name)
            ]
            return c.url!
        }
    }

    static func parse(_ raw: String) -> Info? {
        guard let url = URL(string: raw),
              url.scheme == scheme,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return nil }
        func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        guard let secret = q("secret"), let wss = q("wss"), let name = q("name") else { return nil }
        return Info(secretBase64URL: secret, wssURL: wss, name: name)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
