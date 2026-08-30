import Foundation

// ConfidenceStressTest: a labeled battery that calibrates Jax's never-guess gate.
//
// WHY THIS EXISTS: the never-guess mechanism scored 76 in an end-to-end run,
// partly because content generation did not route ungrounded facts through the
// gate. The visible symptom was Jax writing that a body wash "costs $18"
// when the real catalog price is $15. This battery makes the gate's calibration testable
// and visible: it runs a set of LABELED prompts, two classes, through the SAME
// production path (ConfidenceGate.assessGroundedHeuristic, which layers the
// ungrounded-fact check on the structural heuristics), and scores how well the
// gate's "ask vs proceed" decision matches the labels.
//
// Two error types, named honestly because they cost differently:
//   - FALSE ASK   (the gate asked on a CLEAR prompt): nagging. Annoying, cheap.
//   - MISSED ASK  (the gate proceeded on a TRULY-CONFUSED prompt): guessing.
//     This is the expensive mistake, the $18 class. We weight recall on the
//     "ask" decision accordingly in the readable report.
//
// HONESTY CONTRACT: this harness reports ONLY the gate's real verdicts on real
// prompts. It does not fabricate a score, does not hide a misclassification, and
// names every prompt the gate got wrong with the verdict it actually returned.
//
// House style: @MainActor enum of statics, zero em/en dashes, dollars as $N, no
// vendor/model/stack names. No new SPM deps. The check is pure (no model call),
// so the battery is deterministic and runs offline.

@MainActor
enum ConfidenceStressTest {

    // MARK: - Labeled cases

    // The expected gate decision for a case. shouldAsk = true means a correct
    // gate ASKS a clarifying question (the prompt is truly confused). false means
    // a correct gate PROCEEDS (the prompt is clear, however hard).
    private struct Case {
        let prompt: String
        let shouldAsk: Bool
        let note: String              // why it is labeled this way
        let context: ConfidenceContext
        // For draft-style cases, the text whose product numbers to scan (a
        // generated draft) differs from the prompt. nil => scan the prompt.
        let draft: String?

        init(_ prompt: String, ask: Bool, note: String,
             context: ConfidenceContext = ConfidenceContext(), draft: String? = nil) {
            self.prompt = prompt
            self.shouldAsk = ask
            self.note = note
            self.context = context
            self.draft = draft
        }
    }

    // TRULY-CONFUSED battery: each SHOULD trigger a clarifying question. Mix of
    // structural confusion (empty, dangling referent, contradiction, unknown
    // term) and the new ungrounded-fact class (assert a product number with no
    // catalog backing), realistic to everyday work.
    private static let confusedCases: [Case] = [
        // -- The $18 bug class: assert a fact with no catalog backing. --
        Case("Write a blog post that says the body wash costs $18.",
             ask: true, note: "Ungrounded price: real wash is $15, not $18 (the original bug)."),
        Case("Tweet that our bar soap is just $9.",
             ask: true, note: "Ungrounded price: bar 2-pack is $13, not $9."),
        Case("Put in the email that the body lotion is 12 oz.",
             ask: true, note: "Ungrounded size: lotion is 10.2 oz, not 12 oz."),
        Case("Say the body scrub is $20 in the ad copy.",
             ask: true, note: "Ungrounded price: scrub is $13, not $20."),
        Case("Reference SKU lavender-forest-gel on the product page.",
             ask: true, note: "Ungrounded SKU: no gel format exists, only wash/lotion/bar/scrub."),
        Case("Write that the body wash is 24 oz for the listing.",
             ask: true, note: "Ungrounded size: wash is 16.9 oz, not 24 oz."),
        Case("Caption: the goat-milk-oasis bar is a single bar for $7.",
             ask: true, note: "Ungrounded: bar is ALWAYS a 2-pack at $13, no single-bar SKU at $7."),
        // -- Structural confusion. --
        Case("",
             ask: true, note: "Empty turn: nothing to act on."),
        Case("send that",
             ask: true, note: "Dangling referent: no prior turn or on-screen subject."),
        Case("add the lavender scent and remove the lavender scent, then ship it.",
             ask: true, note: "Direct contradiction: add and remove the same thing in one turn."),
        Case("frobnicate the zorptastic",
             ask: true, note: "Unknown jargon dominating a short request, not learned vocabulary."),
        Case("open that one",
             ask: true, note: "Dangling deixis: 'that one' with no antecedent."),
        Case("uh hmm ok so",
             ask: true, note: "Filler only, no actionable instruction."),
        Case("State the exact price of the arctic-frost wash in the post.",
             ask: false, note: "CONTROL inside confused list: this asks ME to look it up, it is grounded (real SKU), so the gate should PROCEED and retrieve, not ask. Labeled ask=false on purpose to keep the battery honest."),
    ]

