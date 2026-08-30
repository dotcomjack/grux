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
}
