import Foundation
import GruxMCPCore

// MARK: - grux_approvals

/// One handler, one file.
///
/// The tool DEFINITION and its `switch` case live in `GruxControlSocket.swift`, which every
/// tool shares, and the BODY lives here, which nothing else touches. That split is not
/// tidiness: it is what let thirteen of these be written at once without any two of them
/// racing on the same two hundred lines.
///
/// ## The read here and the read in the CLI are deliberately different
///
/// `grux approvals` reads `~/.grux/jax/autonomy.json` and `~/.grux/jax/approvals.json` off
/// disk, so it answers with the app closed. This handler reads the live stores instead,
/// because it only ever runs inside the app and the in-memory queue is the copy the writes
/// below mutate. They agree because `ApprovalQueue` rewrites its file on every change.

/// What looking up one queue item can come back with.
///
/// The three refusals differ in what they ask of the caller: a missing id is a bad call, an
/// unknown id is a stale one, and an already answered id is neither. Collapsing them into a
/// single "not found" would send an agent to re-read the queue when the queue was right.
private enum ApprovalsHit {
    case found(PendingApproval)
    case refused([String: Any])
}

extension GruxControlTools {

    static func approvals(action: String?, mode: String?, id: String?) -> [String: Any] {
        switch (action ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "":
            return approvalsRead()
        case "mode":
            return approvalsSetMode(mode)
        case "approve":
            return approvalsApprove(id)
        case "skip":
            return approvalsSkip(id)
        case let other:
            return MCPWire.textFailure(
                "grux_approvals reads both halves when it is called with no action, and "
                + "otherwise takes mode, approve or skip. It does not take \(other).")
        }
    }

    // MARK: - Read

    /// Both halves in one reply: what the agent may do without asking, and what is waiting.
    ///
    /// THE LIST IS CAPPED AND THE COUNT IS NOT. This queue holds 928 waiting items on the
    /// machine this was written against, and a reply carrying all of them is one JSON line of
    /// roughly 780 KB down a socket whose reader looks for a newline. `showing` beside
    /// `pending` is what keeps the cap from reading as the whole truth.
    private static func approvalsRead(limit: Int = 20) -> [String: Any] {
        let queue = ApprovalQueue.shared
        let waiting = queue.pending.sorted { $0.createdAt < $1.createdAt }
        let shown = Array(waiting.prefix(limit))
        let stamp = ISO8601DateFormatter()
        let rows: [[String: Any]] = shown.map { approvalsRow($0, stamp: stamp) }

        return MCPWire.textResult(jsonText([
            "mode": AutonomyController.shared.mode.rawValue,
            "modes": AutonomyMode.allCases.map(\.rawValue),
            "killed": AutonomyController.shared.killed,
            "pending": waiting.count,
            "total": queue.items.count,
            "showing": shown.count,
            "items": rows,
        ]))
    }

    /// One item, oldest first, with the flags that say why it is not routine.
    private static func approvalsRow(_ item: PendingApproval,
                                     stamp: ISO8601DateFormatter) -> [String: Any] {
        var row: [String: Any] = [
            "id": item.id.uuidString,
            "summary": item.summary,
            "target": item.action.target,
            "created_at": stamp.string(from: item.createdAt),
            "urgent": item.urgent,
            "reason": item.reason,
        ]
        // The tool it would replay, when it has one. An item with no replay coordinates is
        // approvable and performs nothing, which the caller has to be able to tell apart from
        // one that starts a subprocess.
        if let tool = item.action.detail["__replay_tool"], !tool.isEmpty { row["runs"] = tool }

        var why: [String] = []
        if item.action.isSpend { why.append("spends money") }
        if item.action.isExternalComms { why.append("goes to another person") }
        if item.action.isPublicPost { why.append("posts in public") }
        if item.action.touchesSecrets { why.append("touches a credential") }
        if !why.isEmpty { row["not_routine_because"] = why }
        if item.persona != .none { row["would_go_out_as"] = item.persona.displayName }
        return row
    }

    // MARK: - Write: the mode

