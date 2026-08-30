import SwiftUI

// Tabbed root: Chat (remote control) | Mic (stream mic to Mac) | Settings.
// Replaces the old "single-surface" screen. The app is meant to act
// like a cowabunga/coward-for-Claude style remote, with real threads.

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var chatStore = ChatStore.shared

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if app.paired {
                tabs
            } else {
                pairPrompt
            }
            VStack {
                if !app.errorBanner.isEmpty { banner(app.errorBanner).padding(.top, 4) }
                Spacer()
            }
        }
        .fullScreenCover(isPresented: $app.showScanner) { scannerCover }
        .sheet(isPresented: $app.showSettings) { SettingsSheet() }
    }

    private var tabs: some View {
        TabView {
            ChatHomeView()
                .tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right.fill") }

            // Items 25+28: read-only continuity surfaces pushed from the Mac
            // (agenda, reminders, meetings, notes) once the phone subscribes.
            SurfacesView()
                .tabItem { Label("Surfaces", systemImage: "rectangle.stack.fill") }

            MicStreamingView()
                .tabItem { Label("Mic", systemImage: "mic.fill") }

            SettingsSheet()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }

            // Ops is LAST: SwiftUI TabView keys tabs by position, so inserting it
            // before an existing tab would shift the selected index out from under
            // the user. Appending keeps every other tab's position stable.
            if chatStore.socialOpsPanel != nil {
                SocialOpsCockpitView()
                    .tabItem { Label("Ops", systemImage: "dot.radiowaves.left.and.right") }
            }
        }
        .tint(.cyan)
    }

    private var pairPrompt: some View {
        VStack(spacing: 22) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 60, weight: .semibold))
                .foregroundStyle(.cyan)
            Text("Pair with your Mac")
                .font(.system(size: 28, weight: .heavy))
                .multilineTextAlignment(.center)
            Text("Open Grux on your Mac → Pair iPhone, then scan the QR.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            Button { app.showScanner = true } label: {
                HStack {
                    Image(systemName: "camera.viewfinder")
                    Text("Scan Mac QR").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 16)
        }
        .padding(.top, 60)
    }

    private var scannerCover: some View {
        NavigationStack {
            PairingScannerView(
                onScanned: { info in app.handleScannedInfo(info) },
                onError: { msg in
                    app.errorBanner = msg
                    app.showScanner = false
                }
            )
            .ignoresSafeArea()
            .navigationTitle("Scan Mac QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { app.showScanner = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.footnote).foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(10)
            .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 10)
    }
}

// Mic streaming tab, the former main surface. Uses the same streaming
// surface we shipped earlier, just moved into a tab.
struct MicStreamingView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color.cyan.opacity(app.isStreaming ? 0.45 : 0.15), .black],
                center: .center, startRadius: 40, endRadius: 500
            ).ignoresSafeArea()
            VStack(spacing: 22) {
                Text(app.pairedMacName.isEmpty ? "Your Mac" : app.pairedMacName)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 40)

                streamButton
                    .padding(.vertical, 8)

                levelBar

                metricsRow

                if !app.lastTranscript.isEmpty {
                    transcriptCard
                }
                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }

    private var streamButton: some View {
        Button(action: { app.toggleStream() }) {
            ZStack {
                Circle()
                    .fill(app.streamingRequested ? Color.red : Color.cyan)
                    .frame(width: 180, height: 180)
                    .shadow(color: (app.streamingRequested ? Color.red : Color.cyan).opacity(0.5),
                            radius: 30, y: 0)
                VStack(spacing: 4) {
                    Image(systemName: app.streamingRequested ? "stop.fill" : "mic.fill")
                        .font(.system(size: 42, weight: .bold))
                    Text(app.streamingRequested ? "STOP" : "START")
                        .font(.system(size: 14, weight: .heavy)).kerning(2)
                }
                .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
    }

    private var levelBar: some View {
        let normalized = min(1.0, Double(app.micLevel) * 4)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.white.opacity(0.08)).frame(height: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [.cyan, .green, .yellow],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: max(0, 260 * CGFloat(normalized)), height: 8)
        }
        .frame(width: 260)
    }

    private var metricsRow: some View {
        HStack(spacing: 20) {
            metric("UP", "\(app.framesSent)")
            metric("DOWN", "\(app.ttsFramesReceived)")
            metric("HEARD", shortTranscript(app.lastTranscript))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 18, weight: .heavy, design: .monospaced))
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 9, weight: .semibold)).kerning(1)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 70)
    }

    private func shortTranscript(_ s: String) -> String { s.isEmpty ? "-" : String(s.prefix(12)) }

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mac heard:").font(.caption).foregroundStyle(.secondary)
            Text(app.lastTranscript).font(.system(size: 13, design: .rounded)).foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Paired Mac") {
                    row("Name", app.pairedMacName.isEmpty ? "-" : app.pairedMacName)
                    row("Endpoint", PhoneKeychain.get(.macHost))
                }
                Section("Connection") {
                    row("State", stateString(app.transportState))
                }
                Section("Privacy") {
                    Text("ChaCha20-Poly1305 end-to-end encrypted. Cloudflare sees only ciphertext.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button(role: .destructive) {
                        app.unpair(); dismiss()
                    } label: {
                        Label("Unpair Mac", systemImage: "trash")
                    }
                }
                Section("About") {
                    row("Version", "1.1.0")
                    row("Bundle", Bundle.main.bundleIdentifier ?? "?")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func stateString(_ s: TransportService.State) -> String {
        switch s {
        case .idle: return "Idle"
        case .dialing(let h): return "Dialing \(h)"
        case .handshaking: return "Handshake"
        case .authenticating: return "Authenticating"
        case .streaming: return "Live"
        case .failed(let r): return "Error: \(r)"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(.body, design: .monospaced)).lineLimit(1)
        }
    }
}
