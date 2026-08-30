import Foundation

// CorrectionLearner: email Phase 2, the corrections -> learning loop. When the
// user edits a drafted support reply and sends it, the delta between what Jax
// wrote (originalReply) and what they actually sent (draftReply) is a correction. This
// distills ONE durable, generalizable lesson from that delta (or nothing, for a
// cosmetic one-off edit), then:
//   1. stores it in CorrectionLessonStore (which feeds the drafter prompt + the
//      Lessons UI), and
//   2. adds it as a brand-scoped JaxProfile heuristic, so it FIRES in
//      EmailCognition on the next similar email and shows up in the Cognition Map.
// The honest contract holds: a lesson is only recorded when a real edit happened,
// and the model is told to return NONE for changes that do not generalize.
@MainActor
enum CorrectionLearner {

    // Learned lessons are heuristics in this brand-scoped domain, which
    // EmailCognition.match treats as in-scope (it matches "...support...").
    static func learnDomain(_ brand: String) -> String { "\(brand.lowercased())-support" }

    // Distill + record a lesson from a sent draft the user edited. Safe to call
    // unconditionally; it no-ops when the edit was trivial or the model declines.
    static func learn(from draft: SupportDraft) async {
        let before = draft.originalReply.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = draft.draftReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !after.isEmpty, before != after else { return }

        // Cheap pre-filter: an edit whose only differences are digits, punctuation,
        // or whitespace (an order number, a name token, a typo) is not a
        // generalizable lesson. Skip the model call entirely.
        if isCosmetic(before, after) {
            WakeLog.shared.log("correctionLearner: cosmetic edit, no lesson for \(draft.subject.prefix(40))")
            return
        }

        guard let lessonText = await extractLesson(
            brand: draft.brandVoice, category: draft.category.rawValue,
            subject: String(draft.subject.prefix(120)), before: before, after: after), !lessonText.isEmpty else {
            WakeLog.shared.log("correctionLearner: model returned NONE for \(draft.subject.prefix(40))")
            return
        }

        // If this draft was already learned from with a DIFFERENT lesson, drop the
        // stale heuristic first so it cannot orphan in the profile (the store
        // upserts by id, but the profile dedupes by rule text).
        let lessonId = "lesson-\(draft.id)"
        if let prior = CorrectionLessonStore.shared.lessons.first(where: { $0.id == lessonId }),
           prior.lesson != lessonText {
            if let hid = prior.heuristicID { JaxProfile.shared.removeHeuristic(hid) }
            else { JaxProfile.shared.removeHeuristic(matching: prior.lesson) }
        }

        let heuristic = JaxProfile.shared.addHeuristic(rule: lessonText, domain: learnDomain(draft.brandVoice))
        let lesson = CorrectionLesson(
            id: lessonId, learnedAt: Date(), brand: draft.brandVoice.lowercased(),
            category: draft.category.rawValue, lesson: lessonText, subject: String(draft.subject.prefix(120)),
            beforeSnippet: String(before.prefix(140)), afterSnippet: String(after.prefix(140)),
            heuristicID: heuristic.id)
        CorrectionLessonStore.shared.add(lesson)
        CognitionTrace.shared.note(
            kind: .directive,
            trigger: "Learned from your edit: \(draft.subject.prefix(60))",
            heuristicsFired: [lessonText],
            mode: AutonomyController.shared.mode.rawValue,
            outcome: "Captured a lesson from a correction; will apply it to future \(draft.brandVoice) replies.",
            brand: draft.brandVoice.lowercased(),
            correlationId: draft.id)
        WakeLog.shared.log("correctionLearner: learned (\(draft.brandVoice)) \(lessonText.prefix(80))")
    }

    // Forget a lesson: remove it from the store AND the matching profile heuristic,
    // so a bad lesson stops shaping drafts and stops firing. Called by the UI.
    static func forget(_ id: String) {
        let lesson = CorrectionLessonStore.shared.lessons.first { $0.id == id }
        CorrectionLessonStore.shared.remove(id)
        // Prefer the exact heuristic id so a sibling heuristic that happens to
        // share the rule text is never collaterally removed; fall back to text
        // match for lessons learned before heuristicID was tracked.
        if let hid = lesson?.heuristicID { JaxProfile.shared.removeHeuristic(hid) }
        else if let rule = lesson?.lesson { JaxProfile.shared.removeHeuristic(matching: rule) }
    }

    // MARK: - Lesson extraction (LLM)

    private static func extractLesson(brand: String, category: String, subject: String,
                                      before: String, after: String) async -> String? {
        let system = """
        You distill ONE durable lesson from how a human edited an AI-drafted
        customer-support reply, so the AI writes better NEXT time. Output a single
        short imperative rule (max about 20 words), generalizable beyond this one
        email, phrased so it applies to FUTURE replies in the same brand voice.
        If the human's change was purely cosmetic or one-off (an order number, a
        person's name, a typo, trivial reordering) with no reusable lesson, output
        exactly: NONE
        Output ONLY the rule or NONE. No quotes, no preamble, no markdown. Never use
        em dashes or en dashes.
        """
        let user = """
        BRAND VOICE: \(brand)
        CATEGORY: \(category)
        SUBJECT: \(subject)

        AI DRAFT (before):
        \(before)

        WHAT THE HUMAN ACTUALLY SENT (after):
        \(after)

        The single lesson (or NONE):
        """
        do {
            let res = try await AmbientLLM.completeTagged(
                system: system,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 120, temperature: 0.2, featureTag: "support_learn")
            // Take the first non-empty line, strip any leading bullet, scrub dashes.
            let cleaned = stripThink(res.text)
            let line = cleaned
                .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? ""
            let unbulleted = line.drop(while: { $0 == "-" || $0 == "*" || $0 == "•" || $0 == " " })
            // Hard-cap the stored rule: it is spliced into future drafter prompts
            // and the Jax profile, so a runaway model output cannot bloat or hijack
            // either. One line (already taken above), at most 200 chars.
            let lesson = String(DashSanitizer.clean(String(unbulleted))
                .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            if lesson.isEmpty || lesson.uppercased() == "NONE" || lesson.count < 6 { return nil }
            return lesson
        } catch {
            WakeLog.shared.log("correctionLearner: extraction failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Helpers

    // True when before/after differ only in digits, punctuation, casing, or
    // whitespace, i.e. there is no reusable wording change to learn from.
    nonisolated static func isCosmetic(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            let scalars = s.lowercased().unicodeScalars.filter {
                CharacterSet.letters.contains($0) || $0 == " "
            }
            return String(String.UnicodeScalarView(scalars))
                .split(separator: " ").joined(separator: " ")
        }
        return norm(a) == norm(b)
    }

    // Drop a leading <think>...</think> block some local models emit.
    nonisolated static func stripThink(_ s: String) -> String {
        guard let r = s.range(of: "</think>") else { return s }
        return String(s[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
