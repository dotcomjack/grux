import SwiftUI

// MetaAdsOpsSection: the paid-social roll-up that lives inside the Empire
// Dashboard, slotted after SocialOpsSection (U5 owns the actual insertion
// line in EmpireDashboardWindow so this unit stays purely additive and never
// edits an existing file).
//
// It clones the shape of EmpireOpsSection (EmpireDashboard.swift): an
// @ObservedObject .shared store, a one-line subtitle helper, a refresh on
// appear, graceful empty / loading / error states. The visual language is
// the cyan paid-social accent (GruxTheme.accentCo) rather than mint, so the
// reader instantly knows this card is the autonomous Meta ads engine, not the
// org-wide ops snapshot.
//
// In SIMULATE/OBSERVE mode the store reads the snapshot the companion engine
// emits (default mode OBSERVE, no live spend, every brand still on
// act_PLACEHOLDER) so the whole card proves out with mock insights and zero
// live assets.
//
// DEPENDENCIES (sibling MetaAds units, file-disjoint, resolved at link time):
//   - U1  MetaAdsStore.shared + the MetaAdsSnapshot / MetaAdsBrandStat /
//         MetaAdsJournalEntry / MetaAdsMode types and the .refresh()/.load()
//         pull (mirrors EmpireSnapshotStore).
//   - U2  MetaAdsPacingBar(brand:) compact spend-vs-cap bar.
//   - U3  MetaAdsJournalRow(entry:) decision-journal row + MetaAdsModeControl()
//         mode picker and kill switch.
// This unit only composes those; it defines nothing they own.

