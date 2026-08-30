import Foundation

/// The one host-failover loop behind every companion-service client.
///
/// WHY THIS EXISTS. Five clients (PR digest, nightly tests, social ops, brands
/// poster, meta ads) each hand-copied the same try-each-base loop, and the
/// copies had already forked: one aborted failover on a 404, and every one of
/// them answered a configured host being DOWN with the "almost nobody runs one,
/// an empty panel is normal" absence notice, which is a lie to the one person
/// who did configure a host. The rule lives here once so it cannot fork again.
///
/// THE RULE. Each base produces one of three outcomes:
///   - success: return it immediately, remaining bases untried.
///   - answered: the service replied over HTTP, even with an error status or a
///     body Grux could not read. A service that exists and answered badly is a
///     fault worth naming, so after the loop its own message is thrown. A 404
///     that means "nothing published yet" is an answered outcome too: it is
///     recorded and the REMAINING bases still get tried, because one host
///     having no digest says nothing about the next.
///   - transport: nothing answered at this base (refused, timeout, no route).
///
/// When every base failed at the transport level, what to say depends on who
/// pointed Grux there. A host the USER configured being silent is a real
/// condition they can act on, so it gets the technical form naming each base
/// and its reason. Only when nobody configured anything does the absence
/// notice stand, because only then is an empty panel the normal state. Both
/// terminal messages are thrown as `Failure` with a typed kind, so a call
/// site routing them never matches on the prose.
///
/// COMMANDS NEVER GET THE NOTICE. A read that finds nothing is normal; a
/// command (kill switch, pause, veto, post) that went nowhere is not, whatever
/// the config state. Command call sites pass `absenceExplanation: nil` and
/// always get the technical form naming what was attempted.
enum PrivateServiceFetch {

    /// What one attempt against one base produced.
    enum Outcome<T> {
        case success(T)
        /// The service replied over HTTP. Carries the call site's own error so
        /// the thrown type and message survive the loop unchanged.
        case answered(Error)
        /// Nothing answered. Carries the per-base reason (a URLError
        /// description) for the configured-and-down message.
        case transport(String)
    }

    /// Which of the loop's two terminal messages was thrown. Call sites used
    /// to tell them apart by string-equality against the three-paragraph
    /// absence notice, at ten separate places, which is the kind of check
    /// that breaks the day the copy grows a second variant. It did. The kind
    /// is the discriminator; the message stays the whole user-facing text.
    enum FailureKind { case absence, hostsDown }

    struct Failure: LocalizedError {
        let kind: FailureKind
        let message: String
        /// The technical per-base composition, the same sentence the
        /// .hostsDown form carries as its whole message, carried on the
        /// .absence kind too. It exists because absence is a verdict about
        /// CONFIG, not about the cache a store may be holding: when a host
        /// this machine once pulled from stops answering, `classify` below
        /// turns the absence throw into an outage, and the message it
        /// surfaces then must be this transport account, never the "nothing
        /// needs fixing" prose in `message`. Failure is never persisted, so
        /// the field needs no decoder tolerance.
        var transportDetail: String? = nil
        var errorDescription: String? { message }
    }

    /// How the payload a store is holding got there. The absence x cache rule
    /// in `classify` branches on it: a cache PULLED from a host proves that
    /// host once answered this machine, a cache fed by the companion's push
    /// channel proves nothing about any pull host, and an empty cache proves
    /// nothing at all.
    enum CacheProvenance { case empty, pullProven, pushFed }

