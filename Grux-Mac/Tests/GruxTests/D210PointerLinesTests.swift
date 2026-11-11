import XCTest
@testable import Grux

/// D210 items 3 and 7 (sense pass 31): two lines that send a person somewhere
/// and leave out what they find there.
/// (3) Credentials, web research: "Turn offline mode off in Settings, Models to
/// use it" never said that the same switch moves chat to Claude
/// (`AppState.offlineMode` sets the active provider to Anthropic when it goes off).
/// (7) Jax Command, Gmail: "Add your Gmail account in Mailbox, Accounts" while the
/// pane reads "Mail", and with no account it draws no Accounts button, only
/// the setup card's "Set it up".
@MainActor
final class D210PointerLinesTests: XCTestCase {

    private func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: item 3

    func test_everyOfflineLineSaysTheSwitchAlsoMovesChat() throws {
        for offline in [false, true] {
            for enabled in [false, true] {
                for key in [false, true] {
                    for moves in [false, true] {
                        let label = "offline \(offline) enabled \(enabled) key \(key) moves \(moves)"
                        if let line = WebResearch.settingsLine(offline: offline, enabled: enabled, hasSearchKey: key,
                                                               chatMovesToClaude: moves) {
                            XCTAssertEqual(line.contains(WebResearch.offlineAlsoMovesChat), offline && moves, "\(label): \(line)")
                            XCTAssertFalse(line.contains(";."), line)
                        }
                        if let line = DeepResearchEngine.refusal(offline: offline, enabled: enabled, hasSearchKey: key,
                                                                 chatMovesToClaude: moves) {
                            XCTAssertEqual(line.contains(WebResearch.offlineAlsoMovesChat), offline && moves, "\(label): \(line)")
                            XCTAssertFalse(line.contains(";."), line)
                        }
                    }
                }
            }
        }
        XCTAssertEqual(WebResearch.settingsLine(offline: true, enabled: true, hasSearchKey: true, chatMovesToClaude: true),
                       "Not searching now: offline mode is on, and a search sends your question to Brave Search. "
                       + "Turn offline mode off in Settings, Models to use it; turning it off also moves chat to Claude.")
        XCTAssertEqual(WebResearch.settingsLine(offline: true, enabled: true, hasSearchKey: true, chatMovesToClaude: false),
                       "Not searching now: offline mode is on, and a search sends your question to Brave Search. "
                       + "Turn offline mode off in Settings, Models to use it.")
        XCTAssertEqual(DeepResearchEngine.refusal(offline: true, enabled: true, hasSearchKey: false, chatMovesToClaude: false),
                       "Not searching: offline mode is on, and deep research sends your question to Brave Search. "
                       + "Turn offline mode off in Settings, Models. Deep research also needs a Brave Search API key, "
                       + "in Settings, Data & Security, Data & Capabilities, Credentials, Web search API key.")
    }

    /// Wave 75 round 1 P2: with no Claude key and a local model running, offline
    /// mode off still routes chat local, and a chat preset that pins a provider
    /// keeps chat there, yet the line said chat moves to Claude. The words follow
    /// the router in every combination.
    func test_theLineSaysChatMovesOnlyWhereTheRouterMovesIt() {
        for hasKey in [false, true] {
            for hasLocal in [false, true] {
                for preset in [nil, "local", "anthropic", "custom:abc"] as [String?] {
                    let says = WebResearch.offlineOffMovesChat(hasClaudeKey: hasKey, presetProvider: preset)
                    // Offline off records Anthropic; chat answers on Claude only
                    // when that choice routes to Anthropic AND a key can answer,
                    // and no preset overrides the route.
                    let routesToClaude = ModelRegistry.anthropicRoute(hasKey: hasKey, hasLocal: hasLocal) == .anthropic
                    let moves = preset == nil && routesToClaude && hasKey
                    XCTAssertEqual(says, moves, "key \(hasKey) local \(hasLocal) preset \(preset ?? "none")")
                }
            }
        }
    }

    /// Both places the line is drawn read the router's inputs, not a constant.
    func test_bothLinesReadTheKeyAndThePreset() throws {
        let call = "WebResearch.offlineOffMovesChat("
        for path in ["Sources/Grux/SettingsView.swift", "Sources/Grux/Research/DeepResearchEngine.swift"] {
            let src = try source(path)
            let at = try XCTUnwrap(src.range(of: call), path)
            let tail = String(src[at.upperBound...].prefix(420))
            XCTAssertTrue(tail.contains("KeychainStore.exists(.anthropicApiKey)"), "\(path): \(tail)")
            XCTAssertTrue(tail.contains("PresetStore.shared.activeChatApplication()?.providerOverride"), "\(path): \(tail)")
        }
    }

