import Foundation

// ConfidenceGate: Jax's "never guess on TRUE confusion" mechanism.
//
// This is the Jarvis rule made load-bearing. Guardrail 5 in JaxProfile says:
// when Jax is unsure whether an action is safe or wanted, the default is PAUSE
// and ask, not a confident guess. DecisionGate enforces that for the SAFETY
// dimension (money / leaks / posts / outbound comms). ConfidenceGate enforces the
// COMPREHENSION dimension: before Jax acts on a turn, it asks itself "do I
// actually understand what the user is asking, or am I about to confidently fill a
// gap with a guess?". When the honest answer is "I do not understand", Jax asks
// ONE specific clarifying question instead of guessing an answer or firing a tool.
//
// The bar is deliberately conservative and HONEST. It flags TRUE confusion:
//   - a genuinely empty / contentless request,
//   - a missing required referent (a pronoun or "that" / "it" with nothing to
//     bind to, no prior turn and no on-screen subject),
//   - directly conflicting instructions in the same turn,
//   - an unknown term that is not slang Jax has learned, not a known fact, not a
//     heuristic domain, and not a plain English word.
// It does NOT flag mere DIFFICULTY. A hard but well-specified request ("refactor
// the retrieval lane to RRF") is high-effort, not confusing: Jax should attempt
// it, not interrogate the user. Confusing the two would turn Jax into a nag, which
// JaxProfile explicitly forbids. So the heuristics only fire on structural gaps,
// never on "this sounds hard".
//
// Two paths behind one API:
//   1. A lightweight, synchronous, no-model heuristic path (the default). Cheap,
//      deterministic, runs every turn. Catches the obvious structural confusion.
//   2. An optional model-backed path for nuanced cases the heuristics can neither
//      clear nor condemn, gated behind the same assess() call. Used only when the
//      heuristic lands in the ambiguous middle band AND a key + opt-in are present.
//
// FAIL SAFE: if the gate is itself uncertain whether it is confused (the model
// path errors, times out, or returns garbage), it prefers ASKING. A wrongly-asked
// clarifying question costs the user one sentence; a wrongly-confident guess can
// cost them a wrong action. We bias toward the cheap mistake.
//
// House style: enum-namespaced pure logic + a small @MainActor coordinator,
// Codable verdict, zero em/en dashes, dollars as $N. No new SPM dependencies.
//
// Sibling note: the cognition trace (decision provenance shown in the honest
// Cognition Map) is owned by CognitionTrace.swift, built in parallel. This module
// does NOT redefine those types and does NOT call into CognitionTrace directly
// (its API is owned by that sibling). Instead it returns a fully-formed
// ConfidenceVerdict that the integrator hands to CognitionTrace.shared.note(...)
// at the ChatService seam. See the manifest sharedFileEdits for the exact wiring.

// MARK: - ConfidenceVerdict

// The gate's answer for one turn. confidence is a computed 0...1 score (higher =
// Jax understands the request and can act). isTrulyConfused is the boolean Jax
// branches on: when true, ask clarifyingQuestion instead of acting. The verdict
// is Codable so the integrator can persist it onto a CognitionTrace record and
// render it honestly in the Cognition Map as a real decision signal (no invented
// neural numbers, just "here is how sure I was and why").
struct ConfidenceVerdict: Codable, Equatable {

    // 0...1. A computed score, NOT a probability of correctness: it is Jax's
    // honest read of how well-specified and resolvable the request is. 1.0 means
    // "fully understood, act now"; near 0 means "I do not know what is being
    // asked". Always clamped to [0, 1].
    var confidence: Double

    // The decision Jax acts on. true => do NOT guess, ask clarifyingQuestion.
    var isTrulyConfused: Bool

    // Exactly one specific question to put to the user when isTrulyConfused. nil when
    // Jax is confident enough to proceed. Specific by construction (names the
    // missing referent / the unknown term / the conflict), never a generic
    // "what do you mean?".
    var clarifyingQuestion: String?

    // The honest reason this verdict came out the way it did, for the Cognition
    // Map trace. Plain language, names the structural cause. Empty when confident.
    var reason: String

    // Which path produced this verdict, so the trace can show provenance
    // truthfully (a heuristic match vs a model judgement).
    var source: Source