    /// The marker-over-source provenance rule the two digest stores share.
    /// The marker is the authority: only a store's refresh() adoption
    /// ("pull") and its ingest() ("push") write it, so it is a fact about
    /// what THIS machine did, where the payload's source field is the
    /// sender's own display string end to end (a replayed Grux-persisted
    /// digest genuinely carrying "grux-pull", pushed from elsewhere, would
    /// otherwise mark a never-pulled cache pull-proven). The source
    /// heuristic is trusted ONLY for migration of a cache persisted by a
    /// build that predates the marker, because on that build the adopted
    /// pulls really did stamp "grux-pull" themselves. Pure, so the rule is
    /// provable without any singleton's disk writes; it lived as
    /// byte-identical statics on both stores until the copies were one
    /// edit from diverging.
    static func cacheProvenance(source: String?, marker: String?) -> CacheProvenance {
        guard let source else { return .empty }
        switch marker {
        case "pull": return .pullProven
        case "push": return .pushFed
        default: return source == "grux-pull" ? .pullProven : .pushFed
        }
    }

    /// Whether a pull answer that did NOT adopt should upgrade the ingress
    /// marker from push to pull. The two digest stores share it for the
    /// reason `cacheProvenance` above is shared: the block was byte-identical
    /// on both, and this is the second time it needed correcting in two
    /// places at once.
    ///
    /// EQUAL EPOCH ONLY. The upgrade's whole claim is that the host answering
    /// this pull is the host that supplied the payload being held, which is
    /// true when the answer IS that payload and false when it is older. A
    /// mirror serving a stale digest proves it is alive and proves nothing
    /// about provenance, so stamping "pull" on its answer would let it vouch
    /// for data it never sent. It was gated on the same `<=` as the reject
    /// rule, which is one comparison doing two unrelated jobs.
    ///
    /// A MISSING MARKER COUNTS AS PUSH-FED, through `cacheProvenance` rather
    /// than a second reading of the same question. A cache persisted by a
    /// build that predates the marker has none to read, and keying on the
    /// literal "push" left exactly those installs never upgrading, which is
    /// the silence-over-rotting-data hole this upgrade exists to close: pull
    /// absence over a cache classified push-fed is the NORMAL state, so the
    /// day the companion dies those installs say nothing at all.
    static func upgradesIngressToPull(freshEpoch: Double, heldEpoch: Double,
                                      cache: CacheProvenance) -> Bool {
        freshEpoch == heldEpoch && cache == .pushFed
    }

    /// One completed pull failure resolved into the three fields every store
    /// publishes. `displayMessage` is what lastError holds, and it is never
    /// the raw localizedDescription when a classification exists, so the
    /// reclassified rows below cannot leak the wrong prose.
    struct Classification: Equatable {
        let isAbsence: Bool
        let servingStale: Bool
        let displayMessage: String

        /// Which flag survives the pair the banners assume impossible.
        ///
        /// STALE WINS AND ABSENCE DROPS, because the two mistakes are not
        /// symmetric. Absence renders the "almost nobody runs one, an empty
        /// panel is normal" card, so keeping it over a failed pull is the
        /// nothing-needs-fixing lie this whole file exists to end. Dropping
        /// it degrades to a fault named technically over a stale cache,
        /// which is exactly what the (.absence, .pullProven) row already
        /// resolves to and is honest in every cell.
        ///
        /// Pure and separate from the init so the release behaviour is
        /// provable in a test without tripping the debug trap below.
        static func absenceSurvives(isAbsence: Bool, servingStale: Bool) -> Bool {
            isAbsence && !servingStale
        }

        /// The message that survives with it, and dropping the FLAG alone was
        /// only half the resolution. A verdict carrying absence copy renders
        /// its three-paragraph "almost nobody runs one, an empty panel is
        /// normal" prose inside the stale banner as "Showing cached digest.
        /// Last pull failed: <nothing needs fixing>", which is the exact
        /// mislabel the flag drop was meant to prevent, one surface over.
        /// So the conflict swaps the prose for the technical sentence the
        /// (.absence, .pullProven) row already falls back to.
        static func resolvedMessage(isAbsence: Bool, servingStale: Bool,
                                    displayMessage: String) -> String {
            (isAbsence && servingStale) ? conflictFallbackMessage : displayMessage
        }

