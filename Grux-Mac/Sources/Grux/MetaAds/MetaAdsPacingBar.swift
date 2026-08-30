import SwiftUI

// MetaAdsPacingBar (Unit U2)
//
// A reusable horizontal "spend vs cap" bar for the Meta Ads tab. It renders a
// filled track whose width is the fraction of a hard cap consumed, plus a $N
// label pair (spent / cap). The fill turns warnAmber over 80% of the cap and
// destructiveRose at or over the cap, so a glance tells the user whether the
// autonomous engine is pacing inside the un-overridable guardrails.
//
// The cap values it shows are the engine's HARD CAPS (engine/caps.py constants,
// never read from config): the effective daily budget is $16 ($20 / 1.25 to
// absorb Meta's up-to-25% overspend), and the weekly spend cap is $140. This bar
// only DISPLAYS pacing; it never relaxes a cap. All money is formatted from cents
// to $N (whole-dollar), never spelled out as the word dollars.
//
// Self-contained: depends only on GruxTheme + AppKit colors, so U1's store/types
// are not required for this file to compile. Reused by MetaAdsView's pacing
// section (daily vs the $16 effective and $20 hard caps, weekly vs $140).

struct MetaAdsPacingBar: View {
    let label: String          // e.g. "Today" or "This week"
    let spentCents: Int        // observed spend so far in the window
    let capCents: Int          // the hard cap this window is paced against
    var softCapCents: Int? = nil   // optional secondary marker (e.g. $16 effective inside the $20 hard cap)

    private var fraction: Double {
        guard capCents > 0 else { return 0 }
        return min(max(Double(spentCents) / Double(capCents), 0), 1)
    }

    // <80% mint, 80-99% amber, >=100% rose. The engine should never breach the
    // cap (it is a code constant), so rose is a "something is very wrong" tell.
    private var fillColor: Color {
        if spentCents >= capCents { return GruxTheme.destructiveRose }
        if fraction >= 0.80 { return GruxTheme.warnAmber }
        return GruxTheme.successMint
    }

    // Where the optional soft-cap marker sits along the track, 0...1.
    private var softMarkerFraction: Double? {
        guard let soft = softCapCents, capCents > 0, soft < capCents else { return nil }
        return min(max(Double(soft) / Double(capCents), 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.0)
                    .foregroundStyle(GruxTheme.textTertiary)
                Spacer()
                Text("\(dollars(spentCents)) / \(dollars(capCents))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(fillColor)
                Text("(\(Int((fraction * 100).rounded()))%)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                    // Fill
                    Capsule()
                        .fill(fillColor.opacity(0.85))
                        .frame(width: max(3, geo.size.width * fraction))
                        .shadow(color: fillColor.opacity(0.45), radius: 4)
                    // Optional soft-cap marker (the $16 effective line on the $20 hard track)
                    if let mark = softMarkerFraction {
                        Rectangle()
                            .fill(GruxTheme.accentCo.opacity(0.85))
                            .frame(width: 1.5)
                            .offset(x: geo.size.width * mark)
                    }
                }
            }
            .frame(height: 8)

            if let soft = softCapCents, soft < capCents {
                Text("effective cap \(dollars(soft)) (cyan)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(GruxTheme.accentCo.opacity(0.8))
            }
        }
    }

    // Cents to whole-dollar $N. Never spells the word dollars (copy rule).
    private func dollars(_ cents: Int) -> String {
        let v = Double(cents) / 100.0
        if v >= 1000 { return String(format: "$%.1fk", v / 1000.0) }
        if v == v.rounded() { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
}