    /// The words hold only while the switch does what they say.
    func test_theSwitchMovesChatToClaudeWhenItGoesOff() throws {
        let src = try source("Sources/Grux/AppState.swift")
        XCTAssertTrue(src.contains("ModelRegistry.shared.setActiveProvider(offlineMode ? .local : .anthropic)"),
                      "offline mode off no longer moves chat to Claude: change WebResearch.offlineAlsoMovesChat")
    }

    // MARK: item 7

    /// Wave 75 round 1 P2: the line named "Set it up", which Mail draws only with
    /// no mail account switched on; with an iCloud account on, Mail is the inbox
    /// and "Accounts", and in onboarding Mail is not on screen. It names the pane
    /// and no button.
    func test_noGmailAccountLineNamesThePaneAndNoButton() {
        let line = CorpusPermission.needsAccount.humanReason
        XCTAssertTrue(line.contains("in Mail") && line.contains("app password"), line)
        let button = CapabilitySetupCard.actionTitle(for: .endpointImap) ?? "?"
        for named in [button, "Add account", "Accounts", "Set it up"] {
            XCTAssertFalse(line.contains(named), "\(named): \(line)")
        }
    }

    /// Wave 75 round 1 P2: a Gmail account with no stored password read "No Gmail
    /// account yet. Add it", while the account is listed in Mail; adding it made a
    /// second one. It reads as its own state.
    func test_aGmailAccountWithNoPasswordIsNotNoAccount() {
        XCTAssertEqual(GmailSentIngester.permission(hasAccount: false, password: .missing), .needsAccount)
        XCTAssertEqual(GmailSentIngester.permission(hasAccount: false, password: .found("x")), .needsAccount)
        XCTAssertEqual(GmailSentIngester.permission(hasAccount: true, password: .missing), .needsPassword)
        XCTAssertEqual(GmailSentIngester.permission(hasAccount: true, password: .found("x")), .ready)
        let line = CorpusPermission.needsPassword.humanReason
        XCTAssertFalse(line.contains("No Gmail account"), line)
        XCTAssertTrue(line.contains("Add it again in Mail") && line.contains("same address updates")
                      && line.contains("app password"), line)
        XCTAssertFalse(line.contains("Remove"), line)
        XCTAssertEqual(JaxMemorySection.statusHint(.init(source: .gmailSent, permission: .needsPassword, lastRunAt: nil,
                                                         lastNote: "", totalIndexed: 0, lastRunIndexed: 0,
                                                         isRunning: false)), "no password")
    }

