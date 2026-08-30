import SwiftUI
import AppKit

// Integrations tab. Settings-like surface for connecting / disconnecting
// 3rd-party services. Tokens are stored in the macOS Keychain under the
// same service (com.gruxai.grux) as Anthropic / ElevenLabs / Brave keys.
//
// Design principle: token paste, not OAuth redirect. A local-first macOS
// app can't safely ship a Slack/Notion client secret and doesn't have a
// server to hold one. Users create their own app/integration once, paste
// the resulting token here, done.

struct IntegrationsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                SlackSection()
                Divider()
                NotionSection()
                Divider()
                // Item 35: outbound webhooks with HMAC-signed deliveries.
                WebhooksView()
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Integrations")
                .font(GruxType.title).foregroundStyle(GruxTheme.textPrimary)
            Text("Connect Grux to the services you already use. Tokens are stored in your macOS Keychain. Nothing is sent to a server. Grux talks to Slack and Notion directly from your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Slack

private struct SlackSection: View {
    @State private var userToken: String = ""
    @State private var appToken: String = ""
    @State private var revealUserToken: Bool = false
    @State private var revealAppToken: Bool = false
    @State private var statusLine: String = ""
    @State private var connected: Bool = false
    @State private var workspace: String = ""
    @State private var userName: String = ""
    @State private var testing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader

            Text("Create a Slack app at ") +
                Text("api.slack.com/apps").underline().foregroundColor(GruxTheme.accentPrimary) +
                Text(" → add User Token Scopes: `chat:write, channels:read, channels:history, groups:read, users:read, search:read` → install to your workspace → copy the User OAuth Token (xoxp-…). Optional: enable Socket Mode and generate an App-Level Token (xapp-…) if you want `/ask-grux` slash commands.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.open(URL(string: "https://api.slack.com/apps")!)
            } label: {
                Label("Open Slack App Management", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .font(.caption)

            VStack(alignment: .leading, spacing: 6) {
                Text("User OAuth Token (xoxp-…)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if revealUserToken {
                        TextField("xoxp-…", text: $userToken).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("xoxp-…", text: $userToken).textFieldStyle(.roundedBorder)
                    }
                    Button(revealUserToken ? "Hide" : "Show") { revealUserToken.toggle() }
                        .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("App-Level Token (xapp-…), optional, enables slash commands").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if revealAppToken {
                        TextField("xapp-…", text: $appToken).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("xapp-…", text: $appToken).textFieldStyle(.roundedBorder)
                    }
                    Button(revealAppToken ? "Hide" : "Show") { revealAppToken.toggle() }
                        .buttonStyle(.bordered)
                }
            }

            HStack {
                Button("Save & Test") {
                    Task { await saveAndTest() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)

                if connected {
                    DestructiveButton(
                        "Disconnect",
                        question: "Disconnect this account?",
                        detail: "Grux removes the stored token from your Mac's Keychain and stops "
                            + "reading or posting. Nothing on the service itself is changed, and "
                            + "you can reconnect by pasting a token again.",
                        confirmLabel: "Disconnect"
                    ) { disconnect() }
                    .buttonStyle(.bordered)
                }

                if testing {
                    ProgressView().scaleEffect(0.7)
                }

                Spacer()
                statusBadge
            }

            if !statusLine.isEmpty {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(statusLine.hasPrefix("✓") ? .green : .orange)
                    .textSelection(.enabled)
            }
        }
        .onAppear { loadFromKeychain() }
    }

    private var sectionHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "number.square.fill")
                .font(.system(size: 24))
                .foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 2) {
                Text("Slack").font(.title3.weight(.bold))
                Text(connected ? "Connected\(workspace.isEmpty ? "" : " · \(workspace)")" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(connected ? .green : .secondary)
            }
            Spacer()
        }
    }

    private var statusBadge: some View {
        Group {
            if connected {
                Label("Connected", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Label("Not connected", systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadFromKeychain() {
        userToken = KeychainStore.get(.slackUserToken)
        appToken = KeychainStore.get(.slackAppToken)
        connected = !userToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveAndTest() async {
        let trimmedUser = userToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApp = appToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { return }
        _ = KeychainStore.set(.slackUserToken, trimmedUser)
        if !trimmedApp.isEmpty {
            _ = KeychainStore.set(.slackAppToken, trimmedApp)
        }
        testing = true
        defer { testing = false }
        statusLine = "Testing connection…"
        let result = await SlackClient.shared.verify()
        switch result {
        case .success(let me):
            connected = true
            workspace = me.team ?? ""
            userName = me.user ?? ""
            statusLine = "✓ Connected as \(me.user ?? "user") in \(me.team ?? "workspace")"
        case .failure(let e):
            connected = false
            statusLine = "⚠ \(e.localizedDescription)"
        }
    }

    private func disconnect() {
        _ = KeychainStore.delete(.slackUserToken)
        _ = KeychainStore.delete(.slackAppToken)
        userToken = ""
        appToken = ""
        connected = false
        workspace = ""
        statusLine = "Disconnected."
    }
}

// MARK: - Notion

private struct NotionSection: View {
    @State private var token: String = ""
    @State private var databaseId: String = ""
    @State private var reveal: Bool = false
    @State private var statusLine: String = ""
    @State private var connected: Bool = false
    @State private var userName: String = ""
    @State private var testing: Bool = false
    @State private var databases: [NotionClient.DatabaseInfo] = []
    @State private var loadingDBs: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader

            Text("Create an Internal Integration at ") +
                Text("notion.so/my-integrations").underline().foregroundColor(GruxTheme.accentPrimary) +
                Text(" → copy the Internal Integration Secret → in Notion, open the database you want Grux to write to → click Connections → add your integration. Then paste the token below and either pick a database or paste its UUID.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button {
                NSWorkspace.shared.open(URL(string: "https://www.notion.so/my-integrations")!)
            } label: {
                Label("Open Notion Integrations", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .font(.caption)

            VStack(alignment: .leading, spacing: 6) {
                Text("Internal Integration Secret").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if reveal {
                        TextField("ntn_… or secret_…", text: $token).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("ntn_… or secret_…", text: $token).textFieldStyle(.roundedBorder)
                    }
                    Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                        .buttonStyle(.bordered)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Database ID (or pick one after Save)").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. 1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d", text: $databaseId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if !databases.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Available databases").font(.caption).foregroundStyle(.secondary)
                    ForEach(databases, id: \.id) { db in
                        Button {
                            databaseId = db.id
                        } label: {
                            HStack {
                                Image(systemName: databaseId == db.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(databaseId == db.id ? .green : .secondary)
                                Text(db.title).font(.callout)
                                Text(String(db.id.prefix(8)))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Button("Save & Test") {
                    Task { await saveAndTest() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)

                Button("List Databases") {
                    Task { await fetchDatabases() }
                }
                .buttonStyle(.bordered)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loadingDBs)

                if connected {
                    DestructiveButton(
                        "Disconnect",
                        question: "Disconnect this account?",
                        detail: "Grux removes the stored token from your Mac's Keychain and stops "
                            + "reading or posting. Nothing on the service itself is changed, and "
                            + "you can reconnect by pasting a token again.",
                        confirmLabel: "Disconnect"
                    ) { disconnect() }
                    .buttonStyle(.bordered)
                }

                if testing || loadingDBs {
                    ProgressView().scaleEffect(0.7)
                }

                Spacer()
                statusBadge
            }

            if !statusLine.isEmpty {
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(statusLine.hasPrefix("✓") ? .green : .orange)
                    .textSelection(.enabled)
            }
        }
        .onAppear { loadFromKeychain() }
    }

    private var sectionHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "note.text")
                .font(.system(size: 24))
                .foregroundStyle(.gray)
            VStack(alignment: .leading, spacing: 2) {
                Text("Notion").font(.title3.weight(.bold))
                Text(connected ? "Connected\(userName.isEmpty ? "" : " · \(userName)")" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(connected ? .green : .secondary)
            }
            Spacer()
        }
    }

    private var statusBadge: some View {
        Group {
            if connected {
                Label("Connected", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Label("Not connected", systemImage: "minus.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadFromKeychain() {
        token = KeychainStore.get(.notionToken)
        databaseId = KeychainStore.get(.notionDatabaseId)
        connected = NotionClient.isConnected()
    }

    private func saveAndTest() async {
        let trimmedTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDB = databaseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTok.isEmpty else { return }
        _ = KeychainStore.set(.notionToken, trimmedTok)
        _ = KeychainStore.set(.notionDatabaseId, trimmedDB)
        testing = true
        defer { testing = false }
        statusLine = "Testing connection…"
        let result = await NotionClient.shared.verify()
        switch result {
        case .success(let me):
            userName = me.name ?? ""
            if trimmedDB.isEmpty {
                connected = false
                statusLine = "✓ Token valid (as \(me.name ?? "user")) - pick a database to finish setup"
            } else {
                connected = true
                statusLine = "✓ Connected as \(me.name ?? "user") · db \(String(trimmedDB.prefix(8)))…"
            }
        case .failure(let e):
            connected = false
            statusLine = "⚠ \(e.localizedDescription)"
        }
    }

    private func fetchDatabases() async {
        let trimmedTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTok.isEmpty else { return }
        _ = KeychainStore.set(.notionToken, trimmedTok)
        loadingDBs = true
        defer { loadingDBs = false }
        do {
            let dbs = try await NotionClient.shared.listDatabases()
            databases = dbs
            if dbs.isEmpty {
                statusLine = "⚠ No databases shared with the integration yet. Open a Notion page → Connections → add your integration."
            } else {
                statusLine = "✓ Found \(dbs.count) databases - pick one below"
            }
        } catch let e as NotionError {
            statusLine = "⚠ \(e.localizedDescription)"
        } catch {
            statusLine = "⚠ \(error)"
        }
    }

    private func disconnect() {
        _ = KeychainStore.delete(.notionToken)
        _ = KeychainStore.delete(.notionDatabaseId)
        token = ""
        databaseId = ""
        databases = []
        connected = false
        statusLine = "Disconnected."
    }
}
