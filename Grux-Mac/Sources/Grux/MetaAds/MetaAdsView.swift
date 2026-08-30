import SwiftUI

// MetaAdsView: the root of the Meta Ads power tool. An attention-first OVERSIGHT
// COCKPIT over the autonomous engine (reads the snapshot, OBSERVE by default,
// act_PLACEHOLDER so nothing spends). Three levels of progressive
// disclosure, navigation held as plain @State here since the store carries every
// brand in one snapshot:
//
//   LEVEL 0  fleet command deck (this view's default): command bar, portfolio
//            roll-up, the attention queue (only when something needs the user), then
//            the sortable per-brand fleet.
//   LEVEL 1  brand drill (MetaAdsBrandDetailView), pushed by selecting a brand.
//   LEVEL 2  ad detail (MetaAdsAdDetailView), pushed from an ad row or tile.
//
// All money $N, zero em/en dashes, GruxTheme tokens.
struct MetaAdsView: View {
    @ObservedObject private var store = MetaAdsStore.shared

    @State private var selectedBrandKey: String?
    // Hold the ad by id, not by value, and re-resolve from the live snapshot each
    // render. So the detail view never shows stale data after a poll, and if the
    // engine drops the ad (killed) it cleanly falls back to the brand drill
    // instead of showing a captured ghost.
    @State private var selectedAdId: String?

