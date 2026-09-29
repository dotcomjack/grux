import XCTest
@testable import Grux

@MainActor
final class ListeningControllerTests: XCTestCase {
    private var log: [String] = []
    private func make(running: @escaping (ListeningMode) -> Bool = { _ in true }) -> ListeningController {
        ListeningController(startWake: { self.log.append("wake+") }, stopWake: { self.log.append("wake-") },
                            startAmbient: { self.log.append("amb+") }, stopAmbient: { self.log.append("amb-") },
                            isRunning: running)
    }

    func test_alwaysOn_stopsWakeThenStartsAmbient() async {
        let c = make(); let got = await c.apply(mode: .alwaysOn)
        XCTAssertEqual(log, ["wake-", "amb+"]); XCTAssertEqual(got, .alwaysOn)
    }

    func test_wakeWord_stopsAmbientThenStartsWake() async {
        let c = make(); let got = await c.apply(mode: .wakeWord)
        XCTAssertEqual(log, ["amb-", "wake+"]); XCTAssertEqual(got, .wakeWord)
    }

    func test_off_stopsBoth() async {
        let c = make(); let got = await c.apply(mode: .off)
        XCTAssertEqual(log, ["wake-", "amb-"]); XCTAssertEqual(got, .off)
    }

    /// THE INVARIANT IS SERIALISATION, NOT A PARTICULAR SUBMISSION ORDER.
    ///
    /// This asserted one exact sequence, which made it flaky: `async let`
    /// starts both children concurrently and does not guarantee which `apply`
    /// reaches the controller first. Measured 2026-09-20: it failed once
    /// inside a full-suite run with `["amb-", "wake+", "wake-", "amb+",
    /// "amb+done"]` and passed 3 of 3 in isolation immediately afterwards.
    /// That failing log is the OTHER correctly serialised order, so the
    /// controller was right and the assertion was wrong.
    ///
    /// The property that actually matters, and the one the controller exists
    /// for: whichever apply wins finishes completely before the other starts.
    /// The comment in `ListeningController` records what interleaving cost
    /// when it happened for real, which was a transient off written while
    /// ambient was in fact capturing.
    func test_concurrentApplies_doNotInterleave() async {
        // Slow ambient start so a second apply arrives mid-flight.
        let c = ListeningController(
            startWake: { self.log.append("wake+") }, stopWake: { self.log.append("wake-") },
            startAmbient: { self.log.append("amb+"); try? await Task.sleep(nanoseconds: 50_000_000); self.log.append("amb+done") },
            stopAmbient: { self.log.append("amb-") }, isRunning: { _ in true })
        async let a = c.apply(mode: .alwaysOn)
        async let b = c.apply(mode: .wakeWord)
        _ = await (a, b)

        let alwaysOnFirst = ["wake-", "amb+", "amb+done", "amb-", "wake+"]
        let wakeWordFirst = ["amb-", "wake+", "wake-", "amb+", "amb+done"]
        XCTAssertTrue(log == alwaysOnFirst || log == wakeWordFirst,
                      "the two applies interleaved: \(log)")

        // The sharp edge, stated on its own so a future rewrite cannot lose
        // it in the pair above: nothing ran between the slow ambient start
        // and its completion.
        let start = try? XCTUnwrap(log.firstIndex(of: "amb+"))
        if let start, log.index(after: start) < log.endIndex {
            XCTAssertEqual(log[log.index(after: start)], "amb+done",
                           "something ran during the ambient start: \(log)")
        }
    }

    func test_declinedConsent_isAnAnswer_modeFallsToOff() async {
        // enable() returns without starting when the person declines the
        // consent dialog. The controller reports .off rather than pretending.
        let c = make(running: { _ in false })
        let got = await c.apply(mode: .alwaysOn)
        XCTAssertEqual(got, .off)
    }
}
