import Foundation

/// What a chat turn on a LOCAL model looks like: a window the Mac can hold,
/// and a prompt that fits in it.
///
/// Measured on the W4 clean VM (8 GB, Llama 3.2 3B, 2026-10-13): the first
/// reply took 329 s behind "grux is thinking". The turn asked for a 32768
/// token window, which on 8 GB is a KV cache the machine does not have, and
/// sent about 15,000 tokens: a 27,700 character system prompt and 57 tool
/// schemas (30,000 characters) for "what is on my plate today?". And the
/// thread's auto-title call queued ahead of it on the one local model.
///
/// So a local turn gets a window by memory, a lean system prompt (who Grux is
/// and its rules, not the cloud model's tool manual), a shorter reply budget,
/// and either one stable list of tools, the same every turn so Ollama reuses
/// what it read (`stableHead`), or, when the message asks for more, the tools
/// that fit, ranked by what was asked.
enum LocalTurn {

    /// The window every call to an Ollama server asks for, by this Mac's
    /// memory. One number per machine, because Ollama reloads a model whenever
    /// a call asks for a different window than the loaded one.
    static func contextTokens(memoryGB: Double) -> Int {
        switch memoryGB {
        case ..<12: return 8_192
        case ..<24: return 16_384
        default: return 32_768
        }
    }

    static let contextTokens = contextTokens(memoryGB: HardwareProfile.detect().physicalMemoryGB)

    /// Whether the server at `baseURL` is this Mac, so this Mac's memory is
    /// the one that matters: localhost, 127.0.0.0/8 or ::1.
    static func isLoopback(baseURL: String) -> Bool {
        let host = ModelRates.host(fromBaseURL: baseURL)
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" { return true }
        let octets = host.split(separator: ".")
        return octets.count == 4 && octets.first == "127" && octets.allSatisfy { UInt8($0) != nil }
    }

    /// One line naming the tools a local turn left out, so a request that
    /// needs one is told why rather than answered vaguely (PR 40 review).
    /// Names only, nil when nothing was left out.
    static func cutToolsLine(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "TOOLS NOT OFFERED IN THIS LOCAL TURN: \(names.joined(separator: ", ")). "
            + "If the request needs one of these, say plainly that it cannot be done in this local turn, "
            + "and that a bigger local model or a cloud key in Settings, Models enables it."
    }

    /// The most a local chat turn sends, whatever the window. Time to first
    /// word on a local model is the prompt's length: measured on a 16 GB Mac
    /// mini (qwen2.5:7b), about 18,000 tokens took 131 s and about 14,000
    /// took 89 s. A bigger window is room, not a reason to fill it.
    static let promptCeiling = 8_192

    /// How long Ollama keeps a local model loaded after a call. Its default is
    /// 5 minutes, and unloading throws away the prompt it already read, so
    /// the next two turns read every tool again: measured 2026-10-24 on a
    /// MacBook Pro, 8.3 to 14.7 s for the first two turns after every unload
    /// against about 1 s warm. Grux unloads sooner itself on critical memory
    /// pressure and on quit (LocalModelUnload).
    static let keepAlive = "30m"

    /// Reply budget on a local model. The cloud turn allows 2000.
    static let replyTokens = 1_024

    /// Characters to tokens for a budget, on the safe side: local tokenizers
    /// run about 3.5 characters a token on this prompt.
    static func tokens(chars: Int) -> Int { (chars * 2 + 6) / 7 }

    /// The cloud prompt's tool manual starts here. A local turn keeps what is
    /// above it (persona, name, voice, the trust boundary) and drops the rest.
    static let leanCut = "TOOL USE - READ CAREFULLY"

    static let toolNote = """
    TOOLS: call a tool only when the user asks for something it does (a task, an event, a note, a search). Otherwise answer directly, in one to three sentences.
    """

    /// The lean system prompt: the stable prompt up to its tool manual, the
    /// tool note, then `tail` (who the user is and what Grux can do).
    static func leanStable(_ stable: String, tail: [String]) -> String {
        let head = stable.range(of: leanCut).map { String(stable[..<$0.lowerBound]) } ?? stable
        let parts = [head.trimmingCharacters(in: .whitespacesAndNewlines), toolNote] + tail
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The tools a person asks for most, offered first when nothing in the
    /// message points elsewhere.
    static let everyday = ["list_tasks", "add_task", "complete_task", "list_events", "create_event",
                           "search_web", "capture_memory", "open_app"]

    /// The words of a message that `rank` matches: lowercased, split on
    /// anything not a letter or number, four characters or more.
    static func words(_ utterance: String) -> Set<String> {
        Set(utterance.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 })
    }

