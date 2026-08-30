import Foundation
import GruxShellCore
import SwiftUI

/// The treatment for a surface that reads from a companion HTTP service running
/// on the user's own machine.
///
/// WHY THIS EXISTS. Seven surfaces call private services on loopback ports 3847
/// to 3857. Those services are not in this download, they are not on anybody
/// else's machine, and every one of the seven rendered an empty list with no
/// explanation when nothing answered. A panel that looks finished and shows
/// nothing is the single worst thing a first run can do: a missing feature reads
/// as scope, and a feature that says "this needs a key" reads as honesty, but a
/// silent empty panel reads as a broken app.
///
/// WHY IT IS NOT `OperatorTool`, WHICH IT SITS BESIDE. That notice answers a
/// different question: Social, Meta Ads and Feature Review are somebody else's
/// TOOLING, empty because the business they are shaped around is not yours. This
/// answers "the service this panel talks to is not running here", which is a
/// state a machine can be measured for, and which can flip the moment somebody
/// starts one. So this one probes, and it disappears by itself when the service
/// answers.
///
/// WHY IT NO LONGER DEFERS TO THE CONTRACT, WHICH THE FIRST DRAFT DID. Two of
/// the seven have a frozen `endpoint.*` id, and the first draft treated each id
/// as the source of truth: `isConfigured` asked `CapabilityResolver` and the
/// copy quoted the id's own `remediation`. Both halves were measured false
/// against this repo. The ids' config keys, `grux.portfolio.registry_url` and
/// `grux.media.service_url`, have no writer anywhere in the app, so the
/// resolver could never say yes, the probe was skipped, and the notice sat over
/// a working panel for anybody configured the way the client code documents.
/// And both remediations send the reader to a Settings control that does not
/// exist. So `isConfigured` derives from the same base list the probe walks,
/// and the copy names each service's real config source instead of quoting an
/// instruction nobody can follow. The contract ids themselves are untouched:
/// repairing THEM is a frozen-contract change needing a dated change request,
/// and until one lands the honest move is to stop quoting them.
///
/// THE COPY IS WRITTEN ONCE, HERE. Seven panels sharing one voice is the whole
/// point of the type: seven hand written apologies drift into seven voices, and
/// the one thing every reader needs to hear is the same in all seven cases. The
/// shared paragraph carries exactly TWO variants, chosen by one measured fact
/// per service (does its client compile a loopback base in), because one of its
/// sentences is true for four of the services and false for the other three.
struct PrivateServiceNotice: Identifiable, Sendable {

    /// Stable slug. Also the reachability cache key, so two panels backed by the
    /// same host still get one entry each. That is deliberate: they ask
    /// different routes and either can be up while the other is not.
    let id: String

    /// What the surface calls the thing it is missing. Plain English, never a
    /// process name and never a port on its own.
    let label: String

    /// The loopback port the shipped client would try. Named in the copy because
    /// somebody who wants to write this service needs to know what to bind.
    let port: Int

    /// What this panel would show if the service were there, in the second
    /// person. This is the part that differs per surface and the reason a
    /// stranger keeps reading past the first line.
    let does: String

    /// The route the probe asks for. Chosen to be the cheapest read the service
    /// offers, never a write.
    let probePath: String

    /// One sentence naming where this install reads the service's hosts from:
    /// a file path or a defaults key, quoted from the client that reads it and
    /// nothing else. It exists because deleting the old thrown error strings
    /// also deleted the only in-app statement of how to configure these
    /// services, leaving somebody who runs one on another machine a port and
    /// no way to point Grux at it. Never a Settings pane: for these services
    /// no such pane exists, and naming one is exactly how the contract's
    /// remediations went wrong.
    let configSource: String

    /// The base URLs this install would actually try, read live rather than
    /// captured, so editing the config file takes effect without a relaunch.
    /// Empty is the shipped default for most of them and means nobody has
    /// pointed Grux at anything.
    let bases: @Sendable () -> [String]

