import SwiftUI

// The reusable OVERRIDE-ACTIONS control. Approve / veto the engine's pending
// move, pause / force-scale / kill an ad, or flip a brand mode. Every action is
// gated: a confirm sheet, disabled while the kill switch is on, and tagged
// SIMULATED while the brand is not bootstrapped (act_PLACEHOLDER means the engine
// treats it as a no-op, so nothing ever spends). After any action the store
// refreshes so the UI reflects engine truth.
struct MetaAdsActionBar: View {
    // Explicit actions to offer. When an engine SuggestedAction is present we lead
    // with it; the manual verbs (pause/scale/kill) fill out the bar for an ad.
    let suggested: SuggestedAction?
    let brand: String?
    let nodeId: String?
    let crid: String?
    var compact: Bool = false

    @ObservedObject private var store = MetaAdsStore.shared
    @State private var pending: PendingAction?
    @State private var working = false
    @State private var note: String?

    private var killed: Bool { store.snapshot?.killSwitchOn ?? false }
    private var bootstrapped: Bool {
        store.snapshot?.brands.first(where: { $0.slug == brand || $0.id == brand })?.isBootstrapped ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                HStack(spacing: 8) {
                    MetaAdsEyebrow(text: "Override", icon: "slider.horizontal.3", tint: GruxTheme.textTertiary)
                    if !bootstrapped {
                        Text("SIMULATED")
                            .font(GruxTheme.Font.microCaps)
                            .foregroundStyle(GruxTheme.warnAmber)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(GruxTheme.warnAmber.opacity(0.16)))
                    }
                    Spacer()
                }
            }

            if killed {
                Text("Engine halted. Clear the kill switch first.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.destructiveRose)
            }

            HStack(spacing: 8) {
                if let s = suggested {
                    actionButton(s.label, verb: s.verb, tint: tint(for: s.verb), filled: true) {
                        let p = PendingAction(verb: s.verb, label: s.label, brand: s.brand ?? brand,
                                              nodeId: s.nodeId ?? nodeId, crid: s.crid ?? crid,
                                              cents: s.paramCents, mode: s.paramMode)
                        // Spend-affecting or destructive verbs ALWAYS confirm,
                        // regardless of the engine's requiresConfirm hint. Only a
                        // benign verb with requiresConfirm == false may fast-path,
                        // so nothing that can spend ever fires on a single tap.
                        if needsConfirm(s) { pending = p } else { run(p) }
                    }
                }
                if nodeId != nil {
                    actionButton("Pause", verb: .pause, tint: GruxTheme.warnAmber) {
                        pending = PendingAction(verb: .pause, label: "Pause ad", brand: brand, nodeId: nodeId, crid: crid)
                    }
                    actionButton("Scale", verb: .scale, tint: GruxTheme.successMint) {
                        let cents = suggested?.paramCents ?? MetaAdsCaps.effectiveDailyBudgetCents
                        pending = PendingAction(verb: .scale, label: "Force scale", brand: brand, nodeId: nodeId, crid: crid, cents: cents)
                    }
                    actionButton("Kill", verb: .kill, tint: GruxTheme.destructiveRose) {
                        pending = PendingAction(verb: .kill, label: "Kill ad", brand: brand, nodeId: nodeId, crid: crid)
                    }
                }
                Spacer(minLength: 0)
                if working { ProgressView().controlSize(.small) }
            }

            if let note = note {
                Text(note)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .confirmationDialog(pending?.confirmTitle ?? "Confirm",
                            isPresented: confirmBinding,
                            titleVisibility: .visible) {
            Button(pending?.label ?? "Confirm", role: pending?.verb == .kill ? .destructive : nil) {
                if let p = pending { run(p) }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.confirmMessage(bootstrapped: bootstrapped) ?? "")
        }
    }

    private var confirmBinding: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    private func actionButton(_ title: String, verb: SuggestedAction.ActionVerb, tint: Color, filled: Bool = false, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(title)
                .font(GruxTheme.Font.microCaps)
                .kerning(1.0)
                .foregroundStyle(filled ? GruxTheme.base : tint)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(filled ? tint : tint.opacity(0.14)))
                .overlay(Capsule().strokeBorder(tint.opacity(filled ? 0 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        // Block while the kill switch is on, while this bar is working, OR
        // while the store is applying another control action. Every
        // control-plane POST in the tab now runs through the store (see
        // MetaAdsStore.runCommand), so this flag is raised by all of them and
        // two writes can never race to the engine from different surfaces.
        .disabled(killed || working || store.isMutating)
        .opacity(killed ? 0.4 : 1)
    }

    // A spend-affecting or destructive verb must always confirm. Only a benign
    // verb (approve/veto/spawn/flip) whose engine hint says requiresConfirm ==
    // false may skip the dialog.
    private func needsConfirm(_ s: SuggestedAction) -> Bool {
        switch s.verb {
        case .scale, .kill, .pause: return true
        default: return s.requiresConfirm
        }
    }

    private func tint(for verb: SuggestedAction.ActionVerb) -> Color {
        switch verb {
        case .approve, .scale: return GruxTheme.successMint
        case .veto, .pause: return GruxTheme.warnAmber
        case .kill: return GruxTheme.destructiveRose
        case .spawn, .flipMode: return GruxTheme.accentPrimaryLight
        }
    }

    // Routed through the STORE, so the one flag that governs control-plane
    // writes is the one this bar's own .disabled() reads. Every verb below
    // used to call MetaAdsService directly behind `working`, a @State flag
    // private to this bar instance, while claiming store.isMutating made a
    // race impossible: an override POST runs up to 12s per base, and
    // Emergency Stop sat enabled beside it for every second of that.
    //
    // The outcome line is read back off the store's command channel rather
    // than a local catch, because the store is now the one place a
    // control-plane verdict is recorded, and that includes the refusal a
    // press landing on somebody else's in-flight write earns.
    private func run(_ p: PendingAction) {
        pending = nil
        working = true
        note = nil
        Task { @MainActor in
            let outcome = await store.runCommand(p.label) {
                switch p.verb {
                case .approve:  _ = try await MetaAdsService.approveMove(id: p.actionId)
                case .veto:     _ = try await MetaAdsService.vetoMove(id: p.actionId)
                case .pause:    _ = try await MetaAdsService.pauseAd(brand: p.brand ?? "", nodeId: p.nodeId ?? "")
                case .scale:    _ = try await MetaAdsService.scaleAd(brand: p.brand ?? "", nodeId: p.nodeId ?? "", cents: p.cents ?? MetaAdsCaps.effectiveDailyBudgetCents)
                case .kill:     _ = try await MetaAdsService.killAd(brand: p.brand ?? "", nodeId: p.nodeId ?? "")
                case .spawn:    _ = try await MetaAdsService.spawnVariant(brand: p.brand ?? "", crid: p.crid ?? "", variable: p.mode ?? "hook", value: "")
                case .flipMode: _ = try await MetaAdsService.setMode(brand: p.brand ?? "", mode: p.mode ?? "OBSERVE")
                }
                // Publishes nothing itself, so runCommand owes the
                // read-after-write pull. Reported, not inferred.
                return false
            }
            // The verdict for THIS command, not whatever the shared channel
            // holds by now. Sampling store.commandError after the await read
            // a field any other surface can write during it, so a halt
            // refused mid-approve reported the approve as failed.
            switch outcome {
            case .failed(let failure):
                note = "\(p.label) failed: \(failure)"
            case .refused(let advice):
                // NOT a fault: the gate said no and nothing was sent. It is
                // advice to press again, so it lives exactly until they do
                // (cleared at the top of the next press) rather than in the
                // store's sticky channel, where its truth expired without
                // anything noticing for four rounds running.
                note = advice
            case .applied:
                note = bootstrapped ? "\(p.label) applied." : "\(p.label) queued (simulated, act_PLACEHOLDER)."
            case .cancelled:
                // Silent on a torn-down task: no verdict exists, and claiming
                // one applied is the fabricated success the store's own
                // cancellation arm refuses to write.
                break
            }
            working = false
        }
    }

    struct PendingAction {
        let verb: SuggestedAction.ActionVerb
        let label: String
        let brand: String?
        var nodeId: String? = nil
        var crid: String? = nil
        var cents: Int? = nil
        var mode: String? = nil

        // The engine pending-move id for approve/veto routes through the action's
        // own id; fall back to the node id so the call always has a target.
        var actionId: String { nodeId ?? crid ?? (brand ?? "") }

        var confirmTitle: String { label }
        func confirmMessage(bootstrapped: Bool) -> String {
            let sim = bootstrapped ? "" : " This brand is on act_PLACEHOLDER, so it runs as a simulated no-op (no real spend)."
            switch verb {
            case .scale:
                let amt = cents.map { MetaAdsFormat.dollars($0) } ?? "the proposed budget"
                return "Force scale this ad to \(amt)/day." + sim
            case .kill: return "Kill this ad now. This stops its delivery." + sim
            case .pause: return "Pause this ad. It can be resumed later." + sim
            case .approve: return "Approve the engine's proposed move." + sim
            case .veto: return "Veto the engine's proposed move." + sim
            case .spawn: return "Spin up a new one-variable A/B test off this concept." + sim
            case .flipMode: return "Change this brand's autonomy mode." + sim
            }
        }
    }
}
