import Foundation

/// One judged event: a voice chunk, a chat turn, a tool dispatch. Every gate
/// with a question about it registers the question BEFORE the event's single
/// suspension point, the engine asks them all in ONE provider call, and each
/// gate then reads its own typed answer synchronously.
///
/// WHY. Measured 2026-09-21 from the ledger and the code: a spoken request
/// that went on to Chat paid two sequential Jev round trips on one utterance,
/// the voice decision (p50 444 ms) and then `chat.intent` inside
/// `ChatService.send` (about 400 ms more). Six mixed questions in one call
/// returned in 400 ms, no slower than one. And one suspension point per event
/// is the rule that closed the readiness guard hole on 2026-09-20: an await
/// per gate is an interleaving point per gate.
///
/// WHAT GOES WHERE, measured against the live provider on 2026-09-21. The
/// event's STATE is what the event is, the owner gate's own context byte for
/// byte (for a spoken chunk: what was heard). A second gate's context goes in
/// front of ITS OWN questions' instructions, never into the shared state. The
/// first version put every gate's context into one state under headings, and
/// Jev read Chat's "Grux is about to do this" as evidence the words were
/// addressed to Grux: an unaddressed "note that ..." flipped from
/// `not_a_command 0.97` to `say:chat 0.66`. With the context moved into the
/// instructions the voice answer matched its standalone call exactly (0.97 to
/// 0.98 over three rounds), and Chat's answer tracked its standalone call to a
/// mean 0.05 over seven utterances while separating right plans from wrong
/// ones better (+0.52 against +0.36). One call took about 390 ms against about
/// 820 ms for two, on 36% fewer input tokens.
///
/// The rules the engine enforces:
/// - A gate the event COVERS must ask through the event. `DecisionEngine.decide`
///   called for a covered surface while the event is open is recorded in
///   `batchViolations`: that is a gate opening its own round trip when a
///   batched one was available (Phase R acceptance criterion 1).
/// - ONE ledger row per event, its surface naming every gate that asked.
/// - Without a key, or if the provider fails, every gate is answered on device
///   against ITS OWN context, exactly as its direct call would have been. The
///   on-device matcher reads the whole state, so a combined state would change
///   its answers; a keyless install must behave exactly as it did.
@MainActor
final class DecisionEvent {
    let origin: String
    /// What the event is, judged by every question on it. The owner gate's
    /// own context.
    let state: String
    /// The gates that may ask about this event. Fixed at open.
    let covers: Set<String>

    private(set) var gates: [String] = []
    /// A secondary gate's own context. Nil for a gate that judges the event's
    /// state as it stands.
    private(set) var contexts: [String: String] = [:]
    private(set) var questions: [String: [String: DecisionQuestion]] = [:]
    private(set) var answers: [String: [String: DecisionAnswer]] = [:]
    private(set) var provider: DecisionProviderKind?
    private(set) var latencyMs = 0
    private(set) var isResolved = false

    /// Opt-in permission to answer this event ON DEVICE and skip the network
    /// when the on-device provider is already certain.
    ///
    /// WHY THIS EXISTS. Measured from `wake.log` on 2026-09-23 over 603 real
    /// decisions: Jev's median was 368ms (p90 872ms, max 2369ms) while the
    /// on-device provider's was 3ms (p90 7ms, max 10ms), about 120 times
    /// faster. A 368ms round trip does not fit inside a 600ms budget from
    /// sentence end to execution once transcription is paid for, so the only
    /// way to that number is to stop making the call when it cannot change
    /// the answer.
    ///
    /// WHY IT IS SAFE. The bar is an EXACT spoken phrase covering at least
    /// half of what was said (`LocalDecisionProvider.phraseCoverage`), which
    /// scores 0.95. That is not a new risk surface: it is precisely what
    /// every keyless install already executes on, and the coverage rule is
    /// what stopped "we should mute the group chat" from muting the
    /// microphone. Anything short of certain, and anything named in
    /// `neverFast`, still goes to the provider exactly as before, so nothing
    /// that used to be judged on meaning stops being judged on meaning.
    struct FastLocalPath {
        /// The gate whose certainty may settle the whole event.
        let gate: String
        /// The question on that gate to read.
        let question: String
        /// The confidence at or above which the on-device answer is acted on.
        let minConfidence: Double
        /// Options that must NEVER settle on device however confident, because
        /// they are not a specific command and only mean something once a
        /// provider has judged the sentence.
        let neverFast: Set<String>
    }

