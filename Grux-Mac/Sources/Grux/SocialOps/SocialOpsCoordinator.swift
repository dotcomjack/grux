import Foundation
import UserNotifications

// Coordinates inbound change-events from the companion service for the Social Ops
// Cockpit. The companion service's
// social-ops service POSTs a {"kind":"social-ops", ...} event to Grux's
// local inbox (PRInboxServer) the moment a cell flips; that route forwards the
// JSON body here. We refresh the store, fire a native macOS notification on any
// NEW red cell (respecting muted), and relay the grid to a paired phone.
//
// PHONE RELAY (Task 9): relayGridToPhone() calls
// PhoneReceiverService.shared.notifySocialOpsPanel(records:), which is a no-op
// when no authenticated phone session is connected. executePhoneAction()
// handles inbound two-tap operator controls (routed here by PhoneChatBridge):
// it POSTs the command to the companion service via the store, then re-pushes
// the refreshed grid.

@MainActor
final class SocialOpsCoordinator {
    static let shared = SocialOpsCoordinator()

    // Cell IDs ("brand|platform") known to be red on the last event. A native
    // alert fires only when a cell newly enters red (not on every event for a
    // cell that was already red), so we do not re-nag.
    private var knownRedCells: Set<String> = []

    // Whether this run has already said that the Telegram fallback is off. See
    // `noteTelegramFallbackOff`.
    private var telegramFallbackNoticeShown = false

    private init() {}

    // Entry point for an inbound companion service change-event (forwarded by PRInboxServer
    // for kind=="social-ops"). The event body may carry a full snapshot under
    // "snapshot"/"state", or just signal that something changed; either way we
    // refresh the store from the render service so the grid is authoritative.
    func handleMiniEvent(_ json: [String: Any]) {
        WakeLog.shared.log("social-ops: mini change-event received")
        Task { @MainActor in
            // If the event embeds a fresh snapshot, ingest it directly to avoid a
            // round trip; otherwise pull the latest state.
            if let snapData = Self.embeddedSnapshot(json) {
                SocialOpsStore.shared.ingest(snapData)
            } else {
                await SocialOpsStore.shared.refresh()
            }
            alertOnNewReds()
            relayGridToPhone()
        }
    }

    // Phone-on-mesh test. PhoneReceiverState.isConnected is set true the moment
    // a phone clears AUTH_OK and back to false on teardown, so it is the live
    // "is a paired phone authenticated and reachable right now" signal. Used to
    // decide whether the Telegram fallback is needed for a red event.
    private var phoneOnMesh: Bool {
        PhoneReceiverState.shared.isConnected
    }

    // Fire a native macOS notification for any cell that newly turned red.
    // Muted cells are skipped (operator silenced them on purpose). Updates the
    // known-red set so the next event only alerts on genuinely new failures.
    // Internal (not private) so the store can fire alerts on the PULL path too,
    // not just on companion service push events. Safe to call repeatedly: knownRedCells dedups.
    func alertOnNewReds() {
        guard let records = SocialOpsStore.shared.snapshot?.records else { return }
        let currentReds = Set(records.filter { $0.status == .red && !$0.muted }.map { $0.id })
        let newReds = currentReds.subtracting(knownRedCells)
        // Telegram is a fallback only: it fires for a genuinely new red ONLY when
        // no paired phone is on the mesh at this moment (otherwise the phone push
        // already covers it). We snapshot phoneOnMesh once per event so a flap
        // mid-loop cannot send some cells to the phone and some to Telegram.
        let phoneOff = !phoneOnMesh
        for id in newReds {
            if let rec = records.first(where: { $0.id == id }) {
                fireRedNotification(rec)
                if phoneOff {
                    sendTelegramDownAlert(rec)
                }
            }
        }
        // Track all currently-red (including muted) so unmuting later re-alerts,
        // and a cell recovering then re-failing alerts again.
        knownRedCells = Set(records.filter { $0.status == .red }.map { $0.id })
            .subtracting(records.filter { $0.muted }.map { $0.id })
    }

