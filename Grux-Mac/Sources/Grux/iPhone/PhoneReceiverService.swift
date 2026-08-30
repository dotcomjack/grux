import Foundation
import Network
import AppKit
import OSLog

// NWListener running an HTTP+WebSocket endpoint on <this-mac>.local:<port>,
// reachable from the same network only. There is no tunnel in front of it:
// CloudflareTunnelManager is inert, so pairing over cellular or from another
// network is not supported.
//
// Handshake:
//   1. Phone opens WebSocket to ws://<this-mac>.local:<port>/ws
//   2. Phone → Mac: SESSION_INIT { 32B clientNonce }      (plaintext binary WS msg)
//   3. Mac → Phone: SESSION_READY { 32B serverNonce }     (plaintext)
//   4. Both derive session_key = HKDF(hmac_secret, clientNonce||serverNonce)
//   5. Phone → Mac: HELLO_AUTH { HMAC(secret, nonces||deviceName) || deviceName }  (encrypted)
//   6. Mac verifies HMAC constant-time → AUTH_OK (encrypted) or AUTH_FAIL
//   7. Audio frames, location, TTS audio all encrypted.
//
// Single connection at a time. A second connection gets AUTH_FAIL (even on
// the handshake) and is closed.

@MainActor
final class PhoneReceiverService {
    static let shared = PhoneReceiverService()

    private let log = Logger(subsystem: "com.gruxai.grux", category: "PhoneRx")

    // Port the listener bound on the local network. Zero = listener will pick.
    private(set) var localPort: UInt16 = 0

    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private var crypto: PhoneSessionCrypto?
    private var clientNonce = Data()
    private var serverNonce = Data()
    private var serverEphKeypair: PhoneEphemeralKeypair?
    private var clientEphPubKey = Data()
    private var authed: Bool = false
    private var authedDeviceName: String = ""
    // Rate-limit AUTH_FAIL responses: each failure inserts a growing delay
    // before the Mac sends AUTH_FAIL + closes. Resets on successful AUTH_OK.
    private var consecutiveAuthFailures: Int = 0
    private var lastAuthFailureAt: Date = .distantPast

    // TTS fan-out subscription handles.
    private var ttsPCMToken: UUID?
    private var ttsEventToken: UUID?
    private var ttsOutSeq: UInt32 = 0
    private var ttsRemainder: [Int16] = []   // leftover samples between chunks for even framing

    // Chat bridge (one per authenticated session).
    private var chatBridge: PhoneChatBridge?

    private init() {}