    /// Whether the USER pointed this install at a host, read live from the one
    /// user-writable source the `configSource` sentence names and from nothing
    /// else, never counting a compiled-in loopback base. Deliberately NOT the
    /// probe-eligibility question `bases` answers: a client that always tries
    /// loopback is always worth probing, but only somebody who edited a config
    /// file has configured anything. This is the flag that decides who owns
    /// the surface when nothing answers. A configured host being silent is a
    /// real condition the section's technical banner reports, and this notice
    /// saying "absence is normal" beside that banner was a contradiction on
    /// one screen, so the view renders nothing at all when this is true.
    let userConfigured: @Sendable () -> Bool

    /// Whether the shipped client carries a compiled-in loopback base it tries
    /// on every install with no configuration at all. Chooses the shared
    /// paragraph variant: "Grux ships pointing at nobody's host" is false for
    /// a client that just knocked on this Mac's own port and heard nothing.
    let hasCompiledInBase: Bool

    // MARK: - Copy

    /// Deliberately not "Error", "Failed" or "Unavailable". Nothing is broken.
    /// `CapabilitySetupCard`'s header makes the same choice for the same reason.
    var headline: String { "Grux found no \(label) on this Mac" }

    /// The one paragraph every surface says, in the variant its client earns.
    ///
    /// It has to do three jobs in three sentences: say this is a separate thing
    /// that runs on your machine, say plainly that almost nobody runs one so the
    /// reader stops wondering whether they missed a step, and say that an empty
    /// panel is therefore the normal state. Leaving the second sentence out was
    /// the first draft and it read as an instruction, which is exactly the
    /// "you should have set this up" feeling the panel must not create.
    ///
    /// TWO VARIANTS, because the third job's evidence differs. A client that
    /// ships with no host really is pointing at nobody. But socialOps,
    /// brandsPoster and projectRegistry compile a loopback base in and try it
    /// on every install, so "Grux ships pointing at nobody's host" was false
    /// the moment it was written for them, and their own configSource sentence
    /// said so two sentences later. Their variant says what actually happened:
    /// Grux looked on this Mac and nothing answered, which is still the normal
    /// state for every install that is not the author's.
    static func sharedExplanation(hasCompiledInBase: Bool) -> String {
        hasCompiledInBase
            ? """
              This panel reads from a companion service you would run on your own \
              machine. It is not part of the Grux download and almost nobody runs \
              one; Grux looked for it on this Mac at the address the client ships \
              with, and nothing answered, so an empty panel here is the normal \
              state rather than a fault.
              """
            : """
              This panel reads from a companion service you would run on your own \
              machine. It is not part of the Grux download, almost nobody runs one, \
              and Grux ships pointing at nobody's host, so an empty panel here is \
              the normal state rather than a fault.
              """
    }

    /// The variant this service's explanation carries.
    var sharedExplanation: String {
        Self.sharedExplanation(hasCompiledInBase: hasCompiledInBase)
    }

    /// What the surface renders instead of an empty list. Never empty, and never
    /// a raw transport error.
    ///
    /// The close is the handover: the reader has the client already, so the
    /// missing half is a server, the port says what it must bind, and the
    /// config source says how to point Grux at wherever it runs.
    var explanation: String {
        [does, sharedExplanation,
         "Nothing needs fixing. If you want this filled, the service is yours to write: "
         + "Grux asks it for JSON over HTTP on port \(port), and the client that reads it "
         + "is in this repository. " + configSource,
        ].joined(separator: "\n\n")
    }

    // MARK: - The seven

    /// Projects reads its list from an orchestrator on 3847.
    ///
    /// `bases` mirrors `ProjectRegistryClient.candidateBases`: the hosts from
    /// ~/.grux/projects-service.json, then loopback, which the real client
    /// ALWAYS tries last. An earlier version read `configuredBases` alone,
    /// reasoning that a fallback that is always present would make every
    /// install look configured. That answered the wrong question: the probe's
    /// job is "is anything listening where the client will look", the client
    /// looks at loopback on every install, and skipping it put this notice
    /// beside a Projects tab populated from localhost:3847. A service with an
    /// always-present base is always worth probing.
    static let projectRegistry = PrivateServiceNotice(
        id: "registry",
        label: "project registry",
        port: 3847,
        does: "Projects lists what a registry tells it: every project you manage, its live health check, and whether it is running or paused.",
        probePath: "/api/projects",
        configSource: "Point Grux at a machine running one in ~/.grux/projects-service.json; Grux also always tries this Mac at http://localhost:3847.",
        bases: {
            var bases = ProjectRegistryClient.configuredBases
            if !bases.contains(ProjectRegistryClient.localhostBase) {
                bases.append(ProjectRegistryClient.localhostBase)
            }
            return bases
        },
        userConfigured: { !ProjectRegistryClient.configuredBases.isEmpty },
        hasCompiledInBase: true)

