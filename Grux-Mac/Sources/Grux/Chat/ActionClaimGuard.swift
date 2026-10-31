import Foundation

/// A reply on the local route may not say an action happened unless a tool ran
/// in the same turn (operator ruling, 2026-09-27). Measured on qwen2.5:7b with
/// no key: `ship the groceries tomorrow` came back `Shipped the groceries for
/// tomorrow at 3 PM. Track it in the Workflows tab.` with no tool call at all;
/// the model had copied the shape of earlier assistant lines in the thread.
/// A person reads that as done. The whole reply is replaced with a plain offer,
/// because what follows a made-up action (where to track it) is made up too.
///
/// A tool CALL is not enough (RV12): the claim needs a tool RESULT in the same
/// turn that says an action completed. A write that waits in Approvals, one
/// that failed or was refused, and a read (a search, a listing) do not license
/// `I've saved your note`. When a write is waiting or failed, the person gets
/// that result in plain words instead of the offer.
@MainActor
enum ActionClaimGuard {
    static let offer = "I have not done that. Want me to?"
    /// After a third-person sentence on a turn that ran no tool, when the
    /// person seemed to ask a question (wave 20 round 4): true by construction,
    /// so it is right whether the sentence answered or claimed.
    static let nothingDoneNote = "I did not start, send or queue anything just now."
    /// After a reply that says something waits on the person, when Approvals is empty (D90).
    static let nothingWaitsLine = "Nothing waits in Approvals right now."
    /// Opens the line that names what Approvals holds, after the same kind of reply.
    static let approvalsPrefix = "In Approvals right now: "

    typealias ToolResult = (tool: String, input: [String: Any], result: String)

    /// Tools that only look: nothing they return says an action happened.
    /// Every tool on the gate's safe list is either here or in `localActions`,
    /// and `ActionClaimGuardTests` fails on one that is in neither, so a new
    /// tool cannot license a claim by being forgotten.
    static let readOnlyTools: Set<String> = [
        "list_tasks", "list_proposed_actions", "list_memories", "search_memory",
        "decision_log_query", "recall_thread_summary", "get_current_activity",
        "read_workday_log", "list_inbox", "list_macros", "read_screen",
        "list_library_tracks", "slack_list_channels", "notion_list_databases",
        "design_list_projects", "design_system_list", "agent_list", "agent_status",
        "documents_list", "documents_read", "fs_list", "fs_read", "list_events",
        "list_folders", "list_meetings", "list_meetings_in_folder",
        "list_research_reports", "list_skills", "list_speakers", "lookup_contact",
        "get_meeting_transcript", "focus_summary", "search_meetings", "search_notes",
        "speaker_stats", "shell_status", "summarize_meeting", "search_web",
        "research_web", "youtube_transcript", "grux_orb_hint", "grux_orb_stage",
    ]

    /// Ungated tools that do change something on this Mac, so an `ok` from
    /// one does back a claim.
    static let localActions: Set<String> = [
        "add_task", "remove_task", "complete_task", "focus_on_task",
        "promote_action", "dismiss_action", "remember_slang", "remember_fact",
        "capture_memory", "mark_memory_reviewed", "play_music_track", "play_on_youtube",
        "set_mode", "design_create_project", "design_generate", "design_open_project",
        "design_restore_version", "design_system_activate", "design_system_generate_brand",
        "design_system_import", "compact_thread_now", "run_focus_check_now",
        "open_app", "open_url",
    ]

    /// How a result opens when nothing was done: waiting in Approvals, refused,
    /// failed, found nothing, or held by a dry-run turn (`dryrun:`, integrated
    /// review P1: `I've opened Safari` passed after a held `open_app`).
    private static let notDoneOpenings = [
        "pending", "refused", "error", "err:", "busy", "noop", "skipped", "miss:",
        "not_found", "not found", "unknown", "unconfirmed", "unmatched", "failed", "(no ",
        JaxToolGate.dryRunStatus,
    ]

    static func completed(_ result: String) -> Bool {
        let opening = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !notDoneOpenings.contains { opening.hasPrefix($0) }
    }