        /// Deliberately the same sentence `classify`'s pull-proven absence row
        /// falls back to: both are "a verdict exists, the prose that came with
        /// it cannot be trusted here, say the honest technical thing".
        static let conflictFallbackMessage = "the last pull could not reach any host"

        init(isAbsence: Bool, servingStale: Bool, displayMessage: String) {
            // Absence and stale are disjoint by classify()'s table: its two
            // absence rows are the empty-cache and push-fed ones, and both
            // pin servingStale false. The four sections' stale banners
            // render with no absence arm on the strength of that, so the
            // invariant is trapped where the table lives, not re-argued at
            // each banner. The day the table needs an absence-and-stale
            // row, this fires and the four banners must be revisited.
            //
            // A TRAP, NOT AN ABORT. This was a `precondition`, which stays
            // live under -O, so a future edit to the table above would have
            // taken the app down on a failed network pull rather than shown
            // a wrong caption. The whole table is already swept for the
            // pair by PrivateServiceFetchTests, so the debug trap is what
            // catches the edit, and release resolves the conflict toward
            // the fault instead of dying beside it. A crash is not a safer
            // wrong answer than a banner.
            assert(!(isAbsence && servingStale),
                   "a verdict classified as absence AND stale, which the section banners assume impossible")
            self.isAbsence = Self.absenceSurvives(isAbsence: isAbsence, servingStale: servingStale)
            self.servingStale = servingStale
            self.displayMessage = Self.resolvedMessage(
                isAbsence: isAbsence, servingStale: servingStale, displayMessage: displayMessage)
        }
    }

    /// Start-order guard for a store that can have TWO pulls in flight.
    ///
    /// WHY TWO. A command needs a read that STARTED AFTER its write, and the
    /// coalescing gate cannot give it one: `refresh()` returns instantly when
    /// a pass is already running, and that pass may have begun before the
    /// write landed. So the command paths call the pass body directly,
    /// outside the gate, which means a command pull and the store's poll pull
    /// can be on the wire at the same time.
    ///
    /// WHY THE MAINACTOR IS NOT ENOUGH. It orders the WRITES, not the network
    /// waits. A poll that started first and finished last therefore
    /// overwrote the fresher post-command snapshot, and a poll that FAILED
    /// stamped an error verdict over data that had just arrived intact.
    ///
    /// THE RULE. A pull may write only if no pull that started LATER has
    /// already written. Start order, not finish order, because start order is
    /// what "fresher" means for a request whose answer describes a moment.
    struct PullSequence {
        private var started: UInt64 = 0
        private var written: UInt64 = 0

        /// Call once when a pull begins; hold the result until it finishes.
        mutating func begin() -> UInt64 {
            started &+= 1
            return started
        }

        /// True exactly once per pull, and only while it is still the
        /// freshest to have come back. A false answer means a later pull
        /// already published, so this one is stale on arrival and must
        /// write NOTHING, verdict included.
        mutating func claimWrite(_ seq: UInt64) -> Bool {
            guard seq > written else { return false }
            written = seq
            return true
        }

        /// Retires every pull currently in flight, for a write that did not
        /// come from a pull at all.
        ///
        /// A COMMAND ECHO IS NEWER THAN ANY PULL ALREADY ON THE WIRE. The
        /// engine answered the command with post-command state, so a poll
        /// that started before the command describes a moment that no
        /// longer exists. Guarding only `claimWrite` left exactly this hole:
        /// the echo published without advancing the counter, so the older
        /// poll's response still claimed its write and reverted the UI to
        /// the pre-command value.
        mutating func supersedeInFlight() {
            written = started
        }
    }

