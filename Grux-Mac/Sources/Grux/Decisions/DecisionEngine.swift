import Foundation

/// Picks the provider and records the outcome. Jev when a key is present,
/// otherwise on device; and on any provider failure, on device, so a decision
/// is always returned. Callers never see a throw.
@MainActor
final class DecisionEngine {
    static let shared = DecisionEngine(
        keyLookup: { DecisionEngine.isUnderTest ? "" : (KeychainStore.getWithoutWaiting(.typesafeApiKey) ?? "") },
        ledger: DecisionLedger.shared,
        dailyBudget: { DecisionEngine.isUnderTest ? 0 : AppState.shared.config.dailyDecisionBudget },
        keyChecked: { record in if !DecisionEngine.isUnderTest { DecisionsSection.saveCheck(record) } })

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
    /// Where a real decision's verdict on the key goes: the record the
    /// Integrations, Decisions card reads (D166 item 3).
    private let keyChecked: (DecisionsSection.KeyCheckRecord) -> Void

    init(keyLookup: @escaping () -> String,
         ledger: DecisionLedger,
         dailyBudget: @escaping () -> Int = { 0 },
         remote: @escaping (String) -> DecisionProvider = { JevDecisionProvider(apiKey: $0) },
         keyChecked: @escaping (DecisionsSection.KeyCheckRecord) -> Void = { _ in }) {
        self.rawKey = keyLookup
        self.dailyBudget = dailyBudget
        self.ledger = ledger
        self.remote = remote
        self.keyChecked = keyChecked
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
            let asked = await askRemote(provider, key: key, surface: surface, state: state, questions: questions)
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
    /// A call that answered, or that TypeSafe refused, is also a check of the
    /// key it carried, recorded through `keyChecked`.
    func askRemote(_ provider: DecisionProvider, key: String, surface: String, state: String,
                   questions: [String: DecisionQuestion]) async -> (result: DecisionResult?, mayHaveBilled: Bool) {
        let started = Date()
        do {
            let answer = try await provider.decide(state: state, questions: questions)
            recordKeyCheck(Self.keyCheckFromUse(error: nil, key: key), carried: key)
            return (answer, true)
        } catch {
            recordKeyCheck(Self.keyCheckFromUse(error: error, key: key), carried: key)
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

    /// Only while the key the call carried is still the saved one: a call that
    /// lands after the person saved another key (Save & Test, Disconnect) is
    /// about the old key, and must not overwrite the new one's record
    /// (W54-P3 item 1).
    private func recordKeyCheck(_ check: DecisionsSection.KeyCheckRecord?, carried key: String) {
        guard let check, rawKey() == key else { return }
        keyChecked(check)
    }

    /// What a real decision says about the key it carried, the same reading
    /// Save & Test uses: an answer means it works, a 401 or 403 means TypeSafe
    /// refused it, and any other failure (out of credit, a rate limit, a
    /// server error, a timeout, offline) says nothing about the key, so the
    /// last check stands. Nil when there is nothing to record.
    static func keyCheckFromUse(error: Error?, key: String, at: Date = Date()) -> DecisionsSection.KeyCheckRecord? {
        let tail = DecisionsSection.tail(key)
        guard !tail.isEmpty else { return nil }
        let result: DecisionsSection.KeyCheck
        if let error {
            guard DecisionsSection.checkResult(of: error) == .refused else { return nil }
            result = .refused
        } else {
            result = .worked
        }
        return DecisionsSection.KeyCheckRecord(result: result, at: at, keyTail: tail)
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

    /// The ledger keeps the first 57 characters of a state over 60, and never
    /// cuts a gated tool's id: the card names the tool from it, and a long id
    /// clipped before its closing quote read raw (W54-P3 item 2).
    /// The quote it keeps closes a tool id (letters, digits, `_`, `-`, `.`),
    /// so a person's "Run tool 'notes please ... I'm" keeps no more than 57
    /// (wave 55 P3-1). A clip that would save fewer characters than its "..."
    /// keeps the state whole.
    static func clipped(_ gist: String) -> String {
        guard gist.count > 60 else { return gist }
        var keep = 57
        if let open = gist.range(of: "Run tool '") {
            let id = gist[open.upperBound...].prefix { $0.isLetter || $0.isNumber || "_-.".contains($0) }
            if !id.isEmpty, id.endIndex < gist.endIndex, gist[id.endIndex] == "'" {
                keep = max(keep, gist.distance(from: gist.startIndex, to: id.endIndex) + 1)
            }
        }
        return keep + 3 >= gist.count ? gist : String(gist.prefix(keep)) + "..."
    }

    static func summary(state: String, result: DecisionResult) -> String {
        let gist = DecisionUsageSummary.withoutPreamble(state)
        let heard = clipped(gist)
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