    // CLEAR battery: each SHOULD proceed. Specific, actionable, some genuinely
    // hard, none ambiguous. Includes grounded product facts (real prices/sizes)
    // that must NOT be flagged, so the gate does not become a nag.
    private static let clearCases: [Case] = [
        // -- Grounded product facts: real numbers, must NOT be flagged. --
        Case("Write a blog post noting the body wash is $15.",
             ask: false, note: "Grounded price: $15 wash is the real catalog price."),
        Case("Tweet that the bar soap 2-pack is $13.",
             ask: false, note: "Grounded: bar 2-pack is $13."),
        Case("Email that the body lotion is 10.2 oz.",
             ask: false, note: "Grounded size: lotion is 10.2 oz."),
        Case("Mention the body scrub is a 5.5 oz jar for $13.",
             ask: false, note: "Grounded: scrub is 5.5 oz at $13."),
        Case("List the turmeric-citrus-grove-wash SKU on the page.",
             ask: false, note: "Grounded SKU: real scent + real format."),
        Case("Note the bar is two 4.95 oz bars in the listing.",
             ask: false, note: "Grounded size: 4.95 oz per bar (2-pack)."),
        Case("Write that the bar 2-pack is 9.9 oz total in the copy.",
             ask: false, note: "Grounded size: bar 2-pack total is 2 x 4.95 = 9.9 oz. Both the nonisolated check and FactGuard.audit must ground this pack total from the shared seed; a divergence here is the over-trigger this case guards against.",
             context: ConfidenceContext(brand: ProductCatalogSeed.brand)),
        // -- Clear non-product asks. --
        Case("Draft a reply thanking the new follower and pointing them to the help center.",
             ask: false, note: "Specific, actionable comms task."),
        Case("Refactor the SwiftUI Chat tab to use the full GruxTheme treatment.",
             ask: false, note: "Hard but well-specified iOS/Mac work, not confusing."),
        Case("Add a Subscribe and Save 15% badge to the product page.",
             ask: false, note: "Specific production change, grounded discount (15%)."),
        Case("Summarize today's product funnel numbers into three bullets.",
             ask: false, note: "Specific analytics task."),
        Case("Build a cold outreach email for one founding client at the $249 teardown price.",
             ask: false, note: "Specific comms; $249 is a service price, not a product fact, must not flag."),
        Case("Schedule a build of the Grux Mac app for tomorrow morning and open the Chat tab to verify.",
             ask: false, note: "Multi-step but fully specified."),
        Case("Generate alt text for the goat-milk-oasis lotion hero image.",
             ask: false, note: "Specific creative task, no factual number asserted."),
        Case("Set the App Store subtitle to the new tagline I pasted above.",
             ask: false, note: "Resolved referent (pasted above), specific.",
             context: ConfidenceContext(hasPriorTurns: true, lastTurnText: "Here is the tagline: Snap, sort, ship.")),
    ]

    // MARK: - Run

