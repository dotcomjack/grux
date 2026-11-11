import XCTest
@testable import Grux

/// D182, live on grux-local:2b: "Is my calendar private?" got "Your calendar
/// is private. I don't have access to your events or dates." on a Mac where
/// Grux had calendar access, and "Who can read my messages?" got "Only you can
/// read your messages.". Both are guesses about one kind of data. The answer is
/// Grux's own: whether it reads that kind, from the permission or the setup
/// that lets it, and where what it reads goes, from the chat route.
final class PrivacyKindAskTests: XCTestCase {
    func testEachKindIsReadFromTheWholeAsk() {
        let cases: [(String, PrivacyAsk.Kind)] = [
            ("Is my calendar private?", .calendar), ("is my calendar private", .calendar),
            ("Grux, who can see my calendar?", .calendar), ("Does Grux read my calendar?", .calendar),
            ("Where do my calendar events go?", .calendar), ("Is my schedule private?", .calendar),
            ("Are my contacts private?", .contacts), ("Who can see my contacts?", .contacts),
            ("Do you send my contacts anywhere?", .contacts), ("Is my address book private?", .contacts),
            ("Is my email private?", .mail), ("Do you read my email?", .mail), ("Are my emails private?", .mail),
            ("Does my mail leave my Mac?", .mail), ("Is my inbox private?", .mail),
            ("Who can read my messages?", .messages), ("Are my texts private?", .messages),
            ("Hi! Who can read my iMessages?", .messages), ("Are my text messages sent to the cloud?", .messages),
        ]
        for (text, kind) in cases {
            XCTAssertEqual(PrivacyAsk.kind(of: text), kind, text)
        }
        // A second ask beside it, an action ask, or no kind at all stays with the model.
        for text in ["Is my calendar private? Also add milk to my list.", "Can you read my email?",
                     "Read my messages", "What is on my calendar tomorrow?", "Can you see my calendar?",
                     "Is my calendar private or shared with my wife", "Does anything I type leave my Mac?",
                     "Is my bank account private?", "", "Grux", "Who can read my diary?"] {
            XCTAssertNil(PrivacyAsk.kind(of: text), text)
        }
    }

    /// The general ask keeps its own answer: "Do my messages leave this Mac?"
    /// asks about what is typed in chat (D177).
    func testTheGeneralAskStaysGeneral() {
        XCTAssertTrue(PrivacyAsk.matches("Do my messages leave this Mac?"))
        XCTAssertNil(PrivacyAsk.kind(of: "Do my messages leave this Mac?"))
        XCTAssertNil(PrivacyAsk.kind(of: "Are my chats private?"))
    }

    /// The kind answer over the whole-chat answer for these switches.
    private func reply(_ kind: PrivacyAsk.Kind, access: PrivacyAsk.Access, route: PrivacyAsk.Route,
                       backgroundRoute: PrivacyAsk.Route? = nil, mailHosts: [String] = [],
                       mirrorHost: String? = nil, hostedVoice: Bool = false) -> String {
        PrivacyAsk.kindReply(kind, access: access,
                             chat: PrivacyAsk.reply(route: route, searchReady: false, decisionsKey: false,
                                                    updateCheckOn: true, hostedVoice: hostedVoice,
                                                    memoryMirrorHost: mirrorHost, backgroundRoute: backgroundRoute),
                             mailHosts: mailHosts)
    }

    func testAnAllowedCalendarSaysGruxReadsItAndWhereItGoes() {
        let here = reply(.calendar, access: .allowed, route: .thisMac(model: "Grux Local"))
        XCTAssertTrue(here.contains("can read your calendar"), here)
        XCTAssertTrue(here.contains("Grux Local") && here.contains("does not leave this Mac"), here)
        XCTAssertFalse(here.lowercased().contains("is private"), here)
        let cloud = reply(.calendar, access: .allowed, route: .anthropic)
        XCTAssertTrue(cloud.contains("Anthropic") && cloud.contains("leaves this Mac"), cloud)
        XCTAssertFalse(cloud.contains("does not leave"), cloud)
        let lan = reply(.contacts, access: .allowed, route: .otherMachine(model: "Qwen", host: "10.0.0.5"))
        XCTAssertTrue(lan.contains("10.0.0.5") && lan.contains("can read your contacts"), lan)
        let ep = reply(.calendar, access: .allowed, route: .custom(name: "OpenRouter", host: "openrouter.ai"))
        XCTAssertTrue(ep.contains("OpenRouter (openrouter.ai)"), ep)
    }

