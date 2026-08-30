import SwiftUI

// MetaAdsStyle: the ONE place that owns formatting helpers and the presentation
// extensions (tint / icon / label) for the power-tool enums. Centralized so no
// two component files extend the same enum (which would collide), and so money,
// percentages, and ratios read identically across the whole tab.
//
// Money is always $N (never the word dollars). Zero em/en dashes.

enum MetaAdsFormat {
    // Whole-dollar $N, or $N.NN under a dollar; compact $N.Nk past a thousand.
    static func dollars(_ cents: Int) -> String {
        let v = Double(cents) / 100.0
        if abs(v) >= 1000 { return String(format: "$%.1fk", v / 1000.0) }
        if v == v.rounded() { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }

    static func dollarsOpt(_ cents: Int?) -> String { cents.map { dollars($0) } ?? "n/a" }

    // A fractional rate 0...1 as a whole percent.
    static func pct(_ frac: Double?) -> String {
        guard let f = frac else { return "n/a" }
        return String(format: "%.0f%%", f * 100)
    }

    // A fractional rate with one decimal (used for CTR-style small numbers).
    static func pct1(_ frac: Double?) -> String {
        guard let f = frac else { return "n/a" }
        return String(format: "%.1f%%", f * 100)
    }

    static func pct2(_ frac: Double?) -> String {
        guard let f = frac else { return "n/a" }
        return String(format: "%.2f%%", f * 100)
    }

    // A signed percent delta (anomalies): "+45%" / "-12%".
    static func signedPct(_ frac: Double?) -> String {
        guard let f = frac else { return "" }
        let s = f >= 0 ? "+" : ""
        return s + String(format: "%.0f%%", f * 100)
    }

    static func ratio(_ x: Double?) -> String {
        guard let r = x else { return "n/a" }
        return String(format: "%.2fx", r)
    }

    static func count(_ n: Int) -> String { n.formatted() }

    // A probability 0...1 as a tight percent for the P(B>A) readouts.
    static func prob(_ p: Double?) -> String {
        guard let p = p else { return "n/a" }
        return String(format: "%.0f%%", p * 100)
    }
}

extension AdStatus {
    var tint: Color {
        switch self {
        case .winner: return GruxTheme.successMint
        case .contender: return GruxTheme.accentCo
        case .learning: return GruxTheme.accentPrimaryLight
        case .killing: return GruxTheme.destructiveRose
        case .paused: return GruxTheme.textTertiary
        }
    }
    var icon: String {
        switch self {
        case .winner: return "trophy.fill"
        case .contender: return "flame.fill"
        case .learning: return "hourglass"
        case .killing: return "xmark.octagon.fill"
        case .paused: return "pause.circle.fill"
        }
    }
    var label: String {
        switch self {
        case .winner: return "WINNER"
        case .contender: return "CONTENDER"
        case .learning: return "LEARNING"
        case .killing: return "KILLING"
        case .paused: return "PAUSED"
        }
    }
}

extension EngineIntent {
    var tint: Color {
        switch self {
        case .scale, .promote: return GruxTheme.successMint
        case .hold: return GruxTheme.textSecondary
        case .spawn: return GruxTheme.accentPrimaryLight
        case .kill: return GruxTheme.destructiveRose
        }
    }
    var icon: String {
        switch self {
        case .scale: return "arrow.up.right.circle.fill"
        case .promote: return "crown.fill"
        case .hold: return "hand.raised.fill"
        case .spawn: return "plus.diamond.fill"
        case .kill: return "xmark.circle.fill"
        }
    }
    var label: String {
        switch self {
        case .scale: return "SCALE"
        case .promote: return "PROMOTE"
        case .hold: return "HOLD"
        case .spawn: return "SPAWN"
        case .kill: return "KILL"
        }
    }
}

extension AttentionSeverity {
    var tint: Color {
        switch self {
        case .critical: return GruxTheme.destructiveRose
        case .warning: return GruxTheme.warnAmber
        case .info: return GruxTheme.accentCo
        }
    }
    var icon: String {
        switch self {
        case .critical: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

extension AttentionKind {
    var label: String {
        switch self {
        case .approval: return "APPROVAL"
        case .anomaly: return "ANOMALY"
        case .drift: return "DRIFT"
        case .fatigue: return "FATIGUE"
        case .budget: return "BUDGET"
        case .winner: return "WINNER"
        case .killProposed: return "KILL"
        case .proposedCampaign: return "NEW CAMPAIGN"
        }
    }
    var icon: String {
        switch self {
        case .approval: return "checkmark.seal.fill"
        case .anomaly: return "waveform.path.ecg"
        case .drift: return "arrow.down.right"
        case .fatigue: return "battery.25"
        case .budget: return "dollarsign.circle.fill"
        case .winner: return "trophy.fill"
        case .killProposed: return "xmark.octagon.fill"
        case .proposedCampaign: return "sparkles"
        }
    }
}

extension FatigueLevel {
    var tint: Color {
        switch self {
        case .ok: return GruxTheme.successMint
        case .watch: return GruxTheme.warnAmber
        case .fatigued: return GruxTheme.destructiveRose
        }
    }
    var label: String {
        switch self {
        case .ok: return "FRESH"
        case .watch: return "WATCH"
        case .fatigued: return "FATIGUED"
        }
    }
}

// A small section eyebrow used across the power-tool surfaces.
struct MetaAdsEyebrow: View {
    let text: String
    var icon: String? = nil
    var tint: Color = GruxTheme.textTertiary
    var body: some View {
        HStack(spacing: 6) {
            if let icon = icon {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            }
            Text(text.uppercased())
                .font(GruxTheme.Font.microCaps)
                .kerning(1.4)
                .foregroundStyle(tint)
        }
    }
}
