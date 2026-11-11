import Foundation
import Security

// One configured IMAP account. The password NEVER lives in this struct or on
// disk; it goes straight into the login keychain via ImapPasswordVault under
// a per-account key, mirroring KeychainStore's posture for API keys.
struct EmailAccount: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String        // whatever the user calls this account
    var emailAddress: String       // you@yourdomain.com
    var imapHost: String           // outlook.office365.com, imap.gmail.com, ...
    var imapPort: Int              // 993 (TLS) almost always
    var username: String           // usually the email address
    var useTLS: Bool               // implicit TLS on 993; STARTTLS unsupported
    var enabled: Bool              // excluded from sync sweeps when false
    // Verified Resend sender used when composing/replying from this account,
    // e.g. "Your Name <you@yourdomain.com>". Resend is the send path (SMTP-out
    // is intentionally not implemented; the sending domain is verified there).
    var fromAddress: String
    var lastSyncAt: Date?
    var lastSyncError: String?

    init(
        id: UUID = UUID(),
        displayName: String,
        emailAddress: String,
        imapHost: String,
        imapPort: Int = 993,
        username: String = "",
        useTLS: Bool = true,
        enabled: Bool = true,
        fromAddress: String = "",
        lastSyncAt: Date? = nil,
        lastSyncError: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.imapHost = imapHost
        self.imapPort = imapPort
        self.username = username.isEmpty ? emailAddress : username
        self.useTLS = useTLS
        self.enabled = enabled
        self.fromAddress = fromAddress.isEmpty ? "\(displayName) <\(emailAddress)>" : fromAddress
        self.lastSyncAt = lastSyncAt
        self.lastSyncError = lastSyncError
    }

    // Maps an account onto the existing support-triage inbox enum so new mail
    // can ride the EmailTriageEngine classify path with the right brand voice.
    // The address-to-brand routes are the user's own (EmailBrandRoutes) and are
    // empty until they write them, so out of the box no account is routed and
    // triage simply does not run. No match returns nil and skips triage.
    var supportInbox: SupportInbox? {
        let addr = emailAddress.lowercased()
        // Longest needle first so the match is deterministic when one address
        // matches two routes: the more specific route wins.
        for (needle, brand) in EmailBrandRoutes.load().sorted(by: { $0.key.count > $1.key.count }) {
            guard !needle.isEmpty, addr.contains(needle) else { continue }
            if let inbox = SupportInbox(rawValue: brand) { return inbox }
        }
        return nil
    }

    // Brand voice for the app-wide BrandFilter (decision 3). Derived from the
    // support inbox, one brand tag per routed account. Accounts with no route
    // have no brand and only show under the "All" scope. (A routed account can
    // still draft in another voice per-message; the account-level brand stays
    // put, which is the right granularity for inbox filtering.)
    var brandVoice: String? { supportInbox?.rawValue }
}

// Which support brand an incoming address belongs to. The routes are the user's
// own business, not Grux's, so they live on disk at
// ~/.grux/email/brand-routes.json rather than compiled in:
//
//   { "yourdomain.com": "acme", "otherbrand.com": "northwind" }
//
// The key is a lowercase substring matched against the account's address; the
// value is a SupportInbox raw value. Missing file, unreadable JSON, and unknown
// brand values all yield no route, which means the account skips triage. That
// is the intended unconfigured state: a feature awaiting setup, never an error.
enum EmailBrandRoutes {
    static var fileURL: URL {
        Persistence.gruxDir
            .appendingPathComponent("email")
            .appendingPathComponent("brand-routes.json")
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        var routes: [String: String] = [:]
        for (needle, brand) in obj {
            routes[needle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] = brand
        }
        return routes
    }
}

// Multi-account config store. JSON-on-disk at ~/.grux/email/accounts.json
// (same ~/.grux convention as SupportDraftStore so it is greppable from the
// CLI for verification), with the debounced scheduleSave pattern FolderStore
// and CookbookStore use.
@MainActor
final class EmailAccountStore: ObservableObject {
    static let shared = EmailAccountStore()

    @Published private(set) var accounts: [EmailAccount] = []

    static var rootDir: URL {
        Persistence.gruxDir
            .appendingPathComponent("email")
    }
    private static var fileURL: URL { rootDir.appendingPathComponent("accounts.json") }

    private var saveToken: DispatchWorkItem?

