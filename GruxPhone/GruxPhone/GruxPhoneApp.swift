import SwiftUI
import AVFoundation

// Grux Phone, iOS companion for the Grux Mac app.
// A mic for the Mac: capture audio on the phone, stream live to the Mac over
// Bonjour TCP, echo transcript partials back for feedback.
// Personal use, single-device. No servers, no cloud, no telemetry.

@main
struct GruxPhoneApp: App {
    @StateObject private var app = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Skip audio session config when running in synthetic-audio test mode,
        // because configuring playAndRecord triggers an immediate mic-permission dialog
        // that can't be dismissed headlessly from simctl. The sim flow relies
        // on this escape hatch; real-device runs always take the else branch.
        if ProcessInfo.processInfo.environment["GRUX_SYNTHETIC_AUDIO"] != "1" {
            Self.configureAudioSession()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .preferredColorScheme(.dark)
                .onAppear { app.onAppLaunch() }
                .onOpenURL { url in
                    // Redact the secret before logging, diag.log can end up
                    // in iCloud backup, Files.app share sheets, etc., and we
                    // don't want a cleartext pairing secret sitting there.
                    let redacted = AppModel.redactSecretIn(url.absoluteString)
                    AppModel.diag("onOpenURL fired raw=\(redacted)")
                    if let info = PhonePairingURL.parse(url.absoluteString) {
                        AppModel.diag("URL parsed OK wss=\(info.wssURL)")
                        app.handleScannedInfo(info)
                        if url.absoluteString.contains("autostart=1") {
                            AppModel.diag("autostart, scheduling startStreaming in 0.5s")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                app.startStreaming()
                            }
                        }
                        // Optional `chat=...` query drives a round-trip e2e
                        // test from CLI: pair, stream, and immediately send
                        // a user message into whatever's the active thread.
                        if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                           let chat = comps.queryItems?.first(where: { $0.name == "chat" })?.value,
                           !chat.isEmpty {
                            AppModel.diag("chat param present, will send: \(chat)")
                            app.pendingAutoChatText = chat
                        }
                    } else {
                        AppModel.diag("URL parse FAILED for \(url.absoluteString)")
                    }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            app.onScenePhaseChange(phase)
        }
    }

    // Configure the AVAudioSession once at process start. `playAndRecord` +
    // `.mixWithOthers` + `.defaultToSpeaker` keeps the phone usable during
    // calls and music, and `.allowBluetooth` lets you stream from AirPods /
    // the DJI Mic if it shows up as a BT audio source. Background mode
    // `audio` (declared in Info.plist) keeps the tap live when the screen
    // locks, critical for the "mic in my pocket" experience.
    static func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.mixWithOthers, .allowBluetoothHFP, .defaultToSpeaker, .duckOthers]
            )
            try session.setPreferredSampleRate(Double(PhoneWire.micSampleRate))
            try session.setPreferredIOBufferDuration(Double(PhoneWire.micFrameDurationMs) / 1000.0)
            try session.setActive(true, options: [])
        } catch {
            NSLog("[GruxPhone] AVAudioSession config failed: \(error)")
        }
    }
}
