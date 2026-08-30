import Foundation

// Nightly test report for every configured repo. Built by a companion nightly
// service on another machine (git pull + typecheck + tests per repo), then
// surfaced in Grux's Empire Dashboard as a "Nightly Tests" section.
//
// ARCHITECTURE: identical PUSH-primary, PULL-fallback design to PRDigestStore
// (the spec's "POST to Grux /api/inbox" plus a pull so a slept-through laptop
// never misses a night):
//   - PUSH: PRInboxServer exposes POST /api/inbox/tests on the local network (a
//     second route on the same token-guarded server the PR digest uses). When
//     the Mac is awake the service delivers instantly and we call ingest().
//   - PULL: the service caches latest.json and serves it, so on launch /
//     dashboard-open Grux pulls the most recent report. Same direction the LLM,
//     RAG, sentiment, and PR-digest clients already use.
// Both paths feed this store; the newer generatedAtEpoch wins, so a stale pull
// never clobbers a fresh push (or vice versa).
//
// Source service: <configured host>/api/tests/latest, empty until configured.
// Mirrors ~/.grux/nightly-tests.md as a human/CLI-readable companion.

struct TestCheck: Codable, Equatable {
    var kind: String        // typecheck | test | install
    var command: String     // "npx tsc --noEmit"
    var status: String      // pass | fail | skip
    var durationSec: Double
    var summary: String     // "ok" or the tail of the failing output
}

struct TestRepoResult: Codable, Equatable, Identifiable {
    var repo: String        // "owner/repo-name"
    var name: String        // "repo-name"
    var status: String      // pass | fail | skip | error
    var gitInfo: String     // "main @ a1b2c3d [pulled (updated)]"
    var durationSec: Double
    var checks: [TestCheck]

    var id: String { repo }
}

struct TestDigest: Codable, Equatable {
    var generatedAt: String
    var generatedAtEpoch: Double
    var source: String          // mini-cron | mini-manual | grux-pull
    var repoCount: Int
    var passCount: Int
    var failCount: Int
    var skipCount: Int
    var errorCount: Int
    var durationSec: Double
    var fallbackUsed: Bool      // degraded coverage (a repo could not run)
    var headline: String
    var results: [TestRepoResult]
}

@MainActor
final class TestDigestStore: ObservableObject {
    static let shared = TestDigestStore()

    @Published private(set) var digest: TestDigest?
    @Published private(set) var lastUpdated: Date?
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
    // True when the last pull failed and we are showing a cached report.
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

