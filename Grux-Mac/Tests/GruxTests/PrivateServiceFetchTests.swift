import Network
import XCTest
@testable import Grux

/// The one failover loop behind every companion-service client, proven against
/// injected attempts and zero real network.
///
/// THE LIE THIS GUARDS AGAINST: a host the user configured being DOWN used to
/// throw the "almost nobody runs one, an empty panel is normal" absence notice,
/// because every transport failure left the loop's error slot empty. To the one
/// person who configured a host, that message is false, and on a command path
/// (kill switch, pause, veto) it told them nothing needed fixing while their
/// instruction went nowhere. So the assertions here are about WHICH message
/// survives the loop, and every negative assertion has a control showing the
/// check can fire.
final class PrivateServiceFetchTests: XCTestCase {

    /// A distinct error type, so the tests can prove an answered error is
    /// rethrown verbatim rather than rewrapped with its message copied.
    private struct MarkerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let absence = "This panel reads from a companion service. An empty panel here is the normal state."

    /// Runs the helper and hands back the thrown error, nil when it returned.
    private func thrown<T>(
        service: String = "test service",
        bases: [String],
        userConfigured: Bool,
        absence: String?,
        attempt: (String) async -> PrivateServiceFetch.Outcome<T>
    ) async -> Error? {
        do {
            _ = try await PrivateServiceFetch.run(
                service: service, bases: bases, userConfigured: userConfigured,
                absenceExplanation: absence, attempt: attempt)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Success

    func testTheFirstSuccessReturnsImmediatelyAndLaterBasesAreNeverTried() async throws {
        var tried: [String] = []
        let value = try await PrivateServiceFetch.run(
            service: "test service",
            bases: ["http://one:1", "http://two:2"],
            userConfigured: false,
            absenceExplanation: absence
        ) { base -> PrivateServiceFetch.Outcome<String> in
            tried.append(base)
            return .success("payload from \(base)")
        }

        XCTAssertEqual(value, "payload from http://one:1")
        XCTAssertEqual(tried, ["http://one:1"],
            "the first base succeeded, so trying \(tried) means failover keeps "
            + "knocking on doors after somebody already answered")
    }

    // MARK: - Answered outranks everything

    func testAnAnsweredFaultOutranksTransportSilenceAndTheAbsenceNotice() async {
        let error = await thrown(
            bases: ["http://silent:1", "http://talking:2"],
            userConfigured: false,
            absence: absence
        ) { base -> PrivateServiceFetch.Outcome<String> in
            base.contains("silent")
                ? .transport("Connection refused")
                : .answered(MarkerError(message: "http://talking:2 returned HTTP 500"))
        }

        guard let error else { return XCTFail("no base succeeded, so this must throw") }
        XCTAssertTrue(error is MarkerError,
            "the answered error must be rethrown verbatim, not rewrapped, so a call "
            + "site's own error type survives the loop")
        XCTAssertEqual(error.localizedDescription, "http://talking:2 returned HTTP 500")
        XCTAssertNotEqual(error.localizedDescription, absence,
            "control: a service that replied badly must never be reported as absent")
    }

    func testTheHighestPrecedenceAnsweredBaseSpeaksWhenSeveralAnswered() async {
        let error = await thrown(
            bases: ["http://one:1", "http://two:2"],
            userConfigured: true,
            absence: absence
        ) { base -> PrivateServiceFetch.Outcome<String> in
            .answered(MarkerError(message: "answered by \(base)"))
        }

        XCTAssertEqual(error?.localizedDescription, "answered by http://one:1",
            "bases are in precedence order, so the first host that actually replied "
            + "is the authoritative account of what is wrong")
    }

    // MARK: - All transport: configured versus not

    func testAllTransportWithAConfiguredHostNamesTheServiceEachBaseAndItsReason() async {
        let error = await thrown(
            service: "pull request digest service",
            bases: ["http://mini:3852", "http://localhost:3852"],
            userConfigured: true,
            absence: absence
        ) { base -> PrivateServiceFetch.Outcome<String> in
            .transport(base.contains("mini") ? "No route to host" : "Connection refused")
        }

        guard let message = error?.localizedDescription else {
            return XCTFail("all transport with no success must throw")
        }
        XCTAssertTrue(message.contains("pull request digest service"),
            "the technical form must name the service: \(message)")
        XCTAssertTrue(message.contains("could not reach http://mini:3852: No route to host"),
            "each base tried must appear with its own transport reason: \(message)")
        XCTAssertTrue(message.contains("could not reach http://localhost:3852: Connection refused"),
            "the second base's reason is missing: \(message)")
        XCTAssertFalse(message.contains(absence),
            "a host the user configured being down is a real condition, and calling "
            + "it the normal empty state is the lie this helper exists to remove")
    }

    func testAllTransportUnconfiguredYieldsTheAbsenceNoticeExactly() async {
        let error = await thrown(
            bases: ["http://localhost:3856"],
            userConfigured: false,
            absence: absence
        ) { _ -> PrivateServiceFetch.Outcome<String> in
            .transport("Connection refused")
        }

        XCTAssertEqual(error?.localizedDescription, absence,
            "nobody pointed Grux anywhere, so transport silence is absence and the "
            + "notice stands, with no port or socket vocabulary leaking through")

        // Control: the identical run with userConfigured true must NOT yield
        // the notice, or the assertion above is satisfied by a helper that
        // returns the notice unconditionally.
        let configured = await thrown(
            bases: ["http://localhost:3856"],
            userConfigured: true,
            absence: absence
        ) { _ -> PrivateServiceFetch.Outcome<String> in
            .transport("Connection refused")
        }
        XCTAssertNotEqual(configured?.localizedDescription, absence,
            "control: userConfigured flipped nothing, so the notice is unconditional")
    }

    // MARK: - 404 never aborts failover

    func testA404OnBaseOneDoesNotStopBaseTwoFromWinning() async throws {
        var tried: [String] = []
        let value = try await PrivateServiceFetch.run(
            service: "test service",
            bases: ["http://stale:1", "http://fresh:2"],
            userConfigured: true,
            absenceExplanation: absence
        ) { base -> PrivateServiceFetch.Outcome<String> in
            tried.append(base)
            return base.contains("stale")
                ? .answered(MarkerError(message: "service has no digest yet (404)"))
                : .success("digest from \(base)")
        }

        XCTAssertEqual(value, "digest from http://fresh:2",
            "one host having nothing published says nothing about the next, so the "
            + "404 must not abort failover")
        XCTAssertEqual(tried, ["http://stale:1", "http://fresh:2"],
            "base two was never tried, so the 404 aborted the loop")
    }

    func testThe404DerivedMessageStandsOnlyWhenNoBaseSucceeds() async {
        let error = await thrown(
            bases: ["http://stale:1", "http://silent:2"],
            userConfigured: true,
            absence: absence
        ) { base -> PrivateServiceFetch.Outcome<String> in
            base.contains("stale")
                ? .answered(MarkerError(message: "service has no digest yet (404)"))
                : .transport("Connection refused")
        }

        XCTAssertEqual(error?.localizedDescription, "service has no digest yet (404)",
            "when nothing succeeds, the base that answered gets to explain, because "
            + "a service that exists outranks silence elsewhere")
    }

    // MARK: - Command paths never claim normality

    func testACommandPathNeverYieldsAbsenceCopyEvenUnconfigured() async {
        let error = await thrown(
            service: "ads engine (POST /api/meta-ads/kill)",
            bases: ["http://localhost:3857"],
            userConfigured: false,
            absence: nil
        ) { _ -> PrivateServiceFetch.Outcome<String> in
            .transport("Connection refused")
        }

        guard let message = error?.localizedDescription else {
            return XCTFail("an undelivered command must throw")
        }
        XCTAssertTrue(message.contains("could not reach http://localhost:3857: Connection refused"),
            "a failed command must say where it went and why it did not arrive: \(message)")
        XCTAssertTrue(message.contains("ads engine (POST /api/meta-ads/kill)"),
            "a failed command must name what was attempted: \(message)")
        XCTAssertFalse(message.contains("companion service you would run on your own machine"),
            "a kill switch that went nowhere is never the normal state, and telling "
            + "somebody nothing needs fixing while their command was dropped is the "
            + "most dangerous message this loop could produce. The phrase checked "
            + "opens BOTH shared-paragraph variants.")
    }

    func testACommandWithNoBasesAtAllStillThrowsTheTechnicalForm() async {
        let error = await thrown(
            service: "ads engine (POST /api/meta-ads/kill)",
            bases: [],
            userConfigured: false,
            absence: nil
        ) { _ -> PrivateServiceFetch.Outcome<String> in
            XCTFail("no bases exist, so nothing should be attempted")
            return .transport("unreached")
        }

        guard let message = error?.localizedDescription else {
            return XCTFail("a command with nowhere to go must still throw")
        }
        XCTAssertTrue(message.contains("no host is configured"),
            "with zero bases the honest technical answer is that there is nowhere "
            + "to send it: \(message)")
        XCTAssertFalse(message.contains("companion service you would run on your own machine"),
            "even fully unconfigured, a command failure must not read as normal, in "
            + "either shared-paragraph variant")
    }

    // MARK: - The terminal throws carry their kind

    /// Ten call sites used to tell absence from a down host by string-equality
    /// against the three-paragraph notice, which is exactly the check that
    /// breaks the day the copy grows a second variant, and it did. The
    /// discriminator is now typed, so every assertion here is on the kind and
    /// never on the prose.
    func testAbsenceAndHostsDownAreToldApartByKindNotByProse() async {
        let absent = await thrown(
            bases: ["http://localhost:3856"], userConfigured: false, absence: absence
        ) { _ -> PrivateServiceFetch.Outcome<String> in .transport("Connection refused") }
        XCTAssertEqual((absent as? PrivateServiceFetch.Failure)?.kind, .absence,
            "unconfigured transport silence must carry the absence kind, or a section "
            + "cannot route it to the notice without string-matching the copy")

        let down = await thrown(
            bases: ["http://mini:3852"], userConfigured: true, absence: absence
        ) { _ -> PrivateServiceFetch.Outcome<String> in .transport("No route to host") }
        XCTAssertEqual((down as? PrivateServiceFetch.Failure)?.kind, .hostsDown,
            "a configured host being down must carry the hostsDown kind, so the section "
            + "renders its technical banner and nothing else")

        // A command path (no absence text) is hostsDown whatever the config,
        // including the nowhere-to-send-it case with zero bases.
        let command = await thrown(
            bases: [], userConfigured: false, absence: nil
        ) { _ -> PrivateServiceFetch.Outcome<String> in .transport("unreached") }
        XCTAssertEqual((command as? PrivateServiceFetch.Failure)?.kind, .hostsDown,
            "a command with nowhere to go is a technical condition, never absence")

        // Control: an answered error is not a Failure at all. It is rethrown
        // verbatim, so there is no kind for a section to misroute on.
        let answered = await thrown(
            bases: ["http://one:1"], userConfigured: true, absence: absence
        ) { _ -> PrivateServiceFetch.Outcome<String> in
            .answered(MarkerError(message: "HTTP 500"))
        }
        XCTAssertNil(answered as? PrivateServiceFetch.Failure,
            "control: an answered fault came back wrapped as a Failure, so the "
            + "verbatim-rethrow rule broke and every kind assertion above is suspect")
    }

    // MARK: - The classify table

    /// Five stores used to derive the flag/stale/message triple by hand, in
    /// two shapes that diverged inside one commit and produced a confirmed
    /// mislabel. The whole table lives in classify() now, so every row is
    /// pinned here, one assertion set per (kind x cache) cell.

    private let transportDetail = "test service: could not reach http://mini:1: No route to host"

    private func absenceFailure(withDetail: Bool = true) -> PrivateServiceFetch.Failure {
        PrivateServiceFetch.Failure(kind: .absence, message: absence,
                                    transportDetail: withDetail ? transportDetail : nil)
    }

    func testClassifyHostsDownIsNeverAbsenceAndStaleTracksTheCache() {
        let failure = PrivateServiceFetch.Failure(
            kind: .hostsDown, message: transportDetail)
        for cache in [PrivateServiceFetch.CacheProvenance.empty, .pullProven, .pushFed] {
            guard let verdict = PrivateServiceFetch.classify(failure, cache: cache) else {
                return XCTFail("hostsDown classified as nil, which only cancellation may be")
            }
            XCTAssertFalse(verdict.isAbsence,
                "a configured host being down routed to the absence card is the lie the "
                + "typed kind was introduced to end, cache \(cache)")
            XCTAssertEqual(verdict.servingStale, cache != .empty,
                "stale must track whether a cache exists and nothing else, cache \(cache)")
            XCTAssertEqual(verdict.displayMessage, transportDetail,
                "the technical message must stand untouched, cache \(cache)")
        }
    }

    func testClassifyAbsenceOverAnEmptyCacheStandsAsAbsence() {
        guard let verdict = PrivateServiceFetch.classify(absenceFailure(), cache: .empty) else {
            return XCTFail("absence over an empty cache classified as nil")
        }
        XCTAssertTrue(verdict.isAbsence,
            "nothing configured and nothing held is the one true absence")
        XCTAssertFalse(verdict.servingStale, "there is no cache to be stale")
        XCTAssertEqual(verdict.displayMessage, absence,
            "the explanation prose is exactly what the notice renders")
    }

    func testClassifyAbsenceOverAPullProvenCacheIsAnOutageWithTheTransportDetail() {
        guard let verdict = PrivateServiceFetch.classify(absenceFailure(), cache: .pullProven) else {
            return XCTFail("absence over a pull-proven cache classified as nil")
        }
        XCTAssertFalse(verdict.isAbsence,
            "a host this machine once pulled from no longer answers. That is an outage, "
            + "and calling it absence tells the one person who had it working that "
            + "nothing needs fixing")
        XCTAssertTrue(verdict.servingStale, "the held cache is now stale and must say so")
        XCTAssertEqual(verdict.displayMessage, transportDetail,
            "the reclassified message must be the transport account")
        XCTAssertNotEqual(verdict.displayMessage, absence,
            "control: the three-paragraph absence prose rendering inside a fault banner "
            + "is the exact defect this row removes")

        // A hand-built absence with no transportDetail still may not leak the
        // prose: the fallback stays technical.
        guard let bare = PrivateServiceFetch.classify(
            absenceFailure(withDetail: false), cache: .pullProven) else {
            return XCTFail("detail-less absence over a pull-proven cache classified as nil")
        }
        XCTAssertNotEqual(bare.displayMessage, absence,
            "with no transportDetail the fallback leaked the absence prose into a fault "
            + "banner, which is the mislabel wearing a different entry path")
    }

    func testClassifyAbsenceOverAPushFedCacheStaysAbsence() {
        guard let verdict = PrivateServiceFetch.classify(absenceFailure(), cache: .pushFed) else {
            return XCTFail("absence over a push-fed cache classified as nil")
        }
        XCTAssertTrue(verdict.isAbsence,
            "pull absence over push-fed data is the normal state: the companion feeds "
            + "the store and no pull host was ever configured")
        XCTAssertFalse(verdict.servingStale,
            "push-fed data is live, and a stale tag over it would report the working "
            + "push channel as degraded")
        XCTAssertEqual(verdict.displayMessage, absence)
    }

    func testClassifyANonFailureErrorSpeaksForItselfAndStaleTracksTheCache() {
        let error = MarkerError(message: "http://talking:2 returned HTTP 500")
        for cache in [PrivateServiceFetch.CacheProvenance.empty, .pullProven, .pushFed] {
            guard let verdict = PrivateServiceFetch.classify(error, cache: cache) else {
                return XCTFail("an answered fault classified as nil, cache \(cache)")
            }
            XCTAssertFalse(verdict.isAbsence, "an answered fault is never absence")
            XCTAssertEqual(verdict.servingStale, cache != .empty)
            XCTAssertEqual(verdict.displayMessage, error.message,
                "an answered fault's own message is the authoritative account")
        }
    }

    /// The disjointness the four stale banners lean on: no row of the table
    /// classifies to isAbsence and servingStale both true, because absence
    /// stands only over the empty and push-fed caches and both of those rows
    /// pin servingStale false. PRDigestSection, TestDigestSection,
    /// SocialOpsSection and BrandsPostingSection deleted their stale-banner
    /// absence arm on this property, so every reachable (error x cache) cell
    /// is swept here: the day a new row breaks the disjointness, this fails
    /// and names the banners to revisit.
    func testClassifyNeverReturnsAbsenceAndServingStaleTogether() {
        let errors: [(name: String, error: Error)] = [
            ("absence", absenceFailure()),
            ("absence without detail", absenceFailure(withDetail: false)),
            ("hostsDown", PrivateServiceFetch.Failure(kind: .hostsDown, message: transportDetail)),
            ("answered fault", MarkerError(message: "HTTP 500")),
            ("transport URLError", URLError(.timedOut)),
        ]
        var verdicts = 0
        for (name, error) in errors {
            for cache in [PrivateServiceFetch.CacheProvenance.empty, .pullProven, .pushFed] {
                guard let verdict = PrivateServiceFetch.classify(error, cache: cache) else {
                    continue
                }
                verdicts += 1
                XCTAssertFalse(verdict.isAbsence && verdict.servingStale,
                    "\(name) over \(cache) classified as absence AND stale, which the four "
                    + "stale banners assume impossible: they render the technical sentence "
                    + "with no absence arm on the strength of this row never existing")
            }
        }
        // Control: the sweep actually classified cells, or the loop above
        // proves nothing.
        XCTAssertEqual(verdicts, 15, "the sweep skipped cells it should have classified")
    }

    func testClassifyCancellationYieldsNilForEveryCacheShape() {
        for cache in [PrivateServiceFetch.CacheProvenance.empty, .pullProven, .pushFed] {
            XCTAssertNil(PrivateServiceFetch.classify(CancellationError(), cache: cache),
                "a torn-down task is not a verdict about any host, and classifying it "
                + "writes a fabricated answer onto a singleton store, cache \(cache)")
            XCTAssertNil(PrivateServiceFetch.classify(URLError(.cancelled), cache: cache),
                "URLSession reports the same teardown as URLError(.cancelled), and it "
                + "must classify the same way, cache \(cache)")
        }
        // Control: a non-cancelled URLError is a real verdict, or the nils
        // above are satisfied by a classify that always returns nil.
        XCTAssertNotNil(PrivateServiceFetch.classify(URLError(.timedOut), cache: .empty),
            "control: a timeout is a completed failure and must classify")
    }

    // MARK: - The absence throw carries the transport account

    func testRunPopulatesTransportDetailOnTheAbsenceThrow() async {
        let error = await thrown(
            service: "social operations service",
            bases: ["http://localhost:3856"],
            userConfigured: false,
            absence: absence
        ) { _ -> PrivateServiceFetch.Outcome<String> in
            .transport("Connection refused")
        }

        guard let failure = error as? PrivateServiceFetch.Failure else {
            return XCTFail("unconfigured all-transport must throw the absence Failure")
        }
        XCTAssertEqual(failure.kind, .absence)
        guard let detail = failure.transportDetail else {
            return XCTFail("the absence throw carries no transportDetail, so a warm "
                + "pull cache reclassifying it has only the absence prose to show "
                + "inside a fault banner")
        }
        XCTAssertTrue(detail.contains("social operations service"),
            "the detail must name the service: \(detail)")
        XCTAssertTrue(detail.contains("could not reach http://localhost:3856: Connection refused"),
            "the detail must be the same per-base composition hostsDown carries: \(detail)")
    }

    func testRunZeroBasesAbsenceCarriesTheUnconfiguredDetailWhenGiven() async {
        let keySentence = "the defaults key grux.services.metaAdsBaseURLs is not set"
        do {
            _ = try await PrivateServiceFetch.run(
                service: "ads engine",
                bases: [],
                userConfigured: false,
                absenceExplanation: absence,
                unconfiguredDetail: keySentence
            ) { (_: String) -> PrivateServiceFetch.Outcome<String> in
                XCTFail("no bases exist, so nothing should be attempted")
                return .transport("unreached")
            }
            XCTFail("zero bases with an absence explanation must still throw")
        } catch let failure as PrivateServiceFetch.Failure {
            XCTAssertEqual(failure.kind, .absence)
            XCTAssertTrue(failure.transportDetail?.contains(keySentence) ?? false,
                "the zero-bases reclassified message must say which key went missing, "
                + "not count hosts nobody named: \(failure.transportDetail ?? "nil")")
        } catch {
            XCTFail("expected the absence Failure, got \(error)")
        }

        // Control: without the parameter the generic zero-bases sentence
        // stands, so the assertion above is provably the parameter's doing.
        let generic = await thrown(
            bases: [], userConfigured: false, absence: absence
        ) { _ -> PrivateServiceFetch.Outcome<String> in .transport("unreached") }
        XCTAssertTrue((generic as? PrivateServiceFetch.Failure)?
            .transportDetail?.contains("no host is configured") ?? false,
            "control: the default zero-bases detail changed shape")
    }

    // MARK: - Cancellation aborts the loop and records nothing

    func testACancelledAttemptRethrowsCancellationAndAbortsTheLoop() async {
        final class TriedBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: [String] = []
            func append(_ s: String) { lock.lock(); value.append(s); lock.unlock() }
            var tried: [String] { lock.lock(); defer { lock.unlock() }; return value }
        }
        let box = TriedBox()
        do {
            _ = try await PrivateServiceFetch.run(
                service: "test service",
                bases: ["http://one:1", "http://two:2"],
                userConfigured: false,
                absenceExplanation: absence
            ) { (url: URL) -> String in
                box.append(url.absoluteString)
                throw URLError(.cancelled)
            }
            XCTFail("a cancelled attempt must throw")
        } catch is CancellationError {
            // The one acceptable outcome: no Failure, no absence, no
            // hostsDown, just the teardown surfacing as itself.
        } catch {
            XCTFail("a cancelled request classified as \(error). Classifying it as "
                + "transport is how a torn-down recovery pull once ran the remaining "
                + "bases and fabricated an absence verdict.")
        }
        XCTAssertEqual(box.tried.count, 1,
            "cancellation must abort the loop, not fail over: \(box.tried)")

        // The sibling teardown shape: the attempt throws CancellationError
        // itself rather than URLSession's URLError form.
        do {
            _ = try await PrivateServiceFetch.run(
                service: "test service", bases: ["http://one:1"],
                userConfigured: false, absenceExplanation: absence
            ) { (_: URL) -> String in throw CancellationError() }
            XCTFail("a cancelled attempt must throw")
        } catch is CancellationError {
        } catch {
            XCTFail("CancellationError must survive the loop as itself, got \(error)")
        }
    }

    // MARK: - jsonAttempt, the one attempt body

    private struct Payload: Decodable, Equatable { let value: String }

    func testJsonAttemptDecodesA2xxAndSendsTheRequestItPromises() async throws {
        let server = try CannedServer(status: 200, reason: "OK", body: #"{"value":"fresh"}"#)
        try server.start()
        defer { server.stop() }

        let attempt = PrivateServiceFetch.jsonAttempt(Payload.self, path: "/api/digest/latest")
        let value = try await attempt(server.base)

        XCTAssertEqual(value, Payload(value: "fresh"))
        let head = server.seen.joined()
        XCTAssertTrue(head.contains("GET /api/digest/latest"),
            "the request line does not carry the method and path promised: \(head)")
        XCTAssertTrue(head.lowercased().contains("accept: application/json"),
            "every attempt must ask for JSON, exactly as the seven copies did: \(head)")
    }

    /// A trailing-slash base must not double the slash: strict routers 404
    /// "//api/..." and the 404 then reads as the notFoundMessage diagnosis,
    /// converting a healthy service into "no digest yet". The fixture server
    /// records the request line, so the path that actually went over the
    /// wire is the artifact.
    func testJsonAttemptATrailingSlashBaseStillRequestsASingleSlashPath() async throws {
        let server = try CannedServer(status: 200, reason: "OK", body: #"{"value":"fresh"}"#)
        try server.start()
        defer { server.stop() }

        let slashedBase = URL(string: server.base.absoluteString + "/")!
        let attempt = PrivateServiceFetch.jsonAttempt(Payload.self, path: "/api/digest/latest")
        let value = try await attempt(slashedBase)

        XCTAssertEqual(value, Payload(value: "fresh"))
        let head = server.seen.joined()
        XCTAssertTrue(head.contains("GET /api/digest/latest"),
            "the trailing-slash base did not produce the single-slash path: \(head)")
        XCTAssertFalse(head.contains("//api"),
            "the request line carries a doubled slash, which strict routers 404: \(head)")
    }

    func testJsonAttemptA404BecomesTheCallSitesOwnNotFoundMessage() async throws {
        let server = try CannedServer(status: 404, reason: "Not Found", body: "{}")
        try server.start()
        defer { server.stop() }

        let notFound = "service has no digest yet (404); run the nightly build"
        let attempt = PrivateServiceFetch.jsonAttempt(
            Payload.self, path: "/api/digest/latest", notFoundMessage: notFound)
        do {
            _ = try await attempt(server.base)
            XCTFail("a 404 must throw")
        } catch let error as PrivateServiceFetch.AnsweredError {
            XCTAssertEqual(error.message, notFound,
                "the call site's own 404 sentence must survive verbatim; anything else "
                + "re-forks the copies this helper collapsed")
        } catch {
            XCTFail("a 404 with a notFoundMessage must be an AnsweredError so failover "
                + "continues to the remaining bases, got \(error)")
        }
    }

    /// The control for the test above: with no notFoundMessage a 404 is just
    /// another non-2xx, named by status like the rest.
    func testJsonAttemptA404WithNoMessageFallsToTheGenericStatusShape() async throws {
        let server = try CannedServer(status: 404, reason: "Not Found", body: "{}")
        try server.start()
        defer { server.stop() }

        let attempt = PrivateServiceFetch.jsonAttempt(Payload.self, path: "/api/thing")
        do {
            _ = try await attempt(server.base)
            XCTFail("a 404 must throw")
        } catch let error as PrivateServiceFetch.AnsweredError {
            XCTAssertTrue(error.message.contains("returned HTTP 404"),
                "without a notFoundMessage the generic status shape must stand: \(error.message)")
        } catch {
            XCTFail("expected an AnsweredError, got \(error)")
        }
    }

    func testJsonAttemptANon2xxNamesTheStatusAndTheBase() async throws {
        let server = try CannedServer(status: 500, reason: "Internal Server Error", body: "boom")
        try server.start()
        defer { server.stop() }

        let attempt = PrivateServiceFetch.jsonAttempt(Payload.self, path: "/api/thing")
        do {
            _ = try await attempt(server.base)
            XCTFail("a 500 must throw")
        } catch let error as PrivateServiceFetch.AnsweredError {
            XCTAssertTrue(error.message.contains("returned HTTP 500"),
                "the status is the one fact the reader can act on: \(error.message)")
            XCTAssertTrue(error.message.contains(server.base.absoluteString),
                "the base names WHICH host answered badly, which matters exactly when "
                + "several are configured: \(error.message)")
        } catch {
            XCTFail("a non-2xx is an answered fault, not \(error)")
        }
    }

    func testJsonAttemptAURLErrorPropagatesForRunToClassifyAsTransport() async {
        let attempt = PrivateServiceFetch.jsonAttempt(Payload.self, path: "/probe")
        do {
            _ = try await attempt(URL(string: "http://127.0.0.1:1")!)
            XCTFail("nothing binds port 1, so this must throw")
        } catch is URLError {
            // Exactly what run's classification arm turns into .transport.
        } catch {
            XCTFail("a refused connection must surface as URLError untouched, got "
                + "\(error). Wrapping it would make run report a silent host as an "
                + "answered fault, which resurrects the configured-and-down lie.")
        }
    }

    func testJsonAttemptAnUnreadableBodyIsAnAnsweredErrorNamingTheCondition() async throws {
        let server = try CannedServer(status: 200, reason: "OK", body: #"{"unexpected":true}"#)
        try server.start()
        defer { server.stop() }

        let attempt = PrivateServiceFetch.jsonAttempt(Payload.self, path: "/api/thing")
        do {
            _ = try await attempt(server.base)
            XCTFail("a 2xx body that does not decode must throw")
        } catch let error as PrivateServiceFetch.AnsweredError {
            XCTAssertTrue(error.message.contains("could not read"),
                "a service that answered garbage exists and answered, and the message "
                + "must say the body was unreadable rather than hint at absence: \(error.message)")
        } catch {
            XCTFail("an undecodable body is an answered fault, not \(error)")
        }
    }

    func testJsonAttemptAPostCarriesItsBodyContentType() async throws {
        let server = try CannedServer(status: 200, reason: "OK", body: #"{"value":"ack"}"#)
        try server.start()
        defer { server.stop() }

        let attempt = PrivateServiceFetch.jsonAttempt(
            Payload.self, path: "/api/meta-ads/kill", method: "POST",
            body: Data(#"{"on":true}"#.utf8))
        _ = try await attempt(server.base)

        let head = server.seen.joined()
        XCTAssertTrue(head.contains("POST /api/meta-ads/kill"),
            "the method did not survive into the request line: \(head)")
        XCTAssertTrue(head.lowercased().contains("content-type: application/json"),
            "a body without its Content-Type is a request some services reject: \(head)")
    }

    /// The seam between the two halves: jsonAttempt throws, run classifies.
    /// A refused base then a badly answering base must surface the answered
    /// fault, proving URLError became transport and AnsweredError survived.
    func testJsonAttemptThroughRunLetsTheAnsweredHostSpeakOverSilentOnes() async throws {
        let server = try CannedServer(status: 500, reason: "Internal Server Error", body: "boom")
        try server.start()
        defer { server.stop() }

        do {
            _ = try await PrivateServiceFetch.run(
                service: "test service",
                bases: ["http://127.0.0.1:1", server.base.absoluteString],
                userConfigured: true,
                absenceExplanation: absence,
                attempt: PrivateServiceFetch.jsonAttempt(Payload.self, path: "/api/thing"))
            XCTFail("no base succeeded, so this must throw")
        } catch let error as PrivateServiceFetch.AnsweredError {
            XCTAssertTrue(error.message.contains("returned HTTP 500"),
                "the host that answered badly must speak, not the silent one: \(error.message)")
        } catch {
            XCTFail("the answered fault must outrank transport silence through the "
                + "throwing seam too, got \(error)")
        }
    }

    /// The release behaviour of the pair the sweep above proves unreachable.
    ///
    /// It used to be a `precondition`, which stays live under -O, so the day
    /// classify()'s table grew an absence-and-stale row the app would have
    /// aborted on a failed network pull rather than drawn a wrong caption.
    /// The resolver is asserted directly because the init's debug trap fires
    /// in a test build, and a crash is not a safer wrong answer than a banner.
    ///
    /// STALE WINS. Absence renders the "nothing needs fixing" card, so
    /// keeping it over a failed pull is the exact mislabel this file exists
    /// to end; dropping it lands on the fault named technically over a stale
    /// cache, which is what (.absence, .pullProven) already resolves to.
    func testTheImpossiblePairResolvesTowardTheFaultRatherThanAborting() {
        typealias C = PrivateServiceFetch.Classification
        XCTAssertFalse(C.absenceSurvives(isAbsence: true, servingStale: true),
            "the conflict kept the absence card over a stale cache, which is the "
            + "nothing-needs-fixing lie, and under -O the old precondition would "
            + "have taken the app down instead")
        // The three honest pairs are untouched, so the resolver cannot quietly
        // rewrite a verdict the table meant.
        XCTAssertTrue(C.absenceSurvives(isAbsence: true, servingStale: false),
            "a true absence lost its flag, which unmounts the notice card")
        XCTAssertFalse(C.absenceSurvives(isAbsence: false, servingStale: true))
        XCTAssertFalse(C.absenceSurvives(isAbsence: false, servingStale: false))
    }

    /// THE CLIENT'S TRUSTED SET IS A SUBSET OF THE SERVER'S, checked against
    /// the server source rather than against a comment about it.
    ///
    /// Withholding the bearer from loopback is the one change in this wave
    /// whose correctness lives OUTSIDE the repo: if the companion did not in
    /// fact trust loopback by peer address, every loopback install would 401
    /// on both the Social Ops and Brands Poster panels. The companion ships
    /// in this repo, so the claim is checkable: server.py's _post_authorized
    /// returns True for its literal peer list, and its own test pins that.
    /// Reading the file is the difference between a verified subset and a
    /// comment asserting one.
    func testTheWithheldLoopbackSetIsASubsetOfWhatTheServiceTrusts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // FOUND, NOT HARDCODED. The path carries a personal brand marker that
        // NoPersonalIdentityTests correctly refuses in shipped strings, and
        // spelling it around that guard would be evading a check rather than
        // passing it. Locating the file by what it CONTAINS also survives the
        // directory being renamed, where a hardcoded path would silently
        // stop checking anything.
        let servicesRoot = root.appendingPathComponent("mini-services")

        // ABSENT IS NOT BROKEN. `mini-services` is excluded from the extracted
        // public tree (scripts/oss-exclude.txt line 18), so the companion
        // genuinely does not ship there and this check has nothing to read.
        // That is a skip. It failed instead, and turned the public repo's CI red
        // on the 1.2.1 release commit while the same test passed here, because
        // the two trees are not the same tree.
        //
        // The distinction below is the load-bearing half and it is kept: a
        // `mini-services` that EXISTS while no longer exposing
        // `_post_authorized` is precisely the regression this test is for, and
        // still fails rather than skipping.
        guard FileManager.default.fileExists(atPath: servicesRoot.path) else {
            throw XCTSkip("mini-services is not part of this tree, so there is no companion "
                + "server to read. Excluded from the published tree by design.")
        }

        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: servicesRoot, includingPropertiesForKeys: nil)) ?? []
        let sources: [String] = candidates
            .map { $0.appendingPathComponent("server.py") }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .filter { $0.contains("_post_authorized") }
        guard let server = sources.first else {
            return XCTFail("no companion server.py exposing _post_authorized was found "
                + "under \(servicesRoot.path); this check proves nothing until it reads one")
        }
        XCTAssertEqual(sources.count, 1,
            "more than one companion authorizes POSTs, so the subset checked below may "
            + "not be the one the Social Ops client talks to")

        // The peer addresses the service waves through with no token at all.
        for trusted in ["127.0.0.1", "::1"] {
            XCTAssertTrue(server.contains("\"\(trusted)\""),
                "server.py no longer lists \(trusted) as a trusted peer, so withholding "
                + "the bearer from it 401s every loopback install on two panels")
        }
        XCTAssertTrue(server.contains("Loopback is trusted"),
            "server.py's authorization docstring changed shape; re-read _post_authorized "
            + "before trusting the client-side withhold")

        // And the client withholds from a set no wider than that.
        for host in ["http://localhost:3856", "http://127.0.0.1:3856", "http://[::1]:3856"] {
            XCTAssertTrue(SocialOpsService.authHeaders(for: URL(string: host)!).isEmpty,
                "\(host) still carries the bearer")
        }
        // A host the service does NOT trust must keep its token.
        let remote = SocialOpsService.authHeaders(for: URL(string: "http://10.0.0.5:3856")!)
        try XCTSkipIf(remote.isEmpty, "no ~/.grux/pr-inbox-token.txt on this machine")
        XCTAssertNotNil(remote["Authorization"],
            "a non-loopback host lost the bearer the service demands from it")
    }

    // MARK: - Two pulls in flight

    /// THE RACE pullAfterWrite() OPENED, and the guard that closes it.
    ///
    /// Giving the command paths an ungated pull was the right fix for
    /// read-after-write, and it introduced a second pull on the wire: a
    /// command's pull now runs beside the store's 30s poll. The MainActor
    /// orders the WRITES but not the network waits, and MetaAdsStore.apply
    /// had no ordering guard whatsoever, so a poll that started FIRST and
    /// finished LAST overwrote the fresher post-command snapshot. Worse, a
    /// poll that failed stamped an error verdict over data that had just
    /// arrived intact.
    ///
    /// Start order is what decides, not finish order, because the answer to
    /// a request describes the moment the request was made.
    func testAPullThatIsStaleOnArrivalWritesNothing() {
        var seq = PrivateServiceFetch.PullSequence()

        // The poll starts, then the command's pull starts.
        let poll = seq.begin()
        let command = seq.begin()

        // The command's pull comes back first and publishes.
        XCTAssertTrue(seq.claimWrite(command),
            "the freshest pull was refused its write, so a command could never see "
            + "the state it had just created")

        // The poll, older but slower, comes back second and must be dropped
        // ENTIRELY: this is the snapshot overwrite and the error-verdict-over
        // -good-data case in one.
        XCTAssertFalse(seq.claimWrite(poll),
            "an older pull published after a newer one, which is exactly how a 30s "
            + "poll overwrote a post-command read and stamped its failure over it")
    }

    /// THE PAIRING NO TEST COVERED, and the HIGH it let through.
    ///
    /// PullSequence was exercised in isolation and every case passed. The
    /// defect lived in the COMBINATION: `pullOnce` succeeds by claiming its
    /// write and then calling `apply`, and `apply` superseded
    /// unconditionally, so an ordinary poll retired every pull that had
    /// started after it, including the command's own read-after-write pull.
    /// A mechanism can be correct at every call and wrong in the sequence its
    /// callers actually make, which is why this test drives the sequence
    /// rather than the API.
    func testAPullsOwnPublishDoesNotRetireAPullThatStartedAfterIt() {
        var seq = PrivateServiceFetch.PullSequence()

        let poll = seq.begin()          // the 30s tick
        let command = seq.begin()       // the read-after-write, started later

        // The older poll comes back first and publishes. Its apply must NOT
        // supersede: superseding here is what discarded the command's answer.
        XCTAssertTrue(seq.claimWrite(poll))

        // The command's fresher answer must still be allowed to publish.
        XCTAssertTrue(seq.claimWrite(command),
            "the poll's own publish retired a pull that started after it, so the "
            + "command's read-after-write answer was discarded whole and the panel "
            + "kept pre-command state while the command reported .applied")
    }

    /// THE SEAM NO STORE TESTED: a push landing during a failing pull.
    ///
    /// Named by the review as the only one of the five stores' guards that
    /// could regress silently. PRDigestStore and TestDigestStore are the two
    /// with a push channel and were the last two without the start-order
    /// guard, so a push ran ingest() -> apply(), set a fresh digest and
    /// cleared the verdict, and the still-in-flight pull's failure verdict
    /// then landed on top. `servingStale` derives from "a payload exists", so
    /// the section rendered "Showing cached digest. Last pull failed" over a
    /// digest that had arrived seconds before, next to a header saying it was
    /// current: the mislabel classify() exists to prevent, written by the one
    /// path classify() does not govern.
    func testAPushDuringAFailingPullIsNotLabelledStale() {
        var seq = PrivateServiceFetch.PullSequence()

        // A pull starts and will fail slowly.
        let pull = seq.begin()

        // A push arrives while it is on the wire. apply() supersedes, because
        // a push carries no sequence of its own and is newer than anything
        // already in flight.
        seq.supersedeInFlight()

        // The pull's failure verdict is now stale on arrival and must not be
        // written: the payload on screen did not come from this pull.
        XCTAssertFalse(seq.claimWrite(pull),
            "the failing pull stamped its verdict over a digest the push had just "
            + "delivered, so the section claims a cached digest is stale while its own "
            + "header says it arrived seconds ago")
    }

    /// The echo keeps its power, which is the one case supersede exists for:
    /// it carries no sequence of its own and, in MetaAdsStore, no adoption
    /// rule either, so nothing else can order it against an older poll.
    func testACommandEchoStillRetiresThePollItOvertook() {
        var seq = PrivateServiceFetch.PullSequence()
        let poll = seq.begin()
        seq.supersedeInFlight()         // the echo publishes
        XCTAssertFalse(seq.claimWrite(poll),
            "a poll that started before the command echo published anyway, reverting "
            + "the panel to pre-command state")
    }

    /// The ordinary path is untouched: sequential pulls all publish, or the
    /// guard would freeze the panel on its first answer forever.
    func testSequentialPullsEachPublish() {
        var seq = PrivateServiceFetch.PullSequence()
        for i in 1...5 {
            let s = seq.begin()
            XCTAssertTrue(seq.claimWrite(s),
                "pull \(i) was refused its write with nothing newer in flight, which "
                + "would leave the panel frozen on whatever answered first")
        }
    }

    /// One pull, one write. A retry loop that claimed twice would let a
    /// single pass republish after a newer one had already landed.
    func testOnePullMayOnlyWriteOnce() {
        var seq = PrivateServiceFetch.PullSequence()
        let only = seq.begin()
        XCTAssertTrue(seq.claimWrite(only))
        XCTAssertFalse(seq.claimWrite(only),
            "the same pull claimed its write twice, so a later pull's result could be "
            + "overwritten by a republish of an older one")
    }

    // MARK: - Read after write

    /// A COMMAND MAY NOT AWAIT `refresh()` TO SEE ITS OWN EFFECT.
    ///
    /// `RefreshGate.run` returns immediately when a pass is already in
    /// flight: it marks the request pending and hands it to that pass. That
    /// is the coalescing, and it is correct. It also means `await refresh()`
    /// can return having pulled NOTHING, and worse, a coalesced pass may
    /// have STARTED BEFORE the write landed, so it is no evidence at all
    /// about the write.
    ///
    /// Both command stores relied on it anyway. MetaAdsStore polls every
    /// 30s, so a poll was frequently mid-flight; the ack-only path awaited
    /// `refresh()`, got nothing, returned `.applied`, and the kill switch
    /// and mode control rendered success over the pre-command value.
    /// SocialOpsStore had the same shape and relayed the stale cell to the
    /// phone as a success ack.
    ///
    /// Greps `Sources/` the way LinkStylingTests does, because this is a
    /// rule about which function a call site picks, and no runtime assertion
    /// can catch the day somebody types the wrong one back in.
    func testNoCommandPathAwaitsTheCoalescingRefresh() throws {
        let stores = ["MetaAds/MetaAdsStore.swift", "SocialOps/SocialOpsStore.swift"]
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")

        for relative in stores {
            let url = root.appendingPathComponent(relative)
            let source = try String(contentsOf: url, encoding: .utf8)

            // The command bodies begin at the control-plane mark; everything
            // above it is the pull path, where refresh() is exactly right.
            guard let mark = source.range(of: "// MARK: - Control plane")
                    ?? source.range(of: "// MARK: - Command") else {
                // No control-plane section in this store: nothing to police.
                continue
            }
            // COMMENTS STRIPPED FIRST. The prose below the mark explains the
            // hazard by name, so a naive grep flagged this file's own
            // explanation of why the call is wrong. A rule about which
            // function a call site picks has to read the call sites.
            let commandHalf = source[mark.upperBound...]
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    let trimmed = line.drop(while: { $0 == " " })
                    return trimmed.hasPrefix("//") ? "" : line
                }
                .joined(separator: "\n")
            XCTAssertFalse(commandHalf.contains("await refresh()"),
                "\(relative) awaits the coalescing refresh() below its control-plane "
                + "mark. It can return without pulling, and a coalesced pass may have "
                + "started before the write, so the command narrates from pre-command "
                + "state and reports it as success. Use the ungated pullAfterWrite().")
            XCTAssertFalse(commandHalf.contains("await self.refresh()"),
                "\(relative) awaits self.refresh() below its control-plane mark, same "
                + "defect as above")
        }
    }

    // MARK: - The section partition

    /// THE FOUR ARMS MUST COVER EVERY CELL, EXACTLY ONCE.
    ///
    /// The four private-service sections each hand-wrote the same if-chain
    /// with three arms (payload, absence card, fault line) and no arm for
    /// "no payload and no verdict". That cell is reachable on purpose:
    /// pullOnce's cancellation path records NOTHING, because recording a
    /// torn-down request is how a cancelled pull once fabricated an absence.
    /// So a section unmounted mid-pull rendered a header, a refresh button
    /// and empty space, and 2136 passing tests never saw it, because nothing
    /// drives the branch chain.
    ///
    /// This sweeps the whole (payload x verdict) space and asserts the
    /// partition is TOTAL (no blank pane) and DISJOINT (no pane drawing two
    /// things). It does not drive SwiftUI, so it cannot prove a given view
    /// wired all four arms; it proves the model those views branch on leaves
    /// no cell unaccounted for.
    func testEverySectionCellDrawsExactlyOneThing() {
        typealias C = PrivateServiceFetch.Classification
        let verdicts: [(label: String, verdict: C?)] = [
            ("no verdict (a cancelled pull records nothing)", nil),
            ("absence", C(isAbsence: true, servingStale: false, displayMessage: absence)),
            ("hosts down, empty cache", C(isAbsence: false, servingStale: false,
                                          displayMessage: "service: could not reach http://mini:1")),
            ("hosts down over a cache", C(isAbsence: false, servingStale: true,
                                          displayMessage: "service: could not reach http://mini:1")),
        ]

        for hasPayload in [true, false] {
            for (label, verdict) in verdicts {
                // The four arms exactly as the sections spell them.
                let drawsPayload = hasPayload
                let drawsAbsence = !hasPayload && (verdict?.isAbsence ?? false)
                let drawsFault = !hasPayload && verdict != nil && !(verdict?.isAbsence ?? false)
                let drawsAwaiting = PrivateServiceFetch.awaitingFirstPull(
                    hasPayload: hasPayload, verdict: verdict)

                let lit = [drawsPayload, drawsAbsence, drawsFault, drawsAwaiting]
                    .filter { $0 }.count
                XCTAssertEqual(lit, 1,
                    "payload=\(hasPayload), \(label): \(lit) arms lit, not 1. Zero is the "
                    + "blank panel this wave exists to remove; two is a pane saying two "
                    + "things at once")
            }
        }
    }

    /// THE RESCUE'S INVARIANT, asserted as an invariant.
    ///
    /// Two attempts at this rescue failed. Clearing `pending` and spawning
    /// unconditionally let a competitor serve the owed request and the rescue
    /// run a second pass behind it. Leaving `pending` up was no better,
    /// because `run` inspects only `inFlight`: the rescue either ran a
    /// redundant pass or re-raised the flag and made the competitor's loop
    /// run one. A pass counter captured before the handoff settles it.
    ///
    /// COUNTED AS A BOUND, NOT AS A NUMBER. The first version of this test
    /// asserted an exact pass count and failed against CORRECT code, because
    /// which of the rescue and the competitor wins the gap is not something a
    /// test can pin, and both orderings are legitimate with different totals.
    /// The property that actually matters holds either way: no pass runs that
    /// nobody asked for.
    @MainActor
    func testTheRescueNeverRunsAPassNobodyAskedFor() async {
        final class Log { var passes = 0; var fetching: [Bool] = [] }
        let log = Log()
        let gate = RefreshGate()
        var requests = 0
        let isFetching: @MainActor (Bool) -> Void = { log.fetching.append($0) }
        let pass: @MainActor () async -> Void = {
            log.passes += 1
            if log.passes == 1 {
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            }
        }

        let first = Task { @MainActor in await gate.run(isFetching: isFetching, pass: pass) }
        requests += 1
        var waited = 0
        while log.passes < 1, waited < 200 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }
        XCTAssertEqual(log.passes, 1, "the first pass never started")

        await gate.run(isFetching: isFetching, pass: pass)   // coalesces behind it
        requests += 1
        XCTAssertEqual(log.passes, 1, "the second caller ran its own pass instead of coalescing")

        // Cancel the awaiter, then race a competitor into the handoff gap.
        first.cancel()
        await first.value
        await gate.run(isFetching: isFetching, pass: pass)
        requests += 1

        waited = 0
        while waited < 60 { try? await Task.sleep(nanoseconds: 10_000_000); waited += 1 }

        XCTAssertLessThanOrEqual(log.passes, requests,
            "\(log.passes) passes ran for \(requests) requests: a pass ran that nobody "
            + "asked for, which is a duplicate HTTP pull with isFetching held across it "
            + "on a singleton up to seven views observe")
        XCTAssertGreaterThanOrEqual(log.passes, 2,
            "the request coalesced behind the cancelled pass was dropped, which is the "
            + "hole every hand-copied scaffold shared")
        XCTAssertEqual(log.fetching.last, false,
            "isFetching was left raised after every pass completed")
    }

    // MARK: - Per-base auth scoping

    /// The companion service trusts loopback BY PEER ADDRESS and never reads
    /// the header there (server.py:296, pinned by its own
    /// test_loopback_is_trusted_without_token), so Grux must not hand it the
    /// shared secret. It used to: `authHeaders()` was a standing dictionary
    /// computed once and applied to every base the failover loop walked, so
    /// the token went onto a socket any local process can bind whenever the
    /// companion is not running, while this file's own comment claimed
    /// "loopback calls do not require it".
    ///
    /// Deterministic whether or not this machine has a token file: the
    /// loopback answer is empty either way.
    func testTheBearerTokenIsWithheldFromTheLoopbackTheServiceTrustsWithoutIt() {
        for spelling in ["http://localhost:3856", "http://LocalHost:3856",
                         "http://127.0.0.1:3856", "http://[::1]:3856"] {
            let base = URL(string: spelling)!
            XCTAssertTrue(SocialOpsService.authHeaders(for: base).isEmpty,
                "\(spelling) was handed the shared bearer secret, which the service "
                + "never reads from a loopback peer and any local listener can take")
        }
    }

    /// The other half, and the reason this is a scoping change rather than a
    /// removal: the service REQUIRES the bearer from every non-loopback peer,
    /// so withholding it there would 401 the documented configuration.
    func testANonLoopbackBaseStillCarriesTheTokenWhenTheInstallHasOne() throws {
        let remote = URL(string: "http://10.0.0.5:3856")!
        let headers = SocialOpsService.authHeaders(for: remote)
        try XCTSkipIf(headers.isEmpty,
                      "no ~/.grux/pr-inbox-token.txt on this machine, so there is "
                      + "no token to prove reaches a remote base")
        XCTAssertTrue(headers["Authorization"]?.hasPrefix("Bearer ") == true,
            "a configured remote host lost the bearer the service demands from it: \(headers)")
    }

    /// The plumbing the scoping rests on: `jsonAttempt` must call the header
    /// function with the base it is ABOUT TO REQUEST, not with some base
    /// resolved once for the whole loop. A dictionary computed once is
    /// exactly the shape that leaked, so the per-base call is asserted
    /// against the request that actually went over the wire.
    func testJsonAttemptAsksTheHeaderFunctionAboutTheBaseItIsRequesting() async throws {
        let server = try CannedServer(status: 200, reason: "OK", body: #"{"value":"fresh"}"#)
        try server.start()
        defer { server.stop() }

        let attempt = PrivateServiceFetch.jsonAttempt(
            Payload.self,
            path: "/api/digest/latest",
            headers: { ["X-Base-Seen": $0.absoluteString] })
        _ = try await attempt(server.base)

        let head = server.seen.joined()
        XCTAssertTrue(head.contains("X-Base-Seen: \(server.base.absoluteString)"),
            "the header function was not called with the base being requested, so a "
            + "per-base credential decision cannot be trusted: \(head)")
    }

    // MARK: - RefreshGate

    /// A deterministic handoff between the test and the pass running inside
    /// the gate: the pass parks, the test wakes on `arrived()`, makes its move
    /// (coalesce a request, cancel the awaiter), then `release()`s the pass.
    /// Continuations rather than sleeps, so every cell below is a fixed
    /// sequence instead of a race a loaded machine can lose.
    @MainActor
    private final class PassBaton {
        private var parked: CheckedContinuation<Void, Never>?
        private var waiting: CheckedContinuation<Void, Never>?
        private var isParked = false

        func park() async {
            isParked = true
            waiting?.resume()
            waiting = nil
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                self.parked = c
            }
        }

        func arrived() async {
            guard !isParked else { return }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                self.waiting = c
            }
        }

        func release() {
            isParked = false
            parked?.resume()
            parked = nil
        }
    }

    /// What one cell of the grid observed.
    @MainActor
    private final class GateLog {
        var passes = 0
        var requests = 0
        /// The pass count at the moment each request arrived. Invariant 1 is
        /// "the count moved past every one of these".
        var passesAtRequest: [Int] = []
        var fetching: [Bool] = []
        var awaiter: Task<Void, Never>?
        var parkNextPass = false
        var cancelAsPassReturns = false
    }

    /// Where the awaiter's teardown lands, which is the axis every one of the
    /// hand-built scaffolds picked one point on.
    private enum GateCancel: String, CaseIterable {
        case never
        case beforeThePassStarts
        case duringThePass
        case asThePassReturns
    }

    /// Runs one cell. The pass the cell is ABOUT is held parked while the cell
    /// makes its move; every other pass runs straight through.
    @MainActor
    private func runGateCell(coalesced: Bool, pendingDuringPass: Bool,
                             cancel: GateCancel) async -> GateLog {
        let gate = RefreshGate()
        let baton = PassBaton()
        let log = GateLog()

        let isFetching: @MainActor (Bool) -> Void = { log.fetching.append($0) }
        let pass: @MainActor () async -> Void = {
            log.passes += 1
            if log.parkNextPass { await baton.park() }
            if log.cancelAsPassReturns {
                // The teardown landing on the pass's own last instruction:
                // the closest a test can stand to "the pass finished, then
                // the card unmounted" without reaching for a wall clock.
                log.cancelAsPassReturns = false
                log.awaiter?.cancel()
            }
        }
        // A sibling caller: a poll tick, a second card, a manual Refresh. It
        // coalesces, because the observed pass is parked and holds the gate.
        func sibling() async {
            log.requests += 1
            log.passesAtRequest.append(log.passes)
            await gate.run(isFetching: isFetching, pass: pass)
        }

        // The awaiter: a store's refresh() inside a card's structured .task.
        log.requests += 1
        log.passesAtRequest.append(log.passes)
        log.parkNextPass = true
        log.awaiter = Task { @MainActor in
            await gate.run(isFetching: isFetching, pass: pass)
        }
        if cancel == .beforeThePassStarts, !coalesced { log.awaiter?.cancel() }
        await baton.arrived()

        if coalesced {
            // The sibling's request, and the COALESCED pass it is owed is the
            // one this cell observes.
            await sibling()
            if cancel == .beforeThePassStarts { log.awaiter?.cancel() }
            baton.release()
            await baton.arrived()
        }

        // The observed pass is parked and everything below is about IT.
        if pendingDuringPass { await sibling() }
        switch cancel {
        case .duringThePass: log.awaiter?.cancel()
        case .asThePassReturns: log.cancelAsPassReturns = true
        case .never, .beforeThePassStarts: break
        }
        log.parkNextPass = false
        baton.release()
        await log.awaiter?.value
        // A follow-up runs in a FRESH unstructured task, so awaiting the
        // awaiter proves nothing about it. Yields rather than a sleep: a
        // yield puts this task behind everything already enqueued on the
        // main actor, which is exactly where a rescue is sitting.
        for _ in 0..<32 { await Task.yield() }
        return log
    }

    /// The gate's whole grid, replacing the one-scaffold-per-fixed-bug tests
    /// that rounds 5, 6 and 7 each added and round 8 found a hole beside
    /// anyway. Every cell of (a request pending or not) x (the running pass is
    /// coalesced or not) x (the teardown lands before the pass starts, during
    /// it, as it returns, or never) runs the SAME two assertions, so a hole
    /// now has to be a hole in the invariants rather than in which scenario
    /// somebody thought to write down.
    ///
    /// INVARIANT 1, NO CALLER'S REQUEST IS EVER DROPPED. Every request has a
    /// pass START after it arrives, checked by recording the pass count at
    /// each request and requiring the final count to have moved past it. The
    /// drop this pins is real and shipped twice: the absence card's recovery
    /// fires are one-shot, so a fire consumed by a pass that never ran for it
    /// left the card stood down over a stale panel with nobody left to ask.
    ///
    /// INVARIANT 2, NO PASS RUNS THAT NOBODY IS OWED. The total number of
    /// passes never exceeds the number of distinct requests. A pass nobody
    /// asked for is a full extra HTTP pull with isFetching held true across it
    /// on a singleton seven views observe.
    ///
    /// A STARTED pass settles a request, not a COMPLETED one, and the gate
    /// cannot make it the other way round: `pass` is a plain non-throwing
    /// closure, so a pass cut short by cancellation and a pass that ran to the
    /// end are the same event from inside the gate. Invariant 2 is what forces
    /// the choice. Settling on completion would fire a rescue after every
    /// coalesced pass that was cancelled at any point, including one whose
    /// work had already landed, and that is the extra pull above. The cost of
    /// this direction is one stale panel until the next poll tick, and it is
    /// the cheaper of the two.
    @MainActor
    func testTheRefreshGateHoldsBothInvariantsInEveryCancellationCell() async {
        for coalesced in [false, true] {
            for pendingDuringPass in [false, true] {
                for cancel in GateCancel.allCases {
                    let cell = "coalesced=\(coalesced) pending=\(pendingDuringPass) "
                        + "cancel=\(cancel.rawValue)"
                    let log = await runGateCell(coalesced: coalesced,
                                                pendingDuringPass: pendingDuringPass,
                                                cancel: cancel)

                    for (n, before) in log.passesAtRequest.enumerated() {
                        XCTAssertGreaterThan(log.passes, before,
                            "\(cell): request \(n + 1) arrived with \(before) passes run and the "
                            + "run ended on \(log.passes), so no pass ever started for it and a "
                            + "poll tick or a Refresh press died inside another caller's teardown")
                    }

                    XCTAssertLessThanOrEqual(log.passes, log.requests,
                        "\(cell): \(log.passes) passes for \(log.requests) requests, so a full "
                        + "pull ran that nobody asked for, with isFetching held true across it "
                        + "on a singleton seven views observe")

                    XCTAssertEqual(log.fetching.last, false,
                        "\(cell): isFetching never came back down: \(log.fetching)")
                    XCTAssertTrue(log.fetching.dropLast().allSatisfy { $0 },
                        "\(cell): isFetching read false while a pass was still owed: "
                        + "\(log.fetching). Seven UI sites render the spinner and the Refresh "
                        + "button off this flag, so a false in the handoff window says the pull "
                        + "is over while its follow-up is being enqueued")
                }
            }
        }
    }

    /// The control for the grid above: its two invariants must be capable of
    /// failing. A gate that ran a pass per request and never coalesced would
    /// satisfy invariant 1 and break invariant 2, and one that dropped every
    /// coalesced request would do the reverse, so this pins that the counts
    /// the grid reads are the real ones rather than a scaffold that always
    /// agrees with itself.
    @MainActor
    func testTheGridCountsCoalescingRatherThanAlwaysAgreeingWithItself() async {
        let log = await runGateCell(coalesced: true, pendingDuringPass: true, cancel: .never)
        XCTAssertEqual(log.requests, 3,
            "the cell did not make the three requests the grid believes it makes")
        XCTAssertEqual(log.passes, 3,
            "three requests, each arriving while the previous pass held the gate, owe exactly "
            + "three passes: fewer is a drop, more is a queue")
        XCTAssertEqual(log.passesAtRequest, [0, 1, 2],
            "the requests did not land one per in-flight pass, so the cell is not exercising "
            + "the coalescing seam it claims to")
    }
}

/// A loopback HTTP server answering one canned response and recording what it
/// was asked. Same idiom as OllamaCapabilityTests' TagsServer: real socket,
/// real URLSession, no mocking of the transport under test.
private final class CannedServer: @unchecked Sendable {
    private let listener: NWListener
    private let status: Int
    private let reason: String
    private let body: String
    private let lock = NSLock()
    private var requests: [String] = []

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var seen: [String] { lock.lock(); defer { lock.unlock() }; return requests }

    init(status: Int, reason: String, body: String) throws {
        self.status = status
        self.reason = reason
        self.body = body
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }
                                        if case .failed = $0 { ready.signal() } }
        listener.newConnectionHandler = { [status, reason, body] conn in
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if let data { self.record(String(decoding: data, as: UTF8.self)) }
                let resp = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            throw NSError(domain: "CannedServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
    }

    private func record(_ request: String) {
        lock.lock(); requests.append(request); lock.unlock()
    }

    func stop() { listener.cancel() }
}
