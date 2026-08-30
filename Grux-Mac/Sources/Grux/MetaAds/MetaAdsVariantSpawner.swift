import SwiftUI

// Spin a new A/B test off a winner by changing exactly ONE variable. A picker
// over the 8 lineage variables plus a value field, gated by mode and a confirm,
// routed through MetaAdsService.spawnVariant. Never silently spends; while the
// brand is not bootstrapped it shows as queued (simulated).
struct MetaAdsVariantSpawner: View {
    let source: ActiveAd

    @ObservedObject private var store = MetaAdsStore.shared
    @State private var variable: String = "hook"
    @State private var value: String = ""
    @State private var confirming = false
    @State private var working = false
    @State private var note: String?

    private let variables = ["hook", "headline", "primary_text", "scene", "format", "aspect_ratio", "cta", "audience"]

    private var killed: Bool { store.snapshot?.killSwitchOn ?? false }
    private var bootstrapped: Bool {
        store.snapshot?.brands.first(where: { $0.slug == source.brand || $0.id == source.brand })?.isBootstrapped ?? false
    }

    var body: some View {
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    MetaAdsEyebrow(text: "Spawn variant", icon: "plus.diamond.fill", tint: GruxTheme.accentPrimaryLight)
                    if !bootstrapped {
                        Text("SIMULATED").font(GruxTheme.Font.microCaps).foregroundStyle(GruxTheme.warnAmber)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(GruxTheme.warnAmber.opacity(0.16)))
                    }
                    Spacer()
                }
                Text("Branch one new test off \(source.displayName) by changing exactly one variable.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(GruxTheme.textSecondary)

                HStack(spacing: 8) {
                    Menu {
                        ForEach(variables, id: \.self) { v in
                            Button { variable = v } label: {
                                HStack { Text(v); if v == variable { Image(systemName: "checkmark") } }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(variable.uppercased()).font(GruxTheme.Font.microCaps)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(GruxTheme.accentPrimaryLight)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(GruxTheme.accentPrimary.opacity(0.14)))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    TextField("new value (e.g. before-after)", text: $value)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(GruxTheme.base))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))

                    Button { confirming = true } label: {
                        Text("Spawn").font(GruxTheme.Font.microCaps).kerning(1.0)
                            .foregroundStyle(GruxTheme.base)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(GruxTheme.accentPrimaryLight))
                    }
                    .buttonStyle(.plain)
                    // store.isMutating for the same reason the action bar and
                    // the mode control read it: one flag governs every
                    // control-plane POST, so a spawn cannot be pressed while
                    // another surface is mid-write.
                    .disabled(killed || working || store.isMutating
                              || value.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(killed ? 0.4 : 1)
                    if working { ProgressView().controlSize(.small) }
                }
                if killed {
                    Text("Engine halted. Clear the kill switch first.")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(GruxTheme.destructiveRose)
                }
                if let note = note {
                    Text(note).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(GruxTheme.textTertiary)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("Spawn a new variant", isPresented: $confirming, titleVisibility: .visible) {
            Button("Spawn \(variable) test") { spawn() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Branch a new A/B test changing \(variable) to \"\(value)\"." + (bootstrapped ? "" : " Runs as a simulated no-op (no real spend)."))
        }
    }

    // Routed through the STORE, so this spawn takes the same in-flight flag
    // every other control-plane POST takes (see MetaAdsStore.runCommand).
    // Calling the service directly behind this view's own @State flag left
    // it racing whatever another surface was already writing to the engine.
    private func spawn() {
        working = true; note = nil
        let v = value
        Task { @MainActor in
            let outcome = await store.runCommand("spawnVariant") {
                _ = try await MetaAdsService.spawnVariant(brand: source.brand ?? "", crid: source.crid, variable: variable, value: v)
                // Publishes nothing itself; runCommand owes the pull.
                return false
            }
            // This command's own verdict, for the reason MetaAdsActionBar
            // gives: the shared channel is written by every other surface.
            switch outcome {
            case .failed(let failure):
                note = "Spawn failed: \(failure)"
            case .refused(let advice):
                // NOT a fault: the gate said no and nothing was sent. It is
                // advice to press again, so it lives exactly until they do
                // (cleared at the top of the next press) rather than in the
                // store's sticky channel, where its truth expired without
                // anything noticing for four rounds running.
                note = advice
            case .applied:
                note = bootstrapped ? "Variant queued in the engine." : "Variant queued (simulated)."
                value = ""
            case .cancelled:
                break
            }
            working = false
        }
    }
}
