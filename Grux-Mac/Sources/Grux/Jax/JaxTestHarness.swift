import Foundation

// Jax comms + content TEST HARNESS.
//
// This is the single hook a scored end-to-end report drives Jax through. It
// exercises the REAL send pipeline (the same one compose_email uses) without
// adding a parallel, untrusted send path: it builds the SAME ProposedAction,
// classifies the SAME way through CommsPersona.prepareSend, and runs the SAME
// DecisionGate.shared.evaluate. The only thing it adds on top is a structured,
// human-readable report of what happened at each stage so a grader can score
// the disclosure split, the gate verdict, and (on a live run) the actual send.
//
// HONESTY CONTRACT: this harness reports ONLY what the app really did. It never
// claims a send that did not happen, never bypasses a .refuse, and never invents
// a resend id. A dry run says exactly what WOULD be sent and stops; a live run
// only sends when the gate proceeds (or the call was explicitly pre-approved),
// and surfaces the real Resend id it got back.
//
// Two entry points:
//   runCommsTest(to:subject:body:live:)       drives the email send pipeline.
//   dryRunContentPipeline(kind:brief:)         drives a blog/social/production
//                                              generation through Jax (the model
//                                              wearing the JaxProfile persona),
//                                              reports the artifact + gate verdict,
//                                              and PUBLISHES NOTHING.
//
// House style: @MainActor enum of statics (no mutable state), zero em/en dashes,
// dollars as $N, no vendor/model/stack names in any user-facing string.

enum JaxTestHarness {

    // MARK: - Comms test

    // Builds the SAME ProposedAction compose_email builds, runs it through
    // CommsPersona.prepareSend + DecisionGate.shared.evaluate, and returns a
    // multi-line report. Obeys the gate: a .refuse never sends, a
    // .queueForApproval never sends (it reports what is parked), and only a
    // .proceed (or an explicitly pre-approved live test) performs the real send
    // via the same ResendClient path EmailTool uses.
    //
    //   to        comma/semicolon-separated recipient list (same parse as compose_email)
    //   subject   the subject line
    //   body      the plain-text body, pre-signature (the persona signs it)
    //   live      false = dry run, report what WOULD happen, send nothing.
    //             true  = perform the real send IF the gate proceeds.
    @MainActor
    static func runCommsTest(to: String, subject: String, body: String, live: Bool) async -> String {
        var report = ReportBuilder()
        report.header("JAX COMMS PIPELINE TEST")
        report.kv("mode", live ? "LIVE (will send on a proceed verdict)" : "DRY RUN (no send)")
        report.kv("started", Self.timestamp())
        report.blank()

        // STAGE 1: parse + validate recipients, exactly as compose_email does.
        report.section("1. INPUT")
        let recipients = to
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
        let subjectTrimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyTrimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)

        report.kv("to (parsed)", recipients.isEmpty ? "(none valid)" : recipients.joined(separator: ", "))
        report.kv("subject", subjectTrimmed.isEmpty ? "(empty)" : subjectTrimmed)
        report.kv("body chars", "\(bodyTrimmed.count)")

        guard !recipients.isEmpty else {
            report.blank()
            report.line("RESULT: blocked at input. No valid recipient address in '\(to)'. Nothing sent.")
            return report.finish()
        }
        guard !subjectTrimmed.isEmpty else {
            report.blank()
            report.line("RESULT: blocked at input. Empty subject. Nothing sent.")
            return report.finish()
        }
        guard !bodyTrimmed.isEmpty else {
            report.blank()
            report.line("RESULT: blocked at input. Empty body. Nothing sent.")
            return report.finish()
        }
        report.blank()

        // STAGE 2: classification + identity, through the REAL CommsPersona.
        // brandHint is left nil so the heuristic classifier runs (business vs
        // personal), matching a compose_email call with no from_account hint.
        report.section("2. CLASSIFICATION + IDENTITY (CommsPersona)")
        let context = CommsPersona.shared.classify(
            recipient: recipients,
            subject: subjectTrimmed,
            body: bodyTrimmed,
            brandHint: nil
        )
        let prepared = CommsPersona.shared.prepareSend(
            recipients: recipients,
            subject: subjectTrimmed,
            body: bodyTrimmed,
            brandHint: nil
        )
        report.kv("classified context", context.rawValue.uppercased())
        report.kv("from name", prepared.identity.fromName)
        report.kv("from address", prepared.identity.fromAddress)
        report.kv("reply-to", prepared.identity.replyTo)
        report.kv("disclosure", context == .business
            ? "the assistant persona, writing on the user's behalf (business mail)"
            : "the user themselves (personal mail, no assistant disclosure)")
        report.kv("brand", prepared.brand.rawValue)
        report.kv("signature line", prepared.identity.signature)
        report.blank()