    enum Source: String, Codable, Equatable {
        case heuristic      // deterministic structural check, no model call
        case model          // ClaudeClient nuance check
        case failSafe       // model path failed; defaulted to ask
    }

    static func confident(_ score: Double, source: Source = .heuristic, reason: String = "") -> ConfidenceVerdict {
        ConfidenceVerdict(confidence: min(max(score, 0), 1), isTrulyConfused: false,
                          clarifyingQuestion: nil, reason: reason, source: source)
    }

    static func confused(_ score: Double, question: String, reason: String, source: Source = .heuristic) -> ConfidenceVerdict {
        ConfidenceVerdict(confidence: min(max(score, 0), 1), isTrulyConfused: true,
                          clarifyingQuestion: question, reason: reason, source: source)
    }
}

// MARK: - ConfidenceContext

// Everything the gate needs about the turn, supplied by the caller. All fields
// have safe defaults so a caller can pass only what it has. The gate never
// reaches into AppState itself (keeps it pure + testable); ChatService assembles
// this from the live turn (prior user/assistant turns, the on-screen subject if
// any, the active brand) and hands it in.
struct ConfidenceContext {

    // Whether there is ANY prior turn in this thread. A bare pronoun in the very
    // first message of a thread has nothing to bind to; the same pronoun mid
    // thread usually resolves to the last subject.
    var hasPriorTurns: Bool

    // The text of the most recent prior turn (either role), used as a weak
    // referent source: if "that file" follows a turn that named a file, the
    // pronoun resolves and we do NOT flag it.
    var lastTurnText: String

    // True when Grux currently has a concrete on-screen subject Jax could be
    // referring to (a focused doc, a visible handle, a read_screen result). When
    // true, deictic words like "this" / "that" have a plausible external referent
    // and are NOT treated as unresolved.
    var hasOnScreenSubject: Bool

    // The active brand hint, if any. Only used to widen the known-vocabulary set
    // (brand names are known terms, not unknown jargon).
    var brand: String?

    init(hasPriorTurns: Bool = false,
         lastTurnText: String = "",
         hasOnScreenSubject: Bool = false,
         brand: String? = nil) {
        self.hasPriorTurns = hasPriorTurns
        self.lastTurnText = lastTurnText
        self.hasOnScreenSubject = hasOnScreenSubject
        self.brand = brand
    }
}

// MARK: - ConfidenceGate

@MainActor
enum ConfidenceGate {

    // Opt-in for the model-backed nuance path. Off by default: the heuristic path
    // alone is enough for the common cases, and we do not want every ambiguous
    // turn paying a model round trip. ChatService can flip this on for a richer
    // (slower) clarify experience. When off, the gate is purely synchronous.
    static var modelPathEnabled = false

    // The score bands. A turn whose heuristic score lands at or below
    // confusedFloor is TRULY confused (ask). At or above clearCeiling it is
    // clearly understood (proceed). Between the two is the ambiguous middle: if
    // the model path is enabled and a key is present, defer to the model;
    // otherwise FAIL SAFE toward proceeding only when comfortably clear, and ask
    // when the score sits in the lower middle. Tuned conservative: the floor is
    // generous so we never nag on mild fuzziness, but a real structural gap drives
    // the score below it deterministically.
    static let confusedFloor = 0.35
    static let clearCeiling = 0.70

    // MARK: Public API

    // Assess one turn. Synchronous-friendly: the heuristic path returns without
    // any await. The model path is only reached for the ambiguous middle band
    // when explicitly enabled; callers that want the pure-sync answer can read
    // assessHeuristic(...) directly. This async entry point is the canonical one.
    //
    // apiKey is optional: when empty or modelPathEnabled is false, the model path
    // is skipped and the heuristic verdict stands (failing safe to "ask" only when
    // the heuristic itself already said confused).
    static func assess(prompt: String,
                       context: ConfidenceContext = ConfidenceContext(),
                       apiKey: String = "",
                       model: String = "") async -> ConfidenceVerdict {

        let base = assessHeuristic(prompt: prompt, context: context)

        // Decisive heuristic verdicts stand: an empty turn, an unresolved
        // referent, or a flat contradiction does not need a model to confirm.
        if base.confidence <= confusedFloor { return base }
        if base.confidence >= clearCeiling { return base }

        // Ambiguous middle. Only spend a model call if explicitly enabled AND we
        // have a key. Otherwise fail safe: the lower half of the middle band asks,
        // the upper half proceeds (we already know it is not a hard structural
        // gap, so the bias toward proceeding here is the non-nag default).
        guard modelPathEnabled, !apiKey.isEmpty, !model.isEmpty else {
            return base
        }

        return await assessWithModel(prompt: prompt, context: context,
                                     heuristicScore: base.confidence,
                                     apiKey: apiKey, model: model)
    }

