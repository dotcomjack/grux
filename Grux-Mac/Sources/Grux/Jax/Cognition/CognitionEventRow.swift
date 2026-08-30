import SwiftUI

// CognitionEventRow: one decision in the trace. Collapsed it shows the trigger,
// the kind badge, a confidence meter, and the gate verdict. Tapped it expands to
// the full real provenance: every heuristic that fired, every memory retrieved,
// the verdict reasoning, mode, and timing.
//
// All fields are REAL persisted provenance from the sibling CognitionEvent type.
// Nothing here is fabricated or implies neural data.

struct CognitionEventRow: View {
    let event: CognitionEvent
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        let verdict = CognitionFormat.verdict(event.gateVerdict)

        VStack(alignment: .leading, spacing: 0) {
            // Header row (always visible, the whole header is the tap target).
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        CognitionKindChip(kind: event.kind)
                        Text(event.trigger.isEmpty ? "(no trigger text)" : event.trigger)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(GruxTheme.textPrimary)
                            .lineLimit(isExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(GruxTheme.textTertiary)
                    }

                    HStack(spacing: 10) {
                        CognitionConfidenceMeter(value: event.confidence)
                            .frame(maxWidth: 160)
                        Spacer(minLength: 0)
                        verdictChip(verdict)
                    }

                    HStack(spacing: 8) {
                        metaTag(icon: "circle.grid.cross.fill", text: "\(event.firedHeuristicNames.count) heuristic\(event.firedHeuristicNames.count == 1 ? "" : "s")")
                        metaTag(icon: "books.vertical.fill", text: "\(event.retrievedMemories.count) memor\(event.retrievedMemories.count == 1 ? "y" : "ies")")
                        if !event.mode.isEmpty {
                            metaTag(icon: "dial.medium.fill", text: event.mode.capitalized)
                        }
                        Spacer(minLength: 0)
                        Text(JaxTime.ago(event.date))
                            .font(GruxTheme.Font.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                detail(verdict: verdict)
                    .padding(.top, 12)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(isExpanded ? 0.045 : 0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(event.kind.tint.opacity(isExpanded ? 0.28 : 0.12), lineWidth: 1)
        )
    }

    // MARK: Detail

    @ViewBuilder
    private func detail(verdict: (label: String, tint: Color, icon: String)) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(Color.white.opacity(0.08))

            // Outcome (what the decision actually led to).
            if !event.outcome.isEmpty {
                detailBlock(icon: "arrow.forward.circle.fill", title: "Outcome", tint: GruxTheme.accentCo) {
                    Text(event.outcome)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(GruxTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Gate verdict + reason.
            detailBlock(icon: verdict.icon, title: "Gate verdict", tint: verdict.tint) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verdict.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(verdict.tint)
                    if !event.gateReason.isEmpty {
                        Text(event.gateReason)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(GruxTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Heuristics that fired (real, from JaxProfile's 38).
            if !event.firedHeuristicNames.isEmpty {
                CognitionTagFlow(
                    icon: "circle.grid.cross.fill",
                    title: "Heuristics that fired",
                    items: event.firedHeuristicNames,
                    tint: GruxTheme.accentPrimaryLight,
                    cap: 12
                )
            }

            // Memories retrieved from the corpus lane (real).
            if !event.retrievedMemories.isEmpty {
                CognitionTagFlow(
                    icon: "books.vertical.fill",
                    title: "Memories retrieved",
                    items: event.retrievedMemories,
                    tint: GruxTheme.accentCo,
                    cap: 10
                )
            }

            // Timing + mode footer.
            HStack(spacing: 8) {
                if event.durationSeconds > 0 {
                    metaTag(icon: "timer", text: CognitionFormat.ms(event.durationSeconds))
                }
                metaTag(icon: "clock", text: JaxTime.clock(event.date))
                Spacer(minLength: 0)
                Text("Real reasoning provenance, not neuro-scan data")
                    .font(GruxTheme.Font.microCaps).kerning(0.6)
                    .foregroundStyle(GruxTheme.textTertiary.opacity(0.8))
            }
        }
    }

    @ViewBuilder
    private func detailBlock<Content: View>(icon: String, title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                Text(title.uppercased())
                    .font(GruxTheme.Font.microCaps).kerning(1.0)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            content()
        }
    }

    // MARK: Small bits

    private func verdictChip(_ v: (label: String, tint: Color, icon: String)) -> some View {
        HStack(spacing: 4) {
            Image(systemName: v.icon).font(.system(size: 8, weight: .bold))
            Text(v.label).font(.system(size: 10, weight: .heavy)).lineLimit(1)
        }
        .foregroundStyle(v.tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(v.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(v.tint.opacity(0.30), lineWidth: 1))
    }

    private func metaTag(icon: String, text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8, weight: .semibold))
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(GruxTheme.textTertiary)
    }
}
