import Foundation

// Claude-tool adapter for the IMAP mailbox layer. Registered by
// ChatService.allTools() and dispatched by ChatService.dispatchTool()
// (integration snippets in the item-8 notes; mirrors FolderTool's shape).
//
// Two tools:
//   list_inbox    - read-only view over MailStore (per-account, unread,
//                   search, limit). Never touches the network; the sync
//                   engine keeps the store fresh.
//   compose_email - sends a new email through ResendClient from one of the
//                   configured accounts' verified-domain From addresses.
enum EmailTool {

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "list_inbox",
                description: "List the user's synced email inbox (multi-account IMAP). Returns sender, subject, date, unread state, account, and a snippet per message, newest first. Use when they ask 'any new email', 'what's in my inbox', 'did X write back', 'unread mail'. Read-only and instant (reads the local synced store; the IMAP sync engine refreshes it on a timer and via the Mailbox tab).",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "account": ["type": "string", "description": "Optional account filter: address, display name, or host substring ('work', 'support', 'gmail'). Omit for all accounts."],
                        "unread_only": ["type": "boolean", "description": "Only unread messages. Default false."],
                        "search": ["type": "string", "description": "Optional fuzzy filter against sender, subject, and snippet."],
                        "limit": ["type": "integer", "description": "Max rows. Default 15, max 50."]
                    ]
                ]
            ),
            ClaudeTool(
                name: "compose_email",
                description: "Compose and SEND an email as the user (or one of their brands) via the verified Resend sender of a configured account. This routes through the assistant decision gate: an external send is queued for their one-tap approval in Jax HQ (the gate applies the assistant-for-business / user-for-personal disclosure), so it does not always go out instantly. Still only call it when they actually want an email sent and the recipient, subject, and body are settled. If anything is uncertain, read the draft back to them first. Plain text only. Never use em dashes or en dashes; write dollar amounts as $N.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "from_account": ["type": "string", "description": "Which account to send as: address, display name, or substring ('work', 'support'). Omitted = the first configured account."],
                        "to": ["type": "string", "description": "Recipient address(es), comma-separated."],
                        "subject": ["type": "string", "description": "Subject line."],
                        "body": ["type": "string", "description": "Plain-text body, ready to send, signed appropriately."]
                    ],
                    "required": ["to", "subject", "body"]
                ]
            )
        ]
    }

    static let toolNames: Set<String> = ["list_inbox", "compose_email"]

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "list_inbox":
            return await MainActor.run { listInbox(input) }

        case "compose_email":
            return await composeEmail(input)

        default:
            return "error: unknown email tool '\(name)'"
        }
    }

    // MARK: - list_inbox

    @MainActor
    private static func listInbox(_ input: [String: Any]) -> String {
        let accounts = EmailAccountStore.shared.accounts
        guard !accounts.isEmpty else {
            return "(no email accounts configured yet; add one in the Mailbox tab)"
        }

        var accountFilter: UUID?
        if let hint = input["account"] as? String, !hint.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let account = EmailAccountStore.shared.resolve(hint) else {
                let known = accounts.map { $0.emailAddress }.joined(separator: ", ")
                return "error: no account matched '\(hint)'. Configured: \(known)"
            }
            accountFilter = account.id
        }

        let unreadOnly = (input["unread_only"] as? Bool) ?? false
        let search = ((input["search"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max((input["limit"] as? Int) ?? 15, 1), 50)

        var rows = MailStore.shared.messages(for: accountFilter)
        if unreadOnly { rows = rows.filter { $0.isUnread } }
        if !search.isEmpty {
            rows = rows.filter {
                ChatService.fuzzyMatches("\($0.fromName) \($0.fromEmail) \($0.subject) \($0.snippet)", query: search)
            }
        }
        guard !rows.isEmpty else {
            return "(inbox is empty for that filter; last sync: \(InboxSyncEngine.shared.lastSummary.isEmpty ? "never" : InboxSyncEngine.shared.lastSummary))"
        }

        let df = DateFormatter()
        df.dateFormat = "MMM d HH:mm"
        df.timeZone = .current

        var lines: [String] = []
        for msg in rows.prefix(limit) {
            let accountLabel = accounts.first(where: { $0.id == msg.accountId })?.displayName ?? "?"
            let unread = msg.isUnread ? "UNREAD " : ""
            let from = msg.fromName.isEmpty ? msg.fromEmail : "\(msg.fromName) <\(msg.fromEmail)>"
            var line = "- [\(accountLabel)] \(unread)\(df.string(from: msg.date)) | \(from) | \(msg.subject)"
            if !msg.snippet.isEmpty { line += "\n  \(msg.snippet)" }
            if msg.triageDraftId != nil { line += "\n  (reply already drafted in Support Drafts)" }
            lines.append(line)
        }
        let unreadTotal = MailStore.shared.unreadCount(for: accountFilter)
        lines.append("(\(rows.count) message(s) matched, \(unreadTotal) unread)")
        return lines.joined(separator: "\n")
    }

    // MARK: - compose_email

    private static func composeEmail(_ input: [String: Any]) async -> String {
        // Resolve approval status ONCE, synchronously, before any await, so a
        // later mutation of the shared armed token cannot flip it mid-flight.
        let preApproved = await MainActor.run { JaxToolGate.isApproved(input) }

        let toRaw = ((input["to"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = ((input["subject"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = ((input["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let recipients = toRaw
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
        guard !recipients.isEmpty else { return "error: no valid recipient address in '\(toRaw)'" }
        guard !subject.isEmpty else { return "error: empty subject" }
        guard !body.isEmpty else { return "error: empty body" }

        let fromHint = ((input["from_account"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let account: EmailAccount? = await MainActor.run {
            if !fromHint.isEmpty { return EmailAccountStore.shared.resolve(fromHint) }
            return EmailAccountStore.shared.accounts.first
        }
        guard let account else {
            if fromHint.isEmpty {
                return "error: no email accounts configured; add one in the Mailbox tab"
            }
            let known = await MainActor.run { EmailAccountStore.shared.accounts.map { $0.emailAddress }.joined(separator: ", ") }
            return "error: no account matched '\(fromHint)'. Configured: \(known)"
        }

        // Item 31: optional Touch ID gate on outbound sends. Fail closed:
        // when the policy requires authorization and it is refused or
        // unavailable, the email does NOT go out.
        // A re-dispatch from an approved Jax HQ card carries the one-shot bypass
        // token: the user already tapped Approve, so the Touch ID gate and the decision
        // gate were both satisfied when the card was created. Skip re-prompting and
        // send the sanctioned email directly. preApproved was captured once at the
        // top of this function, before any await, so it cannot flip mid-flight.
        let gateReason = "send email to \(recipients.joined(separator: ", ")) as \(account.fromAddress)"
        if !preApproved {
            guard await SensitiveActionGate.shared.authorize(.emailSend, reason: gateReason) else {
                return "error: blocked, Touch ID authorization refused for sending email"
            }
        }

        // --- Jax send-gate + disclosure (replaces the old direct ResendClient().send block) ---
        // Layer the Jax disclosure (assistant for business, the user for personal) and route
        // the send through the universal decision gate. Nothing leaves the machine
        // unless the gate returns .proceed (or the send was already approved).
        let brandHint = fromHint.isEmpty ? account.displayName : fromHint

        let prepared = CommsPersona.shared.prepareSend(
            recipients: recipients,
            subject: subject,
            body: body,
            brandHint: brandHint
        )

        // Pre-approved replay: the gate already ran when this was queued. Send now.
        let verdict: GateVerdict = preApproved ? .proceed
            : await MainActor.run { DecisionGate.shared.evaluate(prepared.proposed) }
        switch verdict {
        case .proceed:
            // Persona owns the From identity + signed body; the disclosed mailbox
            // (assistant/brand or the user) is the reply-to so replies land correctly.
            do {
                let result = try await ResendClient().send(
                    from: prepared.identity.fromAddress,
                    to: prepared.recipients,
                    subject: prepared.subject,
                    text: prepared.body,
                    listUnsubscribe: nil,
                    replyTo: prepared.identity.replyTo
                )
                return "ok: sent as \(prepared.identity.fromName) <\(prepared.identity.replyTo)> to \(prepared.recipients.joined(separator: ", ")) (\(prepared.context.rawValue) disclosure, resend id \(result.id))"
            } catch {
                return "error: send failed: \(error.localizedDescription)"
            }
        case .queueForApproval(var pending):
            // Stamp the replay coordinates so a one-tap approve re-runs this exact
            // compose_email call (with the original recipients, subject, body) and
            // actually sends it.
            pending.action.detail["__replay_tool"] = "compose_email"
            if let json = JaxToolGate.encodeInput(input) { pending.action.detail["__replay_input"] = json }
            await MainActor.run { ApprovalQueue.shared.enqueue(pending) }
            return "pending: this email is waiting in the Jax HQ approval queue for the user's one-tap approval (would send as \(prepared.identity.fromName) to \(prepared.recipients.joined(separator: ", "))). Nothing has been sent."
        case .refuse(let reason):
            return "refused: \(reason). Nothing has been sent."
        }
    }
}
