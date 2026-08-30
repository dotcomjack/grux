import Foundation

// GroundedGenerator: the PRODUCTION content-generation primitive for Jax.
//
// THE BUG THIS EXISTS TO KILL: Jax once wrote blog copy claiming a body wash
// costs "$18" when the real price was "$15". Jax INVENTED a product fact. The
// hard rule is that Jax never guesses or makes things up: a factual number
// (price, size, SKU, cadence) must be RETRIEVED from the real catalog, never
// generated. An ungrounded claim is TRUE confusion: look it up or ask, never
// invent.
//
// This is the single helper every real content tool (and the test harness)
// should route through, so grounded generation is the DEFAULT path, not a
// special case bolted onto one test. It does NOT define product facts itself: it
// leans on its siblings.
//
//   ProductCatalog : the single source of real product facts (price, size,
//                    SKU pattern, scents, Subscribe and Save cadences).
//   FactGuard      : groundingContext(brief:) renders the relevant real facts
//                    into a prompt block, and audit(...) checks a generated
//                    artifact for ungrounded / wrong factual numbers.
//   JaxProfile     : the persona + learned identity rendered into the system
//                    prompt, so the artifact comes out in the user's voice.
//   ClaudeClient   : the model call (same path BriefingEngine + the harness use).
//
// THE GROUNDED LOOP:
//   1. Build the system prompt from JaxProfile.persona + asSystemContext().
//   2. Inject FactGuard.groundingContext(brief:) so the model has the REAL facts
//      BEFORE it writes a single number.
//   3. Generate via ClaudeClient.complete.
//   4. Audit the result with FactGuard.audit. Every flagged number is a fact Jax
//      either got wrong or invented.
//   5. If ungrounded, regenerate EXACTLY ONCE with an explicit correction that
//      names each wrong value, the real value, and the rule: use only the
//      provided facts, never invent a number.
//   6. Re-audit the corrected draft and return the artifact, whether it is
//      grounded, and any issues that survived the correction.
//
// HONESTY CONTRACT: this never returns an invented-fact artifact marked grounded.
// If the second pass still carries an ungrounded fact, `grounded` is false and
// the surviving issues ride along so the caller can refuse, queue, or ask them
// rather than ship a made-up number. Treating a remaining ungrounded fact as
// "good enough" would be exactly the guess this primitive exists to prevent.
//
// House style: @MainActor enum of statics (no mutable state), zero em/en dashes,
// dollars as $N, no vendor/model/stack names in any user-facing string.

@MainActor
enum GroundedGenerator {

    // The result of one grounded generation. `grounded` is true ONLY when the
    // final audit found no ungrounded or wrong factual claim; `issues` carries
    // any that survived (empty on a clean grounded result).
    struct Result {
        var artifact: String
        var grounded: Bool
        var issues: [String]
    }

    // Generate a content artifact with real product facts injected and audited.
    //
    //   kind    the artifact kind hint: "blog", "social", "thread", "email",
    //           "ad", "production", etc. Free-form; frames the brief and the
    //           voice of the piece.
    //   brief   what the user asked for, in plain language. FactGuard uses this to
    //           pick which real facts to surface (e.g. a brief about body wash
    //           pulls the $15 / 16.9 oz / "<scent>-wash" facts).
    //   apiKey  the model key (callers read AppState.shared.anthropicKey).
    //   model   the model id (callers read AppState.shared.config.model).
    //
    // Returns the artifact, whether it is grounded, and any remaining issues.
    // Never throws: a model failure or missing key comes back as an honest,
    // non-grounded Result instead of an exception, so the caller always has a
    // report to act on.
    static func generate(kind: String,
                         brief: String,
                         apiKey: String,
                         model: String) async -> (artifact: String, grounded: Bool, issues: [String]) {
        let r = await generateResult(kind: kind, brief: brief, apiKey: apiKey, model: model)
        return (r.artifact, r.grounded, r.issues)
    }

    // The same flow, returning the richer Result value. Kept separate so callers
    // that want the struct get it, while the tuple-returning entry point above
    // matches the agreed primitive signature.
    static func generateResult(kind: String,
                               brief: String,
                               apiKey: String,
                               model: String) async -> Result {
        let briefTrimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !briefTrimmed.isEmpty else {
            return Result(artifact: "(empty brief, nothing generated)",
                          grounded: false,
                          issues: ["The brief was empty. There is nothing to ground or write."])
        }

        // No key means no generation. Be honest rather than fabricate a draft.
        guard !apiKey.isEmpty else {
            return Result(artifact: "(no model key configured, generation skipped)",
                          grounded: false,
                          issues: ["No model key was available, so no artifact was generated."])
        }

        let kindLabel = kind.isEmpty ? "content" : kind

        // STAGE 1 + 2: the system prompt is Jax's mind plus the REAL facts. The
        // grounding block goes in the SYSTEM context (not the user turn) so the
        // facts are load-bearing instruction, not casual reference the model can
        // drift from. FactGuard owns which facts are relevant to this brief.
        let grounding = FactGuard.groundingContext(brief: briefTrimmed)
        let system = buildSystem(kind: kindLabel, grounding: grounding)
        let user = "Brief: \(briefTrimmed)\n\nWrite the \(kindLabel) now, using ONLY the product facts provided above for any number:"

        // STAGE 3: first generation.
        var artifact = await complete(apiKey: apiKey,
                                      model: model,
                                      system: system,
                                      user: user)
        guard !artifact.hasPrefix(Self.failurePrefix) else {
            // The model call itself failed. Surface it honestly, not as grounded.
            return Result(artifact: artifact,
                          grounded: false,
                          issues: ["Generation failed before any fact check could run."])
        }

        // STAGE 4: audit the first draft against the real catalog.
        var audit = FactGuard.audit(artifact, brief: briefTrimmed)
        if audit.isGrounded {
            return Result(artifact: artifact, grounded: true, issues: [])
        }

        // STAGE 5: ONE correction pass. Name every wrong value and its real value
        // explicitly, and restate the rule. This is the never-guess loop: Jax
        // looked, saw it was wrong, and fixes it from the real facts rather than
        // inventing a new number.
        let correction = buildCorrection(issues: audit.issues,
                                         corrections: audit.corrections,
                                         grounding: grounding)
        let correctedUser = """
        \(user)

        \(correction)
        """
        let secondPass = await complete(apiKey: apiKey,
                                        model: model,
                                        system: system,
                                        user: correctedUser)
        if !secondPass.hasPrefix(Self.failurePrefix) {
            artifact = secondPass
        }

        // STAGE 6: re-audit the corrected draft. Only a clean second audit earns
        // grounded = true. Anything still flagged rides along as a surviving
        // issue so the caller refuses / queues / asks rather than shipping it.
        audit = FactGuard.audit(artifact, brief: briefTrimmed)
        if audit.isGrounded {
            return Result(artifact: artifact, grounded: true, issues: [])
        }

        return Result(artifact: artifact,
                      grounded: false,
                      issues: audit.issues.isEmpty
                          ? ["An ungrounded factual claim remained after one correction pass."]
                          : audit.issues)
    }

