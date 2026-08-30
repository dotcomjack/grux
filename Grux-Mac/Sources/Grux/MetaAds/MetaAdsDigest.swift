import SwiftUI

// Daily Telegram digest for the autonomous Meta Ads engine.
//
// Once a day (and on a manual "send now" tap) this module reads the current Meta
// Ads snapshot, formats a single human-readable summary, and POSTs it to the
// existing Telegram alert channel. It is the phone-side glance:
// mode, spend today vs the $16 / $20 line and the week vs the $140 cap, the top
// winner concept, what got killed and why, how many branches are open against
// the 8 cap, and the kill-switch state.
//
// SAFETY + STYLE
//   - SIMULATE / OBSERVE only: this reads the snapshot the ads engine emits. It
//     never asks the engine to act and never spends a cent (the ad account is
//     act_PLACEHOLDER until configured, so the engine cannot go live).
//   - Telegram is opt in and refuses to act until it is. The send path checks
//     `key.telegram` before it builds a request, and an install that has not
//     opted in gets the capability's own remediation sentence on screen rather
//     than a silent skip. The bot token and chat id come from the Keychain slots
//     the Settings fields write, which is the only home for them, so a machine
//     the user has not configured cannot send. The token is never logged.
//   - Money is formatted as $N (the symbol-plus-numeral form). Zero em / en
//     dashes. Per-brand copy bans are honored (no medical / "organic" /
//     packaging claims; we only report engine state, never marketing copy).
//
// SNAPSHOT SOURCE
//   Prefers MetaAdsStore.shared.snapshot when the tab has already pulled it;
//   falls back to a direct MetaAdsService.fetchLatest() so the digest works even
//   if the tab was never opened this session. Both are link-time siblings in the
//   same target (U1 store, U4 service).

@MainActor
final class MetaAdsDigest: ObservableObject {
    static let shared = MetaAdsDigest()

    // Hard cap on open branches per brand, mirrored from the engine lineage rule
    // (max_open_branches_per_brand = 8). Surfaced so the digest can read "5 / 8".
    private static let maxOpenBranchesPerBrand = 8

    // The $20/day human-facing budget line. The engine sets Meta's daily_budget to
    // the effective $16 (1600c = $20 / 1.25 overspend); the digest shows both so
    // the user reads spend against the number they actually authorized ($20) and
    // the number the engine targets ($16).
    private static let humanDailyBudgetCents = 2000   // $20/day authorized line

    @Published private(set) var lastSentAt: Date?
    @Published private(set) var lastResult: String?   // short status for a UI affordance
    @Published private(set) var isSending = false

    private var timer: Timer?

    private init() {}

    // MARK: - Scheduling

    // Arm the once-daily timer. Idempotent: re-arming replaces the prior timer.
    // The digest fires at the next occurrence of `hour:minute` local time and
    // every 24h thereafter. Default 9:00 local so it lands as a morning glance.
    func startDailySchedule(hour: Int = 9, minute: Int = 0) {
        timer?.invalidate()

        let fireDate = Self.nextFire(hour: hour, minute: minute, from: Date())
        let t = Timer(fire: fireDate, interval: 86_400, repeats: true) { [weak self] _ in
            // Timer callbacks are nonisolated; hop to the main actor to touch
            // @Published state and the @MainActor send path.
            Task { @MainActor in
                await self?.sendNow(trigger: "scheduled")
            }
        }
        // Common run-loop mode so the timer still fires while menus / tracking
        // loops are active, matching how the app schedules its other tickers.
        RunLoop.main.add(t, forMode: .common)
        timer = t
        WakeLog.shared.log("meta-ads-digest: scheduled daily at \(hour):\(String(format: "%02d", minute)) local")
    }

    func stopSchedule() {
        timer?.invalidate()
        timer = nil
    }

