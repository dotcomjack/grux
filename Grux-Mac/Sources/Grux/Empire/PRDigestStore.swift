import Foundation

// Nightly open-PR digest across the repos you track. Built by a companion
// digest service (gh REST API + optional local-model headline), then surfaced
// in Grux's Empire Dashboard as a "Pull Requests" section.
//
// ARCHITECTURE (honors the spec AND reality; see the catalog for the writeup):
// The spec asked for two things that look contradictory until you have both:
//   1. "Grux exposes /api/inbox locally for the service to POST to." -> PUSH.
//   2. The digest service runs on an early-morning cron.           -> the Mac
//      laptop is often asleep then, so a push alone would silently miss days.
// So this is a PUSH-primary, PULL-fallback design:
//   - PUSH: PRInboxServer (NWListener) exposes POST /api/inbox on the local
//     network. When the Mac is awake the service delivers the digest instantly
//     and we call ingest(). This is the literal acceptance-criterion endpoint.
//   - PULL: the service ALSO caches latest.json and serves it over HTTP, so on
//     launch / dashboard-open Grux pulls the most recent digest and never
//     misses a night the laptop slept through. Same direction the other
//     companion-service clients use.
// Both paths feed the same PRDigestStore. Whoever has the newer generatedAt
// wins, so a stale pull never clobbers a fresh push (or vice versa).
//
// Source endpoint: <configured host>/api/digest/latest (see baseURLs below,
// empty until configured). Mirrors ~/.grux/pr-digest.md as a human/CLI-readable
// companion.

struct PRDigest: Codable, Equatable {
    var generatedAt: String
    var generatedAtEpoch: Double
    var repoCount: Int
    var openCount: Int
    var headline: String
    var headlineProvider: String   // ollama | heuristic | none
    var fallbackUsed: Bool
    var source: String             // mini-cron | mini-manual | grux-pull
    var prs: [PRItem]
}

struct PRItem: Codable, Equatable, Identifiable {
    var repo: String               // "owner/name"
    var number: Int
    var title: String
    var author: String
    var url: String
    var createdAt: String
    var ageDays: Int
    var draft: Bool
    var mergeable: String          // clean | dirty | blocked | unstable | unknown | draft
    var additions: Int
    var deletions: Int
    var changedFiles: Int
    var baseRef: String
    var headRef: String

    var id: String { "\(repo)#\(number)" }
}

@MainActor
final class PRDigestStore: ObservableObject {
    static let shared = PRDigestStore()

    @Published private(set) var digest: PRDigest?
    @Published private(set) var lastUpdated: Date?      // last successful fetch OR push
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
    // True when the last pull failed and we are showing a cached digest.
    var servingStale: Bool { lastVerdict?.servingStale ?? false }

    private var loaded = false
    // Coalesces refreshes: any number of requests during one pull owe one
    // follow-up pass, and a cancelled awaiter cannot swallow another
    // caller's request. The whole argument lives on RefreshGate.
    private let refreshGate = RefreshGate()
    // Start-order guard, the one MetaAdsStore and SocialOpsStore already
    // hold. These two are the stores that HAVE a push channel, so they are
    // the ones that most needed it: a push landing during a failing pull ran
    // ingest() -> apply(), setting a fresh digest and clearing the verdict,
    // and the pull's unguarded verdict write then landed on top. servingStale
    // derives from "a payload exists", so the section rendered "Showing
    // cached digest. Last pull failed" over a digest that had arrived seconds
    // earlier, beside a lastUpdated header saying it was current. That is the
    // mislabel classify() exists to prevent, written by the one path it does
    // not govern.
    private var pullSequence = PrivateServiceFetch.PullSequence()

