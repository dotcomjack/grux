#!/usr/bin/env swift

// phone-sim-harness.swift
//
// Pretends to be the GruxPhone iOS app, end-to-end. Connects to the Mac
// receiver at a given host:port, HMAC-auths with the supplied secret, sends
// N synthetic audio frames (160-sample 16 kHz PCM16, 440 Hz tone), then
// closes cleanly. Exits non-zero with a clear reason if anything fails.
//
// Usage:
//   swift phone-sim-harness.swift <grux-pair URL> [--frames 200]
// Example:
//   swift phone-sim-harness.swift "grux-pair://v1?secret=...&host=Jacks-MacBook-Pro.local&port=64493&name=mac"
//
// Output:
//   stdout: one-line status per 10 frames
//   exit 0 on AUTH_OK + all frames sent
//   exit 2 on AUTH_FAIL / timeout
//   exit 3 on wire errors

import Foundation
import Network
import CryptoKit

// MARK: - Wire format (byte-identical to PhoneProtocol.swift)

enum PhoneWire {
    static let magic: [UInt8] = [0x47, 0x52, 0x55, 0x58]
    static let version: UInt8 = 0x01
    enum MsgType: UInt8 {
        case helloAuth = 0x01
        case authOK = 0x02
        case authFail = 0x03
        case audioFrame = 0x10
        case bye = 0xFF
    }
    static let sampleRate: Int = 16_000
    static let samplesPerFrame: Int = 160
}

func encodeFrame(type: PhoneWire.MsgType, payload: Data) -> Data {
    var out = Data()
    out.append(contentsOf: PhoneWire.magic)
    out.append(PhoneWire.version)
    out.append(type.rawValue)
    var lenBE = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &lenBE) { out.append(contentsOf: $0) }
    out.append(payload)
    return out
}

func parsePairURL(_ raw: String) -> (secret: Data, host: String, port: UInt16)? {
    guard let url = URL(string: raw), url.scheme == "grux-pair",
          let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let items = comps.queryItems else { return nil }
    func q(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
    guard let s = q("secret"), let h = q("host"),
          let pStr = q("port"), let p = UInt16(pStr) else { return nil }
    var padded = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while padded.count % 4 != 0 { padded += "=" }
    guard let secret = Data(base64Encoded: padded) else { return nil }
    return (secret, h, p)
}

// MARK: - Sine-tone PCM frame

func makeToneFrame(seq: UInt32, phase: inout Double) -> Data {
    let n = PhoneWire.samplesPerFrame
    var samples = [Int16](repeating: 0, count: n)
    let step = 2.0 * .pi * 440.0 / Double(PhoneWire.sampleRate)
    for i in 0..<n {
        let v = sin(phase) * 0.25
        samples[i] = Int16(clamping: Int(v * Double(Int16.max)))
        phase += step
        if phase > 2 * .pi { phase -= 2 * .pi }
    }
    var payload = Data()
    var seqBE = seq.bigEndian
    withUnsafeBytes(of: &seqBE) { payload.append(contentsOf: $0) }
    var srBE = UInt16(PhoneWire.sampleRate).bigEndian
    withUnsafeBytes(of: &srBE) { payload.append(contentsOf: $0) }
    var nBE = UInt16(n).bigEndian
    withUnsafeBytes(of: &nBE) { payload.append(contentsOf: $0) }
    samples.withUnsafeBufferPointer { buf in
        payload.append(contentsOf: UnsafeRawBufferPointer(buf))
    }
    return encodeFrame(type: .audioFrame, payload: payload)
}

// MARK: - Main

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: phone-sim-harness.swift <grux-pair URL> [--frames N]\n", stderr)
    exit(1)
}
let rawURL = CommandLine.arguments[1]
let framesToSend: Int = {
    if let idx = CommandLine.arguments.firstIndex(of: "--frames"),
       idx + 1 < CommandLine.arguments.count,
       let n = Int(CommandLine.arguments[idx + 1]) { return n }
    return 200
}()

guard let parsed = parsePairURL(rawURL) else {
    fputs("error: bad pair URL\n", stderr)
    exit(1)
}
print("pair: host=\(parsed.host) port=\(parsed.port) secret=\(parsed.secret.count)B")

let endpoint = NWEndpoint.hostPort(host: .init(parsed.host), port: .init(rawValue: parsed.port)!)
let params = NWParameters.tcp
let conn = NWConnection(to: endpoint, using: params)

