import Foundation

// Polls every enabled IMAP account, dedupes by Message-ID, persists new mail
// into MailStore, and routes support-brand mail through the existing
// EmailTriageEngine classify path (via `triageHook`, see below) so a fresh
// support email on any configured brand lands as a staged SupportDraft like the
// Outlook-scraping path stages them today. The webmail scraper remains the
// fallback for webmail-only setups; this engine is the persistent IMAP layer
// on top.
//
// Triage wiring: EmailTriageEngine's classify-and-draft path is private to
// that file, so instead of duplicating its brand prompts here, the engine
// exposes a static `triageHook` closure that integration code points at a
// tiny public wrapper on EmailTriageEngine (exact snippet in the item-8
// integration notes). When the hook is nil (pre-integration), sync still
// works fully; new mail just is not auto-drafted.
@MainActor
final class InboxSyncEngine: ObservableObject {
    static let shared = InboxSyncEngine()
    private init() {}

    @Published private(set) var syncing = false
    @Published private(set) var lastSummary = ""

    // Set once at startup by the EmailTriageEngine integration:
    //   InboxSyncEngine.triageHook = { inbox, msgs in
    //       await EmailTriageEngine.shared.triageFetched(inbox: inbox, messages: msgs)
    //   }
    // Returns the number of drafts staged.
    static var triageHook: (@MainActor (SupportInbox, [InboxMessage]) async -> Int)?

    // How many unseen messages a single sweep fetches per account (newest
    // first). Keeps a first sync of a busy inbox from pulling thousands.
    static let perAccountFetchCap = 25

    private var pollTimer: Timer?

    // MARK: - Polling

    // Idempotent. Called from MailboxView.onAppear; safe to call again with a
    // different interval (replaces the timer).
    func startPolling(interval: TimeInterval = 300) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                _ = await InboxSyncEngine.shared.syncAll()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Sync

    // Sweeps every enabled account. Returns a one-line human summary (also
    // published as `lastSummary` for the UI).
    @discardableResult
    func syncAll() async -> String {
        guard !syncing else { return "sync already running" }
        syncing = true
        defer { syncing = false }

        let accounts = EmailAccountStore.shared.enabledAccounts
        guard !accounts.isEmpty else {
            lastSummary = "no accounts configured"
            return lastSummary
        }

        var totalNew = 0
        var errors: [String] = []
        for account in accounts {
            do {
                let fresh = try await syncAccount(account)
                totalNew += fresh
                EmailAccountStore.shared.update(account.id) {
                    $0.lastSyncAt = Date()
                    $0.lastSyncError = nil
                }
            } catch {
                let msg = error.localizedDescription
                errors.append("\(account.emailAddress): \(msg)")
                EmailAccountStore.shared.update(account.id) {
                    $0.lastSyncError = msg
                }
                WakeLog.shared.log("inboxSync: \(account.emailAddress) failed: \(msg)")
            }
        }

        var parts = ["synced \(accounts.count) account(s), \(totalNew) new"]
        if !errors.isEmpty { parts.append("errors: \(errors.joined(separator: " | "))") }
        lastSummary = parts.joined(separator: ", ")
        WakeLog.shared.log("inboxSync: \(lastSummary)")
        return lastSummary
    }

