import Foundation

/// "Does anything I type leave my Mac?" (D177), answered from where chat
/// really routes, with no model. Sense pass 22 measured Grux Local 2B's
/// answer: "Nothing you type leaves your Mac unless you save it to the
/// system.", a guess that is false on a Mac whose chat goes to a cloud key,
/// a model server on another machine, or a web search. A person decides what
/// to type from this answer, so every line is read from the router and the
/// switches that send something.
enum PrivacyAsk {
    /// Where a chat turn goes right now.
    enum Route: Equatable {
        case thisMac(model: String)
        /// A local route whose server is not on this Mac (a LAN or Tailscale Ollama).
        case otherMachine(model: String, host: String)
        case anthropic
        case custom(name: String, host: String)
        /// Chat cannot send; the step that lets it, from `CapabilityAsk.chatStep`.
        case none(step: String?)
    }

    static let leadIns: Set<String> = ["hi", "hey", "hello", "yo", "grux", "ok", "okay", "so", "and", "there"]
    /// What is typed, as a person names it. Not what is said aloud: the wake
    /// word's own route (Apple's speech recognition) is not this answer's.
    private static let typed = ["anything i type", "what i type", "anything i write", "what i write",
                                "what i tell you", "anything i tell you",
                                "my messages", "my chats", "my data",
                                "my conversations", "my info", "my information", "anything"]
    /// Asks about Grux itself, whatever came before them.
    private static let asks: Set<String> = {
        var out: Set<String> = [
            "what leaves my mac", "is grux private", "are you private", "is anything sent to the cloud",
            "what do you send to the cloud", "what gets sent to the cloud", "do you send anything to the cloud",
            "are you running locally", "do you run locally", "are you running on my mac", "do you run on my mac",
            "does grux run on my mac", "does grux run locally", "how private is grux", "how private are you",
            "do you send anything anywhere", "what do you send anywhere",
        ]
        for s in typed {
            for form in ["does \(s) leave my mac", "do \(s) leave my mac", "is \(s) sent to the cloud",
                         "are \(s) sent to the cloud", "is \(s) sent anywhere", "are \(s) sent anywhere",
                         "is \(s) private", "are \(s) private", "where do \(s) go",
                         "do you send \(s) to the cloud", "do you send \(s) anywhere"] {
                out.insert(form)
            }
        }
        // W59-FIX P3: "Who can read my messages?" asks about mail or iMessage,
        // "Where does anything go?" about nothing: only typed text here.
        for s in ["what i type", "anything i type", "what i write", "anything i write",
                  "what i tell you", "anything i tell you"] {
            out.formUnion(["who can see \(s)", "who can read \(s)", "where does \(s) go"])
        }
        out.formUnion(["where does my data go", "where does my info go", "where does my information go"])
        // "Is anything private?" asks nothing about Grux.
        out.remove("is anything private")
        return out
    }()
    /// Where the typing happens, said after what is typed: "what I type here",
    /// "my chats with you", "what I write in this chat" name chat, so the ask
    /// is the same one (D204). Longest first, so "in here" goes before "here".
    private static let places = ["in this chat", "in the chat", "in here", "in chat", "into chat", "in grux",
                                 "into grux", "to grux", "with grux", "to you", "with you", "here"]