    func start() {
        guard listener == nil else { return }
        _ = PhonePairing.ensureSecret()

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = Int(PhoneWire.maxPayloadBytes)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Binds the local network, not just loopback. This USED to be
        // `requiredInterfaceType = .loopback`, which was correct only while
        // cloudflared fronted us: the phone reached a public
        // *.trycloudflare.com URL and loopback kept LAN hosts from connecting
        // directly.
        //
        // With the tunnel gutted, keeping loopback would not harden anything,
        // it would kill the feature: the pairing QR advertises this Mac's
        // Bonjour name, and a loopback listener refuses every connection that
        // is not from this Mac. Dead QR, dead toggle.
        //
        // Net exposure goes DOWN, not up. Before: anyone on the internet
        // holding the ephemeral tunnel URL could open a TCP connection to this
        // listener. Now: only devices on the same network can. The old comment
        // read as if loopback were the security boundary; the public ingress
        // sitting in front of it was the real one.
        //
        // What still guards the socket, unchanged: a 32B pairing secret, a
        // constant-time HMAC check before any audio is accepted, one
        // connection at a time, and growing delays on repeated AUTH_FAIL.
        // Protocol stack: TCP → WebSocket.
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        let listener: NWListener
        do {
            // Let the kernel pick a free port.
            listener = try NWListener(using: params, on: .any)
        } catch {
            log.error("NWListener init failed: \(String(describing: error), privacy: .public)")
            PhoneReceiverState.shared.lastError = "Listener init: \(error.localizedDescription)"
            return
        }

        listener.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in self?.handleListenerState(st) }
        }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in self?.accept(conn) }
        }
        listener.start(queue: .global(qos: .userInitiated))
        self.listener = listener
    }

    func stop() {
        activeConnection?.cancel()
        activeConnection = nil
        listener?.cancel()
        listener = nil
        localPort = 0
        PhoneReceiverState.shared.isRunning = false
        PhoneReceiverState.shared.isConnected = false
        PhoneReceiverState.shared.connectedDevice = ""
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let p = listener?.port {
                localPort = p.rawValue
                PhoneReceiverState.shared.listenerPort = p.rawValue
                log.log("WS listener ready on local network :\(p.rawValue, privacy: .public)")
                // Inert: logs that there is no cloud path and returns. Kept so
                // spawn, if it ever comes back, comes back at this one site.
                CloudflareTunnelManager.shared.start(forwardingTo: p.rawValue)
                PhoneReceiverState.shared.isRunning = true
            }
        case .failed(let err):
            log.error("listener failed: \(String(describing: err), privacy: .public)")
            PhoneReceiverState.shared.lastError = "Listener failed: \(err.localizedDescription)"
            PhoneReceiverState.shared.isRunning = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.listener = nil
                self?.start()
            }
        case .cancelled:
            PhoneReceiverState.shared.isRunning = false
        default:
            break
        }
    }

    private func accept(_ conn: NWConnection) {
        if activeConnection != nil {
            log.log("rejecting concurrent connection from \(String(describing: conn.endpoint), privacy: .public)")
            conn.start(queue: .global(qos: .userInitiated))
            conn.cancel()
            return
        }
        activeConnection = conn
        crypto = nil
        authed = false
        clientNonce = Data()
        serverNonce = Data()
        clientEphPubKey = Data()
        serverEphKeypair = nil
        authedDeviceName = ""

        conn.stateUpdateHandler = { [weak self] st in
            Task { @MainActor in self?.handleConnState(conn, st) }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receiveNext(conn)
    }

    private func handleConnState(_ conn: NWConnection, _ st: NWConnection.State) {
        switch st {
        case .ready:
            log.log("ws conn ready: \(String(describing: conn.endpoint), privacy: .public)")
        case .failed(let err):
            log.error("ws conn failed: \(String(describing: err), privacy: .public)")
            PhoneReceiverState.shared.lastError = "Phone conn failed: \(err.localizedDescription)"
            teardown()
        case .cancelled:
            teardown()
        default: break
        }
    }

    private func teardown() {
        if let t = ttsPCMToken { TTSBroadcaster.shared.unsubscribe(t) }
        if let t = ttsEventToken { TTSBroadcaster.shared.unsubscribe(t) }
        ttsPCMToken = nil
        ttsEventToken = nil
        ttsRemainder = []
        ttsOutSeq = 0
        chatBridge = nil
        // Items 25+28: stop pushing continuity surfaces once the phone drops.
        // The next session re-arms only after a fresh surfacesSubscribe.
        SurfaceSyncEngine.shared.deactivate()
        // Phase C: same rule for Foundry install-approval pushes. The next
        // session re-arms only after a fresh approvalsSubscribe.
        FoundryApprovalSync.shared.deactivate()
        activeConnection?.cancel()
        activeConnection = nil
        crypto = nil
        authed = false
        authedDeviceName = ""
        PhoneReceiverState.shared.isConnected = false
        PhoneReceiverState.shared.connectedDevice = ""
    }

    private func receiveNext(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let err = error {
                    self.log.error("ws receive err: \(String(describing: err), privacy: .public)")
                    self.teardown()
                    return
                }
                if isComplete && data == nil { self.teardown(); return }
                if let data {
                    PhoneReceiverState.shared.noteBytes(data.count)
                    do {
                        try self.handleMessage(conn: conn, data: data, context: context)
                    } catch {
                        self.log.error("msg handling failed: \(String(describing: error), privacy: .public)")
                        self.teardown()
                        return
                    }
                }
                self.receiveNext(conn)
            }
        }
    }

    private func handleMessage(conn: NWConnection, data: Data, context: NWConnection.ContentContext?) throws {
        // Ignore non-binary framed noise.
        if let meta = context?.protocolMetadata.first(where: { $0 is NWProtocolWebSocket.Metadata })
            as? NWProtocolWebSocket.Metadata, meta.opcode != .binary && meta.opcode != .text {
            return
        }
        let frame = try PhoneFrameCodec.decode(data)

        if PhoneFrameCodec.plaintextTypes.contains(frame.type) {
            try handlePlaintext(conn: conn, frame: frame)
            return
        }
        // Encrypted frames require an established session.
        guard let crypto else {
            throw PhoneFrameError.cryptoFailed("encrypted frame before session")
        }
        let plain = try crypto.open(type: frame.type.rawValue, wireBody: frame.payload)
        try handleEncrypted(conn: conn, type: frame.type, payload: plain)
    }

    private func handlePlaintext(conn: NWConnection, frame: PhoneFrame) throws {
        switch frame.type {
        case .sessionInit:
            let p = try SessionInitPayload.decode(frame.payload)
            guard let secret = PhonePairing.secret() else {
                sendBye(conn); throw PhoneFrameError.cryptoFailed("no pairing secret")
            }
            clientNonce = p.clientNonce
            clientEphPubKey = p.clientEphPubKey
            serverNonce = PhoneAuthHMAC.random32()
            let kp = PhoneEphemeralKeypair.generate()
            serverEphKeypair = kp
            let ecdheShared: Data
            do {
                ecdheShared = try kp.sharedSecret(withPeerPublicKey: clientEphPubKey)
            } catch {
                log.error("ECDHE failed: \(String(describing: error), privacy: .public)")
                sendBye(conn); throw PhoneFrameError.cryptoFailed("ecdhe")
            }
            let sessionKey = PhoneSessionCrypto.deriveKey(
                ecdheShared: ecdheShared, pairingSecret: secret,
                clientNonce: clientNonce, serverNonce: serverNonce
            )
            crypto = PhoneSessionCrypto(key: sessionKey, sendDir: .macToPhone)
            let outPayload = SessionReadyPayload(
                serverNonce: serverNonce, serverEphPubKey: kp.publicKeyBytes
            ).encode()
            sendPlain(conn, type: .sessionReady, payload: outPayload)
            log.log("session key derived (ECDHE + pairing); awaiting HELLO_AUTH")
        default:
            throw PhoneFrameError.malformed("unexpected plaintext \(frame.type.rawValue)")
        }
    }

    private func handleEncrypted(conn: NWConnection, type: PhoneWire.MsgType, payload: Data) throws {
        switch type {
        case .helloAuth:
            try handleHello(conn: conn, payload: payload)
        case .audioFrame16k:
            guard authed else { throw PhoneFrameError.cryptoFailed("pre-auth audio") }
            try ingestMicAudio(payload: payload)
        case .location:
            guard authed else { return }
            if let loc = try? LocationPayload.decode(payload) {
                log.debug("loc \(loc.latitude, privacy: .public),\(loc.longitude, privacy: .public)")
            }
        case .chatEnvelope:
            guard authed else { return }
            if let env = try? ChatEnvelope.decode(payload) {
                chatBridge?.handle(env)
            } else {
                // Second tagged-union on the 0x40 frame: continuity surfaces
                // (items 25+28). Activation only ever happens here, after the
                // phone announces capability via surfacesSubscribe, so old
                // phone builds never receive surface pushes.
                let handled = SurfaceSyncInbound.handle(payload) { [weak self] data in
                    guard let self, let conn = self.activeConnection, self.authed else { return }
                    self.sendEncrypted(conn, type: .chatEnvelope, payload: data)
                }
                if !handled {
                    // Third tagged-union on the 0x40 frame: Foundry install
                    // approvals (Phase C). Activation only happens after
                    // approvalsSubscribe, so old phone builds never receive
                    // approval pushes.
                    FoundryApprovalSyncInbound.handle(payload) { [weak self] data in
                        guard let self, let conn = self.activeConnection, self.authed else { return }
                        self.sendEncrypted(conn, type: .chatEnvelope, payload: data)
                    }
                }
            }
        case .bye:
            teardown()
        default:
            log.log("unexpected post-auth type \(type.rawValue, privacy: .public)")
        }
    }

    private func handleHello(conn: NWConnection, payload: Data) throws {
        let hello = try HelloAuthPayload.decode(payload)
        guard let secret = PhonePairing.secret() else {
            sendAuthFailWithDelay(conn, reason: "no secret")
            return
        }
        guard let serverKp = serverEphKeypair, !clientEphPubKey.isEmpty else {
            sendAuthFailWithDelay(conn, reason: "handshake incomplete")
            return
        }
        let expected = PhoneAuthHMAC.authCode(
            secret: secret, clientNonce: clientNonce, serverNonce: serverNonce,
            clientEphPubKey: clientEphPubKey, serverEphPubKey: serverKp.publicKeyBytes,
            deviceName: hello.deviceName
        )
        guard PhoneAuthHMAC.ctEq(expected, hello.authHmac) else {
            log.error("HMAC mismatch from \(hello.deviceName, privacy: .public)")
            sendAuthFailWithDelay(conn, reason: "bad hmac")
            return
        }
        authed = true
        authedDeviceName = hello.deviceName
        // Success resets the throttle so a legitimate reconnection never
        // inherits someone else's failure backoff.
        consecutiveAuthFailures = 0
        PhoneReceiverState.shared.isConnected = true
        PhoneReceiverState.shared.connectedDevice = hello.deviceName
        // The only place in the app that can honestly say a phone paired. A
        // verified HMAC means a device is holding the secret this Mac minted,
        // which is the whole claim `step.phone_paired` makes. Nothing else is
        // evidence: the secret's mere existence in the Keychain proves only
        // that Grux generated one for itself, which it does on first start
        // with no phone anywhere near it.
        CapabilityResolver.markStepCompleted(.stepPhonePaired)
        sendEncrypted(conn, type: .authOK, payload: Data())
        log.log("AUTH_OK \(hello.deviceName, privacy: .public)")

        // Wire TTS fan-out: when SpeechEngine feeds PCM, we chunk + encrypt + send.
        ttsPCMToken = TTSBroadcaster.shared.subscribePCM { [weak self] data, sr in
            Task { @MainActor in self?.shipTTS(data: data, sampleRate: sr) }
        }
        ttsEventToken = TTSBroadcaster.shared.subscribeEvents { [weak self] starting in
            Task { @MainActor in self?.shipTTSEvent(starting: starting) }
        }
        // Chat bridge: mirrors Mac chat state to the phone and routes
        // envelopes both directions. Creating it kicks a full sync.
        chatBridge = PhoneChatBridge(receiver: self)
    }

    private func ingestMicAudio(payload: Data) throws {
        let frame = try AudioFramePayload.decode(payload, sampleRate: PhoneWire.micSampleRate)
        PhoneReceiverState.shared.audioFramesReceived += 1
        PhoneReceiverState.shared.lastFrameAt = Date()
        // Int16 → Float32, append to AmbientAudioRing.
        let n = frame.samples.count
        var floats = [Float](repeating: 0, count: n)
        for i in 0..<n { floats[i] = Float(frame.samples[i]) / 32768.0 }
        floats.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { AmbientAudioRing.shared.append(base, count: n) }
        }
    }

    // MARK: - Outbound

    private func sendPlain(_ conn: NWConnection, type: PhoneWire.MsgType, payload: Data) {
        let wire = PhoneFrameCodec.encode(type: type, payload: payload)
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let ctx = NWConnection.ContentContext(identifier: "plain", metadata: [meta])
        conn.send(content: wire, contentContext: ctx, isComplete: true,
                  completion: .contentProcessed { _ in })
    }

    private func sendEncrypted(_ conn: NWConnection, type: PhoneWire.MsgType, payload: Data) {
        guard let crypto else { return }
        do {
            let body = try crypto.seal(type: type.rawValue, plaintext: payload)
            let wire = PhoneFrameCodec.encode(type: type, payload: body)
            let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
            let ctx = NWConnection.ContentContext(identifier: "enc", metadata: [meta])
            conn.send(content: wire, contentContext: ctx, isComplete: true,
                      completion: .contentProcessed { _ in })
        } catch {
            log.error("seal failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func sendBye(_ conn: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        conn.send(content: nil, contentContext: ctx, isComplete: true,
                  completion: .contentProcessed { _ in })
    }

    // Exponentially-capped delay + teardown. Defends against online brute-
    // forcing of the pairing secret: even though HMAC-SHA256 with a 32-byte
    // key isn't feasibly brute-forceable, an attacker hammering the endpoint
    // can still waste CPU + bandwidth. Cap at ~4 s so a legitimate user
    // mistyping never gets stuck for too long.
    private func sendAuthFailWithDelay(_ conn: NWConnection, reason: String) {
        consecutiveAuthFailures = min(consecutiveAuthFailures + 1, 8)
        lastAuthFailureAt = Date()
        let delay = min(4.0, 0.25 * pow(2.0, Double(consecutiveAuthFailures - 1)))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self, self.activeConnection === conn else { return }
                self.sendEncrypted(conn, type: .authFail, payload: Data(reason.utf8))
                self.teardown()
            }
        }
    }

    // Called by the "Rotate Secret" UI - drops any live session so the new
    // secret is enforced immediately rather than after the client times out.
    func closeActiveConnectionForRotate() {
        log.log("closing active connection due to secret rotation")
        teardown()
    }

    // MARK: - TTS fan-out

    private func shipTTSEvent(starting: Bool) {
        guard let conn = activeConnection, authed else { return }
        if starting {
            var p = Data(); var ms = UInt32(0).bigEndian
            withUnsafeBytes(of: &ms) { p.append(contentsOf: $0) }
            sendEncrypted(conn, type: .ttsStart, payload: p)
            ttsOutSeq = 0
            ttsRemainder = []
        } else {
            // Flush any remainder samples as a final short frame.
            if !ttsRemainder.isEmpty {
                ttsOutSeq &+= 1
                let frame = AudioFramePayload(
                    seq: ttsOutSeq, samples: ttsRemainder, sampleRate: PhoneWire.ttsSampleRate
                )
                sendEncrypted(conn, type: .ttsAudio24k, payload: frame.encode())
                ttsRemainder = []
            }
            sendEncrypted(conn, type: .ttsEnd, payload: Data())
        }
    }

    private func shipTTS(data: Data, sampleRate: Int) {
        guard let conn = activeConnection, authed else { return }
        // data is PCM_24000 Int16 little-endian. Chunk into ttsSamplesPerFrame
        // (480 samples = 20 ms) frames. Carry remainder between chunks so we
        // never emit a half-sized frame that forces the phone decoder to
        // special-case.
        let countSamples = data.count / 2
        guard countSamples > 0 else { return }
        var buf: [Int16] = ttsRemainder
        buf.reserveCapacity(ttsRemainder.count + countSamples)
        data.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: Int16.self)
            for i in 0..<countSamples { buf.append(base[i]) }
        }
        let frameSize = PhoneWire.ttsSamplesPerFrame
        var offset = 0
        while buf.count - offset >= frameSize {
            let samples = Array(buf[offset..<offset + frameSize])
            offset += frameSize
            ttsOutSeq &+= 1
            let payload = AudioFramePayload(
                seq: ttsOutSeq, samples: samples, sampleRate: sampleRate
            ).encode()
            sendEncrypted(conn, type: .ttsAudio24k, payload: payload)
        }
        ttsRemainder = Array(buf[offset...])
    }

    // Used by PhoneChatBridge to push ChatEnvelope frames over the encrypted
    // channel. Fire-and-forget; if the connection died between the bridge
    // publishing state and us trying to write, the send silently drops.
    func sendChatEnvelope(_ env: ChatEnvelope) {
        guard let conn = activeConnection, authed else { return }
        guard let data = try? env.encode() else { return }
        sendEncrypted(conn, type: .chatEnvelope, payload: data)
    }

    // Push an agent-paused event to the connected phone (no-op if no
    // authenticated session is up). Banner copy lives on the phone side; the
    // Mac just hands over jobId + title + accountLabel.
    func notifyAgentPaused(jobId: String, title: String, accountLabel: String?) {
        let env = ChatEnvelope.agentPaused(
            jobId: jobId,
            title: title,
            accountLabel: accountLabel,
            reason: "authLimitHit",
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        sendChatEnvelope(env)
    }

    // Push a Commands V2 phase-transition event. No-op if no authenticated
    // phone session is connected. Mirrors the agent-paused fan-out path -
    // wire-encrypted via sendChatEnvelope. Payload carries no secrets.
    func notifyPhaseTransitioned(commandId: String, runId: String, phaseName: String,
                                 phaseIndex: Int, totalPhases: Int) {
        let env = ChatEnvelope.phaseTransitioned(
            commandId: commandId,
            runId: runId,
            phaseName: phaseName,
            phaseIndex: phaseIndex,
            totalPhases: totalPhases,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        sendChatEnvelope(env)
    }

    // Push the live Social Ops grid to a paired phone. No-op if no
    // authenticated phone session is connected. Mirrors notifyPhaseTransitioned:
    // builds the envelope, stamps it with the current unix-millis time, and
    // hands it to sendChatEnvelope. Payload carries no secrets, only the
    // brand × platform health grid.
    func notifySocialOpsPanel(records: [SocialHealthRecord]) {
        let env = ChatEnvelope.socialOpsPanelSnapshot(
            generatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            records: records
        )
        sendChatEnvelope(env)
    }

    // Acknowledge a phone-issued operator action with its human-readable result,
    // so the phone can toast the outcome and persist a per-cell last-action line.
    // brand/platform are empty for a global action (sweep). No-op if unpaired.
    func notifySocialOpsAck(brand: String, platform: String, status: String, message: String) {
        let env = ChatEnvelope.socialOpsAck(
            brand: brand, platform: platform, status: status, message: message,
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        sendChatEnvelope(env)
    }

    // Push an account-blocker event so the user sees actionable copy +
    // an open-able URL on the phone. Banner copy lives on the phone side.
    func notifyAccountBlocker(projectName: String, actionURL: String, actionText: String) {
        let env = ChatEnvelope.agentPaused(
            jobId: "asc-blocker:\(projectName)",
            title: "Action needed for \(projectName): \(actionText)",
            accountLabel: actionURL,
            reason: "ascAccountBlocker",
            ts: Int64(Date().timeIntervalSince1970 * 1000)
        )
        sendChatEnvelope(env)
    }

    // For logging / diag only.
    func relayPartialTranscript(_ text: String, seq: UInt32) {
        guard let conn = activeConnection, authed else { return }
        var payload = Data()
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { payload.append(contentsOf: $0) }
        payload.append(text.data(using: .utf8) ?? Data())
        sendEncrypted(conn, type: .partialTx, payload: payload)
        PhoneReceiverState.shared.latestTranscript = text
    }
}
