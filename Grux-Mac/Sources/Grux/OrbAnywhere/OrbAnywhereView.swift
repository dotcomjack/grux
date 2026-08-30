import SwiftUI
import AppKit

// The standalone "face of Grux" orb. Lives in a floating NSPanel (see
// OrbAnywhereController). Tap → toggle mic mute. Right-click → menu.
// Hint pill below the orb reflects the latest tool-driven status push
// from OrbHintBus, or the live orb state when no hint is active.
//
// Kept intentionally minimal - the menu bar already has all the controls.
// This surface exists so Grux's identity is always visible on the desktop,
// something Omi's desktop app cannot match.
struct OrbAnywhereView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var speech = SpeechEngine.shared
    @ObservedObject private var ambient = AmbientState.shared
    @ObservedObject private var wake = WakeWordListener.shared
    @ObservedObject private var hints = OrbHintBus.shared
    // Item 24: shell bus fills the idle gap with canonical moments.
    @ObservedObject private var shellBus = ShellStateBus.shared

    // Derive orb state the same way MenuBarView / AmbientHUDRoot do so every
    // surface tells one story. Muted always wins.
    private var orbState: GruxOrbState {
        if state.micMuted { return .muted }
        if let h = hints.latestHint, let s = h.state { return s }
        if ambient.coachIsSpeaking || speech.isSpeaking || speech.isBuffering { return .speaking }
        if ambient.isExtracting || state.isThinking { return .thinking }
        if ambient.isCapturing || wake.isListening { return .listening }
        return shellBus.current.mode.orbState
    }

    private var displayedLabel: String {
        if let h = hints.latestHint { return h.message }
        return orbState.label.uppercased()
    }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                MicController.toggle()
            } label: {
                OrbView(state: orbState, level: speech.outputLevel)
                    .frame(width: 60, height: 60)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(state.micMuted
                  ? "Mic muted - tap to resume"
                  : "Tap to mute · drag to move")

            hintPill
        }
        .padding(6)
        .contextMenu {
            Button(state.micMuted ? "Unmute mic" : "Mute mic") { MicController.toggle() }
            Divider()
            Button("Open Grux Chat…") { WindowOpener.openChat() }
            Button("Open Settings…") { WindowOpener.openSettings() }
            Button("Toggle Ambient HUD") {
                AmbientState.shared.toggleHUD()
            }
            Divider()
            Button("Hide floating orb") {
                AppState.shared.config.orbAnywhereEnabled = false
                AppState.shared.saveConfig()
                OrbAnywhereController.shared.hide()
            }
        }
    }

    private var hintPill: some View {
        let base = hints.latestHint?.state ?? orbState
        return HStack(spacing: 5) {
            Circle()
                .fill(base.primary)
                .frame(width: 5, height: 5)
                .shadow(color: base.primary.opacity(0.8), radius: 3)
            Text(displayedLabel)
                .font(.system(size: 9, weight: .bold, design: .default))
                .kerning(1.1)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: true, vertical: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(.ultraThinMaterial)
                .overlay(Capsule().stroke(base.primary.opacity(0.35), lineWidth: 0.8))
        )
        .animation(.easeInOut(duration: 0.2), value: displayedLabel)
    }
}