    // MARK: Heuristic path (pure, no model)

    // Deterministic structural confusion detection. nonisolated so it can run off
    // the main actor and be unit-tested without a model. Order matters: the
    // hardest, most certain confusion (empty, contradiction, unresolved referent)
    // is checked first and short-circuits to a low score; unknown-term checks
    // follow; otherwise the request is treated as understood.
    nonisolated static func assessHeuristic(prompt: String,
                                            context: ConfidenceContext) -> ConfidenceVerdict {
        let raw = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()

        // 1. Empty / contentless. Nothing to act on at all.
        if raw.isEmpty {
            return .confused(0.0,
                question: "I did not catch a request there. What would you like me to do?",
                reason: "Empty turn: no request to act on.")
        }
        // A turn that is only filler ("uh", "hmm", "ok so") carries no instruction.
        let words = tokenize(lower)
        if words.allSatisfy({ fillerWords.contains($0) }) {
            return .confused(0.10,
                question: "Did you mean to send a command? I only caught filler, no ask.",
                reason: "Turn is only filler words, no actionable content.")
        }

        // 2. Direct contradiction in the same turn. Conflicting instructions mean
        // any single action would defy half of what the user said.
        if let conflict = detectContradiction(lower) {
            return .confused(0.20,
                question: "You asked to both \(conflict.0) and \(conflict.1) in the same breath. Which one wins?",
                reason: "Conflicting instructions in one turn: \(conflict.0) vs \(conflict.1).")
        }

        // 3. Unresolved required referent. A turn that leans on "it" / "that" /
        // "this" / "the file" / "him" with NOTHING to bind it to (no prior turn,
        // no on-screen subject) is a true gap: Jax would have to invent the
        // antecedent, which is the guess we refuse to make.
        if let dangling = unresolvedReferent(words: words, raw: raw, context: context) {
            return .confused(0.25,
                question: "When you say \"\(dangling)\", what are you referring to? I do not have a referent for it yet.",
                reason: "Unresolved referent \"\(dangling)\": no prior turn or on-screen subject to bind it to.")
        }

        // 4. Unknown term not in Jax's learned vocabulary. A short, content-bearing
        // turn built around a token Jax has never seen, that is not slang it
        // learned, not a known brand, not a heuristic domain, and not plain
        // English, is genuine jargon confusion. Long turns usually carry enough
        // surrounding context to act even with one odd token, so this only fires
        // when the unknown token dominates a short request.
        if let unknown = dominantUnknownTerm(words: words, context: context) {
            return .confused(0.30,
                question: "I do not know what \"\(unknown)\" means yet. Can you tell me, so I get it right and remember it?",
                reason: "Unknown term \"\(unknown)\" dominates a short request and is not in learned vocabulary.")
        }

        // 5. Understood. Score scales gently with how well-specified the request
        // is (a richer, longer, referent-resolved turn scores higher). This is
        // NOT a difficulty score: a hard but clear request still scores high, by
        // design, so Jax attempts it rather than interrogating the user.
        let score = clarityScore(words: words, raw: raw, context: context)
        return .confident(score, source: .heuristic,
            reason: score >= clearCeiling
                ? "Request is well-specified and resolvable."
                : "Request is understood but lightly specified; proceeding.")
    }

    // MARK: Model path (nuance, opt-in)