    /// Media Studio composes its brief through a wrapper on 3850, which then
    /// renders through the image service the config names.
    ///
    /// The wrapper address is loopback and compiled in, so `bases` reports the
    /// image service config instead: `grux.creative.imageServiceBaseURLs` is
    /// the key a person actually sets, documented at
    /// `CreativeEngine.imageBaseURLs`, and a hardcoded loopback address would
    /// report every install as configured. `isConfigured` reads the same list,
    /// which is the point: it used to ask the contract's `endpoint.media_service`
    /// capability, whose key `grux.media.service_url` nothing writes, so an
    /// install configured through the documented key was never probed and this
    /// notice claimed absence over a working panel.
    static let mediaService: PrivateServiceNotice = {
        // One read feeds both questions, through the client's own parser
        // (the configuredHosts precedent: one reader per config source), so
        // the probe list, the who-owns-the-surface flag, and the list the
        // engine actually walks cannot disagree.
        let bases: @Sendable () -> [String] = { CreativeEngine.imageBaseURLs }
        return PrivateServiceNotice(
            id: "media",
            label: "media service",
            // 3847, the render service this notice's bases and configSource
            // actually point at. It said 3850, which is the OPTIONAL local
            // brief wrapper CreativeEngine falls back from: a reader who
            // believed the card bound 3850, configured it, and then had every
            // real call (/api/images/render, /api/images/approve,
            // /api/posts/draft-from-image) hit a server with none of those
            // routes. One card names one service.
            port: 3847,
            does: "Media Studio renders brand images through an image service you run. Without one it can still compose the brief, but nothing is rendered.",
            probePath: "/healthz",
            configSource: "Point Grux at a machine running one in the defaults key grux.creative.imageServiceBaseURLs, a comma separated list of base URLs.",
            bases: bases,
            userConfigured: { !bases().isEmpty },
            hasCompiledInBase: false)
    }()

    static let pullRequestDigest = PrivateServiceNotice(
        id: "pr-digest",
        label: "pull request digest service",
        port: 3852,
        does: "This panel shows every open pull request across the repositories you track, collected once a night, oldest first.",
        probePath: "/api/digest/latest",
        configSource: "Point Grux at a machine running one in ~/.grux/pr-digest-hosts.txt, one base URL per line.",
        bases: { PRDigestService.baseURLs },
        userConfigured: { !PRDigestService.baseURLs.isEmpty },
        hasCompiledInBase: false)

    static let nightlyTests = PrivateServiceNotice(
        id: "test-digest",
        label: "nightly test service",
        port: 3855,
        does: "This panel shows last night's pull, typecheck and test run for every repository you track, worst result first.",
        probePath: "/api/tests/latest",
        configSource: "Point Grux at a machine running one in the defaults key grux.services.testDigestBaseURLs, a comma separated list of base URLs.",
        bases: { TestDigestService.baseURLs },
        userConfigured: { !TestDigestService.baseURLs.isEmpty },
        hasCompiledInBase: false)

    static let socialOps = PrivateServiceNotice(
        id: "social-ops",
        label: "social operations service",
        port: 3856,
        does: "This panel shows every account you post from and which of them wants a retry, a fresh sign in, or a look. Once it is running, Grux also sends you a digest once a day and once a week, which you can switch off underneath the grid.",
        probePath: "/api/social-ops/state",
        configSource: "Point Grux at a machine running one in ~/.grux/social-ops-hosts.txt, one base URL per line; Grux also always tries this Mac at http://localhost:3856.",
        bases: { SocialOpsService.baseURLs },
        // The one user-writable source is the hosts file, read through the
        // client's own parser so the two can never drift (the authHeaders()
        // precedent: one reader per ~/.grux file). Deliberately NOT counting
        // baseURLs, which always carries the compiled-in loopback entry.
        userConfigured: { !SocialOpsService.configuredHosts().isEmpty },
        hasCompiledInBase: true)

