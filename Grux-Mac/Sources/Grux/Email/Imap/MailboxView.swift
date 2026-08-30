import SwiftUI

// The Mailbox tab: multi-account IMAP inbox with unread badges, message
// detail, triage chips, and a draft-reply button that rides the existing
// support-triage pipeline (staged drafts open in Support Drafts; nothing
// sends without an explicit tap). Compose goes out through ResendClient using the
// account's verified-domain From address.
//
// Styling follows GruxTheme tokens and the tight-control rule: small
// type, GruxChip pills for actions, lean inputs.
struct MailboxView: View {
    @ObservedObject private var mailStore = MailStore.shared
    @ObservedObject private var accountStore = EmailAccountStore.shared
    @ObservedObject private var syncEngine = InboxSyncEngine.shared
    @ObservedObject private var draftStore = SupportDraftStore.shared
    @ObservedObject private var brand = BrandFilter.shared

    @State private var selectedAccountId: UUID?   // nil = all accounts
    @State private var selectedMessageId: String?
    @State private var unreadOnly = false
    @State private var showCompose = false
    @State private var showAccounts = false
    @State private var draftingMessageId: String?

    private var visibleMessages: [EmailMessage] {
        var rows = mailStore.messages(for: selectedAccountId)
        if unreadOnly { rows = rows.filter { $0.isUnread } }
        // App-wide brand filter (decision 3): under a specific brand, keep only
        // mail whose account maps to that brand; drop unbranded accounts. "All"
        // is a no-op.
        if brand.scope != .all {
            rows = rows.filter { msg in
                guard let v = accountStore.account(id: msg.accountId)?.brandVoice else { return false }
                return brand.scope.matches(voice: v)
            }
        }
        return rows
    }

    private var selectedMessage: EmailMessage? {
        guard let id = selectedMessageId else { return nil }
        return mailStore.messages.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            if accountStore.accounts.isEmpty {
                emptyState
            } else {
                BrandFilterBar(trailing: brand.scope == .all ? nil : "\(visibleMessages.count) shown")
                    .padding(.horizontal, GruxSpacing.s)
                    .padding(.vertical, GruxSpacing.xs)
                GruxListDetailScaffold(listWidth: 330) {
                    messageList
                } detail: {
                    detailPane
                }
            }
        }
        .background(GruxTheme.base)
        .onAppear {
            InboxSyncEngine.shared.startPolling()
            if !accountStore.accounts.isEmpty && mailStore.messages.isEmpty {
                Task { await InboxSyncEngine.shared.syncAll() }
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeEmailSheet()
        }
        .sheet(isPresented: $showAccounts) {
            MailAccountsSheet()
        }
    }

    // MARK: - Header

