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

    private static let patterns: [NSRegularExpression] = [
        // I added / I've added / I have just scheduled / I went ahead and booked
        "(?:^|[.!?]\\s+|\\n)\\s*\(assent)I(?:'ve| have)?\\s+(?:just\\s+|already\\s+|also\\s+|now\\s+)?(?:gone ahead and\\s+|went ahead and\\s+)?(?:\(verbs))\\b",
        // Sentence that opens on the verb: `Shipped the groceries ...`, `Added to your calendar`
        "(?:^|[.!?]\\s+|\\n)\\s*(?:Done[.!,]?\\s+)?(?:Just\\s+)?(?:\(verbs))\\b",
        // Passive: `has been added`, `have been sent`, `is now scheduled`
        "\\b(?:has|have) been (?:\(verbs)|set)\\b",
        "\\bis now (?:\(verbs)|set)\\b",
        // A tool's status line: `ok: noted "..." as a reminder.` Live on the
        // local route with no tool call, copied from raw result lines in the thread.
        "^\\s*(?:ok|pending|approved):",
        // `Done.` / `All done.` standing alone as the reply's claim
        "(?:^|[.!?]\\s+)\\s*(?:All\\s+)?done[.!]",
    ].compactMap { try? NSRegularExpression(pattern: "(?i)" + $0) }

    static func claimsAnAction(_ reply: String) -> Bool {
        let range = NSRange(reply.startIndex..<reply.endIndex, in: reply)
        return patterns.contains { $0.firstMatch(in: reply, range: range) != nil }
    }

    /// `route` is the turn's provider tag (`ChatService.providerString`);
    /// `results` is every tool result of the turn, as the model saw it.
    static func vet(reply: String, route: String, results: [ToolResult]) -> (text: String, replaced: Bool) {
        guard route == "local", claimsAnAction(reply), !results.contains(where: backsAClaim) else {
            return (reply, false)
        }
        // A write that is waiting or failed: say what did happen.
        if let held = results.last(where: { !readOnlyTools.contains($0.tool) && !completed($0.result) }) {
            return (ToolReplyCopy.forPerson(tool: held.tool, input: held.input, result: held.result), true)
        }
        return (offer, true)
    }
}