    /// Same host as `socialOps`, different route and different panel. Kept
    /// separate so each panel says what IT would show, which is the sentence
    /// that earns the reader's attention.
    static let brandsPoster = PrivateServiceNotice(
        id: "brands-poster",
        label: "posting service",
        port: 3856,
        does: "This panel shows the live posting engine: what each account posted today against its cadence, and whether anything is paused.",
        probePath: "/api/brands-poster/status",
        configSource: "Point Grux at a machine running one in ~/.grux/social-ops-hosts.txt, one base URL per line; it is the same companion on the same port, so one file serves both panels. Grux also always tries this Mac at http://localhost:3856.",
        bases: { BrandsPosterService.baseURLs },
        // The same hosts file socialOps reads, through the same parser: this
        // route and that one are the same companion on 3856, so a host
        // written once configures both. Deliberately NOT counting baseURLs,
        // which always carries the compiled-in loopback entry.
        userConfigured: { !SocialOpsService.configuredHosts().isEmpty },
        hasCompiledInBase: true)

    static let metaAds = PrivateServiceNotice(
        id: "meta-ads",
        label: "ads engine",
        port: 3857,
        does: "This panel drives live ad accounts: what each is spending, what the engine proposes next, and the switch that pauses all of it.",
        probePath: "/api/meta-ads/snapshot",
        configSource: "Point Grux at a machine running one in the defaults key grux.services.metaAdsBaseURLs, a comma separated list of base URLs.",
        bases: { MetaAdsService.baseURLs },
        userConfigured: { !MetaAdsService.baseURLs.isEmpty },
        hasCompiledInBase: false)

    /// Every notice. Walked by test, so a seventh added below is checked and a
    /// seventh NOT added here is caught from the other direction.
    static let all: [PrivateServiceNotice] = [
        projectRegistry, mediaService, pullRequestDigest,
        nightlyTests, socialOps, brandsPoster, metaAds,
    ]
}

/// The live probe and its budget, deliberately OUTSIDE the main actor class
/// below.
///
/// It has to be reachable from a detached task-group child, and a main-actor
/// isolated `URLSession` would mean every probe hops back to the main actor
/// just to read the object it is about to make a network call with. Keeping the
/// seam here also means a test can exercise the real probe without standing up
/// a reachability object at all.
enum PrivateServiceProbe {

    /// The hard ceiling on one probe. These are loopback services, so anything
    /// slower than this is already a failure from the reader's point of view.
    static let timeout: TimeInterval = 1.5

    /// One short lived session with both timeouts pinned, so a probe cannot
    /// inherit the sixty second default and sit on a panel.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = PrivateServiceProbe.timeout
        config.timeoutIntervalForResource = PrivateServiceProbe.timeout
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config)
    }()

    /// A GET, raced against a deadline.
    ///
    /// The race is belt and braces on purpose. `URLRequest.timeoutInterval` is a
    /// data-transfer idle timer, not a wall clock, so a server that dribbles a
    /// byte at a time can outlive it indefinitely. The task group gives a real
    /// ceiling that does not depend on the peer behaving.
    static let live: @Sendable (URL, TimeInterval) async -> Bool = { url, timeout in
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = timeout
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                guard let (_, response) = try? await PrivateServiceProbe.session.data(for: request)
                else { return false }
                return PrivateServiceProbe.provesListening(response)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Whether an answer proves a running service. ANY HTTP response does,
    /// whatever its status: a 404 from a build that moved the route and a 500
    /// from a handler that is up and unhappy are both something listening, and
    /// telling somebody their service is absent when it just replied is the
    /// same lie as telling them it is present when it is not. An earlier
    /// version said exactly that in a comment and then counted only statuses
    /// under 500, so a 404 proved presence and a 500 proved absence. Split
    /// from the transport so the claim is testable without binding a socket.
    static func provesListening(_ response: URLResponse) -> Bool {
        response is HTTPURLResponse
    }
}

