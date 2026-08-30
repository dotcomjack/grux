import SwiftUI

// CognitionMapView: the honest "brain map". This is the visual surface over the
// REAL decision-provenance log that the sibling CognitionTrace records on every
// Jax decision (a chat prompt, a directive, a queued task, a goal-pursuit cycle).
//
// HONESTY CONTRACT (non-negotiable):
//   Everything shown here is REAL provenance the app actually computed: which of
//   the 38 JaxProfile heuristics matched, which corpus memories were retrieved,
//   the DecisionGate verdict, a computed confidence score, the autonomy mode, and
//   timing. There is NO neural / fMRI / brain-scan / brain-wave data anywhere in
//   this app, so this surface NEVER implies any. It is a decision / cognition
//   trace, framed honestly. The constellation is a layout of real heuristic and
//   decision nodes, not a depiction of a brain.
//
// Binds to the REAL sibling singleton CognitionTrace.shared (no parallel state):
//   CognitionTrace.shared.events  -> [CognitionEvent] newest-first
//   CognitionTrace.shared.rollup  -> CognitionRollup (avg confidence, low-confidence
//                                    count, counts by kind, top fired heuristics)
// Both are @Published on a @MainActor ObservableObject. This file references those
// published types; it does not redefine them.
//
// Rendered entirely in GruxTheme so it reads as a first-class CURRENT surface,
// money is $N, zero em/en dashes, tight controls.

struct CognitionMapView: View {
    @ObservedObject private var trace = CognitionTrace.shared
    @ObservedObject private var brand = BrandFilter.shared
    @ObservedObject private var appState = AppState.shared

    // Which event row is expanded to full detail. nil = all collapsed.
    @State private var expandedID: CognitionEvent.ID?

    private static let logCap = 60