    // Syncs one account: connect, login, SELECT INBOX, SEARCH UNSEEN, fetch
    // headers for unseen sequence numbers we have not stored yet, fetch
    // bodies for those, persist, and route the genuinely new support mail
    // through triage. Returns the number of new messages stored.
    @discardableResult
    func syncAccount(_ account: EmailAccount) async throws -> Int {
        let password = EmailAccountStore.shared.password(for: account)
        guard !password.isEmpty else {
            throw IMAPClient.IMAPError.loginFailed("no password stored for \(account.emailAddress); add it in Mailbox > Accounts")
        }

        let client = IMAPClient(host: account.imapHost, port: UInt16(account.imapPort), useTLS: account.useTLS)
        defer { Task { await client.close() } }

        try await client.connect()
        try await client.login(username: account.username, password: password)
        _ = try await client.select("INBOX")

        let unseen = try await client.searchUnseen()
        let targets = Array(unseen.suffix(Self.perAccountFetchCap)) // newest sequence numbers
        guard !targets.isEmpty else {
            await client.logout()
            return 0
        }

        let headers = try await client.fetchHeaders(sequenceNumbers: targets)

        // Build candidate messages; fetch bodies only for ones not yet stored
        // so re-sweeps of a stable unread pile cost one FETCH, not N.
        var batch: [EmailMessage] = []
        for header in headers {
            let id = EmailMessage.dedupeId(
                accountId: account.id,
                messageId: header.messageId,
                fromEmail: header.fromEmail,
                subject: header.subject,
                date: header.date
            )
            var body = ""
            if !MailStore.shared.contains(id: id) {
                body = (try? await client.fetchBodyText(sequenceNumber: header.sequenceNumber)) ?? ""
            }
            let snippet = String(body.replacingOccurrences(of: "\n", with: " ").prefix(160))
            batch.append(EmailMessage(
                id: id,
                accountId: account.id,
                sequenceNumber: header.sequenceNumber,
                messageId: header.messageId,
                fromName: header.fromName,
                fromEmail: header.fromEmail,
                to: header.to,
                subject: header.subject,
                date: header.date ?? Date(),
                snippet: snippet,
                bodyText: body,
                isUnread: header.isUnseen,
                fetchedAt: Date()
            ))
        }
        await client.logout()

        let fresh = MailStore.shared.upsert(batch)
        if !fresh.isEmpty {
            await routeThroughTriage(fresh, account: account)
        }
        return fresh.count
    }

    // MARK: - Triage routing

    // Sends new support-brand messages through the EmailTriageEngine classify
    // path (when wired) and records the deterministic draft id on each
    // message so the Mailbox UI can show the triage chip and jump to the
    // staged draft.
    private func routeThroughTriage(_ fresh: [EmailMessage], account: EmailAccount) async {
        guard let inbox = account.supportInbox, let hook = Self.triageHook else { return }
        let inboxMessages = fresh.map { msg in
            InboxMessage(
                fromName: msg.fromName,
                fromEmail: msg.fromEmail,
                subject: msg.subject,
                preview: msg.bodyText.isEmpty ? msg.snippet : String(msg.bodyText.prefix(1200)),
                messageId: msg.messageId
            )
        }
        let staged = await hook(inbox, inboxMessages)
        if staged > 0 {
            WakeLog.shared.log("inboxSync: routed \(staged) new message(s) through triage (\(inbox.rawValue))")
        }
        for (msg, im) in zip(fresh, inboxMessages) {
            MailStore.shared.update(msg.id) {
                $0.triageDraftId = EmailTriageEngine.draftId(inbox: inbox, msg: im)
            }
        }
    }

    // On-demand triage for a single message (the Draft reply button in
    // MailboxView). Returns the SupportDraft id when staged, nil otherwise.
    func draftReply(for message: EmailMessage) async -> String? {
        guard let account = EmailAccountStore.shared.account(id: message.accountId),
              let inbox = account.supportInbox else { return nil }
        guard let hook = Self.triageHook else {
            WakeLog.shared.log("inboxSync: draftReply requested but triageHook is not wired")
            return nil
        }
        let im = InboxMessage(
            fromName: message.fromName,
            fromEmail: message.fromEmail,
            subject: message.subject,
            preview: message.bodyText.isEmpty ? message.snippet : String(message.bodyText.prefix(1200)),
            messageId: message.messageId
        )
        _ = await hook(inbox, [im])
        let draftId = EmailTriageEngine.draftId(inbox: inbox, msg: im)
        MailStore.shared.update(message.id) { $0.triageDraftId = draftId }
        return draftId
    }
}