/// Answers one question for a surface: is the service it needs reachable right
/// now, and if not, what should it show.
///
/// THREE RULES, and each closes a way this component could itself become the
/// defect it was written to fix.
///
/// **A probe never blocks a view and never throws.** Every path returns a Bool.
/// The probe races a hard deadline in a task group rather than trusting a
/// URLSession timeout, because a panel that hangs for thirty seconds deciding
/// whether to apologise is worse than the empty list it replaced. These are
/// loopback addresses: a closed port refuses in under a millisecond, so the
/// deadline only ever fires for somebody who configured a remote host that is
/// black holing, which is exactly the case worth bounding.
///
/// **An answer is cached.** Opening the Empire dashboard five times must not
/// fire five probes at three services each. An answer is trusted for
/// `reprobeInterval`, which is short enough that starting the service and
/// switching tabs clears the notice, and long enough that ordinary navigation
/// costs nothing.
///
/// **Unknown shows the notice.** Before any probe has answered, the honest
/// default is that the service is absent, because for everybody except its
/// author it is. Defaulting the other way would mean every first render of every
/// one of these panels shows an empty list for the length of a probe, which is
/// the exact frame this whole component exists to delete.
@MainActor
final class PrivateServiceReachability: ObservableObject {

    typealias Probe = @Sendable (URL, TimeInterval) async -> Bool

    static let shared = PrivateServiceReachability()

    /// How long an answer is trusted. One minute: long enough that clicking
    /// between tabs is free, short enough that somebody who just started the
    /// service does not have to relaunch Grux to see it noticed.
    static let reprobeInterval: TimeInterval = 60

    /// Bumped whenever an answer changes, so an observing view re-renders. The
    /// answers themselves are not `@Published` because a dictionary of tuples is
    /// not Equatable and would republish on every write.
    @Published private(set) var revision: Int = 0

    private let probe: Probe
    private let now: () -> Date
    private var answers: [String: (reachable: Bool, at: Date)] = [:]
    private var userConfiguredMemo: [String: (value: Bool, at: Date)] = [:]
    private var inFlight: Set<String> = []

    /// - Parameters:
    ///   - probe: the seam. Injected in tests because the live probe's answer on
    ///     any given machine depends on what that machine happens to be running,
    ///     so a test driven through it can only observe one desk's state.
    ///   - now: the clock, so the cache interval is checkable without waiting a
    ///     minute inside a test.
    init(probe: @escaping Probe = PrivateServiceProbe.live,
         now: @escaping () -> Date = Date.init) {
        self.probe = probe
        self.now = now
    }

    /// The cached answer, or nil when there is none or it has gone stale.
    func lastAnswer(for service: PrivateServiceNotice) -> Bool? {
        guard let answer = answers[service.id],
              now().timeIntervalSince(answer.at) < Self.reprobeInterval
        else { return nil }
        return answer.reachable
    }

    /// Is there anywhere at all for the probe to look.
    ///
    /// Derived from the same base list the probe walks, and from nothing else.
    /// This used to ask `CapabilityResolver` where the contract had an id, so
    /// the notice and the setup card could not disagree, but those ids' config
    /// keys have no writer in the app, so the resolver's no was permanent:
    /// configured the documented way, the probe was skipped and the notice sat
    /// over a working panel. One list now feeds both the probe and this
    /// answer, so they cannot split. A service whose client always carries a
    /// loopback base is therefore always probe-eligible, which is correct:
    /// the question its probe answers is whether anything is listening, not
    /// whether anybody edited a config file.
    func isConfigured(_ service: PrivateServiceNotice) -> Bool {
        !service.bases().isEmpty
    }

