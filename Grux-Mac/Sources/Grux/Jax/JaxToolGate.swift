import Foundation

// The universal tool choke point. ChatService.dispatchTool is a flat switch that,
// historically, called each tool's dispatch directly. Only compose_email self
// gated, which made the guardrail model opt-in per tool: the exact opposite of
// fail safe. Any comms / spend / exfil tool whose author forgot to call the gate
// silently bypassed all five of the hard rules (Slack posting as the user, Notion
// exfil of memories and workday logs, ShellTool curl, and so on).
//
// JaxToolGate closes that hole structurally. dispatchTool now runs EVERY tool call
// through JaxToolGate.evaluate(name:input:) BEFORE the underlying tool runs. The
// gate classifies the call into a ProposedAction and hands it to the existing
// DecisionGate.shared.evaluate. The underlying tool runs only when the verdict is
// .proceed; on .queueForApproval the action is enqueued to ApprovalQueue and a
// "pending" string is returned to the model; on .refuse the reason is returned.
// Nothing leaves the machine without a tap.
//
// House style: enum of statics (mirrors SlackTool / NotionTool / EmailTool), zero
// em/en dashes, dollars as $N. The classification is an explicit allowlist: a tool
// is classified by an entry in `classify`; anything NOT explicitly marked safe and
// NOT self-gating defaults to .bigIrreversible via DecisionGate's residual
// classifier, so a newly added side-effecting tool queues rather than slipping
// through. That is the fail-safe direction.

enum JaxToolGate {

    // The gate's decision for a single tool call. .proceed means run the tool now.
    // .shortCircuit carries the exact string dispatchTool should return to the
    // model WITHOUT running the tool (a "pending ..." or "refused ..." line).
    enum Outcome {
        case proceed
        case shortCircuit(String)
    }

    // Tools that gate themselves internally (they build their own ProposedAction
    // and call DecisionGate). Re-gating them here would double-queue, so the
    // universal gate lets them straight through to their own dispatch, which owns
    // the verdict. compose_email is the canonical example.
    static let selfGating: Set<String> = ["compose_email"]

    // MARK: - One-shot approval bypass
    //
    // When the user taps Approve in Jax HQ, ApprovalQueue re-dispatches the queued
    // action through dispatchTool so it actually runs. That re-dispatch must skip
    // the gate (the human already approved it) without opening a hole. The bypass
    // is a single armed UUID set ONLY by ApprovalQueue.approveAndExecute, for the
    // exact item being approved, and disarmed the instant that one dispatch
    // returns. A tool call is pre-approved only if it carries the matching
    // __approved_id in its input. The model never sees pending ids, the token is
    // single-use, and the window is one bracketed dispatch, so it cannot be forged.
    @MainActor private static var armedApproval: UUID?

    @MainActor static func arm(_ id: UUID) { armedApproval = id }
    @MainActor static func disarm() { armedApproval = nil }

    @MainActor static func isApproved(_ input: [String: Any]) -> Bool {
        guard let armed = armedApproval,
              let raw = input["__approved_id"] as? String,
              let id = UUID(uuidString: raw) else { return false }
        return id == armed
    }

