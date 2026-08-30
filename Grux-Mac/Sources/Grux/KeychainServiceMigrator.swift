import Foundation
import Security

/// Moves Keychain items from a previous service name to the current one.
///
/// The app's Keychain service strings used to carry the original author's
/// initials (`com.dcj.*`). They were renamed to `com.gruxai.*` for the open
/// source release, and a service string is part of the primary key of a
/// Keychain item.
///
/// So renaming without moving does not merely "lose" the items, it makes them
/// permanently unreachable: every stored API key, mail account credential,
/// webhook secret and social token stays sitting in the login keychain,
/// invisible to the app, while the user is told to re-enter everything with no
/// explanation offered. The items are not gone, which is worse, because
/// nothing surfaces to say where they went.
///
/// ORDER IS THE WHOLE DESIGN: copy, verify the copy reads back, and only then
/// delete the original. A migration interrupted after the copy is harmless and
/// re-runs cleanly. One interrupted after a delete is data loss. Anything that
/// cannot be verified is LEFT ALONE rather than deleted.
enum KeychainServiceMigrator {

    /// Every service rename this app has been through, oldest first. Adding a
    /// row here is the only thing a future rename needs.
    static let renames: [(old: String, new: String)] = [
        ("com.dcj.grux",          "com.gruxai.grux"),
        ("com.dcj.grux.webhooks", "com.gruxai.grux.webhooks"),
        ("com.dcj.grux.graph",    "com.gruxai.grux.graph"),
        ("com.dcj.grux.vault",    "com.gruxai.grux.vault"),
    ]

    /// Set by `migrate` to say whether the keychain was actually readable that pass.
    /// Not a result of the migration: a pass that moved nothing because there was nothing
    /// to move is COMPLETE, and a pass that moved nothing because the keychain was locked
    /// is not, and only the first may be recorded as done.
    nonisolated(unsafe) private static var lastPassWasComplete = true

    /// Where "already done" is recorded. Keyed on the rename table itself, so adding a
    /// future rename starts a new question rather than inheriting an old answer.
    static var doneKey: String {
        "grux.keychain.serviceMigration.done."
            + String(renames.map { $0.old + ">" + $0.new }.joined(separator: ",").hashValue)
    }

    /// RUNS ONCE, WHICH IT DID NOT BEFORE.
    ///
    /// The comment that used to sit here said "safe to call on every launch: a service with
    /// no items left under the old name is a no-op costing one Keychain query". Both halves
    /// were the defect. Nothing recorded that the migration had finished, so every boot
    /// re-queried every rename, and a Keychain query is not a no-op: it is a chance for
    /// macOS to raise a modal asking to unlock the login keychain.
    ///
    /// Measured on a Mac Mini with a fresh install: that modal named `grux-vault`, one of
    /// the service strings in `renames` above, it blocked the launch, and it came back on
    /// every boot afterwards. On a Mac whose account password was ever reset through an
    /// Apple ID the login keychain keeps the OLD password, so it cannot be answered at all.
    ///
    /// Marked done only when every rename came back READABLE, so a machine that genuinely
    /// still has items under an old name keeps trying and a machine that has nothing left
    /// stops asking.
    @discardableResult
    static func runOnce() -> Int {
        if UserDefaults.standard.bool(forKey: doneKey) { return 0 }

        var moved = 0
        var everyPassComplete = true
        for rename in renames {
            lastPassWasComplete = true
            moved += migrate(from: rename.old, to: rename.new)
            if !lastPassWasComplete { everyPassComplete = false }
        }
        if moved > 0 {
            NSLog("[KeychainServiceMigrator] moved \(moved) item(s) to the current service names")
        }
        if everyPassComplete {
            UserDefaults.standard.set(true, forKey: doneKey)
        }
        return moved
    }