    /// `service.userConfigured()`, remembered on the same clock as the probe
    /// answers.
    ///
    /// WHY THIS EXISTS. `explanation(for:)` runs on every SwiftUI body
    /// evaluation, and for the file-backed services the closure is a
    /// synchronous read and parse of a ~/.grux file on the main actor. The
    /// shared revision counter re-renders every mounted card whenever ANY
    /// probe answers, so one answer used to mean a file read per card per
    /// render pass. The reprobe interval is the TTL, which keeps the
    /// semantics honest without a file watcher: an expired or missing memo
    /// re-reads the real source, so a user who writes the config file sees
    /// the change within one interval, the same promise the probe cache
    /// already makes.
    ///
    /// THIS READ NEVER PUBLISHES, even when the re-read value differs from
    /// the memo. It runs inside body evaluation, and bumping `revision`
    /// there is publishing during a view update, which SwiftUI forbids. The
    /// probe task's `reloadUserConfigured` below is the one publisher; keep
    /// every future caller on the right side of that line.
    func userConfigured(_ service: PrivateServiceNotice) -> Bool {
        if let memo = userConfiguredMemo[service.id],
           now().timeIntervalSince(memo.at) < Self.reprobeInterval {
            return memo.value
        }
        let value = service.userConfigured()
        userConfiguredMemo[service.id] = (value, now())
        return value
    }

    /// The probe task's read of `service.userConfigured()`: re-reads the
    /// real source, refreshes the memo, and PUBLISHES the flip by bumping
    /// `revision` when the answer changed, so a mounted card whose service
    /// just got configured re-renders and stands down instead of sitting
    /// stale until some other probe happens to publish. A solo-surface card
    /// (Media Studio has no sibling cards bumping the shared counter) could
    /// otherwise show absence copy over a configured service indefinitely.
    ///
    /// Publishing is legal here and ONLY here: this runs from the card's
    /// .task, between view updates, never inside body evaluation (see the
    /// constraint on `userConfigured(_:)` above).
    func reloadUserConfigured(_ service: PrivateServiceNotice) -> Bool {
        let value = service.userConfigured()
        let previous = userConfiguredMemo[service.id]?.value
        userConfiguredMemo[service.id] = (value, now())
        if let previous, previous != value { revision &+= 1 }
        return value
    }

    /// Probes unless a fresh answer is already held. Never throws.
    ///
    /// An unconfigured service is answered without touching the network. That is
    /// not an optimisation, it is the correct answer: there is no address to
    /// ask, so "unreachable" is known rather than measured.
    @discardableResult
    func refreshIfNeeded(_ service: PrivateServiceNotice) async -> Bool {
        if let cached = lastAnswer(for: service) { return cached }
        // A second caller arriving while the first is still waiting gets the
        // pending answer rather than a second probe. Five panels appearing in
        // one dashboard pass is the case this covers.
        guard !inFlight.contains(service.id) else {
            // ALWAYS false, and the code now says so. This read
            // `lastAnswer(for: service) ?? false`, which control cannot
            // reach with a non-nil answer: line one of this function already
            // returned when lastAnswer had one. So the "gets the pending
            // answer rather than a second probe" claim was never true, it
            // fabricated "unreachable" for a service that may be up, and a
            // second card mounted on the same id records previous = false
            // and skips its became-reachable fire for one reprobe interval.
            //
            // Left as a documented "not yet" rather than made to await the
            // in-flight probe, deliberately: the bound is one reprobe
            // interval and it self-corrects, where every hand-rolled
            // ordering mechanism in this wave has cost more than the race it
            // closed. If the 60s delay ever matters, the fix is for the
            // probe to publish its result to waiters, not for this caller to
            // guess.
            return false
        }
        inFlight.insert(service.id)
        defer { inFlight.remove(service.id) }

        var reachable = false
        if isConfigured(service) {
            for base in service.bases() {
                // Through the one join rule, because `provesListening` counts
                // ANY HTTP answer. A base pasted with a trailing slash
                // concatenated to "//healthz", strict routers 404 that, and
                // this probe read the 404 as a healthy service: the notice
                // stood down over a panel whose every real call was failing.
                guard let baseURL = URL(string: base),
                      let url = PrivateServiceFetch.join(baseURL, path: service.probePath)
                else { continue }
                if await probe(url, PrivateServiceProbe.timeout) { reachable = true; break }
            }
        }
        // A CANCELLED PROBE IS NOT A MEASUREMENT. PrivateServiceProbe.live
        // returns false on cancellation (the try? swallows URLError.cancelled
        // and the deadline racer's sleep returns immediately), so recording
        // here cached "unreachable" with a fresh timestamp whenever a card
        // unmounted mid-probe: switching tabs while a slow configured host
        // was being probed left the absence card rendering for a full
        // reprobe interval over a service that is up. The same rule pullOnce,
        // classify and runCommand all state: no verdict from a teardown.
        guard !Task.isCancelled else { return false }
        record(service, reachable: reachable)
        return reachable
    }