struct AuthFailure: Error { let reason: String }
let authed = DispatchSemaphore(value: 0)
var authResult: Result<Void, AuthFailure> = .failure(AuthFailure(reason: "did not complete"))
var inbound = Data()

func handleInbound(_ data: Data) {
    inbound.append(data)
    while inbound.count >= 10 {
        let magic = Array(inbound.prefix(4))
        guard magic == PhoneWire.magic else {
            authResult = .failure(AuthFailure(reason: "bad magic on reply"))
            authed.signal()
            return
        }
        let ver = inbound[inbound.startIndex + 4]
        guard ver == PhoneWire.version else {
            authResult = .failure(AuthFailure(reason: "bad version"))
            authed.signal()
            return
        }
        let typeRaw = inbound[inbound.startIndex + 5]
        let lenBytes = inbound.subdata(in: (inbound.startIndex + 6)..<(inbound.startIndex + 10))
        let length = Int(UInt32(bigEndian: lenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard inbound.count >= 10 + length else { return }
        let payload = inbound.subdata(in: (inbound.startIndex + 10)..<(inbound.startIndex + 10 + length))
        inbound.removeFirst(10 + length)
        switch typeRaw {
        case PhoneWire.MsgType.authOK.rawValue:
            print("< AUTH_OK")
            authResult = .success(())
            authed.signal()
        case PhoneWire.MsgType.authFail.rawValue:
            let reason = String(data: payload, encoding: .utf8) ?? "unknown"
            authResult = .failure(AuthFailure(reason: "AUTH_FAIL: \(reason)"))
            authed.signal()
        default:
            print("< unknown type 0x\(String(typeRaw, radix: 16))")
        }
    }
}

func receiveLoop() {
    conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, err in
        if let data, !data.isEmpty { handleInbound(data) }
        if err != nil || isComplete { return }
        receiveLoop()
    }
}

conn.stateUpdateHandler = { st in
    switch st {
    case .ready:
        print("> connected")
        receiveLoop()
        // Build HELLO_AUTH
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let deviceName = "harness-cli"
        var input = Data()
        input.append(nonce)
        input.append(deviceName.data(using: .utf8)!)
        let key = SymmetricKey(data: parsed.secret)
        let mac = HMAC<SHA256>.authenticationCode(for: input, using: key)
        var helloPayload = Data()
        helloPayload.append(nonce)
        helloPayload.append(Data(mac))
        helloPayload.append(deviceName.data(using: .utf8)!)
        let hello = encodeFrame(type: .helloAuth, payload: helloPayload)
        print("> sending HELLO_AUTH (\(hello.count)B)")
        conn.send(content: hello, completion: .contentProcessed { err in
            if let err { print("send HELLO err: \(err)") }
        })
    case .failed(let err):
        authResult = .failure(AuthFailure(reason: "connection failed: \(err)"))
        authed.signal()
    case .cancelled:
        break
    default:
        break
    }
}

conn.start(queue: .global())

let waited = authed.wait(timeout: .now() + 10)
switch waited {
case .timedOut:
    fputs("TIMEOUT waiting for AUTH reply (10s)\n", stderr)
    exit(2)
case .success:
    break
}

switch authResult {
case .failure(let fail):
    fputs("AUTH failed: \(fail.reason)\n", stderr)
    exit(2)
case .success:
    break
}

print("> auth OK, sending \(framesToSend) audio frames at 100 fps…")
var phase = 0.0
let sendSem = DispatchSemaphore(value: 0)
var sendErrors = 0
for i in 0..<framesToSend {
    let frame = makeToneFrame(seq: UInt32(i + 1), phase: &phase)
    conn.send(content: frame, completion: .contentProcessed { err in
        if err != nil { sendErrors += 1 }
        sendSem.signal()
    })
    _ = sendSem.wait(timeout: .now() + 1)
    if (i + 1) % 25 == 0 {
        print("  \(i + 1) frames sent")
    }
    // 10ms pacing
    Thread.sleep(forTimeInterval: 0.010)
}
print("> sent \(framesToSend) frames (\(sendErrors) errors)")

// Tiny settle time so recv side drains.
Thread.sleep(forTimeInterval: 0.4)
let bye = encodeFrame(type: .bye, payload: Data())
conn.send(content: bye, completion: .contentProcessed { _ in })
Thread.sleep(forTimeInterval: 0.2)
conn.cancel()
print("done")
exit(sendErrors == 0 ? 0 : 3)
