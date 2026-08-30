import Network
import XCTest
@testable import Grux

/// Store-level proof of MetaAdsStore's two error channels, driven through the
/// store's real config seam (the base-URL defaults key) rather than a test
/// double: an empty key IS the absence condition and costs no network, and a
/// loopback port nothing can listen on (1 is privileged) refuses instantly for
/// the configured-and-down case.
///
/// THE REGRESSION THIS GUARDS: a failed Emergency Stop used to land in
/// lastError, and the next 30s poll tick began by clearing lastError, so the
/// only evidence a kill never applied evaporated within one tick while the
/// stale snapshot kept rendering as if the engine had obeyed. The command
/// channel is separate and a refresh must never touch it.
final class MetaAdsStoreErrorChannelTests: XCTestCase {

    /// Runs body with the ads-engine defaults key forced to a value (nil
    /// removes it), restoring whatever the machine had afterwards so the test
    /// never leaks config into the rest of the suite or the developer's own
    /// defaults domain.
    private func withBases(_ value: String?, _ body: @MainActor () async -> Void) async {
        let key = MetaAdsService.baseURLsDefaultsKey
        let saved = UserDefaults.standard.string(forKey: key)
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        await body()
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @MainActor
    func testACommandFaultSurvivesARefreshAndAbsenceSetsTheTypedFlag() async {
        await withBases(nil) {
            let store = MetaAdsStore.shared

            // A kill that cannot be delivered writes the command channel, and
            // its message keeps the config pointer (the defaults key) so the
            // reader knows where a host goes.
            _ = await store.setKill(on: true)
            let commandError = store.commandError
            XCTAssertNotNil(commandError,
                "an undeliverable Emergency Stop left commandError nil, which is the invisible-kill defect")
            XCTAssertTrue(commandError?.contains(MetaAdsService.baseURLsDefaultsKey) ?? false,
                "the zero-bases command message lost its config pointer: \(commandError ?? "nil")")

            // A refresh is the 30s poll tick. It owns lastError, never the
            // command channel.
            await store.refresh()
            XCTAssertEqual(store.commandError, commandError,
                "refresh() erased a command fault; a never-applied kill must stay visible until acted on")

            // With nothing configured, the pull failure itself is typed
            // absence, not a fault.
            XCTAssertNotNil(store.lastError,
                "the unconfigured pull should still record why it returned nothing")
            XCTAssertTrue(store.lastErrorIsAbsence,
                "an unconfigured install's pull failure must carry the absence kind, or every fresh install renders a warning banner")

            // The next command attempt owns the channel again: cleared at its
            // start, then set by this attempt's own outcome (undeliverable
            // here too, so it ends set rather than nil).
            _ = await store.setMode(brand: "brand", mode: "OBSERVE")
            XCTAssertNotNil(store.commandError,
                "the second undeliverable command should have written the channel it had just cleared")
        }
    }

    @MainActor
    func testAConfiguredHostBeingDownIsNotAbsence() async {
        await withBases("http://127.0.0.1:1") {
            let store = MetaAdsStore.shared
            await store.refresh()
            XCTAssertNotNil(store.lastError,
                "a configured host refusing the connection should record a pull error")
            XCTAssertFalse(store.lastErrorIsAbsence,
                "a configured host being down is a real condition the user can act on, never absence")
        }
    }

    /// The command banner's exit. Its branch outranks the fetch banner and a
    /// refresh never clears it, so before acknowledgeCommandError() existed a
    /// stale command fault suppressed every newer genuine fetch failure until
    /// the next command or app relaunch.
    @MainActor
    func testAcknowledgingACommandFaultClearsTheChannelAndAFetchFaultCanSurface() async {
        await withBases("http://127.0.0.1:1") {
            let store = MetaAdsStore.shared

            // An undeliverable kill writes the command channel.
            _ = await store.setKill(on: true)
            XCTAssertNotNil(store.commandError,
                "an undeliverable Emergency Stop should have written the command channel")

            // Acknowledging is the user dismissing the banner: the channel
            // clears without waiting for the next command attempt.
            store.acknowledgeCommandError()
            XCTAssertNil(store.commandError,
                "acknowledgeCommandError() must clear the command channel")

            // With the channel clear, a genuine fetch failure records itself
            // and nothing resurrects the acknowledged command fault, so the
            // fetch banner (keyed on commandError == nil) can finally show it.
            await store.refresh()
            XCTAssertNotNil(store.lastError,
                "the configured-and-down pull after acknowledgment should record its own error")
            XCTAssertFalse(store.lastErrorIsAbsence,
                "a configured host being down stays a real fault after an acknowledgment")
            XCTAssertNil(store.commandError,
                "a refresh must never resurrect an acknowledged command fault")
        }
    }

    /// A torn-down refresh writes NOTHING. The recovery card awaits the
    /// store's refresh from its own .task, so unmounting cancels the pull
    /// mid-request, and before the cancellation arms existed the cancelled
    /// request classified as transport and recorded a fabricated verdict on
    /// this singleton. Driven through a real listener that accepts and never
    /// answers, so the pull is provably in flight when the task is cancelled.
    @MainActor
    func testACancelledPullLeavesEveryErrorFieldUntouched() async throws {
        let store = MetaAdsStore.shared

        // Seed a known verdict first: a configured host that refuses.
        await withBases("http://127.0.0.1:1") {
            await store.refresh()
        }
        let seededError = store.lastError
        let seededAbsence = store.lastErrorIsAbsence
        let seededStale = store.servingStale
        XCTAssertNotNil(seededError, "the seed refresh should have recorded a verdict")

        let silent = try SilentServer()
        try silent.start()
        defer { silent.stop() }

        await withBases("http://127.0.0.1:\(silent.port)") {
            let pull = Task { @MainActor in await store.refresh() }
            // Let the request reach the listener, then tear the task down.
            try? await Task.sleep(nanoseconds: 300_000_000)
            pull.cancel()
            await pull.value
        }

        XCTAssertEqual(store.lastError, seededError,
            "a cancelled pull rewrote lastError, so a torn-down recovery task is "
            + "still fabricating verdicts")
        XCTAssertEqual(store.lastErrorIsAbsence, seededAbsence,
            "a cancelled pull flipped the absence flag")
        XCTAssertEqual(store.servingStale, seededStale,
            "a cancelled pull flipped the stale flag")
        XCTAssertFalse(store.isFetching,
            "the cancelled refresh must still release its in-flight guard")
    }

    /// The refresh guard became a COALESCE. The old guard-return silently
    /// consumed a request arriving mid-pull, and the absence card's recovery
    /// fires are one-shot (probeLoop fires once per transition), so a fire
    /// landing mid-pull evaporated with nothing left to re-fire. Driven
    /// through a listener that counts requests and answers slowly, so the
    /// swallowed-request window is provably open when the extra requests
    /// arrive: N requests during one pull must produce exactly one follow-up
    /// pass, never zero (the old drop) and never N (a queue).
    @MainActor
    func testARefreshArrivingMidPullRunsExactlyOneCoalescedFollowUp() async throws {
        let server = try SlowCountingServer(delay: 1.5)
        try server.start()
        defer { server.stop() }

        await withBases("http://127.0.0.1:\(server.port)") {
            let store = MetaAdsStore.shared
            let first = Task { @MainActor in await store.refresh() }
            // Wait until the first request is provably at the listener before
            // making the requests the old guard used to swallow.
            var waited = 0
            while server.requestCount < 1, waited < 100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            XCTAssertGreaterThanOrEqual(server.requestCount, 1,
                "the first pull never reached the listener, so nothing below is in flight")

            await store.refresh()
            await store.refresh()
            XCTAssertTrue(store.isFetching,
                "both mid-pull requests should return immediately, coalesced behind the "
                + "in-flight pass rather than awaiting their own")

            _ = await first.value
            XCTAssertEqual(server.requestCount, 2,
                "two requests during one in-flight pull must coalesce into exactly one "
                + "follow-up pass")
            XCTAssertFalse(store.isFetching,
                "the coalesced pass must release the in-flight flag when it completes")

            // Nothing left pending: a pass running with nobody asking is the
            // refresh storm the single-Bool shape exists to prevent.
            try? await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(server.requestCount, 2,
                "a further pass ran after the coalesced one with nobody asking")
        }
    }

    /// A cancelled command writes NOTHING, at both seams. The hand-rolled
    /// post() closure used to classify URLError(.cancelled) as .transport, so
    /// the loop completed and threw a hostsDown Failure, and the store's
    /// catch, which had no cancellation arm, stamped that fabricated fault
    /// into commandError for a command nothing refused.
    @MainActor
    func testACancelledCommandRethrowsCancellationAndStampsNoFault() async throws {
        let silent = try SilentServer()
        try silent.start()
        defer { silent.stop() }

        await withBases("http://127.0.0.1:\(silent.port)") {
            // Service seam: the teardown must surface as CancellationError,
            // never as a transport or answered verdict.
            let call = Task { try await MetaAdsService.setKill(on: true) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            call.cancel()
            do {
                _ = try await call.value
                XCTFail("a cancelled command must throw")
            } catch is CancellationError {
                // The one acceptable outcome: the teardown as itself.
            } catch {
                XCTFail("a cancelled command classified as \(error), which is the "
                    + "fabricated verdict the rethrow arms remove")
            }

            // Store seam: the cancellation arm writes nothing.
            let store = MetaAdsStore.shared
            store.acknowledgeCommandError()
            let cmd = Task { @MainActor in await store.setKill(on: true) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            cmd.cancel()
            _ = await cmd.value
            XCTAssertNil(store.commandError,
                "a cancelled command stamped a fabricated fault into commandError")
            XCTAssertFalse(store.isMutating,
                "the cancelled command must still release its in-flight guard")
        }
    }

    /// A command REFUSED for being second in line says so. The in-flight
    /// guard used to be a bare `return`, so a press landing while another
    /// command was still being applied produced no error, no change and no
    /// affordance. On the Emergency Stop that is the worst silence in the
    /// tab: somebody hits the kill switch, the engine keeps spending, and
    /// nothing on screen suggests hitting it again. Driven through a listener
    /// that accepts and never answers, so the first command is provably still
    /// in flight when the second arrives.
    @MainActor
    func testACommandArrivingWhileAnotherIsInFlightIsRefusedOutLoud() async throws {
        let silent = try SilentServer()
        try silent.start()
        defer { silent.stop() }

        await withBases("http://127.0.0.1:\(silent.port)") {
            let store = MetaAdsStore.shared
            store.acknowledgeCommandError()

            let first = Task { @MainActor in await store.setKill(on: true) }
            var waited = 0
            while !store.isMutating, waited < 100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            XCTAssertTrue(store.isMutating,
                "the first command never took the in-flight guard, so nothing below is "
                + "exercising the refusal")

            // The press the old guard swallowed. STILL refused out loud; the
            // out-loud moved from the shared channel to the RETURN TYPE.
            // Transient advice in a sticky channel is what four consecutive
            // rounds each added a clearing rule for, and what the views then
            // copied into @State where no clearing rule reached it.
            let refused = await store.setMode(brand: "brand", mode: "OBSERVE")
            XCTAssertEqual(refused, .refused(MetaAdsStore.commandInFlightMessage),
                "a command refused for being second in line vanished with no verdict and "
                + "no affordance, which is the invisible-kill defect one layer up")
            XCTAssertNil(store.commandError,
                "the refusal was published into the sticky fault channel, where its advice "
                + "outlives the command it describes and no reader clears it")

            // The refusal must not be mistaken for the first command failing:
            // that one is still in flight and has recorded nothing.
            XCTAssertTrue(store.isMutating,
                "the refused press released somebody else's in-flight guard")

            first.cancel()
            _ = await first.value
        }
        MetaAdsStore.shared.acknowledgeCommandError()
    }

    /// A SUCCESSFUL COMMAND CLEARS THE STANDING FAULT.
    ///
    /// The channel's own doc always promised this and nothing did it. Round
    /// 13 removed the clear-on-START, correctly (it erased a failed Emergency
    /// Stop the moment any unrelated command was dispatched, before that
    /// command had any verdict), and added no clear anywhere else. So a
    /// control that failed once wore its amber banner over every subsequent
    /// success, MetaAdsKillSwitch cleared its own local copy on .applied and
    /// the two surfaces openly disagreed, and worst of all MetaAdsView and
    /// MetaAdsOpsSection gate the absence card and the empty state on
    /// commandError == nil, so on a fresh install one failed command
    /// permanently suppressed the explanatory empty state.
    ///
    /// It shipped green because this suite covered the acknowledge path and
    /// the cancellation path and never once asserted the success path.
    @MainActor
    func testASuccessfulCommandClearsAStandingFault() async throws {
        let store = MetaAdsStore.shared

        // A fault, from a base nothing is listening on.
        await withBases("http://127.0.0.1:1") {
            _ = await store.setKill(on: true)
        }
        XCTAssertNotNil(store.commandError,
            "an undeliverable Emergency Stop should have written the command channel, "
            + "so nothing below is exercising the clear")

        // The same command against an engine that answers.
        let ack = try AckServer()
        try ack.start()
        defer { ack.stop() }
        await withBases("http://127.0.0.1:\(ack.port)") {
            let outcome = await store.setKill(on: true)
            XCTAssertEqual(outcome, .applied,
                "the ack-answering engine did not produce an applied verdict, so the "
                + "clear below would be proving nothing")
        }

        XCTAssertNil(store.commandError,
            "a command the engine APPLIED left the previous failure's banner standing, "
            + "which also keeps the absence card and the empty state suppressed on a "
            + "fresh install until the reader finds the dismiss control")
        store.acknowledgeCommandError()
    }

    /// A FAILED EMERGENCY STOP OUTLIVES A LATER FAILURE, not just a later
    /// success.
    ///
    /// Halt stickiness guarded only the success door. The catch arm wrote
    /// commandError and commandErrorIsHalt unconditionally, so a halt that
    /// failed against an unreachable engine was evicted by the very next
    /// command that ALSO failed, and MetaAdsView and MetaAdsOpsSection render
    /// only commandError, so the record that the kill switch never reached
    /// the engine left every surface unacknowledged while spend continued.
    /// Same loss the rule was written to prevent, through the other door.
    ///
    /// The later fault is not swallowed: it comes back to its own caller as
    /// .failed(...) and that surface renders it. What it may not do is take
    /// the halt's place in the channel four views read.
    @MainActor
    func testAFailedHaltIsNotEvictedByALaterFailure() async {
        let store = MetaAdsStore.shared
        store.acknowledgeCommandError()

        await withBases("http://127.0.0.1:1") {
            let halt = await store.setKill(on: true)
            guard case .failed(let haltMessage) = halt else {
                return XCTFail("the undeliverable halt did not produce a failed verdict")
            }
            XCTAssertEqual(store.commandError, haltMessage,
                "the failed halt never reached the channel, so nothing below is "
                + "exercising its stickiness")

            // An unrelated command that also fails.
            let approve = await store.runCommand("approve") {
                _ = try await MetaAdsService.approveMove(id: "move-1")
                return false
            }
            guard case .failed(let approveMessage) = approve else {
                return XCTFail("the undeliverable approve did not produce a failed verdict")
            }

            XCTAssertEqual(store.commandError, haltMessage,
                "a later failure evicted the failed Emergency Stop from the shared "
                + "channel, so the surfaces that render only commandError lost the "
                + "record that the kill switch never landed")
            XCTAssertNotEqual(store.commandError, approveMessage,
                "the approve's own fault took the halt's place in the channel")
        }
        store.acknowledgeCommandError()
    }

    /// DISMISSING A FAILED HALT MUST NOT DEAFEN THE CHANNEL.
    ///
    /// The stickiness rule is checked on BOTH the success and the catch arm,
    /// so a commandErrorIsHalt left standing after the reader dismissed the
    /// banner made every later non-halt fault evaluate `!true || false` and
    /// never be written at all: no banner on either surface, for the process
    /// lifetime, recoverable only by attempting another halt. A rule meant to
    /// keep ONE fault visible hid all the others.
    ///
    /// The suite missed it because the success-clears test uses a halt for
    /// both the fault and the clear, so the flag happened to be reset by the
    /// `isHalt` arm of the same condition.
    @MainActor
    func testDismissingAHaltFaultLetsLaterFaultsSpeakAgain() async {
        let store = MetaAdsStore.shared
        store.acknowledgeCommandError()

        await withBases("http://127.0.0.1:1") {
            _ = await store.setKill(on: true)
            XCTAssertNotNil(store.commandError, "the halt fault never reached the channel")

            // The reader dismisses it. That IS acting on it.
            store.acknowledgeCommandError()
            XCTAssertNil(store.commandError)

            // A later, unrelated command fails. It must be able to speak.
            let approve = await store.runCommand("approve") {
                _ = try await MetaAdsService.approveMove(id: "move-1")
                return false
            }
            guard case .failed(let message) = approve else {
                return XCTFail("the undeliverable approve did not produce a failed verdict")
            }
            XCTAssertEqual(store.commandError, message,
                "the channel stayed deaf after a dismissed halt fault, so no later "
                + "command fault can ever reach the two surfaces that render it")
        }
        store.acknowledgeCommandError()
    }

    /// The removed-key story, end to end minus the store's three assignment
    /// lines: with the defaults key unset the service throws typed absence
    /// whose transportDetail NAMES the key, and classify's pull-proven row
    /// surfaces exactly that detail. Before this, a user who removed their
    /// key over a warm cache read hostsDown-style copy counting zero bases,
    /// with a Retry that could never succeed.
    @MainActor
    func testTheRemovedKeyReclassificationNamesTheDefaultsKey() async {
        await withBases(nil) {
            do {
                _ = try await MetaAdsService.fetchLatest()
                XCTFail("an unconfigured fetch must throw")
            } catch let failure as PrivateServiceFetch.Failure {
                XCTAssertEqual(failure.kind, .absence,
                    "unconfigured is absence at the throw site; the cache decides the rest")
                XCTAssertTrue(
                    failure.transportDetail?.contains(MetaAdsService.baseURLsDefaultsKey) ?? false,
                    "the absence throw's transportDetail must name the config key: "
                    + "\(failure.transportDetail ?? "nil")")

                // The warm-cache half, at the classify seam (warming the real
                // singleton would persist into this machine's cache files).
                guard let verdict = PrivateServiceFetch.classify(failure, cache: .pullProven) else {
                    return XCTFail("a completed absence throw classified as nil")
                }
                XCTAssertFalse(verdict.isAbsence,
                    "absence over a pull-proven snapshot is an outage, not absence")
                XCTAssertTrue(verdict.servingStale)
                XCTAssertEqual(verdict.displayMessage, failure.transportDetail,
                    "the surfaced message must be the actionable key sentence, never the "
                    + "absence prose under a warning triangle")
            } catch {
                XCTFail("expected the typed absence Failure, got \(error)")
            }
        }
    }

    /// ONE FLAG GOVERNS EVERY CONTROL-PLANE POST, proven in both directions.
    ///
    /// The `.disabled(locked || store.isMutating)` on the mode segments and
    /// on the action bar's buttons claimed two control-plane writes could
    /// never race. They could. isMutating was raised only by setMode and
    /// setKill, whose one caller was the Emergency Stop button, while the
    /// mode control, the action bar, the kill card and the variant spawner
    /// posted to MetaAdsService directly behind @State flags private to a
    /// single view instance. Pressing AUTONOMOUS held a POST open for up to
    /// 12s per base with Emergency Stop live beside it the whole time, which
    /// is the exact race the disabled state was added to close.
    ///
    /// Driven through a listener that accepts and never answers, so the first
    /// write is provably still in flight when the second arrives.
    @MainActor
    func testEveryControlPlaneWriteTakesTheSameInFlightFlag() async throws {
        let silent = try SilentServer()
        try silent.start()
        defer { silent.stop() }

        await withBases("http://127.0.0.1:\(silent.port)") {
            let store = MetaAdsStore.shared
            store.acknowledgeCommandError()

            // The seam the action bar and the variant spawner now use. It
            // must raise the flag the Emergency Stop reads.
            let bar = Task { @MainActor in
                await store.runCommand("pause") {
                    _ = try await MetaAdsService.pauseAd(brand: "examplebrand", nodeId: "node-1")
                    return false   // publishes nothing; runCommand owes the pull
                }
            }
            var waited = 0
            while !store.isMutating, waited < 100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            XCTAssertTrue(store.isMutating,
                "an override POST left isMutating false, so every other control surface in the "
                + "tab stayed enabled beside an in-flight write")

            // THE HALT IS THE ONE EXEMPTION, and this assertion reversed on
            // purpose. It used to demand the kill switch be refused mid-write
            // like anything else. Routing every command through one gate then
            // handed that guard a veto over Emergency Stop: Force scale holds
            // a POST open for up to 12s PER BASE and awaits a refresh for as
            // long again, so STOP ALL pressed in that window was answered
            // "wait for it to finish, then try again". On an ad-spend kill
            // switch that is the wrong resolution in the only moment the
            // control exists for, so a halt now goes out beside whatever is
            // running. It is fail-safe (it only ever pauses), so the worst
            // ordering leaves the engine paused.
            // Launched rather than awaited, because the halt is no longer
            // refused instantly: it goes out and blocks for the full POST
            // timeout, by which point the override it overtook has timed out
            // too. The flag has to be read while BOTH are provably in flight.
            let haltTask = Task { @MainActor in await store.setKill(on: true) }
            try? await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertTrue(store.isMutating,
                "the halt lowered a guard it never raised, so every control in the tab "
                + "came back live beside an override still on the wire")
            let halt = await haltTask.value
            XCTAssertNotEqual(halt, .failed(MetaAdsStore.commandInFlightMessage),
                "the Emergency Stop was refused for being second in line, which is a "
                + "dead kill switch for as long as an unrelated command runs")

            bar.cancel()
            _ = await bar.value
            XCTAssertFalse(store.isMutating,
                "the cancelled override never released the guard, which would wedge every "
                + "control in the tab off")

            // The other direction: a kill in flight refuses the bar's write.
            store.acknowledgeCommandError()
            let kill = Task { @MainActor in await store.setKill(on: true) }
            waited = 0
            while !store.isMutating, waited < 100 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            XCTAssertTrue(store.isMutating,
                "the kill never took the guard, so nothing below is exercising the refusal")
            let racer = await store.runCommand("flipMode") {
                _ = try await MetaAdsService.setMode(brand: "examplebrand", mode: "OBSERVE")
                return false
            }
            XCTAssertEqual(racer, .refused(MetaAdsStore.commandInFlightMessage),
                "an override POST raced an in-flight Emergency Stop instead of being refused")

            kill.cancel()
            _ = await kill.value
        }
        MetaAdsStore.shared.acknowledgeCommandError()
    }
}

/// A loopback listener that counts requests and answers each with a delayed
/// HTTP 500, so a pull against it is provably in flight for the delay and no
/// pass ever succeeds (nothing is applied, so nothing persists to this
/// machine's cache files). Sibling of CannedServer with a count and a clock.
private final class SlowCountingServer: @unchecked Sendable {
    private let listener: NWListener
    private let delay: TimeInterval
    private let lock = NSLock()
    private var count = 0

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    init(delay: TimeInterval) throws {
        self.delay = delay
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }
                                        if case .failed = $0 { ready.signal() } }
        listener.newConnectionHandler = { [delay] conn in
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                if data != nil { self.bump() }
                let body = "{}"
                let resp = "HTTP/1.1 500 Internal Server Error\r\n"
                    + "Content-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                DispatchQueue.global(qos: .userInitiated)
                    .asyncAfter(deadline: .now() + delay) {
                        conn.send(content: Data(resp.utf8),
                                  completion: .contentProcessed { _ in conn.cancel() })
                    }
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            throw NSError(domain: "SlowCountingServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
    }

    private func bump() { lock.lock(); count += 1; lock.unlock() }
    func stop() { listener.cancel() }
}

/// A loopback listener that accepts a connection and never answers, so a
/// request against it is reliably in flight until cancelled. Sibling of
/// PrivateServiceFetchTests' CannedServer, minus the response.
/// Answers every request with 200 and a bare `{"ok": true}` ack, the shape
/// the engine uses for a command it applied with no snapshot to echo.
private final class AckServer {
    private let listener: NWListener
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }
                                        if case .failed = $0 { ready.signal() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let body = #"{"ok":true}"#
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            throw NSError(domain: "AckServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
    }

    func stop() { listener.cancel() }
}

private final class SilentServer {
    private let listener: NWListener
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: .any)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() }
                                        if case .failed = $0 { ready.signal() } }
        listener.newConnectionHandler = { conn in
            // Accept, read, say nothing: the caller's timeout or cancellation
            // is the only way out.
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in }
        }
        listener.start(queue: .global(qos: .userInitiated))
        guard ready.wait(timeout: .now() + 10) == .success, listener.port != nil else {
            throw NSError(domain: "SilentServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
    }

    func stop() { listener.cancel() }
}