    /// Nil for every event by default: an approval, an agent judgment or a
    /// meeting moment must keep going to the provider. Only a surface that has
    /// argued its own case sets this.
    var fastLocal: FastLocalPath?

    init(origin: String, state: String, covers: Set<String>) {
        self.origin = origin
        self.state = state
        self.covers = covers
    }

    /// Registers a gate's questions about this event. A gate asks once.
    /// `context` is what this gate's own direct call would have used as its
    /// state; nil when the gate judges the event's state as it stands.
    func ask(_ gate: String, context: String? = nil, _ qs: [String: DecisionQuestion]) {
        precondition(!isResolved, "\(gate) asked after the event was resolved; ask before the one call")
        precondition(covers.contains(gate), "\(gate) is not covered by this \(origin) event")
        precondition(questions[gate] == nil, "\(gate) asked twice about one event")
        gates.append(gate)
        if let context { contexts[gate] = context }
        questions[gate] = qs
    }

    /// The state this gate's own direct call would have sent.
    func ownState(_ gate: String) -> String { contexts[gate] ?? state }

    /// A gate's typed answer, read synchronously once the event is resolved.
    func answer(_ gate: String, _ name: String) -> DecisionAnswer? {
        answers[gate]?[name]
    }

    /// The ledger surface: every gate that asked, in the order they asked.
    var surface: String { gates.joined(separator: "+") }

    // MARK: - Wire shape (the engine's business)

    /// With ONE gate on the event the call is byte-identical to that gate's old
    /// direct call: its own state, its own question names. Only when two or
    /// more gates share the call are the names namespaced and the contexts
    /// given headings. A lone gate therefore sees no change at all on the wire,
    /// which is what lets every existing gate test stay unchanged.
    var isShared: Bool { gates.count > 1 }

    /// Question names on the wire carry their gate when shared, so two gates
    /// can both ask something called "intent". Dots become underscores to keep
    /// the key a plain identifier.
    func wireName(gate: String, name: String) -> String {
        isShared ? gate.replacingOccurrences(of: ".", with: "_") + "__" + name : name
    }

    /// The state on the wire. Shared: the event's own state, and nothing any
    /// other gate brought. Lone: that gate's own state, as its direct call.
    var combinedState: String {
        guard isShared else { return gates.first.map(ownState) ?? state }
        return state
    }

    /// Shared: a secondary gate's context goes in front of each of its
    /// questions' instructions. Lone: the questions exactly as asked.
    var combinedQuestions: [String: DecisionQuestion] {
        var out: [String: DecisionQuestion] = [:]
        for gate in gates {
            for (name, q) in questions[gate] ?? [:] {
                let context = isShared ? contexts[gate] : nil
                out[wireName(gate: gate, name: name)] = context.map { q.prefixed(with: $0) } ?? q
            }
        }
        return out
    }

    func settle(remote result: DecisionResult) {
        var split: [String: [String: DecisionAnswer]] = [:]
        for gate in gates {
            for name in (questions[gate] ?? [:]).keys {
                if let a = result.answers[wireName(gate: gate, name: name)] { split[gate, default: [:]][name] = a }
            }
        }
        finish(split, provider: result.provider, latencyMs: result.latencyMs)
    }

    /// `endToEndMs`: after a remote call that gave no answer, the whole wait,
    /// so the event does not read as the on-device part alone.
    func settle(local perGate: [String: DecisionResult], endToEndMs: Int? = nil) {
        finish(perGate.mapValues(\.answers), provider: .local,
               latencyMs: endToEndMs ?? perGate.values.map(\.latencyMs).reduce(0, +))
    }

