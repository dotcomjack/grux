import Foundation
import Combine
import UIKit
import CryptoKit

// WebSocket client over wss://<cloudflared>.trycloudflare.com/ws with an
// app-layer ChaCha20-Poly1305 session so the Cloudflare edge sees only
// ciphertext. Auto-reconnect with jittered backoff. Mic frames encrypted and
// sent up; TTS frames decrypted and handed to TTSPlayer.

@MainActor
final class TransportService: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    static let shared = TransportService()

    enum State: Equatable {
        case idle
        case dialing(host: String)
        case handshaking
        case authenticating
        case streaming
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var lastTranscript: String = ""
    @Published var framesSent: Int = 0
    @Published var framesDropped: Int = 0
    @Published var ttsActive: Bool = false
    @Published var ttsFramesReceived: Int = 0

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var crypto: PhoneSessionCrypto?
    private var clientNonce = Data()
    private var serverNonce = Data()
    private var clientEphKeypair: PhoneEphemeralKeypair?
    private var serverEphPubKey = Data()
    private var cancellables = Set<AnyCancellable>()
    private var reconnectTask: Task<Void, Never>?
    private var shouldStream = false
    private var backoffSeconds: Double = 2
    private var micMutedForTTS = false

    private override init() {
        super.init()
        MicCaptureService.shared.framesPublisher
            .sink { [weak self] frame in self?.sendMicFrame(frame) }
            .store(in: &cancellables)
    }

    // MARK: - Public

    func startStreaming() {
        AppModel.diag("Transport.startStreaming, paired=\(PhoneKeychain.isPaired()) host=\(PhoneKeychain.get(.macHost))")
        guard PhoneKeychain.isPaired() else {
            AppModel.diag("Transport: not paired, aborting")
            state = .failed("Not paired yet"); return
        }
        shouldStream = true
        backoffSeconds = 2
        dial()
    }

    func stopStreaming() {
        shouldStream = false
        reconnectTask?.cancel()
        reconnectTask = nil
        closeTask(code: .goingAway)
        state = .idle
    }

    // MARK: - Dial + handshake

    private func dial() {
        let wss = PhoneKeychain.get(.macHost)
        AppModel.diag("TransportService.dial wss='\(wss)'")
        guard !wss.isEmpty, let url = URL(string: wss) else {
            AppModel.diag("dial FAILED, bad URL: \(wss)")
            state = .failed("Bad pairing URL")
            return
        }
        state = .dialing(host: url.host ?? wss)

        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 0   // no overall cap; we handle reconnect
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        self.session = session

        var req = URLRequest(url: url)
        req.setValue("grux-phone/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.webSocketTask(with: req)
        self.task = task
        task.resume()
        state = .handshaking
        Task { await sendSessionInit() }
        receiveLoop()
    }

    private func sendSessionInit() async {
        clientNonce = PhoneAuthHMAC.random32()
        let kp = PhoneEphemeralKeypair.generate()
        clientEphKeypair = kp
        let payload = SessionInitPayload(
            clientNonce: clientNonce, clientEphPubKey: kp.publicKeyBytes
        ).encode()
        let wire = PhoneFrameCodec.encode(type: .sessionInit, payload: payload)
        do {
            try await task?.send(.data(wire))
        } catch {
            scheduleReconnect(reason: "init send: \(error.localizedDescription)")
        }
    }

    private func sendHelloAuth() async {
        guard let secret = loadPairingSecret() else {
            state = .failed("Missing pairing secret"); return
        }
        guard let kp = clientEphKeypair, !serverEphPubKey.isEmpty else {
            scheduleReconnect(reason: "no ephemeral keypair")
            return
        }
        state = .authenticating
        let deviceName = UIDevice.current.name
        let code = PhoneAuthHMAC.authCode(
            secret: secret, clientNonce: clientNonce, serverNonce: serverNonce,
            clientEphPubKey: kp.publicKeyBytes, serverEphPubKey: serverEphPubKey,
            deviceName: deviceName
        )
        let payload = HelloAuthPayload(authHmac: code, deviceName: deviceName).encode()
        guard let crypto else { return }
        do {
            let body = try crypto.seal(type: PhoneWire.MsgType.helloAuth.rawValue, plaintext: payload)
            let wire = PhoneFrameCodec.encode(type: .helloAuth, payload: body)
            try await task?.send(.data(wire))
        } catch {
            scheduleReconnect(reason: "hello seal: \(error.localizedDescription)")
        }
    }

    // MARK: - Receive

    private func receiveLoop() {
        Task { [weak self] in
            guard let self, let task = self.task else { return }
            do {
                while true {
                    let msg = try await task.receive()
                    switch msg {
                    case .data(let d):
                        await self.handleBinary(d)
                    case .string(let s):
                        if let d = s.data(using: .utf8) { await self.handleBinary(d) }
                    @unknown default: break
                    }
                }
            } catch {
                await MainActor.run {
                    self.scheduleReconnect(reason: "recv: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleBinary(_ data: Data) async {
        do {
            let frame = try PhoneFrameCodec.decode(data)
            if PhoneFrameCodec.plaintextTypes.contains(frame.type) {
                try await handlePlain(frame)
                return
            }
            guard let crypto else { return }
            let plain = try crypto.open(type: frame.type.rawValue, wireBody: frame.payload)
            await handleEncrypted(type: frame.type, payload: plain)
        } catch {
            NSLog("[TransportService] frame error: \(error)")
            await MainActor.run { self.scheduleReconnect(reason: "decode") }
        }
    }

    private func handlePlain(_ frame: PhoneFrame) async throws {
        switch frame.type {
        case .sessionReady:
            let p = try SessionReadyPayload.decode(frame.payload)
            serverNonce = p.serverNonce
            serverEphPubKey = p.serverEphPubKey
            guard let secret = loadPairingSecret() else {
                await MainActor.run { self.state = .failed("No stored secret") }
                return
            }
            guard let kp = clientEphKeypair else {
                await MainActor.run { self.state = .failed("No ephemeral keypair") }
                return
            }
            let ecdheShared: Data
            do {
                ecdheShared = try kp.sharedSecret(withPeerPublicKey: serverEphPubKey)
            } catch {
                await MainActor.run { self.scheduleReconnect(reason: "ecdhe: \(error)") }
                return
            }
            let key = PhoneSessionCrypto.deriveKey(
                ecdheShared: ecdheShared, pairingSecret: secret,
                clientNonce: clientNonce, serverNonce: serverNonce
            )
            await MainActor.run {
                self.crypto = PhoneSessionCrypto(key: key, sendDir: .phoneToMac)
            }
            await sendHelloAuth()
        default:
            throw PhoneFrameError.malformed("unexpected plaintext from mac")
        }
    }

    @MainActor
    private func handleEncrypted(type: PhoneWire.MsgType, payload: Data) async {
        switch type {
        case .authOK:
            state = .streaming
            backoffSeconds = 2
            // Immediately request a full chat sync so the UI paints threads
            // without waiting for any AppState change on the Mac side.
            sendChat(.requestSync)
            // Announce surface capability (items 25+28). Old Macs ignore this
            // unknown envelope type; new Macs start pushing reminders,
            // meetings, notes, and the 7-day agenda. This subscribe is the
            // negotiation gate: no subscribe, no surface pushes.
            sendSurface(.surfacesSubscribe(version: SurfaceWire.version))
            // Announce install-approval capability (Foundry Phase C). Old
            // Macs ignore this unknown envelope type; new Macs start pushing
            // pending install-approval cards. Same negotiation gate as
            // surfaces: no subscribe, no approval pushes.
            sendApproval(.approvalsSubscribe(version: FoundryApprovalWire.version))
        case .authFail:
            let r = String(data: payload, encoding: .utf8) ?? ""
            state = .failed("Auth failed: \(r)")
            shouldStream = false
            closeTask(code: .policyViolation)
        case .ttsStart:
            AppModel.diag("TTS_START received")
            ttsActive = true
            micMutedForTTS = true
            TTSPlayer.shared.start()
        case .ttsEnd:
            AppModel.diag("TTS_END received (frames this burst: \(ttsFramesReceived))")
            ttsActive = false
            micMutedForTTS = false
            TTSPlayer.shared.finish()
        case .ttsAudio24k:
            if let frame = try? AudioFramePayload.decode(payload, sampleRate: PhoneWire.ttsSampleRate) {
                ttsFramesReceived &+= 1
                if ttsFramesReceived % 50 == 0 {
                    AppModel.diag("TTS audio frame count=\(ttsFramesReceived)")
                }
                TTSPlayer.shared.enqueue(frame.samples)
            }
        case .partialTx:
            if payload.count >= 4 {
                let text = String(data: payload.suffix(from: payload.startIndex + 4), encoding: .utf8) ?? ""
                lastTranscript = text
            }
        case .chatEnvelope:
            if let env = try? ChatEnvelope.decode(payload) {
                ChatStore.shared.ingest(env)
            } else if let surf = try? SurfaceEnvelope.decode(payload) {
                // Second tagged-union sharing the 0x40 frame (SurfaceModels).
                SurfaceStore.shared.ingest(surf)
            } else if let appr = try? FoundryApprovalEnvelope.decode(payload) {
                // Third tagged-union: Foundry install approvals (Phase C).
                ApprovalStore.shared.ingest(appr)
            } else {
                AppModel.diag("chat envelope decode failed (\(payload.count)B)")
            }
        case .bye:
            scheduleReconnect(reason: "bye")
        default:
            break
        }
    }

    // MARK: - Send (mic frames)

    private func sendMicFrame(_ payload: AudioFramePayload) {
        guard case .streaming = state, let task, let crypto else {
            framesDropped &+= 1; return
        }
        if micMutedForTTS { return }    // don't transcribe Grux's own voice
        do {
            let bytes = try crypto.seal(
                type: PhoneWire.MsgType.audioFrame16k.rawValue,
                plaintext: payload.encode()
            )
            let wire = PhoneFrameCodec.encode(type: .audioFrame16k, payload: bytes)
            task.send(.data(wire)) { [weak self] err in
                if let err {
                    NSLog("[TransportService] send err: \(err)")
                } else {
                    Task { @MainActor in self?.framesSent &+= 1 }
                }
            }
        } catch {
            framesDropped &+= 1
        }
    }

    func sendLocation(_ loc: LocationPayload) {
        guard case .streaming = state, let task, let crypto else { return }
        do {
            let bytes = try crypto.seal(type: PhoneWire.MsgType.location.rawValue,
                                         plaintext: loc.encode())
            let wire = PhoneFrameCodec.encode(type: .location, payload: bytes)
            task.send(.data(wire)) { _ in }
        } catch { /* drop */ }
    }

    // MARK: - Chat envelope (JSON control plane) --------------------------

    // Ships a ChatEnvelope over the encrypted channel. Called from the
    // ChatView / ChatStore when the user sends, switches threads, etc.
    func sendChat(_ env: ChatEnvelope) {
        guard case .streaming = state, let task, let crypto else {
            AppModel.diag("sendChat dropped, not streaming (state=\(state))")
            return
        }
        guard let data = try? env.encode() else {
            AppModel.diag("sendChat encode failed")
            return
        }
        do {
            let body = try crypto.seal(type: PhoneWire.MsgType.chatEnvelope.rawValue, plaintext: data)
            let wire = PhoneFrameCodec.encode(type: .chatEnvelope, payload: body)
            task.send(.data(wire)) { err in
                if let err { AppModel.diag("sendChat err: \(err.localizedDescription)") }
            }
        } catch {
            AppModel.diag("sendChat seal failed: \(error.localizedDescription)")
        }
    }

    // Ships a SurfaceEnvelope over the same encrypted 0x40 channel. Old Macs
    // decode it as ChatEnvelope, fail, and ignore it silently.
    func sendSurface(_ env: SurfaceEnvelope) {
        guard case .streaming = state, let task, let crypto else {
            AppModel.diag("sendSurface dropped (not streaming, state=\(state))")
            return
        }
        guard let data = try? env.encode() else {
            AppModel.diag("sendSurface encode failed")
            return
        }
        do {
            let body = try crypto.seal(type: PhoneWire.MsgType.chatEnvelope.rawValue, plaintext: data)
            let wire = PhoneFrameCodec.encode(type: .chatEnvelope, payload: body)
            task.send(.data(wire)) { err in
                if let err { AppModel.diag("sendSurface err: \(err.localizedDescription)") }
            }
        } catch {
            AppModel.diag("sendSurface seal failed: \(error.localizedDescription)")
        }
    }

    // Ships a FoundryApprovalEnvelope over the same encrypted 0x40 channel.
    // Old Macs decode it as ChatEnvelope, fail, and ignore it silently.
    func sendApproval(_ env: FoundryApprovalEnvelope) {
        guard case .streaming = state, let task, let crypto else {
            AppModel.diag("sendApproval dropped (not streaming, state=\(state))")
            return
        }
        guard let data = try? env.encode() else {
            AppModel.diag("sendApproval encode failed")
            return
        }
        do {
            let body = try crypto.seal(type: PhoneWire.MsgType.chatEnvelope.rawValue, plaintext: data)
            let wire = PhoneFrameCodec.encode(type: .chatEnvelope, payload: body)
            task.send(.data(wire)) { err in
                if let err { AppModel.diag("sendApproval err: \(err.localizedDescription)") }
            }
        } catch {
            AppModel.diag("sendApproval seal failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Reconnect

    private func closeTask(code: URLSessionWebSocketTask.CloseCode) {
        task?.cancel(with: code, reason: nil)
        task = nil
        crypto = nil
        clientEphKeypair = nil
        serverEphPubKey = Data()
        micMutedForTTS = false
    }

    private func scheduleReconnect(reason: String) {
        guard shouldStream else { return }
        closeTask(code: .abnormalClosure)
        let delay = backoffSeconds + Double.random(in: 0...0.5)
        backoffSeconds = min(backoffSeconds * 1.6, 30)
        NSLog("[TransportService] reconnect in %.1fs (%@)", delay, reason)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, self.shouldStream else { return }
            await MainActor.run { self.dial() }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocolName: String?) {
        AppModel.diag("ws opened proto=\(protocolName ?? "nil")")
    }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let r = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        AppModel.diag("ws closed code=\(closeCode.rawValue) reason='\(r)'")
        Task { @MainActor in self.scheduleReconnect(reason: "closed \(closeCode.rawValue)") }
    }

    // Additional URLSessionDelegate surface for TLS / low-level errors.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            AppModel.diag("urlSessionTask didComplete error: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private func loadPairingSecret() -> Data? {
        let b64 = PhoneKeychain.get(.pairingSecretB64)
        guard !b64.isEmpty else { return nil }
        return Data(base64Encoded: b64)
    }
}
