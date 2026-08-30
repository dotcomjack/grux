import Foundation
import Security

// Secure storage for Grux API keys backed by the macOS Keychain.
//
// Why: prior to this module the anthropicApiKey / elevenLabsApiKey lived as
// plaintext fields inside `~/Library/Application Support/Grux/config.json`.
// Anybody (or any process) with read access to that dir - Time Machine
// snapshots, iCloud Drive sync, stray Spotlight indexing - could exfiltrate
// the keys. Keychain moves them into the user's encrypted login keychain
// with per-item ACLs managed by macOS.
//
// Design notes:
// - `kSecClassGenericPassword`, service `com.gruxai.grux`, account = key name.
// - Accessibility is `kSecAttrAccessibleAfterFirstUnlock` (NOT the
//   `ThisDeviceOnly` variant) - Grux runs at login, so it needs to read the
//   keys the first time it launches after a reboot, before the user has
//   necessarily re-entered their password. `AfterFirstUnlock` lets macOS
//   decrypt automatically once the user has unlocked the device at least
//   once since boot, and the key survives migrations.
// - `get` NEVER returns nil. Callers (see `ClaudeClient`, SpeechEngine)
//   already treat the empty string as "key missing", so we preserve that
//   contract and make missing-key handling branchless at call sites.
// - All errors are logged via NSLog (no key material ever logged) and
//   swallowed - Keychain failures should never crash Grux. Worst case
//   the user sees an empty-key error path and can re-paste in Settings.
enum KeychainStore {
    static let service = "com.gruxai.grux"

    enum Key: String {
        case anthropicApiKey
        case elevenLabsApiKey
        case braveApiKey  // Brave Search API key for the web research tool.
        // Replicate API token, used by ReplicateClient as the provider for
        // generated media in the Creative engine (image today, video/motion a
        // later rung). Auth header is `Authorization: Bearer {value}`. Seeded
        // best-effort from the GRUX_REPLICATE_KEY env var by KeychainMigrator on
        // first boot; empty = Media Studio reports needs-setup.
        //
        // REPLACED `falApiKey`. fal.ai is out of the business model. The old key
        // is deliberately NOT migrated: it is a different vendor's credential and
        // copying it into a slot Grux sends to Replicate would be sending one
        // vendor's secret to another. Anything still holding a fal key in the
        // Keychain keeps it; nothing reads it.
        case replicateApiKey
        // Slack integration - user's own Slack app tokens (BYO).
        case slackUserToken     // xoxp-… User OAuth Token (chat.postMessage as human)
        case slackAppToken      // xapp-… App-Level Token (Socket Mode / slash commands)
        // Notion integration - Internal Integration (BYO).
        case notionToken        // ntn_… / secret_… integration token
        case notionDatabaseId   // UUID of the Grux target database
        // 32-byte HMAC secret shared with the GruxPhone iOS companion.
        // Stored base64-encoded. PhonePairing.ensureSecret() generates on
        // first use; the QR in the Pair iPhone window encodes a base64url
        // copy for the phone to scan.
        case phonePairingSecret
        // Resend API key (re_…), used by ResendClient to send the staged
        // support-triage replies and the voice-drafted cold outreach emails.
        // Full-access workspace key; covers whichever sending domains the user
        // has verified on their own Resend account. Stored here so it never
        // lands in source or a plaintext config file. Empty
        // = the Send buttons surface a "set up your Resend key" error path.
        case resendApiKey
        // GoDaddy API key + secret, used by DomainMonitor to list every domain
        // on the account and alert when one is within 30 days of expiry. Auth
        // header is `sso-key {key}:{secret}` (two separate values). Seeded from
        // ~/.grux/godaddy-creds.json on first sweep when absent here.
        case goDaddyApiKey
        case goDaddyApiSecret
        // The five contract `key.*` capabilities that had no slot until the
        // capability registry needed to resolve all 40. Empty by default and
        // never seeded: a stranger's install starts with nothing in any of
        // these, and each one is asked for in onboarding or in a setup card.
        // RETIRED by CR-34, 2026-08-28, and deliberately NOT deleted. Their capability
        // ids are gone from the contract and nothing reads either slot. Removing the
        // cases would not remove a value: Settings offered all fourteen key capabilities
        // before CR-31, so somebody may have pasted one, and an account name no code can
        // name is a credential sitting unreachable in the login keychain rather than
        // deleted. That is the exact failure KeychainServiceMigrator exists to prevent.
        // grux doctor reports a value here so a person can remove it deliberately.
        case openAIApiKey           // retired, an OpenAI-compatible endpoint keeps its own key
        case openRouterApiKey       // retired, same
        case gitHubToken            // key.github, classic token with repo scope
        case appStoreConnectKey     // key.appstoreconnect, the .p8 contents
        case redditCredentials      // key.reddit, client id and secret
        // key.telegram, a pair like the registrar one above: the bot token is
        // the credential and the chat id says where its messages land. Both
        // empty by default, and nothing sends until both are filled in.
        case telegramBotToken
        case telegramChatId
    }

