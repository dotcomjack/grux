import SwiftUI
import AppKit

/// The optional decision-model key. Grux decides on device without it; with
/// it, every decision point upgrades at once. Same shape as the Slack card:
/// paste a key, Save and Test makes one real call, Disconnect removes it.
struct DecisionsSection: View {
    struct Copy { let title: String; let body: String }
    static let copy = Copy(
        title: "Decisions",
        body: "Jev by TypeSafe makes Grux's small decisions in about half a second with a confidence attached. Optional. Without it Grux decides on device, and adding a key changes nothing else.")

    @State private var key: String = ""
    @State private var reveal: Bool = false
    @State private var statusLine: String = ""
    @State private var connected: Bool = false
    @State private var testing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.title2).foregroundStyle(GruxTheme.accentPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.copy.title).font(.headline)
                    Text(connected ? "Connected" : "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(Self.copy.body)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                NSWorkspace.shared.open(URL(string: "https://console.typesafe.ai/keys")!)
            } label: {
                Label("Get a key from TypeSafe", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .font(.caption)

            VStack(alignment: .leading, spacing: 6) {
                Text("TypeSafe API key").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if reveal {
                        TextField("apikey_…", text: $key).textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("apikey_…", text: $key).textFieldStyle(.roundedBorder)
                    }
                    Button(reveal ? "Hide" : "Show") { reveal.toggle() }
                        .buttonStyle(.bordered)
                }
            }

            HStack {
                Button("Save & Test") { Task { await saveAndTest() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)

                if connected {
                    DestructiveButton(
                        "Disconnect",
                        question: "Remove the decision key?",
                        detail: "Grux removes the key from your Mac's Keychain and goes back to deciding on device. Nothing on TypeSafe's side changes.",
                        confirmLabel: "Disconnect"
                    ) { disconnect() }
                    .buttonStyle(.bordered)
                }

                if testing { ProgressView().controlSize(.small) }
                if !statusLine.isEmpty {
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: loadFromKeychain)
    }

    private func loadFromKeychain() {
        key = KeychainStore.get(.typesafeApiKey)
        connected = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveAndTest() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = KeychainStore.set(.typesafeApiKey, trimmed)
        testing = true
        defer { testing = false }
        statusLine = "Asking one question…"
        do {
            let r = try await JevDecisionProvider(apiKey: trimmed).decide(
                state: "Grux is checking that this key works.",
                questions: ["works": .noul(instructions: "Is this a connection check?")])
            connected = true
            statusLine = "Connected, answered in \(r.latencyMs) ms"
        } catch let e as JevDecisionProvider.Failure {
            connected = false
            switch e {
            case .http(let code): statusLine = code == 401 || code == 403 ? "That key was not accepted" : "TypeSafe could not answer right now"
            case .malformed: statusLine = "TypeSafe answered in a shape Grux did not expect"
            case .noKey: statusLine = "Paste a key first"
            }
        } catch {
            connected = false
            statusLine = "No answer. Check the connection and try again"
        }
    }

    private func disconnect() {
        _ = KeychainStore.delete(.typesafeApiKey)
        key = ""
        connected = false
        statusLine = "Disconnected. Deciding on device."
    }
}
