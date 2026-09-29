import Foundation

/// Picks the provider and records the outcome. Jev when a key is present,
/// otherwise on device; and on any provider failure, on device, so a decision
/// is always returned. Callers never see a throw.
@MainActor
final class DecisionEngine {
    static let shared = DecisionEngine(
        keyLookup: { DecisionEngine.isUnderTest ? "" : (KeychainStore.getWithoutWaiting(.typesafeApiKey) ?? "") },
        ledger: DecisionLedger.shared,
        dailyBudget: { DecisionEngine.isUnderTest ? 0 : AppState.shared.config.dailyDecisionBudget })

    /// THE SUITE NEVER REACHES THE KEYCHAIN OR THE NETWORK.
    ///
    /// Every gate that moved onto this engine turned a synchronous call into
    /// an async one, and any test that exercises such a gate would otherwise
    /// read the operator's Keychain (which can raise a system password prompt
    /// and hang the run) and then post the state of whatever it was judging to
    /// a remote provider. Neither is acceptable from a test.
    ///
    /// With no key the shared engine answers on device: no network, no
    /// prompt, deterministic. A test that wants to exercise a provider builds
    /// its own engine with its own `keyLookup`, which every decision test in
    /// this suite already does.
    static let isUnderTest: Bool = NSClassFromString("XCTestCase") != nil

    private let rawKey: () -> String
    private let dailyBudget: () -> Int
    private let ledger: DecisionLedger
    private let remote: (String) -> DecisionProvider
    private let local: DecisionProvider = LocalDecisionProvider()

    init(keyLookup: @escaping () -> String,
         ledger: DecisionLedger,
         dailyBudget: @escaping () -> Int = { 0 },
         remote: @escaping (String) -> DecisionProvider = { JevDecisionProvider(apiKey: $0) }) {
        self.rawKey = keyLookup
        self.dailyBudget = dailyBudget
        self.ledger = ledger
        self.remote = remote
    }

    /// Whether a remote decision may be made right now: a key is saved and
    /// today's cap is not reached. What every gate asks before calling out.
    var hasRemoteKey: Bool { !keyLookup().isEmpty }

    /// Whether a key is saved at all, cap or no cap. For SAYING so (Tuning),
    /// never for deciding whether to call out; that is `hasRemoteKey`.
    var hasSavedKey: Bool { !rawKey().isEmpty }

    /// True once today's remote decisions reach the cap Tuning sets.
    func budgetReached(now: Date = Date()) -> Bool {
        let cap = dailyBudget()
        return cap > 0 && remoteDecisionsToday(now: now) >= cap
    }

    /// Remote decisions recorded since midnight.
    func remoteDecisionsToday(now: Date = Date()) -> Int {
        ledger.remoteDecisions(on: now)
    }

    /// THE ONE PLACE A KEY IS READ, and the daily budget with it: once today's
    /// remote decisions reach the cap Tuning sets, the key reads as absent and
    /// every gate answers on device, exactly as a keyless install does, until
    /// midnight. Both the single call and the batched event read through here.
    private func keyLookup() -> String {
        let key = rawKey()
        guard !key.isEmpty, !budgetReached() else { return "" }
        return key
    }

    /// Events currently open (`DecisionEvent`). Internal so the event
    /// extension can maintain it; nothing else writes it.
    var openEvents: [DecisionEvent] = []

    /// Every time a gate called `decide` directly for a surface an open event
    /// covered: a round trip of its own when a batched one was available. The
    /// call is still answered, because failing a gate closed on a bookkeeping
    /// rule would be worse than the extra call, but a test asserts this stays
    /// empty.
    private(set) var batchViolations: [String] = []

    func decide(surface: String, state: String, questions: [String: DecisionQuestion]) async -> DecisionResult {
        if openEvents.contains(where: { $0.covers.contains(surface) }) {
            batchViolations.append(surface)
            WakeLog.shared.log("decisions: \(surface) opened its own call while an event covering it was open")
        }
        let key = keyLookup()
        let started = Date()
        var answered: DecisionResult?
        var fellBackFrom: DecisionProviderKind?
        var mayHaveBilled = false
        if !key.isEmpty {
            let provider = remote(key)
            let asked = await askRemote(provider, surface: surface, state: state, questions: questions)
            answered = asked.result
            if answered == nil { fellBackFrom = provider.kind; mayHaveBilled = asked.mayHaveBilled }
        }
        var result: DecisionResult
        if let answered {
            result = answered
        } else {
            result = await localAnswer(state: state, questions: questions)
            // After a remote call that gave no answer, the wait is the whole
            // wait, not the on-device part of it.
            if fellBackFrom != nil { result = result.withLatency(Self.elapsedMs(since: started)) }
        }
        ledger.record(DecisionLedgerEntry(surface: surface, provider: result.provider, latencyMs: result.latencyMs,
                                     inputTokens: result.inputTokens, outputTokens: result.outputTokens,
                                     at: Date(), summary: Self.summary(state: state, result: result),
                                     fallbackFrom: fellBackFrom, fallbackMayHaveBilled: fellBackFrom == nil ? nil : mayHaveBilled))
        return result
    }

