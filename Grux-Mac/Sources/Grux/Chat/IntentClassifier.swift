import Foundation

// Lightweight keyword-based intent classifier for relevance-gating the
// volatile system block in ChatService.buildSystemBlocks. Decides which
// optional context sections (TASK_STACK, RECENT_FOCUS, AVAILABLE_MACROS,
// PROPOSED_ACTIONS) are worth shipping for a given user utterance.
//
// Why keyword matching, not an LLM classifier? Because a classifier call
// would itself cost tokens - we'd be spending input tokens to save input
// tokens. Keywords are free, deterministic, and perfectly adequate for
// "is this a music request" type buckets.
//
// Default behavior is conservative: if the classifier isn't sure, INCLUDE
// the section. Wrong inclusion costs tokens; wrong exclusion costs the
// model a piece of context it might have needed. We bias toward inclusion
// on ambiguity.
enum ChatIntentClassifier {

    struct VolatileSections: Equatable, Sendable {
        var taskStack: Bool         // user's active task list
        var proposedActions: Bool   // ambient-detected proposed actions
        var recentFocus: Bool       // last 15min of FocusWatcher verdicts
        var availableMacros: Bool   // VoiceMacroRegistry trigger phrases

        // Sections always emitted regardless of intent - they're either
        // free (tiny) or load-bearing for safety:
        // - RECENT_SPOKEN_MEMORIES: prevents re-firing stale ambient commands
        // - PENDING_MEMORIES: low cost (~100 tokens), assistant decides
        //   whether to surface
        // - RELEVANT_MEMORIES: SemanticMemory retrieval is context-aware

        // The "include everything" baseline, used when the utterance is
        // empty, when the classifier can't make a decision, or when the
        // safety-default kicks in.
        static let all = VolatileSections(
            taskStack: true,
            proposedActions: true,
            recentFocus: true,
            availableMacros: true
        )

        // The "playing music" / "open URL" / pure utility shape - none of
        // the focus/task context is relevant.
        static let utility = VolatileSections(
            taskStack: false,
            proposedActions: false,
            recentFocus: false,
            availableMacros: true
        )
    }

