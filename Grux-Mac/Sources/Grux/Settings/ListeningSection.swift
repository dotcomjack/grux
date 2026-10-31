import SwiftUI

/// Listening, as Settings shows it: the mode in effect, the live status row,
/// the cost while it runs and the microphone switch. Shown in both places the
/// old wake word and passive listening sections were, so a person who
/// remembers where the old switch lived still finds it.
///
/// The mode picker and the "tell me when Grux acts" switch moved to Tuning in
/// P-E-2, beside the threshold they work with. This keeps a pointer to them,
/// never a second copy, so the two surfaces cannot disagree.
struct ListeningSection: View {
    struct Copy { let title: String; let body: String }
    static let copy = Copy(
        title: "Listening",
        body: "Closing windows and opening tabs happen on the spot. Sending, deleting and spending always stop in Approvals first. Shell commands never run by voice.")

    static let bannerCopy = Copy(
        title: "Tell me when Grux acts",
        body: "A notification each time Grux does something you asked for out loud, with how long it took to decide. The first one is preceded by a short explanation, once. Turn this off and Grux still acts; it just stops announcing it, and the menu bar, the HUD and the rail in Chat keep the record.")

    static let micCopy = Copy(
        title: "Listen on this Mac's microphone",
        body: "Headphones, a phone over Continuity and an AirPlay speaker drop to call quality while anything holds their microphone open, so listening stays on the Mac's own. A microphone you plug in is used as normal, and the input goes back to your choice when listening stops. Turn this off to listen on whatever the system input is.")

    @ObservedObject private var state = AppState.shared
    @ObservedObject private var ambient = AmbientState.shared
    @ObservedObject private var wake = WakeWordListener.shared

    var body: some View {
        Section(Self.copy.title) {
            Text(Self.modeLine(mode: state.config.listeningMode, awaitingConsent: state.config.listeningAwaitingConsent))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.copy.body)
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if state.config.listeningMode != .off,
               let note = Self.costNote(mode: state.config.listeningMode, awaitingConsent: state.config.listeningAwaitingConsent) {
                Text(note)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.config.listeningAwaitingConsent {
                // Chosen, but no yes yet: the microphone is closed, so the
                // row says what Home and the foot say and offers the yes.
                HStack {
                    Circle()
                        .fill(GruxTheme.warnAmber)
                        .frame(width: 8, height: 8)
                    Text(ListeningTell.waiting.phrase).font(.caption)
                    Spacer()
                    Button(ListeningTell.allowTitle) { ListeningTell.allow() }
                        .font(.caption)
                }
            } else {
                HStack {
                    Circle()
                        .fill(isLive ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(statusLine).font(.caption)
                    Spacer()
                    if state.config.listeningMode == .alwaysOn, ambient.isTranscribing {
                        Label("hearing you", systemImage: "waveform")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let err = ambient.error ?? wake.error {
                Text(err).font(.caption).foregroundStyle(.orange)
            }

            TuningPointer(text: TuningCopy.listeningPointer)

            Toggle(Self.micCopy.title, isOn: Binding(
                get: { state.config.listenOnTheMacsOwnMic },
                set: { state.config.listenOnTheMacsOwnMic = $0; state.saveConfig() }))
            Text(Self.micCopy.body)
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The mode and what it does. While it waits for its yes nothing is
    /// heard yet, so the description is conditional (wave 8 review of D29:
    /// "Grux hears you all the time" sat above "the microphone stays closed").
    static func modeLine(mode: ListeningMode, awaitingConsent: Bool) -> String {
        awaitingConsent ? "\(mode.label). Once you allow it, \(mode.explanation)" : "\(mode.label). \(mode.explanation)"
    }

    /// The line under the mode: what listening costs while it runs, or, while
    /// the mode waits for its yes, that the microphone is still closed (D29:
    /// this said the microphone was open before anyone had agreed).
    static func costNote(mode: ListeningMode, awaitingConsent: Bool) -> String? {
        guard mode != .off else { return nil }
        return awaitingConsent ? TodayModel.sayItLine(.waiting) : MicConsent.runningNote
    }

    private var isLive: Bool {
        switch state.config.listeningMode {
        case .alwaysOn: return ambient.isCapturing
        case .wakeWord: return wake.isListening
        case .off: return false
        }
    }

    private var statusLine: String {
        switch state.config.listeningMode {
        case .alwaysOn: return ambient.isCapturing ? "Listening" : (ambient.status.isEmpty ? "Starting" : ambient.status)
        case .wakeWord: return wake.isListening ? "Waiting for Hey Grux" : "Paused"
        case .off: return "Off"
        }
    }
}