        // STAGE 3: the universal decision gate. This is the same call EmailTool
        // makes; the harness reports the verdict and HONORS it.
        report.section("3. DECISION GATE (DecisionGate.shared.evaluate)")
        let verdict = DecisionGate.shared.evaluate(prepared.proposed)
        switch verdict {
        case .proceed:
            report.kv("verdict", "PROCEED")
            report.line("  The gate cleared this for an immediate send.")
        case .queueForApproval(let pending):
            report.kv("verdict", "QUEUE FOR APPROVAL")
            report.kv("  urgent", pending.urgent ? "yes" : "no")
            report.kv("  would send as", pending.persona.displayName)
            report.kv("  reason", pending.reason)
        case .refuse(let reason):
            report.kv("verdict", "REFUSE")
            report.kv("  reason", reason)
        }
        report.blank()

        // STAGE 4: act on the verdict.
        report.section("4. SEND")

        // The body that WOULD leave the machine, after the persona signs it and
        // the final dash scrubber runs on the ResendClient path. We show the
        // scrubbed preview so the report reflects the exact wire bytes.
        let wireSubject = DashSanitizer.clean(prepared.subject)
        let wireBody = DashSanitizer.clean(prepared.body)

        switch verdict {
        case .refuse(let reason):
            // HARD STOP. A refuse is never overridden, live or dry.
            report.line("Honored REFUSE. Nothing sent.")
            report.kv("refused because", reason)

        case .queueForApproval:
            // The gate wants a human tap. The harness does NOT auto-approve and
            // does NOT send. On a live run it reports that the real pipeline
            // would park this in the Jax HQ queue (the harness deliberately does
            // not enqueue, to keep test runs from polluting the live queue).
            if live {
                report.line("Honored QUEUE verdict. A real compose_email call would park this in the Jax HQ approval queue for the user's one-tap approval. The harness does not auto-approve and does not enqueue a test item, so NOTHING was sent and the live queue is untouched.")
            } else {
                report.line("DRY RUN. The gate would queue this for the user's one-tap approval. Nothing sent.")
            }
            report.blank()
            report.subsection("WOULD SEND (after approval)")
            report.kv("from", prepared.identity.fromAddress)
            report.kv("to", prepared.recipients.joined(separator: ", "))
            report.kv("reply-to", prepared.identity.replyTo)
            report.kv("subject", wireSubject)
            report.line("  body:")
            report.indented(wireBody)

        case .proceed:
            if live {
                // LIVE + PROCEED: perform the REAL send through the same
                // ResendClient path EmailTool uses. Identity owns From + reply-to;
                // body is already signed and gets the dash scrub in the client.
                do {
                    let result = try await ResendClient().send(
                        from: prepared.identity.fromAddress,
                        to: prepared.recipients,
                        subject: prepared.subject,
                        text: prepared.body,
                        listUnsubscribe: nil,
                        replyTo: prepared.identity.replyTo
                    )
                    report.line("SENT (real). The email left the machine through the verified sender.")
                    report.kv("resend id", result.id)
                    report.kv("sent as", "\(prepared.identity.fromName) <\(prepared.identity.replyTo)>")
                    report.kv("to", prepared.recipients.joined(separator: ", "))
                    report.kv("disclosure", context.rawValue)
                } catch {
                    report.line("SEND FAILED. The gate proceeded but the send threw. Nothing left the machine.")
                    report.kv("error", error.localizedDescription)
                }
            } else {
                // DRY RUN + PROCEED: report exactly what WOULD be sent. No send.
                report.line("DRY RUN. The gate would PROCEED. The real pipeline would send this now. Nothing sent in this run.")
                report.blank()
                report.subsection("WOULD SEND")
                report.kv("from", prepared.identity.fromAddress)
                report.kv("to", prepared.recipients.joined(separator: ", "))
                report.kv("reply-to", prepared.identity.replyTo)
                report.kv("subject", wireSubject)
                report.line("  body:")
                report.indented(wireBody)
            }
        }

