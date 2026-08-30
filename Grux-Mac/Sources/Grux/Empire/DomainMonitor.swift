import Foundation
import SwiftUI

// Domain renewal monitor, sweeps every 24h across EVERY domain on the
// configured GoDaddy account, records each
// one's expiry, and surfaces any ACTIVE domain within 30 days of lapsing via
// voice + system notification (the "banner") + an Empire dashboard section.
//
// Why this exists: a lapsed domain silently 404s a live brand. GoDaddy emails
// renewal notices, but those drown in the inbox. Grux says it out loud the
// morning a domain crosses the 30-day line, so a renewal (or a deliberate
// let-it-go) is a conscious decision, not an accident.
//
// Scope decisions baked in from reality (see spec hygiene notes in the build
// brief):
//   - ACTIVE-only. An account can hold CANCELLED domains whose `expires` is
//     years in the past. Alerting on those would scream every single day about
//     domains the user already let go. We filter to status == "ACTIVE" so only
//     renewable domains alert.
//   - renewAuto is surfaced, not silenced. A domain with auto-renew ON still
//     enters the window and still shows in the dashboard, but the voice line
//     says so, so a 23-day domain (renewAuto=true) reads as "FYI, it'll
//     renew itself" instead of "act now".
//
// Credentials: GoDaddy key+secret, resolved in this order (rule #5 fallback):
//   1. Keychain (goDaddyApiKey / goDaddyApiSecret), canonical secret store.
//   2. ~/.grux/godaddy-creds.json {"key":"…","secret":"…"}, local, gitignored
//      analog to ship-config.json. If found here, it's seeded into Keychain so
//      step 1 wins on every subsequent launch.
//   3. GODADDY_API_KEY / GODADDY_API_SECRET environment variables.
// If none resolve, the sweep records a lastError and no-ops (no crash, no
// alert). Auth header per CLAUDE.md: `Authorization: sso-key {key}:{secret}`.
//
// Transition detection mirrors ASCStateMonitor: the set of domains currently
// inside the 30-day window is persisted across reboots, so the voice cue fires
// ONCE when a domain newly crosses the line, not every 24h sweep.

struct DomainRecord: Identifiable, Hashable, Sendable {
    var id: String { domain }
    let domain: String
    let expires: Date
    let daysUntilExpiry: Int
    let renewAuto: Bool
    let status: String           // "ACTIVE" (only ACTIVE domains are tracked)

    var isExpiring: Bool { daysUntilExpiry < DomainMonitor.thresholdDays }

    enum Health { case ok, soon, urgent }

    // urgent = inside the window AND auto-renew is off (a real lapse risk).
    // soon = inside the window but auto-renew will save it. ok = outside.
    var health: Health {
        guard isExpiring else { return .ok }
        return renewAuto ? .soon : .urgent
    }
}

@MainActor
final class DomainMonitor: ObservableObject {
    static let shared = DomainMonitor()

    @Published private(set) var records: [DomainRecord] = []
    @Published private(set) var isSweeping: Bool = false
    @Published private(set) var lastSweep: Date?
    @Published private(set) var lastError: String?
    /// Unconfigured, which is a state and not a failure. Kept separate from
    /// `lastError` so the two can never be rendered by the same branch again.
    @Published private(set) var needsSetup: Bool = false

    static let cadence: TimeInterval = 24 * 60 * 60   // 24h, daily
    static let thresholdDays: Int = 30                // alert under 30 days
    private var timer: Timer?
    private var prevExpiring: Set<String> = []        // domains last seen inside the window

    private init() { loadState() }

    // MARK: - Lifecycle

