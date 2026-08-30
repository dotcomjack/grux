import Foundation
import UserNotifications

// Mac-side store for the live Brands Poster panel. Holds the latest status of
// every configured autonomous posting account, restores a cache on launch,
// pulls live status from the poster service, and mirrors a human/CLI
// readable ~/.grux/brands-poster-status.md. Built on the exact SocialOpsStore
// pattern: @MainActor ObservableObject singleton, cache in Application Support,
// soft-fail to cache on a pull error, and a stale flag when we degrade to cache.
//
// Read-only: there is no command/sweep path here (no cadence or ramp controls).
// A native alert fires the moment any brand transitions into needs_reauth or an
// open circuit, so a posting account quietly going dark can never recur unseen.
//
// Source service: <configured base>/api/brands-poster/status (see
// BrandsPosterService.baseURLs).

@MainActor
final class BrandsPosterStore: ObservableObject {
    static let shared = BrandsPosterStore()

    @Published private(set) var status: BrandsPosterStatus?
    @Published private(set) var lastUpdated: Date?      // last successful fetch
    @Published private(set) var isFetching: Bool = false
    // The standing verdict of the last completed pull, nil when it succeeded
    // (or none has completed). ONE published value rather than the three
    // fields it derives, because the triple was written in lockstep at every
    // verdict site across five stores, and lockstep by hand is how the
    // mislabel classify() exists to prevent almost shipped again.
    @Published private(set) var lastVerdict: PrivateServiceFetch.Classification?
    var lastError: String? { lastVerdict?.displayMessage }
    // True when lastError is the "nothing configured, absence is normal" state
    // rather than a real fault. Typed off the thrown Failure kind so no view
    // ever has to compare lastError against the explanation string.
    var lastErrorIsAbsence: Bool { lastVerdict?.isAbsence ?? false }
    // True when the last pull failed and we are showing a cached status.
    var servingStale: Bool { lastVerdict?.servingStale ?? false }

    private var loaded = false
    // Coalesces refreshes: any number of requests during one pull owe one
    // follow-up pass, and a cancelled awaiter cannot swallow another
    // caller's request. The whole argument lives on RefreshGate.
    private let refreshGate = RefreshGate()