    private static func approvalsSetMode(_ raw: String?) -> [String: Any] {
        let names = AutonomyMode.allCases.map(\.rawValue).joined(separator: ", ")
        let wanted = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !wanted.isEmpty else {
            return MCPWire.textFailure("Changing the mode needs one to change it to. "
                + "The modes are \(names).")
        }
        guard let mode = AutonomyMode(rawValue: wanted) else {
            return MCPWire.textFailure("There is no mode called \(wanted). "
                + "The modes are \(names).")
        }

        AutonomyController.shared.setMode(mode)

        // The pending count comes back with it because the mode does NOT touch the queue.
        // Anything already waiting stays waiting in every mode, and a reply that mentioned
        // only the new mode would let a caller conclude otherwise.
        return MCPWire.textResult(jsonText([
            "mode": mode.rawValue,
            "killed": AutonomyController.shared.killed,
            "pending": ApprovalQueue.shared.pendingCount,
        ]))
    }

    // MARK: - Write: approve one, which runs something

    private static func approvalsApprove(_ raw: String?) -> [String: Any] {
        let item: PendingApproval
        switch approvalsFind(raw, verb: "Approving") {
        case .refused(let reply): return reply
        case .found(let hit): item = hit
        }

        let tool = item.action.detail["__replay_tool"] ?? ""

        // THE REPLY CANNOT CARRY THE RESULT, and pretending otherwise would be the lie.
        //
        // `ApprovalQueue.approveAndExecute` is async and this handler is not: the dispatch
        // table in GruxControlSocket calls `approvals(...)` without `await`, so the signature
        // is fixed. Blocking on it here is not available either, because it is main actor
        // work and this call already holds the main actor, so a semaphore would deadlock the
        // whole app rather than just this command.
        //
        // So it is started and answered for immediately, exactly as grux_request_permission
        // raises a permission dialog and answers before it is dismissed. The outcome stays
        // observable rather than lost: approveAndExecute puts a FAILED item back to pending,
        // so reading the queue again is a real check and not a consolation.
        Task { @MainActor in
            await ApprovalQueue.shared.approveAndExecute(item.id)
        }

        var out: [String: Any] = [
            "id": item.id.uuidString,
            "summary": item.summary,
            "runs": tool,
            "started": true,
            // The check is honest about being a CHECK. approveAndExecute returns an item to
            // pending when the tool answers with error, refused or busy, which is a real
            // signal and not a guarantee: a tool that fails in some other wording stays
            // marked approved, so this says "caught it failing" rather than "it failed".
            "how_to_check": "read grux_approvals again: the item has left the queue if it "
                + "went through, and is back to waiting if Grux caught it failing",
        ]
        if tool.isEmpty {
            out["how_to_check"] = "nothing was performed, so the item simply leaves the queue"
        }
        return MCPWire.textResult(jsonText(out))
    }

    // MARK: - Write: refuse one

    private static func approvalsSkip(_ raw: String?) -> [String: Any] {
        let item: PendingApproval
        switch approvalsFind(raw, verb: "Refusing") {
        case .refused(let reply): return reply
        case .found(let hit): item = hit
        }

        ApprovalQueue.shared.skip(item.id)

        // The count is recomputed AFTER the skip so it is the count the caller can now go and
        // verify, rather than the one from a moment before the change.
        return MCPWire.textResult(jsonText([
            "id": item.id.uuidString,
            "summary": item.summary,
            "skipped": true,
            "pending": ApprovalQueue.shared.pendingCount,
        ]))
    }

    // MARK: - Finding one

    /// One WAITING item by id, or the refusal to send back instead.
    ///
    /// The id must be complete here. The CLI accepts a prefix and resolves it against the
    /// same file before it ever calls this, which is the right place for that convenience:
    /// an ambiguous prefix has to be shown to a person, and the socket is where a decision
    /// gets executed rather than where it gets made.
    private static func approvalsFind(_ raw: String?, verb: String) -> ApprovalsHit {
        let wanted = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else {
            return .refused(MCPWire.textFailure("\(verb) needs the id of one waiting item. "
                + "Call grux_approvals with no action to see what is waiting."))
        }
        guard let uuid = UUID(uuidString: wanted),
              let item = ApprovalQueue.shared.items.first(where: { $0.id == uuid }) else {
            return .refused(MCPWire.textFailure("Nothing in the queue has the id \(wanted). "
                + "Call grux_approvals with no action to see what is waiting."))
        }
        guard item.state == .pending else {
            // NOT AN ERROR IN THE CALLER, and it does not want a retry. The item was already
            // answered, by this queue's own rule that an answer is final.
            return .refused(MCPWire.textFailure("That one was already answered, so nothing "
                + "was run and nothing changed. Only a waiting item can be approved or "
                + "refused."))
        }
        return .found(item)
    }
}
