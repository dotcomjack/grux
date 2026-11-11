import SwiftUI
import AppKit

/// The optional decision-model key. Grux decides on device without it; with
/// it, every decision point upgrades at once. Same shape as the Slack card:
/// paste a key, Save and Test makes one real call, Disconnect removes it.
struct DecisionsSection: View {
    struct Copy { let title: String; let body: String }
    /// The speed is the one Settings, Usage measured, never a promise (D87): it said "in about
    /// half a second" beside a measured 216 ms. No Jev decision today, no number.
    static func copy(jevTypicalMs: Int?) -> Copy {
        let speed = jevTypicalMs.map { ", in a typical \($0) ms today" } ?? ""
        return Copy(
            title: "Decisions",
            body: "Jev by TypeSafe makes Grux's small decisions with a confidence attached\(speed). Optional. Without it Grux decides on device, and adding a key changes nothing else.")
    }

    /// The link to get a key sat under "Connected" (D116 item 9).
    static func showsGetKeyLink(connected: Bool) -> Bool { !connected }

    // MARK: - What the last check of the saved key found (W33-P3 item 1)

    /// A key that failed Save & Test stayed in the Keychain, and reopening the
    /// pane read "Connected" from the key's mere presence. "Connected" now
    /// means the last check of THIS key worked.
    enum KeyCheck: String, Codable { case worked, refused, unanswered }

    /// The last check, matched to its key by the key's last four characters,
    /// never the key itself.
    struct KeyCheckRecord: Codable, Equatable {
        let result: KeyCheck
        let at: Date
        let keyTail: String
    }

    static let checkDefaultsKey = "decisionKeyCheck"

    static func tail(_ key: String) -> String {
        String(key.trimmingCharacters(in: .whitespacesAndNewlines).suffix(4))
    }

    static func headline(key: String, record: KeyCheckRecord?) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Not connected" }
        guard let record, record.keyTail == tail(trimmed) else { return "Key saved, not checked yet" }
        switch record.result {
        case .worked: return "Connected"
        case .refused: return "Key saved, TypeSafe refused it"
        case .unanswered: return "Key saved, not checked yet: TypeSafe did not answer"
        }
    }

    /// Any saved key can be removed, checked or not.
    static func offersDisconnect(savedKey: String) -> Bool {
        !savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isConnected(key: String, record: KeyCheckRecord?) -> Bool {
        headline(key: key, record: record) == "Connected"
    }

    /// Only 401 and 403 say the key itself was refused; any other failure
    /// says nothing about the key.
    static func checkResult(of error: Error) -> KeyCheck {
        if case .http(let code)? = error as? JevDecisionProvider.Failure, code == 401 || code == 403 { return .refused }
        return .unanswered
    }

    /// A key TypeSafe refused is not kept; the earlier key, if any, stays.
    /// Re-testing the saved key itself after TypeSafe revoked it removes it
    /// (W34-P3 item 1): the "earlier key" was the refused one.
    static func keyToKeep(tried: String, previous: String, result: KeyCheck) -> String {
        guard result == .refused else { return tried }
        return previous == tried ? "" : previous
    }

    static func refusedLine(tried: String, previous: String) -> String {
        if previous == tried { return "TypeSafe no longer accepts this key, so Grux removed it" }
        return previous.isEmpty ? "That key was not accepted, so Grux did not keep it"
                                : "That key was not accepted, so Grux kept your earlier key"
    }

    static func loadCheck(_ defaults: UserDefaults = .standard) -> KeyCheckRecord? {
        defaults.data(forKey: checkDefaultsKey).flatMap { try? JSONDecoder().decode(KeyCheckRecord.self, from: $0) }
    }

    static func saveCheck(_ record: KeyCheckRecord?, _ defaults: UserDefaults = .standard) {
        guard let record, let data = try? JSONEncoder().encode(record) else {
            defaults.removeObject(forKey: checkDefaultsKey); return
        }
        defaults.set(data, forKey: checkDefaultsKey)
    }

    @ObservedObject private var usage = DecisionUsageModel.shared

    @State private var key: String = ""
    /// What the Keychain holds, which is not what the field holds while a
    /// person types.
    @State private var savedKey: String = ""
    @State private var check: KeyCheckRecord?
    @State private var reveal: Bool = false
    @State private var statusLine: String = ""
    @State private var testing: Bool = false

    private var connected: Bool { Self.isConnected(key: savedKey, record: check) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.fill")
                    .font(.title2).foregroundStyle(GruxTheme.accentPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.copy(jevTypicalMs: usage.snapshot.jevTypicalMs).title).font(.headline)
                    Text(Self.headline(key: savedKey, record: check))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text(Self.copy(jevTypicalMs: usage.snapshot.jevTypicalMs).body)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if Self.showsGetKeyLink(connected: connected) {
                Button {
                    NSWorkspace.shared.open(URL(string: "https://console.typesafe.ai/keys")!)
                } label: {
                    Label("Get a key from TypeSafe", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

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

                if Self.offersDisconnect(savedKey: savedKey) {
                    DestructiveButton(
                        "Disconnect",
                        question: "Remove the decision key?",
                        detail: "Grux removes the key from your Mac's Keychain and goes back to deciding on device. Nothing on TypeSafe's side changes.",
                        confirmLabel: "Disconnect"
                    ) { disconnect() }
                    .buttonStyle(.bordered)
                    .disabled(testing)
                }

                if testing { ProgressView().controlSize(.small) }
                if !statusLine.isEmpty {
                    Text(statusLine).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: loadFromKeychain)
        // A real decision is a check of the key too (D166 item 3), and it lands
        // in the ledger right after, so the headline follows it live.
        .onChange(of: usage.snapshot) { _, _ in check = Self.loadCheck() }
    }

    private func loadFromKeychain() {
        key = KeychainStore.get(.typesafeApiKey)
        savedKey = key
        check = Self.loadCheck()
    }

    private func saveAndTest() async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let previous = savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        testing = true
        defer { testing = false }
        statusLine = "Asking one question…"
        let result: KeyCheck
        do {
            let r = try await JevDecisionProvider(apiKey: trimmed).decide(
                state: "Grux is checking that this key works.",
                questions: ["works": .noul(instructions: "Is this a connection check?")])
            result = .worked
            statusLine = "Connected, answered in \(r.latencyMs) ms"
        } catch {
            result = Self.checkResult(of: error)
            switch error as? JevDecisionProvider.Failure {
            case .http(let code)?:
                statusLine = result == .refused
                    ? Self.refusedLine(tried: trimmed, previous: previous)
                    : "TypeSafe could not answer (HTTP \(code)). The key is saved; try again later"
            case .malformed?: statusLine = "TypeSafe answered in a shape Grux did not expect. The key is saved"
            case .noKey?: statusLine = "Paste a key first"
            case nil: statusLine = "No answer. The key is saved; check the connection and try again"
            }
        }
        let kept = Self.keyToKeep(tried: trimmed, previous: previous, result: result)
        if kept.isEmpty { _ = KeychainStore.delete(.typesafeApiKey) } else { _ = KeychainStore.set(.typesafeApiKey, kept) }
        if kept == trimmed {
            check = KeyCheckRecord(result: result, at: Date(), keyTail: Self.tail(trimmed))
            Self.saveCheck(check)
        } else if kept.isEmpty {
            check = nil
            Self.saveCheck(nil)
        }
        savedKey = kept
        key = kept
    }

    private func disconnect() {
        _ = KeychainStore.delete(.typesafeApiKey)
        key = ""
        savedKey = ""
        check = nil
        Self.saveCheck(nil)
        statusLine = "Disconnected. Deciding on device."
    }
}
