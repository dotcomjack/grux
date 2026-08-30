import Foundation
import Security

// JSON-on-disk persistence for webhook configs + the delivery audit log.
// Same pattern as ComparisonStore / FolderStore: @MainActor singleton,
// @Published arrays, debounced scheduleSave (0.3s coalesce). Default files:
// ~/Library/Application Support/Grux/webhooks.json and
// webhook-deliveries.json. Tests inject temp fileURLs so they never touch
// real state.
@MainActor
final class WebhookStore: ObservableObject {
    static let shared = WebhookStore()

    @Published private(set) var configs: [WebhookConfig] = []
    @Published private(set) var deliveries: [WebhookDelivery] = []

    // Audit log stays bounded, delivery records are small but accrete on
    // every event x endpoint. Oldest fall off past the cap.
    static let maxDeliveries = 200

    private let configsURL: URL
    private let deliveriesURL: URL
    private var saveToken: DispatchWorkItem?

    init(configsURL: URL? = nil, deliveriesURL: URL? = nil) {
        self.configsURL = configsURL ?? Persistence.supportDir.appendingPathComponent("webhooks.json")
        self.deliveriesURL = deliveriesURL ?? Persistence.supportDir.appendingPathComponent("webhook-deliveries.json")
        self.configs = Persistence.load([WebhookConfig].self, from: self.configsURL, fallback: [])
        self.deliveries = Persistence.load([WebhookDelivery].self, from: self.deliveriesURL, fallback: [])
    }

    // MARK: - Read

    func config(id: UUID) -> WebhookConfig? {
        configs.first(where: { $0.id == id })
    }

    // Enabled configs subscribed to a given event. The manager's fan-out
    // filter, pulled into the store so it's trivially unit-testable.
    func targets(for event: WebhookEvent) -> [WebhookConfig] {
        configs.filter { $0.enabled && $0.events.contains(event) }
    }

    // Newest first, what the recent-deliveries list wants.
    var orderedDeliveries: [WebhookDelivery] {
        deliveries.sorted { $0.timestamp > $1.timestamp }
    }

    func deliveries(for webhookId: UUID) -> [WebhookDelivery] {
        orderedDeliveries.filter { $0.webhookId == webhookId }
    }

    // MARK: - Write

    func upsert(_ config: WebhookConfig) {
        if let idx = configs.firstIndex(where: { $0.id == config.id }) {
            configs[idx] = config
        } else {
            configs.insert(config, at: 0)
        }
        scheduleSave()
    }

    func delete(id: UUID) {
        guard let cfg = config(id: id) else { return }
        configs.removeAll(where: { $0.id == id })
        WebhookSecretStore.delete(account: cfg.secretAccount)
        scheduleSave()
    }

    func setEnabled(id: UUID, _ enabled: Bool) {
        guard let idx = configs.firstIndex(where: { $0.id == id }) else { return }
        configs[idx].enabled = enabled
        scheduleSave()
    }

    func recordDelivery(_ delivery: WebhookDelivery) {
        deliveries.append(delivery)
        if deliveries.count > Self.maxDeliveries {
            let sorted = orderedDeliveries
            let keep = Set(sorted.prefix(Self.maxDeliveries).map { $0.id })
            deliveries.removeAll(where: { !keep.contains($0.id) })
        }
        scheduleSave()
    }

    // MARK: - Save (debounced)

    private func scheduleSave() {
        saveToken?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Persistence.save(self.configs, to: self.configsURL)
            Persistence.save(self.deliveries, to: self.deliveriesURL)
        }
        saveToken = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // Immediate flush, used by tests and app teardown.
    func saveNow() {
        saveToken?.cancel()
        saveToken = nil
        Persistence.save(configs, to: configsURL)
        Persistence.save(deliveries, to: deliveriesURL)
    }
}

// MARK: - Secret storage

// Per-webhook HMAC secrets live in the macOS Keychain, NOT in webhooks.json.
// KeychainStore.Key is a closed enum (one fixed account per key), so webhook
// secrets get their own service namespace with dynamic accounts. Same
// accessibility posture as KeychainStore: AfterFirstUnlock so signing works
// on a post-reboot launch before the user re-authenticates.
enum WebhookSecretStore {
    static let service = "com.gruxai.grux.webhooks"

    @discardableResult
    static func set(account: String, secret: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        var findQuery = baseQuery
        findQuery[kSecReturnData as String] = false
        findQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let findStatus = KeychainStore.copyMatching(findQuery, nil)
        switch findStatus {
        case errSecSuccess:
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let status = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
            if status != errSecSuccess {
                NSLog("[WebhookSecretStore] update \(account) -> OSStatus \(status)")
                return false
            }
            return true
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                NSLog("[WebhookSecretStore] add \(account) -> OSStatus \(status)")
                return false
            }
            return true
        default:
            NSLog("[WebhookSecretStore] find \(account) -> OSStatus \(findStatus)")
            return false
        }
    }

    // Empty string == missing, matching the KeychainStore.get contract so
    // call sites stay branchless ("no secret -> unsigned delivery refused").
    static func get(account: String) -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            // A read never prompts. See KeychainStore.neverPrompt for why.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = KeychainStore.copyMatching(query, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func exists(account: String) -> Bool {
        !get(account: account).isEmpty
    }
}
