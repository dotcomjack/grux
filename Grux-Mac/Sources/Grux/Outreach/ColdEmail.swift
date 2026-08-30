import Foundation

// Voice-to-cold-email pipeline. The user says (during ambient listening):
//   "Grux, draft outreach to <person> at <company>"
// Grux parses the target, drafts a tailored outreach email around the user's
// own configured pitch (Claude Sonnet 4.6, local fallback), then opens a
// confirmation dialog. Nothing sends until the user taps Send.
//
// Guardrails wired in:
//  - Client cap: at most ONE active engagement. If an active client is on file
//    (~/.grux/outreach/active-client.json), the confirm dialog shows a hard
//    warning before send.
//  - Sender identity comes from ~/.grux/outreach/sender.json and is empty on a
//    fresh install, so Grux refuses to send rather than mailing from a domain
//    it does not own.
//  - No em/en dashes (DashSanitizer scrubs the draft).
//  - CAN-SPAM: every send carries a List-Unsubscribe header.
//  - Every send is logged to ~/.grux/outreach/sent-YYYY-MM-DD.jsonl.
@MainActor
final class ColdEmailEngine {
    static let shared = ColdEmailEngine()
    private init() {}

    private var inFlight = false
    private var lastTriggerAt: Date = .distantPast

    // Drafting model. Sonnet 4.6 per spec (verified against CLAUDE.md model
    // table: Sonnet 4.6 = claude-sonnet-4-6). Falls back to the ambient
    // local-first router on error.
    static let draftModel = "claude-sonnet-4-6"

    struct OutreachIntent {
        var person: String
        var company: String
        var toEmail: String      // often empty from voice; filled in the dialog
    }

    struct OutreachDraft {
        var intent: OutreachIntent
        var subject: String
        var body: String
        var provider: String
        var capWarning: String?     // non-nil when the founding-customer cap is hit
        var dedupeWarning: String?  // non-nil when this company/email was emailed before
        var groundingSource: String? // what the opener was grounded on (or why it stayed generic)
    }

    // An empty draft for the manual "Compose outreach" flow: the user types the
    // person + company in the dialog, then taps Regenerate to draft.
    static func emptyDraft() -> OutreachDraft {
        OutreachDraft(
            intent: OutreachIntent(person: "", company: "", toEmail: ""),
            subject: "",
            body: "",
            provider: "manual",
            capWarning: OutreachCap.warningIfCapped(),
            dedupeWarning: nil,
            groundingSource: nil
        )
    }

    // MARK: - Voice entry

    // Called for every ambient transcript chunk (hooked in AmbientListener).
    // Cheap regex gate first; only a match spins up an LLM call. Debounced so a
    // repeated phrase in the rolling transcript does not fire twice.
    func onTranscriptChunk(_ text: String) async {
        // Check in-flight BEFORE touching the debounce clock, otherwise a
        // matching chunk arriving during a draft call would reset the 20s
        // window without doing any work.
        guard !inFlight else { return }
        guard let intent = Self.parseIntent(text) else { return }
        guard Date().timeIntervalSince(lastTriggerAt) > 20 else { return }
        lastTriggerAt = Date()
        WakeLog.shared.log("coldEmail: voice intent person=\(intent.person) company=\(intent.company)")
        await draftAndPresent(intent: intent)
    }

    // MARK: - Intent parsing

    // Matches phrasings like:
    //   "Grux, draft outreach to Jane Doe at Acme Co"
    //   "draft a cold email to Sam at Bright Labs"
    //   "cold email to Maria Lopez at the Corner Cafe"
    // Returns nil when no clear "<verb> ... to <person> at <company>" shape is
    // present. Trailing email, if spoken, is pulled into toEmail.
    static func parseIntent(_ raw: String) -> OutreachIntent? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        // Deliberate command phrasings only. "reach out to" was removed: it is
        // common conversational English ("I should reach out to the PM at
        // Google") and would spuriously fire on ambient transcript fragments.
        let triggers = ["draft outreach to ", "draft a cold email to ", "cold email to ",
                        "draft an outreach email to ", "draft outreach for "]
        guard let trigger = triggers.first(where: { lower.contains($0) }) else { return nil }
        guard let tRange = lower.range(of: trigger) else { return nil }
        let after = String(text[tRange.upperBound...])