    /// The cell all four section if-chains left with no arm.
    ///
    /// They branched payload / stale-banner / absence-card and nothing else,
    /// on the assumption that a section with no payload always holds a
    /// verdict explaining why. `pullOnce`'s cancellation path makes that
    /// false ON PURPOSE: a section unmounted mid-pull records NOTHING, which
    /// is what stops a torn-down request fabricating an absence. So the pane
    /// drew a header, a refresh button, and empty space: the blank panel this
    /// whole wave exists to remove. It self-heals on the next onAppear, which
    /// is the only reason it is not worse.
    ///
    /// Lives here rather than as a fifth hand-written `store.lastVerdict ==
    /// nil` so the four-way partition can be proven TOTAL in one test.
    static func awaitingFirstPull(hasPayload: Bool, verdict: Classification?) -> Bool {
        !hasPayload && verdict == nil
    }

    /// The one home of the absence x cache decision. The typed Failure kind
    /// centralized the cast but left every store to derive its own
    /// flag/stale/message triple by hand; five did, in two shapes that had
    /// already diverged inside one commit, and the divergence produced a
    /// confirmed mislabel. The whole table now lives here:
    ///
    ///   .hostsDown, any cache: a configured host is down. Not absence,
    ///     stale exactly when a cache exists, the technical message stands.
    ///   .absence, .empty: nothing configured and nothing held. The one
    ///     true absence: the explanation prose stands.
    ///   .absence, .pullProven: a host this machine once PULLED from no
    ///     longer answers. That is an OUTAGE wearing absence's config
    ///     verdict, so the flag drops, the cache is stale, and the message
    ///     is the transport detail, never the "nothing needs fixing" prose,
    ///     which an earlier gate left rendering inside fault banners.
    ///   .absence, .pushFed: pull absence over push-fed data is the normal
    ///     state (the companion feeds the store with no pull host
    ///     configured), so absence stands and the sections render silence
    ///     over live data.
    ///   any non-Failure error: an answered fault or a decode error. Its
    ///     own message stands, stale exactly when a cache exists.
    ///
    /// nil means CANCELLATION: the caller's task was torn down mid-request,
    /// so there is no verdict and the store must write NOTHING. Recording a
    /// cancelled attempt is how a card unmounting mid-recovery fabricated an
    /// absence verdict on a singleton store.
    static func classify(_ error: Error, cache: CacheProvenance) -> Classification? {
        if error is CancellationError { return nil }
        if let urlError = error as? URLError, urlError.code == .cancelled { return nil }
        guard let failure = error as? Failure else {
            return Classification(isAbsence: false, servingStale: cache != .empty,
                                  displayMessage: error.localizedDescription)
        }
        switch (failure.kind, cache) {
        case (.hostsDown, _):
            return Classification(isAbsence: false, servingStale: cache != .empty,
                                  displayMessage: failure.message)
        case (.absence, .empty), (.absence, .pushFed):
            return Classification(isAbsence: true, servingStale: false,
                                  displayMessage: failure.message)
        case (.absence, .pullProven):
            // run() always populates transportDetail on the absence throw;
            // the fallback exists for hand-built Failures and stays
            // technical, because rendering the absence prose here is the
            // exact mislabel this row removes.
            return Classification(isAbsence: false, servingStale: true,
                                  displayMessage: failure.transportDetail
                                      ?? "the last pull could not reach any host")
        }
    }

