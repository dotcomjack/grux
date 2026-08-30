import SwiftUI

// Empire Dashboard section that mirrors the live Social Ops grid: every brand
// across every platform (Threads, Instagram, TikTok, LinkedIn) as a colored
// status pill. Tapping a non-green cell reveals the two-tap operator controls
// (retry, reauth, mute, approve) which route through SocialOpsStore.sendCommand
// to the companion service. Built on the PRDigestSection layout (header, refresh, cached
// banner) with the tight, not chunky button style.
//
// SUBSTITUTION NOTE: same surface choice as the PR digest. Grux has no Inbox
// window, so the cockpit mirror lives in the Empire Dashboard alongside the
// other panels backed by the companion service. The phone cockpit (Task 9 onward) is the live,
// operator-first surface; this is the at-a-glance Mac mirror.

struct SocialOpsSection: View {
    @ObservedObject private var store = SocialOpsStore.shared
    // The cell the operator has expanded to reveal its controls. nil when none.
    @State private var expandedCellID: String?
    // Two-tap arm-in-place: which "key::action" is armed (awaiting a confirming
    // second tap). Auto-disarms after ~4s. Only one action is armed at a time.
    @State private var armed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "megaphone.fill")
                    .foregroundStyle(.pink)
                Text("Social Ops").font(.headline)
                // Out-of-chain stale disclosure, mirroring MetaAdsOpsSection:
                // the banner chain below can be held by an undismissed
                // command fault for unbounded time, and the stale fact must
                // not wait on it.
                if store.servingStale {
                    Text("CACHED")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.20))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if store.isFetching {
                    ProgressView().controlSize(.mini)
                }
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isFetching)
                .help("Pull the latest grid from the render service")
                Button { Task { _ = await store.sweep() } } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Sweep now: live re-check every cell on the render service")
            }

            // commandError outranks the fetch banners: a command or sweep that
            // never applied stays visible over a healthy grid until acted on,
            // and refresh never clears it. No Retry chip, because re-tapping
            // the same control IS the retry; dismiss is the only other thing
            // to do with the message. Same argument as MetaAdsView.
            if let cmdErr = store.commandError {
                HStack(spacing: 6) {
                    Text(cmdErr)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                    Button { store.acknowledgeCommandError() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss. Re-tapping the control retries the command.")
                }
            }
            // Same honesty rule as PRDigestSection: the stale banner carries
            // no absence arm (the Classification precondition asserts the
            // disjointness) and always names the fault technically.
            else if store.servingStale, let err = store.lastError {
                Text("Showing cached grid. Last pull failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let err = store.lastError, store.snapshot == nil,
                      !store.lastErrorIsAbsence {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let snapshot = store.snapshot, !snapshot.records.isEmpty {
                grid(snapshot.records)
                footer(snapshot)
                Divider()
                digestSwitch
            } else if store.snapshot != nil,
                      store.lastError == nil || store.lastErrorIsAbsence {
                // Success with zero cells: the service answered and tracks
                // nothing yet, which is neither a fault nor absence, and a
                // header over a blank pane says neither. A standing absence
                // verdict passes the gate too: absence over a held empty
                // snapshot means the push channel feeds this store while no
                // pull host answers, and this sentence stays the accurate
                // one. Only a REAL pull failure defers to the cached-grid
                // story the banner above tells, which "the service answered"
                // would contradict.
                Text(Self.emptyGridCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.snapshot == nil, store.lastErrorIsAbsence {
                // Only when the pull proved absence AND nothing is held: any
                // held snapshot, even an empty one, means a data channel
                // exists, and the three-paragraph onboarding card is the
                // wrong surface beside live data. Only with no standing
                // command fault: a failed sweep's technical banner directly
                // above "nothing needs fixing" is a contradiction on one
                // screen, so the banner owns the surface until dismissed.
                // Deliberately NOT gated on isFetching: the closure is the
                // recovery pull, so that gate unmounted the card the moment
                // its own recovery started and cancelled it mid-request (see
                // the mount rules on PrivateServiceNoticeView).
                PrivateServiceNoticeView(service: .socialOps) { await store.refresh() }
            } else if PrivateServiceFetch.awaitingFirstPull(
                hasPayload: store.snapshot != nil, verdict: store.lastVerdict) {
                // THE ARM THAT WAS MISSING. No payload and no verdict is
                // reachable: pullOnce's cancellation path writes nothing, so
                // a section unmounted mid-pull left this pane holding a
                // header, a refresh button and empty space. Never silence.
                //
                // The copy splits on isFetching because the arm replaced an
                // `else if !store.isFetching`: during the very first pull
                // there is no payload and no verdict, so this pane told the
                // reader to click a Refresh button that is .disabled for the
                // length of that pull. An instruction that cannot be followed
                // while it is on screen is the defect one line up.
                Text(store.isFetching
                     ? "Pulling the latest grid..."
                     : "No grid yet. Click refresh to pull one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            store.load()
            if store.snapshot == nil
               || Date().timeIntervalSince(store.lastUpdated ?? .distantPast) > 1800 {
                Task { await store.refresh() }
            }
        }
    }

    /// The digest switch, here rather than in Settings because this panel is the only place
    /// somebody learns Social Ops exists at all. It is ON, so an account going dark is still
    /// noticed; the point is that a daily notification and a weekly chat card now have an
    /// off, and that somebody reads the sentence before the first one arrives rather than
    /// after.
    @ViewBuilder
    var digestSwitch: some View {
        Toggle("Send me the daily and weekly digest", isOn: Binding(
            get: { SocialOpsCoordinator.digestsEnabled },
            set: { UserDefaults.standard.set($0, forKey: SocialOpsCoordinator.digestsEnabledKey) }
        ))
        Text("On. Once a day and once a week, Grux posts a notification and a chat card summing up which accounts are healthy and which want a look. Turning this off leaves the grid above working and stops the unprompted messages.")
            .font(.caption).foregroundStyle(.secondary)
    }

    // What an answered-but-empty grid says. Success with zero cells reads
    // differently from absence: the service is there, so the panel says so
    // instead of rendering nothing under the header. Internal so the copy
    // tests can read the sentence the screen draws.
    static let emptyGridCopy = "The social operations service answered with no accounts tracked yet. "
        + "The grid fills in as accounts come under watch."

    // Cached: SwiftUI recomputes body (and this property) often, and DateFormatter
    // is expensive to construct on every render.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private var subtitle: String {
        guard let t = store.lastUpdated else {
            return store.snapshot == nil ? "not yet pulled" : "cached"
        }
        return "updated \(Self.timeFormatter.string(from: t))"
    }

    // Brand rows x platform columns. One pill per cell. A pill is the only
    // affordance: tap a non-green one to reveal its controls inline below.
    private func grid(_ records: [SocialHealthRecord]) -> some View {
        let brands = orderedBrands(records)
        let platforms = SocialPlatform.allCases
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ("\($0.brand)|\($0.platform.rawValue)", $0) })
        return VStack(alignment: .leading, spacing: 6) {
            // Column header row.
            HStack(spacing: 6) {
                Text("").frame(width: 96, alignment: .leading)
                ForEach(platforms, id: \.self) { p in
                    Text(platformShort(p))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(brands, id: \.self) { brand in
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(brand)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(width: 96, alignment: .leading)
                        ForEach(platforms, id: \.self) { p in
                            let key = "\(brand)|\(p.rawValue)"
                            cellPill(record: byKey[key], brand: brand, platform: p, key: key)
                        }
                    }
                    // Expanded controls render full width under the brand row.
                    ForEach(platforms, id: \.self) { p in
                        let key = "\(brand)|\(p.rawValue)"
                        if expandedCellID == key, let rec = byKey[key] {
                            controls(for: rec)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cellPill(record: SocialHealthRecord?, brand: String,
                          platform: SocialPlatform, key: String) -> some View {
        let status = record?.status ?? .unknown
        let color = statusColor(status)
        let isExpanded = expandedCellID == key
        // utility radius 10 (tight, not chunky), no chunky border.
        Button {
            guard record != nil else { return }
            armed = nil
            expandedCellID = isExpanded ? nil : key
        } label: {
            Text(statusGlyph(status))
                .font(.system(size: 13, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(color.opacity(isExpanded ? 0.35 : 0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(color.opacity(0.45), lineWidth: 1)
                )
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
        .help(cellHelp(record, brand: brand, platform: platform))
        .disabled(record == nil)
    }

    // Two-tap arm-in-place controls for a cell, showing only the actions that
    // apply to its state. First tap arms (label flips, turns amber); a second tap
    // within ~4s executes. Tight pill buttons.
    private func controls(for rec: SocialHealthRecord) -> some View {
        let key = "\(rec.brand)|\(rec.platform.rawValue)"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(rec.brand) | \(rec.platform.rawValue) | \(reasonText(rec))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                ForEach(contextualActions(rec), id: \.self) { action in
                    armButton(action, rec, key: key)
                }
            }
            if let last = store.lastActionByCell[key], !last.isEmpty {
                Text("last action: \(last)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func armButton(_ action: SocialOpAction, _ rec: SocialHealthRecord, key: String) -> some View {
        let armKey = "\(key)::\(action.rawValue)"
        let isArmed = armed == armKey
        return Button {
            if isArmed {
                armed = nil
                Task {
                    await store.sendCommand(brand: rec.brand, platform: rec.platform, action: action)
                    expandedCellID = nil
                }
            } else {
                armed = armKey
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if armed == armKey { armed = nil }
                }
            }
        } label: {
            Text(isArmed ? armedLabel(action, rec) : restingLabel(action, rec))
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isArmed ? AnyShapeStyle(Color.orange.opacity(0.9))
                                            : AnyShapeStyle(statusColor(rec.status).opacity(0.16)))
                )
                .foregroundStyle(isArmed ? AnyShapeStyle(.white) : AnyShapeStyle(statusColor(rec.status)))
        }
        .buttonStyle(.plain)
        .help(isArmed ? "Tap again to confirm" : "Tap to arm")
    }

    // Only the actions that apply to this cell's state.
    private func contextualActions(_ rec: SocialHealthRecord) -> [SocialOpAction] {
        if rec.muted { return [.mute] }   // shows as Unmute
        var out: [SocialOpAction] = []
        if !rec.loggedIn || !rec.sessionValid || rec.twoFAChallenge { out.append(.reauth) }
        if rec.lastPostResult == "failed" { out.append(.retry) }
        if rec.lastPostResult == "pending" { out.append(.approve) }
        out.append(.mute)
        return out
    }

    private func restingLabel(_ a: SocialOpAction, _ rec: SocialHealthRecord) -> String {
        switch a {
        case .mute: return rec.muted ? "Unmute" : "Mute"
        case .reauth: return "Reauth"
        case .retry: return "Retry"
        case .approve: return "Approve"
        case .sweep: return "Sweep"
        }
    }

    private func armedLabel(_ a: SocialOpAction, _ rec: SocialHealthRecord) -> String {
        switch a {
        case .mute: return rec.muted ? "Tap again to unmute" : "Tap again to mute"
        case .reauth: return "Confirm reauth"
        case .retry: return "Confirm retry"
        case .approve: return "Confirm approve"
        case .sweep: return "Confirm sweep"
        }
    }

    private func reasonText(_ rec: SocialHealthRecord) -> String {
        if !rec.lastError.isEmpty { return rec.lastError }
        if rec.twoFAChallenge { return "2FA challenge" }
        if !rec.loggedIn { return "logged out" }
        if !rec.sessionValid { return "session invalid" }
        if rec.rateLimited { return "rate limited" }
        if rec.reachTrend == "down" { return "reach down" }
        return rec.status == .green ? "healthy" : "needs attention"
    }

    private func footer(_ s: SocialOpsSnapshot) -> some View {
        let reds = s.records.filter { $0.status == .red }.count
        let ambers = s.records.filter { $0.status == .amber }.count
        let greens = s.records.filter { $0.status == .green }.count
        return HStack(spacing: 12) {
            Text("\(greens) green")
            Text("\(ambers) amber").foregroundStyle(ambers > 0 ? .orange : .secondary)
            Text("\(reds) red").foregroundStyle(reds > 0 ? .red : .secondary)
            Text("via \(s.source)")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    // MARK: - Helpers

    private func orderedBrands(_ records: [SocialHealthRecord]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in records.sorted(by: { $0.brand < $1.brand }) where !seen.contains(r.brand) {
            seen.insert(r.brand)
            out.append(r.brand)
        }
        return out
    }

    private func platformShort(_ p: SocialPlatform) -> String {
        switch p {
        case .threads:   return "Threads"
        case .instagram: return "IG"
        case .tiktok:    return "TikTok"
        case .linkedin:  return "LinkedIn"
        }
    }

    private func statusColor(_ s: SocialStatus) -> Color {
        switch s {
        case .green:   return .green
        case .amber:   return .orange
        case .red:     return .red
        case .muted:   return Color(nsColor: .systemGray)
        case .unknown: return Color(nsColor: .systemGray)
        }
    }

    private func statusGlyph(_ s: SocialStatus) -> String {
        switch s {
        case .green:   return "OK"
        case .amber:   return "!"
        case .red:     return "X"
        case .muted:   return "M"
        case .unknown: return "?"
        }
    }

    private func cellHelp(_ rec: SocialHealthRecord?, brand: String, platform: SocialPlatform) -> String {
        guard let rec else { return "\(brand) \(platform.rawValue): no data" }
        var parts = ["\(brand) \(platform.rawValue): \(rec.status.rawValue)"]
        if !rec.lastError.isEmpty { parts.append(rec.lastError) }
        if rec.muted { parts.append("muted, tap to unmute") }
        else { parts.append("tap for controls") }
        return parts.joined(separator: " | ")
    }
}