    /// True when this result says an action happened.
    static func backsAClaim(_ r: ToolResult) -> Bool {
        !readOnlyTools.contains(r.tool) && completed(r.result)
    }

    /// Past-tense verbs of things Grux could be asked to do. Forms that read the
    /// same in the imperative (`set`, `put`) are left to the explicit patterns.
    private static let verbs = [
        "added", "created", "scheduled", "rescheduled", "sent", "shipped", "booked",
        "deleted", "removed", "saved", "opened", "closed", "launched", "moved",
        "renamed", "emailed", "texted", "messaged", "posted", "published", "submitted",
        "uploaded", "ordered", "cancell?ed", "updated", "wrote", "drafted", "invited",
        "installed", "archived", "forwarded", "replied", "paid", "bought", "purchased",
        "deployed", "pushed", "committed", "queued", "stored", "logged", "recorded",
        "started", "ran", "turned (?:on|off)", "set up", "reminded",
        // Live on this route: `I've noted your grocery run for tomorrow.` with
        // no tool call. A note is an action here, so `noted` counts.
        "noted", "jotted", "made a note", "took a note", "added it",
    ].joined(separator: "|")

    /// A word of assent before the claim, joined by a comma, colon, hyphen or
    /// dash. Live: `Sure, I've added "draft the Grux 3.0 release notes" to your
    /// tasks.` and `Got it - I've added "Write down your thoughts" to your
    /// tasks.`, each with no tool call and no task stored.
    private static let assent =
        "(?:(?:Sure|Okay|OK|Ok|Alright|All right|Got it|Of course|Absolutely|Certainly|No problem|Yes|Yep|Great|Perfect|Done)\\s*[,:\\-\\u2013\\u2014]\\s*)?"

    /// Before a contraction: words whose `'s` is `is` or `has` in an answer
    /// (`what's scheduled`, `here's`, `it's sent from`, `let's`), never a claim.
    private static let notAnAnswer =
        "(?<!\\b(?:what|that|this|here|there|who|where|which|how|it|let|nothing|everything|something))"

    /// Before a contracted passive: words whose `'s been` or `'ve been` reads
    /// back what happened, not what Grux did (`what's been added`, `nothing's
    /// been added`, `you've been invited`). `it's been added` stays a claim.
    private static let notAReadBack =
        "(?<!\\b(?:what|that|here|there|who|where|which|how|nothing|everything|something|you))"

    /// Verbs of something happening, for the third-person forms: `scheduled`,
    /// `saved` and the like after `'s` usually mean `is` (a read of the calendar).
    private static let happening =
        "(?:started|begun|kicked off|launched|queued|sent|shipped|submitted|deployed|posted|published|gone out)"

    /// Claims in Grux's own voice, or in a shape no read back takes: checked on
    /// every turn.
    private static let patterns: [NSRegularExpression] = [
        // I added / I've added / I have just scheduled / I went ahead and booked /
        // we started, we've started (wave 20)
        "(?:^|[.!?]\\s+|\\n)\\s*\(assent)(?:I|We)(?:['\u{2019}]ve| have)?\\s+(?:just\\s+|already\\s+|also\\s+|now\\s+)?(?:gone ahead and\\s+|went ahead and\\s+)?(?:\(verbs))\\b",
        // Sentence that opens on the verb: `Shipped the groceries ...`, `Added to your calendar`
        "(?:^|[.!?]\\s+|\\n)\\s*(?:Done[.!,]?\\s+)?(?:Just\\s+)?(?:\(verbs))\\b",
        // `is now scheduled`
        "\\bis now (?:\(verbs)|set)\\b",
        // Grux says it waits on the person (D85, live: `I'm waiting for your OK in
        // the Approvals tray`). Only a write waiting this turn backs it, and then
        // Grux names that write in its own words. `still waiting` is a wait from an
        // earlier turn, read back (wave 20).
        "\\bI(?:['\u{2019}]m| am)\\s+(?:now\\s+|just\\s+)?waiting (?:for|on) your (?:OK|okay|approval|go-ahead|go ahead|confirmation|sign-off)\\b",
        // A tool's status line: `ok: noted "..." as a reminder.` Live on the
        // local route with no tool call, copied from raw result lines in the thread.
        "^\\s*(?:ok|pending|approved):",
        // `Done.` / `All done.` standing alone as the reply's claim
        "(?:^|[.!?]\\s+)\\s*(?:All\\s+)?done[.!]",
    ].compactMap { try? NSRegularExpression(pattern: "(?i)" + $0) }