    private func fireRedNotification(_ rec: SocialHealthRecord) {
        let content = UNMutableNotificationContent()
        content.title = "Social Ops: \(rec.brand) \(rec.platform.rawValue) down"
        content.body = rec.lastError.isEmpty
            ? "This account needs attention. Open the cockpit to retry or reauth."
            : rec.lastError
        content.sound = .default
        content.userInfo = ["kind": "socialOpsRed", "cell": rec.id]
        let req = UNNotificationRequest(
            identifier: "grux.socialops.red.\(rec.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // Relay the current grid to a paired phone. PhoneReceiverService.notifySocialOpsPanel
    // is a no-op when no authenticated phone session is connected, so this is
    // safe to call unconditionally.
    func relayGridToPhone() {
        let records = SocialOpsStore.shared.snapshot?.records ?? []
        PhoneReceiverService.shared.notifySocialOpsPanel(records: records)
    }

    // MARK: - Scheduled digests (daily health + weekly trend)

    // UserDefaults keys for the once-per-period guards. Storing a yyyy-MM-dd
    // string (daily) and a yyyy-ww ISO week string (weekly) keeps the guard
    // robust across relaunches, sleep, and clock changes without a Timer that
    // has to survive the whole period.
    private static let dailyDigestKey = "socialOps.lastDailyDigestDay"
    private static let weeklyTrendKey = "socialOps.lastWeeklyTrendWeek"

    private static func dayStamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func weekStamp(_ date: Date = Date()) -> String {
        let cal = Calendar(identifier: .iso8601)
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let y = comps.yearForWeekOfYear ?? 0
        let w = comps.weekOfYear ?? 0
        return String(format: "%04d-W%02d", y, w)
    }

    // Start the periodic scheduler. A lightweight repeating Timer ticks every
    // 15 minutes and the date-string guards decide whether the daily or weekly
    // card is actually due, so a missed tick (sleep, app restart) just fires on
    // the next wake instead of being lost. Idempotent: a second call is ignored.
    private var schedulerTimer: Timer?
    func startSchedulers() {
        guard schedulerTimer == nil else { return }
        // Kick once shortly after launch so a day or week that rolled over while
        // the app was closed still gets its card.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            self.runScheduledDigestsIfDue()
        }
        let t = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runScheduledDigestsIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        schedulerTimer = t
        WakeLog.shared.log("social-ops: digest scheduler started")
    }

    // Fire whichever scheduled cards are due. Public so a debug trigger file can
    // force a run without waiting for the tick.
    /// Whether the unattended daily and weekly digests may speak. Default ON, because
    /// somebody who has pointed Grux at a posting service wants to hear when an account goes
    /// dark, and that is the whole stated purpose of the watch. What was missing was any way
    /// to say no: no Settings toggle, no contract step, no defaults key, so the only way to
    /// stop a daily notification and a chat card was to stop launching Grux.
    ///
    /// `force` is the manual "digest now" path and ignores this, because somebody who just
    /// pressed a button has asked for exactly one digest.
    /// `nonisolated` because the enclosing type is `@MainActor`, which would otherwise make
    /// these statics main-actor isolated and unreachable from a plain test method. Reading a
    /// defaults key needs no isolation, and a switch a test cannot drive is a switch nobody
    /// has confirmed works.
    nonisolated static let digestsEnabledKey = "grux.socialOps.digestsEnabled"

    nonisolated static var digestsEnabled: Bool {
        UserDefaults.standard.object(forKey: digestsEnabledKey) as? Bool ?? true
    }

    func runScheduledDigestsIfDue(force: Bool = false) {
        guard force || Self.digestsEnabled else { return }
        let defaults = UserDefaults.standard
        let today = Self.dayStamp()
        if force || defaults.string(forKey: Self.dailyDigestKey) != today {
            if emitDailyDigest() {
                defaults.set(today, forKey: Self.dailyDigestKey)
            }
        }
        let thisWeek = Self.weekStamp()
        if force || defaults.string(forKey: Self.weeklyTrendKey) != thisWeek {
            if emitWeeklyTrend() {
                defaults.set(thisWeek, forKey: Self.weeklyTrendKey)
            }
        }
    }

    // A record needs re-auth when the session is gone or a 2FA challenge is
    // pending: logged out, invalid session, or a standing 2FA wall. These are
    // the states an operator must clear by hand (retry alone will not fix them).
    private func needsReauth(_ r: SocialHealthRecord) -> Bool {
        !r.loggedIn || !r.sessionValid || r.twoFAChallenge
    }

    // Build + deliver the daily health digest: green/amber/red counts per brand
    // plus any account needing re-auth. Returns false (so the guard does not
    // advance) when there is no snapshot yet, so the digest retries next tick.
    @discardableResult
    private func emitDailyDigest() -> Bool {
        guard let records = SocialOpsStore.shared.snapshot?.records, !records.isEmpty else {
            return false
        }
        let brands = Set(records.map { $0.brand }).sorted()
        var lines: [String] = []
        lines.append("Social Ops daily health digest")
        for brand in brands {
            let cells = records.filter { $0.brand == brand }
            let g = cells.filter { $0.status == .green }.count
            let a = cells.filter { $0.status == .amber }.count
            let r = cells.filter { $0.status == .red }.count
            lines.append("\(brand): \(g) green, \(a) amber, \(r) red")
        }
        let reauth = records.filter { needsReauth($0) }
        if reauth.isEmpty {
            lines.append("Re-auth needed: none")
        } else {
            let labels = reauth
                .sorted(by: { ($0.brand, $0.platform.rawValue) < ($1.brand, $1.platform.rawValue) })
                .map { "\($0.brand) \($0.platform.rawValue)" }
            lines.append("Re-auth needed: \(labels.joined(separator: ", "))")
        }
        let body = lines.joined(separator: "\n")

        // Native notification (one-line summary in the body, brands in subtitle).
        let totalRed = records.filter { $0.status == .red }.count
        let totalAmber = records.filter { $0.status == .amber }.count
        fireDigestNotification(
            title: "Social Ops daily digest",
            body: "\(records.count) cells across \(brands.count) brands. \(totalRed) red, \(totalAmber) amber. \(reauth.count) need re-auth."
        )
        // Chat card.
        AppState.shared.appendChat(ChatMessage(role: .system, content: "📊 " + body))
        // Compact version to the phone (no-op when no phone is connected).
        relayGridToPhone()
        WakeLog.shared.log("social-ops: daily digest emitted")
        return true
    }

    // Build + deliver the weekly trend summary: per (brand, platform) reachTrend
    // direction (up / flat / down) read from the current snapshot. Returns false
    // when there is no snapshot yet so it retries on the next tick.
    @discardableResult
    private func emitWeeklyTrend() -> Bool {
        guard let records = SocialOpsStore.shared.snapshot?.records, !records.isEmpty else {
            return false
        }
        let sorted = records.sorted(by: {
            ($0.brand, $0.platform.rawValue) < ($1.brand, $1.platform.rawValue)
        })
        var up = 0, down = 0, flat = 0
        var lines: [String] = []
        lines.append("Social Ops weekly trend summary")
        for r in sorted {
            let dir = Self.trendDirection(r.reachTrend)
            switch dir {
            case "up": up += 1
            case "down": down += 1
            default: flat += 1
            }
            lines.append("\(r.brand) \(r.platform.rawValue): reach \(dir)")
        }
        let body = lines.joined(separator: "\n")

        fireDigestNotification(
            title: "Social Ops weekly trends",
            body: "Reach across \(records.count) accounts: \(up) up, \(flat) flat, \(down) down."
        )
        AppState.shared.appendChat(ChatMessage(role: .system, content: "📈 " + body))
        relayGridToPhone()
        WakeLog.shared.log("social-ops: weekly trend emitted")
        return true
    }

    // Normalize a free-form reachTrend string into up / flat / down. The companion service
    // may report "up", "down", "flat", "rising", "falling", a signed number, or
    // an arrow; we fold all of those into three buckets for the card.
    private static func trendDirection(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return "flat" }
        if s.contains("up") || s.contains("ris") || s.contains("grow") || s.hasPrefix("+") || s.contains("▲") {
            return "up"
        }
        if s.contains("down") || s.contains("fall") || s.contains("drop") || s.hasPrefix("-") || s.contains("▼") {
            return "down"
        }
        if let v = Double(s) {
            if v > 0 { return "up" }
            if v < 0 { return "down" }
        }
        return "flat"
    }

