import SwiftUI

/// The one input. Enter sends through ChatService (workflow triggers, the PIM
/// intents and chat all fast-path there already). The mic is the ambient
/// listening toggle, wearing the shared tell.
struct PanelInput: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var micHealth = MicHealth.shared
    @ObservedObject private var sidebarStore = SidebarStateStore.shared
    /// Redraws on a theme commit without a remount: the panel does not key
    /// the input on the theme, so focus and the draft survive it.
    @ObservedObject private var theme = ThemeConfig.shared
    @FocusState private var focused: Bool
    @State private var draft = ""
    /// Opens Tuning, where listening is switched on.
    var onTuning: () -> Void
    var onSend: (String) -> Void

    /// Whether the microphone is open, not what Grux is doing with it: the
    /// mic glyph and placeholder turn on muted or off only, so speaking and
    /// thinking are left out on purpose. The foot shows the full tell.
    private var tell: ListeningTell {
        ListeningTell.resolve(mode: state.config.listeningModeInEffect, micMuted: state.micMuted,
                              isSpeaking: false, isThinking: false, notHearing: micHealth.notHearing)
    }

    private var micClosed: Bool { tell == .muted || tell == .off }

    /// What the field says, by what the mic press will do. Listening off is
    /// a setting, not a mute, so it never says "unmute".
    static func placeholder(for tell: ListeningTell) -> String {
        switch tell {
        case .off: return PanelCopy.placeholderOff
        case .muted: return PanelCopy.placeholderMuted
        default: return PanelCopy.placeholder
        }
    }

    /// Listening off: the press opens Tuning, where it is switched on,
    /// instead of muting a listener that is already silent.
    static func micOpensTuning(_ tell: ListeningTell) -> Bool { tell == .off }

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            HStack(spacing: GruxSpacing.s) {
                TextField(Self.placeholder(for: tell), text: $draft)
                    .textFieldStyle(.plain)
                    .font(GruxType.body)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .focused($focused)
                    .onSubmit(send)
                    .accessibilityLabel(PanelCopy.inputLabel)
                Button {
                    if Self.micOpensTuning(tell) { onTuning() } else { MicController.toggle(source: "panel") }
                } label: {
                    Image(systemName: micClosed ? "mic.slash.fill" : "mic.fill")
                        .font(GruxType.caption)
                        .foregroundStyle(micClosed ? GruxTheme.textTertiary : GruxTheme.accentPrimary)
                }
                .buttonStyle(.plain)
                .help(tell.help)
                .accessibilityLabel(PanelCopy.micLabel(tell))
            }
            .padding(.horizontal, GruxSpacing.m)
            .padding(.vertical, GruxSpacing.s)
            .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                .fill(GruxTheme.chipFill))
            // First run: nothing has been opened yet, so say where to start.
            if sidebarStore.recents.isEmpty {
                Text(PanelCopy.firstRunUnderInput)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .onAppear { focused = true }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        draft = ""
        onSend(t)
    }
}