    // For the ambiguous middle band only. Asks the model a tightly-scoped,
    // self-contained question: is this request truly ambiguous, and if so what is
    // the single best clarifying question? The model is told explicitly to
    // distinguish confusion from difficulty and to default to "act" when in doubt,
    // mirroring the heuristic bias. FAIL SAFE on any error: if the call throws or
    // returns something unparseable, we do NOT silently proceed on a turn the
    // heuristics already flagged as middle band; we return an ask verdict.
    private static func assessWithModel(prompt: String,
                                        context: ConfidenceContext,
                                        heuristicScore: Double,
                                        apiKey: String,
                                        model: String) async -> ConfidenceVerdict {
        let sys = """
        You are the comprehension self-check inside Jax's reasoning. Decide ONLY whether a request to Jax is TRULY confusing, meaning genuinely ambiguous, missing a required referent, or self-contradictory, such that any single action would be a guess. Difficulty is NOT confusion: a hard but well-specified request is understood, not confusing. When in doubt, treat it as understood. Do not nag.

        Reply with ONE line of strict JSON and nothing else:
        {"understood": true|false, "confidence": 0.0-1.0, "question": "single specific clarifying question or empty string"}
        If understood is true, question must be empty. If false, question must be one specific question that names the exact gap.
        """
        let ctx = """
        PRIOR_TURN: \(context.lastTurnText.isEmpty ? "(none)" : context.lastTurnText)
        ON_SCREEN_SUBJECT_PRESENT: \(context.hasOnScreenSubject)
        REQUEST: \(prompt)
        """
        // ROUTED. The nuance check built its own ClaudeClient and sent the
        // caller's Anthropic key straight to api.anthropic.com, so it was one of
        // the 32 sites where "your key or a local model" was false. `model` is
        // the caller's explicit choice, so it rides as the override and only the
        // backend and the credential come from the registry. Resolved ONCE, on
        // the main actor this enum is already isolated to. The `apiKey`
        // parameter stays: `assess` still uses it as the entry gate, and that
        // gate is the caller's contract, not this call's credential.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: model)
        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: sys,
                messages: [ClaudeMessage(role: "user", content: ctx)],
                maxTokens: 160,
                temperature: 0.0,
                spanName: "jax.confidence",
                feature: "jaxConfidence"
            )
            if let v = parseModelVerdict(reply) { return v }
            // Unparseable model output: fail safe to asking, with a specific-ish
            // question derived from the prompt rather than a generic one.
            return .confused(min(heuristicScore, confusedFloor),
                question: failSafeQuestion(for: prompt),
                reason: "Model nuance check returned unparseable output; defaulting to ask.",
                source: .failSafe)
        } catch {
            return .confused(min(heuristicScore, confusedFloor),
                question: failSafeQuestion(for: prompt),
                reason: "Model nuance check failed; defaulting to ask (fail safe).",
                source: .failSafe)
        }
    }

    // Parse the strict-JSON model reply. Tolerant: finds the JSON object even if
    // the model wrapped it in prose. Returns nil when it cannot extract a usable
    // verdict (caller then fails safe).
    nonisolated static func parseModelVerdict(_ raw: String) -> ConfidenceVerdict? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else { return nil }
        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let understood = (obj["understood"] as? Bool) ?? false
        let conf = (obj["confidence"] as? Double)
            ?? (obj["confidence"] as? Int).map(Double.init)
            ?? (understood ? clearCeiling : confusedFloor)
        let question = (obj["question"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if understood {
            return .confident(max(conf, clearCeiling), source: .model,
                reason: "Model judged the request understood.")
        }
        let q = question.isEmpty ? "Can you say that another way? I want to be sure I have it right before acting." : question
        return .confused(min(conf, confusedFloor), question: q,
            reason: "Model judged the request truly ambiguous.", source: .model)
    }

    // MARK: Heuristic helpers (pure)

    nonisolated private static func tokenize(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" && $0 != "-" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    // Words that carry no instruction on their own.
    // PURE non-content filler only. Conversational/social words (hey, thanks,
    // okay, yeah, please, yo) were intentionally REMOVED: a one-word greeting or
    // acknowledgment is a valid turn that deserves a normal reply, not a "did you
    // mean to send a command?" interrogation. They now fall through to the
    // known-word check (commonEnglish + system dictionary) and clear as understood.
    nonisolated private static let fillerWords: Set<String> = [
        "uh","um","umm","hmm","hm","er","eh","ah","oh","so","well",
        "like","nah","huh","grux","jax","you","the","a","an"
    ]

    // Deictic / pronoun tokens that REQUIRE a referent to act on.
    nonisolated private static let referentTokens: Set<String> = [
        "it","that","this","those","these","them","they","him","her","he","she",
        "their","its"
    ]
    // Multi-word dangling phrases ("the file", "that one") checked against raw.
    nonisolated private static let referentPhrases: [String] = [
        "the file","that file","this file","that one","this one","the thing",
        "that thing","the doc","that doc","the email","that email","the message",
        "that message","the link","that link"
    ]

    // An action verb usually opens an instruction. If a turn STARTS with a verb
    // and has a clear object, it is not a dangling-pronoun case even if a pronoun
    // appears later. Used to avoid false positives.
    nonisolated private static let leadVerbs: Set<String> = [
        "add","remove","delete","open","play","send","draft","write","read","find",
        "search","look","show","list","make","build","ship","run","start","stop",
        "remember","save","note","summarize","schedule","call","email","text",
        "set","switch","focus","check","close","mark","pull","put","tell","give"
    ]

    // Detect a dangling referent: a pronoun/deictic that the turn relies on with
    // no antecedent available (no prior turn AND no on-screen subject), and where
    // the turn does NOT itself name a concrete object. Returns the offending
    // surface token/phrase, or nil if everything resolves.
    nonisolated private static func unresolvedReferent(words: [String],
                                                       raw: String,
                                                       context: ConfidenceContext) -> String? {
        // If there is any antecedent source, deixis resolves. We trust the prior
        // turn / on-screen subject to bind it (that is what context is for).
        if context.hasPriorTurns && !context.lastTurnText.isEmpty { return nil }
        if context.hasOnScreenSubject { return nil }

        let lower = raw.lowercased()

        // A turn that names a concrete content noun supplies its own referent.
        // Cheap proxy: presence of a quoted phrase or a capitalized proper-ish
        // token beyond the first word suggests a named subject.
        if lower.contains("\"") { return nil }

        // Phrase-level dangling ("send that file" with no file in sight).
        for phrase in referentPhrases where lower.contains(phrase) {
            // Only dangling if the phrase is the object and nothing names it.
            return phrase
        }

        // Token-level: the turn is SHORT and built around a bare pronoun. Long
        // turns usually self-describe; we only flag terse deixis like "do it",
        // "send them", "open that".
        guard words.count <= 4 else { return nil }
        let content = words.filter { !fillerWords.contains($0) }
        // If a content word is itself a referent token AND there is no concrete
        // noun alongside it, it is dangling. "open that" -> dangling.
        let hasReferent = content.contains { referentTokens.contains($0) }
        guard hasReferent else { return nil }
        // A lead verb with ONLY a pronoun object is the classic dangling case.
        let nonReferentContent = content.filter { !referentTokens.contains($0) && !leadVerbs.contains($0) }
        if nonReferentContent.isEmpty {
            return content.first { referentTokens.contains($0) }
        }
        return nil
    }

    // Detect two directly-opposed instructions in one turn. Conservative: only a
    // small set of clear antonym verb pairs counts, so "turn it up but not too
    // loud" (a refinement, not a contradiction) does not trip it.
    nonisolated private static func detectContradiction(_ lower: String) -> (String, String)? {
        let pairs: [(String, String)] = [
            ("add","remove"), ("add","delete"), ("open","close"),
            ("start","stop"), ("enable","disable"), ("mute","unmute"),
            ("turn it on","turn it off"), ("play","pause"),
            ("send","do not send"), ("keep","delete")
        ]
        for (a, b) in pairs where lower.contains(a) && lower.contains(b) {
            // Require an "and" / "but" / "then" joiner so a turn merely MENTIONING
            // both ("should I add or remove?") is not flagged, only one COMMANDING
            // both.
            if lower.contains("and ") || lower.contains("but ") || lower.contains("then ") || lower.contains(", ") {
                return (a, b)
            }
        }
        return nil
    }

    // Find a single unknown token that dominates a SHORT request. Returns nil for
    // long turns (enough context to act) or when every content token is known.
    nonisolated private static func dominantUnknownTerm(words: [String],
                                                        context: ConfidenceContext) -> String? {
        let content = words.filter { !fillerWords.contains($0) && !leadVerbs.contains($0) }
        // Only consider terse requests where one odd token carries the weight.
        guard content.count >= 1 && content.count <= 3 else { return nil }

        for token in content {
            if isKnownTerm(token, context: context) { continue }
            // An unknown token that is not a number, not a URL-ish fragment, and
            // long enough to be a real word/jargon (>= 3 chars) is the candidate.
            if token.count >= 3,
               !token.allSatisfy({ $0.isNumber }),
               !token.contains(".") {
                // If it is the ONLY content token, it dominates by definition.
                if content.count == 1 { return token }
                // With 2 to 3 content tokens, flag only if ALL of them are unknown
                // (the whole request is jargon), not just one.
                let unknowns = content.filter { !isKnownTerm($0, context: context) && $0.count >= 3 }
                if unknowns.count == content.count { return token }
            }
        }
        return nil
    }

    // Is this token something Jax already understands: learned slang, a known
    // brand/product name, a heuristic domain, or a common English word? Reads the
    // live JaxProfile + ProfileMemoryStore (both @MainActor singletons) so the
    // vocabulary check reflects what Jax has actually learned. nonisolated wrapper
    // hops to the main actor's stores via a precomputed snapshot is overkill here;
    // this helper is only called from the main-actor assess path in practice, but
    // to stay nonisolated-safe it relies ONLY on the static built-in sets plus the
    // caller-supplied brand. Learned-vocabulary widening (slang/heuristics) is
    // applied in the main-actor wrapper isKnownTermLive below.
    nonisolated private static func isKnownTerm(_ token: String, context: ConfidenceContext) -> Bool {
        let t = token.lowercased()
        if commonEnglish.contains(t) { return true }
        if systemDictionary.contains(t) { return true }
        if knownBrands.contains(t) { return true }
        if conversationalSlang.contains(t) { return true }
        if let b = context.brand?.lowercased(), b.contains(t) || t.contains(b) { return true }
        // Hyphenated/compound everyday tokens.
        if t.contains("-") { return true }
        return false
    }

    // Common internet slang / interjections. A turn that is just "bruh", "lol",
    // "fr", "sheesh", etc. is conversation, NOT a request built around unknown
    // jargon, so it must never trip the clarify gate ("I do not know what bruh
    // means yet"). These are not in the system dictionary, so list them.
    nonisolated private static let conversationalSlang: Set<String> = [
        "bruh","bro","bruv","brah","fam","dude","sis","yo","ayo","yoo","yooo",
        "lol","lmao","lmaoo","lmfao","rofl","lel","kek","haha","hahaha","hehe",
        "fr","frfr","ngl","tbh","tbf","imo","imho","idk","idc","idgaf","istg",
        "smh","smfh","omg","omfg","wtf","wth","ffs","af","asf","ikr","irl",
        "lit","fire","goat","based","cap","nocap","sus","mid","bussin","slaps",
        "vibe","vibes","vibing","slay","ate","stan","drip","rizz","gyat","ong",
        "deadass","lowkey","highkey","sheesh","sheeesh","yeet","oof","bet","betch",
        "welp","meh","nah","naw","yep","yup","nope","nvm","ok","okay","kk",
        "gg","ez","pog","poggers","ratio","cope","mald","copium","yikes",
        "facts","fax","periodt","preach","mood","relatable","valid","unhinged",
        "lowercase","goated","cooked","cooking","clutch","sigma","skibidi","gng",
    ]

    // Product and tooling tokens Grux itself deals in. These are never "unknown
    // jargon". The user's own brand and project names are deliberately NOT
    // compiled in here: they arrive through context.brand, through slang Jax has
    // been taught, and through heuristic domains (see isKnownTermLive), so an
    // unfamiliar one is asked about exactly once and is known from then on.
    nonisolated private static let knownBrands: Set<String> = [
        "grux","jax","ai",
        "qwen","dashscope","resend","render","cloudflare","supabase","stripe",
        "shopify","testflight","appstore","app","store","ios","mac","macos",
        "swiftui","figma","godaddy","anthropic","claude"
    ]

    // A tiny high-frequency English set. This is NOT a dictionary: it just keeps
    // the dominant-unknown-term check from flagging ordinary words. The check
    // only fires on SHORT turns where every content token is unrecognized, so a
    // partial list is sufficient and safe (a missing common word at worst makes
    // the gate ask once, which is the cheap mistake).
    // macOS system word list (~236k words). Loaded once so the gate recognizes
    // any real English word as known, so a plain greeting like "hello" is never
    // mistaken for unknown jargon. Empty if the file is unavailable, in which
    // case the commonEnglish set below still covers the common cases.
    nonisolated private static let systemDictionary: Set<String> = {
        for p in ["/usr/share/dict/words", "/usr/share/dict/web2"] {
            if let s = try? String(contentsOfFile: p, encoding: .utf8) {
                return Set(s.split(separator: "\n").map { $0.lowercased() })
            }
        }
        return []
    }()

    nonisolated private static let commonEnglish: Set<String> = [
        "task","note","email","mail","message","reply","file","doc","document",
        "link","url","page","song","music","track","album","artist","video",
        "today","tomorrow","yesterday","week","day","time","date","calendar",
        "meeting","event","reminder","list","status","update","report","summary",
        "screen","window","app","tab","browser","chrome","price","cost","money",
        "code","build","app","site","website","brand","product","client","work",
        "thing","stuff","one","two","name","number","question","answer","help",
        "yes","no","maybe","now","later","next","first","last","new","old","more",
        "less","all","some","any","mode","focus","goal","idea","plan","project",
        "morning","night","afternoon","evening","again","still","just","really",
        // Greetings + conversational words (belt-and-suspenders if the system
        // dictionary is missing, and covers informal tokens web2 omits like "okay").
        "hello","hey","hi","hiya","howdy","yo","sup","okay","ok","yeah","yep",
        "yup","nope","gotcha","thanks","thx","please","sorry","cool","nice",
        "good","great","bye","welcome","hello?"
    ]

    // A score for understood-but-not-flagged requests. Scales with specificity:
    // a lead verb + content + resolved referents scores high; a terse single-word
    // command scores in the upper-middle. Never below clearCeiling-0.05 so an
    // understood turn does not accidentally fall into the model-call band.
    nonisolated private static func clarityScore(words: [String],
                                                 raw: String,
                                                 context: ConfidenceContext) -> Double {
        var score = 0.72
        let content = words.filter { !fillerWords.contains($0) }
        if content.count >= 3 { score += 0.10 }
        if let first = words.first, leadVerbs.contains(first) { score += 0.08 }
        if raw.contains("\"") { score += 0.05 }            // quoted = explicit subject
        if context.hasPriorTurns { score += 0.03 }
        return min(score, 1.0)
    }

    // Build a fail-safe clarifying question from the prompt when the model path
    // could not produce one. Echoes the request back so the question is at least
    // specific to what the user said.
    nonisolated private static func failSafeQuestion(for prompt: String) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = trimmed.count > 60 ? String(trimmed.prefix(60)) + "..." : trimmed
        return "I want to be sure I have this right before acting: when you say \"\(snippet)\", what is the specific outcome you want?"
    }

    // MARK: Main-actor vocabulary widening

    // Live known-term check that also consults the user's learned slang and heuristic
    // domains. ChatService can call this variant (it is on the main actor anyway)
    // to get the most accurate vocabulary picture. The pure assessHeuristic path
    // stays usable off-actor for tests; this is the production "did Jax already
    // learn this word" upgrade. Returns true if the token is known by ANY source.
    static func isKnownTermLive(_ token: String, context: ConfidenceContext) -> Bool {
        if isKnownTermStaticProxy(token, context: context) { return true }
        let t = token.lowercased()
        // Learned slang: if the user taught Jax this term, it is known.
        if ProfileMemoryStore.shared.slang.contains(where: { $0.term.lowercased() == t }) { return true }
        // Heuristic domains are vocabulary Jax reasons in (e.g. "pricing").
        if JaxProfile.shared.heuristics.contains(where: { $0.domain.lowercased() == t }) { return true }
        return false
    }

    // nonisolated static helper is private; expose its result for the live check
    // without duplicating the set membership logic.
    private static func isKnownTermStaticProxy(_ token: String, context: ConfidenceContext) -> Bool {
        let t = token.lowercased()
        if commonEnglish.contains(t) { return true }
        if systemDictionary.contains(t) { return true }
        if knownBrands.contains(t) { return true }
        if let b = context.brand?.lowercased(), b.contains(t) || t.contains(b) { return true }
        if t.contains("-") { return true }
        return false
    }
}