    private var resolvedAd: ActiveAd? {
        guard let id = selectedAdId else { return nil }
        return store.snapshot?.brands.flatMap { $0.activeAds }.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let ad = resolvedAd {
                MetaAdsAdDetailView(ad: ad) { selectedAdId = nil }
            } else if let key = selectedBrandKey, let brand = brand(for: key) {
                MetaAdsBrandDetailView(
                    brand: brand,
                    snapshotMode: store.snapshot?.mode ?? "OBSERVE",
                    onBack: { selectedBrandKey = nil; selectedAdId = nil },
                    onSelectAd: { ad in
                        selectedAdId = ad.id
                        if selectedBrandKey == nil { selectedBrandKey = ad.brand }
                    }
                )
            } else {
                fleetDeck
            }
        }
        // All three branches are card stacks, so the cap goes on the Group
        // rather than being repeated in each. At a 2400pt window the EMPIRE
        // ROLL-UP spread its six columns until the trailing labels were
        // unreadable, and every FLEET row clustered its spend figures into the
        // left quarter with 2000pt of empty space beside them.
        //
        // The second .frame is not redundant: the background has to keep
        // painting the WHOLE pane, otherwise the capped column sits on a
        // 1200pt-wide slab of GruxTheme.base with bare window either side.
        .frame(maxWidth: GruxLayout.contentMax)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GruxTheme.base)
        .onAppear {
            store.load()
            if store.lastUpdated == nil
                || Date().timeIntervalSince(store.lastUpdated ?? .distantPast) > 60 {
                Task { await store.refresh() }
            }
        }
    }

    private func brand(for key: String) -> MetaAdsBrand? {
        store.snapshot?.brands.first { $0.slug == key || $0.id == key }
    }

    // MARK: Level 0, the fleet command deck

    private var fleetDeck: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                commandBar
                // Rendered whether or not a snapshot is held: a failed setKill
                // over a cached snapshot used to show NOTHING, and a silently
                // ignored Emergency Stop is the worst invisible failure this
                // tab can produce. commandError outranks the fetch error (a
                // never-applied kill stays visible until acted on; refresh
                // never clears it), and only typed absence stays out of the
                // banner, because unconfigured absence is not a fault and the
                // empty state below already explains it.
                if let cmdErr = store.commandError {
                    errorBanner(cmdErr, showsRetry: false) { store.acknowledgeCommandError() }
                } else if let err = store.lastError, !store.lastErrorIsAbsence {
                    errorBanner(err)
                }
                if let snap = store.snapshot {
                    MetaAdsEmpireRollupBar(rollup: snap.empireRollup, attentionCount: snap.attentionCount)
                    // servingStale from the SAME classify() verdict the banner
                    // above is drawn from, so the calm line and the amber line
                    // can never disagree about whether this pull landed.
                    MetaAdsAttentionQueue(items: snap.allAttention,
                                          onSelectTarget: handleTarget,
                                          stale: store.servingStale)
                    MetaAdsFleetDeck(brands: snap.brands, snapshotMode: snap.mode) { selectedBrandKey = $0 }
                } else if store.isFetching {
                    loading
                } else if store.lastError == nil || store.lastErrorIsAbsence {
                    // A COMMAND FAULT MAY NOT SUPPRESS THIS SURFACE'S OWN ABSENCE STATE.
                    // The gate was `commandError == nil`, on the reasoning that
                    // "went nowhere" above "running without one is normal" is a
                    // contradiction. It is not: lastErrorIsAbsence is true ONLY
                    // when nothing is configured, which is exactly why the
                    // command went nowhere, so the banner is the cause and the
                    // card is the remedy. A configured-but-down host is never
                    // absence, so the contradiction the gate feared cannot
                    // reach here. What the gate DID produce: one press of the
                    // always-enabled Emergency Stop on a fresh install left a
                    // header, an amber banner and empty space, which is the
                    // blank pane this wave exists to remove.
                    // The unconfigured explainer never sits under the technical
                    // banner of a configured engine that is down, nor under a
                    // standing command fault: that banner's "went nowhere"
                    // directly above this card's "not yours to run" is a
                    // contradiction on one screen, so the fault owns the
                    // surface until dismissed.
                    empty
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var commandBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(GruxTheme.accentCo)
            VStack(alignment: .leading, spacing: 1) {
                MetaAdsEyebrow(text: "Autonomous engine", tint: GruxTheme.accentPrimaryLight)
                Text("Meta Ads")
                    .font(GruxTheme.Font.title)
                    .foregroundStyle(GruxTheme.textPrimary)
            }
            Text(subtitle)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GruxTheme.textTertiary)
            Spacer()
            killButton
            if store.servingStale {
                Text("CACHED").font(GruxTheme.Font.microCaps)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(GruxTheme.warnAmber.opacity(0.2)))
                    .foregroundStyle(GruxTheme.warnAmber)
            }
            if store.isFetching { ProgressView().controlSize(.small) }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise").foregroundStyle(GruxTheme.accentCo)
            }
            .buttonStyle(.plain)
            .disabled(store.isFetching)
            .help("Pull a fresh snapshot from the render service")
        }
    }

    // Compact global kill switch in the command bar (full semantics via store).
    // A LOCAL debounce, not the global isMutating. Gating this chip on
    // isMutating made it dead for the length of any unrelated command plus
    // its trailing refresh, which is a dead Emergency Stop; removing that
    // gate without replacing it left the chip with NO guard at all, and its
    // direction is read from the snapshot: a double-click halted, `apply`
    // flipped killSwitchOn true synchronously, and the second click computed
    // setKill(on: false) and RESUMED the spend the first had just stopped.
    // A press-scoped flag closes the double-fire without ever letting an
    // unrelated command disable the control.
    @State private var killPressInFlight = false
    // The chip's own verdict. RESUME (on == false) does not bypass the gate,
    // so it can be refused, and a refusal is returned rather than published:
    // with the outcome dropped the press was a silent no-op, no message, no
    // state change, no affordance. The one control in the tab that must never
    // look ignored was the last one still ignoring itself.
    @State private var killNote: String?

    private var killButton: some View {
        let on = store.snapshot?.killSwitchOn ?? false
        return HStack(spacing: 6) {
        Button {
            guard !killPressInFlight else { return }
            killPressInFlight = true
            killNote = nil
            Task {
                switch await store.setKill(on: !on) {
                case .applied, .cancelled: killNote = nil
                case .refused(let advice): killNote = advice
                case .failed(let message): killNote = message
                }
                killPressInFlight = false
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: on ? "stop.circle.fill" : "stop.circle")
                    .font(.system(size: 12, weight: .bold))
                Text(on ? "HALTED" : "KILL")
                    .font(GruxTheme.Font.microCaps)
            }
            .foregroundStyle(on ? GruxTheme.destructiveRose : GruxTheme.textSecondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill((on ? GruxTheme.destructiveRose : Color.white).opacity(on ? 0.18 : 0.05)))
            .overlay(Capsule().strokeBorder((on ? GruxTheme.destructiveRose : Color.white).opacity(on ? 0.4 : 0.10), lineWidth: 1))
        }
        .buttonStyle(.plain)
        // NEVER disabled. It was gated on isMutating so a press could not
        // land on the store's in-flight guard and be refused silently, but a
        // greyed control with a help string still reading "Halt all
        // autonomous action now" is just as silent, and it stayed grey for
        // the whole of an unrelated command PLUS its trailing refresh: tens
        // of seconds of dead Emergency Stop. The refusal is gone instead,
        // `setKill(on: true)` bypasses the gate, so the press always goes
        // out and there is nothing left to protect the user from.
        .help(on ? "Engine halted. Tap to resume." : "Halt all autonomous action now.")

        if let killNote {
            Text(killNote)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.warnAmber)
                .fixedSize(horizontal: false, vertical: true)
        }
        }
    }

    private var subtitle: String {
        // Was "port 3857 · OBSERVE". Which port the engine listens on is not a
        // fact a reader has, and it was the tab's SUBTITLE, so it was the first
        // thing anybody saw before the engine was ever running.
        guard let s = store.snapshot else { return "Not connected · OBSERVE" }
        var parts: [String] = []
        if s.source?.simulate ?? true { parts.append("SIMULATE") }
        if let t = store.lastUpdated {
            let f = DateFormatter(); f.timeStyle = .short
            parts.append("updated \(f.string(from: t))")
        }
        return parts.joined(separator: " · ")
    }

    private func handleTarget(_ target: AttentionTarget) {
        let allAds = store.snapshot?.brands.flatMap { $0.activeAds } ?? []
        switch target.type {
        case .ad:
            if let id = target.nodeId, let ad = allAds.first(where: { $0.id == id }) {
                selectedBrandKey = ad.brand ?? target.brand
                selectedAdId = ad.id
            } else {
                // The node is not a live ad (e.g. a killed/graveyard node that
                // lives only in the lineage). Never dead-tap: drill to its brand.
                selectedBrandKey = target.brand ?? brandForNode(target.nodeId)
                selectedAdId = nil
            }
        case .brand, .family:
            selectedBrandKey = target.brand ?? brandForNode(target.crid)
            selectedAdId = nil
        }
    }

    // Resolve the owning brand of a node or family id from the snapshot, so an
    // attention target always lands somewhere even when the ad is not live.
    private func brandForNode(_ nodeId: String?) -> String? {
        guard let nodeId, let snap = store.snapshot else { return nil }
        for b in snap.brands {
            if b.lineageNodes.contains(where: { $0.id == nodeId || $0.crid == nodeId })
                || b.activeAds.contains(where: { $0.id == nodeId || $0.crid == nodeId }) {
                return b.slug ?? b.id
            }
        }
        return nil
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Pulling the Meta ads snapshot from the render service...")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(GruxTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // Was "No Meta ads snapshot yet. The engine runs in OBSERVE on the render
    // service. Refresh to pull the fleet." That sentence assumes you have the
    // render service, which is the author's. Refreshing forever was the only
    // advice it gave anyone else.
    private var empty: some View {
        OperatorToolNoticeView(tool: .metaAds)
    }

    // showsRetry is false for command faults: the retry chip re-pulls a
    // snapshot, which cannot re-send a command, so offering it there would
    // look like a fix that does nothing. Re-tapping the control retries.
    // onDismiss is the command banner's exit: without one, this branch
    // outranking the fetch banner means a stale command fault hides any
    // newer fetch failure until the next command or app relaunch.
    private func errorBanner(_ message: String, showsRetry: Bool = true,
                             onDismiss: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GruxTheme.warnAmber)
            Text(message).font(.system(size: 11, weight: .medium)).foregroundStyle(GruxTheme.textSecondary).textSelection(.enabled)
            Spacer()
            if showsRetry {
                GruxChip(title: "Retry", systemImage: "arrow.clockwise", style: .secondary) {
                    Task { await store.refresh() }
                }
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(GruxTheme.warnAmber)
                }
                .buttonStyle(.plain)
                .help("Dismiss. Re-tapping the control retries the command.")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous).fill(GruxTheme.warnAmber.opacity(0.12)))
    }
}