    // Word-boundary matcher: returns true when `text` contains any of
    // `keywords` as a whole word (case-insensitive). Avoids false positives
    // like "task" matching inside "fantastic".
    static func containsAnyWord(_ text: String, keywords: Set<String>) -> Bool {
        let lowered = text.lowercased()
        for kw in keywords {
            // Word boundary on either side (start/end of string or non-letter).
            let pattern = "(?:^|[^a-z])\(NSRegularExpression.escapedPattern(for: kw))(?:[^a-z]|$)"
            if let re = try? NSRegularExpression(pattern: pattern),
               re.firstMatch(in: lowered, range: NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)) != nil {
                return true
            }
        }
        return false
    }

    // Keyword sets per intent family. Tuned for the way people actually talk
    // to Grux based on AVAILABLE_MACROS / V2 trigger / system-prompt examples.

    static let taskKeywords: Set<String> = [
        "task", "tasks", "todo", "to-do", "todos", "list", "stack",
        "plate", "schedule", "agenda", "rundown",
        "remind", "reminder", "remember", "scratch",
        "shipped", "shipping", "ship", "shipped it", "knock", "knocked",
        "finished", "complete", "completed", "done", "did",
        "promote", "dismiss", "focus", "now", "next", "later",
        "current", "working on", "what am i", "what's on", "what are you",
        "drop", "delete", "remove", "kill", "nuke"
    ]

    static let focusKeywords: Set<String> = [
        "focused", "focus", "focusing", "drift", "drifting", "drifted",
        "off-task", "off task", "distracted", "distraction",
        "productive", "productivity", "tracking", "track",
        "scan", "rescan", "re-scan", "screen", "looking at",
        "what am i on", "what app", "what window",
        "doing", "currently", "right now"
    ]

    static let musicKeywords: Set<String> = [
        "play", "song", "music", "track", "album", "artist",
        "spotify", "apple music", "youtube",
        "hype", "chill", "vibe", "tune", "jam",
        "pause", "stop", "skip", "next track", "volume",
        "sing", "beat", "playlist"
    ]

    // Macro-trigger detection: whether the utterance might be invoking a
    // voice macro. Macros are user-defined and dynamic, so this cannot be an
    // exhaustive list. It is a cheap hint on top of the `isShort` rule below,
    // which is what actually catches a one-word trigger nobody could predict.
    //
    // This list used to carry one person's private slang ("daddy", "pit crew",
    // "hit the", "lock in"), which biased a stranger's classifier toward
    // vocabulary they have never used and would never say. Those are gone. What
    // remains is either an ordinary English verb for launching something, or a
    // real product noun: chill / normal / grind / sheesh are the four GruxMode
    // cases, so they are Grux's own vocabulary rather than anyone's personal
    // idiom.
    //
    // The honest signal, if this ever needs to be stronger, is the user's own
    // registered macro triggers rather than a longer guess.
    static let macroKeywords: Set<String> = [
        "open", "launch", "fire up", "pull up", "boot up", "start",
        "switch to", "go to", "tile", "arrange",
        "lights", "volume", "do not disturb", "dnd",
        "chill mode", "grind mode", "normal mode", "sheesh mode",
        "mode"
    ]

    // Classify a single user utterance into the set of volatile sections
    // worth shipping in this turn's system prompt.
    //
    // Edge cases handled explicitly:
    // - Empty / whitespace-only → safety default (include everything).
    // - Utterance contains an image (caller signals via hasImage) →
    //   include focus/screen sections (he's likely showing us something).
    // - Very short utterance (≤ 3 words) → likely a macro trigger or
    //   one-liner; bias toward inclusion of macros + tasks.
    static func classify(utterance: String, hasImage: Bool = false) -> VolatileSections {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .all }

        // Image input → he's likely asking about what's on the screen.
        if hasImage {
            var sections = VolatileSections.all
            // Music + macros aren't relevant when he's pointing at an image.
            sections.availableMacros = false
            return sections
        }

        let words = trimmed.split { !$0.isLetter && !$0.isNumber }.count
        let isShort = words <= 3

        let touchesTasks = containsAnyWord(trimmed, keywords: taskKeywords)
        let touchesFocus = containsAnyWord(trimmed, keywords: focusKeywords)
        let touchesMusic = containsAnyWord(trimmed, keywords: musicKeywords)
        let touchesMacro = containsAnyWord(trimmed, keywords: macroKeywords) || isShort

        // Pure utility request (music or open URL) with no other signals →
        // shed everything except macros (Claude may need to call run_macro
        // to actually execute "open chrome").
        if touchesMusic && !touchesTasks && !touchesFocus {
            return .utility
        }

        // Otherwise build up sections by signal.
        return VolatileSections(
            taskStack: touchesTasks,
            // Proposed actions only matter if the user is doing task-stack work.
            proposedActions: touchesTasks,
            // Focus block only when the utterance smells focus-related.
            recentFocus: touchesFocus,
            // Macros are tiny - include them if the utterance might be a
            // trigger or whenever the user is doing utility-shaped stuff.
            availableMacros: touchesMacro || touchesMusic
        )
    }

    // MARK: - Voice-first PIM routes (Foundry batch 2)

    // Deterministic fast-path route for PIM utterances: "put X on my
    // calendar Friday 3pm", "note that ...", "email Sarah about ...",
    // "find the doc about ...". Confident matches skip the Claude round
    // trip; ChatService.send consults this AFTER the Commands V2 trigger
    // check and BEFORE shipping the turn to Claude, then hands the plan to
    // PIMConfirmationController (spoken ack + 5s undo window + execution
    // through ChatService.dispatchTool). Pattern + slot logic lives in
    // PIMIntents; this is just the classifier-side route so all utterance
    // routing decisions stay discoverable from one file.
    //
    // nil = not a confident PIM command; fall through to the normal path.
    static func pimRoute(utterance: String, now: Date = Date()) -> PIMPlan? {
        PIMIntents.plan(for: utterance, now: now)
    }

    // MARK: - The engine as a second opinion on the fast path

    /// What the router decided and what it cost, so the caller can log it and
    /// the release notes can carry a measured latency.
    struct PIMRouteDecision: Equatable {
        let confidence: Double
        let latencyMs: Int
        let provider: DecisionProviderKind
        /// False means "do not take the fast path", not "do nothing". The
        /// utterance goes to the model like any other turn.
        let confirmed: Bool
    }

    /// The pattern matcher PROPOSES; the engine may only VETO.
    ///
    /// The fast path skips the model entirely and then acts, so a wrong match
    /// executes a wrong calendar event with a spoken acknowledgement. The
    /// engine is a second opinion on that, and it is deliberately one-way:
    ///
    /// - No match from the pattern matcher means no fast path, and the engine
    ///   is never asked. It cannot invent a route that the deterministic path
    ///   did not find.
    /// - On device the answer to a yes/no question is 0.5, which is the
    ///   provider saying it cannot judge. That is not a veto, so a person with
    ///   no key gets exactly today's behaviour and never a new refusal.
    /// - Only a provider that can actually judge, answering below the execute
    ///   threshold, sends the utterance to the model instead.
    ///
    /// Takes an ALREADY MATCHED plan rather than matching one itself. That is
    /// load-bearing: `send()` runs on the main actor, and an `await` anywhere
    /// above the readiness guard is a suspension point that lets other
    /// main-actor work interleave before the guard is read. Measured
    /// 2026-09-20: awaiting a version of this that matched internally let a
    /// turn which should have been refused locally reach the network and come
    /// back HTTP 400, which is the exact hole that guard exists to close. The
    /// caller matches synchronously and only suspends once there is something
    /// to ask about.
    static func confirmPIMRoute(plan: PIMPlan,
                                utterance: String,
                                engine: DecisionEngine,
                                threshold: Double) async -> PIMRouteDecision {
        let result = await engine.decide(
            surface: pimGate,
            state: pimState(plan: plan, utterance: utterance),
            questions: pimQuestions)
        return pimDecision(answer: result.answers["meant"], provider: result.provider,
                           latencyMs: result.latencyMs, threshold: threshold)
    }

    /// Chat's use of this gate: the answer a batched event already carries for
    /// these exact words and this exact plan, or else one call of its own.
    static func resolvePIM(plan: PIMPlan, utterance: String, preDecided: PreDecidedPIM?,
                           engine: DecisionEngine, threshold: Double) async -> PIMRouteDecision {
        if !plan.kind.isJudged {
            return PIMRouteDecision(confidence: 1, latencyMs: 0, provider: .local, confirmed: true)
        }
        if let preDecided, preDecided.applies(to: plan, utterance: utterance) { return preDecided.decision }
        return await confirmPIMRoute(plan: plan, utterance: utterance, engine: engine, threshold: threshold)
    }

    /// The gate's name on the engine and in the ledger.
    static let pimGate = "chat.intent"

    /// What the engine judges a matched plan against.
    ///
    /// Names the action and today's date. Without them the judge saw only a
    /// card title and a time, could not tell a calendar event from a note, and
    /// could not check "Friday" against anything, so it held back plain asks
    /// (live 2026-09-27: 0.33 for a calendar ask, 0.46 for a note).
    static func pimState(plan: PIMPlan, utterance: String, today: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEEE, MMMM d yyyy"
        return "The person said: \(utterance)\nToday is \(f.string(from: today)).\n"
            + "Grux is about to \(plan.kind.judgeAction) without asking anything else: "
            + "\(plan.cardTitle). \(plan.cardDetail)"
    }

    static var pimQuestions: [String: DecisionQuestion] { ["meant": .noul(instructions: pimInstructions)] }

    /// The verdict from an answer, whoever asked the question: this gate on its
    /// own, or a batched event that asked on its behalf. Pure.
    static func pimDecision(answer: DecisionAnswer?, provider: DecisionProviderKind,
                            latencyMs: Int, threshold: Double) -> PIMRouteDecision {
        guard case .noul(let probability)? = answer else {
            return PIMRouteDecision(confidence: 1, latencyMs: latencyMs, provider: provider, confirmed: true)
        }
        // A provider that cannot judge does not get a vote.
        let confirmed = provider == .local || probability >= threshold
        return PIMRouteDecision(confidence: probability, latencyMs: latencyMs,
                                provider: provider, confirmed: confirmed)
    }

    /// A verdict this gate already has, because a spoken request asked its
    /// question on the voice event's one call (P-R-1). Chat reads it instead of
    /// opening a second round trip on the same utterance. It only counts for
    /// the exact words and the exact plan it was decided for.
    struct PreDecidedPIM: Equatable {
        let utterance: String
        let planKind: PIMIntentKind
        let cardTitle: String
        let decision: PIMRouteDecision

        func applies(to plan: PIMPlan, utterance other: String) -> Bool {
            utterance == other && planKind == plan.kind && cardTitle == plan.cardTitle
        }
    }

    static let pimInstructions =
        "Is that what the person asked for? Answer high only if the action matches what they said, "
        + "including the date, the time and the people named. Answer low if any of those were guessed, "
        + "if they were asking a question rather than giving an instruction, or if they were talking "
        + "about the thing rather than asking for it to be done."
}