    // Grux-side ingress marker for the report we hold: "pull" or "push",
    // stamped by the two entry points below and read by cacheProvenance.
    // A stamped fact rather than a read of digest.source, because source is
    // a wire-controlled display string PRInboxServer preserves verbatim: a
    // replayed Grux-persisted report genuinely carrying "grux-pull", pushed
    // from elsewhere, would otherwise mark a never-pulled cache pull-proven.
    static let ingressDefaultsKey = "grux.services.testDigestIngress"

    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("nightly-tests.json") }
    private var mdURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("nightly-tests.md")
    }

    private init() {}

    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: jsonURL),
           let cached = try? JSONDecoder().decode(TestDigest.self, from: data) {
            self.digest = cached
        }
    }

    // PUSH path: the service delivered a report to POST /api/inbox/tests. Accept it
    // only if it is newer than what we hold, so an out-of-order/replayed push
    // can't roll us backwards.
    @discardableResult
    func ingest(_ fresh: TestDigest, source: String) -> Bool {
        if let current = digest, fresh.generatedAtEpoch <= current.generatedAtEpoch {
            return false
        }
        var d = fresh
        d.source = source
        UserDefaults.standard.set("push", forKey: Self.ingressDefaultsKey)
        // The push, and the one write here that supersedes in-flight pulls.
        apply(d, supersedesInFlightPulls: true)
        WakeLog.shared.log("nightly-tests: ingested push (\(d.passCount) pass / \(d.failCount) fail across \(d.repoCount) repos)")
        return true
    }

    // PULL path: ask the service for the latest cached report.
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
            let fresh = try await TestDigestService.fetchLatest()
            guard pullSequence.claimWrite(seq) else { return }
            // Adopt only when STRICTLY newer; an equal-epoch pull is a no-op so we
            // don't overwrite a push's provenance with "grux-pull". Mirrors
            // ingest()'s <= reject rule.
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
                // PRDigestStore.
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
            // Keep the cache. The absence x cache rule lives in classify():
            // pull absence over a push-fed report is normal, over a
            // pull-proven one it is an outage named technically.
            guard let verdict = PrivateServiceFetch.classify(error, cache: cacheProvenance)
            else { return }
            // A verdict that is stale on arrival must not label a payload a
            // push delivered while this pull was still on the wire.
            guard pullSequence.claimWrite(seq) else { return }
            self.lastVerdict = verdict
            WakeLog.shared.log("nightly-tests: pull failed: \(verdict.displayMessage)")
        }
    }

    // How the report we hold entered this store, for classify()'s absence x
    // cache rule. Read from the Grux-side stamped marker; the source string
    // is trusted only as a legacy fallback. The rule itself lives once at
    // PrivateServiceFetch.cacheProvenance(source:marker:), shared with
    // PRDigestStore.
    private var cacheProvenance: PrivateServiceFetch.CacheProvenance {
        PrivateServiceFetch.cacheProvenance(
            source: digest?.source,
            marker: UserDefaults.standard.string(forKey: Self.ingressDefaultsKey))
    }

    /// - Parameter supersedesInFlightPulls: true ONLY for a PUSH, which
    ///   carries no sequence of its own and is newer than anything already
    ///   on the wire. A pull's own apply must never supersede.
    private func apply(_ d: TestDigest, supersedesInFlightPulls: Bool = false) {
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

    private func persist(_ d: TestDigest) {
        if let data = try? JSONEncoder().encode(d) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        writeMarkdownMirror(d)
    }

    // Human + CLI readable mirror at ~/.grux/nightly-tests.md so a smoke test can
    // grep the result without parsing app state.
    private func writeMarkdownMirror(_ d: TestDigest) {
        var lines: [String] = []
        lines.append("# Nightly Empire Tests")
        lines.append("")
        lines.append("Generated: \(d.generatedAt) | \(d.passCount) pass / \(d.failCount) fail / \(d.skipCount) skip / \(d.errorCount) error across \(d.repoCount) repo\(d.repoCount == 1 ? "" : "s") | source: \(d.source)")
        lines.append("")
        lines.append(d.headline)
        lines.append("")
        // Failures first: the broken repos are the ones worth seeing.
        let order: [String: Int] = ["fail": 0, "error": 1, "skip": 2, "pass": 3]
        for r in d.results.sorted(by: { (order[$0.status] ?? 9) < (order[$1.status] ?? 9) }) {
            lines.append("## \(r.name) [\(r.status.uppercased())] | \(r.gitInfo)")
            for c in r.checks {
                lines.append("- \(c.kind): \(c.status) (\(Int(c.durationSec))s) | \(c.command)")
                if c.status != "pass", !c.summary.isEmpty, c.summary != "ok" {
                    lines.append("  \(c.summary.replacingOccurrences(of: "\n", with: "\n  "))")
                }
            }
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    }
}

enum TestDigestService {
    // Where the nightly service lives. EMPTY by default: the service is one the
    // user runs on their own machine, so there is no host worth guessing, and an
    // unconfigured install renders PrivateServiceNotice.nightlyTests instead of
    // hammering somebody else's LAN. Comma or newline separated, tried in order.
    //   defaults write com.gruxai.grux grux.services.testDigestBaseURLs "http://host:3855,http://localhost:3855"
    static let baseURLsDefaultsKey = "grux.services.testDigestBaseURLs"

    static var baseURLs: [String] {
        (UserDefaults.standard.string(forKey: baseURLsDefaultsKey) ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func fetchLatest() async throws -> TestDigest {
        // The failover rule lives once in PrivateServiceFetch: an unconfigured
        // install (empty defaults key) gets the notice, a configured host that
        // is down gets the technical form, and a 404 never aborts the
        // remaining bases. The per-attempt HTTP shape lives there too. ONE
        // read of the defaults key feeds both arguments, so the base list
        // and the flag cannot disagree mid-edit.
        let bases = baseURLs
        return try await PrivateServiceFetch.run(
            service: "nightly test service",
            bases: bases,
            userConfigured: !bases.isEmpty,
            absenceExplanation: PrivateServiceNotice.nightlyTests.explanation,
            unconfiguredDetail: "the defaults key \(baseURLsDefaultsKey) is not set",
            attempt: PrivateServiceFetch.jsonAttempt(
                TestDigest.self,
                path: "/api/tests/latest",
                notFoundMessage: "service has no report yet (404); run the nightly build"
            )
        )
    }
}