    @discardableResult
    static func set(_ key: Key, _ value: String) -> Bool {
        invalidate(key)
        guard let data = value.data(using: .utf8) else {
            NSLog("[KeychainStore] set \(key.rawValue) → utf8 encode failed")
            return false
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]

        // First check whether the item exists - can't just SecItemAdd because
        // that returns errSecDuplicateItem on rewrites.
        var findQuery = baseQuery
        findQuery[kSecReturnData as String] = false
        findQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        let findStatus = copyMatching(findQuery, nil)

        switch findStatus {
        case errSecSuccess:
            // Update in place.
            let attrs: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attrs as CFDictionary)
            if updateStatus != errSecSuccess {
                NSLog("[KeychainStore] update \(key.rawValue) → OSStatus \(updateStatus)")
                return false
            }
            return true

        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                NSLog("[KeychainStore] add \(key.rawValue) → OSStatus \(addStatus)")
                return false
            }
            return true

        default:
            NSLog("[KeychainStore] find \(key.rawValue) → OSStatus \(findStatus)")
            return false
        }
    }

    // MARK: - Read cache

    // A Keychain read is an XPC round trip to securityd, and these values were being read
    // from inside SwiftUI view bodies. `AppState.anthropicKey` and its two siblings are
    // computed properties over `get`, and four view files read them in `body`, which SwiftUI
    // re-evaluates on every invalidation. With the app's timers firing dozens of times a
    // second, that turned into a sustained stream of securityd round trips for values that
    // change only when someone edits Settings. A `sample` of the shipping build caught it
    // under `LaunchRootView.statusBar.getter`.
    //
    // Cached in memory, invalidated on every write and delete, so a value can never go
    // stale relative to this process. `nil` is a real cached answer meaning "asked and it
    // was not there", which matters because a missing key is the common case on a fresh
    // install and re-asking for it is the same expensive round trip.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    private static func cached(_ key: Key) -> String? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[key.rawValue]
    }

    private static func store(_ key: Key, _ value: String) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[key.rawValue] = value
    }

    /// Drop a cached read. Called by every write path so the cache cannot outlive the truth.
    static func invalidate(_ key: Key) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache.removeValue(forKey: key.rawValue)
    }


    /// A READ MUST NEVER RAISE A MODAL, and this is the flag that guarantees it.
    ///
    /// `SecItemCopyMatching` asks macOS to unlock the keychain holding the item, and macOS
    /// answers by putting a password dialog in front of whoever is there. Measured on the
    /// Mac Mini on the first launch of 1.2.1, from a screenshot of its actual screen:
    /// "Grux OS wants to use the "grux-vault" keychain. Please enter the keychain password."
    /// sat over everything before any Grux window was usable.
    ///
    /// That is not a hypothetical. `SetupStatusFile.write()` runs at launch, resolves every
    /// `key.*` capability through `CapabilityResolver`, and every one of those is a
    /// `KeychainStore.get`. So a launch reads the keychain a dozen times before anybody has
    /// touched anything.
    ///
    /// `KeychainServiceMigrator` already carried this flag and its comment already explained
    /// why. What it did not do was generalise: a sweep found 42 SecItem calls across ten
    /// files and the migrator held the only four skip flags in the tree.
    ///
    /// Skipping the UI turns a locked keychain into `errSecInteractionNotAllowed`, which
    /// reads here as "no value", which reads upstream as "that credential is not set". That
    /// is a degradation and it is the right one: a credential somebody cannot reach is
    /// survivable and self-corrects the moment the keychain unlocks. A launch they cannot
    /// get past is not.
    ///
    /// WRITES ARE DELIBERATELY NOT COVERED. `set` and `delete` happen because a person just
    /// pressed something, so a prompt has context and an answer.
    nonisolated static let neverPrompt: [String: Any] = [
        kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
    ]

    nonisolated static func withoutUI(_ query: [String: Any]) -> [String: Any] {
        query.merging(neverPrompt) { current, _ in current }
    }

    /// THE ONLY PLACE IN THE `Grux` MODULE THAT CALLS `SecItemCopyMatching`.
    ///
    /// Made the single copy after a per-file COUNT of read queries against skip flags failed
    /// to catch two planted defects. Counting cannot work here: this file shares one
    /// `neverPrompt` constant across several queries, so the arithmetic says "guarded" while
    /// an individual query is not, and the tokens also appear in the prose explaining the
    /// rule. Rather than write a Swift dictionary-literal parser that will silently stop
    /// matching one day, the flag is applied HERE, where it cannot be forgotten, and the test
    /// checks the one thing a grep can answer without ambiguity: that nothing else calls the
    /// raw API.
    ///
    /// Same argument as `Lookup`, `BillView` and `AgentHandoff` being single copies.
    nonisolated static func copyMatching(_ query: [String: Any],
                                         _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
        SecItemCopyMatching(onlyOurOwnKeychain(withoutUI(query)) as CFDictionary, result)
    }

    /// SEARCH ONLY THE DEFAULT KEYCHAIN, because a search with no search list traverses
    /// EVERY keychain in the login session's list, and Grux does not own most of them.
    ///
    /// This is the actual cause of a password dialog reported twice and twice not closed.
    /// Measured on two Macs: each carried a CUSTOM keychain created by an unrelated local
    /// tool. Creating a keychain ADDS IT TO THE SEARCH LIST, and such a keychain is commonly
    /// locked with a password of its own rather than the login password, so every keychain
    /// search the app made traversed it and macOS asked for a password the person genuinely
    /// does not know. That is exactly the "it is asking for a password that is not my Mac
    /// password" report.
    ///
    /// `kSecUseAuthenticationUISkip` did not close it, because that governs the ITEM query.
    /// The prompt comes from traversing a locked keychain on the way there.
    ///
    /// Stray keychains accumulate on any developer machine. An app's own credential reads
    /// should not care what else is in the list.
    ///
    /// Constraining READS to the default keychain is consistent with where WRITES already go:
    /// `SecItemAdd` with no keychain specified lands in the default one. So this narrows the
    /// search to exactly the place Grux puts things.
    ///
    /// `SecKeychainCopyDefault` is deprecated and is the only way to name a file-based
    /// keychain for `kSecMatchSearchList`. If it fails, the query is returned UNCHANGED
    /// rather than blocked: a prompt is better than a credential that cannot be read at all.
    private static func onlyOurOwnKeychain(_ query: [String: Any]) -> [String: Any] {
        guard query[kSecMatchSearchList as String] == nil else { return query }
        var keychain: SecKeychain?
        guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else {
            return query
        }
        var out = query
        out[kSecMatchSearchList as String] = [keychain] as CFArray
        return out
    }

    static func get(_ key: Key) -> String {
        if let hit = cached(key) { return hit }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = copyMatching(query, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { store(key, ""); return "" }
            let value = String(data: data, encoding: .utf8) ?? ""
            store(key, value)
            return value
        case errSecItemNotFound:
            store(key, "")
            return ""
        default:
            // Deliberately NOT cached. A transient failure must not pin an empty value for
            // the life of the process, which would look exactly like a key the user never
            // entered and send them to Settings to re-add one that is already there.
            NSLog("[KeychainStore] get \(key.rawValue) → OSStatus \(status)")
            return ""
        }
    }

    @discardableResult
    static func delete(_ key: Key) -> Bool {
        invalidate(key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return true
        default:
            NSLog("[KeychainStore] delete \(key.rawValue) → OSStatus \(status)")
            return false
        }
    }

    static func exists(_ key: Key) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = copyMatching(query, nil)
        return status == errSecSuccess
    }
}