    /// What the surface should show. nil means say nothing: either the service
    /// answered and the real content renders, or the user configured a host
    /// and the section's technical banner owns whatever is wrong with it.
    ///
    /// THE GUARD THAT MAKES THE OTHERS MEAN ANYTHING: this returns nil on a
    /// reachable service. A notice that is always shown is indistinguishable
    /// from a notice that works, and it would put an apology over a working
    /// panel, which is the same defect as the empty list running the other way.
    ///
    /// THE SECOND nil IS THE CONFIGURED-BUT-DOWN FIX. The fetch layer already
    /// told these apart (a configured host that is down throws the technical
    /// form, never the notice), but this layer keyed on reachability alone, so
    /// the section rendered its technical banner AND this card claimed absence
    /// beside it. One surface has one owner: when the user configured a host,
    /// the card stands down whatever the probe says.
    func explanation(for service: PrivateServiceNotice) -> String? {
        if userConfigured(service) { return nil }
        return lastAnswer(for: service) == true ? nil : service.explanation
    }

    private func record(_ service: PrivateServiceNotice, reachable: Bool) {
        // Bumped only when the ANSWER changes, which is what the field's doc
        // promises. It was bumped on every probe RESULT, so five mounted
        // cards each looping on a 60s timer republished this @Published
        // singleton about five times a minute with nothing changed,
        // re-rendering every observer and re-running explanation(for:),
        // which reads ~/.grux config files. The timestamp still refreshes,
        // because freshness is what lastAnswer's reprobe window reads.
        let changed = answers[service.id]?.reachable != reachable
        answers[service.id] = (reachable, now())
        if changed { revision &+= 1 }
    }
}

/// The rendered treatment. Replaces the panel's content rather than floating
/// over it, for the reason `OperatorToolNoticeView` gives: there is nothing
/// behind to see, and dimming an empty pane teaches nobody anything.
///
/// MOUNTED in five places: `PRDigestSection`, `TestDigestSection`,
/// `SocialOpsSection` and `BrandsPostingSection` render it where their list
/// would be, and `CreativeStudioView` renders it as Media Studio's engine
/// status. That list is prose and prose rots, so do not trust it over the
/// tree: `grep -rn "PrivateServiceNoticeView(" Grux-Mac/Sources` is the
/// authoritative answer, and a mount added without an `onBecameReachable`
/// closure should say why, because a card that hides itself without
/// re-asking its store leaves the panel blank right after the service heals.
/// The remaining surfaces still reach a reader through their client's thrown
/// message alone. Four rules the mounts rely on:
///
/// USER-CONFIGURED RENDERS NOTHING. A host somebody pointed Grux at being
/// silent is a real condition, the section's technical banner reports it, and
/// this card standing beside that banner saying "absence is the normal state"
/// was a contradiction on one screen. The rule lives in
/// `PrivateServiceReachability.explanation(for:)`, the seam this view reads,
/// so it is asserted there rather than through SwiftUI.
///
/// A MOUNTED CARD KEEPS PROBING. One probe on appear used to be all of it: the
/// sixty second cache expired and nothing ever asked again, so a card claiming
/// no service exists on this Mac could sit over a service started minutes ago
/// until the panel happened to be remounted. The task loops on the reprobe
/// interval instead, and unmounting cancels it. An unconfigured service still
/// costs nothing, because `refreshIfNeeded` answers it without touching the
/// network.
///
/// REACHABLE AGAIN RE-PULLS THE STORE. When the loop's probe finds the
/// service up, this card hides itself, but hiding is only half of the
/// recovery: nothing re-asked the store whose empty answer mounted the card,
/// so the panel sat blank until a manual refresh, which reads as a second
/// defect right after the first one healed. `onBecameReachable` closes that
/// window, and the sections pass their store's refresh.
///
/// A MOUNT NEVER KEYS ON THE STORE'S isFetching. The closure above IS the
/// store's refresh, so the awaited recovery pull raises isFetching, and a
/// mount condition carrying `!store.isFetching` unmounts this card the
/// moment its own recovery starts, cancelling that pull from inside itself:
/// a mount/cancel loop in which the recovery rarely completes. The absence
/// copy stays true while the pull runs, and success clears the store's flag,
/// which unmounts the card cleanly.
struct PrivateServiceNoticeView: View {