    func start() {
        // Sweep on launch (one GET, ~60 domains, cheap), then daily. Catches
        // domains that crossed the line while the Mac was asleep.
        Task { await sweep() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.cadence, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sweep() }
        }
    }

    /// `askedForByAPerson` is true only when somebody pressed something. The background
    /// 24 hour pass and the launch pass are not that, and they read the Keychain alone.
    func sweep(askedForByAPerson: Bool = false) async {
        guard !isSweeping else { return }
        isSweeping = true
        defer { isSweeping = false }

        guard let creds = Self.resolveCredentials(allowAmbientSources: askedForByAPerson) else {
            // NOT an error, and this is the third place in the app that made the
            // same mistake. The sentence here used to read "No GoDaddy
            // credentials. Set goDaddyApiKey/goDaddyApiSecret in Keychain, drop
            // ~/.grux/godaddy-creds.json, or export GODADDY_API_KEY/SECRET",
            // which offered a stranger three things they cannot do and named two
            // internal storage slots to do them with.
            //
            // Contract section 3: an unconfigured capability is `needs-setup`.
            // The section renders the shared card from the registry row, so the
            // wording comes from the contract and there is nothing to write
            // here.
            needsSetup = true
            lastError = nil
            records = []
            lastSweep = Date()
            persist()
            return
        }
        needsSetup = false

        do {
            let all = try await GoDaddyAPI.fetchDomains(key: creds.key, secret: creds.secret)
            let now = Date()

            // ACTIVE-only. CANCELLED domains carry stale years-old expiry dates.
            var newRecords: [DomainRecord] = all.compactMap { d in
                guard d.status == "ACTIVE" else { return nil }
                let days = Int((d.expires.timeIntervalSince(now) / 86_400).rounded(.down))
                return DomainRecord(
                    domain: d.domain,
                    expires: d.expires,
                    daysUntilExpiry: days,
                    renewAuto: d.renewAuto,
                    status: d.status
                )
            }
            // Soonest-to-expire first.
            newRecords.sort { $0.daysUntilExpiry < $1.daysUntilExpiry }

            // Transition detection, voice cue fires only for domains that
            // newly entered the window since the last sweep.
            let expiringNow = Set(newRecords.filter { $0.isExpiring }.map { $0.domain })
            let newlyExpiring = newRecords.filter { $0.isExpiring && !prevExpiring.contains($0.domain) }
            if !newlyExpiring.isEmpty {
                announce(newlyExpiring, totalInWindow: newRecords.filter { $0.isExpiring })
            }
            prevExpiring = expiringNow

            records = newRecords
            lastError = nil
        } catch {
            lastError = "GoDaddy sweep failed: \(error.localizedDescription)"
            WakeLog.shared.log("DomainMonitor sweep failed: \(error.localizedDescription)")
        }

        lastSweep = Date()
        persist()
    }

    // MARK: - Alert (voice + system notification banner)

    private func announce(_ newly: [DomainRecord], totalInWindow: [DomainRecord]) {
        // The alert names the domain that JUST crossed the line (the trigger),
        // not the overall soonest in the window. Mirrors ASCStateMonitor, which
        // announces the specific record that transitioned. If several crossed in
        // one sweep, lead with the soonest of those and count the rest. The full
        // window total is appended only as trailing context.
        guard let trigger = newly.min(by: { $0.daysUntilExpiry < $1.daysUntilExpiry }) else { return }
        let renewNote = trigger.renewAuto ? "Auto renew is on." : "Auto renew is OFF, add a card or it lapses."

        let lede: String
        if newly.count == 1 {
            lede = "Heads up. The domain \(trigger.domain) just crossed into the 30-day window, it expires in \(trigger.daysUntilExpiry) days."
        } else {
            lede = "Heads up. \(newly.count) domains just crossed into the 30-day window. Soonest is \(trigger.domain) in \(trigger.daysUntilExpiry) days."
        }
        // Mention the broader window only when it holds more than just the new ones.
        let context = totalInWindow.count > newly.count
            ? " \(totalInWindow.count) domains are within 30 days total."
            : ""
        let line = "\(lede) \(renewNote)\(context)"

        WakeLog.shared.log("DomainMonitor: \(newly.count) newly crossed (trigger \(trigger.domain) @ \(trigger.daysUntilExpiry)d), \(totalInWindow.count) in window, speaking + posting banner")
        SpeechEngine.shared.speak(line)
        NotificationManager.shared.sendInfo(
            title: newly.count == 1 ? "Domain expiring: \(trigger.domain)" : "\(newly.count) domains expiring soon",
            body: "\(trigger.domain) in \(trigger.daysUntilExpiry) days. \(renewNote)"
        )
    }

    // MARK: - Credential resolution

    struct Creds { let key: String; let secret: String }

    /// Whether credentials exist somewhere OTHER than the Keychain, checked
    /// without writing anything.
    ///
    /// This exists because the registry was about to tell a lie. `key.godaddy`
    /// resolves from the Keychain, which is correct for a stranger, who pastes
    /// into Settings and has no environment variables. But this monitor also
    /// accepts a JSON file and two environment variables, so an install
    /// configured that way would have had a working domain sweep sitting under a
    /// setup card that said it was unconfigured, and a sidebar count that
    /// included it.
    ///
    /// Deliberately side-effect free, unlike `resolveCredentials()` below, which
    /// seeds the Keychain when it finds the JSON file. The resolver runs from
    /// SwiftUI view bodies on every render, and a check that writes to somebody's
    /// Keychain as a side effect of drawing a screen is not a check.
    static func credentialsFoundOutsideKeychain() -> Bool {
        let path = NSHomeDirectory() + "/.grux/godaddy-creds.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = obj["key"] as? String, !key.isEmpty,
           let secret = obj["secret"] as? String, !secret.isEmpty {
            return true
        }
        let env = ProcessInfo.processInfo.environment
        return !(env["GODADDY_API_KEY"] ?? "").isEmpty
            && !(env["GODADDY_API_SECRET"] ?? "").isEmpty
    }

    /// AMBIENT SOURCES ARE OFF UNLESS A PERSON ASKED FOR THIS RUN.
    ///
    /// The file and environment branches below do not only READ a credential, they WRITE
    /// both halves into the login Keychain and then send them to GoDaddy. So on a Mac where
    /// somebody had never configured Grux but where ~/.grux/godaddy-creds.json had been left
    /// by a script, a dotfiles restore, a migration or an older Grux, the very first launch
    /// adopted that credential and listed every domain on the account.
    ///
    /// The app had already written this defect down. The comment above the App Store Connect
    /// gate says "a credential file left behind by some other tool was enough to make Grux
    /// start talking to App Store Connect on the user's behalf, unasked. Same defect shape as
    /// the GoDaddy file source and the digest-inbox listener." The GoDaddy file source it
    /// names by hand was the one left ungated.
    ///
    /// So the default is Keychain only, which is the store a person can only have filled by
    /// pasting into Settings. The two ambient sources stay reachable from the paths somebody
    /// explicitly took: the Empire dashboard's sweep button and the fire-domain-sweep trigger.
    static func resolveCredentials(allowAmbientSources: Bool = false) -> Creds? {
        // 1. Keychain.
        let kKey = KeychainStore.get(.goDaddyApiKey)
        let kSecret = KeychainStore.get(.goDaddyApiSecret)
        if !kKey.isEmpty && !kSecret.isEmpty {
            return Creds(key: kKey, secret: kSecret)
        }

        guard allowAmbientSources else { return nil }

        // 2. ~/.grux/godaddy-creds.json, seed Keychain when found.
        let path = NSHomeDirectory() + "/.grux/godaddy-creds.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let key = obj["key"] as? String, !key.isEmpty,
           let secret = obj["secret"] as? String, !secret.isEmpty {
            _ = KeychainStore.set(.goDaddyApiKey, key)
            _ = KeychainStore.set(.goDaddyApiSecret, secret)
            return Creds(key: key, secret: secret)
        }

        // 3. Environment.
        let eKey = ProcessInfo.processInfo.environment["GODADDY_API_KEY"] ?? ""
        let eSecret = ProcessInfo.processInfo.environment["GODADDY_API_SECRET"] ?? ""
        if !eKey.isEmpty && !eSecret.isEmpty {
            return Creds(key: eKey, secret: eSecret)
        }

        return nil
    }

    // MARK: - Persistence (prev window + last sweep across reboots)

    private var stateFileURL: URL {
        Persistence.supportDir.appendingPathComponent("domain-monitor-state.json", isDirectory: false)
    }

    private struct PersistedState: Codable {
        var lastSweep: Date?
        var prevExpiring: [String]
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let s = try? dec.decode(PersistedState.self, from: data) {
            self.lastSweep = s.lastSweep
            self.prevExpiring = Set(s.prevExpiring)
        }
    }

    private func persist() {
        let s = PersistedState(lastSweep: lastSweep, prevExpiring: Array(prevExpiring).sorted())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(s) {
            try? data.write(to: stateFileURL, options: .atomic)
        }
    }
}