    private init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([EmailAccount].self, from: data) {
            accounts = decoded
        }
    }

    var enabledAccounts: [EmailAccount] { accounts.filter { $0.enabled } }

    func account(id: UUID) -> EmailAccount? {
        accounts.first { $0.id == id }
    }

    // Fuzzy lookup for the Claude tools: matches address, display name, or
    // host substring, case-insensitive.
    func resolve(_ hint: String) -> EmailAccount? {
        let q = hint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        return accounts.first {
            $0.emailAddress.lowercased().contains(q)
                || $0.displayName.lowercased().contains(q)
                || $0.imapHost.lowercased().contains(q)
        }
    }

    // Adds (or replaces by id) an account and stores its password in the
    // keychain. Pass an empty password to keep any existing one.
    func upsert(_ account: EmailAccount, password: String) {
        if let idx = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[idx] = account
        } else {
            accounts.append(account)
        }
        if !password.isEmpty {
            ImapPasswordVault.set(accountId: account.id, password: password)
        }
        scheduleSave()
    }

    /// What Mail's Add saves (wave 75 round 3): an address already listed is that
    /// account with the form's settings and a new password, keeping its id (so
    /// its cached mail and the Keychain item). Add made a second account before,
    /// which every "add it again" step then sent people to make, while Gmail reads
    /// kept the first, passwordless one. Adding is asking Grux to read it, so the
    /// account is switched on (round 4): kept off, Add + test tested nothing, the
    /// setup card stayed, and the cleared error read as a pass.
    static func formTarget(accounts: [EmailAccount], new: EmailAccount) -> EmailAccount {
        let wanted = new.emailAddress.lowercased()
        guard var existing = accounts.first(where: { $0.emailAddress.lowercased() == wanted }) else { return new }
        existing.displayName = new.displayName
        existing.emailAddress = new.emailAddress
        existing.imapHost = new.imapHost
        existing.imapPort = new.imapPort
        existing.username = new.username
        existing.useTLS = new.useTLS
        existing.enabled = true
        existing.lastSyncError = nil
        return existing
    }

    func update(_ id: UUID, _ mutate: (inout EmailAccount) -> Void) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        mutate(&accounts[idx])
        scheduleSave()
    }

    func remove(_ id: UUID) {
        accounts.removeAll { $0.id == id }
        ImapPasswordVault.delete(accountId: id)
        scheduleSave()
    }

    func password(for account: EmailAccount) -> String {
        ImapPasswordVault.get(accountId: account.id)
    }

    func passwordRead(for account: EmailAccount) -> ImapPasswordVault.PasswordRead {
        ImapPasswordVault.read(accountId: account.id)
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveToken?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.saveNow() }
        }
        saveToken = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        objectWillChange.send()
    }

    func saveNow() {
        try? FileManager.default.createDirectory(at: Self.rootDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(accounts) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}

// Per-account IMAP password storage in the macOS login keychain. Separate
// from KeychainStore because that enum keys items by a fixed Key enum; IMAP
// accounts are dynamic, so this vault keys by account UUID under the same
// com.gruxai.grux service. Same accessibility posture (AfterFirstUnlock, Grux
// runs at login) and the same never-crash, never-log-secret error handling.
enum ImapPasswordVault {
    static let service = "com.gruxai.grux"

    private static func accountKey(_ id: UUID) -> String {
        "imapPassword.\(id.uuidString)"
    }

    @discardableResult
    static func set(accountId: UUID, password: String) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(accountId)
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
                NSLog("[ImapPasswordVault] update -> OSStatus \(status)")
                return false
            }
            return true
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            if status != errSecSuccess {
                NSLog("[ImapPasswordVault] add -> OSStatus \(status)")
                return false
            }
            return true
        default:
            NSLog("[ImapPasswordVault] find -> OSStatus \(findStatus)")
            return false
        }
    }

    /// What a read found (wave 75 round 2): a password that is not there and a
    /// Keychain that would not answer (locked, or headless with interaction off)
    /// are different things to tell a person, and only the first means "add it".
    enum PasswordRead: Equatable {
        case found(String)
        case missing
        case unreadable(OSStatus)
    }

    static func classify(status: OSStatus, data: Data?) -> PasswordRead {
        switch status {
        case errSecSuccess:
            guard let data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return .missing }
            return .found(text)
        case errSecItemNotFound:
            return .missing
        default:
            return .unreadable(status)
        }
    }

    static func read(accountId: UUID) -> PasswordRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(accountId),
            kSecReturnData as String: true,
            // A read never prompts. See KeychainStore.neverPrompt for why.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = KeychainStore.copyMatching(query, &item)
        let result = classify(status: status, data: item as? Data)
        if case .unreadable = result { NSLog("[ImapPasswordVault] get -> OSStatus \(status)") }
        return result
    }

    // Empty string = missing or unreadable, mirroring KeychainStore.get's contract.
    static func get(accountId: UUID) -> String {
        if case .found(let text) = read(accountId: accountId) { return text }
        return ""
    }

    @discardableResult
    static func delete(accountId: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey(accountId)
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
