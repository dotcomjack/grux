import Foundation
import Security

// GraphMailStore: the configuration + credential home for Graph mail access.
// Non-secret config (tenant id, client id, mailbox map) persists to
// ~/.grux/jax/graph-mail-config.json; the client SECRET lives only in the macOS
// Keychain (never on disk, never in the struct), mirroring ImapPasswordVault's
// posture. One Azure app serves every mailbox, so tenant/client are shared and
// each SupportInbox maps to its mailbox address.

struct GraphMailbox: Codable, Equatable {
    var inbox: String      // SupportInbox rawValue
    var address: String    // the M365 mailbox, e.g. support@example.com
}

struct GraphMailConfig: Codable, Equatable {
    var tenantId: String = ""
    var clientId: String = ""
    var mailboxes: [GraphMailbox] = []

    var isPresent: Bool { !tenantId.isEmpty && !clientId.isEmpty && !mailboxes.isEmpty }
    func address(forInbox raw: String) -> String? {
        mailboxes.first { $0.inbox.lowercased() == raw.lowercased() }?.address
    }
}

@MainActor
final class GraphMailStore: ObservableObject {
    static let shared = GraphMailStore()

    @Published private(set) var config = GraphMailConfig()

    private let url: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grux/jax", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("graph-mail-config.json")
    }()

    private init() { config = Persistence.load(GraphMailConfig.self, from: url, fallback: GraphMailConfig()) }

    // Configured + has a stored secret + a mailbox mapping for this inbox.
    func isConfigured(forInbox raw: String) -> Bool {
        config.isPresent && config.address(forInbox: raw) != nil && !GraphSecretVault.get().isEmpty
    }

    func mailboxAddress(forInbox raw: String) -> String? { config.address(forInbox: raw) }

    // Build the client Config (tenant/client from disk + secret from Keychain).
    func clientConfig() -> MailGraphClient.Config? {
        let secret = GraphSecretVault.get()
        guard config.isPresent, !secret.isEmpty else { return nil }
        return MailGraphClient.Config(tenantId: config.tenantId, clientId: config.clientId, clientSecret: secret)
    }

    // Ingest a one-time setup JSON: {tenantId, clientId, clientSecret, mailboxes:
    // [{inbox, address}]}. Stores config to disk and the secret to Keychain.
    // Returns a short status string. The caller (fire trigger) shreds the source
    // file so the secret never lingers in plaintext.
    @discardableResult
    func ingest(_ data: Data) -> String {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "graph setup: could not parse JSON"
        }
        let tenant = (o["tenantId"] as? String) ?? ""
        let client = (o["clientId"] as? String) ?? ""
        let secret = (o["clientSecret"] as? String) ?? ""
        var boxes: [GraphMailbox] = []
        if let arr = o["mailboxes"] as? [[String: Any]] {
            for m in arr {
                if let inbox = m["inbox"] as? String, let addr = m["address"] as? String, !addr.isEmpty {
                    boxes.append(GraphMailbox(inbox: inbox, address: addr))
                }
            }
        }
        guard !tenant.isEmpty, !client.isEmpty, !boxes.isEmpty else {
            return "graph setup: need tenantId, clientId, and at least one mailbox"
        }
        config = GraphMailConfig(tenantId: tenant, clientId: client, mailboxes: boxes)
        Persistence.save(config, to: url)
        if !secret.isEmpty { _ = GraphSecretVault.set(secret) }
        let hasSecret = !GraphSecretVault.get().isEmpty
        return "graph setup: stored tenant + client + \(boxes.count) mailbox(es); secret \(hasSecret ? "in Keychain" : "MISSING (add clientSecret)")"
    }
}

// Single-item Keychain vault for the Graph client secret (separate from the
// fixed-key KeychainStore and the per-account ImapPasswordVault).
enum GraphSecretVault {
    private static let service = "com.gruxai.grux.graph"
    private static let account = "graph-client-secret"

    @discardableResult
    static func set(_ secret: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get() -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                     kSecAttrService as String: service,
                                     kSecAttrAccount as String: account,
                                     kSecReturnData as String: true,
                                     kSecMatchLimit as String: kSecMatchLimitOne,
                                     // A read never prompts. See KeychainStore.neverPrompt.
                                     kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip]
        var item: CFTypeRef?
        guard KeychainStore.copyMatching(query, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }
}
