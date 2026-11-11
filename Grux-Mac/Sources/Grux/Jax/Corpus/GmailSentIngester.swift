import Foundation

// Indexes the user's SENT Gmail (their real writing voice) via the existing
// IMAP path. The inbox is noisy (other people's words), so we focus exclusively
// on the Sent folder: every message there is the user writing as themselves.
//
// Account resolution: reuses EmailAccountStore. We look for a configured
// account whose address matches the configured owner address (see
// targetAddress below), then fall back to any Gmail-hosted account. If none is
// configured, we surface needsAccount rather than guessing credentials. The
// IMAP app password lives in ImapPasswordVault, set once when the user adds
// the account in Mail, Accounts.
//
// Gmail Sent folder is "[Gmail]/Sent Mail" on most accounts; we discover the
// real name via LIST and the \Sent special-use attribute fallback, so localized
// or IMAP-prefix variants still resolve.
actor GmailSentIngester: CorpusIngester {
    nonisolated let source: CorpusSource = .gmailSent

    private let rag: RAGClient
    private var ledger: CorpusLedger
    private let perRunCap = 400   // newest N sent messages per pass

    // Whose sent mail this indexes. EMPTY by default: this used to be one
    // person's hardcoded address, which made the ingester useless to anyone else
    // running Grux. Resolved env var first, then UserDefaults.
    // Unset simply means "no preferred address", and resolveAccount falls back
    // to any configured Gmail-hosted account.
    //   GRUX_CORPUS_GMAIL_ADDRESS=someone@gmail.com
    //   defaults write com.gruxai.grux grux.corpus.gmailAddress someone@gmail.com
    static let addressDefaultsKey = "grux.corpus.gmailAddress"
    static var targetAddress: String {
        if let env = ProcessInfo.processInfo.environment["GRUX_CORPUS_GMAIL_ADDRESS"], !env.isEmpty {
            return env
        }
        return UserDefaults.standard.string(forKey: addressDefaultsKey) ?? ""
    }

    init(rag: RAGClient) {
        self.rag = rag
        self.ledger = CorpusLedger.load(source: .gmailSent)
    }

    // Find the owner's Gmail account (configured address first, then any gmail host).
    @MainActor
    private func resolveAccount() -> EmailAccount? {
        let store = EmailAccountStore.shared
        let wanted = Self.targetAddress.lowercased()
        if !wanted.isEmpty,
           let exact = store.accounts.first(where: { $0.emailAddress.lowercased() == wanted }) {
            return exact
        }
        return store.accounts.first(where: { $0.imapHost.lowercased().contains("gmail") || $0.imapHost.lowercased().contains("imap.google") })
    }

    func probe() async -> CorpusPermission {
        let account = await resolveAccount()
        guard let account else { return Self.permission(hasAccount: false, password: .missing) }
        let read = await MainActor.run { EmailAccountStore.shared.passwordRead(for: account) }
        return Self.permission(hasAccount: true, password: read)
    }

    /// No account and an account with no password are two things to do, and the
    /// second is listed in Mail already (wave 75 round 1). A Keychain that would
    /// not answer is neither (rounds 2 and 3): the password may be there, so it
    /// is its own state and names the Keychain.
    static func permission(hasAccount: Bool, password: ImapPasswordVault.PasswordRead) -> CorpusPermission {
        guard hasAccount else { return .needsAccount }
        switch password {
        case .found: return .ready
        case .missing: return .needsPassword
        case .unreadable: return .needsKeychain
        }
    }

    /// Opens the note of a read Gmail refused the password for, which Jax Command
    /// reads to keep naming the fix after a probe that only sees a stored password.
    static let refusedPrefix = "Gmail refused the password: "
    static func refusedLogin(_ note: String) -> Bool { note.hasPrefix(refusedPrefix) }

    /// What a read that failed while connecting or logging in reports: a failed
    /// read of an account that is set up, never a missing account (wave 66 round
    /// 2). Only the server refusing the login is a password to fix (round 3); a
    /// network down or a timeout is not.
    static func readFailure(_ error: Error, duringLogin: Bool) -> CorpusRunResult {
        let refused: Bool
        if duringLogin, case IMAPClient.IMAPError.loginFailed = error { refused = true } else { refused = false }
        return CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown,
                               note: (refused ? refusedPrefix : "Gmail could not be read: ") + error.localizedDescription)
    }

    func ingest() async -> CorpusRunResult {
        guard let account = await resolveAccount() else {
            return .blocked(.needsAccount)
        }
        let read = await MainActor.run { EmailAccountStore.shared.passwordRead(for: account) }
        guard case .found(let password) = read else {
            return .blocked(Self.permission(hasAccount: true, password: read))
        }

        let client = IMAPClient(host: account.imapHost, port: UInt16(account.imapPort), useTLS: account.useTLS)
        defer { Task { await client.close() } }

        do {
            try await client.connect()
        } catch {
            return Self.readFailure(error, duringLogin: false)
        }
        do {
            try await client.login(username: account.username, password: password)
        } catch {
            return Self.readFailure(error, duringLogin: true)
        }

        guard let sentMailbox = await discoverSentMailbox(client: client) else {
            await client.logout()
            return CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .noData,
                                   note: "Could not locate the Gmail Sent folder")
        }

        do {
            let total = try await client.select(sentMailbox)
            guard total > 0 else {
                await client.logout()
                return CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .noData, note: "Sent folder empty")
            }
            // Newest sequence numbers are the highest; take the last perRunCap.
            let lo = max(1, total - perRunCap + 1)
            let seqs = Array(lo...total)
            let headers = try await client.fetchHeaders(sequenceNumbers: seqs)

            var indexed = 0, skipped = 0
            var docs: [RAGClient.Document] = []
            for header in headers {
                let key = header.messageId.isEmpty
                    ? CorpusIndexer.stableHash("\(header.subject)|\(header.date?.timeIntervalSince1970 ?? 0)")
                    : header.messageId
                guard ledger.insert(key) else { skipped += 1; continue }

                let body = (try? await client.fetchBodyText(sequenceNumber: header.sequenceNumber)) ?? ""
                let cleaned = Self.cleanSentBody(body)
                let composed = cleaned.isEmpty ? header.subject : "Subject: \(header.subject)\n\n\(cleaned)"
                guard composed.trimmingCharacters(in: .whitespacesAndNewlines).count >= 12 else { skipped += 1; continue }

                let ts = header.date.map { Int($0.timeIntervalSince1970 * 1000) }
                await MainActor.run {
                    CorpusIndexer.indexLocal(source: .gmailSent, text: composed, timestampMillis: ts,
                                             extraMetadata: ["subject": String(header.subject.prefix(120))])
                }
                docs.append(RAGClient.Document(
                    id: CorpusIndexer.docId(source: .gmailSent, key: key),
                    source: "email",
                    text: composed,
                    ts: ts.map { $0 / 1000 },
                    brandHint: ""
                ))
                indexed += 1
            }
            await client.logout()

            let pushed = await CorpusIndexer.pushToRAG(rag, source: .gmailSent, docs: docs)
            ledger.save(source: .gmailSent)
            return CorpusRunResult(indexed: indexed, pushedToRAG: pushed, skipped: skipped, permission: .ready,
                                   note: "Indexed \(indexed) sent emails (\(skipped) already seen)")
        } catch {
            await client.logout()
            // Not .ready: a read that failed partway is not one that found nothing
            // (wave 63). The card shows this note as the row's reason.
            return CorpusRunResult(indexed: 0, pushedToRAG: 0, skipped: 0, permission: .unknown,
                                   note: "Sent sync error: \(error.localizedDescription)")
        }
    }

    // Resolve the real Sent mailbox name. Gmail exposes "[Gmail]/Sent Mail";
    // other servers use "Sent" or "Sent Items". Match by common names.
    private func discoverSentMailbox(client: IMAPClient) async -> String? {
        guard let boxes = try? await client.listMailboxes() else { return "[Gmail]/Sent Mail" }
        let wanted = ["[gmail]/sent mail", "sent mail", "sent items", "sent"]
        for w in wanted {
            if let hit = boxes.first(where: { $0.lowercased() == w }) { return hit }
        }
        // Substring fallback (e.g. "[Google Mail]/Sent Mail").
        return boxes.first(where: { $0.lowercased().contains("sent") })
    }

    // Strip quoted reply chains and signatures so the corpus captures the user's
    // fresh prose, not the email he replied to. Keeps everything above the first
    // quote marker / "On ... wrote:" line.
    static func cleanSentBody(_ raw: String) -> String {
        var lines: [String] = []
        for line in raw.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { break }
            if t.range(of: #"^On .+wrote:$"#, options: .regularExpression) != nil { break }
            if t == "--" { break }                       // signature delimiter
            if t.hasPrefix("From:") && lines.count > 2 { break } // forwarded header block
            lines.append(line)
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