    /// A service answered over HTTP with something other than a usable value:
    /// a non-2xx status, a body that would not decode, or no HTTP framing at
    /// all. Distinct from `Failure` because an answered fault is one host's
    /// own story, and it outranks both of the loop's terminal messages.
    struct AnsweredError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Tries `bases` in precedence order.
    ///
    /// - Parameters:
    ///   - service: what the technical message calls the thing, e.g.
    ///     "pull request digest service". Command sites append what was
    ///     attempted, because "the command was not delivered" has to say which.
    ///   - userConfigured: true only when the user pointed Grux somewhere, with
    ///     compiled-in loopback defaults excluded. Read from the service's real
    ///     config source at the call site, never assumed.
    ///   - absenceExplanation: the PrivateServiceNotice text to throw when
    ///     nothing is configured and nothing answered. nil on command paths,
    ///     which must never claim a failed command is normal.
    ///   - unconfiguredDetail: what the zero-bases technical detail says in
    ///     place of the generic "no host is configured to send it to". The
    ///     services whose whole config is one defaults key pass a sentence
    ///     naming that key, so the message a warm-cache reclassification
    ///     surfaces (a user who removed their key over a cached payload) is
    ///     actionable rather than a shrug.
    ///   - attempt: one request against one base. Owns the URL, headers, auth
    ///     and decode; classifies its own result. A thrown error aborts the
    ///     whole loop, which is how the overload below rethrows cancellation.
    static func run<T>(
        service: String,
        bases: [String],
        userConfigured: Bool,
        absenceExplanation: String?,
        unconfiguredDetail: String? = nil,
        attempt: (String) async throws -> Outcome<T>
    ) async throws -> T {
        // The first ANSWERED outcome wins the right to speak: bases are in
        // precedence order, so the highest-precedence host that actually
        // replied is the authoritative account of what is wrong.
        var answered: Error?
        var transports: [(base: String, reason: String)] = []
        for base in bases {
            switch try await attempt(base) {
            case .success(let value):
                return value
            case .answered(let error):
                if answered == nil { answered = error }
            case .transport(let reason):
                transports.append((base, reason))
            }
        }
        if let answered { throw answered }
        // Composed for BOTH terminal throws: the hostsDown message IS this
        // detail, and the absence throw carries it as transportDetail so
        // classify() can surface a technical account when a warm pull cache
        // reclassifies absence into an outage.
        let detail = transports.isEmpty
            ? (unconfiguredDetail ?? "no host is configured to send it to")
            : transports.map { "could not reach \($0.base): \($0.reason)" }
                .joined(separator: "; ")
        if let absenceExplanation, !userConfigured {
            throw Failure(kind: .absence, message: absenceExplanation,
                          transportDetail: "\(service): \(detail)")
        }
        throw Failure(kind: .hostsDown, message: "\(service): \(detail)")
    }

