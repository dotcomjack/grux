import Foundation

/// "What can you do?" (D145), the likeliest first sentence a stranger types,
/// answered from the feature registry with no model. Sense pass 17 (3:15 AM
/// Nov 3) measured the local model's answer: 22 s, then "ambient actions like
/// music or macros if you want them promoted to the task stack", paraphrased
/// from a tool description, offering music local models are kept from, and
/// naming none of what works here. The prompt's WHAT_YOU_CAN_DO block was in
/// front of it the whole time; the answer is composed here instead, so it is
/// instant and every line is true for this Mac.
enum CapabilityAsk {
    /// Things a person can ask for in chat, each claimed only while the
    /// registry row behind it is working AND a chat turn can be sent: the
    /// model calls these tools (add_task, complete_task, list_tasks;
    /// lookup_contact, create_contact), and a row reads ready while the send
    /// path refuses (wave 44: a local model found but not routed).
    static let abilities: [(id: String, phrase: String)] = [
        ("tasks", "keep your task list"),
        ("contacts", "look up a contact"),
    ]
    /// Features named as one step away when they are not working yet, in
    /// this order; chat has its own sentence. Names only: the registry's
    /// setup steps read as commands after "needs" ("Install the agent command
    /// line tool"), and either-or needs read as both (wave 44).
    static let worthNaming = ["calendar", "mailbox", "agents", "meetings", "research"]
    /// At most this many things one step away, chat counted.
    static let maxPending = 3

    private static let leadIns: Set<String> = ["hi", "hey", "hello", "yo", "grux", "ok", "okay", "so", "and", "there"]
    private static let asks: Set<String> = [
        "what can you do",
        "what do you do", "what are you able to do", "what can grux do", "what are your capabilities",
        "what are your features", "what can i ask you", "what can i ask", "what can i do with you",
        "what else can you do",
        "tell me what you can do", "what are you capable of",
    ]
    /// D176: the first-run forms of the same question. Wave 58 round 1: in a
    /// conversation they ask about it ("Where do I start?" after "help me plan
    /// my move"), so they are this ask only beside a line saying the person is
    /// new, or in a chat whose every earlier ask was itself an opening.
    private static let firstRunAsks: Set<String> = [
        "what should i try first", "what should i try", "what should i do first", "what do i do first",
        "where do i start", "where should i start", "how do i start", "how do i get started",
        "how do i use you", "how do i use grux", "what should i ask you", "what should i ask",
        "what can i try", "what can i try first",
    ]
    /// Wave 67 round 2: help-shaped, so after "My landlord kept my whole
    /// deposit." they ask about the deposit, not about Grux: the first-run rule
    /// holds for them, unless a Mac place says it is Grux being asked about
    /// ("How can you help me on my Mac?", round 3).
    private static let helpAsks: Set<String> = [
        "how can you help", "how can you help me", "what can you do for me", "what can you do here",
        "what can you help me with", "what can you help with", "what can you help me do",
    ]
    /// D196: where or for whom, said after either ask ("What can you do on my
    /// Mac?"). One is taken off before the lookup; anything else after the ask
    /// ("on my phone", "about my Mac") is a different question.
    /// "here", "for me" and "exactly" can point at the conversation ("How can you
    /// help me here?" after a problem was described, wave 67 round 1), so after
    /// one of them the ask is taken only where the first-run rule would take it.
    private static let places = [
        "on my mac", "on this mac", "on my computer", "on this computer", "on my macbook", "on my laptop",
    ]
    private static let conversationPlaces = ["for me", "here", "exactly"]
    /// Sentences that only say the person is new, allowed beside the ask (D176).
    private static let introductions: Set<String> = [
        "i just installed you", "i just installed grux", "i just downloaded you", "i just downloaded grux",
        "i just got you", "i just set you up", "i just set up grux", "i'm new", "i'm new here", "i am new",
        "i am new here", "i'm new to grux", "nice to meet you", "thanks", "thank you", "this is my first time",
        "it's my first time", "first time here", "first time using grux",
    ]

