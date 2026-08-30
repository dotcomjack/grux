import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// "Pair iPhone" window content. Shows a QR that encodes the Bonjour host,
// listener port, 32B shared secret (base64url), and a human-readable Mac
// name. Phone scans it, stores the secret in its iOS Keychain, and begins
// advertising its willingness to stream to Bonjour `_grux-phone._tcp`.
struct PhonePairingView: View {
    @ObservedObject private var state = PhoneReceiverState.shared
    @ObservedObject private var app = AppState.shared
    @State private var secretRotateTick = 0

    var body: some View {
        Group {
            if app.config.phoneCompanionEnabled {
                pairingBody
            } else {
                disabledBody
            }
        }
        .padding(22)
        .frame(width: 380, height: 560)
        .onAppear {
            // Same switch that gates the launch path, because opening this
            // window is a request to SEE the pairing code and not consent to
            // start listening. Without the guard the window is a second, ungated
            // way to bind a socket on every interface, and it would leave the
            // Settings toggle reading off while Grux listened.
            guard app.config.phoneCompanionEnabled else { return }
            PhoneReceiverService.shared.start()
        }
    }

    private var disabledBody: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text("Phone companion is off")
                .font(.system(size: 15, weight: .semibold))
            Text("Grux is not listening for a phone, so there is no code to scan yet. "
                 + "Turn it on in Settings, under Data & Capabilities, in the Grux Phone "
                 + "companion section, then relaunch Grux and open this window again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("It stays a local network feature. Your phone has to be on the same "
                 + "network as this Mac: Grux never publishes a public address for it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Done") {
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
    }

    private var pairingBody: some View {
        VStack(spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: state.isConnected ? "iphone.gen3.radiowaves.left.and.right" : "iphone.gen3")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(state.isConnected ? .green : .secondary)
                Text(state.isConnected ? "Connected: \(state.connectedDevice)"
                     : state.isRunning ? "Waiting for iPhone…"
                     : "Phone receiver is off")
                    .font(.system(size: 14, weight: .semibold))
            }

            if let img = qrImage() {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .background(Color.white)
                    .cornerRadius(14)
                    .shadow(radius: 6, y: 3)
            } else {
                ProgressView("Preparing QR…").frame(width: 260, height: 260)
            }

            VStack(alignment: .leading, spacing: 6) {
                row("Reach", "This network only")
                row("Address", state.listenerPort == 0
                    ? "starting…"
                    : "ws://\(PhonePairing.localHostname()):\(state.listenerPort)")
                row("E2EE", "ChaCha20-Poly1305")
                if state.isConnected {
                    row("Frames", "\(state.audioFramesReceived) @ \(String(format: "%.1f", state.recentKilobytesPerSecond)) KB/s")
                }
                if !state.latestTranscript.isEmpty {
                    row("Heard", String(state.latestTranscript.prefix(64)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)

            HStack(spacing: 10) {
                DestructiveButton(
                    "Rotate Secret",
                    question: "Rotate the pairing secret?",
                    detail: "Your current phone pairing stops working immediately and you will "
                        + "need to scan a fresh code on the phone to reconnect. Do this if you "
                        + "think the old secret was exposed.",
                    confirmLabel: "Rotate secret"
                ) {
                    // Kick the current phone off immediately so it can't keep
                    // streaming with the now-revoked key. Then generate a
                    // fresh 32B secret; QR re-encodes automatically via the
                    // secretRotateTick dependency.
                    PhoneReceiverService.shared.closeActiveConnectionForRotate()
                    _ = PhonePairing.reset()
                    _ = PhonePairing.ensureSecret()
                    secretRotateTick &+= 1
                }
                .buttonStyle(.bordered)
                Button("Copy Link") {
                    if let url = pairingURL()?.url {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
                Button("Done") {
                    NSApp.keyWindow?.close()
                }
                .buttonStyle(.borderedProminent)
            }

            // Kept to roughly the two lines this said before. The window is a
            // FIXED 380x560, so copy that grows here pushes the buttons off the
            // bottom with nothing to scroll. The "why" lives in the Reach row.
            Text("Install Grux Phone on your iPhone and tap ‘Scan Mac QR’. It has to be on this "
                 + "network: Grux never opens a public address to your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(size: 12, design: .monospaced)).lineLimit(1)
        }
    }

    private func pairingURL() -> PhonePairingURL.Info? {
        _ = secretRotateTick   // dependency so View recomputes after rotate
        guard let secret = PhonePairing.secret() else { return nil }
        // A LAN ws:// address, and only once the listener has reported the port
        // it actually bound. Substituting a placeholder port would encode a QR
        // that scans cleanly and then fails to connect with nothing on screen
        // to explain it, which is worse than the "Preparing QR" the caller
        // already shows while this returns nil.
        guard state.listenerPort != 0 else { return nil }
        let wss = "ws://\(PhonePairing.localHostname()):\(state.listenerPort)/ws"
        return PhonePairingURL.Info(
            secretBase64URL: PhonePairingURL.base64URLEncode(secret),
            wssURL: wss,
            name: PhonePairing.displayName()
        )
    }

    private func qrImage() -> NSImage? {
        guard let info = pairingURL() else { return nil }
        let url = info.url.absoluteString
        let ctx = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = CGAffineTransform(scaleX: 12, y: 12)
        let scaled = output.transformed(by: scale)
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: 260, height: 260))
    }
}