    /// Third-person claims (D85, live: `The Foundry cycle's started;` with no
    /// tool call). The same words are how a read reports what it found
    /// (`Maria's sent you two emails`, `your 3 PM meeting's started`) and how
    /// an answer reads back an earlier turn (`Did it send?` `it's queued for
    /// your approval`), and no rule on the reply's words tells them apart
    /// (wave 20 rounds 1 and 2). So they count only when the person asked Grux
    /// to act, not a question, and the turn did not just read cleanly: a read
    /// beside a write that failed still leaves the claim to check.
    private static let thirdPersonPatterns: [NSRegularExpression] = [
        // Passive: `has been added`, `have been sent`; a read back after a read
        // (`Your order has been shipped`, wave 20 round 2)
        "(?<!\\b(?:what|that|who|which|you|nothing|everything|something)\\s)\\b(?:has|have) been (?:\(verbs)|set)\\b",
        // Contracted passive (D85): `it's been added`, `they've been sent`
        "\(notAReadBack)['\u{2019}](?:s|ve) been (?:\(verbs)|set)\\b",
        // Contracted perfect: `cycle's started`, `email's sent`
        "\(notAnAnswer)['\u{2019}]s\\s+(?:just\\s+|already\\s+|now\\s+)?\(happening)\\b",
        // The same, written out (wave 20): `The Foundry cycle has started.`
        "(?<!\\b(?:what|who|which|that|you|nobody|no one|nothing|anyone|anybody|someone|somebody))\\s+(?:has|have)\\s+(?:just\\s+|already\\s+|now\\s+)?\(happening)\\b",
        // `it's sent.`, `that's queued.`: the short claim ends its clause, where
        // the answer goes on (`it's sent from your work address`).
        "\\b(?:it|that|this)['\u{2019}]s\\s+(?:just\\s+|already\\s+|now\\s+)?\(happening)(?=\\s*(?:[.!;,]|$)|\\s+for\\b)",
    ].compactMap { try? NSRegularExpression(pattern: "(?i)" + $0) }

    /// Something happened, in the simple past or with `was` or `got` (D90, live:
    /// `Yes, the Foundry cycle started earlier.` after "Did the Foundry build
    /// start?"). Read only after a question with no tool run, where what follows
    /// is `nothingDoneNote`, true whatever the sentence meant, so a wide net costs
    /// a true line under a true answer at worst.
    private static let happenedPatterns: [NSRegularExpression] = [
        "\\b(?:started|began|begun|kicked off|launched|queued|sent|shipped|submitted|deployed|posted|published|went out)\\b",
    ].compactMap { try? NSRegularExpression(pattern: "(?i)" + $0) }

    /// The reply says something waits on the person (D90, live: `It's still
    /// waiting for your OK in the Approvals tray` with nothing of the kind there).
    private static let waitsOnPerson: [NSRegularExpression] = [
        "\\b(?:waiting|waits|wait) (?:for|on) your (?:OK|okay|approval|go-ahead|go ahead|confirmation|sign-off|yes)\\b",
        "\\b(?:awaiting|needs?) your (?:OK|okay|approval|go-ahead|go ahead|confirmation|sign-off)\\b",
        "\\bin (?:the )?Approvals\\b",
    ].compactMap { try? NSRegularExpression(pattern: "(?i)" + $0) }

