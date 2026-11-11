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
    /// After writing the person asked for that reads like a claim (D171). Said
    /// only when no write ran and nothing in `keepsWhatItReads` completed this
    /// turn, so it is true by construction, and it names what a made-up claim
    /// says happened (W57-FIX rounds 2 to 6). It opens on what the reply is, not
    /// on a denial (D179 item 3: "I only wrote this. I did not ..." read
    /// defensive), and says nothing of its use: the writing may be a pasted
    /// text sent back unchanged, or only a made-up claim (wave 66 round 1).
    nonisolated static let writtenOnlyNote = "This is only text. Nothing was saved, sent or added."
    /// Earlier words of `writtenOnlyNote`, still in older threads, where a small
    /// model copies them from; each is recognised and taken out as the current one is.
    /// The second was on a private build for one day (wave 66), and sits in its threads.
    nonisolated static let olderWrittenOnlyNotes = ["I only wrote this. I did not save, send or add anything just now.",
                                                    "Ready for you to use. Nothing was saved, sent or added."]

    /// True when the reply carries the writing note in any wording.
    nonisolated static func carriesWrittenOnlyNote(_ reply: String) -> Bool {
        ([writtenOnlyNote] + olderWrittenOnlyNotes).contains { reply.contains($0) }
    }
    /// After a reply that says something waits on the person, when Approvals is empty (D90).
    static let nothingWaitsLine = "Nothing waits in Approvals right now."
    /// Opens the line that names what Approvals holds, after the same kind of reply.
    nonisolated static let approvalsPrefix = "In Approvals right now: "

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

    /// Read-only tools that still keep something (W57-FIX round 4, every tool in
    /// `readOnlyTools` read): summarize_meeting saves the summary back to the
    /// meeting, youtube_transcript and research_web store into memory. They back no
    /// claim (their result says nothing about which claim was theirs, round 6);
    /// after one completed, the note after writing denies no save and a copied
    /// note goes.
    static let keepsWhatItReads: Set<String> = ["summarize_meeting", "youtube_transcript", "research_web"]

    /// What a keeper kept this turn, read from its result (D173): the summary
    /// saved back to the meeting (`ok: resummarized`), the transcript stored in
    /// memory (`YouTubeTool.savedLine`, said only with memory on), the answer
    /// stored in memory (`WebResearch.keptLine`). nil when it kept nothing.
    enum Kept: Equatable {
        case summary, transcript, answer

        /// Words that name what was kept, one of which a claim must carry.
        var names: [String] {
            switch self {
            case .summary: return ["summary", "summaries"]
            case .transcript: return ["transcript", "transcripts"]
            case .answer: return ["answer", "answers", "research", "findings", "result", "results"]
            }
        }
    }

    /// After a reply that claims something on a turn whose keeper kept
    /// something (W59-FIX round 3): what was kept, then that nothing else was
    /// done, true by construction (only looks and keepers ran, nothing waits).
    static let keptOnlyTail = "I did not send, share or add anything else just now."
    static func keptSentence(_ k: Kept) -> String {
        switch k {
        case .summary: return "I saved this summary to the meeting."
        case .transcript: return "I saved the video's transcript in memory."
        case .answer: return "I kept this answer in memory."
        }
    }
    /// Two summaries in one turn read plural (W59-FIX round 4 P3).
    static let keptSummaries = "I saved these summaries to their meetings."
    static func keptLine(_ kept: [Kept]) -> String {
        var said: [String] = []
        for k in kept {
            let one = k == .summary && kept.filter({ $0 == .summary }).count > 1 ? keptSummaries : keptSentence(k)
            if !said.contains(one) { said.append(one) }
        }
        return (said + [keptOnlyTail]).joined(separator: " ")
    }

    static func kept(_ r: ToolResult) -> Kept? {
        guard completed(r.result) else { return nil }
        switch r.tool {
        case "summarize_meeting": return r.result.hasPrefix("ok: resummarized") ? .summary : nil
        // Only in the tool's own header: a caption could carry the words (W59-FIX P3).
        case "youtube_transcript":
            let header = r.result.components(separatedBy: "\n\ntranscript:").first ?? ""
            return header.split(separator: "\n").contains { $0 == YouTubeTool.savedLine } ? .transcript : nil
        case "research_web": return r.result.hasSuffix(WebResearch.keptLine) ? .answer : nil
        default: return nil
        }
    }

    /// The reply with every copy of the kept line taken out: a model copies
    /// it from an earlier reply, and it is said only where true.
    static func withoutKeptLine(_ reply: String) -> String {
        var text = reply
        for piece in [Kept.summary, .transcript, .answer].map(keptSentence) + [keptSummaries, keptOnlyTail] {
            text = text.replacingOccurrences(of: piece, with: "")
        }
        guard text != reply else { return reply }
        return text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

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
    nonisolated private static let notDoneOpenings = [
        "pending", "refused", "error", "err:", "busy", "noop", "skipped", "miss:",
        "not_found", "not found", "unknown", "unconfirmed", "unmatched", "failed", "(no ",
        JaxToolGate.dryRunStatus,
    ]

    nonisolated static func completed(_ result: String) -> Bool {
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
        // Grux's own line for a waiting write is said only for a write this turn put
        // there (D162, live: "Okay. Not done yet: your note is waiting for your OK in
        // Approvals." copied from the turn before, with no tool run). Each copy goes;
        // a reply that was nothing else is answered as a made-up claim is, or, after a
        // question, with what Approvals really holds.
        let ownLines = waitingLines(results)
        let reply = withoutCopiedWaits(reply, keeping: ownLines)
        if reply.cut, ownLines.isEmpty, isOnlyAssent(reply.text) {
            guard let ask, asksAQuestion(ask) else { return (offer, true) }
            return (approvals.map(approvalsLine) ?? nothingDoneNote, true)
        }
        var (text, replaced) = claimCheck(reply: reply.text, results: results, ask: ask)
        replaced = replaced || reply.cut
        // A wait on the person with no write waiting this turn is a wait from an
        // earlier turn or a made-up one (D90): Grux says what Approvals really
        // holds, once, after any copy of that line the model brought along.
        // A reply carrying a copy of that line says what Approvals holds too, so it
        // gets the true line even with no wait in its own words (wave 21 round 1).
        // A copy of Grux's waiting line that was cut counts as carrying one
        // (W53-FIX): "Yes, it is still there." or "Sure thing!" was left with no
        // true line once the copy went, since the copy was what made D90 look.
        // What Approvals holds is true after any reply, so it is the line said;
        // the offer is kept for a reply that was nothing but an assent (above).
        let copiedOnly = reply.cut && ownLines.isEmpty
        if let approvals, waitingLines(results).isEmpty {
            let body = withoutApprovalsLine(text)
            let carriesCopy = copiedOnly || text.contains(approvalsPrefix) || text.contains(nothingWaitsLine)
            if carriesCopy || matches(waitsOnPerson, body) {
                let checked = appending(approvalsLine(approvals), to: body)
                replaced = replaced || checked != text
                text = checked
            }
        } else if copiedOnly, results.isEmpty, !text.contains(nothingDoneNote), !carriesWrittenOnlyNote(text) {
            // Approvals not known: with no tool run, that nothing was done is true.
            text = appending(nothingDoneNote, to: text)
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
    nonisolated static func appending(_ paragraph: String, to text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return paragraph }
        let fences = body.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }.count
        if fences % 2 == 1 { body += "\n```" }
        return body + "\n\n" + paragraph
    }

    /// The reply with every copy of `nothingDoneNote` and `writtenOnlyNote` taken
    /// out (W20-P3 2, W57-FIX): a model that copies an earlier corrected reply from
    /// the thread brings the note with it; callers say the note that is true now.
    static func withoutNote(_ reply: String) -> String {
        ([writtenOnlyNote] + olderWrittenOnlyNotes)
            .reduce(reply) { $0.replacingOccurrences(of: $1, with: nothingDoneNote) }
            .components(separatedBy: nothingDoneNote)
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

    /// Grux's own line for a write waiting in Approvals (`ToolReplyCopy`'s pending
    /// lines and `waitingLines`' "also waiting" ones), from its sentence start: the
    /// subject, "is (also) waiting for your OK in Approvals.", then its "Nothing ...
    /// until you approve it." sentence when it has one. A full stop inside the subject
    /// counts only before a non-space (an email address, a file name).
    private static let waitCopy = try? NSRegularExpression(pattern:
        #"(?:^|(?<=[.!?:]\s)|(?<=\n))[ \t]*(Not done yet: )?((?:[^\n.!?]|\.(?=\S))*? (?:is|are) (also )?waiting for your OK in Approvals\.)( Nothing (?:[^\n.!?]|\.(?=\S))*? until you approve it\.)?"#)

    /// The reply with every copy of Grux's waiting line taken out, except one that
    /// names a write in `keeping` (this turn's own). Only a sentence with Grux's
    /// signature is a copy: the "Not done yet: " opening, the "Nothing ... until you
    /// approve it." close, or "also waiting". The model's own words for a wait
    /// (`It's still waiting for your OK in the Approvals tray`) stay, for D90's check.
    static func withoutCopiedWaits(_ reply: String, keeping: [String]) -> (text: String, cut: Bool) {
        guard let waitCopy else { return (reply, false) }
        let ns = reply as NSString
        var cuts: [NSRange] = []
        for m in waitCopy.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            func group(_ i: Int) -> String? {
                m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i))
            }
            guard group(1) != nil || group(3) != nil || group(4) != nil, let core = group(2) else { continue }
            let line = (core + (group(4) ?? "")).trimmingCharacters(in: .whitespaces)
            let said = line.prefix(1).uppercased() + line.dropFirst()
            if keeping.contains(said) { continue }
            cuts.append(m.range)
        }
        guard !cuts.isEmpty else { return (reply, false) }
        var text = reply
        for r in cuts.reversed() { text = (text as NSString).replacingCharacters(in: r, with: "") }
        let tidy = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (tidy, true)
    }

    /// Words that only agree, with nothing said: what is left of a reply that was
    /// a copied waiting line after an "Okay." (D162).
    private static let assentOnly: Set<String> = [
        "", "ok", "okay", "sure", "got it", "done", "alright", "all right", "perfect", "great",
        "yes", "yep", "noted", "certainly", "of course", "absolutely", "no problem", "will do",
    ]

    static func isOnlyAssent(_ text: String) -> Bool {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted.subtracting(.whitespaces))
            .joined(separator: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return assentOnly.contains(words)
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
    nonisolated static let notDoneYet = "Not done yet: "

    /// Each waiting write's line, once per distinct write, in turn order. A different
    /// write that would read the same is named by its subject, and more than one such
    /// write by a count.
    /// The reply when the model wrote nothing (D194, live: "Okay. / Not done yet: that
    /// request is waiting for your OK in Approvals."): with a write waiting this turn
    /// it is Grux's waiting line alone, so the reply opens on what waits, not on an
    /// assent the model never gave. Every route, since only the local route is vetted.
    /// With nothing waiting and no write done, a call that was refused or failed
    /// is named instead (wave 67 round 1: offline mode refused `deep_research` on
    /// every hop and the bubble read "Okay." with no reason).
    static func emptyReply(results: [ToolResult]) -> String {
        let lines = waitingLines(results)
        if !lines.isEmpty { return lines.joined(separator: " ") }
        let done = doneLines(results)
        if !done.isEmpty { return done.joined(separator: " ") }
        if !results.contains(where: { !readOnlyTools.contains($0.tool) && completed($0.result) }),
           let stopped = results.last(where: { r in
               let opening = r.result.trimmingCharacters(in: .whitespaces).lowercased()
               // A lookup that found nothing did happen (wave 67 round 3: "(no active
               // tasks)" read "That did not happen"), so only a read's failure or
               // refusal is named; a read's own text may start "pending:" (wave 7 round 9).
               if readOnlyTools.contains(r.tool) { return opening.hasPrefix("error:") || opening.hasPrefix("refused:") }
               return !completed(r.result) && !opening.hasPrefix("pending")
           }) {
            return stoppedLine(stopped)
        }
        return "Okay."
    }

    /// What a person reads for a call that did nothing (wave 67 round 2). The
    /// result texts are written for the model ("Ask the user to turn on ..."), so
    /// only the openings ToolReplyCopy words for a person go through it; a short
    /// plain reason after "skipped:" is named; every other one says only what
    /// is true of all of them.
    private static func stoppedLine(_ r: ToolResult) -> String {
        let raw = r.result.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        if lower.hasPrefix("error:") {
            return ToolReplyCopy.forPerson(tool: r.tool, input: r.input, result: "error:" + raw.dropFirst("error:".count))
        }
        if lower.hasPrefix("refused:") || lower.hasPrefix("busy") || raw.hasPrefix(JaxToolGate.dryRunStatus) {
            return ToolReplyCopy.forPerson(tool: r.tool, input: r.input, result: raw)
        }
        if lower.hasPrefix("unconfirmed") { return "I tried that, but I could not confirm it worked." }
        if lower.hasPrefix("skipped:") {
            let reason = raw.dropFirst("skipped:".count).split(separator: ".", maxSplits: 1).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let plain = CharacterSet.letters.union(.whitespaces).union(CharacterSet(charactersIn: "'"))
            if !reason.isEmpty, reason.count <= 60, reason.unicodeScalars.allSatisfy(plain.contains),
               !reason.lowercased().contains("user") {
                return "I did not do that: \(reason)."
            }
        }
        return "That did not happen, so nothing was changed."
    }

    /// D209: "Can you remember that I prefer short answers?" saved the fact and
    /// the bubble read "Okay.", so nobody could tell what was kept. A write that
    /// was done and has its own sentence for a person ("Got it, I will remember:
    /// ...", "Added ... to your tasks.") is said, each once; a fold of a repeat
    /// adds nothing, since the write it repeats is already said.
    static func doneLines(_ results: [ToolResult]) -> [String] {
        var lines: [String] = []
        for r in results where backsAClaim(r) && ToolReplyCopy.saysWhatWasDone.contains(r.tool)
            && r.result != RepeatedPendingCalls.doneResult {
            let line = ToolReplyCopy.forPerson(tool: r.tool, input: r.input, result: r.result)
            if !lines.contains(line) { lines.append(line) }
        }
        return lines
    }

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
        guard !results.contains(where: backsAClaim) else {
            // A note the model copied from an earlier reply is false beside a real
            // write (W57-FIX round 3); Grux says its own notes where they are true.
            // So is a copied kept line (W59-FIX round 4).
            let noLine = withoutKeptLine(reply)
            guard noLine != reply || reply.contains(nothingDoneNote) || carriesWrittenOnlyNote(reply) else {
                return (reply, false)
            }
            let kept = withoutNote(noLine)
            if kept.isEmpty {
                var lines: [String] = []
                for done in results where backsAClaim(done) {
                    let line = ToolReplyCopy.forPerson(tool: done.tool, input: done.input, result: done.result)
                    if !lines.contains(line) { lines.append(line) }
                }
                return (lines.joined(separator: "\n\n"), true)
            }
            return (kept, true)
        }
        // A note the model copied from an earlier reply is false beside a write
        // waiting this turn ("did not queue", "Nothing was saved"), so it goes and
        // Grux names the waiting write after the reply (W57-FIX rounds 8 and 9).
        // After a look that kept something, a copied "I did not save" may deny a
        // save that happened (round 5): it becomes the older note, true there, and
        // the reply is never left empty (round 7).
        let keeperRan = results.contains { keepsWhatItReads.contains($0.tool) && completed($0.result) }
        let waits = results.contains(where: isWaiting)
        let anyCopy = reply.contains(nothingDoneNote) || carriesWrittenOnlyNote(reply)
        let original = reply
        let kept: String
        if waits && anyCopy {
            kept = withoutNote(original)
        } else if keeperRan && carriesWrittenOnlyNote(original) {
            let rest = withoutNote(original)
            kept = rest.isEmpty ? nothingDoneNote : appending(nothingDoneNote, to: rest)
        } else {
            kept = original
        }
        let reply = withoutKeptLine(kept)
        let copied = reply != original
        let keptKinds = results.compactMap(Self.kept)
        // A reply that was only a copied line is never left empty (W59-FIX
        // round 4): the line that is true now, or, with a write waiting,
        // nothing here and the waiting line after (`vet`).
        // An assent left after the copy ("Okay.") is answered as a bare assent
        // is (D162, W59-FIX round 5): it read as done with nothing done.
        if copied, reply.isEmpty || isOnlyAssent(reply) {
            if waits { return ("", true) }
            if let held = results.last(where: { !readOnlyTools.contains($0.tool) && !completed($0.result) }) {
                return (ToolReplyCopy.forPerson(tool: held.tool, input: held.input, result: held.result), true)
            }
            if !keptKinds.isEmpty { return (keptLine(keptKinds), true) }
            // A reply that was only the copy says nothing was done; an assent
            // left after it is the offer unless the person asked a question.
            if reply.isEmpty { return (nothingDoneNote, true) }
            if let ask, asksAQuestion(ask) { return (nothingDoneNote, true) }
            return (offer, true)
        }
        let tier = thirdPerson(ask: ask, results: results)
        if !claimsAnAction(reply, thirdPerson: tier == .claims) {
            guard tier == .noted, matches(thirdPersonPatterns, reply) || matches(happenedPatterns, reply) else {
                return (reply, copied)
            }
            return (appending(nothingDoneNote, to: withoutNote(reply)), true)
        }
        // A write that is waiting or failed: say what did happen.
        if let held = results.last(where: { !readOnlyTools.contains($0.tool) && !completed($0.result) }) {
            return (ToolReplyCopy.forPerson(tool: held.tool, input: held.input, result: held.result), true)
        }
        // D171: writing the person asked for ("We started as a small family
        // business") is the answer, not a claim; the note after it is true
        // whatever the words meant, and says so of a made-up "I've saved it"
        // too (W57-FIX round 2), so no reading of the ask can leave one standing.
        // After a look that kept something, the turn reads as before wave 57: a
        // claim gets the offer, since no note can both deny a made-up save and
        // stay true of the real one (round 7).
        // D173, W59-FIX round 3: a look that kept something ("ok: resummarized")
        // makes "I've updated the summary" true and "I've sent it to Maria"
        // false, and no reading of the words told them apart in three rounds.
        // The reply stays, with Grux's own line saying what was kept and that
        // nothing else was done: true either way, as the writing note is.
        if !keptKinds.isEmpty {
            return (appending(keptLine(keptKinds), to: withoutNote(reply)), true)
        }
        if let ask, !keeperRan, DraftAsk.asksForWriting(ask) {
            // Only reads that kept nothing can have run here, so the note is true.
            return (appending(writtenOnlyNote, to: withoutNote(reply)), true)
        }
        return (offer, true)
    }
}