    /// D207: asking who Grux is or how it is opens a chat as a greeting does,
    /// so "What should I try first?" after "Who are you?" is still the first-run
    /// ask (sense pass 30: the model answered it from a memory instead). Beside
    /// the ask in one message it is a second question, so it stays with the model.
    /// Every way of asking who Grux is comes from `SelfAsk.identityAsks`, the
    /// asks Grux answers itself, so a form added there opens a chat here too
    /// (W73-P3 item 3: "Who am I talking to?" was answered there, missing here).
    private static let openers: Set<String> = SelfAsk.identityAsks.union([
        "how are you", "how are you doing", "how are you doing today", "how are you today", "how's it going",
        "how is it going", "what's up", "good morning", "good afternoon", "good evening", "are you there",
    ])

    /// Whether the message is the ask, after a greeting or "Grux," and before a
    /// closing "Grux", read sentence by sentence: one sentence asks, and every
    /// other one is a greeting or says the person is new ("Hello, I just
    /// installed you. What should I try first?", D176). "What can you do about
    /// my inbox?" is a different question, and a sentence that asks for
    /// anything else ("Add milk to my list.") leaves the message with the model.
    /// `earlier` is the person's earlier messages in this chat: a first-run
    /// form with no introduction beside it is this ask only when every one of
    /// them was an opening too (`isOpening`).
    /// `name` is the assistant's own name, read as "Grux" is (W73-P3 item 1).
    static func matches(_ text: String, earlier: [String] = [], name: String = "") -> Bool {
        guard let read = read(text, name: name), !read.opener else { return false }
        if read.asked { return true }
        return read.firstRun && (read.introduced || earlier.allSatisfy { isOpening($0, name: name) })
    }