    /// How many of `words` a tool's name or description holds.
    static func score(_ t: ClaudeTool, words: Set<String>) -> Int {
        let text = (t.name.replacingOccurrences(of: "_", with: " ") + " " + t.description).lowercased()
        return words.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }

    /// Tools by how much the message is about them: words of the message found
    /// in a tool's name or description, then the everyday ones, then the rest
    /// in their usual order. Deterministic, so the same message gets the same tools.
    static func rank(_ tools: [ClaudeTool], utterance: String) -> [ClaudeTool] {
        let words = Self.words(utterance)
        return tools.enumerated().sorted { a, b in
            let sa = score(a.element, words: words), sb = score(b.element, words: words)
            if sa != sb { return sa > sb }
            let ea = everyday.firstIndex(of: a.element.name) ?? Int.max
            let eb = everyday.firstIndex(of: b.element.name) ?? Int.max
            if ea != eb { return ea < eb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The tools a local turn offers turn after turn, in an order no message
    /// changes. Ollama reuses the prompt it read last only up to the first
    /// token that differs, and the tools open the prompt, so a list ranked per
    /// message makes every turn read its tools again. Measured 2026-10-24 on a
    /// MacBook Pro (Ollama 0.40.8, grux-local:4b, the 265 chat turns of
    /// held-out v2): 8.54 s a turn at the median with the ranked list and
    /// 1.1 s with one list for every turn, with 201 passes against 198.
    /// `stableHead` leads it, then the core tools in their usual order.
    static let stableHead = everyday + ["set_mode", "create_note", "remember_fact", "remove_task"]

    /// Room the stable list leaves for what changes every turn (the turn's own
    /// block and the newest message), so neither changes how many tools it
    /// holds. A turn that needs more takes the ranked list.
    static let turnReserveChars = 2_700

    /// A message points past the stable list when a tool outside it holds at
    /// least this many of the message's words and more than any tool inside.
    static let pointsPastScore = 3

    /// Or when a tool from a group the message's words switched on (meetings,
    /// screen, research and the rest, ToolRelevance) holds at least this many
    /// and no fewer than any tool inside: "record a meeting" is two words, and
    /// the list holds core tools only.
    static let groupPointsPastScore = 2

    /// Function words only: verbs like make, know, tell, want and need stay,
    /// because tool descriptions use them ("make a folder", "what skills do
    /// you know"). Words that say nothing about a tool, so they never count toward
    /// pointing past the list. Measured 2026-10-25 on held-out v2: "with" gave
    /// a research tool 3 of "done with the expense report, mark it complete",
    /// and "about" a work-log tool 3 of "complete the task about the
    /// watercolor class", and both turns read every tool again. Filtering
    /// these took the ranked turns from 56 to 37 of 265. `rank` is unchanged.
    static let fillerWords: Set<String> = [
        "about", "above", "after", "again", "also", "been", "before", "being", "both", "could", "does", "doing",
        "down", "each", "from", "have", "having", "here", "into", "just", "more", "most", "much", "only",
        "other", "over", "please", "same", "should", "some", "such", "than", "that", "their", "them", "then",
        "there", "these", "they", "this", "those", "through", "under", "until", "very", "were", "what",
        "when", "where", "which", "while", "with", "would", "your", "yours", "okay", "thanks", "thank",
        "anything", "something",
    ]

    /// `tools` with `stableHead` first, then the rest in their usual order.
    static func stableOrder(_ tools: [ClaudeTool]) -> [ClaudeTool] {
        tools.enumerated().sorted { a, b in
            let ha = stableHead.firstIndex(of: a.element.name) ?? Int.max
            let hb = stableHead.firstIndex(of: b.element.name) ?? Int.max
            if ha != hb { return ha < hb }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The stable list: `core` in the stable order, as many as fit beside the
    /// system text it is given, the longest cut line and the turn reserve.
    /// Nothing about the turn goes in. The system text is counted in whole
    /// 2,000 character steps, so a fact the profile gains moves the list only
    /// when it crosses a step; the list changes when the persona block, the
    /// features or the tool catalogue (MCP) change, never from turn to turn.
    static func stableTools(core: [ClaudeTool], cachedSystemChars: Int, longestCutLineChars: Int,
                            window: Int) -> [ClaudeTool] {
        let ordered = stableOrder(core)
        let stepped = (cachedSystemChars / 2_000 + 1) * 2_000
        let fit = Self.fit(systemChars: stepped + longestCutLineChars + turnReserveChars, messageChars: [],
                      toolChars: ordered.map { Self.chars($0) }, window: window)
        return Array(ordered.prefix(fit.tools))
    }

    /// Whether the message is about a tool the stable list does not hold, so
    /// the turn should take the ranked list instead. `candidates` are the
    /// tools ToolRelevance kept for this turn. Filler words do not count, and
    /// a group tool that only ties the list's best does not point past it when
    /// an everyday tool is among those tied ("mark the expense report
    /// complete" is complete_task's); a tie with only other tools goes to the
    /// group's tool ("read my screen").
    /// With both, 35 of held-out v2's 265 chat turns take the ranked list.
    static func pointsPast(_ stable: [ClaudeTool], candidates: [ClaudeTool], utterance: String) -> Bool {
        let words = Self.words(utterance).subtracting(fillerWords)
        let inside = Set(stable.map(\.name))
        let scores = stable.map { (name: $0.name, score: score($0, words: words)) }
        let best = scores.map(\.score).max() ?? 0
        let everydayLeads = best > 0 && scores.contains { $0.score == best && everyday.contains($0.name) }
        return candidates.contains { t in
            guard !inside.contains(t.name) else { return false }
            let s = score(t, words: words)
            if s >= pointsPastScore && s > best { return true }
            guard ToolRelevance.group(for: t.name) != .core, s >= groupPointsPastScore else { return false }
            return s > best || (s == best && !everydayLeads)
        }
    }

    /// How many of the newest messages fit beside a fixed tool list: the
    /// newest always, then older ones while they fit.
    static func messagesThatFit(systemChars: Int, messageChars: [Int], toolTokens: Int,
                                window: Int, reply: Int = replyTokens) -> Int {
        guard let newest = messageChars.last else { return 0 }
        var budget = window - reply - 256 - tokens(chars: systemChars) - toolTokens - tokens(chars: newest)
        var messages = 1
        for chars in messageChars.dropLast().reversed() {
            let cost = tokens(chars: chars)
            guard cost <= budget else { break }
            budget -= cost
            messages += 1
        }
        return messages
    }

    /// How many of the newest messages and of the ranked tools fit in the
    /// window beside the system prompt and the reply. The newest message
    /// always stays; then the best tools, up to half of what is left; then
    /// older history; then more tools if room remains.
    static func fit(systemChars: Int, messageChars: [Int], toolChars: [Int],
                    window: Int, reply: Int = replyTokens) -> (messages: Int, tools: Int) {
        let margin = 256
        var budget = window - reply - margin - tokens(chars: systemChars)
        var messages = 0
        var tools = 0
        if let newest = messageChars.last {
            budget -= tokens(chars: newest)
            messages = 1
        }
        func takeTools(within limit: Int) {
            var spent = 0
            while tools < toolChars.count {
                let cost = tokens(chars: toolChars[tools])
                guard cost <= budget, spent + cost <= limit else { return }
                budget -= cost
                spent += cost
                tools += 1
            }
        }
        takeTools(within: max(0, budget / 2))
        for chars in messageChars.dropLast().reversed() {
            let cost = tokens(chars: chars)
            guard cost <= budget else { break }
            budget -= cost
            messages += 1
        }
        takeTools(within: Int.max)
        return (messages, tools)
    }

    /// A tool's size on the wire, for `fit`.
    static func chars(_ t: ClaudeTool) -> Int {
        t.name.count + t.description.count + ((try? JSONSerialization.data(withJSONObject: t.inputSchema))?.count ?? 0) + 40
    }

    /// A message's size on the wire, for `fit`.
    static func chars(_ m: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: m))?.count ?? 0
    }
}

/// The line under a turn in flight: how long, and on what.
enum ChatThinkingCopy {
    /// `since` is nil when no chat turn is in flight (FocusWatcher's own
    /// calls also show the bubble), and then there is no count to give.
    static func line(since: Date?, now: Date, local: Bool) -> String {
        guard let since else { return "Thinking" }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return local ? "Thinking, \(seconds) s, local model" : "Thinking, \(seconds) s"
    }
}