    let service: PrivateServiceNotice

    /// Fired once per unreachable-to-reachable transition this card's own
    /// probe loop observes, including a first probe that finds the service up
    /// when the card only mounted because the owning store's flag was stale.
    /// A true answer while the previous answer was already true fires
    /// nothing: the loop keeps probing a live service, and re-pulling the
    /// store once a minute for no state change would be a refresh storm
    /// wearing a recovery's clothes. ALSO fired once when the loop exits
    /// because the service became user-configured: the card told the reader
    /// to configure it, they did, and the store whose empty answer mounted
    /// the card is still holding that answer with nothing else to re-ask it.
    let onBecameReachable: (() async -> Void)?

    @ObservedObject private var reachability = PrivateServiceReachability.shared

    init(service: PrivateServiceNotice,
         onBecameReachable: (() async -> Void)? = nil) {
        self.service = service
        self.onBecameReachable = onBecameReachable
    }

    var body: some View {
        Group {
            if let explanation = reachability.explanation(for: service) {
                card(explanation)
            } else {
                // NEVER AN EMPTY PANE. explanation() returns nil the moment
                // userConfigured flips true, which is exactly what happens
                // when a reader FOLLOWS this card's instructions: they write
                // the config file, the next probe sees it, the card body goes
                // blank, and the section (which took this branch on the
                // store's still-standing absence verdict) draws a header, a
                // refresh button and nothing else until a new verdict lands,
                // up to 12s per base later. The reward for doing as asked was
                // the blank panel this wave exists to remove.
                Text("Waiting for the \(service.label) to answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await Self.probeLoop(service: service,
                                 reachability: reachability,
                                 onBecameReachable: onBecameReachable)
        }
    }

    /// The mounted card's probe loop, a static seam so both exit paths are
    /// testable without SwiftUI. Two ways out, each with an obligation:
    /// CANCELLATION (the card unmounted) exits firing nothing, and the
    /// service becoming USER-CONFIGURED (the reader did what the card said)
    /// fires `onBecameReachable` once on the way out, because the loop used
    /// to exit that arm with NOTHING after it, so configuring the service
    /// the card asked for triggered no refresh and the panel sat on its
    /// stale empty answer. `reloadUserConfigured` also publishes the flip,
    /// so the card's body re-renders and the card stands down.
    @MainActor
    static func probeLoop(service: PrivateServiceNotice,
                          reachability: PrivateServiceReachability,
                          onBecameReachable: (() async -> Void)?) async {
        // nil until this mount's first answer lands, so a first-pass true
        // still counts as a transition: the only reason the card mounted
        // is that some store believed the service absent, and that belief
        // is exactly what the closure exists to correct.
        var previous: Bool? = nil
        while !Task.isCancelled, !reachability.reloadUserConfigured(service) {
            let reachable = await reachability.refreshIfNeeded(service)
            if reachable, previous != true {
                await onBecameReachable?()
            }
            previous = reachable
            try? await Task.sleep(
                nanoseconds: UInt64(PrivateServiceReachability.reprobeInterval * 1_000_000_000))
        }
        if !Task.isCancelled {
            await onBecameReachable?()
        }
    }

    private func card(_ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            HStack(spacing: GruxSpacing.s) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GruxTheme.textTertiary)
                Text(service.headline)
                    .font(GruxType.body.weight(.semibold))
                    .foregroundStyle(GruxTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(explanation)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(GruxSpacing.m)
        .background(RoundedRectangle(cornerRadius: 8).fill(GruxTheme.base.opacity(0.35)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(GruxTheme.textTertiary.opacity(0.18), lineWidth: 1)
        )
    }
}
