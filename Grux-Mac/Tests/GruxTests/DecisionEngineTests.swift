import XCTest
@testable import Grux

@MainActor
final class DecisionEngineTests: XCTestCase {
    private struct Failing: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            throw JevDecisionProvider.Failure.http(500)
        }
    }

    func test_withoutKey_usesLocalAndRecords() async {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "" }, ledger: ledger)
        let r = await engine.decide(surface: "test", state: "close everything",
                                    questions: ["intent": .choice(instructions: "?", criteria: ["close_all": "close everything", "not_a_command": "chatter"])])
        XCTAssertEqual(r.provider, .local)
        XCTAssertEqual(ledger.last?.surface, "test")
        XCTAssertEqual(ledger.last?.costUSD, 0)
    }

    func test_remoteFailure_fallsBackToLocal() async {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, remote: { _ in Failing() })
        let r = await engine.decide(surface: "test", state: "close everything",
                                    questions: ["intent": .choice(instructions: "?", criteria: ["close_all": "close everything", "not_a_command": "chatter"])])
        XCTAssertEqual(r.provider, .local)
    }

    /// Stalls, then gives up the way URLSession does at its request timeout.
    private struct TimingOut: DecisionProvider {
        let kind: DecisionProviderKind = .jev
        let stallMs: UInt64
        func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
            try await Task.sleep(nanoseconds: stallMs * 1_000_000)
            throw URLError(.timedOut)
        }
    }

    private func wakeLogLines(containing marker: String) -> [String] {
        let deadline = Date().addingTimeInterval(3)
        var lines: [String] = []
        repeat {
            let text = (try? String(contentsOf: WakeLog.shared.fileURL, encoding: .utf8)) ?? ""
            lines = text.components(separatedBy: "\n").filter { $0.contains(marker) }
            if !lines.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return lines
    }

    /// Final sweep, 2026-09-28: about 7 of 10 Jev calls stalled for the 3 s
    /// request timeout and fell back on device with no wake.log line, and the
    /// decision row said 0 to 10 ms, the on-device part alone. The row now
    /// carries the whole wait and names the provider that gave no answer.
    func test_aRemoteTimeoutIsLoggedAndTheRowCarriesTheWholeWait() async {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, remote: { _ in TimingOut(stallMs: 300) })
        let surface = "timeout-\(UUID().uuidString.prefix(8))"
        let r = await engine.decide(surface: surface, state: "close everything",
                                    questions: ["intent": .choice(instructions: "?", criteria: ["close_all": "close everything", "not_a_command": "chatter"])])
        XCTAssertEqual(r.provider, .local)
        XCTAssertGreaterThanOrEqual(r.latencyMs, 300, "the caller's latency is the whole wait")
        let row = ledger.last
        XCTAssertEqual(row?.provider, .local)
        XCTAssertEqual(row?.fallbackFrom, .jev)
        XCTAssertGreaterThanOrEqual(row?.latencyMs ?? 0, 300, "the row says only the on-device part")
        let lines = wakeLogLines(containing: surface)
        XCTAssertEqual(lines.count, 1, "no wake.log line for the fallback")
        XCTAssertTrue(lines.first?.contains("timed out") == true, lines.first ?? "")
        XCTAssertNotNil(lines.first?.range(of: #"after [0-9]+ ms"#, options: .regularExpression), lines.first ?? "")
    }

    /// The batched path the voice router uses: the same line and the same row.
    func test_anEventWhoseRemoteCallTimesOutCarriesTheWholeWait() async {
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, remote: { _ in TimingOut(stallMs: 300) })
        let origin = "timeout-\(UUID().uuidString.prefix(8))"
        let event = engine.open(origin: origin, state: "Heard: open my calendar", covering: [origin])
        event.ask(origin, ["intent": .choice(instructions: "i", criteria: ["tab:calendar": "open my calendar"])])
        await engine.resolve(event)
        engine.close(event)
        XCTAssertEqual(event.provider, .local)
        XCTAssertGreaterThanOrEqual(event.latencyMs, 300, "the voice row reads the event's latency")
        XCTAssertEqual(ledger.last?.fallbackFrom, .jev)
        XCTAssertGreaterThanOrEqual(ledger.last?.latencyMs ?? 0, 300)
        let lines = wakeLogLines(containing: origin)
        XCTAssertEqual(lines.count, 1, "no wake.log line for the fallback")
        XCTAssertTrue(lines.first?.contains("timed out") == true, lines.first ?? "")
    }

    /// Review of e125705: a remote call that timed out may still have been
    /// billed, so it counts toward the daily cap like one that answered.
    func test_aTimedOutRemoteCallCountsAgainstTheDailyCap() async {
        final class Counted: DecisionProvider, @unchecked Sendable {
            let kind: DecisionProviderKind = .jev
            var calls = 0
            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
                calls += 1
                throw URLError(.timedOut)
            }
        }
        let provider = Counted()
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, dailyBudget: { 1 }, remote: { _ in provider })
        let q: [String: DecisionQuestion] = ["intent": .choice(instructions: "?", criteria: ["close_all": "x"])]
        _ = await engine.decide(surface: "cap-1", state: "close everything", questions: q)
        XCTAssertEqual(ledger.remoteDecisions(), 1, "a timed out call is not counted")
        XCTAssertTrue(engine.budgetReached())
        _ = await engine.decide(surface: "cap-2", state: "close everything", questions: q)
        XCTAssertEqual(provider.calls, 1, "a second call went out past the cap")

        let reloaded = DecisionLedger(storeURL: nil)
        reloaded.record(DecisionLedgerEntry(surface: "s", provider: .local, latencyMs: 3100, inputTokens: 0,
                                            outputTokens: 0, at: Date(), summary: "x", fallbackFrom: .jev,
                                            fallbackMayHaveBilled: true))
        XCTAssertEqual(reloaded.remoteDecisions(), 1)
    }

    /// Re-review of 90236d0: only a call that may have been billed counts
    /// toward the cap. A timeout, a server error (5xx) or a 2xx whose body
    /// does not parse may have been; a
    /// Mac that is offline, a name that does not resolve, a bad key (401) or
    /// a rate limit (429) never reached a billed answer.
    func test_onlyAFailedCallThatMayHaveBeenBilledCountsTowardTheCap() async {
        struct Failing: DecisionProvider {
            let kind: DecisionProviderKind = .jev
            let error: Error
            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult { throw error }
        }
        let cases: [(Error, Bool, String)] = [
            (URLError(.timedOut), true, "timed out"),
            (JevDecisionProvider.Failure.http(500), true, "HTTP 500"),
            (JevDecisionProvider.Failure.http(503), true, "HTTP 503"),
            // A 2xx whose body does not parse: the server did the work.
            (JevDecisionProvider.Failure.malformed, true, "2xx unreadable"),
            (URLError(.notConnectedToInternet), false, "offline"),
            (URLError(.cannotFindHost), false, "DNS"),
            (JevDecisionProvider.Failure.http(401), false, "HTTP 401"),
            (JevDecisionProvider.Failure.http(429), false, "HTTP 429"),
            (JevDecisionProvider.Failure.http(400), false, "HTTP 400"),
        ]
        for (error, billed, what) in cases {
            let ledger = DecisionLedger(storeURL: nil)
            let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, remote: { _ in Failing(error: error) })
            _ = await engine.decide(surface: "cap", state: "close everything",
                                    questions: ["intent": .choice(instructions: "?", criteria: ["close_all": "x"])])
            XCTAssertEqual(ledger.last?.fallbackFrom, .jev, what)
            XCTAssertEqual(ledger.remoteDecisions(), billed ? 1 : 0, what)
        }
    }

    /// A call that answers is not a fallback.
    func test_aRemoteAnswerIsNotMarkedAsAFallback() async {
        struct Answering: DecisionProvider {
            let kind: DecisionProviderKind = .jev
            func decide(state: String, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
                DecisionResult(answers: ["intent": .choice("close_all", confidence: 0.9, probabilities: [:])],
                               latencyMs: 350, inputTokens: 100, outputTokens: 5, provider: .jev)
            }
        }
        let ledger = DecisionLedger(storeURL: nil)
        let engine = DecisionEngine(keyLookup: { "k" }, ledger: ledger, remote: { _ in Answering() })
        _ = await engine.decide(surface: "answered", state: "close everything",
                                questions: ["intent": .choice(instructions: "?", criteria: ["close_all": "x"])])
        XCTAssertEqual(ledger.last?.provider, .jev)
        XCTAssertNil(ledger.last?.fallbackFrom)
        XCTAssertEqual(ledger.last?.latencyMs, 350)
    }

    func test_ledgerCost_isInputTokensAtTheJevRate() {
        let ledger = DecisionLedger(storeURL: nil)
        ledger.record(DecisionLedgerEntry(surface: "s", provider: .jev, latencyMs: 500, inputTokens: 1_000_000, outputTokens: 10, at: Date(), summary: "x"))
        XCTAssertEqual(ledger.last?.costUSD ?? -1, 0.042, accuracy: 1e-9)
        let t = ledger.today()
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t.avgLatencyMs, 500)
    }
}