    /// The class: no line points at "Mailbox, Accounts" or "Mailbox > Accounts".
    /// The pane's header reads Mail (`SidebarIA.railOrder`), and its Accounts
    /// button exists, so a pointer names those two.
    func test_noPointerNamesAPaneThatIsNotDrawn() throws {
        let rail = SidebarIA.railOrder.first { $0.key == "mailbox" }
        XCTAssertEqual(rail?.label, "Mail")
        XCTAssertTrue(try source("Sources/Grux/Email/Imap/MailboxView.swift")
            .contains("GruxChip(title: \"Accounts\""))
        XCTAssertTrue(try source("Sources/Grux/Email/Imap/MailboxView.swift").contains("ctaTitle: \"Add account\""))
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100)
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for bad in ["Mailbox, Accounts", "Mailbox > Accounts"] where text.contains(bad) {
                hits.append("\(file.lastPathComponent): \(bad)")
            }
        }
        XCTAssertEqual(hits, [])
    }

    // MARK: wave 75 round 2

    /// A Keychain that would not answer (locked, or headless with interaction off,
    /// `errSecInteractionNotAllowed`) read as "no password saved", whose step,
    /// Remove it and add it again, deletes the account's mail. Only a password
    /// that is not there reads as missing.
    func test_aLockedKeychainIsNotAMissingPassword() {
        XCTAssertEqual(ImapPasswordVault.classify(status: errSecSuccess, data: Data("pw".utf8)), .found("pw"))
        XCTAssertEqual(ImapPasswordVault.classify(status: errSecSuccess, data: Data()), .missing)
        XCTAssertEqual(ImapPasswordVault.classify(status: errSecSuccess, data: nil), .missing)
        XCTAssertEqual(ImapPasswordVault.classify(status: errSecItemNotFound, data: nil), .missing)
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecUserCanceled] {
            XCTAssertEqual(ImapPasswordVault.classify(status: status, data: nil), .unreadable(status), "\(status)")
            XCTAssertEqual(GmailSentIngester.permission(hasAccount: true, password: .unreadable(status)), .needsKeychain)
        }
        XCTAssertEqual(GmailSentIngester.permission(hasAccount: false, password: .unreadable(errSecInteractionNotAllowed)),
                       .needsAccount)
        // Round 3: it read "Not checked yet. Reopen this tab" (`.unknown`) forever,
        // since nothing on either screen starts a read. It names the Keychain.
        let line = CorpusPermission.needsKeychain.humanReason
        XCTAssertTrue(line.contains("Keychain"), line)
        XCTAssertFalse(line.contains("Remove") || line.contains("no password") || line.contains("Add"), line)
        let st = CorpusCoordinator.SourceStatus(source: .gmailSent, permission: .needsKeychain, lastRunAt: nil,
                                                lastNote: "", totalIndexed: 0, lastRunIndexed: 0, isRunning: false)
        XCTAssertEqual(JaxMemorySection.statusHint(st), "keychain locked")
        XCTAssertEqual(JaxMemorySection.needLine(st), line)
        XCTAssertFalse(JaxMemorySection.canIndex(st))
    }

    /// The Accounts sheet's sync error said "add it in Mail, Accounts" inside that
    /// sheet, where Add makes a second account, and "no password stored" for a
    /// Keychain that only would not answer.
    func test_theSyncErrorSaysWhichPasswordProblemItIs() {
        let missing = InboxSyncEngine.noPasswordLine(address: "a@b.c", read: .missing)
        XCTAssertTrue(missing.contains("no password stored for a@b.c") && missing.contains("add it again below")
                      && missing.contains("same address updates it"), missing)
        XCTAssertFalse(missing.contains("Accounts"), missing)
        let locked = InboxSyncEngine.noPasswordLine(address: "a@b.c", read: .unreadable(errSecInteractionNotAllowed))
        XCTAssertFalse(locked.contains("no password") || locked.contains("remove"), locked)
        XCTAssertTrue(locked.contains("Keychain"), locked)
    }

    // MARK: wave 75 round 3

    /// Mail's Add made a second account for an address already listed, so every
    /// "add it again" step left Gmail reading the first, passwordless one. The
    /// same address now updates that account, keeps its id, and switches it on.
    func test_addingAListedAddressUpdatesThatAccount() {
        var old = EmailAccount(displayName: "me", emailAddress: "Me@Gmail.com", imapHost: "imap.gmial.com")
        old.enabled = false
        old.lastSyncError = "no password stored"
        let other = EmailAccount(displayName: "work", emailAddress: "me@work.com", imapHost: "imap.work.com")
        let form = EmailAccount(displayName: "Me", emailAddress: "me@gmail.com", imapHost: "imap.gmail.com",
                                imapPort: 994, username: "me2", useTLS: true)
        let target = EmailAccountStore.formTarget(accounts: [other, old], new: form)
        XCTAssertEqual(target.id, old.id)
        // Round 4: kept off, Add + test synced nothing (`syncAll` reads enabled
        // accounts), the setup card stayed, and the cleared error read as a pass.
        XCTAssertTrue(target.enabled, "adding it is asking Grux to read it")
        XCTAssertEqual(target.imapHost, "imap.gmail.com")
        XCTAssertEqual(target.imapPort, 994)
        XCTAssertEqual(target.username, "me2")
        XCTAssertEqual(target.displayName, "Me")
        XCTAssertNil(target.lastSyncError)
        let fresh = EmailAccount(displayName: "x", emailAddress: "x@y.z", imapHost: "imap.y.z")
        XCTAssertEqual(EmailAccountStore.formTarget(accounts: [other, old], new: fresh).id, fresh.id)
        XCTAssertEqual(EmailAccountStore.formTarget(accounts: [], new: fresh).id, fresh.id)
        XCTAssertTrue(try source("Sources/Grux/Email/Imap/MailboxView.swift")
            .contains("accountStore.upsert(EmailAccountStore.formTarget(accounts: accountStore.accounts, new: account),"))
    }

    /// `grux remove mailbox` said "Nothing ever entered one" for a Keychain that
    /// would not answer, and `grux add mailbox` said the account has no password.
    func test_theMailCommandsSayWhatTheKeychainAnswered() throws {
        XCTAssertTrue(GruxControlTools.passwordRemovalLine(.found("x")).contains("is forgotten"))
        XCTAssertTrue(GruxControlTools.passwordRemovalLine(.missing).contains("no password"))
        let locked = GruxControlTools.passwordRemovalLine(.unreadable(errSecInteractionNotAllowed))
        XCTAssertTrue(locked.contains("could not read") && locked.contains("may still be in it"), locked)
        XCTAssertFalse(locked.contains("Nothing ever") || locked.contains("forgotten"), locked)
        for path in ["Sources/Grux/Onboarding/GruxControlTools+Add.swift", "Sources/Grux/Onboarding/GruxControlTools+Remove.swift"] {
            let src = try source(path)
            XCTAssertFalse(src.contains("password(for:"), "\(path) reads a failed Keychain read as no password")
            XCTAssertTrue(src.contains("passwordRead(for:"), path)
        }
    }
}