    private func finish(_ split: [String: [String: DecisionAnswer]], provider: DecisionProviderKind, latencyMs: Int) {
        answers = split
        self.provider = provider
        self.latencyMs = latencyMs
        isResolved = true
    }
}

extension DecisionEngine {
    /// Opens an event. Until `close`, a direct `decide` for any covered surface
    /// is recorded as a batch violation.
    func open(origin: String, state: String, covering gates: Set<String>) -> DecisionEvent {
        let event = DecisionEvent(origin: origin, state: state, covers: gates)
        openEvents.append(event)
        return event
    }

    func close(_ event: DecisionEvent) {
        openEvents.removeAll { $0 === event }
    }

    /// The event's single suspension point: one provider call for every
    /// question every gate registered, one ledger row.
    /// Every gate on the event answered on device, against ITS OWN context.
    /// Shared by the fast path and the no-key/provider-failure path so both
    /// build the answers the same way.
    func localAnswers(for event: DecisionEvent) async -> [String: DecisionResult] {
        var perGate: [String: DecisionResult] = [:]
        for gate in event.gates {
            perGate[gate] = await localAnswer(state: event.ownState(gate), questions: event.questions[gate] ?? [:])
        }
        return perGate
    }

    func resolve(_ event: DecisionEvent) async {
        guard !event.isResolved else { return }
        guard !event.gates.isEmpty else {
            event.settle(local: [:])
            return
        }
        let key = remoteKey()
        let started = Date()
        // THE FAST PATH. Ask the device first when this event has opted in,
        // and skip the round trip entirely when the device is already certain.
        // The on-device answer costs about 3ms against Jev's 368ms median, so
        // the wasted work when it is NOT certain is a rounding error against
        // the call it might save. See DecisionEvent.FastLocalPath for why the
        // bar is where it is and why this is not a new risk surface.
        if !key.isEmpty, let fast = event.fastLocal {
            let onDevice = await localAnswers(for: event)
            if case .choice(let id, let confidence, _)? = onDevice[fast.gate]?.answers[fast.question],
               id != LocalDecisionProvider.notACommand,
               !fast.neverFast.contains(id),
               confidence >= fast.minConfidence {
                event.settle(local: onDevice)
                let total = DecisionResult(answers: [:], latencyMs: event.latencyMs, inputTokens: 0,
                                           outputTokens: 0, provider: .local)
                record(surface: event.surface, result: total, heard: event.state, answers: event.answers)
                return
            }
        }
        var fellBackFrom: DecisionProviderKind?
        var mayHaveBilled = false
        if !key.isEmpty {
            let provider = remoteProvider(key)
            let asked = await askRemote(provider, surface: event.surface, state: event.combinedState,
                                        questions: event.combinedQuestions)
            if let r = asked.result {
                event.settle(remote: r)
                record(surface: event.surface, result: r, heard: event.state, answers: event.answers)
                return
            }
            fellBackFrom = provider.kind
            mayHaveBilled = asked.mayHaveBilled
        }
        let perGate = await localAnswers(for: event)
        event.settle(local: perGate, endToEndMs: fellBackFrom == nil ? nil : Self.elapsedMs(since: started))
        let total = DecisionResult(answers: [:], latencyMs: event.latencyMs, inputTokens: 0,
                                   outputTokens: 0, provider: .local)
        record(surface: event.surface, result: total, heard: event.state, answers: event.answers,
               fallbackFrom: fellBackFrom, fallbackMayHaveBilled: fellBackFrom == nil ? nil : mayHaveBilled)
    }
}

extension DecisionQuestion {
    /// The same question with a gate's own context in front of its
    /// instructions, so the context reaches this question and no other.
    func prefixed(with context: String) -> DecisionQuestion {
        switch self {
        case .choice(let i, let c): return .choice(instructions: context + "\n" + i, criteria: c)
        case .noul(let i): return .noul(instructions: context + "\n" + i)
        case .score(let i, let l): return .score(instructions: context + "\n" + i, levels: l)
        }
    }
}