// One-time migration for legacy plaintext keys living in `GruxConfig`.
//
// Called once at launch. If the config still has real keys in it, they're
// copied into Keychain and the config fields are overwritten with the
// sentinel string "[MIGRATED]" so:
//   1. The migrator is idempotent - it won't re-run on a clean config.
//   2. A stray reader that missed the sweep will get "[MIGRATED]" instead
//      of a real key, making any accidental leak a loud failure instead
//      of a silent one.
//
// We intentionally DO NOT delete the `anthropicApiKey` / `elevenLabsApiKey`
// fields from `GruxConfig` - they need to stay decodable so existing
// config.json files keep loading (backwards compatibility) and the
// migrator can find any legacy plaintext on first launch.
enum KeychainMigrator {
    @MainActor
    static func runOnce() {
        let state = AppState.shared
        var dirty = false

        let legacyAnthropic = state.config.anthropicApiKey
        if !legacyAnthropic.isEmpty && legacyAnthropic != "[MIGRATED]" {
            _ = KeychainStore.set(.anthropicApiKey, legacyAnthropic)
            state.config.anthropicApiKey = "[MIGRATED]"
            dirty = true
        }

        let legacyEleven = state.config.elevenLabsApiKey
        if !legacyEleven.isEmpty && legacyEleven != "[MIGRATED]" {
            _ = KeychainStore.set(.elevenLabsApiKey, legacyEleven)
            state.config.elevenLabsApiKey = "[MIGRATED]"
            dirty = true
        }

        if dirty {
            state.saveConfig()
            NSLog("[KeychainMigrator] migrated keys to Keychain; config fields blanked")
        }

        // Best-effort seed: land the Replicate token from GRUX_REPLICATE_KEY so a
        // headless / ops launch that exports it lands the key in Keychain once
        // without a Settings round-trip. Non-fatal; never overwrites a key that
        // is already stored; the value is never logged.
        if KeychainStore.get(.replicateApiKey).isEmpty,
           let envReplicate = ProcessInfo.processInfo.environment["GRUX_REPLICATE_KEY"]?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !envReplicate.isEmpty {
            if KeychainStore.set(.replicateApiKey, envReplicate) {
                NSLog("[KeychainMigrator] seeded Replicate token from GRUX_REPLICATE_KEY")
            }
        }
    }
}