    /// What Approvals holds, in one line Grux can stand behind.
    static func approvalsLine(_ waiting: [String]) -> String {
        guard let first = waiting.first else { return nothingWaitsLine }
        var head = first.trimmingCharacters(in: .whitespacesAndNewlines)
        while head.hasSuffix(".") { head.removeLast() }
        return approvalsPrefix + head + (waiting.count > 1 ? ", and \(waiting.count - 1) more." : ".")
    }

    /// `thirdPerson`: whether the third-person forms count this turn
    /// (`thirdPerson(ask:results:)` is `.claims`).
    static func claimsAnAction(_ reply: String, thirdPerson: Bool = true) -> Bool {
        matches(patterns, reply) || (thirdPerson && matches(thirdPersonPatterns, reply))
    }

    private static func matches(_ list: [NSRegularExpression], _ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return list.contains { $0.firstMatch(in: text, range: range) != nil }
    }

    /// How the third-person forms are read this turn.
    enum ThirdPerson: Equatable {
        /// As claims: a write did not complete, or the person asked Grux to act.
        case claims
        /// Kept, with `nothingDoneNote` after them: the person seemed to ask a
        /// question and no tool ran. No word rule tells every request from every
        /// question, so a request read as a question still never reads as done.
        case noted
        /// Not at all: a read completed this turn and they report it.
        case reports
    }

    /// An unknown ask is read as a request.
    static func thirdPerson(ask: String?, results: [ToolResult]) -> ThirdPerson {
        if results.contains(where: { !readOnlyTools.contains($0.tool) && !completed($0.result) }) { return .claims }
        // A read that found nothing or failed reports nothing (wave 20 round 4).
        if results.contains(where: { readOnlyTools.contains($0.tool) && completed($0.result) }) { return .reports }
        if let ask, asksAQuestion(ask) { return .noted }
        return .claims
    }

    /// A request anywhere in the message makes it a request, whatever opens it
    /// or ends it (`Thanks! Can you send it to Maria too?`, wave 20 round 3).
    private static let requestPhrase = try? NSRegularExpression(pattern:
        "\\b(?:(?:can|could|would|will|wo?n't) (?:you|u)|please|pls|plz|kindly|any chance|is it possible|go ahead|i(?: want| need| would like|'d like) you|why (?:don't|not)|how about|what about|when (?:you|you're)|do you (?:mind|think)|are you able|is there a way|is it ok(?:ay)?)\\b")

    /// Words with no meaning for the question: greetings, thanks, assent,
    /// fillers and the assistant's name, skipped before the first word that
    /// counts (`Good morning Grux, did it send`).
    private static let fillers: Set<String> = [
        "hey", "hi", "hello", "yo", "ok", "okay", "so", "and", "also", "but", "then", "now", "well",
        "oh", "um", "good", "morning", "afternoon", "evening", "thanks", "thank", "you", "great", "cool",
        "yes", "yeah", "yep", "no", "nope", "sure", "alright", "there", "-", "grux", "jax",
    ]

    /// Words a question opens with. A trailing `?` alone is not one: a
    /// request ends in `?` as often (`Grux, upgrade yourself, ok?`).
    private static let questionOpeners: Set<String> = [
        "what", "what's", "whats", "who", "who's", "whos", "when", "where", "where's", "which", "why",
        "how", "how's", "did", "didn't", "does", "doesn't", "is", "isn't", "are", "aren't", "was",
        "wasn't", "were", "has", "hasn't", "haven't", "am", "any", "anything", "will", "should",
    ]

    /// `do` and `have` open a question before who is asked about (`Do I have
    /// meetings`, `Have you sent it`), or before a noun when it ends in `?`
    /// (`Have the builds started?`); `Do it now?`, `Do my weekly review` and
    /// `Have it sent to Maria` ask Grux to act.
    private static let auxiliaryOpeners: Set<String> = ["do", "have"]
    private static let subjects: Set<String> = ["i", "you", "we", "they", "he", "she"]
    private static let objects: Set<String> = ["it", "that", "this", "them", "my", "your", "our"]

