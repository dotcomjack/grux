import XCTest
import GruxShellCore
@testable import Grux

/// The notice that stands where seven panels used to render an empty list.
///
/// THE FAILURE THIS GUARDS IS NOT A CRASH. Every one of those panels compiled,
/// ran, and showed a stranger nothing at all, which is the single shape that
/// reads as a broken app rather than as an unfinished one. So the assertions
/// below are about what a person sees, and the most important one is the
/// inverse: a service that IS running must produce NO notice. A guard that
/// always fires is indistinguishable from a guard that works, and it would put
/// an apology over a working panel, which is the same defect running the other
/// way.
@MainActor
final class PrivateServiceNoticeTests: XCTestCase {

    // MARK: - Fixtures

    /// A counter a `@Sendable` probe closure can bump. The probe may run off the
    /// main actor, so this cannot be a captured local.
    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// A clock the test moves by hand, so the cache interval is checkable
    /// without a test that sleeps for a minute.
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_700_000_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) {
            lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock()
        }
    }

    /// A mutable flag with a read counter, standing in for a `userConfigured`
    /// closure. The per-entry closure is already the injectable seam, so
    /// counting reads needs no new entry shape: a fixture built over this box
    /// observes both how often the reachability layer consults the source and
    /// whether a value written mid-test is ever seen.
    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        private var readCount = 0
        var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
        func read() -> Bool { lock.lock(); defer { lock.unlock() }; readCount += 1; return value }
        func set(_ newValue: Bool) { lock.lock(); value = newValue; lock.unlock() }
    }

    /// A notice with one base, so `isConfigured` is true and the probe is
    /// actually consulted. Built here rather than borrowed from the catalog
    /// because a catalog entry's `bases` reads this machine's real config, and
    /// a test that depends on one desk's state proves nothing.
    private func fixture(id: String = "fixture",
                         bases: [String] = ["http://127.0.0.1:3999"],
                         userConfigured: @escaping @Sendable () -> Bool = { false },
                         hasCompiledInBase: Bool = false) -> PrivateServiceNotice {
        PrivateServiceNotice(
            id: id,
            label: "test service",
            port: 3999,
            does: "This panel would show the thing the test service knows.",
            probePath: "/health",
            configSource: "Point Grux at a machine running one in ~/.grux/test-service-hosts.txt.",
            bases: { bases },
            userConfigured: userConfigured,
            hasCompiledInBase: hasCompiledInBase)
    }

    // MARK: - The probe is fast, and it does not hang

    /// A slow probe is its own kind of broken. These are loopback services, so
    /// the budget is in seconds, not tens of seconds, and it is a constant so
    /// this can assert on it rather than on a stopwatch alone.
    func testTheProbeBudgetIsShortEnoughToBeInvisible() {
        XCTAssertLessThanOrEqual(PrivateServiceProbe.timeout, 2.0,
            "a probe this panel waits on is allowed \(PrivateServiceProbe.timeout)s. "
            + "Anything past about two seconds is a panel that visibly stalls, which is the "
            + "defect the notice was written to remove, arriving by a different route.")
    }

    /// A refused loopback port is the exact case every install without a
    /// companion service is in. It must answer false, and it must answer at once.
    func testARefusedLoopbackPortAnswersFalseImmediately() async {
        let url = URL(string: "http://127.0.0.1:1/probe")!
        let started = Date()
        let reachable = await PrivateServiceProbe.live(url, 1.5)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(reachable, "nothing binds port 1, so the probe must report unreachable")
        XCTAssertLessThan(elapsed, 3.0,
            "a refused connection took \(elapsed)s. Connection refused is returned by the "
            + "kernel in under a millisecond, so anything near the timeout means the probe is "
            + "waiting on something it should not be.")
    }

    /// THE HANG TEST. The deadline is enforced by a task group rather than by
    /// `URLRequest.timeoutInterval`, because that field is an idle timer rather
    /// than a wall clock and a peer that dribbles bytes can outlive it forever.
    /// Aimed at a non-routable address so nothing answers, with a deliberately
    /// tiny budget: the call has to come back anyway.
    func testTheProbeReturnsEvenWhenNothingEverAnswers() async {
        let url = URL(string: "http://10.255.255.1/probe")!
        let started = Date()
        let reachable = await PrivateServiceProbe.live(url, 0.05)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertFalse(reachable)
        XCTAssertLessThan(elapsed, 2.0,
            "the probe took \(elapsed)s against a black hole with a 0.05s budget, so the "
            + "deadline is not bounding it and a view awaiting this can hang.")
    }

    /// ANY HTTP status proves something is listening, 5xx included. The probe
    /// once said exactly that in a comment and then counted only statuses under
    /// 500, so a service answering 500 was reported absent while a 404 was
    /// reported present. Asserted through the classification seam, because
    /// standing up a real server per status would test the socket, not the rule.
    func testAnyHTTPStatusProvesSomethingIsListening() {
        let url = URL(string: "http://127.0.0.1:3999/health")!
        for status in [200, 204, 404, 500, 503] {
            let answer = HTTPURLResponse(url: url, statusCode: status,
                                         httpVersion: nil, headerFields: nil)!
            XCTAssertTrue(PrivateServiceProbe.provesListening(answer),
                "a \(status) answer was classified as nothing listening. Whatever wrote that "
                + "status is a running service, and reporting it absent puts the notice over "
                + "a panel that would render if asked.")
        }
        let notHTTP = URLResponse(url: url, mimeType: nil,
                                  expectedContentLength: 0, textEncodingName: nil)
        XCTAssertFalse(PrivateServiceProbe.provesListening(notHTTP),
            "a non-HTTP response proved a service, so the true branch above is vacuous")
    }

    // MARK: - A failed probe always says something

    func testAFailedProbeYieldsANoticeAndNeverAnEmptyString() async {
        let reachability = PrivateServiceReachability(probe: { _, _ in false })
        let service = fixture()

        await reachability.refreshIfNeeded(service)
        let explanation = reachability.explanation(for: service)

        XCTAssertNotNil(explanation, "an unreachable service must produce a notice, not silence")
        XCTAssertFalse((explanation ?? "").isEmpty,
            "an empty explanation is an empty panel with extra steps, which is the exact "
            + "thing this component exists to delete")
        XCTAssertTrue((explanation ?? "").contains(service.sharedExplanation),
            "the notice dropped the one paragraph every surface is supposed to share")
    }

    /// The probe joins base to route through the ONE join rule, so a base a
    /// person pasted with a trailing slash asks for the real route.
    ///
    /// This one is worse than a 404 on a fetch. `provesListening` counts ANY
    /// HTTP answer, so the 404 a strict router returns for "//health" proved
    /// the service present, the notice stood down, and the panel it stood
    /// down over was failing every call it made. A probe that certifies
    /// health by asking for a path nothing serves is worse than no probe.
    func testTheProbeJoinsATrailingSlashBaseOntoTheRealRoute() async {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var urls: [String] = []
            func note(_ u: URL) { lock.lock(); urls.append(u.absoluteString); lock.unlock() }
            var all: [String] { lock.lock(); defer { lock.unlock() }; return urls }
        }
        let seen = Seen()
        let reachability = PrivateServiceReachability(probe: { url, _ in
            seen.note(url); return true
        })
        let service = fixture(bases: ["http://127.0.0.1:3999/"])

        await reachability.refreshIfNeeded(service)

        XCTAssertEqual(seen.all, ["http://127.0.0.1:3999/health"],
            "the probe asked for \(seen.all), and a strict router 404s the doubled slash "
            + "while this probe counts any answer as proof, so the notice stands down over "
            + "a panel whose every call is failing")
    }

    /// Before any probe has run there is no answer, and the honest default is
    /// the notice: for everybody except the person who wrote these services they
    /// are absent. Defaulting the other way would show an empty list for the
    /// length of a probe on every first render.
    func testAnUnprobedServiceShowsTheNoticeRatherThanNothing() {
        let reachability = PrivateServiceReachability(probe: { _, _ in true })
        let explanation = reachability.explanation(for: fixture())

        XCTAssertNotNil(explanation,
            "with no answer yet the panel must say something. An empty list while a probe "
            + "runs is the frame that reads as a broken app.")
    }

    /// An install nobody has pointed anywhere is answered without a single
    /// network call. Not an optimisation: there is no address to ask, so
    /// unreachable is known rather than measured.
    func testAnUnconfiguredServiceIsAnsweredWithoutProbingAtAll() async {
        let counter = ProbeCounter()
        let reachability = PrivateServiceReachability(probe: { _, _ in counter.bump(); return true })
        let service = fixture(bases: [])

        await reachability.refreshIfNeeded(service)

        XCTAssertEqual(counter.count, 0,
            "a service with no configured base was probed \(counter.count) times. A fresh "
            + "install must make no network calls to discover it has no companion service.")
        XCTAssertNotNil(reachability.explanation(for: service))
    }

    /// `isConfigured` for the media service derives from the SAME defaults key
    /// its `bases` reads, `grux.creative.imageServiceBaseURLs`. It used to ask
    /// the contract capability instead, whose key `grux.media.service_url` has
    /// no writer anywhere in the app, so an install configured the documented
    /// way was never probed and the notice claimed absence over a working
    /// panel. Both directions asserted, on the real defaults, saved and
    /// restored so the test leaves this desk's config alone.
    func testMediaServiceIsConfiguredExactlyWhenTheImageServiceKeyHoldsABase() {
        let key = "grux.creative.imageServiceBaseURLs"
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        let reachability = PrivateServiceReachability(probe: { _, _ in true })
        let media = PrivateServiceNotice.mediaService

        defaults.removeObject(forKey: key)
        XCTAssertFalse(reachability.isConfigured(media),
            "with \(key) unset the media service reports configured, so some other source "
            + "is answering for it and the two halves can disagree again")
        defaults.set("", forKey: key)
        XCTAssertFalse(reachability.isConfigured(media),
            "an empty \(key) is absence, exactly like an unset one")

        defaults.set("http://localhost:3847", forKey: key)
        XCTAssertTrue(reachability.isConfigured(media),
            "\(key) holds a base and the media service still reports unconfigured, which "
            + "skips the probe and claims absence over whatever that base serves")
        XCTAssertEqual(media.bases(), ["http://localhost:3847"],
            "isConfigured said yes for a base that bases() does not carry, so the probe "
            + "would walk a different list than the one that made it eligible")
    }

    /// The registry probe covers the loopback base the real client ALWAYS
    /// tries last, so it is always probe-eligible and its notice can only
    /// appear when nothing answered anywhere the client would look. The old
    /// shape read the configured hosts alone, so a Projects tab populated from
    /// localhost:3847 sat beside a notice claiming no registry exists.
    func testTheRegistryProbeCoversTheLoopbackBaseTheRealClientAlwaysTries() async {
        final class URLBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: [URL] = []
            func append(_ url: URL) { lock.lock(); value.append(url); lock.unlock() }
            var urls: [URL] { lock.lock(); defer { lock.unlock() }; return value }
        }
        let box = URLBox()
        let reachability = PrivateServiceReachability(
            probe: { url, _ in box.append(url); return false })
        let registry = PrivateServiceNotice.projectRegistry

        XCTAssertTrue(reachability.isConfigured(registry),
            "the registry client always carries the loopback base, so an install where it "
            + "is not probe-eligible is walking a different list than the client")

        await reachability.refreshIfNeeded(registry)
        XCTAssertTrue(box.urls.contains(URL(string: "http://localhost:3847/api/projects")!),
            "the probe never asked http://localhost:3847, the one base the real client "
            + "tries on every install. Probed: \(box.urls)")
    }

    // MARK: - THE GUARD TESTS ITSELF

    /// The assertion that makes every other one mean something. Without it every
    /// test above passes against a component that returns the notice
    /// unconditionally, which would put an apology over a working panel.
    func testAReachableServiceYieldsNoNoticeAtAll() async {
        let reachability = PrivateServiceReachability(probe: { _, _ in true })
        let service = fixture()

        await reachability.refreshIfNeeded(service)

        XCTAssertNil(reachability.explanation(for: service),
            "a service that answered still produced a notice. A panel that apologises over "
            + "live data is the same defect as an empty list, running the other way.")
    }

    /// The pair, run through one instance, so the difference is provably the
    /// probe's answer and not two differently configured objects.
    func testTheSameServiceFlipsWithTheAnswer() async {
        let service = fixture()

        let down = PrivateServiceReachability(probe: { _, _ in false })
        await down.refreshIfNeeded(service)
        XCTAssertNotNil(down.explanation(for: service))

        let up = PrivateServiceReachability(probe: { _, _ in true })
        await up.refreshIfNeeded(service)
        XCTAssertNil(up.explanation(for: service))
    }

    /// A host the user pointed Grux at being down is the section banner's
    /// story, and this card claiming "absence is normal" beside that banner
    /// was the round 2 contradiction: both rendered at once. The rule lives in
    /// `explanation(for:)`, the seam the view reads, so it is asserted here
    /// rather than through SwiftUI.
    func testAUserConfiguredServiceProducesNoCardEvenWhenItsHostIsDown() async {
        let reachability = PrivateServiceReachability(probe: { _, _ in false })

        let configured = fixture(id: "configured", userConfigured: { true })
        await reachability.refreshIfNeeded(configured)
        XCTAssertNil(reachability.explanation(for: configured),
            "the probe found nothing and the user configured a host, yet the absence card "
            + "still renders. The section's technical banner owns that surface, and showing "
            + "both is the configured-but-down contradiction again.")

        // Control: the identical service without user config must still show
        // the card, or the assertion above is satisfied by a component that
        // never shows anything at all.
        let unconfigured = fixture(id: "unconfigured", userConfigured: { false })
        await reachability.refreshIfNeeded(unconfigured)
        XCTAssertNotNil(reachability.explanation(for: unconfigured),
            "control: with userConfigured false the card must stand, so the nil above is "
            + "provably the flag's doing")
    }

    // MARK: - The cache

    /// Opening the Empire dashboard five times must not fire five probes at
    /// three services each.
    func testASecondCallInsideTheIntervalDoesNotProbeAgain() async {
        let counter = ProbeCounter()
        let clock = TestClock()
        let reachability = PrivateServiceReachability(
            probe: { _, _ in counter.bump(); return false },
            now: { clock.now })
        let service = fixture()

        await reachability.refreshIfNeeded(service)
        await reachability.refreshIfNeeded(service)
        await reachability.refreshIfNeeded(service)

        XCTAssertEqual(counter.count, 1,
            "three calls inside the re-probe interval fired \(counter.count) probes. Five tab "
            + "opens would be five round trips against a service that is almost never there.")
    }

    /// The other half, and the reason the test above is not vacuous. A cache
    /// that never expires is indistinguishable from probing once ever, and it
    /// would mean somebody who just started the service has to relaunch Grux
    /// before the notice clears.
    ///
    /// EVERY expiry must be answered again, not just the first, which is why
    /// this drives two of them. The mounted view now loops on the reprobe
    /// interval instead of probing once on appear (a card claiming no service
    /// exists on this Mac used to sit over one started after the single
    /// probe), and that loop only keeps the card honest if the layer under it
    /// re-measures on each pass through the interval.
    func testTheCacheExpiresSoAStartedServiceIsNoticed() async {
        let counter = ProbeCounter()
        let clock = TestClock()
        let reachability = PrivateServiceReachability(
            probe: { _, _ in counter.bump(); return false },
            now: { clock.now })
        let service = fixture()

        await reachability.refreshIfNeeded(service)
        clock.advance(PrivateServiceReachability.reprobeInterval + 1)
        await reachability.refreshIfNeeded(service)

        XCTAssertEqual(counter.count, 2,
            "past the re-probe interval the answer must be taken again, or starting the "
            + "service never clears the notice without a relaunch")

        clock.advance(PrivateServiceReachability.reprobeInterval + 1)
        await reachability.refreshIfNeeded(service)

        XCTAssertEqual(counter.count, 3,
            "the second expiry produced no third probe, so the view's reprobe loop would "
            + "go stale after one cycle and a card could again outlive a started service")
    }

    /// `userConfigured` is a synchronous file read and parse for the
    /// file-backed services, `explanation(for:)` runs on every SwiftUI body
    /// evaluation, and the shared revision counter re-renders every mounted
    /// card whenever any probe answers. So the reachability layer memoizes
    /// the answer on the probe cache's own clock. Three reads inside the
    /// interval must cost one consult of the source; the interval passing
    /// must cost a second, or the memo is a permanent snapshot and a config
    /// edit needs a relaunch to be seen.
    func testUserConfiguredIsReadOncePerIntervalNotOncePerBodyEvaluation() {
        let flag = FlagBox()
        let clock = TestClock()
        let reachability = PrivateServiceReachability(
            probe: { _, _ in false }, now: { clock.now })
        let service = fixture(userConfigured: { flag.read() })

        _ = reachability.explanation(for: service)
        _ = reachability.explanation(for: service)
        _ = reachability.explanation(for: service)
        XCTAssertEqual(flag.reads, 1,
            "three body evaluations inside the interval consulted the config source "
            + "\(flag.reads) times. For the file-backed services that is a file read and "
            + "parse on the main actor per mounted card per render pass.")

        clock.advance(PrivateServiceReachability.reprobeInterval + 1)
        _ = reachability.explanation(for: service)
        XCTAssertEqual(flag.reads, 2,
            "past the interval the memo must expire and re-read the real source, or a "
            + "user who writes the config file cannot be seen without a relaunch")
    }

    /// The memo has to keep the semantics, not just cut the reads: a config
    /// write while a memo is fresh takes effect at the next expiry, the same
    /// promise the probe cache already makes. Both halves asserted, because
    /// each on its own is satisfiable by a broken memo: seen-inside-the-
    /// interval means nothing is memoized, and never-seen means nothing
    /// expires.
    func testAConfigWriteIsSeenWithinOneIntervalThroughTheMemo() {
        let flag = FlagBox()
        let clock = TestClock()
        let reachability = PrivateServiceReachability(
            probe: { _, _ in false }, now: { clock.now })
        let service = fixture(userConfigured: { flag.read() })

        XCTAssertNotNil(reachability.explanation(for: service),
            "unconfigured and unprobed must show the card, or the flip below proves nothing")

        flag.set(true)
        XCTAssertNotNil(reachability.explanation(for: service),
            "a config write landed INSIDE the interval, so the memo re-read the source "
            + "and is not suppressing reads at all")

        clock.advance(PrivateServiceReachability.reprobeInterval + 1)
        XCTAssertNil(reachability.explanation(for: service),
            "the user pointed Grux at a host and past the interval the card still "
            + "stands, so the memo never expires and the card and the section banner "
            + "will fight over the surface again")
    }

    /// The publish split. `userConfigured(_:)` runs inside body evaluation,
    /// where bumping `revision` is publishing during a view update, so it
    /// must NEVER publish; `reloadUserConfigured(_:)` runs from the card's
    /// probe task, and it is the ONE place a config flip may publish, or a
    /// solo-surface card (Media Studio has no sibling cards bumping the
    /// shared counter) sits on stale absence copy indefinitely after the
    /// user configures the service.
    func testOnlyTheTaskContextReadPublishesTheConfigFlip() {
        let flag = FlagBox()
        let clock = TestClock()
        let reachability = PrivateServiceReachability(
            probe: { _, _ in false }, now: { clock.now })
        let service = fixture(userConfigured: { flag.read() })

        // Body reads never publish, before or after the memo expires, even
        // when the re-read value differs from the memo.
        let before = reachability.revision
        _ = reachability.userConfigured(service)
        flag.set(true)
        clock.advance(PrivateServiceReachability.reprobeInterval + 1)
        _ = reachability.userConfigured(service)
        XCTAssertEqual(reachability.revision, before,
            "a body-path read published. Bumping revision inside body evaluation is "
            + "publishing during a view update, the thing the split exists to prevent.")

        // The task-context read publishes exactly the flip, not every read.
        flag.set(false)
        let flipped = reachability.reloadUserConfigured(service)
        XCTAssertFalse(flipped, "the reload must return the freshly re-read value")
        let afterFlip = reachability.revision
        XCTAssertNotEqual(afterFlip, before,
            "the config flip never published, so no mounted card re-renders and the "
            + "stale absence copy stands over a configured service")

        _ = reachability.reloadUserConfigured(service)
        XCTAssertEqual(reachability.revision, afterFlip,
            "an unchanged answer published anyway, which re-renders every mounted card "
            + "once per loop pass for no state change")
    }

    /// A first-ever reload has no earlier answer any view rendered from, so
    /// there is no flip to publish.
    func testTheFirstReloadDoesNotPublish() {
        let reachability = PrivateServiceReachability(probe: { _, _ in false })
        let before = reachability.revision
        _ = reachability.reloadUserConfigured(fixture(userConfigured: { true }))
        XCTAssertEqual(reachability.revision, before,
            "with no memo there is no earlier answer to correct, so publishing is a "
            + "spurious re-render of every mounted card")
    }

    // MARK: - The probe loop's exits

    /// A shared mutable counter for the loop's closure. MainActor-confined by
    /// use: probeLoop and its closure both run on the main actor.
    private final class FireBox {
        var count = 0
    }

    /// The got-configured exit. The loop used to end that arm with NOTHING
    /// after it, so configuring the service the card told the reader to
    /// configure fired no refresh and the panel sat on its stale empty
    /// answer until a manual pull.
    func testTheProbeLoopFiresTheClosureOnceWhenItExitsGotConfigured() async {
        let reachability = PrivateServiceReachability(probe: { _, _ in false })
        let box = FireBox()

        await PrivateServiceNoticeView.probeLoop(
            service: fixture(userConfigured: { true }),
            reachability: reachability) { box.count += 1 }

        XCTAssertEqual(box.count, 1,
            "the loop exited because the service became user-configured and fired the "
            + "closure \(box.count) times; the store whose empty answer mounted the "
            + "card is still holding that answer, and exactly one re-pull corrects it")
    }

    /// The cancellation exit fires nothing: the card unmounted, nobody is
    /// looking, and a refresh fired from a dead mount is work the next mount
    /// will redo anyway. The reachable-transition fire inside the loop is
    /// pinned on the way: a probe that answers true on the first pass fires
    /// exactly once, never again per pass.
    func testTheProbeLoopCancellationExitFiresNothingFurther() async {
        let reachability = PrivateServiceReachability(probe: { _, _ in true })
        let box = FireBox()

        let loop = Task { @MainActor in
            await PrivateServiceNoticeView.probeLoop(
                service: fixture(userConfigured: { false }),
                reachability: reachability) { box.count += 1 }
        }
        // Let the first pass run (fires once on the unreachable-to-reachable
        // transition), then tear the mount down mid-sleep.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(box.count, 1,
            "the first pass found the service up and should have fired exactly once")
        loop.cancel()
        await loop.value

        XCTAssertEqual(box.count, 1,
            "the cancellation exit fired the closure again, so every unmount triggers "
            + "a refresh nobody asked for")
    }

    /// The interval has to sit between "free to navigate" and "noticed within a
    /// reasonable wait". A day is a stale answer, a second is the probe storm
    /// the cache exists to stop.
    func testTheReprobeIntervalIsInTheUsefulRange() {
        let interval = PrivateServiceReachability.reprobeInterval
        XCTAssertGreaterThanOrEqual(interval, 10, "\(interval)s re-probes often enough to be a storm")
        XCTAssertLessThanOrEqual(interval, 300, "\(interval)s is long enough to feel broken")
    }

    // MARK: - The catalog

    func testEveryNoticeHasUsableCopy() {
        for service in PrivateServiceNotice.all {
            XCTAssertFalse(service.explanation.isEmpty, "\(service.id) explains nothing")
            XCTAssertFalse(service.does.isEmpty, "\(service.id) never says what the panel would show")
            XCTAssertFalse(service.headline.isEmpty, "\(service.id) has no headline")
            XCTAssertTrue(service.explanation.contains(service.sharedExplanation),
                "\(service.id) does not carry its shared paragraph variant, so the surfaces "
                + "have started drifting into separate voices, which is the thing one type "
                + "was for")
            XCTAssertTrue(service.probePath.hasPrefix("/"),
                "\(service.id) probePath \(service.probePath) is not a route")
        }
    }

    /// Nothing here may read as a fault. The feature is not broken, it was never
    /// pointed at anything, and those are different things to read on a first
    /// run. `CapabilitySetupCard`'s header makes the same choice.
    func testNoNoticeReadsAsAnError() {
        let banned = ["error", "failed", "failure", "unavailable", "broken", "crash"]
        for service in PrivateServiceNotice.all {
            let text = (service.headline + " " + service.explanation).lowercased()
            for word in banned {
                XCTAssertFalse(text.contains(word),
                    "\(service.id) says \"\(word)\". Nothing is broken when an optional "
                    + "companion service is simply absent, and saying so reads as a fault.")
            }
        }
    }

    func testIdsAreUniqueAndTheListIsTheSevenKnownSurfaces() {
        XCTAssertEqual(Set(PrivateServiceNotice.all.map(\.id)).count,
                       PrivateServiceNotice.all.count,
                       "duplicate id in PrivateServiceNotice.all, so two panels would share a "
                       + "reachability cache entry and one could hide the other's answer")
        XCTAssertEqual(Set(PrivateServiceNotice.all.map(\.id)),
                       ["registry", "media", "pr-digest", "test-digest",
                        "social-ops", "brands-poster", "meta-ads"],
                       "the set of private-service surfaces changed. That is allowed, but it "
                       + "is a decision: update this expectation deliberately rather than to "
                       + "make a test pass.")
    }

    /// Every explanation names the port AND the real config source, pinned per
    /// service to the exact key or path the shipped client reads. Pinned HERE,
    /// not derived from the notice, because the failure this guards is the
    /// notice and the client disagreeing: each value below is quoted from the
    /// client file named beside it, so a client that moves its config breaks
    /// this test rather than silently orphaning the copy. The full-set
    /// equality keeps the map honest: a service missing from it is a failure,
    /// not a skip.
    func testEveryExplanationNamesItsPortAndItsRealConfigSource() {
        let sources: [String: String] = [
            // ProjectRegistryClient / ProjectsServiceConfig.fileURL
            "registry": "~/.grux/projects-service.json",
            // CreativeEngine.imageBaseURLs
            "media": "grux.creative.imageServiceBaseURLs",
            // PRDigestService.baseURLs
            "pr-digest": "~/.grux/pr-digest-hosts.txt",
            // TestDigestService.baseURLsDefaultsKey
            "test-digest": "grux.services.testDigestBaseURLs",
            // SocialOpsService.configuredHosts()
            "social-ops": "~/.grux/social-ops-hosts.txt",
            // BrandsPosterService.baseURLs, which reads the SAME file through
            // SocialOpsService.configuredHosts(): one companion on 3856 with
            // two routes, so one file configures both panels.
            "brands-poster": "~/.grux/social-ops-hosts.txt",
            // MetaAdsService.baseURLsDefaultsKey
            "meta-ads": "grux.services.metaAdsBaseURLs",
        ]
        XCTAssertEqual(Set(sources.keys), Set(PrivateServiceNotice.all.map(\.id)),
            "a service exists that this map does not pin a config source for, so its copy "
            + "could name nothing actionable and no test would say so")

        for service in PrivateServiceNotice.all {
            guard let source = sources[service.id] else { continue }
            XCTAssertTrue(service.explanation.contains(source),
                "\(service.id) never names \(source). The old thrown error strings were the "
                + "only in-app statement of how to point Grux at these services and they are "
                + "gone, so the notice is now the one place a reader learns the switch.")
            XCTAssertTrue(service.explanation.contains("\(service.port)"),
                "\(service.id) tells a reader the service is missing and never says what it "
                + "would have to bind, which leaves them with nothing to act on")
        }
    }

    /// `userConfigured` reads ONLY the user-writable source each configSource
    /// sentence names, never a compiled-in loopback base. The file-backed
    /// services are asserted against their client's own read so the two
    /// cannot drift, and brandsPoster is asserted against the SAME read as
    /// socialOps, because they are one companion on 3856 answering two
    /// routes: the file that points Grux at one points it at both.
    /// The union check at the end keeps the split honest: a service neither
    /// this test nor the defaults one pins is a failure, not a skip.
    func testUserConfiguredReadsTheUserSourceAndNeverCompiledBases() {
        let poster = PrivateServiceNotice.brandsPoster
        XCTAssertFalse(poster.bases().isEmpty,
            "brandsPoster lost its compiled loopback base, so an unconfigured install "
            + "stops trying the one host it could ever have answered on")
        XCTAssertEqual(poster.userConfigured(),
                       !SocialOpsService.configuredHosts().isEmpty,
            "brandsPoster userConfigured disagrees with the hosts file its client now "
            + "reads, which is how a configured remote poster got every fetch "
            + "classified as absence")
        XCTAssertEqual(poster.userConfigured(),
                       PrivateServiceNotice.socialOps.userConfigured(),
            "the two routes of one companion answered the who-configured-this question "
            + "differently, so one panel would claim absence beside the other's banner")
        XCTAssertEqual(poster.bases().count, PrivateServiceNotice.socialOps.bases().count,
            "brandsPoster and socialOps stopped composing the same host list, so a "
            + "remote host reaches one route and not the other")

        let registry = PrivateServiceNotice.projectRegistry
        XCTAssertTrue(registry.bases().contains(ProjectRegistryClient.localhostBase),
            "the registry probe list dropped the loopback base the real client always tries")
        XCTAssertEqual(registry.userConfigured(),
                       !ProjectRegistryClient.configuredBases.isEmpty,
            "registry userConfigured disagrees with ~/.grux/projects-service.json, the one "
            + "source its configSource sentence names, so the card and the section banner "
            + "can fight over the surface again")

        XCTAssertEqual(PrivateServiceNotice.socialOps.userConfigured(),
                       SocialOpsService.baseURLs.count > 1,
            "socialOps userConfigured disagrees with its client's own host list, which is "
            + "the configured hosts plus exactly one compiled loopback entry")

        XCTAssertEqual(PrivateServiceNotice.pullRequestDigest.userConfigured(),
                       !PRDigestService.baseURLs.isEmpty,
            "pr-digest userConfigured disagrees with the client's read of "
            + "~/.grux/pr-digest-hosts.txt")

        let fileBacked: Set<String> = ["registry", "social-ops", "pr-digest", "brands-poster"]
        let defaultsBacked: Set<String> = ["media", "test-digest", "meta-ads"]
        XCTAssertEqual(fileBacked.union(defaultsBacked),
                       Set(PrivateServiceNotice.all.map(\.id)),
            "a service exists whose userConfigured source no test pins, so its flag could "
            + "read the wrong source and nothing would say so")
    }

    /// The defaults-backed flags, exercised BOTH ways on the real key, saved
    /// and restored so the test leaves this desk's config alone. The set-then
    /// -assert direction is the one that catches a flag wired to a different
    /// key: unset-reads-false passes for almost any bug.
    func testDefaultsBackedUserConfiguredTracksItsOwnKeyExactly() {
        let pairs: [(service: PrivateServiceNotice, key: String)] = [
            (.mediaService, "grux.creative.imageServiceBaseURLs"),
            (.nightlyTests, "grux.services.testDigestBaseURLs"),
            (.metaAds, "grux.services.metaAdsBaseURLs"),
        ]
        let defaults = UserDefaults.standard
        for (service, key) in pairs {
            let original = defaults.string(forKey: key)
            defer {
                if let original {
                    defaults.set(original, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }

            defaults.removeObject(forKey: key)
            XCTAssertFalse(service.userConfigured(),
                "\(service.id): with \(key) unset, userConfigured still says somebody "
                + "configured a host, so some other source is answering for it")

            defaults.set("http://mini:9999", forKey: key)
            XCTAssertTrue(service.userConfigured(),
                "\(service.id): \(key) holds a host and userConfigured still says nobody "
                + "configured anything, so the section banner and this card will disagree "
                + "about who owns the surface")
        }
    }

    /// The shared paragraph's third sentence must be TRUE per service.
    /// socialOps, brandsPoster and projectRegistry compile a loopback base in
    /// and try it on every install, so telling their reader "Grux ships
    /// pointing at nobody's host" was false, and their own configSource
    /// sentence contradicted it two sentences later. Pinned here by id, like
    /// the config sources: adding a service means classifying it deliberately.
    func testTheSharedParagraphVariantIsTruePerService() {
        let compiledIn: Set<String> = ["registry", "social-ops", "brands-poster"]
        XCTAssertTrue(compiledIn.isSubset(of: Set(PrivateServiceNotice.all.map(\.id))),
            "the pinned compiled-in set names a service that no longer exists")

        for service in PrivateServiceNotice.all {
            let expectCompiled = compiledIn.contains(service.id)
            XCTAssertEqual(service.hasCompiledInBase, expectCompiled,
                "\(service.id) is classified \(service.hasCompiledInBase ? "compiled-in" : "configured-only") "
                + "but its client \(expectCompiled ? "always tries a loopback base" : "ships with no host"), "
                + "so its shared paragraph argues from the wrong facts")
            XCTAssertTrue(service.explanation.contains(
                PrivateServiceNotice.sharedExplanation(hasCompiledInBase: expectCompiled)),
                "\(service.id) does not carry the variant its client earns")
            if expectCompiled {
                XCTAssertFalse(service.explanation.contains("nobody's host"),
                    "\(service.id) claims Grux ships pointing at nobody's host while its own "
                    + "client compiles a loopback base in and just tried it, and its "
                    + "configSource sentence says so two sentences later")
            }
        }

        // Control: the two variants genuinely differ, or everything above
        // passes with one paragraph and the split never happened.
        XCTAssertNotEqual(PrivateServiceNotice.sharedExplanation(hasCompiledInBase: true),
                          PrivateServiceNotice.sharedExplanation(hasCompiledInBase: false),
            "both variants are the same string, so the per-service choice is vacuous")
    }

    /// The copy compiles into the binary and the house rule bans typographic
    /// dashes everywhere. Asserted on the COMPOSED string rather than on the
    /// source, because the composition is where a dash would survive a scan of
    /// either half on its own.
    func testNoticeCopyUsesNoTypographicDashes() {
        for service in PrivateServiceNotice.all {
            let text = service.headline + " " + service.explanation
            XCTAssertFalse(text.contains("\u{2014}"), "\(service.id) copy contains an em dash")
            XCTAssertFalse(text.contains("\u{2013}"), "\(service.id) copy contains an en dash")
        }
    }
}