    /// The sentence with a place after what is typed taken out.
    static func unplaced(_ said: String) -> String {
        var s = " \(said) "
        for t in typed where t != "anything" {
            for place in places {
                s = s.replacingOccurrences(of: " \(t) \(place) ", with: " \(t) ")
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Asks that name "this": in a conversation "this" is what was just said
    /// ("Is this private?" after pasting a letter), so they are this ask only
    /// in a chat whose every earlier message was an opening.
    private static let openingAsks: Set<String> = [
        "is this private", "is this local", "does this run on my mac", "does this run locally",
        "is this running locally", "is this running on my mac", "how private is this",
    ]

    /// Whether the message is the ask, after a greeting or "Grux," and before
    /// a closing "Grux", read sentence by sentence: one sentence asks, every
    /// other one is only a greeting. "Is my calendar private?" and a second
    /// ask beside it ("Also add milk to my list.") stay with the model.
    static func matches(_ text: String, earlier: [String] = []) -> Bool {
        var asked = false, opening = false
        let normal = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        for sentence in normal.split(whereSeparator: { ".!?\n".contains($0) }) {
            var words = sentence.split { !$0.isLetter && $0 != "'" }.map(String.init)
            while let first = words.first, leadIns.contains(first) { words.removeFirst() }
            if words.last == "grux" { words.removeLast() }
            guard !words.isEmpty else { continue }
            let said = unplaced(machine(words.joined(separator: " ")))
            if asks.contains(said) { asked = true }
            else if openingAsks.contains(said) { opening = true }
            else { return false }
        }
        if asked { return true }
        return opening && earlier.allSatisfy { CapabilityAsk.isOpening($0) || matches($0) }
    }

    /// "my computer", "this Mac" and "my laptop" are all "my mac".
    static func machine(_ s: String) -> String {
        var s = " \(s) "
        for name in ["my computer", "this computer", "my laptop", "this laptop", "this mac", "the mac",
                     "my macbook", "this macbook"] {
            s = s.replacingOccurrences(of: " \(name) ", with: " my mac ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The route from the router's own answers: `canSend` is
    /// `ChatReadiness.canSend`, `resolved` is `ModelRegistry.resolvedProvider`,
    /// and `pin` is the active chat preset's provider (`presetApp?.providerOverride`),
    /// which `ChatService` hands `resolvedRouting` and which wins (W59-FIX P1).
    /// A custom endpoint on this Mac (LM Studio on localhost) is this Mac's.
    static func route(canSend: Bool, pin: String?, resolved: ActiveProvider, localBaseURL: String, model: String,
                      endpoint: (name: String, baseURL: String)?, step: String?, cloudModel: Bool = false) -> Route {
        guard canSend else { return .none(step: step) }
        func local(_ base: String, _ name: String) -> Route {
            if cloudModel { return .otherMachine(model: name, host: "Ollama's cloud") }
            return LocalTurn.isLoopback(baseURL: base)
                ? .thisMac(model: name)
                : .otherMachine(model: name, host: ModelRates.host(fromBaseURL: base))
        }
        switch pin {
        case "anthropic": return .anthropic
        case "local": return local(localBaseURL, model)
        default: break
        }
        switch resolved {
        case .anthropic:
            return .anthropic
        case .local:
            return local(localBaseURL, model)
        case .custom:
            guard let endpoint else { return .anthropic }
            return LocalTurn.isLoopback(baseURL: endpoint.baseURL)
                ? .thisMac(model: endpoint.name)
                : .custom(name: endpoint.name, host: ModelRates.host(fromBaseURL: endpoint.baseURL))
        }
    }

    /// An Ollama cloud model ("gpt-oss:120b-cloud", "kimi-k2:cloud"): served
    /// through the local Ollama but run at Ollama (W59-FIX round 2 P3).
    static func isCloudModel(_ id: String) -> Bool {
        let t = id.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasSuffix("-cloud") || t.hasSuffix(":cloud")
    }

    /// The reply. `searchReady` is `WebResearch.blocker == nil`, with a key not
    /// read yet counted as there; `decisionsKey` is a stored TypeSafe key
    /// (`DecisionEngine` sends to Jev only with one), nil while not read yet:
    /// the answer names a send that may happen rather than leave one out
    /// (W59-FIX P2). `hostedVoice`: replies read aloud in the ElevenLabs voice;
    /// `memoryMirrorHost`: the companion store memories are copied to.
    static func reply(route: Route, searchReady: Bool, decisionsKey: Bool?, updateCheckOn: Bool,
                      hostedVoice: Bool = false, memoryMirrorHost: String? = nil, backgroundRoute: Route? = nil) -> String {
        var out: String
        switch route {
        case .thisMac(let model):
            out = "What you type in chat goes to \(model), the model running on this Mac, so a chat turn does not leave this Mac."
        case .otherMachine(let model, let host):
            out = "What you type in chat goes to \(model) on \(host), the model server Grux is set to use, so it leaves this Mac for that machine."
        case .anthropic:
            out = "What you type in chat leaves this Mac: it goes to Anthropic, where Claude answers it, with the conversation so far and what Grux looks up to answer."
        case .custom(let name, let host):
            out = "What you type in chat leaves this Mac: it goes to \(name) (\(host)), the endpoint chat is set to use, with the conversation so far and what Grux looks up to answer."
        case .none(let step):
            out = "Right now chat has no model, so what you type in chat goes nowhere."
            if let step { out += " " + step }
        }
        // A chat preset pins chat, but thread titles, summaries of long chats
        // and web answers go by the route (`AppState.chatBackgroundRouting`,
        // W59-FIX round 9).
        if let background = backgroundRoute, background != route {
            // Web answers only while a web search can run (round 10 P3).
            let jobs = searchReady
                ? " Thread titles, short summaries of long chats and web search answers are written"
                : " Thread titles and short summaries of long chats are written"
            switch background {
            case .anthropic:
                out += jobs + " by Claude, so your conversation also goes to Anthropic."
            case .custom(let name, let host):
                out += jobs + " by \(name) (\(host)), so your conversation also goes there."
            case .otherMachine(let model, let host):
                out += jobs + " by \(model) on \(host), so your conversation also goes to that machine."
            case .thisMac, .none:
                break
            }
        }
        out += " A weather or time question sends only the place name to Open-Meteo, a free weather service"
        out += searchReady ? ", and a web search sends your search words to Brave Search." : "."
        switch decisionsKey {
        case true?:
            out += " Your Decisions key also sends short parts of what you ask Grux to do to TypeSafe's Jev, to judge what you meant."
        case nil:
            out += " If a Decisions key is set, it also sends short parts of what you ask Grux to do to TypeSafe's Jev, to judge what you meant."
        case false?:
            break
        }
        if hostedVoice {
            out += " Replies read aloud in the ElevenLabs voice send their words to ElevenLabs."
        }
        out += updateCheckOn
            ? " Once a day Grux asks GitHub's public release page whether a newer Grux AI exists; that carries nothing about you."
            : " The update check is off, so Grux does not look for new versions."
        out += " Your chats, notes and memories are kept on this Mac"
        out += memoryMirrorHost.map { ", and Grux also copies memories and what it indexes to \($0), where memory searches go too." } ?? "."
        return out
    }

    /// The route a chat turn takes now, and the route the background jobs
    /// take when a chat preset pins chat elsewhere (nil with no pin).
    @MainActor
    static func routes(state: AppState) -> (route: Route, background: Route?) {
        let registry = ModelRegistry.shared
        let readiness = ChatReadiness.current()
        let pin = PresetStore.shared.activeChatApplication()?.providerOverride
        var endpoint: (name: String, baseURL: String)?
        if case .custom(let id) = registry.resolvedProvider, let ep = CustomEndpointStore.shared.endpoint(id: id) {
            endpoint = (ep.name, ep.baseURL)
        }
        // A local pin answers on the offline model, as `resolvedRouting` does.
        let modelId = pin == "local" ? state.config.offlineLLMModel : registry.modelId()
        let route = route(canSend: readiness.canSend, pin: pin, resolved: registry.resolvedProvider,
                          localBaseURL: state.config.ollamaBaseURL,
                          model: ComposerFooter.displayName(id: modelId, registryName: nil),
                          endpoint: endpoint, step: CapabilityAsk.chatStep(for: readiness),
                          cloudModel: isCloudModel(modelId))
        // What the background jobs use: the route with no preset pin.
        let background = pin == nil ? nil : Self.route(
            canSend: readiness.canSend, pin: nil, resolved: registry.resolvedProvider,
            localBaseURL: state.config.ollamaBaseURL,
            model: ComposerFooter.displayName(id: registry.modelId(), registryName: nil),
            endpoint: endpoint, step: nil, cloudModel: isCloudModel(registry.modelId()))
        return (route, background)
    }

    /// The companion store memories and what Grux indexes are copied to, when
    /// it is not on this Mac.
    static func mirrorHost() -> String? {
        let mirror = (UserDefaults.standard.string(forKey: RAGClient.baseURLDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return mirror.isEmpty || LocalTurn.isLoopback(baseURL: mirror) ? nil : ModelRates.host(fromBaseURL: mirror)
    }

    @MainActor
    static func reply(state: AppState) -> String {
        let routes = routes(state: state)
        // nil: not read yet (`getWithoutWaiting`), never a dialog.
        let stored: (KeychainStore.Key) -> Bool? = { key in
            KeychainStore.getWithoutWaiting(key).map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return reply(route: routes.route,
                     searchReady: WebResearch.blocker(offline: state.offlineMode,
                                                      enabled: state.config.webResearchEnabled,
                                                      hasSearchKey: stored(.braveApiKey) ?? true) == nil,
                     decisionsKey: stored(.typesafeApiKey),
                     updateCheckOn: state.config.updateCheckEnabled,
                     hostedVoice: state.config.speakRepliesAloud
                        && SpeechEngine.usesElevenLabs(choice: state.config.useElevenLabs,
                                                       hasKey: stored(.elevenLabsApiKey) ?? KeychainStore.exists(.elevenLabsApiKey),
                                                       offline: state.offlineMode),
                     memoryMirrorHost: mirrorHost(),
                     backgroundRoute: routes.background)
    }
}

/// D199 (sense pass 28): Settings, Persistent memory said "No data leaves your
/// Mac." while every chat turn carries the memories that best match the message
/// (`ChatService`, RELEVANT_MEMORIES) to the chat route, and a memory mirror
/// copies them to its host. The caption now says where they go on this setup,
/// from the same route and mirror the privacy answer reads.
enum MemoryPrivacyCaption {
    static func line(route: PrivacyAsk.Route, memoryMirrorHost: String?, memoryOn: Bool) -> String {
        var out = "Grux keeps memories on this Mac and finds them with Apple's on-device embeddings."
        let few = "the few that best match your message"
        if !memoryOn {
            // Memory off stops only RELEVANT_MEMORIES in `ChatService`. Long term
            // facts and slang, the remember-this inbox, recent ambient memories,
            // person cards, Focus lines and the memory tools still reach the
            // chat model, so the rest is named by example, not as a full list
            // (W69-FIX rounds 2 and 3).
            out += " Memory is off, so chat stops adding the memories that best match your message."
                + " Other things Grux keeps about you, such as facts you told it to remember and what Ambient heard lately,"
                + " can still go with a turn"
            switch route {
            case .thisMac(let model): out += ", to \(model) on this Mac."
            case .otherMachine(let model, let host): out += ", to \(model) on \(host), off this Mac."
            case .anthropic: out += ", to Anthropic, off this Mac."
            case .custom(let name, let host): out += ", to \(name) (\(host)), off this Mac."
            case .none: out += "."
            }
        } else {
            switch route {
            case .thisMac(let model):
                // A mirror copies them off this Mac, so they do not stay here.
                out += " Each chat turn gives \(few) to \(model) on this Mac"
                out += memoryMirrorHost == nil ? ", so they stay here." : "."
            case .otherMachine(let model, let host):
                out += " Each chat turn sends \(few) to \(model) on \(host), so those leave this Mac for that machine."
            case .anthropic:
                out += " Each chat turn sends \(few) to Anthropic with it, so those leave this Mac."
            case .custom(let name, let host):
                out += " Each chat turn sends \(few) to \(name) (\(host)) with it, so those leave this Mac."
            case .none:
                out += " Chat has no model yet; once it has one, each turn gives that model \(few)."
            }
        }
        if let host = memoryMirrorHost {
            out += " Grux also copies memories to \(host), where memory searches go too."
        }
        return out
    }
}
