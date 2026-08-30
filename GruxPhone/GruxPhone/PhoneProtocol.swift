import Foundation
import CryptoKit

// Wire format v2, BYTE-IDENTICAL copy of Grux-Mac's
// Sources/Grux/iPhone/PhoneProtocol.swift. Keep in lockstep.

enum PhoneWire {
    // v3, per-session X25519 ECDHE for forward secrecy.
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
        case chatEnvelope    = 0x40
        case bye             = 0xFF
    }

    static let micSampleRate: Int = 16_000
    static let ttsSampleRate: Int = 24_000
    static let micFrameDurationMs: Int = 10
    static let ttsFrameDurationMs: Int = 20
    static let micSamplesPerFrame: Int = micSampleRate * micFrameDurationMs / 1000
    static let ttsSamplesPerFrame: Int = ttsSampleRate * ttsFrameDurationMs / 1000
}

struct PhoneFrame {
    let type: PhoneWire.MsgType
    let payload: Data
}

enum PhoneFrameError: Error {
    case badVersion(UInt8)
    case unknownType(UInt8)
    case oversizedPayload(Int)
    case malformed(String)
    case cryptoFailed(String)
}

enum PhoneFrameCodec {
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

    static var plaintextTypes: Set<PhoneWire.MsgType> {
        [.sessionInit, .sessionReady]
    }
}

struct SessionInitPayload {
    let clientNonce: Data
    let clientEphPubKey: Data
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
    let serverNonce: Data
    let serverEphPubKey: Data
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
    let authHmac: Data
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
    let sampleRate: Int
    func encode() -> Data {
        var d = Data()
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { d.append(contentsOf: $0) }
        var nBE = UInt16(samples.count).bigEndian
        withUnsafeBytes(of: &nBE) { d.append(contentsOf: $0) }
        samples.withUnsafeBufferPointer { buf in d.append(contentsOf: UnsafeRawBufferPointer(buf)) }
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

enum PhonePairingURL {
    static let scheme = "grux-pair"

    struct Info {
        let secretBase64URL: String
        let wssURL: String
        let name: String
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

    static func base64URLDecode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