    // Grux-side ingress marker for the digest we hold: "pull" or "push",
    // stamped by the two entry points below and read by cacheProvenance.
    // A stamped fact rather than a read of digest.source, because source is
    // a wire-controlled display string PRInboxServer preserves verbatim: a
    // replayed Grux-persisted digest genuinely carrying "grux-pull", pushed
    // from elsewhere, would otherwise mark a never-pulled cache pull-proven.
    static let ingressDefaultsKey = "grux.services.prDigestIngress"

    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("pr-digest.json") }
    private var mdURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pr-digest.md")
    }

    private init() {}

    // Restore the last cached digest on launch so the dashboard has something to
    // show before the first live fetch (or push) lands.
    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: jsonURL),
           let cached = try? JSONDecoder().decode(PRDigest.self, from: data) {
            self.digest = cached
        }
    }

    // PUSH path: the service delivered a digest to POST /api/inbox. Accept it only
    // if it is newer than what we already hold, so an out-of-order or replayed
    // push can't roll us backwards.
    @discardableResult
    func ingest(_ fresh: PRDigest, source: String) -> Bool {
        if let current = digest, fresh.generatedAtEpoch <= current.generatedAtEpoch {
            return false
        }
        var d = fresh
        d.source = source
        UserDefaults.standard.set("push", forKey: Self.ingressDefaultsKey)
        // The push, and the one write here that supersedes in-flight pulls.
        apply(d, supersedesInFlightPulls: true)
        WakeLog.shared.log("pr-digest: ingested push (\(d.openCount) open across \(d.repoCount) repos)")
        return true
    }

    // PULL path: ask the service for the latest cached digest.
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
        let seq = pullSequence.begin()
        do {
            let fresh = try await PRDigestService.fetchLatest()
            guard pullSequence.claimWrite(seq) else { return }
            // Adopt only when STRICTLY newer than what we hold. A push between
            // launch and this pull may already be fresher; an equal-epoch pull is
            // a true no-op so we don't re-persist or overwrite the push's source
            // provenance with "grux-pull". Mirrors ingest()'s <= reject rule.
            if let current = digest, fresh.generatedAtEpoch <= current.generatedAtEpoch {
                // An EQUAL-epoch no-op is still an ANSWER to a pull this
                // machine sent, and the answer IS the payload being held, so
                // a push-fed marker upgrades to "pull" (SocialOpsStore's
                // markHeldSnapshotPullProven twin). Without this a loopback
                // install that both pushes and pulls holds "push" forever,
                // and the day the companion dies classify() reads
                // (.absence, .pushFed) as the normal state: total silence
                // over rotting data. Both halves of the rule (equal epoch,
                // and a missing marker counting as push-fed) live once at
                // PrivateServiceFetch.upgradesIngressToPull, shared with
                // TestDigestStore.
                if PrivateServiceFetch.upgradesIngressToPull(
                    freshEpoch: fresh.generatedAtEpoch,
                    heldEpoch: current.generatedAtEpoch,
                    cache: cacheProvenance) {
                    UserDefaults.standard.set("pull", forKey: Self.ingressDefaultsKey)
                }
                self.lastUpdated = Date()
                self.lastVerdict = nil
            } else {
                var d = fresh
                d.source = "grux-pull"
                UserDefaults.standard.set("pull", forKey: Self.ingressDefaultsKey)
                apply(d)
            }
        } catch is CancellationError {
            // The awaiting task was torn down mid-pull (a section unmounting
            // cancels its recovery refresh). No verdict exists, so every
            // error field stays exactly as it was: writing one here is how a
            // cancelled pull once recorded a fabricated absence on this
            // singleton. The gate owns any request that coalesced behind
            // this pass.
            return
        } catch {
            // Host asleep / network drop / no-digest-yet: keep the cache. The
            // absence x cache rule lives in classify(): pull absence over a
            // push-fed digest is normal, over a pull-proven one it is an
            // outage named technically.
            guard let verdict = PrivateServiceFetch.classify(error, cache: cacheProvenance)
            else { return }
            // A verdict that is stale on arrival must not label a payload a
            // push delivered while this pull was still on the wire.
            guard pullSequence.claimWrite(seq) else { return }
            self.lastVerdict = verdict
            WakeLog.shared.log("pr-digest: pull failed: \(verdict.displayMessage)")
        }
    }

    // How the digest we hold entered this store, for classify()'s absence x
    // cache rule. Read from the Grux-side stamped marker; the source string
    // is trusted only as a legacy fallback. The rule itself lives once at
    // PrivateServiceFetch.cacheProvenance(source:marker:), shared with
    // TestDigestStore.
    private var cacheProvenance: PrivateServiceFetch.CacheProvenance {
        PrivateServiceFetch.cacheProvenance(
            source: digest?.source,
            marker: UserDefaults.standard.string(forKey: Self.ingressDefaultsKey))
    }

    /// - Parameter supersedesInFlightPulls: true ONLY for a PUSH, which
    ///   carries no sequence of its own and is newer than anything already
    ///   on the wire. A pull's own apply must never supersede.
    private func apply(_ d: PRDigest, supersedesInFlightPulls: Bool = false) {
        // A push, like a command echo, is newer than any pull already on
        // the wire, and unlike a pull it carries no sequence of its own.
        //
        // GATED, matching MetaAdsStore.apply and SocialOpsStore.apply, which
        // both document the ungated form as a bug: a PULL's own apply would
        // otherwise set written = started and discard any pull that started
        // later. It is masked here today only because RefreshGate keeps these
        // two stores single-flight, and it goes live the moment either grows
        // a command's read-after-write pull, which is the shape both sibling
        // stores already have. Latent is not safe, it is undated.
        if supersedesInFlightPulls { pullSequence.supersedeInFlight() }
        self.digest = d
        self.lastUpdated = Date()
        self.lastVerdict = nil
        persist(d)
    }

    private func persist(_ d: PRDigest) {
        if let data = try? JSONEncoder().encode(d) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        writeMarkdownMirror(d)
    }

    // Human + CLI readable mirror at ~/.grux/pr-digest.md, same convention as
    // sentiment.md. Lets a smoke test grep the result without parsing app state.
    private func writeMarkdownMirror(_ d: PRDigest) {
        var lines: [String] = []
        lines.append("# Open PR Digest")
        lines.append("")
        lines.append("Generated: \(d.generatedAt) | \(d.openCount) open across \(d.repoCount) repo\(d.repoCount == 1 ? "" : "s") | source: \(d.source)")
        lines.append("")
        lines.append(d.headline)
        lines.append("")
        // Oldest first: the stalest PR is the one most likely rotting.
        for p in d.prs.sorted(by: { $0.ageDays > $1.ageDays }) {
            let draftTag = p.draft ? " (draft)" : ""
            lines.append("## \(p.repo) #\(p.number)\(draftTag) | \(p.mergeable) | \(p.ageDays)d old")
            lines.append("\(p.title) | by \(p.author) | +\(p.additions)/-\(p.deletions) in \(p.changedFiles) file\(p.changedFiles == 1 ? "" : "s")")
            lines.append(p.url)
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    }
}