    // Brand IDs known to be in a red state (needs_reauth or open circuit) on the
    // last update. A native alert fires only when a brand NEWLY enters red, so we
    // do not re-nag on every refresh for an account that was already down.
    private var knownRedBrands: Set<String> = []

    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("brands-poster-status.json") }
    private var mdURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("brands-poster-status.md")
    }

    private init() {}

    // Restore the last cached status on launch so the panel has something to
    // show before the first live pull lands.
    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: jsonURL),
           let cached = try? JSONDecoder().decode(BrandsPosterStatus.self, from: data) {
            self.status = cached
        }
    }

    // PULL path: ask the companion service for the latest posting status. The wire status
    // carries no monotonic counter, so unlike SocialOps every successful pull is
    // adopted (the companion is authoritative for posting health); we still soft-fail
    // to the cache on a pull error and tag it stale.
    //
    // Error state is NOT cleared at the top: the fields hold the last
    // completed verdict until this pull lands one of its own. Clearing here
    // unmounted the absence card mid-recovery (its mount keys on the flag),
    // which cancelled the very pull it was awaiting.
    func refresh() async {
        await refreshGate.run(isFetching: { self.isFetching = $0 }) {
            await self.pullOnce()
        }
    }

    private func pullOnce() async {
        do {
            let fresh = try await BrandsPosterService.fetchPostingStatus()
            apply(fresh)
        } catch is CancellationError {
            // The awaiting task was torn down mid-pull (a section unmounting
            // cancels its recovery refresh). No verdict exists, so every
            // error field stays exactly as it was: writing one here is how a
            // cancelled pull once recorded a fabricated absence on this
            // singleton. The gate owns any request that coalesced behind
            // this pass.
            return
        } catch {
            // Keep the cache. The absence x cache rule lives in classify().
            // This store has no push path (no ingest), so a warm status
            // always proves a host once answered a PULL from this machine:
            // absence over it reclassifies to an outage named technically.
            guard let verdict = PrivateServiceFetch.classify(
                error, cache: status == nil ? .empty : .pullProven) else { return }
            self.lastVerdict = verdict
            WakeLog.shared.log("brands-poster: pull failed: \(verdict.displayMessage)")
        }
    }

    private func apply(_ s: BrandsPosterStatus) {
        self.status = s
        self.lastUpdated = Date()
        self.lastVerdict = nil
        persist(s)
        // Fire native alerts for any brand that newly entered a red state
        // (needs_reauth or open circuit). Dedups via knownRedBrands so repeated
        // refreshes for unchanged state are no-ops.
        alertOnNewReds(s)
    }

    // Fire a native macOS notification for any brand that newly turned red
    // (needs_reauth or open circuit). Updates the known-red set so the next pull
    // only alerts on genuinely new failures. Mirrors SocialOpsCoordinator's
    // alertOnNewReds shape so the silent-darkness failure can never recur unseen.
    private func alertOnNewReds(_ s: BrandsPosterStatus) {
        let currentReds = Set(
            s.brands.filter { $0.needsReauth || $0.circuitState == "open" }.map { $0.id }
        )
        let newReds = currentReds.subtracting(knownRedBrands)
        for id in newReds {
            if let rec = s.brands.first(where: { $0.id == id }) {
                fireRedNotification(rec)
            }
        }
        knownRedBrands = currentReds
    }

    private func fireRedNotification(_ rec: BrandPostingRecord) {
        let reason: String
        if rec.needsReauth {
            reason = "needs re-auth (posting halted)"
        } else if rec.circuitState == "open" {
            reason = rec.lastError ?? "circuit open (posting paused)"
        } else {
            reason = "needs attention"
        }
        let content = UNMutableNotificationContent()
        content.title = "Brands Poster: \(rec.brand) down"
        content.body = reason
        content.sound = .default
        content.userInfo = ["kind": "brandsPosterRed", "brand": rec.brand]
        let req = UNNotificationRequest(
            identifier: "grux.brandsposter.red.\(rec.brand)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func persist(_ s: BrandsPosterStatus) {
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        writeMarkdownMirror(s)
    }

    // Human + CLI readable mirror at ~/.grux/brands-poster-status.md, same
    // convention as social-ops.md. Lets a smoke test grep the panel without
    // parsing app state.
    private func writeMarkdownMirror(_ s: BrandsPosterStatus) {
        var lines: [String] = []
        lines.append("# Brands Poster")
        lines.append("")
        let reauth = s.brands.filter { $0.needsReauth }.count
        let circuits = s.brands.filter { $0.circuitState == "open" }.count
        lines.append("Updated: \(s.updatedAt) | service: \(s.service) | cdp_up: \(s.cdpUp) | \(s.brands.count) brands (\(reauth) reauth, \(circuits) circuit-open)")
        lines.append("")
        for r in s.brands.sorted(by: { $0.brand < $1.brand }) {
            var detail = "\(r.brand) (@\(r.handle)) | \(r.statusPill.label) | \(r.postsToday)/\(r.cadencePerDay) (rem \(r.remainingToday))"
            if r.consecutiveFailures > 0 { detail += " | fails \(r.consecutiveFailures)" }
            if let err = r.lastError, !err.isEmpty { detail += " | \(err)" }
            lines.append(detail)
        }
        lines.append("")
        try? lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Poll timer

    // Lightweight repeating pull so a brand going dark surfaces even when nobody
    // is looking at the dashboard. Idempotent: a second call is ignored. Mirrors
    // the SocialOps refresh cadence posture (the companion is the source of truth).
    private var pollTimer: Timer?
    /// True when this machine has been told where the companion service lives.
    /// Absent file means the feature is off, which is the correct posture for
    /// tooling only its author runs.
    ///
    /// Read through `SocialOpsService.configuredHosts()`, the one parser of
    /// ~/.grux/social-ops-hosts.txt, rather than a private copy of it. This
    /// gate, BrandsPosterService's base list and the notice's userConfigured
    /// flag are three answers to one question, and they must move together:
    /// the poller gating on this file while the client tried loopback ONLY is
    /// exactly how a configured remote poster got polled forever against a
    /// host it never contacted.
    static var companionServiceConfigured: Bool {
        !SocialOpsService.configuredHosts().isEmpty
    }

    func startPolling(interval: TimeInterval = 300) {
        guard pollTimer == nil else { return }
        // Do not poll a companion service this machine has never been told
        // about. The poller ran at launch and every five minutes forever on
        // every install, failing to reach loopback each time, on a host that
        // was only ever going to answer for the one person running the service.
        // ~/.grux/social-ops-hosts.txt is the same marker SocialOpsService uses
        // to decide it has somewhere to talk to, so the two agree by
        // construction rather than by a second convention nobody maintains.
        guard Self.companionServiceConfigured else {
            WakeLog.shared.log("brands-poster: no companion service configured, poller stays off.")
            return
        }
        Task { @MainActor in await self.refresh() }
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        WakeLog.shared.log("brands-poster: poll timer started (\(Int(interval))s)")
    }
}