    // MARK: - Prompt construction

    private static func buildSystem(kind: String, grounding: String) -> String {
        """
        \(JaxProfile.shared.persona)

        \(JaxProfile.shared.asSystemContext())

        RIGHT NOW you are drafting a \(kind) artifact from the user's brief, for them to review. Write the real, finished artifact in their voice.

        GROUNDED FACTS (the ONLY source of truth for any number, price, size, SKU, or cadence in this piece):
        \(grounding)

        FACT DISCIPLINE (this is how they think, treat it as your own):
        - Every price, size, count, SKU, and cadence MUST come from the GROUNDED FACTS above, copied exactly. Never round, never estimate, never invent a number.
        - If the facts do not contain a number you would need, you do NOT make one up. Leave it out and write around it, or say the fact is not available. A made-up number is a lie, and you do not lie in their voice.
        - If a fact in your head disagrees with the GROUNDED FACTS, the GROUNDED FACTS win. They are the real catalog; your memory is not.

        STYLE:
        - Write the actual content, ready for them to read and approve. No preamble, no "here is a draft", just the piece.
        - Stay in their voice: direct, observational, no buzzwords, no hype.
        - No em dashes and no en dashes. Use commas, periods, colons, or pipes. Write dollar amounts as $N.
        - Do not name any vendor, model, framework, or tech-stack detail.
        - No emoji.
        """
    }

    private static func buildCorrection(issues: [String],
                                        corrections: [String: String],
                                        grounding: String) -> String {
        var lines: [String] = []
        lines.append("STOP. Your draft contained a factual claim that is NOT in the real catalog. That is exactly the mistake you must never make: you invented or misremembered a number instead of using the provided facts.")
        lines.append("")

        if !corrections.isEmpty {
            lines.append("Fix each of these exactly, using the real value:")
            for (wrong, right) in corrections.sorted(by: { $0.key < $1.key }) {
                lines.append("  - You wrote \(wrong). The real value is \(right). Use \(right).")
            }
            lines.append("")
        }

        if !issues.isEmpty {
            lines.append("Problems found:")
            for issue in issues {
                lines.append("  - \(issue)")
            }
            lines.append("")
        }

        lines.append("Rewrite the full artifact now. Use ONLY the GROUNDED FACTS for every number. If a number is not in the facts, leave it out rather than guess. Keep everything else (voice, structure, no em or en dashes, dollars as $N).")
        lines.append("")
        lines.append("GROUNDED FACTS (reminder, the only source of truth):")
        lines.append(grounding)
        return lines.joined(separator: "\n")
    }

    // MARK: - Model call

    // Prefix that marks an internal failure string so the loop can tell a real
    // artifact from a failed call without throwing. Never shown as grounded.
    private static let failurePrefix = "(generation failed"

    private static func complete(apiKey: String,
                                 model: String,
                                 system: String,
                                 user: String) async -> String {
        // ROUTED. This built its own ClaudeClient per call and sent the
        // caller's Anthropic key, so grounded generation only ever worked for a
        // hosted-Anthropic user. `model` is the caller's explicit choice and
        // rides as the override; the backend and credential come from the
        // registry. Resolved ONCE per completion, and generateResult calls this
        // at most twice in sequence, never in a loop. The `apiKey` parameter
        // stays: `generateResult` still uses it as the entry gate, and that gate
        // is the caller's contract, not this call's credential.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: model)
        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: system,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 1400,
                temperature: 0.6,
                // Explicit because a ModelBackend requirement carries no default
                // arguments; these are ClaudeClient's own, so the wire is unchanged.
                spanName: "claude.complete",
                feature: "jaxGroundedContent"
            )
            let cleaned = DashSanitizer.clean(reply.trimmingCharacters(in: .whitespacesAndNewlines))
            return cleaned.isEmpty ? "(model returned an empty draft)" : cleaned
        } catch {
            return "\(failurePrefix): \(error.localizedDescription))"
        }
    }
}