        report.blank()
        report.kv("finished", Self.timestamp())
        return report.finish()
    }

    // MARK: - Content dry run

    // Has Jax (the model wearing the JaxProfile persona) GENERATE the real
    // artifact for a blog / social / production-style task, then reports what it
    // WOULD publish plus the gate verdict, WITHOUT publishing. This is a pure dry
    // run for the scored report: it never touches a publish surface.
    //
    //   kind   the artifact kind hint: "blog", "social", "thread", "email",
    //          "ad", "production", etc. Free-form; used to frame the brief and
    //          the gate's public-post sniff.
    //   brief  what the user asked for, in plain language.
    @MainActor
    static func dryRunContentPipeline(kind: String, brief: String) async -> String {
        var report = ReportBuilder()
        report.header("JAX CONTENT DRY RUN")
        report.kv("kind", kind.isEmpty ? "(unspecified)" : kind)
        report.kv("brief", brief.isEmpty ? "(empty)" : brief)
        report.kv("started", Self.timestamp())
        report.kv("publish", "NO. This is a pure dry run. Nothing is published.")
        report.blank()

        let briefTrimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !briefTrimmed.isEmpty else {
            report.line("RESULT: blocked at input. Empty brief. Nothing generated.")
            return report.finish()
        }

        // STAGE 1: generate the real artifact through Jax's own mind. If there is
        // no model key, fall back to an honest placeholder so the harness still
        // produces a report instead of throwing.
        // Generate through GroundedGenerator: it injects the REAL catalog facts
        // into the prompt, generates, audits the draft against the catalog, and
        // regenerates ONCE if an ungrounded number slipped in. This is the fix for
        // the $18 hallucination, and it is the production grounded-content
        // primitive any REAL content tool (blog, social, ad, email body) must
        // route through too, not just this harness.
        report.section("1. GENERATION (Jax persona, grounded)")
        let key = AppState.shared.anthropicKey
        let model = AppState.shared.config.model
        var artifact: String

        if key.isEmpty {
            artifact = "(no model key configured, generation skipped. The pipeline would normally compose the \(kind) artifact here from the brief.)"
            report.line("No model key available. Reporting the pipeline shape without a generated artifact.")
        } else {
            let result = await GroundedGenerator.generate(kind: kind, brief: briefTrimmed, apiKey: key, model: model)
            artifact = result.artifact
            report.kv("grounded", result.grounded ? "YES (every fact checked against the real catalog)" : "NO (an ungrounded fact survived, see issues)")
            if result.issues.isEmpty {
                report.line(result.grounded
                    ? "Jax generated grounded copy: every number was retrieved from the real catalog, not invented."
                    : "Jax generated the artifact but a factual claim could not be grounded.")
            } else {
                report.line("RESULT: NOT publishable. Jax asserted a product fact that contradicts the catalog. An ungrounded fact is true confusion: regenerate with the real facts or ask, never invent. Nothing published.")
                report.line("Remaining grounding issues:")
                for issue in result.issues { report.kv("  issue", issue) }
            }
        }
        report.kv("artifact chars", "\(artifact.count)")
        report.blank()

        // STAGE 2: run the artifact through the SAME decision gate a real publish
        // would hit. Publishing as the user is a hard refuse by design (guardrail 3);
        // the report surfaces that verdict so the grader sees the gate working.
        report.section("2. DECISION GATE (what publishing this WOULD return)")
        let lower = kind.lowercased()
        let looksPublic = ["social", "thread", "threads", "twitter", "instagram",
                           "tiktok", "facebook", "linkedin", "post", "tweet"]
            .contains { lower.contains($0) }
        let proposed = ProposedAction(
            kind: .other,
            summary: "Publish \(kind.isEmpty ? "content" : kind): \(briefTrimmed.prefix(80))",
            target: looksPublic ? "social post" : "draft",
            isPublicPost: looksPublic,
            detail: [
                "channel": kind,
                "brief": briefTrimmed,
                "would_publish": "true"
            ]
        )
        let verdict = DecisionGate.shared.evaluate(proposed)
        switch verdict {
        case .proceed:
            report.kv("verdict", "PROCEED")
            report.line("  A non-public artifact like this clears as a draft action. Publishing still requires the user; this harness publishes nothing.")
        case .queueForApproval(let pending):
            report.kv("verdict", "QUEUE FOR APPROVAL")
            report.kv("  reason", pending.reason)
        case .refuse(let reason):
            report.kv("verdict", "REFUSE")
            report.kv("  reason", reason)
            report.line("  This is the expected verdict for a public post as the user. The artifact stays a private draft.")
        }
        report.blank()

        // STAGE 3: the artifact itself, clearly labelled unpublished.
        report.section("3. ARTIFACT (DRAFT, NOT PUBLISHED)")
        report.indented(artifact)
        report.blank()
        report.kv("finished", Self.timestamp())
        return report.finish()
    }

    // MARK: - Helpers

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return f.string(from: Date())
    }
}

// MARK: - ReportBuilder

// A tiny string accumulator for clean, scannable multi-line reports. Kept local
// to the harness; no shared state. Every line is plain text so the report reads
// the same on stderr and in the result file.
private struct ReportBuilder {
    private var lines: [String] = []

    mutating func header(_ s: String) {
        lines.append("==============================================")
        lines.append(s)
        lines.append("==============================================")
    }

    mutating func section(_ s: String) {
        lines.append("---- \(s) ----")
    }

    mutating func subsection(_ s: String) {
        lines.append("[\(s)]")
    }

    mutating func kv(_ key: String, _ value: String) {
        lines.append("  \(key): \(value)")
    }

    mutating func line(_ s: String) {
        lines.append(s)
    }

    mutating func indented(_ block: String) {
        for raw in block.split(separator: "\n", omittingEmptySubsequences: false) {
            lines.append("    | \(raw)")
        }
    }

    mutating func blank() {
        lines.append("")
    }

    func finish() -> String {
        lines.joined(separator: "\n")
    }
}