    /// The same loop over an attempt that THROWS instead of classifying its
    /// own result. The classification lives here once: cancellation is
    /// rethrown as CancellationError, because a torn-down caller is not a
    /// verdict about any host; any other URLError is transport, because
    /// nothing answered; anything else the attempt throws is an answered
    /// fault, because only a service that replied can produce one; a
    /// returned value is success. Exists so `jsonAttempt` below can stay a
    /// plain throwing closure rather than every call site repeating these
    /// catch arms.
    static func run<T>(
        service: String,
        bases: [String],
        userConfigured: Bool,
        absenceExplanation: String?,
        unconfiguredDetail: String? = nil,
        attempt: (URL) async throws -> T
    ) async throws -> T {
        try await run(service: service, bases: bases, userConfigured: userConfigured,
                      absenceExplanation: absenceExplanation,
                      unconfiguredDetail: unconfiguredDetail) { base -> Outcome<T> in
            guard let url = URL(string: base) else {
                return .transport("not a valid base URL")
            }
            do {
                return .success(try await attempt(url))
            } catch is CancellationError {
                // Aborts the loop with nothing recorded. Classifying a
                // cancelled request as transport is how a cancelled recovery
                // pull once ran the remaining bases (each instantly
                // cancelled) and fabricated an absence throw for the store
                // that awaited it.
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError {
                return .transport(error.localizedDescription)
            } catch {
                return .answered(error)
            }
        }
    }

    /// Joins a base URL and a route path (which always starts with "/").
    /// The naive string concat produced "http://host//api/..." for a
    /// trailing-slash base, and strict routers 404 that path, converting a
    /// healthy service into the notFoundMessage diagnosis, so the trailing
    /// slash is trimmed before the concat.
    static func join(_ base: URL, path: String) -> URL? {
        var trimmed = base.absoluteString
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return URL(string: trimmed + path)
    }

    /// One JSON request against one base: the attempt body every client used
    /// to paste. Seven copies existed and had already forked on 404 handling
    /// and on the noun in their could-not-read message, so this is the one
    /// shape, kept to the strongest form the copies had: name the base and
    /// the status, keep the call site's own 404 sentence where it has one,
    /// and let a URLError fly untouched for `run` above to classify as
    /// transport.
    ///
    /// - Parameters:
    ///   - notFoundMessage: what a 404 means at THIS route, e.g. "service has
    ///     no digest yet (404); run the nightly build". nil means a 404 is
    ///     just another non-2xx status.
    ///   - headers: extra header fields for THIS base, applied last so they
    ///     win. A function of the base rather than a fixed dictionary
    ///     because the bearer-token clients (social ops, brands poster) are
    ///     why this exists and their secret is not sendable to every base:
    ///     the loop walks a whole precedence list, so a dictionary computed
    ///     once is a credential attached to hosts the caller never decided
    ///     to trust. The decision lives at the call site, per base.
    static func jsonAttempt<T: Decodable>(
        _ type: T.Type,
        path: String,
        method: String = "GET",
        body: Data? = nil,
        timeout: TimeInterval = 12,
        notFoundMessage: String? = nil,
        headers: @escaping @Sendable (URL) -> [String: String] = { _ in [:] }
    ) -> @Sendable (URL) async throws -> T {
        { base in
            guard let url = join(base, path: path) else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let body {
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            for (field, value) in headers(base) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AnsweredError(message: "no HTTP response from \(base.absoluteString)")
            }
            if http.statusCode == 404, let notFoundMessage {
                throw AnsweredError(message: notFoundMessage)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw AnsweredError(message: "\(base.absoluteString) returned HTTP \(http.statusCode)")
            }
            do {
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                throw AnsweredError(message: "\(base.absoluteString) answered with a body "
                    + "Grux could not read: \(error.localizedDescription)")
            }
        }
    }
}

/// The one coalescing gate behind every store's refresh(). Five stores
/// hand-copied the in-flight check, the pending flag and the
/// repeat-until-clean loop, and every copy shared the same hole: the pass's
/// cancellation exits left a pending request with nothing to consume it.
///
/// THE RULE. In flight means COALESCE, never drop. The old guard-return
/// silently consumed a caller's request, and the absence card's recovery
/// fires are ONE-SHOT (probeLoop fires once per transition), so a fire
/// landing mid-pull evaporated and nothing ever re-fired: the card stood
/// down while the panel sat on its stale answer. One Bool folds any number
/// of requests during one pass into exactly one follow-up pass. Never a
/// queue: N requests during one pass owe one pass.
///
/// THE RESCUE. The pass runs inside whatever task awaited refresh(), and
/// for a mounted card that is a structured .task the view cancels on
/// unmount. A pass exiting under that cancellation used to take the pending
/// flag down with it, so a sibling caller's coalesced request (a poll tick,
/// a second card, a manual refresh) died inside a teardown it never joined
/// and the panel sat on its stale answer with nobody left to re-ask. When
/// the loop exits cancelled owing a pass, the follow-up is handed to a fresh
/// unstructured task, so a cancelled awaiter cannot swallow another caller's
/// request.
///
/// TWO INVARIANTS, and together they are the whole point of the class.
/// NO CALLER'S REQUEST IS DROPPED: every request either starts the loop, is
/// consumed by a later iteration of it, or is still pending when a cancelled
/// loop exits and is handed to the rescue. NO PASS RUNS THAT NOBODY IS OWED:
/// `pending` is cleared only immediately before the pass that serves it, and
/// nothing else clears it, so the number of passes can never exceed the
/// number of requests.
///
/// THE ARM THAT CAME OFF. A second rescue arm used to fire when the loop
/// exited cancelled after a COALESCED pass, on the theory that the pass had
/// been abandoned mid-flight. It could not tell that from a coalesced pass
/// that FINISHED and was cancelled afterwards: `pass` is a plain
/// non-throwing closure, so whether it did its work or returned early is not
/// something this class can observe, and the arm read `Task.isCancelled`
/// after the loop, later still than the pass's own return. The notice card
/// is the shape that made the guess wrong. Its .task calls refresh(), the
/// successful pass clears lastErrorIsAbsence, the card unmounts and cancels,
/// and the gate answered a request that had just been served in full with a
/// whole extra HTTP pull, isFetching held true across it on a singleton
/// seven views observe. Guessing that way costs all seven a spinner for a
/// request nobody made; guessing the other way costs one stale panel until
/// the next poll tick. So a pass that STARTED for a request settles it,
/// cancelled or not, and only a request no pass ever started for is owed
/// the rescue.
@MainActor
final class RefreshGate {
    private var inFlight = false
    private var pending = false
    // Counts passes that have STARTED. The rescue captures it and runs only
    // if it has not moved, which is how it tells "my owed request is still
    // owed" from "a competitor already served it". Without that it could only
    // see `inFlight`, so a caller arriving in the gap served the request and
    // the rescue then ran a redundant pass regardless.
    private var passCount: UInt64 = 0