    // Serialize a tool input dict so an approved item can be replayed faithfully.
    // Reserved bypass keys (anything __-prefixed) are stripped so a stored replay
    // never carries a stale token, and non-JSON values fail soft to nil (no replay
    // stored, approval still recorded, nothing performed: the safe direction).
    static func encodeInput(_ input: [String: Any]) -> String? {
        var clean: [String: Any] = [:]
        for (k, v) in input where !k.hasPrefix("__") { clean[k] = v }
        guard JSONSerialization.isValidJSONObject(clean),
              let data = try? JSONSerialization.data(withJSONObject: clean),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    // Evaluate one tool call against the universal gate. Returns .proceed when the
    // caller should run the underlying tool, or .shortCircuit(result) when the gate
    // has already resolved the call (queued for approval, or refused) and the caller
    // must NOT run the tool.
    @MainActor
    static func evaluate(name: String, input: [String: Any]) -> Outcome {
        // A re-dispatch of an already-approved item carries a one-shot token that
        // only ApprovalQueue could have armed, for this exact item. Let it run.
        if isApproved(input) { return .proceed }

        // Self-gating tools own their verdict. Do not second-guess them here.
        if selfGating.contains(name) { return .proceed }

        // Defense in depth for design_generate. The model-facing schema no longer
        // exposes a route (DesignTools hardcodes the api route), so a chat-invoked
        // generation is an ordinary ungated chat turn and legitimately sits on
        // safeReadOnlyTools below. But the api route is the ONLY safe one: the
        // subscriptionCLI/localModel routes spawn a local Claude Code subprocess
        // with bypassPermissions (whole-disk read incl. secrets, open network),
        // which is not read-only. If any future caller re-adds the route param or
        // forges the input with a non-api route, refuse to treat it as safe and
        // send it through the gate so DecisionGate queues it for the user's one-tap
        // approval. A missing or "api" route falls through to the safe path.
        if name == "design_generate" {
            let route = (input["route"] as? String)?.trimmingCharacters(in: .whitespaces)
            if let route, !route.isEmpty, route != "api" {
                let action = ProposedAction(
                    kind: .other,
                    summary: "Run a Claude Code subprocess for a design generation (route '\(route)').",
                    target: name,
                    detail: ["tool": name, "route": route]
                )
                return resolve(action: action, toolName: name, input: input)
            }
        }

        // Read-only / internal-reversible tools are explicitly safe and skip the
        // gate machinery entirely (no ProposedAction, no log noise). Everything
        // not on this list is treated as potentially side-effecting and is gated.
        if safeReadOnlyTools.contains(name) { return .proceed }

        guard let action = classify(name: name, input: input) else {
            // No classifier entry AND not on the safe list: treat as an unknown
            // side-effecting tool. Build a deliberately opaque action so the gate's
            // residual classifier falls to .bigIrreversible and queues it.
            let fallback = ProposedAction(
                kind: .other,
                summary: "Run tool '\(name)' (unclassified side effect).",
                target: name,
                detail: ["tool": name]
            )
            return resolve(action: fallback, toolName: name, input: input)
        }

        return resolve(action: action, toolName: name, input: input)
    }

    // Run the ProposedAction through DecisionGate and translate the verdict into an
    // Outcome. proceed runs the tool; queueForApproval enqueues + returns pending;
    // refuse returns the reason. Mirrors EmailTool's switch exactly.
    @MainActor
    private static func resolve(action: ProposedAction, toolName: String, input: [String: Any]) -> Outcome {
        let verdict = DecisionGate.shared.evaluate(action)
        switch verdict {
        case .proceed:
            return .proceed
        case .queueForApproval(var pending):
            // Stamp the replay coordinates so approving the card actually re-runs
            // this exact tool call through the gate's one-shot bypass.
            pending.action.detail["__replay_tool"] = toolName
            if let json = encodeInput(input) { pending.action.detail["__replay_input"] = json }
            ApprovalQueue.shared.enqueue(pending)
            WakeLog.shared.log("jax-gate: queued '\(toolName)' for approval (\(pending.reason))")
            let who = pending.persona == .none ? "" : " It would go out as \(pending.persona.displayName)."
            return .shortCircuit(
                "pending: '\(toolName)' is waiting in the Jax HQ approval queue for the user's one-tap approval.\(who) Nothing was sent or changed."
            )
        case .refuse(let reason):
            WakeLog.shared.log("jax-gate: refused '\(toolName)' (\(reason))")
            return .shortCircuit("refused: \(reason) Nothing was sent or changed.")
        }
    }

    // MARK: - Classification

    // Tools that are read-only or internal-and-reversible. These never leave the
    // machine and never move money, so they proceed without building an action.
    // This is the local-state surface of Grux: tasks, memory, reads, UI hints,
    // listing, planning. When in doubt a tool is LEFT OFF this list (so it gets
    // gated), never added speculatively.
    static let safeReadOnlyTools: Set<String> = [
        // task + action stack (local AppState, fully reversible)
        "add_task", "remove_task", "complete_task", "focus_on_task",
        "promote_action", "dismiss_action",
        "list_tasks", "list_proposed_actions",
        // memory + profile (local stores, fully reversible). capture_memory
        // appends to the local inbox (~/.grux/inbox.md + inbox.json) and
        // mark_memory_reviewed toggles a local flag - same safety class as
        // remember_fact. Leaving these OFF was the cause of the 2026-06-20
        // "Grux forgot the golf event" bug: a spoken "save this to my inbox"
        // got queued for approval and never written, so it was unrecallable.
        "remember_slang", "remember_fact",
        "capture_memory", "list_memories", "mark_memory_reviewed",
        // recall / search (read-only: local stores + the companion's vector index,
        // no side effects, nothing leaves as a comm). Without these, a spoken
        // "what did I say about X" gets parked in the approval queue and the
        // search never runs, so Grux answers "nothing came back from memory".
        "search_memory", "decision_log_query", "recall_thread_summary",
        // read-only context
        "get_current_activity", "read_workday_log", "list_inbox",
        "list_macros", "read_screen",
        // local media playback (controls Music.app / Chrome on THIS machine,
        // moves no money, sends no comms, leaks nothing - fully reversible by
        // pausing/closing). Without these, every spoken "play X" request gets
        // queued for approval and silently never plays.
        "play_music_track", "list_library_tracks", "play_on_youtube",
        // local UI affordances
        "grux_orb_hint", "grux_orb_stage", "set_mode",
        // channel listings are read-only (they do not send anything)
        "slack_list_channels", "notion_list_databases",
        // Design Studio (local-state surface: projects live under
        // ~/Documents/Grux/design, every mutation is version-snapshotted and
        // reversible, nothing is posted anywhere). design_generate is safe here
        // ONLY on the api route, where it spends API tokens exactly like an
        // ordinary ungated chat turn; that is the only route the model-facing
        // schema now exposes (DesignTools hardcodes it). The subscriptionCLI and
        // localModel routes spawn a local Claude Code subprocess with
        // bypassPermissions, which is NOT read-only, so the guard in evaluate()
        // above catches any non-api route and queues it before it reaches this
        // list. Without these entries, a spoken "mock up a landing page" parks
        // its FIRST read-only call in the approval queue and the Design Studio
        // never renders (observed live 2026-07-18: design_list_projects queued).
        "design_list_projects", "design_create_project", "design_generate",
        "design_open_project", "design_restore_version",
        "design_system_list", "design_system_activate",
        "design_system_generate_brand", "design_system_import"
    ]

    // Build a ProposedAction for the tools that need an explicit classification:
    // the comms and exfil surfaces. Returns nil for tools with no entry, which the
    // caller then routes through the fail-safe fallback.
    static func classify(name: String, input: [String: Any]) -> ProposedAction? {
        switch name {

        // MARK: Slack (Guardrails 2 + 4) ---------------------------------------
        // Posting to Slack is an outbound message to other people as the user. It must
        // carry a disclosure and may only go out through the gate. We mark it
        // externalComms with an external-looking target so sniffsExternalComms (and,
        // for the workday log, sniffsSecretLeak) fire.
        case "slack_send":
            let channel = (input["channel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let text = (input["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ProposedAction(
                kind: .externalComms,
                summary: "Post a Slack message to \(channel.isEmpty ? "a channel" : channel).",
                target: externalTarget(channel: channel, host: "slack.com"),
                brand: nil,
                isExternalComms: true,
                detail: ["channel": channel, "body": text, "subject": "Slack: \(channel)"]
            )

        case "slack_send_workday_log":
            // Worse than a plain message: it ships internal insights (shipped task
            // titles, commit counts, project names, productive minutes) to an
            // external channel. This is an outbound comm that must QUEUE for the user's
            // one-tap approval (the locked behavior), carrying the right disclosure,
            // before any internal data leaves the machine. externalComms => queue.
            let channel = (input["channel"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            return ProposedAction(
                kind: .externalComms,
                summary: "Post the workday log (shipped items, commit counts, project names, productive time) to Slack \(channel.isEmpty ? "channel" : channel).",
                target: externalTarget(channel: channel, host: "slack.com"),
                brand: nil,
                isExternalComms: true,
                detail: ["channel": channel, "subject": "Workday log to Slack",
                         "body": "workday log summary for the team: shipped items, commit counts, project names, productive time"]
            )

        // MARK: Notion (Guardrail 2) -------------------------------------------
        // Notion pushes ship arbitrary text, captured memories, and full workday
        // logs one-way to a third-party SaaS. That is exfiltration of insights and
        // internal data. Each push is an outbound action to an external host that
        // must QUEUE for the user's one-tap approval before any data leaves the machine.
        // Targeting an external Notion host makes sniffsExternalComms fire => queue.
        case "notion_push_memory":
            let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ProposedAction(
                kind: .externalComms,
                summary: "Push a captured memory to Notion (third-party): \(title.isEmpty ? "(untitled)" : title).",
                target: "https://notion.so",
                isExternalComms: true,
                detail: ["subject": "Notion push: memory",
                         "body": "memory / note exported to Notion: \(title)"]
            )

        case "notion_push_workday_log":
            let date = (input["date"] as? String ?? "today").trimmingCharacters(in: .whitespacesAndNewlines)
            return ProposedAction(
                kind: .externalComms,
                summary: "Push the \(date) workday log (shipped items, commits, insights) to Notion (third-party).",
                target: "https://notion.so",
                isExternalComms: true,
                detail: ["subject": "Notion push: workday log",
                         "body": "workday log exported to Notion: shipped items, commit counts, project names, insights"]
            )

        case "notion_sync_all_logs":
            // The most dangerous: one call backfills the ENTIRE workday-log history
            // (every shipped item across every brand) to an external destination.
            // Surface the volume on the approval card and queue a SINGLE approval.
            // WorkdayLogStore.list() and NotionSyncLedger are both non-isolated and
            // internally thread-safe, so this volume count is fine to read here.
            let pendingCount = WorkdayLogStore.list()
                .filter { !NotionSyncLedger.shared.isSynced(dayKey: $0.dayKey) }
                .count
            return ProposedAction(
                kind: .externalComms,
                summary: "Backfill \(pendingCount) workday log(s) to Notion (entire shipped history across every brand).",
                target: "https://notion.so",
                isExternalComms: true,
                detail: ["subject": "Notion bulk sync",
                         "body": "bulk export of \(pendingCount) workday logs (every shipped item across every brand) to Notion"]
            )

        default:
            return nil
        }
    }

    // MARK: - Helpers

    // An external-looking target string for a channel send, so DecisionGate's
    // isExternalTarget (which keys on "://", "@", or an http(s) prefix) treats it
    // as leaving the machine even when the raw channel is just a name like
    // "#general".
    private static func externalTarget(channel: String, host: String) -> String {
        let c = channel.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        return "https://\(host)/\(c)"
    }
}
