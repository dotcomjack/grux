import Foundation
import SwiftUI
import Combine
import AVFoundation
import UIKit

// Root app-level view model. Owns references to the singletons, exposes a
// clean @Published surface to ContentView, and mediates between the launch /
// scene lifecycle and the capture + transport services.

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // UI-visible tab. Users see either Pair (when unpaired) or Stream (once
    // paired). Tapping the top-right gear surfaces the Settings sheet.
    enum Section: Hashable {
        case pair, stream, settings
    }

    @Published var section: Section = .pair
    @Published var paired: Bool = false
    @Published var pairedMacName: String = ""
    @Published var streamingRequested: Bool = false
    @Published var showScanner: Bool = false
    @Published var showSettings: Bool = false
    @Published var errorBanner: String = ""
    // Set by the grux-pair URL's `chat=` query (CLI e2e test hook). Sent as
    // a user message once the chat store has received the active thread.
    var pendingAutoChatText: String?

    // Passthrough mirrors so ContentView doesn't have to subscribe to both
    // the mic and the transport directly.
    @Published var micRunning: Bool = false
    @Published var micLevel: Float = 0
    @Published var framesSent: Int = 0
    @Published var framesEmitted: Int = 0
    @Published var transportState: TransportService.State = .idle
    @Published var lastTranscript: String = ""
    @Published var ttsActive: Bool = false
    @Published var ttsFramesReceived: Int = 0

    var cancellables = Set<AnyCancellable>()

    private init() {
        paired = PhoneKeychain.isPaired()
        pairedMacName = PhoneKeychain.get(.macDisplayName)
        section = paired ? .stream : .pair

        MicCaptureService.shared.$isRunning.receive(on: RunLoop.main).assign(to: &$micRunning)
        MicCaptureService.shared.$levelRMS.receive(on: RunLoop.main).assign(to: &$micLevel)
        MicCaptureService.shared.$framesEmittedThisSession.receive(on: RunLoop.main).assign(to: &$framesEmitted)
        TransportService.shared.$state.receive(on: RunLoop.main).assign(to: &$transportState)
        TransportService.shared.$framesSent.receive(on: RunLoop.main).assign(to: &$framesSent)
        TransportService.shared.$lastTranscript.receive(on: RunLoop.main).assign(to: &$lastTranscript)
        TransportService.shared.$ttsActive.receive(on: RunLoop.main).assign(to: &$ttsActive)
        TransportService.shared.$ttsFramesReceived.receive(on: RunLoop.main).assign(to: &$ttsFramesReceived)

        // When the chat store picks up an active thread, and we have a
        // pending auto-chat text from the pair URL, send it.
        ChatStore.shared.$activeThreadId
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] id in
                guard let self, let text = self.pendingAutoChatText else { return }
                AppModel.diag("auto-send triggered, thread=\(id) text=\(text)")
                TransportService.shared.sendChat(.userMessage(threadId: id, text: text))
                self.pendingAutoChatText = nil
            }
            .store(in: &cancellables)
    }

    // Wipe any historical diag entries every launch. Protects against stale
    // pre-redaction logs lingering in iCloud backups / Files share-sheets.
    // Called once from the scene init path, before any diag() write.
    static func wipeDiagLog() {
        let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        )
        guard let url = docs?.appendingPathComponent("diag.log") else { return }
        try? "".write(to: url, atomically: true, encoding: .utf8)
        var u = url
        var v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    func onAppLaunch() {
        AppModel.wipeDiagLog()
        let env = ProcessInfo.processInfo.environment
        // GRUX_SYNTHETIC_AUDIO=1: MicCaptureService emits a 440 Hz sine wave
        // instead of tapping the mic. Lets the sim produce non-silent frames
        // without host-mic permission + simulator audio routing hassle.
        let synthetic = env["GRUX_SYNTHETIC_AUDIO"] == "1"
        if synthetic {
            UserDefaults.standard.set(true, forKey: "UseSyntheticAudio")
        } else {
            // Soft-request mic permission on launch so the main "Start" tap is
            // instant. If denied, the user gets a clear banner, no silent fails.
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        }

        // GRUX_AUTO_PAIR=<grux-pair://…>: ingest pairing URL on launch
        if let url = env["GRUX_AUTO_PAIR"], let info = PhonePairingURL.parse(url) {
            handleScannedInfo(info)
        }
        // GRUX_AUTO_START=1: tap the Start button as soon as we're paired.
        if env["GRUX_AUTO_START"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.startStreaming()
            }
        }
    }

    func onScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            // Keep audio alive, that's what the `audio` background mode is for.
            // Nothing to do; AVAudioSession + background-mode entitlement handle this.
            break
        case .active:
            break
        @unknown default:
            break
        }
    }

    // MARK: - Pairing

    // Diagnostic log. Pullable via
    // `xcrun devicectl device copy from --domain-type appDataContainer ...`
    //
    // WARNING: files in Documents are included in iCloud backups. This log
    // MUST NEVER contain the pairing secret, a session key, or any message
    // content, only operational events. Redaction enforced via
    // `redactSecretIn`.
    static func diag(_ line: String) {
        let docs = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        guard let url = docs?.appendingPathComponent("diag.log") else { return }
        // Belt-and-suspenders: if any secret slipped into the line from a
        // caller we didn't audit, strip it on the way in too.
        let safe = redactSecretIn(line)
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(ts)] \(safe)\n"
        if let data = entry.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
                try? h.close()
            } else {
                try? data.write(to: url)
                // Exclude from iCloud backup, iOS default for Documents is
                // "included"; we flip it so even if the user restores from a
                // backup, no stale diag/secret gets carried over.
                var u = url
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? u.setResourceValues(values)
            }
        }
        NSLog("[GruxPhone DIAG] %@", safe)
    }

    // Redact the base64url `secret=...` parameter wherever it might appear
    // in a log line. Matches the grux-pair URL scheme's query param.
    // Leaves the rest of the URL intact for debuggability.
    static func redactSecretIn(_ line: String) -> String {
        guard line.contains("secret=") else { return line }
        // Non-greedy up to the next & or end-of-string / quote / whitespace.
        let pattern = #"secret=[A-Za-z0-9\-_]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return line }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return re.stringByReplacingMatches(
            in: line, range: range, withTemplate: "secret=***REDACTED***"
        )
    }

    func handleScannedInfo(_ info: PhonePairingURL.Info) {
        AppModel.diag("handleScannedInfo name=\(info.name) wss=\(info.wssURL) secretLen=\(info.secretBase64URL.count)")
        // Verify secret decodes to 32 bytes before storing.
        guard let secret = PhonePairingURL.base64URLDecode(info.secretBase64URL), secret.count == 32 else {
            errorBanner = "Pairing QR is malformed"
            return
        }
        // v2 stores the wss:// URL in place of the v1 host/port pair.
        _ = PhoneKeychain.set(.pairingSecretB64, secret.base64EncodedString())
        _ = PhoneKeychain.set(.macHost, info.wssURL)
        _ = PhoneKeychain.set(.macPort, "")           // deprecated under v2
        _ = PhoneKeychain.set(.macDisplayName, info.name)
        paired = true
        pairedMacName = info.name
        section = .stream
        showScanner = false
    }

    func unpair() {
        stopStreamingIfNeeded()
        PhoneKeychain.clearPairing()
        paired = false
        pairedMacName = ""
        section = .pair
    }

    // MARK: - Streaming

    func startStreaming() {
        AppModel.diag("startStreaming paired=\(paired) host=\(PhoneKeychain.get(.macHost))")
        streamingRequested = true
        Task { @MainActor in
            do {
                try MicCaptureService.shared.start()
                AppModel.diag("mic started OK")
                TransportService.shared.startStreaming()
                AppModel.diag("transport.startStreaming called")
            } catch {
                AppModel.diag("mic start failed: \(error.localizedDescription)")
                errorBanner = "Mic start failed: \(error.localizedDescription)"
                streamingRequested = false
            }
        }
    }

    func stopStreamingIfNeeded() {
        streamingRequested = false
        MicCaptureService.shared.stop()
        TransportService.shared.stopStreaming()
    }

    func toggleStream() {
        if streamingRequested {
            stopStreamingIfNeeded()
        } else {
            startStreaming()
        }
    }

    var isStreaming: Bool {
        if case .streaming = transportState { return true }
        return false
    }
}
