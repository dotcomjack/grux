import Foundation

// EmailCognition: the JAX cognition pass over a support-email triage decision.
// Phase 1 of the email vertical slice. It turns support triage from a standalone
// classifier into a traced JAX decision: for each email it retrieves relevant
// you-ness memory, fires the matching profile heuristics, runs the never-guess
// ConfidenceGate over the decision, and records a real CognitionEvent so the
// Cognition Map fills with actual email judgment the user can inspect (and, in
// later phases, correct + graduate to live).
//
// Honesty: every recorded field is real, the retrieved memory, the matched
// heuristics, and the gate's computed confidence. Nothing is fabricated. A
// genuinely confusing email (TRUE confusion) escalates needsReview so it is
// never auto-drafted with false confidence, the same never-guess contract the
// rest of Jax honors.

@MainActor
enum EmailCognition {

    struct Result {
        let verdict: ConfidenceVerdict
        let memories: [String]        // short snippets of retrieved you-ness memory
        let firedHeuristics: [String]
        // Convenience: did the never-guess gate decide this needs a human read?
        var needsHuman: Bool { verdict.isTrulyConfused }
        var humanReason: String? {
            // The assistant's name is deliberately NOT interpolated here. This
            // value flows into EmailTriageEngine's auditReason, which is not
            // MainActor isolated, and `assistantName` is. Rippling isolation
            // through the cognition path to prefix a name is the wrong trade, so
            // the attribution is dropped instead: the sentence is complete
            // without it, and a hardcoded "Jax" here would be wrong the moment
            // somebody renames their assistant.
            verdict.isTrulyConfused ? (verdict.clarifyingQuestion ?? verdict.reason) : nil
        }
    }

    // Assess one support-email triage decision through JAX cognition and record
    // the trace. Returns the verdict + provenance so the caller can gate the draft.
    static func assess(subject: String, thread: String, category: String,
                       draft: String, voice: String,
                       correlationId: String? = nil) async -> Result {
        // Use the full thread (capped) so retrieval, heuristic matching, and the
        // confidence gate all see the real conversation, consistent with the
        // thread-aware drafter. Falls back to whatever the caller has (preview).
        let context = String(thread.prefix(2000))
        let query = "\(subject)\n\(context)"
        // 1. Retrieve relevant you-ness memory (past handling + durable facts).
        let mems = SemanticMemory.shared
            .retrieve(query: query, topK: 4, kinds: [.corpus, .fact, .chatAssistant])
            .map { String($0.text.prefix(140)) }
        // 2. Fire the profile heuristics relevant to this decision.
        let fired = Self.match(
            heuristics: JaxProfile.shared.heuristics.map { ($0.rule, $0.domain) },
            subject: subject, preview: context, voice: voice)
        // 3. Never-guess gate over the decision, INCLUDING the conversation so the
        // gate can flag a draft that ignores what the thread already established.
        let prompt = "Handle a \(voice) support email. Subject: \(subject). Category: \(category).\nConversation so far:\n\(String(thread.prefix(1500)))\nDrafted reply: \(draft)"
        let verdict = await ConfidenceGate.assess(
            prompt: prompt,
            apiKey: AppState.shared.anthropicKey,
            model: AppState.shared.config.model)
        // 4. Record the honest trace so it appears in the Cognition Map.
        _ = CognitionTrace.shared.note(
            kind: .task,
            trigger: "support email: \(String(subject.prefix(80)))",
            heuristicsFired: fired,
            memoriesRetrieved: mems,
            gateVerdict: verdict.isTrulyConfused ? "clarify" : "proceed",
            gateReason: verdict.reason,
            confidence: verdict.confidence,
            mode: AutonomyController.shared.mode.rawValue,
            outcome: verdict.isTrulyConfused
                ? "Flagged for review: \(verdict.clarifyingQuestion ?? "needs a human read")"
                : "Drafted a \(voice) reply (category: \(category))",
            brand: voice,
            correlationId: correlationId)
        return Result(verdict: verdict, memories: mems, firedHeuristics: fired)
    }

    // Pure, testable match: a heuristic fires if it is in a comms/support/email
    // domain, or its rule shares a meaningful keyword with the email. Kept simple
    // and model-free so the fired set is always explainable (honesty contract).
    nonisolated static func match(heuristics: [(rule: String, domain: String)],
                                  subject: String, preview: String, voice: String) -> [String] {
        let hay = (subject + " " + preview + " " + voice).lowercased()
        let v = voice.lowercased()
        let brandTags = Set(SupportInbox.roster.map(\.rawValue))
        var out: [String] = []
        for h in heuristics {
            let dom = h.domain.lowercased()
            // A brand-scoped domain ("<brand>-support", or a bare brand tag that
            // is one of the configured inboxes) only fires for ITS brand, so a
            // lesson learned on one brand's mail does not pollute another's
            // replies. General comms/email/support domains (no brand prefix) fire
            // for every voice. The brand tags come from the user's own inbox
            // roster rather than a compiled-in list, so adding an inbox scopes
            // its lessons too, and an unconfigured install simply has no bare
            // brand tags (the "<brand>-support" suffix rule still works, which
            // is what the learner actually writes).
            let brandScoped = dom.hasSuffix("-support") || brandTags.contains(dom)
            let domainHit: Bool
            if brandScoped {
                domainHit = dom == "\(v)-support" || dom == v
            } else {
                domainHit = dom.contains("comms") || dom == "support" || dom.contains("email")
            }
            let keywordHit = keywords(in: h.rule).contains { hay.contains($0) }
            if domainHit || keywordHit { out.append(h.rule) }
            if out.count >= 6 { break }
        }
        return out
    }

    // Meaningful keywords from a heuristic rule: alphanumeric tokens >= 5 chars,
    // so short stopwords ("the", "a", "with") do not spuriously match.
    nonisolated static func keywords(in rule: String) -> [String] {
        rule.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 5 }
    }
}