    func testATurnedOffPermissionSaysNothingIsReadAndNamesTheSwitch() {
        let cal = reply(.calendar, access: .denied, route: .anthropic)
        XCTAssertTrue(cal.contains("cannot read your calendar"), cal)
        XCTAssertTrue(cal.contains("Privacy & Security, Calendars"), cal)
        XCTAssertFalse(cal.contains("Anthropic"), cal)
        let con = reply(.contacts, access: .denied, route: .thisMac(model: "Grux Local"))
        XCTAssertTrue(con.contains("cannot read your contacts") && con.contains("Privacy & Security, Contacts"), con)
        let asked = reply(.calendar, access: .notAsked, route: .anthropic)
        XCTAssertTrue(asked.contains("macOS asks you"), asked)
        // What it would read still names where it would go.
        XCTAssertTrue(asked.contains("Anthropic"), asked)
    }

    func testMailIsReadFromTheAccountsAdded() {
        let none = reply(.mail, access: .nothing, route: .anthropic)
        XCTAssertTrue(none.contains("no mail account") && none.contains("in Mail"), none)
        XCTAssertFalse(none.contains("Anthropic"), none)
        let some = reply(.mail, access: .allowed, route: .anthropic, mailHosts: ["imap.gmail.com"])
        XCTAssertTrue(some.contains("imap.gmail.com") && some.contains("Anthropic"), some)
        let two = reply(.mail, access: .allowed, route: .thisMac(model: "Grux Local"),
                                       mailHosts: ["imap.gmail.com", "outlook.office365.com"])
        XCTAssertTrue(two.contains("imap.gmail.com and outlook.office365.com"), two)
    }

    func testMessagesSayOnlyTheOnesYouSentAndFullDiskAccess() {
        let off = reply(.messages, access: .denied, route: .anthropic)
        XCTAssertTrue(off.contains("cannot read your Messages") && off.contains("Full Disk Access"), off)
        XCTAssertFalse(off.contains("Anthropic"), off)
        let unknown = reply(.messages, access: .notAsked, route: .thisMac(model: "Grux Local"))
        XCTAssertTrue(unknown.contains("Full Disk Access") && unknown.contains("you sent"), unknown)
        let on = reply(.messages, access: .allowed, route: .thisMac(model: "Grux Local"),
                                      mirrorHost: "mini.local")
        XCTAssertTrue(on.contains("you sent") && on.contains("mini.local"), on)
        let empty = reply(.messages, access: .nothing, route: .anthropic)
        XCTAssertTrue(empty.contains("no Messages on this Mac"), empty)
    }

    func testNoModelAndABackgroundRouteThatLeaves() {
        let none = reply(.calendar, access: .allowed, route: .none(step: nil))
        XCTAssertTrue(none.contains("no model"), none)
        let pinned = reply(.calendar, access: .allowed, route: .thisMac(model: "Grux Local"),
                                          backgroundRoute: .anthropic)
        XCTAssertTrue(pinned.contains("Thread titles") && pinned.contains("Anthropic"), pinned)
        let same = reply(.calendar, access: .allowed, route: .thisMac(model: "Grux Local"),
                                        backgroundRoute: .thisMac(model: "Grux Local"))
        XCTAssertFalse(same.contains("Thread titles"), same)
    }

    /// W60-FIX P2: a memory mirror carries replies that quote events or
    /// contacts too, so every kind names it, and "does not leave this Mac"
    /// never stands alone beside one. P3: with no model the reply does not say
    /// nothing goes anywhere while the mirror line follows.
    func testTheMirrorIsNamedForEveryKind() {
        for kind in [PrivacyAsk.Kind.calendar, .contacts, .mail, .messages] {
            let r = reply(kind, access: .allowed, route: .thisMac(model: "Grux Local"),
                                         mailHosts: ["imap.gmail.com"], mirrorHost: "mini.local")
            XCTAssertTrue(r.contains("mini.local"), r)
            XCTAssertFalse(r.contains("so it does not leave this Mac."), r)
            let none = reply(kind, access: .allowed, route: .none(step: nil),
                                            mailHosts: ["imap.gmail.com"], mirrorHost: "mini.local")
            XCTAssertFalse(none.contains("goes anywhere"), none)
            XCTAssertTrue(none.contains("mini.local"), none)
        }
    }