    private var header: some View {
        GruxToolbar("Mailbox") {
            if mailStore.unreadCount() > 0 {
                Text("\(mailStore.unreadCount())")
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(.white)
                    .padding(.horizontal, GruxSpacing.s - 1).padding(.vertical, GruxSpacing.xs - 1)
                    .background(Capsule().fill(GruxTheme.accentPrimary))
            }

            Picker("", selection: $selectedAccountId) {
                Text("All accounts").tag(UUID?.none)
                ForEach(accountStore.accounts) { account in
                    Text(accountLabel(account)).tag(UUID?.some(account.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 240)

            Toggle("Unread", isOn: $unreadOnly)
                .toggleStyle(.checkbox)
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)

            Spacer()

            if syncEngine.syncing {
                ProgressView().controlSize(.small)
            } else if !syncEngine.lastSummary.isEmpty {
                Text(syncEngine.lastSummary)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .lineLimit(1)
            }

            GruxChip(title: "Sync", systemImage: "arrow.triangle.2.circlepath", style: .secondary) {
                Task { await InboxSyncEngine.shared.syncAll() }
            }
            GruxChip(title: "Compose", systemImage: "square.and.pencil", style: .primary) {
                showCompose = true
            }
            GruxChip(title: "Accounts", systemImage: "person.crop.circle.badge.plus", style: .secondary) {
                showAccounts = true
            }
        }
    }

    private func accountLabel(_ account: EmailAccount) -> String {
        let unread = mailStore.unreadCount(for: account.id)
        return unread > 0 ? "\(account.displayName) (\(unread))" : account.displayName
    }

    // MARK: - Empty state

    private var emptyState: some View {
        GruxEmptyState(
            icon: "envelope",
            line: "No email accounts yet",
            detail: "Add an IMAP account (use an app password for Gmail and Fastmail; M365 needs basic auth or an app password). Passwords go straight into the login keychain.",
            ctaTitle: "Add account",
            ctaAction: { showAccounts = true },
            voiceHint: "Grux, check my email"
        )
    }

    // MARK: - Message list

    private var messageList: some View {
        ScrollView {
            LazyVStack(spacing: GruxSpacing.xs - 2) {
                if visibleMessages.isEmpty {
                    Text(unreadOnly ? "No unread mail" : "No messages synced yet")
                        .font(GruxTheme.Font.body)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.top, GruxSpacing.xl)
                } else {
                    ForEach(visibleMessages) { msg in
                        messageRow(msg)
                    }
                }
            }
            .padding(GruxSpacing.s)
        }
    }

    private func messageRow(_ msg: EmailMessage) -> some View {
        let isSelected = msg.id == selectedMessageId
        return Button {
            selectedMessageId = msg.id
            if msg.isUnread { mailStore.markRead(msg.id) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: GruxSpacing.s - 2) {
                    if msg.isUnread {
                        Circle().fill(GruxTheme.accentPrimary).frame(width: 7, height: 7)
                    }
                    Text(msg.fromName.isEmpty ? msg.fromEmail : msg.fromName)
                        .font(GruxTheme.Font.body.weight(msg.isUnread ? .bold : .medium))
                        .foregroundStyle(GruxTheme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(Self.shortDate(msg.date))
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                Text(msg.subject)
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .lineLimit(1)
                HStack(spacing: GruxSpacing.s - 2) {
                    Text(msg.snippet)
                        .font(GruxTheme.Font.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .lineLimit(1)
                    Spacer()
                    triageChip(for: msg)
                }
            }
            .padding(.horizontal, GruxSpacing.m - 2)
            .padding(.vertical, GruxSpacing.s - 1)
            .background(
                RoundedRectangle(cornerRadius: GruxTheme.Radius.chip, style: .continuous)
                    .fill(isSelected ? GruxTheme.accentPrimary.opacity(0.16) : Color.white.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func triageChip(for msg: EmailMessage) -> some View {
        if let draftId = msg.triageDraftId,
           let draft = draftStore.drafts.first(where: { $0.id == draftId }) {
            Text(draft.status == .sent ? "REPLIED" : draft.category.label.uppercased())
                .font(GruxTheme.Font.microCaps)
                .kerning(0.8)
                .foregroundStyle(draft.status == .sent ? GruxTheme.successMint : GruxTheme.accentCo)
                .padding(.horizontal, GruxSpacing.s - 2).padding(.vertical, GruxSpacing.xs - 2)
                .background(
                    Capsule().stroke(
                        (draft.status == .sent ? GruxTheme.successMint : GruxTheme.accentCo).opacity(0.5),
                        lineWidth: 0.8
                    )
                )
        }
    }

    // MARK: - Detail

    private var detailPane: some View {
        Group {
            if let msg = selectedMessage {
                VStack(alignment: .leading, spacing: 0) {
                    detailHeader(msg)
                    Divider().opacity(0.3)
                    ScrollView {
                        Text(msg.bodyText.isEmpty ? msg.snippet : msg.bodyText)
                            .font(.system(size: 13))
                            .foregroundStyle(GruxTheme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(GruxSpacing.l)
                    }
                }
            } else {
                GruxEmptyState(
                    icon: "envelope.open",
                    line: "Select a message"
                )
            }
        }
    }

    private func detailHeader(_ msg: EmailMessage) -> some View {
        let account = accountStore.account(id: msg.accountId)
        let canTriage = account?.supportInbox != nil && InboxSyncEngine.triageHook != nil
        let hasDraft = msg.triageDraftId != nil
            && draftStore.drafts.contains(where: { $0.id == msg.triageDraftId })

        return VStack(alignment: .leading, spacing: GruxSpacing.s - 2) {
            Text(msg.subject)
                .font(GruxTheme.Font.title)
                .foregroundStyle(GruxTheme.textPrimary)
            HStack(spacing: GruxSpacing.s) {
                Text("\(msg.fromName.isEmpty ? "" : msg.fromName + " ")<\(msg.fromEmail)>")
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textSecondary)
                Text(Self.longDate(msg.date))
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                if let account {
                    Text(account.displayName)
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.horizontal, GruxSpacing.s - 2).padding(.vertical, GruxSpacing.xs - 2)
                        .background(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.8))
                }
                Spacer()
                Menu("Hide sender") {
                    Button("Hide this address (\(msg.fromEmail))") {
                        EmailTriageEngine.shared.hideSenderEmail(msg.fromEmail)
                    }
                    if let dom = SenderSuppressionStore.domain(of: msg.fromEmail) {
                        Button("Hide @\(dom)") {
                            EmailTriageEngine.shared.hideSenderDomain(dom)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textTertiary)
                if hasDraft {
                    GruxChip(title: "Open draft", systemImage: "tray.full", style: .success) {
                        WindowOpener.openSupportDrafts()
                    }
                } else if canTriage {
                    if draftingMessageId == msg.id {
                        ProgressView().controlSize(.small)
                    } else {
                        GruxChip(title: "Draft reply", systemImage: "arrowshape.turn.up.left", style: .primary) {
                            draftingMessageId = msg.id
                            Task {
                                _ = await InboxSyncEngine.shared.draftReply(for: msg)
                                draftingMessageId = nil
                                WindowOpener.openSupportDrafts()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, GruxSpacing.m)
        .padding(.vertical, GruxSpacing.s)
    }

    // MARK: - Date formatting

    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "MMM d"
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }

    private static func longDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d yyyy HH:mm"
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }
}

// MARK: - Compose sheet

// Sends through ResendClient with the selected account's verified From
// address. Plain text, DashSanitizer scrubs dashes at the client layer.
private struct ComposeEmailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var accountStore = EmailAccountStore.shared

    @State private var fromAccountId: UUID?
    @State private var to = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var sending = false
    @State private var errorText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m - 2) {
            Text("Compose")
                .font(GruxTheme.Font.title)
                .foregroundStyle(GruxTheme.textPrimary)

            Picker("From", selection: $fromAccountId) {
                ForEach(accountStore.accounts) { account in
                    Text(account.fromAddress).tag(UUID?.some(account.id))
                }
            }
            .pickerStyle(.menu)

            TextField("To (comma-separated)", text: $to)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            TextField("Subject", text: $subject)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            TextEditor(text: $bodyText)
                .font(.system(size: 13))
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            if !errorText.isEmpty {
                Text(errorText)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.destructiveRose)
            }

            HStack {
                Spacer()
                GruxChip(title: "Cancel", style: .secondary) { dismiss() }
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    GruxChip(title: "Send", systemImage: "paperplane.fill", style: .primary) {
                        send()
                    }
                }
            }
        }
        .padding(GruxSpacing.l)
        // A sheet is bounded by the window it hangs off, so its width is a
        // range rather than a demand. It still renders at the 520 it always
        // did, which is GruxLayout.sheetIdeal, and the bounds are what keep it
        // inside the 840pt window floor if the form grows or that floor moves.
        .frame(minWidth: GruxLayout.sheetMin,
               idealWidth: GruxLayout.sheetIdeal,
               maxWidth: GruxLayout.sheetMax)
        .background(GruxTheme.base)
        .onAppear {
            if fromAccountId == nil { fromAccountId = accountStore.accounts.first?.id }
        }
    }

    private func send() {
        let recipients = to.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("@") }
        guard !recipients.isEmpty else { errorText = "Add at least one valid recipient."; return }
        guard !subject.trimmingCharacters(in: .whitespaces).isEmpty else { errorText = "Subject is empty."; return }
        guard !bodyText.trimmingCharacters(in: .whitespaces).isEmpty else { errorText = "Body is empty."; return }
        guard let account = accountStore.accounts.first(where: { $0.id == fromAccountId }) ?? accountStore.accounts.first else {
            errorText = "No account configured."
            return
        }
        sending = true
        errorText = ""
        let subj = subject
        let text = bodyText
        Task {
            do {
                _ = try await ResendClient().send(
                    from: account.fromAddress,
                    to: recipients,
                    subject: subj,
                    text: text,
                    listUnsubscribe: nil,
                    replyTo: account.emailAddress
                )
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    sending = false
                    errorText = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Accounts sheet

// Lists configured accounts and adds new ones. The password field writes to
// the keychain only (never to accounts.json).
private struct MailAccountsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var accountStore = EmailAccountStore.shared

    @State private var displayName = ""
    @State private var emailAddress = ""
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var username = ""
    @State private var password = ""
    @State private var errorText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Email accounts")
                .font(GruxTheme.Font.title)
                .foregroundStyle(GruxTheme.textPrimary)

            if !accountStore.accounts.isEmpty {
                VStack(spacing: GruxSpacing.xs) {
                    ForEach(accountStore.accounts) { account in
                        HStack(spacing: GruxSpacing.s) {
                            Circle()
                                .fill(account.lastSyncError == nil ? GruxTheme.successMint : GruxTheme.destructiveRose)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(account.displayName) (\(account.emailAddress))")
                                    .font(GruxTheme.Font.body)
                                    .foregroundStyle(GruxTheme.textPrimary)
                                Text(account.lastSyncError ?? "\(account.imapHost):\(account.imapPort)")
                                    .font(GruxTheme.Font.caption)
                                    .foregroundStyle(account.lastSyncError == nil ? GruxTheme.textTertiary : GruxTheme.destructiveRose)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { account.enabled },
                                set: { on in accountStore.update(account.id) { $0.enabled = on } }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            GruxChip(title: "Remove", style: .destructive) {
                                MailStore.shared.remove(accountId: account.id)
                                accountStore.remove(account.id)
                            }
                        }
                        .padding(.vertical, GruxSpacing.xs - 1)
                    }
                }
                Divider().opacity(0.3)
            }

            Text("Add account")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)

            Grid(alignment: .leading, horizontalSpacing: GruxSpacing.s, verticalSpacing: GruxSpacing.s - 2) {
                GridRow {
                    TextField("Display name", text: $displayName)
                    TextField("Email address", text: $emailAddress)
                }
                GridRow {
                    TextField("IMAP host (outlook.office365.com)", text: $imapHost)
                    TextField("Port", text: $imapPort)
                }
                GridRow {
                    TextField("Username (defaults to address)", text: $username)
                    SecureField("App password (keychain only)", text: $password)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))

            if !errorText.isEmpty {
                Text(errorText)
                    .font(GruxTheme.Font.caption)
                    .foregroundStyle(GruxTheme.destructiveRose)
            }

            HStack {
                Spacer()
                GruxChip(title: "Done", style: .secondary) { dismiss() }
                GruxChip(title: "Add + test", systemImage: "plus", style: .primary) {
                    addAccount()
                }
            }
        }
        .padding(GruxSpacing.l)
        // 560 stays the IDEAL so the form renders exactly as it did; the bounds
        // are what stop it dictating the window. sheetMax is the widest a modal
        // can be and still clear the 840pt window floor with room on both
        // sides, and sheetMin is the narrowest this two-column Grid still reads
        // at, so the row of fields shrinks instead of running off the edge.
        .frame(minWidth: GruxLayout.sheetMin,
               idealWidth: 560,
               maxWidth: GruxLayout.sheetMax)
        .background(GruxTheme.base)
    }

    private func addAccount() {
        let address = emailAddress.trimmingCharacters(in: .whitespaces)
        let host = imapHost.trimmingCharacters(in: .whitespaces)
        guard address.contains("@") else { errorText = "Enter a valid email address."; return }
        guard !host.isEmpty else { errorText = "Enter the IMAP host."; return }
        guard let port = Int(imapPort.trimmingCharacters(in: .whitespaces)), port > 0, port < 65536 else {
            errorText = "Port must be a number (usually 993)."
            return
        }
        guard !password.isEmpty else { errorText = "Enter the account's app password."; return }

        let account = EmailAccount(
            displayName: displayName.trimmingCharacters(in: .whitespaces).isEmpty
                ? address : displayName.trimmingCharacters(in: .whitespaces),
            emailAddress: address,
            imapHost: host,
            imapPort: port,
            username: username.trimmingCharacters(in: .whitespaces),
            useTLS: true
        )
        accountStore.upsert(account, password: password)
        errorText = ""
        displayName = ""; emailAddress = ""; imapHost = ""; imapPort = "993"; username = ""; password = ""

        // Immediate verification sweep so a typo'd host or password surfaces
        // as lastSyncError on the row instead of failing silently later.
        Task { _ = await InboxSyncEngine.shared.syncAll() }
    }
}
