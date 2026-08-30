import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Social Ops Cockpit: the live operator grid on the phone. Brand rows x platform
// columns, each cell a status pill. Tapping a cell opens a detail sheet with the
// full reason and the contextual two-tap operator controls (arm in place: first
// tap changes the label and arms, second tap within ~4s executes). Actions route
// a .socialOpsAction back to the Mac, which runs the Mini command and replies
// with a .socialOpsAck that drives the result toast + the per-cell last-action
// line. A header shows green/amber/red counts, snapshot freshness, and a Sweep
// now button (a global re-check). No local caching: the view always renders
// ChatStore.socialOpsPanel, the latest pushed snapshot. Tight styling.

private struct DetailTarget: Identifiable { let id: String }

struct SocialOpsCockpitView: View {
    @ObservedObject private var store = ChatStore.shared
    @State private var detail: DetailTarget?
    @State private var sweeping = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let panel = store.socialOpsPanel, !panel.records.isEmpty {
                    grid(panel)
                } else {
                    placeholder
                }
                toastOverlay
            }
            .navigationTitle("Social Ops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { sweepButton }
            }
            .sheet(item: $detail) { target in
                SocialOpsDetailSheet(cellId: target.id)
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: - Grid

    private func grid(_ panel: SocialOpsSnapshot) -> some View {
        let brands = orderedBrands(panel.records)
        let platforms = SocialPlatform.allCases
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                countsHeader(panel)

                HStack(spacing: 8) {
                    Text("").frame(width: 84, alignment: .leading)
                    ForEach(platforms, id: \.self) { p in
                        Text(platformShort(p))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }

                ForEach(brands, id: \.self) { brand in
                    HStack(spacing: 8) {
                        Text(brand)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .frame(width: 84, alignment: .leading)
                        ForEach(platforms, id: \.self) { p in
                            let rec = panel.records.first { $0.brand == brand && $0.platform == p }
                            cell(brand: brand, platform: p, record: rec)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }

                legend
            }
            .padding(16)
        }
    }

    private func cell(brand: String, platform: SocialPlatform,
                      record: SocialHealthRecord?) -> some View {
        let status = record?.status ?? .unknown
        let id = record?.id ?? "\(brand)|\(platform.rawValue)"
        return Button {
            hapticLight()
            detail = DetailTarget(id: id)
        } label: {
            VStack(spacing: 2) {
                Text(statusLabel(status))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pillForeground(status))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)   // comfortable tap target (low-mobility)
                    .background(pillColor(status), in: Capsule())
                if let last = store.lastActionByCell[id], !last.isEmpty {
                    Text(last)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Header / counts / legend

    private func countsHeader(_ panel: SocialOpsSnapshot) -> some View {
        let recs = panel.records
        let green = recs.filter { $0.status == .green }.count
        let amber = recs.filter { $0.status == .amber }.count
        let red = recs.filter { $0.status == .red }.count
        let muted = recs.filter { $0.status == .muted }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                countChip(green, "OK", .green)
                countChip(amber, "Degraded", .orange)
                countChip(red, "Down", .red)
                if muted > 0 { countChip(muted, "Muted", .gray) }
            }
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text("updated \(relative(panel.generatedAt))")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func countChip(_ n: Int, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(n) \(label)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: Capsule())
    }

    private var legend: some View {
        Text("green healthy | amber degraded | red down | grey muted. Tap a cell for details and controls.")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private var sweepButton: some View {
        Button {
            sweepNow()
        } label: {
            if sweeping {
                ProgressView().controlSize(.small)
            } else {
                Label("Sweep", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
        }
        .tint(.cyan)
        .disabled(sweeping)
    }

    private func sweepNow() {
        hapticLight()
        sweeping = true
        TransportService.shared.sendChat(
            .socialOpsAction(brand: "", platform: "", action: SocialOpAction.sweep.rawValue,
                             ts: Int64(Date().timeIntervalSince1970 * 1000))
        )
        AppModel.diag("socialOps: sweep requested")
        // The live re-check runs on the Mini and pushes a fresh grid back; clear
        // the spinner shortly (visual ack), the grid updates when it lands.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            sweeping = false
        }
    }

    // MARK: - Toast

    private var toastOverlay: some View {
        VStack {
            Spacer()
            if let toast = store.socialOpsToast {
                HStack(spacing: 8) {
                    Image(systemName: toast.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(toast.text).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(toast.ok ? Color.green.opacity(0.85) : Color.red.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 24).padding(.horizontal, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.socialOpsToast)
        .onChange(of: store.socialOpsToast?.id) { _, _ in
            // Auto-dismiss the toast after a few seconds.
            Task { @MainActor in
                let shown = store.socialOpsToast?.id
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                if store.socialOpsToast?.id == shown { store.socialOpsToast = nil }
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.6))
            Text("No live grid yet")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
            Text("The cockpit appears when your Mac pushes a snapshot.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Shared helpers

    private func orderedBrands(_ records: [SocialHealthRecord]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in records where !seen.contains(r.brand) {
            seen.insert(r.brand); out.append(r.brand)
        }
        return out.sorted()
    }

    private func relative(_ ms: Int64) -> String { Self.relativeStatic(ms) }

    static func relativeStatic(_ ms: Int64) -> String {
        let then = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let delta = Date().timeIntervalSince(then)
        if delta < 5 { return "just now" }
        if delta < 60 { return "\(Int(delta))s ago" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }

    private func hapticLight() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func platformShort(_ p: SocialPlatform) -> String {
        switch p {
        case .threads: return "Threads"
        case .instagram: return "IG"
        case .tiktok: return "TikTok"
        case .linkedin: return "LinkedIn"
        }
    }

    private func statusLabel(_ s: SocialStatus) -> String {
        switch s {
        case .green: return "OK"
        case .amber: return "Degraded"
        case .red: return "Down"
        case .muted: return "Muted"
        case .unknown: return "?"
        }
    }

    private func pillColor(_ s: SocialStatus) -> Color {
        switch s {
        case .green: return Color.green.opacity(0.85)
        case .amber: return Color.orange.opacity(0.9)
        case .red: return Color.red.opacity(0.9)
        case .muted: return Color.gray.opacity(0.45)
        case .unknown: return Color.white.opacity(0.12)
        }
    }

    private func pillForeground(_ s: SocialStatus) -> Color {
        switch s {
        case .green, .amber, .red: return .black
        case .muted: return .white
        case .unknown: return .secondary
        }
    }
}

// MARK: - Detail sheet with arm-in-place two-tap controls

private struct SocialOpsDetailSheet: View {
    let cellId: String
    @ObservedObject private var store = ChatStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var armed: SocialOpAction?
    @State private var armToken = 0
    @State private var working: SocialOpAction?
    // The ts of the in-flight action's outgoing envelope. We clear `working` only
    // when an ack with this exact ts arrives, so an unrelated ack (e.g. a sweep
    // ack firing mid-action) cannot clear the spinner early.
    @State private var pendingActionTs: Int64 = 0

    private var rec: SocialHealthRecord? {
        store.socialOpsPanel?.records.first { $0.id == cellId }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView {
                    if let rec = rec {
                        VStack(alignment: .leading, spacing: 16) {
                            header(rec)
                            reasonBlock(rec)
                            if needsSession(rec) { needsSessionCTA }
                            if let last = store.lastActionByCell[cellId], !last.isEmpty {
                                lastActionLine(last)
                            }
                            controls(rec)
                            Spacer(minLength: 8)
                        }
                        .padding(18)
                    } else {
                        Text("This cell is no longer in the grid.")
                            .foregroundStyle(.secondary).padding(40)
                    }
                }
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.tint(.cyan)
                }
            }
            .onChange(of: store.socialOpsToast?.id) { _, newId in
                // Clear the spinner only for OUR action's ack (matched by ts), so a
                // sweep ack or another cell's ack cannot clear it prematurely.
                guard let newId, newId == pendingActionTs, working != nil else { return }
                hapticResult(store.socialOpsToast?.ok ?? true)
                working = nil
                pendingActionTs = 0
            }
        }
    }

    private var titleText: String {
        guard let rec = rec else { return "Cell" }
        return "\(rec.brand) | \(platformShort(rec.platform))"
    }

    private func header(_ rec: SocialHealthRecord) -> some View {
        HStack(spacing: 10) {
            Text(statusLabel(rec.status))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(pillForeground(rec.status))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(pillColor(rec.status), in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(rec.brand).font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                Text("checked \(SocialOpsCockpitView.relativeStatic(rec.lastChecked == 0 ? 0 : rec.lastChecked * 1000))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func reasonBlock(_ rec: SocialHealthRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Reason", reasonText(rec))
            if !rec.lastPostResult.isEmpty { detailRow("Last post", rec.lastPostResult) }
            if !rec.reachTrend.isEmpty && rec.reachTrend != "flat" { detailRow("Reach", rec.reachTrend) }
            detailRow("Session", rec.loggedIn ? "logged in" : "logged out")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private func detailRow(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(v).font(.system(size: 12)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var needsSessionCTA: some View {
        HStack(spacing: 8) {
            Image(systemName: "key.fill").foregroundStyle(.yellow)
            Text("Needs a logged-in session. Import an existing browser session on the Mini (headless login is blocked by the platform).")
                .font(.system(size: 11)).foregroundStyle(.white)
        }
        .padding(10)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func lastActionLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(.secondary)
            Text("last action: \(text)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    // Contextual controls: only the actions that apply to this cell's state.
    private func controls(_ rec: SocialHealthRecord) -> some View {
        let acts = actions(for: rec)
        return VStack(spacing: 10) {
            ForEach(acts, id: \.self) { action in
                actionButton(action, rec)
            }
            if acts == [.mute] && rec.status == .green {
                Text("All good. Nothing to fix here.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func actions(for rec: SocialHealthRecord) -> [SocialOpAction] {
        if rec.muted { return [.mute] }   // mute toggles -> shows as Unmute
        var out: [SocialOpAction] = []
        if !rec.loggedIn || !rec.sessionValid || rec.twoFAChallenge { out.append(.reauth) }
        if rec.lastPostResult == "failed" { out.append(.retry) }
        if rec.lastPostResult == "pending" { out.append(.approve) }
        out.append(.mute)
        return out
    }

    private func actionButton(_ action: SocialOpAction, _ rec: SocialHealthRecord) -> some View {
        let isArmed = armed == action
        let isWorking = working == action
        return Button {
            tap(action, rec)
        } label: {
            Group {
                if isWorking {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("working...") }
                } else {
                    Text(isArmed ? armedLabel(action, rec) : restingLabel(action, rec))
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 46)   // big tap target
            .background(isArmed ? Color.orange : Color.cyan, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(working != nil)
        .opacity(working != nil && !isWorking ? 0.4 : 1)
    }

    private func tap(_ action: SocialOpAction, _ rec: SocialHealthRecord) {
        guard working == nil else { return }
        if armed == action {
            // Second tap: confirm + execute.
            armed = nil
            working = action
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            pendingActionTs = ts
            hapticLight()
            TransportService.shared.sendChat(
                .socialOpsAction(brand: rec.brand, platform: rec.platform.rawValue,
                                 action: action.rawValue, ts: ts)
            )
            AppModel.diag("socialOps: confirmed \(action.rawValue) for \(rec.id)")
            // Fallback: clear working if no ack ever lands (unconditional, so a
            // re-arm after confirm cannot strand the spinner).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                if working == action && pendingActionTs == ts {
                    working = nil
                    pendingActionTs = 0
                }
            }
        } else {
            // First tap: arm this action, auto-disarm after ~4s.
            armed = action
            armToken += 1
            let token = armToken
            hapticLight()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if armed == action && token == armToken { armed = nil }
            }
        }
    }

    // Resting / armed labels.
    private func restingLabel(_ a: SocialOpAction, _ rec: SocialHealthRecord) -> String {
        switch a {
        case .mute: return rec.muted ? "Unmute" : "Mute"
        case .reauth: return "Re-auth"
        case .retry: return "Retry"
        case .approve: return "Approve"
        case .sweep: return "Sweep"
        }
    }

    private func armedLabel(_ a: SocialOpAction, _ rec: SocialHealthRecord) -> String {
        switch a {
        case .mute: return rec.muted ? "Tap again to unmute" : "Tap again to mute"
        case .reauth: return "Confirm re-auth"
        case .retry: return "Confirm retry"
        case .approve: return "Confirm approve"
        case .sweep: return "Confirm sweep"
        }
    }

    private func needsSession(_ rec: SocialHealthRecord) -> Bool {
        let e = rec.lastError.lowercased()
        return rec.status == .red && (e.contains("login wall") || e.contains("logged out") || !rec.loggedIn)
    }

    private func reasonText(_ rec: SocialHealthRecord) -> String {
        if !rec.lastError.isEmpty { return rec.lastError }
        if rec.twoFAChallenge { return "2FA challenge pending" }
        if !rec.loggedIn { return "logged out" }
        if !rec.sessionValid { return "session invalid" }
        if rec.rateLimited { return "rate limited" }
        if rec.reachTrend == "down" { return "reach trending down" }
        return rec.status == .green ? "healthy" : "needs attention"
    }

    private func hapticLight() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func hapticResult(_ ok: Bool) {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(ok ? .success : .error)
        #endif
    }

    private func platformShort(_ p: SocialPlatform) -> String {
        switch p {
        case .threads: return "Threads"
        case .instagram: return "IG"
        case .tiktok: return "TikTok"
        case .linkedin: return "LinkedIn"
        }
    }

    private func statusLabel(_ s: SocialStatus) -> String {
        switch s {
        case .green: return "OK"
        case .amber: return "Degraded"
        case .red: return "Down"
        case .muted: return "Muted"
        case .unknown: return "?"
        }
    }

    private func pillColor(_ s: SocialStatus) -> Color {
        switch s {
        case .green: return Color.green.opacity(0.85)
        case .amber: return Color.orange.opacity(0.9)
        case .red: return Color.red.opacity(0.9)
        case .muted: return Color.gray.opacity(0.45)
        case .unknown: return Color.white.opacity(0.12)
        }
    }

    private func pillForeground(_ s: SocialStatus) -> Color {
        switch s {
        case .green, .amber, .red: return .black
        case .muted: return .white
        case .unknown: return .secondary
        }
    }
}