    /// W60-FIX P2: `list_inbox` and the Gmail sent source read every added
    /// account, enabled or not, so the mail answer counts every one. P3: a
    /// host is named once.
    func testEveryAddedMailAccountCounts() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Chat/PrivacyAsk+Kinds.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("enabledAccounts"))
        XCTAssertTrue(src.contains("EmailAccountStore.shared.accounts"))
        let same = reply(.mail, access: .allowed, route: .thisMac(model: "Grux Local"),
                                        mailHosts: ["imap.gmail.com", "imap.gmail.com"])
        XCTAssertFalse(same.contains("imap.gmail.com and imap.gmail.com"), same)
        XCTAssertTrue(same.contains("(imap.gmail.com)"), same)
    }

    /// W60-FIX round 2 P2: replies read aloud in the ElevenLabs voice carry
    /// what Grux read, so the kind answer names every send the whole-chat
    /// answer names: it is built on that answer, never on a list of its own.
    func testTheKindAnswerCarriesEverySendTheWholeChatAnswerNames() throws {
        for kind in [PrivacyAsk.Kind.calendar, .contacts, .mail, .messages] {
            let r = reply(kind, access: .allowed, route: .thisMac(model: "Grux Local"),
                          mailHosts: ["imap.gmail.com"], hostedVoice: true)
            XCTAssertTrue(r.contains("ElevenLabs"), r)
            let chat = PrivacyAsk.reply(route: .anthropic, searchReady: true, decisionsKey: true, updateCheckOn: true,
                                        hostedVoice: true, memoryMirrorHost: "mini.local", backgroundRoute: nil)
            let full = PrivacyAsk.kindReply(kind, access: .allowed, chat: chat, mailHosts: ["imap.gmail.com"])
            XCTAssertTrue(full.hasSuffix(chat), full)
        }
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Chat/PrivacyAsk+Kinds.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("chat: reply(state: state)"))
    }

    /// Permissions as macOS reports them.
    func testThePermissionMapping() {
        XCTAssertEqual(PrivacyAsk.access(calendar: .fullAccess), .allowed)
        XCTAssertEqual(PrivacyAsk.access(calendar: .writeOnly), .denied)
        XCTAssertEqual(PrivacyAsk.access(calendar: .denied), .denied)
        XCTAssertEqual(PrivacyAsk.access(calendar: .restricted), .denied)
        XCTAssertEqual(PrivacyAsk.access(calendar: .notDetermined), .notAsked)
        XCTAssertEqual(PrivacyAsk.access(contacts: .authorized), .allowed)
        XCTAssertEqual(PrivacyAsk.access(contacts: .denied), .denied)
        XCTAssertEqual(PrivacyAsk.access(contacts: .notDetermined), .notAsked)
        XCTAssertEqual(PrivacyAsk.access(messages: .ready), .allowed)
        XCTAssertEqual(PrivacyAsk.access(messages: .needsFullDiskAccess), .denied)
        XCTAssertEqual(PrivacyAsk.access(messages: .noData), .nothing)
        XCTAssertEqual(PrivacyAsk.access(messages: nil), .notAsked)
        XCTAssertEqual(PrivacyAsk.access(messages: .unknown), .notAsked)
    }

    /// The Messages answer probes chat.db when asked: the corpus coordinator's
    /// statuses are a snapshot saved at the last Jax HQ visit, so Full Disk
    /// Access given since would still read "cannot".
    func testMessagesAccessIsProbedWhenAsked() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Chat/PrivacyAsk+Kinds.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("CorpusCoordinator.shared.statuses"))
        XCTAssertTrue(src.contains("IMessageIngester.probe(dbPath: IMessageIngester.defaultDBPath)"))
        XCTAssertEqual(IMessageIngester.probe(dbPath: "/nonexistent/chat.db"), .noData)
        let notADB = FileManager.default.temporaryDirectory.appendingPathComponent("d182-\(UUID().uuidString).db")
        try Data("not sqlite".utf8).write(to: notADB)
        defer { try? FileManager.default.removeItem(at: notADB) }
        XCTAssertEqual(IMessageIngester.probe(dbPath: notADB.path), .needsFullDiskAccess)
    }

    /// Order in send(): before the readiness guard, so it answers with no model.
    func testTheKindAskSitsBeforeTheReadinessGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let kind = try XCTUnwrap(src.range(of: "PrivacyAsk.kind(of: trimmed)"))
        let readiness = try XCTUnwrap(src.range(of: "let readiness = ChatReadiness.current()"))
        XCTAssertTrue(kind.lowerBound < readiness.lowerBound)
    }
}