    /// True when the person's message asks something rather than asking Grux to
    /// act. Fails toward a request, which keeps the claim check on: a request
    /// phrase anywhere is a request; otherwise every sentence with a word that
    /// counts must open as a question (`Did it go out? If not, send it.` is a
    /// request, wave 20 round 4).
    static func asksAQuestion(_ ask: String) -> Bool {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if requestPhrase?.firstMatch(in: text, range: range) != nil { return false }
        let names = fillers.union([UserIdentity.assistantName.lowercased()])
        var asked = false
        for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!?")) {
            guard let opens = opensAsQuestion(sentence, names: names, endsInMark: text.hasSuffix("?")) else { continue }
            guard opens else { return false }
            asked = true
        }
        return asked
    }

    /// nil when the sentence has no word that counts; otherwise whether its
    /// first clause with one opens as a question.
    private static func opensAsQuestion(_ sentence: String, names: Set<String>, endsInMark: Bool) -> Bool? {
        for clause in sentence.components(separatedBy: CharacterSet(charactersIn: ",;:")) {
            let words = clause.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                .drop { names.contains($0) }
            guard let first = words.first else { continue }
            if auxiliaryOpeners.contains(first) {
                let next = words.dropFirst().first ?? ""
                return subjects.contains(next) || (endsInMark && !next.isEmpty && !objects.contains(next))
            }
            return questionOpeners.contains(first)
        }
        return nil
    }

    /// True when this result is a write waiting in Approvals: the gate's `pending:`
    /// status from a tool that writes. A read whose CONTENT starts with "pending" is not.
    static func isWaiting(_ r: ToolResult) -> Bool {
        !readOnlyTools.contains(r.tool)
            && r.result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("pending:")
    }

    /// `route` is the turn's provider tag (`ChatService.providerString`);
    /// `results` is every tool result of the turn, as the model saw it.
    /// `ask` is the person's message this turn: a question is answered, not
    /// acted on, so its answer's third-person sentences are not claims.
    /// `approvals` is what waits in Approvals now (nil: not known, not checked).
    static func vet(reply: String, route: String, results: [ToolResult], ask: String? = nil,
                    approvals: [String]? = nil) -> (text: String, replaced: Bool) {
        guard route == "local" else { return (reply, false) }
        var (text, replaced) = claimCheck(reply: reply, results: results, ask: ask)
        // A wait on the person with no write waiting this turn is a wait from an
        // earlier turn or a made-up one (D90): Grux says what Approvals really
        // holds, once, after any copy of that line the model brought along.
        // A reply carrying a copy of that line says what Approvals holds too, so it
        // gets the true line even with no wait in its own words (wave 21 round 1).
        if let approvals, waitingLines(results).isEmpty {
            let body = withoutApprovalsLine(text)
            let carriesCopy = text.contains(approvalsPrefix) || text.contains(nothingWaitsLine)
            if carriesCopy || matches(waitsOnPerson, body) {
                let checked = appending(approvalsLine(approvals), to: body)
                replaced = replaced || checked != text
                text = checked
            }
        }
        // A write waiting in Approvals is always named, by Grux, in its own paragraph
        // after the reply (D28, live: "Got it. You're good to go." while
        // foundry_upgrade_cycle sat waiting). Keyed on the RESULT, never on wording, and
        // the model's text is left as the claim check left it: eight review rounds
        // showed that rewriting free text (dropping sentences, replacing the reply)
        // loses true answers and shows tool output. The paragraph opens "Not done yet"
        // so it overrides any claim in the reply the claim check could not see.
        let missing = waitingLines(results).filter { !text.contains($0) }
        guard !missing.isEmpty else { return (text, replaced) }
        let joined = missing.joined(separator: " ")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (joined, true) }
        let lowered = joined.prefix(1).lowercased() + joined.dropFirst()
        return (appending(Self.notDoneYet + lowered, to: text), true)
    }

    /// `paragraph` after `text`, outside any code fence `text` leaves open
    /// (counted the way the renderer does: a line that starts with three
    /// backticks), so a fence never swallows it.
    static func appending(_ paragraph: String, to text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return paragraph }
        let fences = body.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        if fences % 2 == 1 { body += "\n```" }
        return body + "\n\n" + paragraph
    }

    /// The reply with every copy of `nothingDoneNote` taken out (W20-P3 2): a model
    /// that copies an earlier corrected reply from the thread brings the note with
    /// it, and the note is appended once after this.
    static func withoutNote(_ reply: String) -> String {
        reply.components(separatedBy: nothingDoneNote)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The reply with any copy of the Approvals line taken out, so it is said once.
    /// A copy is cut wherever it sits, inline too (the model copies Grux's lines into
    /// its own sentences), from the prefix to its own sentence end, so what follows it
    /// in the same paragraph stays.
    static func withoutApprovalsLine(_ reply: String) -> String {
        reply.replacingOccurrences(of: approvalsCopy, with: "", options: .regularExpression)
            .components(separatedBy: nothingWaitsLine)
            .flatMap { $0.components(separatedBy: "\n\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// One copy of the Approvals line: the prefix, then up to the LAST full stop on
    /// that line that ends a sentence (followed by a space or the line's end), or the
    /// line's end. `approvalsLine` always ends on such a full stop, and a summary can
    /// hold one too ("Lunch with Dr. Lee", "e.g. the orb", "Wait... what"), so the
    /// first one would leave a piece of the old line behind (wave 21 round 2). The
    /// cost: a sentence of the model's with its own full stop after a copy on the
    /// same line goes with the copy.
    private static let approvalsCopy = "(?m)[ \\t]*" + NSRegularExpression.escapedPattern(for: approvalsPrefix)
        + #"(?:[^\n]*\.(?=\s|$)|[^\n]*$)"#

    /// Opens the paragraph that names what waits, after a reply that may have said otherwise.
    static let notDoneYet = "Not done yet: "

    /// Each waiting write's line, once per distinct write, in turn order. A different
    /// write that would read the same is named by its subject, and more than one such
    /// write by a count.
    static func waitingLines(_ results: [ToolResult]) -> [String] {
        var lines: [String] = []
        var seen: Set<String> = []
        var also: [(subject: String, count: Int)] = []
        for w in results where isWaiting(w) {
            // The same write asked twice is one wait.
            let key = w.tool + "|" + w.input.keys.sorted().map { "\($0)=\(w.input[$0] ?? "")" }.joined(separator: "&")
            guard seen.insert(key).inserted else { continue }
            let line = ToolReplyCopy.forPerson(tool: w.tool, input: w.input, result: w.result)
            if !lines.contains(line) { lines.append(line); continue }
            let subject = ToolReplyCopy.subject(tool: w.tool, input: w.input)
            if let i = also.firstIndex(where: { $0.subject == subject }) { also[i].count += 1 }
            else { also.append((subject, 1)) }
        }
        for a in also {
            let s = a.subject.prefix(1).uppercased() + a.subject.dropFirst()
            lines.append(a.count == 1 ? "\(s) is also waiting for your OK in Approvals."
                                      : "\(s) and \(a.count - 1) more like it are also waiting for your OK in Approvals.")
        }
        return lines
    }

    /// The claim check (A18, RV12): a reply may not say an action happened unless a
    /// result this turn says one completed.
    private static func claimCheck(reply: String, results: [ToolResult], ask: String?) -> (text: String, replaced: Bool) {
        guard !results.contains(where: backsAClaim) else { return (reply, false) }
        let tier = thirdPerson(ask: ask, results: results)
        if !claimsAnAction(reply, thirdPerson: tier == .claims) {
            guard tier == .noted, matches(thirdPersonPatterns, reply) || matches(happenedPatterns, reply) else {
                return (reply, false)
            }
            return (appending(nothingDoneNote, to: withoutNote(reply)), true)
        }
        // A write that is waiting or failed: say what did happen.
        if let held = results.last(where: { !readOnlyTools.contains($0.tool) && !completed($0.result) }) {
            return (ToolReplyCopy.forPerson(tool: held.tool, input: held.input, result: held.result), true)
        }
        return (offer, true)
    }
}