    private func fireDigestNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["kind": "socialOpsDigest"]
        let req = UNNotificationRequest(
            identifier: "grux.socialops.digest.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // MARK: - Telegram fallback (down-alerts only, phone-off-mesh only)

    // Send a plain Telegram down-alert for a single newly-red cell.
    //
    // Refuses unless the user turned Telegram on: `key.telegram` is checked
    // before a request exists, and the bot token and chat id are read from the
    // Keychain slots the Settings fields write, so nothing here can fire off a
    // credential the setup UI never asked for. An install that has not opted in
    // is told once, by `noteTelegramFallbackOff`, rather than quietly losing the
    // alert. Plain text only (no markdown), so a label with special characters
    // never breaks parsing. Never logs the token.
    private func sendTelegramDownAlert(_ rec: SocialHealthRecord) {
        guard CapabilityResolver.isSatisfied(.keyTelegram) else {
            noteTelegramFallbackOff()
            return
        }
        let token = KeychainStore.get(.telegramBotToken).trimmingCharacters(in: .whitespacesAndNewlines)
        let chatId = KeychainStore.get(.telegramChatId).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !chatId.isEmpty else { return }

        let detail = rec.lastError.isEmpty
            ? "Account needs attention. Open the cockpit to retry or reauth."
            : rec.lastError
        let text = "Social Ops down: \(rec.brand) \(rec.platform.rawValue). \(detail) (phone off mesh, Telegram fallback)"

        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendMessage") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "chat_id": chatId,
            "text": text,
            "disable_web_page_preview": true,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload) else { return }
        req.httpBody = bodyData

        WakeLog.shared.log("social-ops: telegram fallback firing for \(rec.id) (phone off mesh)")
        URLSession.shared.dataTask(with: req) { _, response, error in
            // Completion runs on a background URLSession thread; WakeLog is
            // @MainActor, so hop before touching it.
            let status = (response as? HTTPURLResponse)?.statusCode
            let errText = error?.localizedDescription
            Task { @MainActor in
                if let errText = errText {
                    WakeLog.shared.log("social-ops: telegram fallback send failed: \(errText)")
                } else if let status = status, !(200...299).contains(status) {
                    WakeLog.shared.log("social-ops: telegram fallback HTTP \(status)")
                }
            }
        }.resume()
    }