// MARK: - GoDaddy API

enum GoDaddyAPI {
    enum Error: Swift.Error { case http(Int, String), badJSON }

    struct Domain: Sendable {
        let domain: String
        let expires: Date
        let renewAuto: Bool
        let status: String
    }

    /// GET /v1/domains, lists every domain on the account. We pull a high
    /// limit (the account has ~60; 1000 is the API max) and parse client-side.
    static func fetchDomains(key: String, secret: String) async throws -> [Domain] {
        guard let url = URL(string: "https://api.godaddy.com/v1/domains?limit=1000") else {
            throw Error.badJSON
        }
        var req = URLRequest(url: url)
        req.setValue("sso-key \(key):\(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw Error.http(-1, "no HTTPURLResponse") }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw Error.http(http.statusCode, String(body.prefix(300)))
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Error.badJSON
        }

        // GoDaddy stamps expiry as ISO8601 with fractional seconds (".000Z").
        // Keep a no-fraction fallback in case a record omits them.
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        isoPlain.formatOptions = [.withInternetDateTime]
        func parse(_ s: String?) -> Date? {
            guard let s else { return nil }
            return isoFrac.date(from: s) ?? isoPlain.date(from: s)
        }

        return arr.compactMap { item in
            guard
                let domain = item["domain"] as? String,
                let expires = parse(item["expires"] as? String),
                let status = item["status"] as? String
            else { return nil }
            let renewAuto = item["renewAuto"] as? Bool ?? false
            return Domain(domain: domain, expires: expires, renewAuto: renewAuto, status: status)
        }
    }
}