    // Nonisolated so the stores can default-construct one in a stored
    // property initializer; it assigns two Bools and touches no state.
    nonisolated init() {}

    /// Runs `pass` until no request is left pending. `isFetching` is the
    /// seam that keeps each store's own @Published flag truthful: it is
    /// called with true before the first pass and false after the last one
    /// this awaiter runs, and the rescue task brackets its follow-up the
    /// same way, so the flag never reads false while a pass is in flight.
    ///
    /// THE FLAG SURVIVES THE HANDOFF. It used to drop to false before the
    /// rescue task was even enqueued, so seven UI sites watched the spinner
    /// vanish and Refresh re-enable in the window between one pass ending
    /// and its owed follow-up starting, which is the opposite of what the
    /// paragraph above promises. It is now lowered ONLY when no pass is
    /// owed; when one is, it stays true and the rescue's own bracket owns
    /// it from there.
    func run(isFetching: @escaping @MainActor (Bool) -> Void,
             pass: @escaping @MainActor () async -> Void) async {
        if inFlight {
            pending = true
            return
        }
        inFlight = true
        isFetching(true)
        repeat {
            // Cleared immediately before the pass that serves it, and
            // nowhere else. That one line is what bounds passes by
            // requests: a pass can only be reached by consuming a request.
            pending = false
            passCount &+= 1
            await pass()
        } while pending && !Task.isCancelled
        inFlight = false
        // Only reachable cancelled: an uncancelled loop consumes the flag
        // and runs the pass it consumed it for. The follow-up runs in a
        // fresh task because THIS task is being torn down, and the request
        // it owes belongs to some other caller who is not.
        guard pending else {
            isFetching(false)
            return
        }
        // A TOKEN, because neither clearing the flag nor leaving it up is
        // enough on its own. Clearing it and spawning unconditionally let a
        // competitor arriving in the gap serve the owed request and the
        // rescue run a second full pass behind it. Leaving it up was no
        // better: `run` inspects only `inFlight`, never `pending`, so the
        // rescue either ran its own redundant pass or re-raised the flag and
        // made the competitor's loop run one. Either way an extra HTTP pull
        // with isFetching held true across it, on a singleton up to seven
        // views observe, which is the duplicate-pull-and-flicker this whole
        // block exists to avoid.
        //
        // The pass counter settles it: any pass that STARTS after this point
        // serves the owed request, so the rescue runs only if none has.
        let owedAt = passCount
        pending = false
        Task {
            guard self.passCount == owedAt else {
                // A competitor's pass already served it. Settle the flag only
                // if that competitor is finished and nobody else holds it.
                if !self.inFlight { isFetching(false) }
                return
            }
            await self.run(isFetching: isFetching, pass: pass)
        }
    }
}