enum PRDigestService {
    // Base URLs to try, in order. EMPTY until configured: the digest comes
    // from a service the user runs, and Grux ships pointing at nobody's
    // machine. Configure it with one base URL per line in
    // ~/.grux/pr-digest-hosts.txt, e.g.
    //
    //   http://my-server:3852
    //   http://localhost:3852
    //
    // Blank lines and lines starting with # are ignored. With nothing
    // configured, fetchLatest() below finds no host and throws
    // PrivateServiceNotice.pullRequestDigest.explanation, which PRDigestSection
    // already renders in place of the empty list. The PUSH path (PRInboxServer)
    // is independent and still works.
    static var baseURLs: [String] {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux")
            .appendingPathComponent("pr-digest-hosts.txt")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func fetchLatest() async throws -> PRDigest {
        // The failover rule (first success wins, an answered fault outranks
        // transport silence, a 404 never aborts the remaining bases, and the
        // absence notice only stands when nobody configured a host) lives once
        // in PrivateServiceFetch, and so does the per-attempt HTTP shape.
        // ONE read of the hosts file feeds both arguments, so the base list
        // and the flag cannot disagree mid-edit.
        let bases = baseURLs
        return try await PrivateServiceFetch.run(
            service: "pull request digest service",
            bases: bases,
            userConfigured: !bases.isEmpty,
            absenceExplanation: PrivateServiceNotice.pullRequestDigest.explanation,
            unconfiguredDetail: "~/.grux/pr-digest-hosts.txt names no host",
            attempt: PrivateServiceFetch.jsonAttempt(
                PRDigest.self,
                path: "/api/digest/latest",
                notFoundMessage: "service has no digest yet (404); run the nightly build"
            )
        )
    }
}