        // Split on " at " (last occurrence so multi-word names survive).
        let afterLower = after.lowercased()
        guard let atRange = afterLower.range(of: " at ", options: .backwards) else { return nil }
        let person = String(after[..<atRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        var company = String(after[atRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Pull a spoken/typed email out of the company tail if present.
        var email = ""
        if let found = firstEmail(in: company) {
            email = found
            company = company.replacingOccurrences(of: found, with: "").trimmingCharacters(in: .whitespaces)
        }
        // Trim trailing punctuation/filler.
        company = company.trimmingCharacters(in: CharacterSet(charactersIn: ".,!? "))
        guard !person.isEmpty, !company.isEmpty else { return nil }
        return OutreachIntent(person: person, company: company, toEmail: email)
    }

    private static func firstEmail(in s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}") else { return nil }
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range), let r = Range(m.range, in: s) else { return nil }
        return String(s[r])
    }

    // MARK: - Drafting

    func draftAndPresent(intent: OutreachIntent) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }
        guard let draft = await draft(intent: intent) else {
            WakeLog.shared.log("coldEmail: drafting failed for \(intent.company)")
            return
        }
        ColdEmailConfirmController.shared.present(draft: draft)
    }

    func draft(intent: OutreachIntent) async -> OutreachDraft? {
        // The one sanctioned place a name enters a prompt, read here on the main
        // actor and threaded in, so the prompt builder itself stays a pure fold.
        let system = Self.systemPrompt(identityLine: UserIdentity.systemPromptLine())
        // Ground the opener in real, verifiable facts so we never fabricate a
        // compliment ("loved the story behind your sourcing process") that could
        // embarrass the sender. Disambiguated by the recipient's own domain and gated
        // by a confidence check so we do not ground on a DIFFERENT company that
        // happens to share the name. Empty when nothing reliable, in which case
        // the model is told to stay generic.
        let (grounded, groundingSource) = await groundCompany(intent.company, email: intent.toEmail)
        let groundingBlock = grounded.isEmpty
            ? "No reliable web context was found. Keep the opener honest and non-specific. Do NOT invent details, achievements, products, or compliments about the company."
            : """
            Web context about \(intent.company) (identity verified, but FRESHNESS is not):
            \(grounded)

            Use this ONLY for DURABLE facts: what they make or do, their category,
            roughly where they are. Do NOT cite specific or volatile numbers
            (location counts, headcount, funding, revenue, dates), recent
            launches, awards, or "congrats on X" claims: those may be stale or
            wrong and would embarrass the sender. If something is not in this context,
            do not claim it.
            """

        let offerLine = OutreachPitch.load().isEmpty
            ? "Do not name any service, package, or price: none is configured, so any you write would be invented."
            : "Weave in whatever offer the pitch in the system prompt states, and nothing beyond it."

        let user = """
        Draft a short, warm cold-outreach email from the sender to \(intent.person) at \(intent.company).
        Keep it under 130 words. Open with a specific, genuine reason to reach
        out to \(intent.company), grounded in the context below. \(offerLine)
        Soft CTA ("let's chat, no commitment"). Commas and pipes, never em or en
        dashes.

        \(groundingBlock)

        Return ONLY a JSON object, no prose, no fences:
        { "subject": "...", "body": "..." }
        The body must be the full email including a "Hi \(intent.person)," opener
        and a sign-off in the sender's own first name. If you have not been told
        the sender's name, end after the closing line and add no name at all.
        """

        // Try Sonnet 4.6 directly (quality matters for outreach), fall back to
        // the local-first ambient router on any error, logging the fallback.
        var text = ""
        var provider = "claude/\(Self.draftModel)"
        // PINNED TO ANTHROPIC, DELIBERATELY. Sonnet is the quality tier this
        // surface was built around, and the fallback directly below is
        // AmbientLLM, which is local-first and (as of this sweep) routed, so a
        // local-only or custom-endpoint user IS served: the pinned call throws
        // missingKey immediately and the routed fallback answers. Routing the
        // primary instead would send "claude-sonnet-4-6" to a local server, eat a
        // 404 round trip, and land in the same fallback. It goes through the
        // registry with the provider pinned so there is one shared client and one
        // credential lookup.
        let routing = ModelRegistry.shared.resolvedRouting(
            provider: "anthropic", modelOverride: Self.draftModel)
        do {
            text = try await routing.backend.complete(
                apiKey: routing.apiKey,
                model: routing.modelId,
                system: system,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 500,
                temperature: 0.6,
                spanName: "coldEmail.draft",
                feature: "cold_email"
            )
        } catch {
            WakeLog.shared.log("coldEmail: Sonnet draft failed (\(error.localizedDescription)), falling back")
            do {
                let res = try await AmbientLLM.completeTagged(
                    system: system,
                    messages: [ClaudeMessage(role: "user", content: user)],
                    maxTokens: 500, temperature: 0.6, featureTag: "cold_email"
                )
                text = res.text
                provider = res.provider
            } catch {
                return nil
            }
        }

        let cleaned = EmailTriageEngine.stripThink(text)
        guard let obj = EmailTriageEngine.extractJSONObject(cleaned) else { return nil }
        let subject = DashSanitizer.clean((obj["subject"] as? String) ?? "Quick idea for \(intent.company)")
        let body = DashSanitizer.clean((obj["body"] as? String) ?? "")
        guard !body.isEmpty else { return nil }

        return OutreachDraft(
            intent: intent,
            subject: subject,
            body: body,
            provider: provider,
            capWarning: OutreachCap.warningIfCapped(),
            dedupeWarning: Self.recentlyEmailed(company: intent.company, email: intent.toEmail),
            groundingSource: groundingSource
        )
    }

    // Best-effort, time-boxed web lookup, returned with its source label.
    // Returns ("", reason) when there is nothing reliable, in which case the
    // drafter stays generic. Two guards against grounding on the WRONG company
    // that shares the target's name:
    //   1) Disambiguate by the recipient's own domain when we have it (search
    //      biased to that site), so "Rivera Coffee" the customer resolves to
    //      THEIR site, not a different Rivera Coffee.
    //   2) A confidence gate: a cheap LLM check confirms the retrieved context
    //      is clearly about this company before we let the drafter use it.
    private func groundCompany(_ company: String, email: String) async -> (String, String?) {
        let clean = company.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count > 1 else { return ("", "no company name") }

        let domain = Self.companyDomain(fromEmail: email)
        let query: String
        if let domain {
            // Bias the search to the recipient's own domain.
            query = "\(clean) \(domain) site:\(domain) what they do products"
        } else {
            query = "\(clean) company what they do products"
        }

        let result: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask { await WebResearch.research(query: query, depth: "fast") }
            group.addTask {
                try? await Task.sleep(nanoseconds: 12_000_000_000) // 12s cap
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard var text = result else { return ("", "lookup timed out") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.count < 40 || text.lowercased().hasPrefix("error") {
            return ("", "no reliable web result")
        }
        text = String(text.prefix(900))

        // Confidence gate. If the context might be a different same-name company,
        // discard it and let the drafter stay generic.
        let matched = await Self.contextMatchesCompany(company: clean, domain: domain, context: text)
        guard matched else {
            return ("", "discarded: low-confidence company match")
        }
        return (text, domain ?? "web search")
    }

    // Extracts a usable company domain from the recipient email, skipping the
    // common free-mail providers (which tell us nothing about the company) and
    // collapsing mail subdomains (mail.acme.com -> acme.com) so the site: search
    // does not over-narrow to a non-web host.
    static func companyDomain(fromEmail email: String) -> String? {
        let parts = email.split(separator: "@")
        guard parts.count == 2 else { return nil }
        var domain = parts[1].lowercased().trimmingCharacters(in: .whitespaces)
        let freemail: Set<String> = ["gmail.com", "googlemail.com", "yahoo.com", "outlook.com",
                                     "hotmail.com", "icloud.com", "me.com", "mac.com", "aol.com",
                                     "proton.me", "protonmail.com", "pm.me", "live.com", "msn.com",
                                     "fastmail.com", "hey.com", "duck.com", "tutanota.com",
                                     "zoho.com", "zohomail.com", "gmx.com", "example.com"]
        guard !domain.isEmpty, domain.contains(".") else { return nil }
        // Collapse a leading mail-host label so we search the real site.
        let mailPrefixes: Set<String> = ["mail", "email", "smtp", "mx", "m", "e"]
        let labels = domain.split(separator: ".").map(String.init)
        if labels.count > 2, let first = labels.first, mailPrefixes.contains(first) {
            domain = labels.dropFirst().joined(separator: ".")
        }
        guard !freemail.contains(domain) else { return nil }
        return domain
    }

    // Is the company name reflected in its domain (acme.com for "Acme")? Used to
    // warn the gate when the recipient emails from a domain that does not match
    // the company (a personal/portfolio domain, or a contractor), which is a
    // common way grounding latches onto the wrong subject.
    static func domainReflectsName(company: String, domain: String?) -> Bool {
        guard let domain else { return false }
        let root = domain.split(separator: ".").first.map(String.init) ?? domain
        let tokens = company.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return tokens.contains { $0.count >= 3 && root.contains($0) }
    }

    // Cheap check: is the web context clearly, primarily about THIS company (not
    // a person who works there, not a different same-named entity)? Strict by
    // design and defaults to NO on any doubt or error, so an uncertain match
    // never reaches the drafter as fact. Local-first via AmbientLLM. maxTokens
    // is generous because the local model (qwen3) spends budget on a <think>
    // block before answering; we strip it and read the final ANSWER line.
    static func contextMatchesCompany(company: String, domain: String?, context: String) async -> Bool {
        let hint = domain.map { " (email domain: \($0))" } ?? " (no company domain known)"
        let mismatchNote = (domain != nil && !domainReflectsName(company: company, domain: domain))
            ? "\nWARNING: the email domain does not obviously match the company name. The context may be about a PERSON who merely works there, or a different entity. If so, answer NO."
            : ""
        let system = "You decide whether web search context is primarily about a specific company. Be strict. Answer NO if the context is mainly about a person (a bio, portfolio, or LinkedIn) rather than the company itself, if it could be a different company that merely shares the name, or if you are at all unsure. End your reply with exactly 'ANSWER: YES' or 'ANSWER: NO'."
        let user = """
        Target company: \(company)\(hint)\(mismatchNote)

        Web context:
        \(context)

        Is the MAIN SUBJECT of this context the target company itself? Think
        briefly, then end with ANSWER: YES or ANSWER: NO.
        """
        do {
            let res = try await AmbientLLM.completeTagged(
                system: system,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 256, temperature: 0.0, featureTag: "cold_email_grounding_check"
            )
            let answer = stripThinkForGrounding(res.text).uppercased()
            if answer.contains("ANSWER: NO") || answer.contains("ANSWER:NO") { return false }
            if answer.contains("ANSWER: YES") || answer.contains("ANSWER:YES") { return true }
            // No clean final answer: default to discard (stay generic).
            return false
        } catch {
            return false
        }
    }

    private static func stripThinkForGrounding(_ s: String) -> String {
        EmailTriageEngine.stripThink(s)
    }

    // Scans ~/.grux/outreach/sent-*.jsonl for a prior send to the same company
    // or email. Returns a warning string with the date, or nil. Keeps the user
    // from re-pitching someone they already contacted.
    static func recentlyEmailed(company: String, email: String) -> String? {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("outreach")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let co = company.lowercased().trimmingCharacters(in: .whitespaces)
        let em = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard !co.isEmpty || !em.isEmpty else { return nil }
        var latest: String?
        for name in files where name.hasPrefix("sent-") && name.hasSuffix(".jsonl") {
            guard let content = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) else { continue }
            for line in content.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let lc = (obj["company"] as? String)?.lowercased() ?? ""
                let lt = (obj["to"] as? String)?.lowercased() ?? ""
                let tsMatch = (!co.isEmpty && lc == co) || (!em.isEmpty && lt == em)
                if tsMatch, let ts = obj["ts"] as? String {
                    if latest == nil || ts > latest! { latest = ts }
                }
            }
        }
        guard let ts = latest else { return nil }
        let day = String(ts.prefix(10))
        return "You already emailed \(company.isEmpty ? email : company) on \(day). Send again only if this is a deliberate follow-up."
    }

    // Manual "Compose outreach" entry: opens the dialog with an empty, fully
    // editable draft. The user types the person + company, taps Regenerate to draft.
    func startManualCompose() {
        ColdEmailConfirmController.shared.present(draft: Self.emptyDraft())
    }

    // MARK: - Send (called from the confirm dialog on the user's tap)

    @discardableResult
    func send(draft: OutreachDraft, toEmail: String) async -> Result<String, Error> {
        let to = toEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard to.contains("@") else {
            return .failure(ResendError.http(0, "No valid recipient address."))
        }
        // Sender identity is the user's own and is empty on a fresh install.
        // Refuse rather than mail from a domain this install does not own.
        guard let sender = OutreachSender.load() else {
            return .failure(ResendError.http(0, OutreachSender.setupMessage))
        }
        // Deliberately NO List-Unsubscribe header. This is one-to-one personal
        // outreach, and that header makes Apple Mail / Gmail render a "from a
        // mailing list" banner with an Unsubscribe button, which kills the
        // one-off feel. Recipients opt out by replying (reply-to is the sender's
        // own address), which is the right mechanism for personal mail.
        do {
            let result = try await ResendClient().send(
                from: sender.fromHeader,
                to: [to],
                subject: draft.subject,
                text: draft.body,
                listUnsubscribe: nil,
                replyTo: sender.email,
                inReplyTo: nil
            )
            logSend(draft: draft, to: to, messageId: result.id)
            return .success(result.id)
        } catch {
            return .failure(error)
        }
    }

    private func logSend(draft: OutreachDraft, to: String, messageId: String) {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("outreach")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dayKey = Self.dayKey()
        let url = dir.appendingPathComponent("sent-\(dayKey).jsonl")
        let entry: [String: Any] = [
            "ts": ISO8601DateFormatter().string(from: Date()),
            "to": to,
            "person": draft.intent.person,
            "company": draft.intent.company,
            "subject": draft.subject,
            "messageId": messageId,
            "provider": draft.provider,
            "capWarned": draft.capWarning != nil
        ]
        guard let line = try? JSONSerialization.data(withJSONObject: entry),
              var str = String(data: line, encoding: .utf8) else { return }
        str += "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(str.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? str.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func dayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Smoke test (fire-cold-email-test)

    // Payload (file contents) is optional: "<person>|<company>|<toEmail>".
    // Empty payload uses a built-in test target. Drafts, presents the dialog
    // (no auto-send), and writes a summary to resultPath.
    func runSmokeTest(payload: String, resultPath: String) async {
        var person = "Alex Rivera"
        var company = "Rivera Coffee Roasters"
        var toEmail = ""
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, !parts[0].isEmpty {
            person = parts[0]; company = parts[1]
            if parts.count >= 3 { toEmail = parts[2] }
        }
        let intent = OutreachIntent(person: person, company: company, toEmail: toEmail)
        let draft = await draft(intent: intent)

        var lines: [String] = []
        lines.append("cold-email-test @ \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("target: \(person) at \(company)")
        if let draft {
            lines.append("provider: \(draft.provider)")
            lines.append("grounding_source: \(draft.groundingSource ?? "none (generic opener)")")
            lines.append("cap_warning: \(draft.capWarning ?? "none")")
            lines.append("dedupe_warning: \(draft.dedupeWarning ?? "none")")
            lines.append("subject: \(draft.subject)")
            lines.append("body:")
            lines.append(draft.body)
            // Dash check for the no-em/en-dash rule.
            let hasDash = draft.body.contains("\u{2014}") || draft.body.contains("\u{2013}") ||
                          draft.subject.contains("\u{2014}") || draft.subject.contains("\u{2013}")
            lines.append("em_or_en_dash_present: \(hasDash)")
            ColdEmailConfirmController.shared.present(draft: draft)
        } else {
            lines.append("DRAFT FAILED")
        }
        try? lines.joined(separator: "\n").write(toFile: resultPath, atomically: true, encoding: .utf8)
        WakeLog.shared.log("coldEmail: smoke test -> \(resultPath)")
    }

    // MARK: - Prompt

    nonisolated private static func systemPrompt(identityLine: String) -> String {
        // The pitch is the user's own words, read off disk, and is empty until
        // they write one. Empty is a supported state: the model is told there
        // is no pitch and to claim nothing, which is safer than a default pitch
        // that would be a lie about whoever is running this install.
        let pitch = OutreachPitch.load()
        let pitchBlock = pitch.isEmpty
            ? """
            No pitch has been configured yet (\(OutreachPitch.path)). You therefore
            know NOTHING about what the sender does, sells, charges, or has built.
            Do not describe them, do not name a service, a price, a product, or a
            track record. Write a short, honest note that asks for a conversation
            and nothing more.
            """
            : """
            Use this pitch as the source of truth for who the sender is and what
            they offer, adapting it naturally to the recipient (do not paste it
            whole):

            \(pitch)

            The pitch above is the ONLY thing you know about the sender. Any
            service, price, guarantee, team member, delivery date, or credential
            not stated in it does not exist: do not invent one.
            """

        return """
        You write cold outreach emails on behalf of the person using this app.
        \(identityLine)

        \(pitchBlock)

        Voice: humble, soft CTA, concrete, no buzzwords. NEVER use em dashes or
        en dashes: use commas, periods, colons, parentheses, or a pipe. Keep it
        short and personal.

        ANTI-FABRICATION (critical): do NOT fabricate specifics about the
        recipient or their company (achievements, products, recent news, awards,
        "I loved your X"). Use a specific detail ONLY if it appears in the
        verified web context provided in the user message. If that context is
        empty or you are unsure, keep the opener honest and non-specific (a
        plain, genuine reason to reach out) rather than guessing. A
        generic-but-true opener beats a specific falsehood.
        """
    }
}

// The user's own outreach pitch, in their own words. Plain text at
// ~/.grux/outreach/pitch.md, absent on a fresh install. Absent means the
// drafter is told it knows nothing about the sender rather than inventing a
// biography, so an unconfigured install degrades to a short honest note instead
// of a confident fiction.
enum OutreachPitch {
    static var path: String { "~/.grux/outreach/pitch.md" }

    static func load() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("outreach")
            .appendingPathComponent("pitch.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
    }
}

// Who outreach is sent AS. Read from ~/.grux/outreach/sender.json:
//   {"email": "you@yourdomain.com", "name": "Your Name"}
// nil until configured, because the send provider only accepts a domain this
// install actually owns and guessing an address would mail as somebody else.
struct OutreachSender {
    var name: String
    var email: String

    static var setupMessage: String {
        "No outreach sender configured. Write ~/.grux/outreach/sender.json as {\"email\": \"you@yourdomain.com\", \"name\": \"Your Name\"} using a domain verified with your send provider, then try again."
    }

    var fromHeader: String {
        name.isEmpty ? email : "\(name) <\(email)>"
    }

    static func load() -> OutreachSender? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("outreach")
            .appendingPathComponent("sender.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let email = ((obj["email"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else { return nil }
        let name = ((obj["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return OutreachSender(name: name, email: email)
    }
}

// Client cap helper. Reads ~/.grux/outreach/active-client.json. The
// file can be either a bare string (the client name) or {"name": "..."}.
// Present + non-empty means the cap is hit and we must warn before any send.
enum OutreachCap {
    static func activeClient() -> String? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".grux").appendingPathComponent("outreach")
            .appendingPathComponent("active-client.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = obj["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        if let str = String(data: data, encoding: .utf8) {
            let trimmed = str.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t"))
            if !trimmed.isEmpty && trimmed != "{}" && trimmed != "null" { return trimmed }
        }
        return nil
    }

    static func warningIfCapped() -> String? {
        guard let client = activeClient() else { return nil }
        return "Client cap: \(client) is your one active engagement. Client work is capped at one at a time. Sending more outreach risks a second concurrent client. Send only if you mean to override the cap."
    }
}