    // Runs every labeled prompt through the production grounded gate, scores the
    // ask-decision precision/recall, and returns a readable report naming any
    // misclassification with the verdict the gate actually produced. Pure: no
    // model call, deterministic, offline.
    static func run() async -> String {
        var lines: [String] = []
        func L(_ s: String = "") { lines.append(s) }

        L("==============================================")
        L("JAX CONFIDENCE GATE STRESS TEST")
        L("==============================================")
        L("started: \(timestamp())")
        L("path: ConfidenceGate.assessGroundedHeuristic (structural heuristics + ungrounded-fact check)")
        L("note: pure offline check, no model call, deterministic.")
        L("")
        L("Two error types, named by what they cost:")
        L("  FALSE ASK  = gate asked on a CLEAR prompt (nagging, cheap mistake).")
        L("  MISSED ASK = gate proceeded on a TRULY-CONFUSED prompt (guessing, the $18 class).")
        L("")

        var truePositive = 0   // should ask, did ask
        var falseNegative = 0  // should ask, did NOT ask (MISSED ASK, the dangerous one)
        var trueNegative = 0   // should proceed, did proceed
        var falsePositive = 0  // should proceed, but asked (FALSE ASK, nagging)

        var missedAsks: [String] = []
        var falseAsks: [String] = []

        let all = confusedCases.map { ($0, "TRULY-CONFUSED") }
            + clearCases.map { ($0, "CLEAR") }

        L("---- PER-PROMPT RESULTS ----")
        for (c, klass) in all {
            let verdict = ConfidenceGate.assessGroundedHeuristic(
                prompt: c.prompt, factText: c.draft, context: c.context
            )
            let didAsk = verdict.isTrulyConfused
            let correct = (didAsk == c.shouldAsk)

            if c.shouldAsk {
                if didAsk { truePositive += 1 } else { falseNegative += 1 }
            } else {
                if didAsk { falsePositive += 1 } else { trueNegative += 1 }
            }

            let mark = correct ? "ok " : "XX "
            let decision = didAsk ? "ASK   " : "PROCEED"
            let want = c.shouldAsk ? "ASK" : "PROCEED"
            let shown = c.prompt.isEmpty ? "(empty turn)" : truncate(c.prompt, 64)
            L("  [\(mark)] \(decision) (want \(want)) conf=\(fmt(verdict.confidence)) [\(klass)] \(shown)")
            if !correct {
                if c.shouldAsk {
                    missedAsks.append("    MISSED ASK (guessed): \(shown)\n      label-reason: \(c.note)\n      gate-reason: \(verdict.reason)")
                } else {
                    falseAsks.append("    FALSE ASK (nagged): \(shown)\n      label-reason: \(c.note)\n      gate-asked: \(verdict.clarifyingQuestion ?? "(no question)")")
                }
            }
        }
        L("")

        // Scores on the ASK decision (positive class = "ask").
        let askPrecision = ratio(truePositive, truePositive + falsePositive)
        let askRecall = ratio(truePositive, truePositive + falseNegative)
        let f1 = (askPrecision + askRecall) == 0 ? 0
            : 2 * askPrecision * askRecall / (askPrecision + askRecall)
        let total = all.count
        let correctCount = truePositive + trueNegative
        let accuracy = ratio(correctCount, total)

        L("---- SCORES (positive class = ASK) ----")
        L("  cases: \(total)  (confused=\(confusedCases.count), clear=\(clearCases.count))")
        L("  correct: \(correctCount)/\(total)   accuracy: \(pct(accuracy))")
        L("")
        L("  confusion matrix:")
        L("    true positive  (asked, should ask)   : \(truePositive)")
        L("    false negative (proceeded, MISSED ASK): \(falseNegative)   <- guessing risk")
        L("    true negative  (proceeded, should)   : \(trueNegative)")
        L("    false positive (asked, FALSE ASK)    : \(falsePositive)   <- nagging risk")
        L("")
        L("  ask precision: \(pct(askPrecision))   (of the asks, how many were warranted)")
        L("  ask recall:    \(pct(askRecall))   (of the truly-confused, how many we caught)")
        L("  ask F1:        \(pct(f1))")
        L("")

        // Recall is the safety number: a missed ask is a guess. Call it out.
        if falseNegative == 0 {
            L("  RECALL CHECK: PASS. Zero missed asks. The gate caught every truly-confused")
            L("  prompt, including the ungrounded-fact ($18) class. No guessing observed.")
        } else {
            L("  RECALL CHECK: ATTENTION. \(falseNegative) truly-confused prompt(s) slipped through as")
            L("  PROCEED. Each is a place Jax would GUESS instead of asking. Tighten the check.")
        }
        L("")

        if !missedAsks.isEmpty {
            L("---- MISSED ASKS (the dangerous misclassifications) ----")
            for m in missedAsks { L(m) }
            L("")
        }
        if !falseAsks.isEmpty {
            L("---- FALSE ASKS (nagging misclassifications) ----")
            for f in falseAsks { L(f) }
            L("")
        }
        if missedAsks.isEmpty && falseAsks.isEmpty {
            L("---- MISCLASSIFICATIONS ----")
            L("  None. Every labeled prompt got the correct ask/proceed decision.")
            L("")
        }

        // A direct re-creation of the original failure, end to end, so the report
        // proves the specific bug is closed.
        L("---- REGRESSION: the original $18 failure ----")
        let bugDraft = "Turmeric Citrus Grove body wash. A clean, bright wash. Just $18 for a generous bottle."
        let bugVerdict = ConfidenceGate.assessGroundedHeuristic(
            prompt: "Write the turmeric citrus grove body wash blog post.",
            factText: bugDraft,
            context: ConfidenceContext(brand: ProductCatalogSeed.brand)
        )
        L("  draft scanned: \(truncate(bugDraft, 80))")
        L("  verdict: \(bugVerdict.isTrulyConfused ? "ASK (caught the invented price)" : "PROCEED (BUG STILL OPEN)")")
        if bugVerdict.isTrulyConfused {
            L("  would say: \(bugVerdict.clarifyingQuestion ?? "")")
            L("  STATUS: FIXED. The invented $18 is treated as true confusion before publish.")
        } else {
            L("  STATUS: NOT FIXED. The draft's $18 was not caught.")
        }
        L("")

        // Cross-path agreement guard: the nonisolated ungrounded-fact check
        // (JaxProductFacts, used by the chat/confidence path) and the @MainActor
        // FactGuard.audit (the POST seam every content path uses) must agree on
        // whether a TRUE on-catalog fact is grounded. The bar 2-pack total (9.9 oz)
        // was the divergence: JaxProductFacts grounded it, FactGuard.audit falsely
        // flagged it. Both now derive valid sizes from ProductCatalogSeed, so both must
        // pass a true "9.9 oz total" line. If they ever disagree, this fails loud.
        L("---- CROSS-PATH AGREEMENT: bar 2-pack 9.9 oz total ----")
        let packDraft = "The bar soap is a 2-pack: two 4.95 oz bars, 9.9 oz total."
        let nonisolatedFlag = ConfidenceGate.ungroundedFact(in: packDraft, brand: ProductCatalogSeed.brand)
        let auditIssues = FactGuard.audit(brand: ProductCatalogSeed.brand, artifact: packDraft)
        let nonisolatedGrounds = (nonisolatedFlag == nil)
        let auditGrounds = auditIssues.isEmpty
        L("  draft scanned: \(truncate(packDraft, 80))")
        L("  nonisolated ungroundedFact: \(nonisolatedGrounds ? "GROUNDED (no flag)" : "FLAGGED \(nonisolatedFlag!.stated)")")
        L("  FactGuard.audit:            \(auditGrounds ? "GROUNDED (no issue)" : "FLAGGED \(auditIssues.map { $0.claim }.joined(separator: ", "))")")
        if nonisolatedGrounds && auditGrounds {
            L("  STATUS: PASS. Both paths ground the 9.9 oz pack total. No over-trigger, no divergence.")
        } else if nonisolatedGrounds != auditGrounds {
            L("  STATUS: DIVERGENCE. The two grounding paths disagree on a true fact. This is the over-trigger bug; fix the shared seed derivation.")
        } else {
            L("  STATUS: BOTH FLAGGED a true fact. Over-trigger on legitimate copy; the 9.9 oz total must be grounded.")
        }
        L("")
        L("finished: \(timestamp())")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func ratio(_ num: Int, _ den: Int) -> Double {
        den == 0 ? 0 : Double(num) / Double(den)
    }
    private static func pct(_ x: Double) -> String {
        String(format: "%.0f%%", x * 100)
    }
    private static func fmt(_ x: Double) -> String {
        String(format: "%.2f", x)
    }
    private static func truncate(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "..." : s
    }
    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f.string(from: Date())
    }
}