    // Next local-time occurrence of hour:minute strictly after `from`.
    private static func nextFire(hour: Int, minute: Int, from: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: from)
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        let today = cal.date(from: comps) ?? from
        if today > from { return today }
        return cal.date(byAdding: .day, value: 1, to: today) ?? from.addingTimeInterval(86_400)
    }

    // MARK: - Send

    // Build and send the digest now. Used by both the daily timer and the manual
    // "send now" affordance. Returns true if Telegram accepted the message.
    @discardableResult
    func sendNow(trigger: String = "manual") async -> Bool {
        guard !isSending else { return false }
        isSending = true
        defer { isSending = false }

        // Opt in gate, first, before the snapshot is even resolved. Telegram is
        // an outbound integration the user chooses, so a machine that has not
        // chosen it does no work and says why in the contract's own words. The
        // sentence lands on `lastResult`, which the control below renders.
        guard CapabilityResolver.isSatisfied(.keyTelegram) else {
            lastResult = SetupRequirement.keyTelegram.remediation
            WakeLog.shared.log("meta-ads-digest: telegram not enabled, nothing sent (\(trigger))")
            return false
        }

        let snap = await resolveSnapshot()
        guard let snap else {
            lastResult = "No snapshot available"
            WakeLog.shared.log("meta-ads-digest: no snapshot, skipping (\(trigger))")
            return false
        }

        let text = Self.formatDigest(snap)
        let ok = await Self.sendTelegram(text)

        lastSentAt = Date()
        lastResult = ok ? "Sent" : "Send failed"
        return ok
    }

    // Prefer the already-pulled store snapshot; otherwise fetch directly so the
    // digest never depends on the tab having been opened.
    private func resolveSnapshot() async -> MetaAdsSnapshot? {
        if let s = MetaAdsStore.shared.snapshot { return s }
        return try? await MetaAdsService.fetchLatest()
    }

    // MARK: - Formatting

    // One Telegram message. Plain text (no markdown) so a concept label with
    // special characters never breaks parsing. $N money, zero em / en dashes.
    static func formatDigest(_ snap: MetaAdsSnapshot) -> String {
        var lines: [String] = []
        lines.append("Meta Ads daily digest")

        let killState = snap.killSwitchOn ? "ON (everything paused)" : "off"
        lines.append("Mode: \(snap.mode) | Kill switch: \(killState)")

        if let src = snap.source {
            var tags: [String] = []
            if src.simulate == true { tags.append("simulate") }
            if src.bootstrapped == false { tags.append("not bootstrapped, cannot act live") }
            if !tags.isEmpty {
                lines.append("Engine: " + tags.joined(separator: ", "))
            }
        }
        lines.append("")

        if snap.brands.isEmpty {
            lines.append("No brands reporting yet. Engine builds its first snapshot on the opening tick.")
            return lines.joined(separator: "\n")
        }

        for brand in snap.brands {
            lines.append(contentsOf: brandLines(brand, snapshotMode: snap.mode))
            lines.append("")
        }

        // Trim a single trailing blank line for a tidy message tail.
        if lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private static func brandLines(_ brand: MetaAdsBrand, snapshotMode: String) -> [String] {
        var out: [String] = []
        out.append("\(brand.displayName) [\(brand.effectiveMode(default: snapshotMode))]")

        // Spend pacing. Show today vs both the $16 engine target and the $20
        // authorized line, and the week vs the $140 cap.
        let k = brand.kpis
        let p = brand.pacing
        let todayStr = money(k.spendTodayCents)
        let dailyCapStr = money(p.dailyCapCents)
        let humanDailyStr = money(humanDailyBudgetCents)
        let weekStr = money(k.spendWeekCents)
        let weekCapStr = money(p.weeklyCapCents)
        out.append("Spend today: \(todayStr) of \(dailyCapStr) target (\(humanDailyStr) authorized), \(pct(p.dailyPct))")
        out.append("Spend week: \(weekStr) of \(weekCapStr) cap, \(pct(p.weeklyPct))")

        if let cpa = k.cpaCents {
            out.append("CPA: \(money(cpa)) | conversions: \(k.conversions)")
        } else {
            out.append("Conversions: \(k.conversions)")
        }

        // Lineage roll-up: top winner, open-branch count vs the 8 cap, kills.
        let families = brand.families
        let openBranches = families.filter { $0.bucket != .graveyard }.count
        out.append("Open branches: \(openBranches) of \(maxOpenBranchesPerBrand)")

        if let topWinner = bestWinner(families) {
            let cpaTag = topWinner.bestCpaCents.map { " at \(money($0)) CPA" } ?? ""
            out.append("Top winner: \(topWinner.displayLabel)\(cpaTag)")
        } else {
            out.append("Top winner: none yet, still gathering signal")
        }

        let killed = families.filter { $0.bucket == .graveyard }
        if killed.isEmpty {
            out.append("Killed: none")
        } else {
            let names = killed.prefix(3).map { $0.displayLabel }.joined(separator: ", ")
            let extra = killed.count > 3 ? " and \(killed.count - 3) more" : ""
            out.append("Killed (\(killed.count)): \(names)\(extra)")
        }

        return out
    }

    // The winner with the lowest CPA; ties and missing CPAs fall back to node
    // count so a healthy scaling family still surfaces.
    private static func bestWinner(_ families: [ConceptFamily]) -> ConceptFamily? {
        let winners = families.filter { $0.bucket == .winners }
        guard !winners.isEmpty else { return nil }
        return winners.sorted { a, b in
            switch (a.bestCpaCents, b.bestCpaCents) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.nodeCount > b.nodeCount
            }
        }.first
    }

    // MARK: - Money + percent helpers ($N symbol-plus-numeral form)

    private static func money(_ cents: Int) -> String {
        // Whole-dollar amounts render as $16; fractional as $4.95.
        if cents % 100 == 0 {
            return "$\(cents / 100)"
        }
        return String(format: "$%.2f", Double(cents) / 100.0)
    }

    private static func pct(_ fraction: Double) -> String {
        let p = Int((fraction * 100).rounded())
        return "\(p)% of cap"
    }

    // MARK: - Telegram delivery (Keychain-sourced, never hardcoded)

    // POST the digest to the Telegram channel. Bot token + chat id come from the
    // Keychain slots the Settings fields write, which is what `key.telegram`
    // resolves against, so the gate in `sendNow` and the credential read below
    // can never disagree about whether this machine is configured. Plain text, no
    // markdown. Never logs the token. Returns true only on a 2xx.
    private static func sendTelegram(_ text: String) async -> Bool {
        let token = KeychainStore.get(.telegramBotToken).trimmingCharacters(in: .whitespacesAndNewlines)
        let chatId = KeychainStore.get(.telegramChatId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !chatId.isEmpty else { return false }
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else {
            return false
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "disable_web_page_preview": true,
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        req.httpBody = body

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(status) {
                WakeLog.shared.log("meta-ads-digest: telegram digest sent")
                return true
            }
            WakeLog.shared.log("meta-ads-digest: telegram HTTP \(status)")
            return false
        } catch {
            WakeLog.shared.log("meta-ads-digest: telegram send failed: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Manual "send now" affordance

// A compact control the Meta Ads tab can drop into a toolbar or footer. Shows
// the last-sent timestamp and a button that fires the digest immediately. Pure
// presentation over MetaAdsDigest.shared; arms the daily schedule on appear so
// the digest runs even if the tab is never reopened.
//
// Until Telegram is turned on it shows the capability's remediation sentence and
// a button to the field, instead of a Send button that would only fail. Arming
// the schedule regardless is deliberate: `sendNow` refuses on its own, so a user
// who adds the token later starts getting the digest without reopening the tab.
struct MetaAdsDigestControl: View {
    @ObservedObject private var digest = MetaAdsDigest.shared

    private var telegramReady: Bool {
        CapabilityResolver.isSatisfied(.keyTelegram)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.fill")
                .font(.caption)
                .foregroundStyle(GruxTheme.accentCo)

            VStack(alignment: .leading, spacing: 1) {
                Text("Daily Telegram digest")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                Text(statusLine)
                    .font(.caption2)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if telegramReady {
                Button {
                    Task { await digest.sendNow(trigger: "manual") }
                } label: {
                    if digest.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Send now", systemImage: "paperplane")
                            .font(.caption)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(digest.isSending)
                .help("Send the Meta Ads digest to Telegram now")
            } else {
                // The same deep link the setup card uses, so this lands on the
                // Telegram field rather than the top of Settings.
                Button("Turn it on") {
                    AppState.shared.requestedSettingsTab = SetupRequirement.keyTelegram.rawValue
                    AppState.shared.requestedTab = "settings"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(SetupRequirement.keyTelegram.remediation)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                .strokeBorder(GruxTheme.accentCo.opacity(0.18), lineWidth: 1)
        )
        .onAppear { digest.startDailySchedule() }
    }

    private var statusLine: String {
        // The contract's own sentence, so the reader learns what this is and
        // where to switch it on and off without having to press anything first.
        guard telegramReady else { return SetupRequirement.keyTelegram.remediation }
        guard let t = digest.lastSentAt else { return "Fires once a day. Not sent yet this session." }
        let f = DateFormatter()
        f.timeStyle = .short
        let result = digest.lastResult ?? "Sent"
        return "Last: \(f.string(from: t)) | \(result)"
    }
}