    // The decision log narrowed by the app-wide brand filter (decision 4). A
    // decision with no brand (a general chat turn) shows only under "All", so a
    // brand view stays a clean, honest slice of just that brand's decisions.
    private var filteredEvents: [CognitionEvent] {
        guard brand.scope != .all else { return trace.events }
        return trace.events.filter { event in
            guard let b = event.brand else { return false }
            return brand.scope.matches(voice: b)
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero

                    if trace.events.isEmpty {
                        emptyState
                    } else {
                        BrandFilterBar(trailing: brand.scope == .all
                                       ? nil
                                       : "\(filteredEvents.count) of \(trace.events.count)")
                        // Only draw the constellation when there are real heuristic
                        // nodes to anchor it. With events but zero fired heuristics
                        // (an honest, reachable state), there would be no nodes and no
                        // lines, so the constellation would render floating sparks that
                        // contradict its own caption. The rollup + log still show.
                        if !trace.rollup.topHeuristics.isEmpty {
                            CognitionConstellation(
                                nodes: trace.rollup.topHeuristics,
                                events: Array(filteredEvents.prefix(8))
                            )
                        }
                        rollupRow
                        if filteredEvents.isEmpty {
                            Text("No \(brand.scope.label) decisions traced yet. Switch the brand filter to see others.")
                                .font(GruxTheme.Font.body)
                                .foregroundStyle(GruxTheme.textTertiary)
                                .italic()
                                .padding(.vertical, 8)
                        } else {
                            log
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(GruxTheme.base)
            .onAppear {
                trace.load()
                focusIfRequested(proxy)
            }
            .onChange(of: appState.cognitionFocus) { _, _ in focusIfRequested(proxy) }
        }
    }

    // Deep-link target (decision 4): the Jax HQ draft card sets
    // AppState.cognitionFocus to a draft id and switches to this tab. Find the
    // decision whose correlationId matches, make sure the brand filter is not
    // hiding it, expand it, scroll it into view, then clear the request so it
    // does not re-fire.
    private func focusIfRequested(_ proxy: ScrollViewProxy) {
        guard let target = appState.cognitionFocus,
              let hit = trace.events.first(where: { $0.correlationId == target }) else { return }
        // Make the target visible: a brand-scoped view could otherwise hide it.
        if let b = hit.brand, !brand.scope.matches(voice: b) {
            brand.scope = BrandScope(rawValue: b) ?? .all
        } else if hit.brand == nil, brand.scope != .all {
            brand.scope = .all
        }
        expandedID = hit.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(hit.id, anchor: .center) }
            appState.cognitionFocus = nil
        }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(GruxTheme.iridescent)
                        .frame(width: 38, height: 38)
                        .shadow(color: GruxTheme.violetGlow(strong: true), radius: 12)
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    MetaAdsEyebrow(text: "The real circuitry behind each decision", tint: GruxTheme.accentPrimaryLight)
                    Text("Cognition Map")
                        .font(GruxTheme.Font.title)
                        .foregroundStyle(GruxTheme.textPrimary)
                }
                Spacer()
                if !trace.events.isEmpty {
                    statPill(count: trace.events.count, label: "DECISIONS", tint: GruxTheme.accentPrimaryLight, icon: "brain.head.profile")
                }
            }

            // The honesty line. Always visible so the surface can never be mistaken
            // for neuro-scan data.
            HStack(spacing: 6) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(GruxTheme.successMint)
                Text("Real reasoning provenance, not neuro-scan data. Every node is a heuristic that fired, a memory that was retrieved, or a gate verdict.")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .fill(GruxTheme.successMint.opacity(0.07))
            )
        }
    }

    private func statPill(count: Int, label: String, tint: Color, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
            Text("\(count)").font(.system(size: 12, weight: .heavy, design: .rounded))
            Text(label).font(GruxTheme.Font.microCaps).kerning(1.2)
        }
        .foregroundStyle(count > 0 ? tint : GruxTheme.textTertiary)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill((count > 0 ? tint : Color.white).opacity(count > 0 ? 0.14 : 0.05)))
        .overlay(Capsule().strokeBorder((count > 0 ? tint : Color.white).opacity(count > 0 ? 0.35 : 0.10), lineWidth: 1))
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: 76, height: 76)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            VStack(spacing: 5) {
                Text("No decisions traced yet")
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                Text("The map fills in as \(UserIdentity.assistantName) decides. Send a prompt, give a directive, or let a goal-pursuit cycle run, and every decision lands here with the heuristics that fired, the memories it pulled, the gate verdict, and a confidence score.")
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }

    // MARK: Rollup stats

    private var rollupRow: some View {
        let r = trace.rollup
        return JaxSection(title: "At a glance", icon: "chart.bar.xaxis", tint: GruxTheme.textSecondary) {
            HStack(spacing: 10) {
                CognitionStatCard(
                    value: r.avgConfidence > 0 ? CognitionFormat.pct(r.avgConfidence) : "n/a",
                    label: "Avg confidence",
                    tint: CognitionFormat.confidenceTint(r.avgConfidence),
                    icon: "gauge.with.dots.needle.67percent"
                )
                CognitionStatCard(
                    value: "\(r.lowConfidenceCount)",
                    label: "Paused to clarify",
                    tint: r.lowConfidenceCount > 0 ? GruxTheme.warnAmber : GruxTheme.textTertiary,
                    icon: "questionmark.bubble.fill"
                )
                CognitionStatCard(
                    value: "\(r.events.count)",
                    label: "Decisions traced",
                    tint: GruxTheme.accentPrimaryLight,
                    icon: "list.number"
                )
            }
            if !r.countsByKind.isEmpty {
                HStack(spacing: 6) {
                    ForEach(CognitionEvent.Kind.allCases, id: \.self) { kind in
                        let n = r.countsByKind[kind] ?? 0
                        if n > 0 {
                            CognitionKindChip(kind: kind, count: n)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: Log (newest first, tappable rows)

    private var log: some View {
        let shown = Array(filteredEvents.prefix(Self.logCap))
        return JaxSection(
            title: "Decision trace",
            icon: "list.bullet.rectangle.portrait.fill",
            tint: GruxTheme.textSecondary,
            count: filteredEvents.count
        ) {
            VStack(spacing: 8) {
                ForEach(shown) { event in
                    CognitionEventRow(
                        event: event,
                        isExpanded: expandedID == event.id,
                        onTap: {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                expandedID = (expandedID == event.id) ? nil : event.id
                            }
                        }
                    )
                    .id(event.id)
                }
            }
        }
    }
}