    /// Returns the number of items successfully moved. Never throws, never
    /// crashes: a Keychain failure here must not stop the app from launching,
    /// because the fallback (the user re-enters a key in Settings) is survivable
    /// and a launch crash is not.
    static func migrate(from old: String, to new: String) -> Int {
        guard old != new else { return 0 }

        // TWO PASSES, and the split is required rather than stylistic. On macOS
        // a generic-password query combining kSecMatchLimitAll with
        // kSecReturnData does not return the values the way the iOS keychain
        // does; it comes back empty and the migration silently reports nothing
        // to do. So: list the accounts with attributes only, then read each
        // value individually with kSecMatchLimitOne.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: old,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            // NEVER RAISE UI FROM A LAUNCH-TIME MIGRATION.
            //
            // Without this, `SecItemCopyMatching` asks macOS to unlock the login keychain,
            // and macOS puts a modal in front of somebody who has just opened the app. On a
            // Mac whose account password was ever reset through an Apple ID the login
            // keychain keeps the OLD password, so that dialog CANNOT BE ANSWERED by the
            // person looking at it. Measured on a Mac Mini with a fresh install: the dialog
            // named `grux-vault`, one of the service strings in `renames` below, launch
            // blocked behind it, and it came back on every boot afterwards.
            //
            // Skipping the UI turns that into `errSecInteractionNotAllowed`, which is a
            // deferral rather than a failure: nothing is migrated this launch and the next
            // one tries again, silently, while the app carries on. A credential a person
            // cannot reach is survivable. A launch they cannot get past is not.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]

        var result: CFTypeRef?
        let status = KeychainStore.copyMatching(query, &result)
        if status == errSecItemNotFound {
            lastPassWasComplete = true
            return 0
        }
        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            // NOT FINISHED, AND THE DIFFERENCE MATTERS. Anything other than not-found means
            // the keychain could not be read this time, usually because it is locked. Saying
            // so is what stops `runOnce` from marking the migration done and skipping it
            // forever on the one machine that still needs it.
            lastPassWasComplete = false
            return 0
        }
        lastPassWasComplete = true

        var movedAccounts: [String] = []
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = readData(service: old, account: account) else { continue }

            // Never clobber a value already stored under the new service. If
            // both exist the new one is authoritative: it is what the running
            // app has been reading and writing.
            if copyExists(service: new, account: account) {
                movedAccounts.append(account)
                continue
            }

            var add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: new,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            // Carry the human-facing label across when the original had one, so
            // the entry does not become anonymous in Keychain Access.
            if let label = item[kSecAttrLabel as String] as? String {
                add[kSecAttrLabel as String] = label
            }

            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecSuccess || addStatus == errSecDuplicateItem {
                movedAccounts.append(account)
            } else {
                NSLog("[KeychainServiceMigrator] copy failed for account \(account) (OSStatus \(addStatus)); leaving the original in place")
            }
        }

        // Delete the originals ONLY for accounts that verifiably read back under
        // the new service. An account that failed to copy keeps its original,
        // so the user still has the credential and a later launch retries.
        var deleted = 0
        for account in movedAccounts where copyExists(service: new, account: account) {
            let del: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: old,
                kSecAttrAccount as String: account,
            ]
            if SecItemDelete(del as CFDictionary) == errSecSuccess { deleted += 1 }
        }
        return deleted
    }

    /// Reads one item's value. Single-item lookup with kSecMatchLimitOne, which
    /// is the form that reliably returns data on macOS.
    private static func readData(service: String, account: String) -> Data? {
        let q: [String: Any] = [
            // Same reason as the list query above: a migration is background work and
            // background work does not get to put a password prompt on somebody's screen.
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard KeychainStore.copyMatching(q, &out) == errSecSuccess,
              let data = out as? Data, !data.isEmpty else { return nil }
        return data
    }

    /// Reads the item back rather than trusting the add's status code. This is
    /// the verification the delete depends on, so it asks the Keychain the same
    /// question the app will ask later.
    private static func copyExists(service: String, account: String) -> Bool {
        readData(service: service, account: account) != nil
    }
}
