import SwiftUI

// U3 (Meta Ads): per-brand mode control. A segmented control letting the user set
// each brand's engine mode: SIMULATE, OBSERVE (default), RECOMMEND, or
// AUTONOMOUS. Selecting a mode calls MetaAdsService.setMode(brand:mode:).
//
// The live double-gate is made VISIBLE here: AUTONOMOUS is disabled, greyed,
// and lock-iconed for any brand that is NOT bootstrapped. A brand still on
// act_PLACEHOLDER can never have its AUTONOMOUS segment tapped, which mirrors
// the engine's own registry.require_bootstrapped() block exactly. The kill switch (U3) overrides
// everything: when it is on, the whole control is disabled and reads OBSERVE.
//
// MetaAdsMode, MetaAdsBrandState, MetaAdsService, MetaAdsStore are owned by U1.

struct MetaAdsModeControl: View {
    // Optional explicit brand state; when nil we derive the snapshot-wide default
    // so the embedded ops card can use MetaAdsModeControl() with no argument.
    private let explicitBrand: MetaAdsBrandState?

    init(brand: MetaAdsBrandState? = nil) {
        self.explicitBrand = brand
    }

    @ObservedObject private var store = MetaAdsStore.shared

    private var brand: MetaAdsBrandState {
        explicitBrand ?? MetaAdsBrandState.global(from: store.snapshot)
    }
    @State private var isWorking = false
    @State private var lastError: String?

    private var killed: Bool { store.snapshot?.killSwitchOn ?? false }
    private var current: MetaAdsMode { killed ? .observe : brand.mode }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(brand.displayName)
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textPrimary)
                if !brand.bootstrapped {
                    placeholderTag
                }
                Spacer()
                if isWorking { ProgressView().controlSize(.mini) }
            }

            segmented

            if killed {
                Text("Kill switch is on. Cleared per-brand control returns when you clear the halt.")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(GruxTheme.destructiveRose.opacity(0.9))
            } else if let err = lastError {
                Text(err)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(GruxTheme.warnAmber)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var placeholderTag: some View {
        Text("act_PLACEHOLDER")
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(GruxTheme.textTertiary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .help("Not a bootstrapped ad account. AUTONOMOUS is physically blocked.")
    }

    private var segmented: some View {
        HStack(spacing: 5) {
            ForEach(MetaAdsMode.allCases, id: \.self) { mode in
                modeSegment(mode)
            }
        }
        .disabled(killed || isWorking)
        .opacity(killed ? 0.5 : 1.0)
    }

    @ViewBuilder
    private func modeSegment(_ mode: MetaAdsMode) -> some View {
        let locked = (mode == .autonomous) && !brand.bootstrapped
        let selected = (current == mode)
        let tint = mode.tint

        Button {
            guard !locked else { return }
            Task { await select(mode) }
        } label: {
            HStack(spacing: 3) {
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold))
                }
                Text(mode.label)
                    .font(.system(size: 11, weight: selected ? .bold : .semibold))
            }
            .foregroundStyle(segmentForeground(selected: selected, locked: locked, tint: tint))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? tint.opacity(0.20) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? tint.opacity(0.55) : Color.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // Also off while the store is applying another control action. Every
        // control-plane POST in the tab now runs through the store (see
        // MetaAdsStore.runCommand), so this flag is raised by all of them and
        // two writes can never race to the engine from different surfaces.
        .disabled(locked || store.isMutating)
        .help(locked
              ? "AUTONOMOUS needs a bootstrapped ad account. This brand is act_PLACEHOLDER, so live action is blocked."
              : mode.helpText)
    }

    private func segmentForeground(selected: Bool, locked: Bool, tint: Color) -> Color {
        if locked { return GruxTheme.textTertiary.opacity(0.6) }
        if selected { return tint }
        return GruxTheme.textSecondary
    }

    // Routed through the STORE, so the one flag that governs control-plane
    // writes is the one this view's own .disabled() reads. It used to call
    // MetaAdsService directly behind `isWorking`, a @State flag private to
    // this instance, while the segment below claimed store.isMutating made a
    // race impossible: a mode POST runs up to 12s per base, and Emergency
    // Stop sat enabled beside it for every second of that.
    private func select(_ mode: MetaAdsMode) async {
        guard !isWorking, mode != brand.mode else { return }
        // NOT cleared on entry. Clearing here made the `.cancelled: break`
        // arm below DEAD: it exists so a torn-down command preserves the
        // last real verdict, and there was never anything left to preserve.
        // The next verdict overwrites this anyway, so a refusal still stops
        // being shown as soon as the next press produces one.
        isWorking = true
        defer { isWorking = false }
        // This flip's own verdict, not whatever the shared channel holds by
        // the time the await returns. .cancelled leaves lastError alone for
        // the reason MetaAdsKillSwitch gives: no verdict exists to report.
        switch await store.setMode(brand: brand.key, mode: mode.engineValue) {
        case .failed(let message): lastError = message
        case .refused(let advice): lastError = advice
        case .applied: lastError = nil
        case .cancelled: break
        }
    }
}

// MARK: - Mode visual tokens

// Color + label + help for each mode, drawn from GruxTheme. Kept here (not in U1)
// because it is purely presentation: SIMULATE / OBSERVE are calm, RECOMMEND
// leans co-pilot cyan, AUTONOMOUS is the violet "the engine is driving" accent.
extension MetaAdsMode {
    var label: String {
        switch self {
        case .simulate:   return "SIM"
        case .observe:    return "OBS"
        case .recommend:  return "REC"
        case .autonomous: return "AUTO"
        }
    }

    var tint: Color {
        switch self {
        case .simulate:   return GruxTheme.textSecondary
        case .observe:    return GruxTheme.accentCo
        case .recommend:  return GruxTheme.warnAmber
        case .autonomous: return GruxTheme.accentPrimary
        }
    }

    var helpText: String {
        switch self {
        case .simulate:   return "SIMULATE: feed the loop mock insights, prove it end to end, touch nothing."
        case .observe:    return "OBSERVE (default): watch live data, log every decision, apply nothing."
        case .recommend:  return "RECOMMEND: surface decisions for human approval before any action."
        case .autonomous: return "AUTONOMOUS: the engine applies decisions itself. Requires a bootstrapped account."
        }
    }
}
