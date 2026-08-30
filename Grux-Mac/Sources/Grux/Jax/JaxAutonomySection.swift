import SwiftUI

// JaxAutonomySection: the Phase 4 surface that makes Jax's send autonomy legible
// and controllable, per brand. AutonomyLedger tracks how Jax has been doing per
// brand (clean sends, edited sends, gate blocks) and computes a graduation
// readiness from that history. This surface shows that status and gives the user
// the manual lever: flip a brand between OBSERVE (Jax drafts, they send) and LIVE
// (Jax auto-sends, but only what the output gate clears). Brand-filtered like the
// Drafts, Filtered, and Lessons sections. The toggle is the one autonomy control
// the user holds: nothing graduates itself to LIVE, the readiness line only earns
// the recommendation.
struct JaxSendAutonomySection: View {
    @ObservedObject private var ledger = AutonomyLedger.shared
    @ObservedObject private var brand = BrandFilter.shared

    // The brands that have a live support inbox are always shown (even with zero
    // history) so the OBSERVE/LIVE control is always reachable, unioned with any
    // brand that has a recorded history. Filtered by the active brand scope.
    // Derived from the support-inbox roster rather than a second hardcoded list,
    // so there is one place brands are declared and this surface can never drift
    // from it. An empty roster simply renders nothing (see `body`).
    private static var canonicalBrands: [String] { SupportInbox.roster.map(\.rawValue) }

    private var shownBrands: [BrandAutonomyRecord] {
        var byBrand = ledger.records
        for b in Self.canonicalBrands where byBrand[b] == nil {
            byBrand[b] = BrandAutonomyRecord(brand: b, sentClean: 0, sentEdited: 0,
                                             gateBlocks: 0, mode: ledger.mode(forBrand: b))
        }
        return byBrand.values
            .filter { brand.scope.matches(voice: $0.brand) }
            .sorted { $0.brand < $1.brand }
    }

    var body: some View {
        // Stay quiet when there is no autonomy history for the current brand: this
        // is a secondary surface, it should not shout an empty box.
        if !shownBrands.isEmpty {
            JaxSection(
                title: "Autonomy", icon: "gauge.with.dots.needle.67percent",
                tint: GruxTheme.accentPrimaryLight, count: shownBrands.count
            ) {
                Text("How much \(UserIdentity.assistantName) sends on its own, per brand. LIVE auto-sends only what the output gate clears.")
                    .font(.system(size: 11.5)).foregroundStyle(GruxTheme.textTertiary)
                    .padding(.bottom, 4)
                ForEach(shownBrands, id: \.brand) { JaxAutonomyRow(record: $0) }
            }
        }
    }
}

private struct JaxAutonomyRow: View {
    let record: BrandAutonomyRecord

    var body: some View {
        let r = AutonomyLedger.shared.readiness(forBrand: record.brand)

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                // The roster's own display text, not the raw token: the token is
                // an identifier, and a brand whose label is not just its id
                // upcased would otherwise render wrong here alone.
                pill(BrandRoster.label(forId: record.brand), GruxTheme.accentPrimary)
                Spacer()
                modeToggle
            }

            HStack(spacing: 6) {
                Text("\(record.sentClean) clean / \(record.sentEdited) edited")
                    .font(.system(size: 11.5)).foregroundStyle(GruxTheme.textSecondary)
                if record.gateBlocks > 0 {
                    Text("\(record.gateBlocks) blocked")
                        .font(.system(size: 11.5)).foregroundStyle(GruxTheme.destructiveRose)
                }
            }

            readinessLine(r)
        }
        .padding(12)
        .background(Color(red: 0x14/255, green: 0x12/255, blue: 0x0d/255))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(GruxTheme.textTertiary.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func readinessLine(_ r: (ready: Bool, cleanSends: Int, needed: Int, editRate: Double, gateBlocks: Int)) -> some View {
        if record.mode == .live {
            Text("LIVE, auto-sending")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(GruxTheme.successMint)
        } else if r.ready {
            Text("Ready to go live")
                .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(GruxTheme.successMint)
        } else {
            Text("\(r.needed) more clean sends to graduate")
                .font(.system(size: 11.5)).foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var modeToggle: some View {
        // Earned graduation: LIVE is only selectable once the brand is ready (or is
        // already live, so it can be toggled back to OBSERVE). This is the enforced
        // gate, the readiness line is the advisory. Premature auto-send is therefore
        // not reachable through the UI, the only graduation path.
        let ready = AutonomyLedger.shared.graduationReady(forBrand: record.brand)
        let liveEnabled = record.mode == .live || ready
        return HStack(spacing: 0) {
            segment("OBSERVE", active: record.mode == .observe, enabled: true) {
                AutonomyLedger.shared.setMode(.observe, forBrand: record.brand)
            }
            segment("LIVE", active: record.mode == .live, enabled: liveEnabled) {
                AutonomyLedger.shared.setMode(.live, forBrand: record.brand)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(GruxTheme.textTertiary.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .help(liveEnabled ? "Toggle auto-send for this brand" : "LIVE unlocks once this brand is ready to graduate")
    }

    private func segment(_ text: String, active: Bool, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 9.5, weight: .bold)).tracking(0.4)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(active ? GruxTheme.accentPrimary.opacity(0.22) : Color.clear)
                .foregroundStyle(!enabled ? GruxTheme.textTertiary.opacity(0.4)
                                 : (active ? GruxTheme.accentPrimaryLight : GruxTheme.textTertiary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold)).tracking(0.4)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.16)).foregroundStyle(color).clipShape(Capsule())
    }
}
