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
    /// Redraws when a model arrives, so the held line goes once Chat can send.
    @ObservedObject private var registry = ModelRegistry.shared
    @FocusState private var focused: Bool
    @State private var draft: String
    /// Return was pressed on text nothing can answer yet: no model is
    /// connected and no workflow takes it. The text stays in the field.
    @State private var heldForModel: Bool
    /// Opens Tuning, where listening is switched on.
    var onTuning: () -> Void
    var onSend: (String) -> Void
    /// Where "Connect a model" goes, the same place as the Now row.
    var onConnectModel: () -> Void

    init(onTuning: @escaping () -> Void, onSend: @escaping (String) -> Void,
         onConnectModel: @escaping () -> Void = {}, draft: String = "", heldForModel: Bool = false) {
        self.onTuning = onTuning
        self.onSend = onSend
        self.onConnectModel = onConnectModel
        _draft = State(initialValue: draft)
        _heldForModel = State(initialValue: heldForModel)
    }

    /// Whether the microphone is open, not what Grux is doing with it: the
    /// mic glyph and placeholder turn on muted or off only, so speaking and
    /// thinking are left out on purpose. The foot shows the full tell.
    private var tell: ListeningTell {
        ListeningTell.resolve(mode: state.config.listeningModeInEffect, micMuted: state.micMuted,
                              isSpeaking: false, isThinking: false, notHearing: micHealth.notHearing,
                              awaitingConsent: state.config.listeningAwaitingConsent)
    }

    private var micClosed: Bool { tell == .muted || tell.listenerOff }

    /// What the field says, by what the mic press will do. Listening off is
    /// a setting, not a mute, so it never says "unmute".
    static func placeholder(for tell: ListeningTell) -> String {
        switch tell {
        case .off: return PanelCopy.placeholderOff
        case .waiting: return PanelCopy.placeholderWaiting
        case .muted: return PanelCopy.placeholderMuted
        default: return PanelCopy.placeholder
        }
    }

    /// Listening off: the press opens Tuning, where it is switched on,
    /// instead of muting a listener that is already silent.
    static func micOpensTuning(_ tell: ListeningTell) -> Bool { tell == .off }

    /// Whether Return keeps the text instead of sending it. With no model,
    /// Return used to clear the field and open a Chat that could not show the
    /// message, so it was gone (W4 pass 1, 2026-10-13). A workflow trigger or
    /// an answer to a waiting workflow needs no model, so those still go.
    static func holdsForModel(canSend: Bool, needsNoModel: Bool) -> Bool { !canSend && !needsNoModel }

    /// The held line shows only while Chat still cannot send.
    static func showsConnectLine(held: Bool, canSend: Bool) -> Bool { held && !canSend }

    @MainActor static func holdsForModel(_ text: String) -> Bool {
        let workflows = CommandV2Engine.shared
        return holdsForModel(canSend: ChatReadiness.current().canSend,
                             needsNoModel: workflows.matchTrigger(text) != nil
                                 || workflows.activeRuns.contains { $0.status == .waitingForApproval })
    }

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
                    if tell == .waiting { ListeningTell.allow() }
                    else if Self.micOpensTuning(tell) { onTuning() }
                    else { MicController.toggle(source: "panel") }
                } label: {
                    Image(systemName: micClosed ? "mic.slash.fill" : "mic.fill")
                        .font(GruxType.caption)
                        .foregroundStyle(micClosed ? GruxTheme.textTertiary : GruxTheme.accentPrimary)
                }
                .buttonStyle(.plain)
                // Out of the key view loop, like the orb: a space typed for the
                // field must never toggle the microphone.
                .focusable(false)
                .help(tell.help)
                .accessibilityLabel(PanelCopy.micLabel(tell))
            }
            .padding(.horizontal, GruxSpacing.m)
            .padding(.vertical, GruxSpacing.s)
            .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                .fill(GruxTheme.chipFill))
            // Only while it is still true: once a model is installed the text
            // stays, and "Connect a model to send this" goes (W4 build 11, 41-c).
            if Self.showsConnectLine(held: heldForModel, canSend: ChatReadiness.current().canSend) {
                HStack(spacing: GruxSpacing.s) {
                    Text(PanelCopy.connectToSend)
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                    Button(PanelCopy.connectModel, action: onConnectModel)
                        .buttonStyle(.plain)
                        .font(GruxType.caption.weight(.semibold))
                        .foregroundStyle(GruxTheme.accentPrimary)
                }
            } else if sidebarStore.recents.isEmpty {
                // First run: nothing has been opened yet, so say where to start.
                Text(PanelCopy.firstRunUnderInput)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .onAppear { focused = true }
        .onChange(of: draft) { _, new in
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { heldForModel = false }
        }
    }

    private func send() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if Self.holdsForModel(t) {
            heldForModel = true
            return
        }
        heldForModel = false
        draft = ""
        onSend(t)
    }
}