    /// One remote call. Nil when it gave no answer, with one wake.log line
    /// saying why and how long it took: a stall to the request timeout used
    /// to fall back on device with no trace at all.
    /// `mayHaveBilled`: with no answer, whether the call may still have been
    /// billed (`mayHaveBeenBilled`), so the daily cap counts it.
    func askRemote(_ provider: DecisionProvider, surface: String, state: String,
                   questions: [String: DecisionQuestion]) async -> (result: DecisionResult?, mayHaveBilled: Bool) {
        let started = Date()
        do {
            return (try await provider.decide(state: state, questions: questions), true)
        } catch {
            WakeLog.shared.log("decisions: \(surface) \(provider.kind.rawValue) gave no answer after "
                               + "\(Self.elapsedMs(since: started)) ms (\(Self.failureName(error))); answered on device")
            return (nil, Self.mayHaveBeenBilled(error))
        }
    }

    /// A call that timed out, reached the server and failed there (5xx), or
    /// came back 2xx with a body that does not parse (the server did the
    /// work) may have been billed. One that never left this Mac (offline, a
    /// name that does not resolve) or that the server refused before any work
    /// (a 4xx: bad key, rate limit) was not.
    static func mayHaveBeenBilled(_ error: Error) -> Bool {
        if let url = error as? URLError { return url.code == .timedOut }
        switch error as? JevDecisionProvider.Failure {
        case .http(let status)?: return (500..<600).contains(status)
        case .malformed?: return true
        case .noKey?, nil: return false
        }
    }

    static func elapsedMs(since start: Date) -> Int { Int(Date().timeIntervalSince(start) * 1000) }

    static func failureName(_ error: Error) -> String {
        if let url = error as? URLError { return url.code == .timedOut ? "timed out" : "network error \(url.code.rawValue)" }
        if let jev = error as? JevDecisionProvider.Failure {
            switch jev {
            case .http(let status): return "HTTP \(status)"
            case .malformed: return "unreadable answer"
            case .noKey: return "no key"
            }
        }
        return String(describing: error)
    }

    // MARK: - Shared with DecisionEvent

    func remoteKey() -> String { keyLookup() }
    func remoteProvider(_ key: String) -> DecisionProvider { remote(key) }

    func localAnswer(state: String, questions: [String: DecisionQuestion]) async -> DecisionResult {
        (try? await local.decide(state: state, questions: questions))
            ?? DecisionResult(answers: [:], latencyMs: 0, inputTokens: 0, outputTokens: 0, provider: .local)
    }

    func record(surface: String, result: DecisionResult, heard: String,
                answers: [String: [String: DecisionAnswer]], fallbackFrom: DecisionProviderKind? = nil,
                fallbackMayHaveBilled: Bool? = nil) {
        var flat: [String: DecisionAnswer] = [:]
        for (gate, qs) in answers { for (name, a) in qs { flat["\(gate).\(name)"] = a } }
        let shown = DecisionResult(answers: flat, latencyMs: result.latencyMs, inputTokens: result.inputTokens,
                                   outputTokens: result.outputTokens, provider: result.provider)
        ledger.record(DecisionLedgerEntry(surface: surface, provider: result.provider, latencyMs: result.latencyMs,
                                     inputTokens: result.inputTokens, outputTokens: result.outputTokens,
                                     at: Date(), summary: Self.summary(state: heard, result: shown),
                                     fallbackFrom: fallbackFrom, fallbackMayHaveBilled: fallbackMayHaveBilled))
    }

    /// The gate's owner decided something other than the provider's answer,
    /// by a rule of its own ("said to Grux by name"). The provider's row
    /// stays, and this one, on device and free, says what was DONE: without
    /// it the ledger said `not_a_command` for words Grux went on to answer.
    func recordOverride(surface: String, heard: String, question: String,
                        choice: String, confidence: Double, rule: String) {
        let shown = DecisionResult(answers: [question: .choice(choice, confidence: confidence, probabilities: [:])],
                                   latencyMs: 0, inputTokens: 0, outputTokens: 0, provider: .local)
        ledger.record(DecisionLedgerEntry(surface: surface, provider: .local, latencyMs: 0,
                                          inputTokens: 0, outputTokens: 0, at: Date(),
                                          summary: Self.summary(state: heard, result: shown) + " (\(rule))"))
    }

    static func summary(state: String, result: DecisionResult) -> String {
        let heard = state.count > 60 ? String(state.prefix(57)) + "..." : state
        let decided = result.answers.map { name, a -> String in
            switch a {
            case .choice(let c, let conf, _): return "\(name)=\(c) \(String(format: "%.2f", conf))"
            case .noul(let p): return "\(name)=\(String(format: "%.2f", p))"
            case .score(let s, _): return "\(name)=\(String(format: "%.1f", s))"
            }
        }.sorted().joined(separator: ", ")
        return "\(heard) -> \(decided)"
    }
}