struct MetaAdsOpsSection: View {
    @ObservedObject private var store = MetaAdsStore.shared

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // commandError outranks the fetch error (a mode flip or kill that
            // never applied stays visible; refresh never clears it), and typed
            // absence never reaches the warning banner: on a fresh install the
            // three-paragraph explanation used to render inside a warning
            // triangle here, which reads as a fault where nothing is wrong.
            if let cmdErr = store.commandError {
                errorBanner(cmdErr, showsRetry: false) { store.acknowledgeCommandError() }
            } else if store.servingStale, let err = store.lastError {
                // THE STALE ARM THIS CARD NEVER HAD. The condition carried
                // `snapshot == nil`, so a configured engine going down while a
                // cached snapshot was held said nothing at all: the Empire
                // dashboard kept rendering yesterday's spend numbers under a
                // 7pt CACHED chip, with no statement of what failed. All four
                // sibling sections print exactly this sentence, and it is the
                // silent-stale defect the wave removed everywhere else.
                errorBanner("Showing cached numbers. Last pull failed: \(err)")
            } else if let err = store.lastError, store.snapshot == nil,
                      !store.lastErrorIsAbsence {
                errorBanner(err)
            }
            if let snap = store.snapshot {
                summaryStrip(snap)
                if expanded {
                    expandedBody(snap)
                }
            } else if store.isFetching {
                loading
            } else if store.lastErrorIsAbsence {
                // A command fault may not suppress this card: absence is true
                // only when nothing is configured, which is why the command
                // went nowhere, so the banner names the cause and this names
                // the remedy.
                absenceNotice
            } else if store.lastError == nil {
                empty
            }
        }
        .onAppear {
            store.load()
            if store.lastUpdated == nil
                || Date().timeIntervalSince(store.lastUpdated!) > 60 {
                Task { await store.refresh() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "megaphone.fill")
                .foregroundStyle(GruxTheme.accentCo)
            Text("Meta Ads").font(.headline)
            modeBadge
            if store.servingStale {
                Text("CACHED")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(GruxTheme.warnAmber.opacity(0.20))
                    .foregroundStyle(GruxTheme.warnAmber)
                    .clipShape(Capsule())
            }
            if store.snapshot?.killSwitchEngaged == true {
                Text("KILL SWITCH")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(GruxTheme.destructiveRose.opacity(0.20))
                    .foregroundStyle(GruxTheme.destructiveRose)
                    .clipShape(Capsule())
            }
            Spacer()
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            if store.isFetching { ProgressView().controlSize(.mini) }
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
            }
            .buttonStyle(.borderless)
            .help(expanded ? "Collapse the Meta ads panel" : "Expand the Meta ads panel")
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isFetching)
            .help("Pull a fresh engine snapshot from the render service")
        }
    }

    // Mode pill: OBSERVE (cyan, default) / RECOMMEND (amber) / AUTONOMOUS (mint).
    @ViewBuilder
    private var modeBadge: some View {
        if let mode = store.snapshot?.mode {
            let color = modeColor(mode)
            Text(mode.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(color.opacity(0.18))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
    }

    private func modeColor(_ mode: String) -> Color {
        switch mode.uppercased() {
        case "AUTONOMOUS": return GruxTheme.successMint
        case "RECOMMEND": return GruxTheme.warnAmber
        default: return GruxTheme.accentCo   // OBSERVE
        }
    }

    // Subtitle mirrors EmpireOpsSection: mode | spend | winners | contenders |
    // graveyard, plus a freshness stamp.
    private var subtitle: String {
        guard let s = store.snapshot else {
            return "mode · spend · winners · contenders · graveyard"
        }
        var parts: [String] = []
        parts.append(s.mode.lowercased())
        parts.append("spend \(money(s.spendTodayCents)) / \(money(s.effectiveDailyCapCents))")
        parts.append("\(s.winnerCount)W · \(s.contenderCount)C · \(s.graveyardCount)G")
        if let t = store.lastUpdated {
            let f = DateFormatter(); f.timeStyle = .short
            parts.append("updated \(f.string(from: t))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Collapsed summary

    // The one-line-at-a-glance strip: mode, today's spend vs the hard cap, and
    // the Winners / Contenders / Graveyard roll-up across brands. Always shown.
    private func summaryStrip(_ s: MetaAdsSnapshot) -> some View {
        let spendColor: Color = s.spendTodayCents >= s.effectiveDailyCapCents
            ? GruxTheme.destructiveRose
            : (Double(s.spendTodayCents) >= Double(s.effectiveDailyCapCents) * 0.8
               ? GruxTheme.warnAmber : GruxTheme.accentCo)
        return HStack(spacing: 10) {
            kpiTile("Mode", s.mode.uppercased(), modeColor(s.mode), "dot.radiowaves.left.and.right")
            kpiTile("Spend today",
                    "\(money(s.spendTodayCents)) / \(money(s.effectiveDailyCapCents))",
                    spendColor, "gauge.with.dots.needle.50percent")
            kpiTile("Winners", "\(s.winnerCount)", GruxTheme.successMint, "trophy.fill")
            kpiTile("Contenders", "\(s.contenderCount)", GruxTheme.accentCo, "flask.fill")
            kpiTile("Graveyard", "\(s.graveyardCount)",
                    s.graveyardCount > 0 ? GruxTheme.textSecondary : .secondary, "xmark.bin.fill")
        }
    }

    private func kpiTile(_ label: String, _ value: String, _ color: Color, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    // MARK: - Expanded body

    @ViewBuilder
    private func expandedBody(_ s: MetaAdsSnapshot) -> some View {
        // Wrapped in the paid-social glass card so the expanded detail reads as
        // one cohesive panel against the rest of the Empire dashboard.
        GruxGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                // Per-brand spend pacing (U2 MetaAdsPacingBar).
                if !s.brands.isEmpty {
                    sectionLabel("PACING VS CAPS")
                    VStack(spacing: 8) {
                        ForEach(s.brands) { brand in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(brand.brandName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(GruxTheme.textPrimary)
                                    if !brand.isBootstrapped {
                                        Text("PLACEHOLDER")
                                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(GruxTheme.textTertiary.opacity(0.18))
                                            .foregroundStyle(GruxTheme.textSecondary)
                                            .clipShape(Capsule())
                                            .help("act_PLACEHOLDER: cannot act live, simulate only")
                                    }
                                    Spacer()
                                    Text("\(money(brand.spendTodayCents)) / \(money(brand.dailyCapCents))")
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(GruxTheme.textSecondary)
                                }
                                MetaAdsPacingBar(
                                    label: "Today",
                                    spentCents: brand.spendTodayCents,
                                    capCents: brand.dailyCapCents,
                                    softCapCents: MetaAdsCaps.effectiveDailyBudgetCents
                                )
                            }
                        }
                    }
                }

                // Latest 3 decision-journal entries (U3 MetaAdsJournalRow).
                if !s.journal.isEmpty {
                    sectionLabel("DECISION JOURNAL")
                    // Reuse the journal view (U3), capped to the latest 3 rows and
                    // headerless so it reads as a compact embed inside the ops card.
                    MetaAdsJournalView(maxRows: 3, showsHeader: false)
                } else {
                    Text("No decisions logged yet. The engine writes a rationale on every spawn, kill, and scale.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                // Mode + kill switch (U3 MetaAdsModeControl).
                Divider().opacity(0.4)
                MetaAdsModeControl()
            }
            .padding(16)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .heavy, design: .monospaced))
            .kerning(1.1)
            .foregroundStyle(.tertiary)
    }

    // MARK: - States

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Pulling the Meta ads engine snapshot from the render service…")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "megaphone")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No engine snapshot yet").font(.subheadline.bold())
            Text("Refresh to pull mode, spend pacing, winners, contenders, and the decision journal.")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    // The honest unconfigured state, compact enough for a dashboard card. The
    // full explainer (OperatorToolNoticeView) is a whole-pane scroll view, so
    // the Meta Ads tab carries it and this card points there instead.
    private var absenceNotice: some View {
        VStack(spacing: 6) {
            Image(systemName: "megaphone")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No ads engine connected").font(.subheadline.bold())
            // NAMES THE KEY. It used to promise "the Meta Ads tab explains
            // how to point Grux at your own", and that tab's absence surface
            // is OperatorToolNoticeView, whose copy never mentions the
            // defaults key: it suggests reading the source with an AI. The
            // one sentence that answers the question is
            // PrivateServiceNotice.metaAds.configSource, which nothing in
            // that tab renders. A reader who followed the pointer did not
            // find what it promised, which is the cannot-be-followed
            // instruction this wave removes everywhere else. Read from the
            // notice so the two cannot drift.
            Text("This card mirrors an autonomous Meta ads engine its author runs on a separate machine. Running without one is the normal state. \(PrivateServiceNotice.metaAds.configSource)")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    // showsRetry is false for command faults: the retry button re-pulls a
    // snapshot, which cannot re-send a command, so offering it there would
    // look like a fix that does nothing. Re-tapping the control retries.
    // onDismiss is the command banner's exit: without one, this branch
    // outranking the fetch banner means a stale command fault hides any
    // newer fetch failure until the next command or app relaunch.
    private func errorBanner(_ message: String, showsRetry: Bool = true,
                             onDismiss: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GruxTheme.warnAmber)
            Text(message).font(.caption).textSelection(.enabled)
            Spacer()
            if showsRetry {
                Button("Retry") { Task { await store.refresh() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .foregroundStyle(GruxTheme.warnAmber)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss. Re-tapping the control retries the command.")
            }
        }
        .padding(10)
        .background(GruxTheme.warnAmber.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Helpers

    // Compact money. Cents in, $N out (always the $N symbol form).
    private func money(_ cents: Int?) -> String {
        guard let c = cents else { return "n/a" }
        let v = Double(c) / 100.0
        if v >= 1000 { return String(format: "$%.1fk", v / 1000.0) }
        if v == v.rounded() { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
}