    // Tell the user, once per run, that the alert they are missing had a channel
    // and it is switched off.
    //
    // This moment is the whole reason the fallback exists: the phone is off the
    // mesh, so the red notification just posted is landing on a Mac nobody is
    // sitting at. Skipping in silence would mean the one person who needs to
    // know never learns Telegram was an option. It carries the capability's own
    // remediation sentence rather than a second wording, and fires at most once
    // per launch so a bad afternoon of red cells cannot turn it into nagging.
    private func noteTelegramFallbackOff() {
        WakeLog.shared.log("social-ops: telegram fallback is off, nothing sent")
        guard !telegramFallbackNoticeShown else { return }
        telegramFallbackNoticeShown = true

        let content = UNMutableNotificationContent()
        content.title = "Social Ops alerts stop at this Mac"
        content.body = SetupRequirement.keyTelegram.remediation
        content.sound = .default
        content.userInfo = ["kind": "socialOpsTelegramOff"]
        let req = UNNotificationRequest(
            identifier: "grux.socialops.telegram.off",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // Execute a phone-originated two-tap operator action. Maps the string action
    // to a SocialOpAction, POSTs the command to the companion service via the store (which
    // refreshes the grid on completion), then re-pushes the updated grid to the
    // phone so the cell reflects the result live. Unknown actions are ignored.
    func executePhoneAction(brand: String, platform: String, action: String) {
        guard let actionEnum = SocialOpAction(rawValue: action) else {
            WakeLog.shared.log("social-ops: phone action ignored, unknown action \(action)")
            return
        }
        // Sweep is global (no cell): trigger a live re-check and ack.
        if actionEnum == .sweep {
            Task { @MainActor in
                let ok = await SocialOpsStore.shared.sweep()
                relayGridToPhone()
                PhoneReceiverService.shared.notifySocialOpsAck(
                    brand: "", platform: "",
                    status: ok ? "done" : "failed",
                    message: ok ? "sweep started" : "sweep failed")
            }
            return
        }
        guard let platformEnum = SocialPlatform(rawValue: platform) else {
            WakeLog.shared.log("social-ops: phone action ignored, unknown platform \(platform)")
            return
        }
        Task { @MainActor in
            let result = await SocialOpsStore.shared.sendCommand(
                brand: brand, platform: platformEnum, action: actionEnum
            )
            // sendCommand refreshes the store on completion; re-push the grid, then
            // ack the phone with the human-readable outcome (drives the toast +
            // the per-cell last-action line).
            relayGridToPhone()
            PhoneReceiverService.shared.notifySocialOpsAck(
                brand: brand, platform: platform,
                status: result.ok ? "done" : "failed",
                message: result.message)
        }
    }

    // Smoke test: pull the companion service's current state, write a PASS/FAIL summary to
    // ~/.grux/social-ops-cockpit-test-result.txt, return a one-line summary.
    // Exercises the Mac pull path end to end without waiting for a sweep event.
    func runSmokeTest() async -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        lines.append("social-ops-cockpit-test @ \(iso.string(from: Date()))")

        var summary: String
        do {
            let snap = try await SocialOpsService.fetchState()
            SocialOpsStore.shared.ingest(snap)
            let reds = snap.records.filter { $0.status == .red }.count
            let ambers = snap.records.filter { $0.status == .amber }.count
            let greens = snap.records.filter { $0.status == .green }.count
            lines.append("PASS: reached the remote service, \(snap.records.count) cells (\(greens) green, \(ambers) amber, \(reds) red)")
            lines.append("source: \(snap.source) | generatedAt: \(snap.generatedAt)")
            lines.append("inboxServerPort: \(PRInboxServer.shared.boundPort)")
            for r in snap.records.sorted(by: { ($0.brand, $0.platform.rawValue) < ($1.brand, $1.platform.rawValue) }) {
                var l = "  \(r.brand) | \(r.platform.rawValue) | \(r.status.rawValue)"
                if !r.lastError.isEmpty { l += " | \(r.lastError)" }
                lines.append(l)
            }
            summary = "Social Ops cockpit test PASS: \(snap.records.count) cells, \(reds) red, \(ambers) amber via \(snap.source)."
        } catch {
            lines.append("FAIL: could not reach the remote social-ops service: \(error.localizedDescription)")
            lines.append("inboxServerPort: \(PRInboxServer.shared.boundPort)")
            summary = "Social Ops cockpit test FAIL: \(error.localizedDescription)"
        }

        let outPath = NSHomeDirectory() + "/.grux/social-ops-cockpit-test-result.txt"
        try? lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
        return summary
    }

    // Pull a full snapshot out of the event body if the companion service embedded one.
    // Tolerates either {"snapshot": {...}} or {"state": {...}}.
    private static func embeddedSnapshot(_ json: [String: Any]) -> SocialOpsSnapshot? {
        for key in ["snapshot", "state"] {
            if let nested = json[key] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: nested),
               let snap = try? JSONDecoder().decode(SocialOpsSnapshot.self, from: data) {
                return snap
            }
        }
        return nil
    }
}