    /// A message that is only greetings, introductions or this ask. A typed
    /// message is never empty, so an empty one is an image sent alone
    /// (`earlierTurns`, `modelAsks`), which opens nothing; "👋" or ":)" is
    /// typed and still opens (wave 71 round 3 P2).
    static func isOpening(_ text: String, name: String = "") -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && read(text, name: name) != nil
    }

    /// What the message's sentences say, or nil when one says something else.
    /// A sentence with the assistant's name at its front or end is read as
    /// it is first, then without the name (`SelfAsk.withoutName`).
    private static func read(_ text: String, name: String = "")
        -> (asked: Bool, firstRun: Bool, introduced: Bool, opener: Bool)? {
        var out = (asked: false, firstRun: false, introduced: false, opener: false)
        for sentence in SelfAsk.normalized(text).split(whereSeparator: { ".!?\n".contains($0) }) {
            var words = sentence.split { !$0.isLetter && $0 != "'" }.map(String.init)
            while let first = words.first, leadIns.contains(first) { words.removeFirst() }
            if take(words, into: &out) { continue }
            guard let rest = SelfAsk.withoutName(words, name: name) else { return nil }
            var bare = rest
            while let first = bare.first, leadIns.contains(first) { bare.removeFirst() }
            if !take(bare, into: &out) { return nil }
        }
        return out
    }

    /// Reads one sentence into `out`; false when it says something else.
    private static func take(_ words: [String],
                             into out: inout (asked: Bool, firstRun: Bool, introduced: Bool, opener: Bool)) -> Bool {
        var words = words
        // A closing "please" as `SelfAsk` reads it ("Tell me about yourself, please.").
        if words.count > 1, words.last == "please" { words.removeLast() }
        let whole = words.joined(separator: " ")
        if words.last == "grux" { words.removeLast() }
        guard !words.isEmpty else { return true }
        let said = words.joined(separator: " ")
        func without(_ list: [String]) -> String? {
            list.first { said.hasSuffix(" " + $0) }.map { String(said.dropLast($0.count + 1)) }
        }
        let bare = without(places) ?? said
        let loose = without(conversationPlaces)
        if asks.contains(said) || asks.contains(bare) || (bare != said && helpAsks.contains(bare)) { out.asked = true }
        else if firstRunAsks.contains(said) || firstRunAsks.contains(bare) || helpAsks.contains(said) { out.firstRun = true }
        else if let loose, asks.contains(loose) || firstRunAsks.contains(loose) || helpAsks.contains(loose) {
            out.firstRun = true
        }
        else if openers.contains(said) || openers.contains(whole) { out.opener = true }
        else if introductions.contains(said) || introductions.contains(whole) {
            // "Thanks" and "Nice to meet you" close or greet; only these say the person is new.
            if !["thanks", "thank you", "nice to meet you"].contains(said) { out.introduced = true }
        } else { return false }
        return true
    }

    /// The sentence saying what chat needs before a turn can be sent, from
    /// the send path's own readiness, or nil when it can send.
    static func chatStep(for readiness: ChatReadiness) -> String? {
        switch readiness {
        case .ready: return nil
        case .needsModel: return "Chat needs a model first: run a local model, or add your own API key; both are in Settings."
        // One is running: it needs a switch, not a model (W44-P3).
        case .localModelFoundButNotRouted:
            return "Chat needs one switch: turn on Offline mode in Settings, Models to use the local model already running."
        // No key is promised: none may be stored (W44-P3).
        case .offlinePinnedButNoLocalModel:
            return "Chat needs your local model server: start it, or turn offline mode off in Settings, Models."
        }
    }

    /// The reply. `chatCanSend` is `ChatReadiness.canSend`, the check the send
    /// path refuses on; `calendarReadable` is the calendar fast path's own
    /// access (full access, never write only).
    static func reply(state: (String) -> FeatureState?, chatCanSend: Bool, chatStep: String?,
                      calendarReadable: Bool, label: (String) -> String?, memoryOn: Bool) -> String {
        func works(_ id: String) -> Bool { state(id) == .ready || state(id) == .degraded }
        var can = ["tell you the weather anywhere"]
        if chatCanSend { can += abilities.filter { works($0.id) }.map(\.phrase) }
        // Adding an event needs full access too (`CalendarService.createEvent`),
        // so write-only access claims nothing (W44-P3).
        if calendarReadable {
            if chatCanSend && works("calendar") {
                can.insert("read your calendar and add events", at: min(2, can.count))
            } else {
                can.append("tell you what's on your calendar")
            }
        }
        if chatCanSend && memoryOn { can.append("remember what you tell me") }
        if chatCanSend { can.append("answer questions and help you write") }
        var out = "On this Mac right now I can " + list(can) + "."
        out += calendarReadable
            ? " Try \u{201C}What's on my calendar tomorrow?\u{201D} or \u{201C}What's the weather in Boston?\u{201D}"
            : " Try \u{201C}What's the weather in Boston?\u{201D}"
        var room = maxPending
        if !chatCanSend, let chatStep {
            out += " " + chatStep
            room -= 1
        }
        let pending = worthNaming.compactMap { id -> String? in
            state(id) == .needsSetup ? label(id) : nil
        }.prefix(room)
        if !pending.isEmpty {
            // One name reads "it" (D166 item 14: "each one" after one name).
            out += " One step away: " + list(Array(pending)) + ". Settings says what "
                + (pending.count == 1 ? "it needs." : "each one needs.")
        }
        return out
    }

    @MainActor
    static func reply(memoryOn: Bool) -> String {
        let rows = Dictionary(FeatureRegistry.rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let readiness = ChatReadiness.current()
        return reply(
            state: { rows[$0].map(FeatureRegistry.state(of:)) },
            chatCanSend: readiness.canSend,
            chatStep: chatStep(for: readiness),
            calendarReadable: CalendarService.shared.hasAccess,
            label: { rows[$0]?.label },
            memoryOn: memoryOn)
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }
}
