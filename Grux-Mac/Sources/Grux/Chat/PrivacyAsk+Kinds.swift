import Contacts
import EventKit
import Foundation

/// "Is my calendar private?" and "Who can read my messages?" (D182): Grux
/// Local 2B answered "Your calendar is private. I don't have access to your
/// events." on a Mac where Grux could read it. The answer is Grux's own: whether
/// it reads that kind, from the permission or setup that lets it, and where
/// what it reads goes, from the same route the whole-chat answer uses.
extension PrivacyAsk {
    enum Kind: Equatable { case calendar, contacts, mail, messages }

    /// Whether Grux can read a kind now. `nothing`: no mail account added, or
    /// no Messages on this Mac.
    enum Access: Equatable { case allowed, denied, notAsked, nothing }

    /// The kind as a person names it.
    private static let kindNames: [(String, Kind)] = [
        ("my calendar events", .calendar), ("my calendar", .calendar), ("my events", .calendar),
        ("my schedule", .calendar), ("my contacts", .contacts), ("my address book", .contacts),
        ("my emails", .mail), ("my email", .mail), ("my mail", .mail), ("my inbox", .mail),
        ("my text messages", .messages), ("my imessages", .messages), ("my texts", .messages),
        ("my messages", .messages),
    ]
    /// Privacy asks only: "Can you read my email?" and "Can you see my calendar?"
    /// ask Grux to do it, so they stay with the model.
    private static let kindForms = [
        "is X private", "are X private", "how private is X", "how private are X",
        "who can see X", "who can read X", "does grux read X", "do you read X",
        "does X leave my mac", "do X leave my mac", "is X sent to the cloud", "are X sent to the cloud",
        "is X sent anywhere", "are X sent anywhere", "where does X go", "where do X go",
        "do you send X anywhere", "do you send X to the cloud",
    ]
    private static let kindAsks: [String: Kind] = {
        var out: [String: Kind] = [:]
        for (name, kind) in kindNames {
            for form in kindForms { out[form.replacingOccurrences(of: "X", with: name)] = kind }
        }
        return out
    }()

    /// The kind the whole message asks about, read sentence by sentence as
    /// `matches` reads: one sentence asks, every other one is only a greeting.
    /// nil for the whole-chat ask ("Do my messages leave this Mac?" is about
    /// what is typed), which `matches` answers first.
    static func kind(of text: String) -> Kind? {
        guard !matches(text) else { return nil }
        var found: Kind?
        let normal = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for sentence in normal.split(whereSeparator: { ".!?\n".contains($0) }) {
            var words = sentence.split { !$0.isLetter && $0 != "'" }.map(String.init)
            while let first = words.first, leadIns.contains(first) { words.removeFirst() }
            if words.last == "grux" { words.removeLast() }
            guard !words.isEmpty else { continue }
            guard let kind = kindAsks[machine(words.joined(separator: " "))], found == nil || found == kind else {
                return nil
            }
            found = kind
        }
        return found
    }

    static func access(calendar status: EKAuthorizationStatus) -> Access {
        switch status {
        case .fullAccess, .authorized: return .allowed
        case .notDetermined: return .notAsked
        // Write-only access cannot read; restricted is a manager's switch.
        default: return .denied
        }
    }

    static func access(contacts status: CNAuthorizationStatus) -> Access {
        switch status {
        case .authorized, .limited: return .allowed
        case .notDetermined: return .notAsked
        default: return .denied
        }
    }

    /// From the iMessage source's probe; nil or unknown: not probed yet, so the
    /// answer says what it takes rather than guess.
    static func access(messages permission: CorpusPermission?) -> Access {
        switch permission {
        case .ready?: return .allowed
        case .needsFullDiskAccess?: return .denied
        case .noData?: return .nothing
        default: return .notAsked
        }
    }

    /// The kind's access line, then, when Grux reads it or may, the whole-chat
    /// answer (`chat`, from `reply(state:)`): what Grux reads joins the chat and
    /// goes wherever the chat goes. Built on that answer and never on a list
    /// of its own, because a list here missed the memory mirror, then the
    /// ElevenLabs voice (W60-FIX rounds 1 and 2).
    static func kindReply(_ kind: Kind, access: Access, chat: String, mailHosts: [String] = []) -> String {
        var out: String
        switch (kind, access) {
        case (.calendar, .allowed):
            out = "Grux can read your calendar: macOS allows it for Grux AI (System Settings, Privacy & Security, Calendars)."
        case (.calendar, .notAsked):
            out = "Grux has not read your calendar: macOS asks you the first time Grux needs it, and nothing is read before you say yes."
        case (.calendar, _):
            return "Grux cannot read your calendar: macOS does not allow it for Grux AI (System Settings, Privacy & Security, Calendars), so nothing from it goes anywhere."
        case (.contacts, .allowed):
            out = "Grux can read your contacts: macOS allows it for Grux AI (System Settings, Privacy & Security, Contacts)."
        case (.contacts, .notAsked):
            out = "Grux has not read your contacts: macOS asks you the first time Grux needs them, and nothing is read before you say yes."
        case (.contacts, _):
            return "Grux cannot read your contacts: macOS does not allow it for Grux AI (System Settings, Privacy & Security, Contacts), so nothing from them goes anywhere."
        case (.mail, .allowed) where !mailHosts.isEmpty:
            // A host named once (W60-FIX P3), in the order added.
            var seen = Set<String>()
            let unique = mailHosts.filter { seen.insert($0.lowercased()).inserted }
            let hosts = unique.count == 1 ? unique[0]
                : unique.dropLast().joined(separator: ", ") + " and " + unique[unique.count - 1]
            out = "Grux reads mail from the \(mailHosts.count == 1 ? "account" : "accounts") you added in Mail (\(hosts)): it copies your mail to this Mac, and your mail provider keeps it as before."
        case (.mail, _):
            return "There is no mail account in Mail yet, so Grux syncs no mail."
        case (.messages, .allowed):
            out = "Grux can read the messages you sent in Messages, never the ones you received, because it has Full Disk Access; it reads them to learn how you write."
        case (.messages, .notAsked):
            out = "Grux reads your Messages only with Full Disk Access (System Settings, Privacy & Security), and then only the ones you sent, to learn how you write."
        case (.messages, .denied):
            return "Grux cannot read your Messages: it has no Full Disk Access, so nothing from them goes anywhere."
        case (.messages, .nothing):
            return "There are no Messages on this Mac for Grux to read."
        }
        let them = kind == .contacts || kind == .messages ? "them" : "it"
        return out + " What Grux reads from \(them) can join your chat and goes wherever your chat goes. " + chat
    }

    @MainActor
    static func kindReply(_ kind: Kind, state: AppState) -> String {
        let access: Access
        var hosts: [String] = []
        switch kind {
        case .calendar: access = Self.access(calendar: CalendarAsk.access())
        case .contacts: access = Self.access(contacts: CNContactStore.authorizationStatus(for: .contacts))
        case .mail:
            // Every added account, enabled or not: `list_inbox` and the Gmail
            // sent source read them all (W60-FIX P2).
            hosts = EmailAccountStore.shared.accounts.map(\.imapHost)
            access = hosts.isEmpty ? .nothing : .allowed
        case .messages: access = Self.access(messages: IMessageIngester.probe(dbPath: IMessageIngester.defaultDBPath))
        }
        return kindReply(kind, access: access, chat: reply(state: state), mailHosts: hosts)
    }
}
