import SwiftUI

/// Orb, wordmark, and the two badges that draw nothing when idle.
struct PanelHead: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var micHealth = MicHealth.shared
    @ObservedObject private var shellBus = ShellStateBus.shared
    /// Opens a surface by its locked key.
    var onOpen: (String) -> Void
    var onOptimize: () -> Void

    private var tell: ListeningTell {
        ListeningTell.resolve(state: state, speech: speech, notHearing: micHealth.notHearing)
    }

    /// The rail orb's rule: an alert outranks the listening story, and with
    /// listening off the shell bus (focus, workflows, agents) gets the orb.
    private var orbState: GruxOrbState {
        if shellBus.current.mode == .alert { return ShellMode.alert.orbState }
        if tell == .off { return shellBus.current.mode.orbState }
        return tell.orbState
    }

    var body: some View {
        HStack(spacing: GruxSpacing.m) {
            // A click mutes; a right click tunes, exactly as the rail's orb.
            Button {
                MicController.toggle(source: "orb")
            } label: {
                OrbView(state: orbState, level: speech.outputLevel)
                    .frame(width: GruxLayout.railOrb, height: GruxLayout.railOrb)
                    .scaleEffect(GruxLayout.panelOrb / GruxLayout.railOrb)
                    .frame(width: GruxLayout.panelOrb, height: GruxLayout.panelOrb)
            }
            .buttonStyle(.plain)
            .orbDecisionHelp(tell.help)
            .contextMenu {
                Button(TuningCopy.title) { onOpen("tuning") }
                Button(TuningCopy.optimizeTitle) { onOptimize() }
            }
            .accessibilityLabel(PanelCopy.orbLabel(tell))
            Text(PanelCopy.wordmark)
                .font(GruxType.microCaps)
                .kerning(GruxType.wordmarkTracking)
                .foregroundStyle(GruxTheme.textSecondary)
            Spacer()
            FoundryStatusBadge { onOpen("selfUpgrade") }
            ActivitySwarmBadge { onOpen("agents") }
        }
    }
}
