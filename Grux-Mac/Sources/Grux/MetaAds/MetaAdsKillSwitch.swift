import SwiftUI

// U3 (Meta Ads): the emergency stop. One prominent rose toggle that, when
// engaged, calls MetaAdsService.setKill(true) on the companion engine. The engine
// honors the kill flag by forcing EVERY brand to OBSERVE immediately, no matter
// what mode it was in, so nothing can spend or mutate a live account until a
// human clears it. This is the human-in-the-loop circuit breaker that sits on
// top of the engine's own un-overridable hard caps.
//
// Reflects snapshot.killSwitchOn so the UI always shows the real engine state,
// not just local intent: if the engine reports the kill is on, the toggle reads
// ON even after an app relaunch.
//
// MetaAdsService + MetaAdsStore + MetaAdsSnapshot are owned by U1; this unit
// only calls and reads them.

struct MetaAdsKillSwitch: View {
    @ObservedObject private var store = MetaAdsStore.shared

    @State private var isWorking = false
    @State private var lastError: String?

    private var isOn: Bool { store.snapshot?.killSwitchOn ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "stop.circle.fill" : "stop.circle")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(isOn ? GruxTheme.destructiveRose : GruxTheme.textSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isOn ? "ENGINE HALTED" : "Emergency Stop")
                        .font(GruxTheme.Font.title)
                        .foregroundStyle(isOn ? GruxTheme.destructiveRose : GruxTheme.textPrimary)
                    Text(isOn
                         ? "Every brand forced to OBSERVE. No actions applied."
                         : "Force every brand to OBSERVE. Stops all autonomous action at once.")
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    actionButton
                }
            }

            if let err = lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(GruxTheme.warnAmber)
                    Text(err)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.warnAmber)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .fill(GruxTheme.destructiveRose.opacity(isOn ? 0.14 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.card, style: .continuous)
                .strokeBorder(GruxTheme.destructiveRose.opacity(isOn ? 0.55 : 0.22), lineWidth: isOn ? 1.5 : 1)
        )
        .shadow(color: isOn ? GruxTheme.destructiveRose.opacity(0.35) : .clear, radius: 14, x: 0, y: 6)
    }

    // The tight button style: not chunky. Rose when arming the stop, a quieter
    // outline when clearing it (so clearing never looks like the dangerous action).
    @ViewBuilder
    private var actionButton: some View {
        if isOn {
            Button { Task { await setKill(false) } } label: {
                Text("Clear Halt")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                    .overlay(Capsule().strokeBorder(GruxTheme.textSecondary.opacity(0.4), lineWidth: 1))
                    .foregroundStyle(GruxTheme.textPrimary)
            }
            .buttonStyle(.plain)
            .help("Re-enable per-brand mode control. Brands return to whatever mode they were set to.")
        } else {
            Button { Task { await setKill(true) } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    Text("STOP ALL")
                        .font(.system(size: 13, weight: .bold))
                        .kerning(0.5)
                }
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Capsule().fill(GruxTheme.destructiveRose))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                .foregroundStyle(.white)
                .shadow(color: GruxTheme.destructiveRose.opacity(0.45), radius: 6)
            }
            .buttonStyle(.plain)
            .help("Immediately force every brand to OBSERVE. The engine applies nothing until cleared.")
        }
    }

    // Routed through the STORE, which owns the one flag that governs every
    // control-plane POST (see MetaAdsStore.runCommand) and pulls a fresh
    // snapshot so killSwitchOn reflects engine truth rather than local
    // intent. Calling the service directly behind this view's own @State
    // flag left the halt racing whatever another surface was already writing.
    private func setKill(_ on: Bool) async {
        guard !isWorking else { return }
        // NOT cleared on entry. Clearing here made the `.cancelled: break`
        // arm below DEAD: it exists so a torn-down command preserves the
        // last real verdict, and there was never anything left to preserve.
        // The next verdict overwrites this anyway, so a refusal still stops
        // being shown as soon as the next press produces one.
        isWorking = true
        defer { isWorking = false }
        // This halt's own verdict. Reading store.commandError after the
        // await reported another surface's refusal as this switch's failure.
        //
        // .cancelled is NOT success and must not clear a standing error, the
        // same rule MetaAdsActionBar holds: a torn-down command wrote no
        // verdict, so wiping the last real one reads as "the halt worked" on
        // the one control where that lie costs the most.
        switch await store.setKill(on: on) {
        case .failed(let message): lastError = message
        // Shown like a fault but cleared by the next press, see above.
        case .refused(let advice): lastError = advice
        case .applied: lastError = nil
        case .cancelled: break
        }
    }
}
