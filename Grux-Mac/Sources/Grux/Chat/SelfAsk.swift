import Foundation

/// "Can I use a smarter model?" and "Do you work without internet?" (D189),
/// answered from Grux's own state, with no model. D186 put the facts in the
/// prompt (ABOUT_YOU), and sense pass 25 read Grux Local 2B answering from it
/// anyway: "add a new one in the Models tab" (there is none) and "I don't need
/// an internet connection to operate" (weather, web search and the update check
/// do). A prompt fact does not make a 2B model answer right, so these are
/// answered here, as the voice (D184) and privacy (D177) asks are. "Who are
/// you?" joined them (D208 item 10): the model answered "I'm Jax ... I don't
/// have a specific name".
enum SelfAsk {
    enum Kind: Equatable { case smarterModel, offline, identity }

    private static let leadIns: Set<String> = ["hi", "hey", "hello", "yo", "grux", "ok", "okay", "so", "and", "there"]
    private static let closings: Set<String> = ["grux", "please"]

    private static let smarterAsks: Set<String> = {
        var out: Set<String> = [
            "can you be smarter", "how can i make you smarter", "how do i make you smarter",
            "can i make you smarter", "can i switch models", "can i change models", "can i change the model",
            "how do i change the model", "how can i change the model", "how do i switch models",
            "how can i switch models", "can i use claude", "how do i use claude", "how can i use claude",
            "what model are you", "what model do you use", "what model are you using", "which model are you",
            "which model do you use", "which model are you using", "what model do you run on",
            "what model are you running on", "which model do you run on",
            "what's your model", "what is your model",
            "what model is chat using", "which model is chat using", "what model is chat running on",
            "what model are you running", "which model are you running",
            "what model is grux using", "which model is grux using", "what model does grux use",
            "which model does grux use", "what model is grux running on", "which model is grux running on",
        ]
        for kind in ["smarter", "better", "bigger", "different", "stronger"] {
            for form in ["can i use a \(kind) model", "how do i get a \(kind) model", "how can i get a \(kind) model",
                         "how do i use a \(kind) model", "how can i use a \(kind) model", "is there a \(kind) model",
                         "can i get a \(kind) model", "can you use a \(kind) model"] {
                out.insert(form)
            }
        }
        return out
    }()

    /// Asks that name "this": after a photo of a car or a laptop listing,
    /// "What model is this?" asks about that, so they are Grux's own only in a
    /// chat whose every earlier message was an opening (wave 71 round 1 P2).
    private static let openingAsks: Set<String> = ["what model is this", "which model is this"]

    /// Who the assistant is, and what Grux is (D208 item 10). "Who is this?"
    /// can name a photo, so it is not here. `CapabilityAsk` opens a chat on
    /// every one of these, so the two never drift (W73-P3 item 3).
    static let identityAsks: Set<String> = [
        "who are you", "what are you", "what's your name", "what is your name", "what should i call you",
        "what do i call you", "who am i talking to", "who am i talking with", "what is grux", "what's grux",
        "what is grux ai", "what's grux ai",
        // W73-P3 item 2: forms the wave 73 review read going to the model.
        "do you have a name", "what's your name again", "what is your name again", "what are you called",
        "who are you exactly", "who are you again", "tell me about yourself", "who am i speaking to",
        "who am i speaking with",
    ]

    /// Read after `connection` folds "the internet", "an internet connection"
    /// and "wifi" into "internet".
    private static let offlineAsks: Set<String> = {
        var out: Set<String> = []
        for subject in ["do you", "does grux"] {
            out.formUnion(["\(subject) work offline", "\(subject) work without internet", "\(subject) need internet",
                           "\(subject) run offline", "\(subject) run without internet"])
        }
        for modal in ["can", "will"] {
            for subject in ["you", "grux"] {
                out.formUnion(["\(modal) \(subject) work offline", "\(modal) \(subject) work without internet",
                               "\(modal) \(subject) run offline", "\(modal) \(subject) run without internet"])
            }
        }
        out.formUnion(["can i use you offline", "can i use you without internet", "can i use grux offline",
                       "can i use grux without internet", "is grux offline", "are you offline capable"])
        return out
    }()

    /// Words that only say when or how, dropped before the ask is read:
    /// "Which model are you using right now?" asks what "Which model are you
    /// using?" asks (D200 item 16), and so do "Right now, which model..." and
    /// "What's your current model?" (W71-P3 item 1). Only whole words, so "Now
    /// write me a poem" keeps its other words and stays with the model. A
    /// sentence of only when words ("Right now,") is dropped whole.
    private static let whenWords: Set<String> = ["now", "currently", "current", "actually", "today"]

    private static func dropWhen(_ words: [String]) -> [String] {
        var out = words.filter { !whenWords.contains($0) }
        for edge in [["right"], ["at", "the", "moment"]] {
            if out.count >= edge.count, Array(out.suffix(edge.count)) == edge { out.removeLast(edge.count) }
            if out.count >= edge.count, Array(out.prefix(edge.count)) == edge { out.removeFirst(edge.count) }
        }
        return out
    }

    private static func connection(_ s: String) -> String {
        var s = " \(s) "
        for name in ["an internet connection", "the internet", "internet connection", "a connection", "wi fi",
                     "wifi", "the wifi"] {
            s = s.replacingOccurrences(of: " \(name) ", with: " internet ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "Grux.ai" is "Grux AI", read before the period splits it in two.
    static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "grux.ai", with: "grux ai")
    }

    /// The words with the assistant's own name (Settings, "What you call the
    /// assistant") taken off the front or the end, or nil when it is at
    /// neither: "Jax, who are you?" asks what "Who are you?" asks (W73-P3
    /// item 1). Callers read the words as they are first, so a name that is
    /// itself an ask word ("Who") never eats the ask.
    static func withoutName(_ words: [String], name: String) -> [String]? {
        let own = name.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        guard !own.isEmpty, words.count >= own.count else { return nil }
        if Array(words.prefix(own.count)) == own { return Array(words.dropFirst(own.count)) }
        if Array(words.suffix(own.count)) == own { return Array(words.dropLast(own.count)) }
        return nil
    }

    private enum Read { case skip, ask(Kind), other }

    /// Which ask the message is: one sentence asks it, read word for word after
    /// a greeting, "Grux," or the assistant's own name (`name`), and before a
    /// closing "Grux", the name, "please" or "thanks", and every other
    /// sentence is only a greeting, thanks or the name. "Can I use a smarter
    /// model for coding in Python?" and a second ask beside it stay with the
    /// model.
    static func kind(of text: String, earlier: [String] = [], name: String = "") -> Kind? {
        var found: Kind?
        for sentence in normalized(text).split(whereSeparator: { ".!?,\n".contains($0) }) {
            var words = sentence.split { !$0.isLetter && $0 != "'" }.map(String.init)
            while let first = words.first, leadIns.contains(first) { words.removeFirst() }
            var read = self.read(words, earlier: earlier, name: name)
            if case .other = read, let rest = withoutName(words, name: name) {
                read = rest.isEmpty ? .skip : self.read(rest, earlier: earlier, name: name)
            }
            switch read {
            case .skip: continue
            case .other: return nil
            case .ask(let kind):
                if let found, found != kind { return nil }
                found = kind
            }
        }
        return found
    }

    private static func read(_ words: [String], earlier: [String], name: String) -> Read {
        var words = words
        // "What is Grux?" ends in the closing "Grux", so it is read before that goes.
        let named = words.filter { $0 != "please" && $0 != "thanks" }.joined(separator: " ")
        while let last = words.last {
            if closings.contains(last) || last == "thanks" { words.removeLast() }
            else if words.count >= 2, words.suffix(2) == ["thank", "you"] { words.removeLast(2) }
            else { break }
        }
        words = dropWhen(words)
        guard !words.isEmpty else { return .skip }
        let said = connection(words.joined(separator: " "))
        if smarterAsks.contains(said) { return .ask(.smarterModel) }
        if offlineAsks.contains(said) { return .ask(.offline) }
        if identityAsks.contains(said) || identityAsks.contains(named) { return .ask(.identity) }
        if openingAsks.contains(said),
           earlier.allSatisfy({ CapabilityAsk.isOpening($0, name: name) || kind(of: $0, name: name) != nil }) {
            return .ask(.smarterModel)
        }
        return .other
    }

    /// The reply to "Who are you?": the name Settings holds, the app, and the
    /// route line "What model are you?" prints, so the two never disagree.
    static func identityReply(name: String, route: PrivacyAsk.Route, chatLocalModel: String?,
                              claudeModel: String = "") -> String {
        "I'm \(name), the assistant in Grux AI, a free app on this Mac that needs no account. "
            + routeLine(route: route, chatLocalModel: chatLocalModel, claudeModel: claudeModel)
            + " Ask \"What can you do?\" to see what is set up here. To call me something else, change "
            + "\"What you call the assistant\" in Settings, \(SettingsPane.general.label)."
    }

    /// Where chat answers from now, one sentence (or two, with the step chat
    /// needs). `chatLocalModel` and `claudeModel` as in `smarterReply`.
    static func routeLine(route: PrivacyAsk.Route, chatLocalModel: String?, claudeModel: String = "") -> String {
        let chatModel = catalogModel(chatLocalModel)
        switch route {
        case .thisMac(let model):
            return "Chat runs on \(chatModel.map { Cookbook.personName(for: $0.id) } ?? model), on this Mac, now."
        case .otherMachine(let model, let host):
            return "Chat runs on \(chatModel.map { Cookbook.personName(for: $0.id) } ?? model) on \(host) now."
        case .anthropic:
            return claudeModel.isEmpty
                ? "Chat runs on Claude through your Anthropic key now."
                : "Chat runs on Claude (\(ComposerFooter.displayName(id: claudeModel, registryName: nil))) through "
                    + "your Anthropic key now."
        case .custom(let name, let host):
            return "Chat runs on \(name) at \(host) now."
        case .none(let step):
            return "Chat has no model to answer with yet." + (step.map { " " + $0 } ?? "")
        }
    }

    /// The reply to "Can I use a smarter model?". `chatLocalModel` is chat's
    /// local model id (`offlineLLMModel`) when chat routes to it, nil on any
    /// other route; `claudeModel` is the Claude model chat sends to on the
    /// Anthropic route; `pick` is Local Models' headline for this Mac and
    /// `pickInstalled` whether Ollama holds it; `claudeKey` is a stored
    /// Anthropic key, nil while not read yet; `localModelsLine` says where
    /// Local Models opens (`HowItWorksCopy.localModelsLine`). `chosen` is the
    /// provider the person chose (`ModelRegistry.activeProvider`) and
    /// `localModelAvailable` whether a local model answers
    /// (`ModelRegistry.localUsable`), the two inputs the Use Claude button reads.
    static func smarterReply(chosen: ActiveProvider, route: PrivacyAsk.Route, chatLocalModel: String?, claudeModel: String = "",
                             pick: CookbookModel?, pickInstalled: Bool,
                             claudeKey: Bool?, localModelsLine: String, localModelAvailable: Bool = true,
                             claudeChoices: [String] = ComposerFooter.claudeChoices) -> String {
        let chatModel = catalogModel(chatLocalModel)
        var out = routeLine(route: route, chatLocalModel: chatLocalModel, claudeModel: claudeModel)
        if case .anthropic = route, !claudeModel.isEmpty { out += claudeRank(claudeModel, choices: claudeChoices) }
        if let pick, let chatModel, chatModel.id == pick.id {
            out += " That is already the local model Local Models recommends for this Mac (\(Cookbook.personName(for: pick.id)))."
        } else if let pick {
            let name = Cookbook.personName(for: pick.id)
            // USE on a card sets chat's local model and nothing else, so it
            // switches chat only while chat routes to its local model. The
            // model menu under the message box sets the model and the route.
            if chatLocalModel != nil {
                out += pickInstalled
                    ? " Local Models recommends \(name) for this Mac, and it is already downloaded: click USE on its card."
                    : " Local Models recommends \(name) for this Mac: click PULL on its card to download it."
            } else {
                out += pickInstalled
                    ? " Local Models recommends \(name) for this Mac, and it is already downloaded: pick it in the model "
                        + "menu under the message box to run chat on it."
                    : " Local Models recommends \(name) for this Mac: click PULL on its card to download it, then pick "
                        + "it in the model menu under the message box."
            }
            out += " " + localModelsLine
        } else {
            out += " No local model in Local Models fits this Mac's memory."
        }
        if case .anthropic = route { return out }
        switch claudeKey {
        case true?:
            out += " Your Anthropic key is saved: click Use Claude in Settings, \(SettingsPane.models.label) and chat "
                + "answers with Claude, over the internet."
        default:
            // Whether a key alone moves chat to Claude depends on the CHOSEN
            // provider, not on where chat routes now: with Claude chosen a saved
            // key routes chat to Claude by itself and no Use Claude button is
            // drawn; with a local model or an endpoint chosen (offline mode on
            // included, server up or down) only the press moves chat. So the
            // step asks the button's own rule (`ClaudeSwitchOffer`) whether a
            // key saved now would put Use Claude on screen (wave 74 review).
            let button = ClaudeSwitchOffer.decide(chosen: chosen, hasAnthropicKey: true,
                                                  localModelAvailable: localModelAvailable) == .button
            let step = button ? ", then click Use Claude there" : ""
            out += " For a stronger model than any that fits this Mac, add an Anthropic API key in Settings, "
                + "\(SettingsPane.models.label)\(step); chat then answers with Claude, and what you type goes to Anthropic."
        }
        return out
    }

    /// Where chat's Claude model sits in the composer's menu, strongest first.
    /// A model typed in Settings is not on that list, so no rank is claimed.
    /// `choices` is the list the menu draws (`ClaudeModelCatalog.ids`).
    private static func claudeRank(_ id: String, choices: [String]) -> String {
        guard let i = choices.firstIndex(of: id) else {
            return " Other Claude models are in the model menu under the message box."
        }
        if i == 0 { return " That is the strongest Claude model in the model menu under the message box." }
        return " Stronger Claude models are in the model menu under the message box, starting with "
            + "\(ComposerFooter.displayName(id: choices[0], registryName: nil))."
    }

    /// The reply to "Do you work without internet?". `searchReady` is
    /// `WebResearch.blocker == nil`; `hostedVoice` is replies read aloud in the
    /// ElevenLabs voice (`SpeechEngine.usesElevenLabs`). Each line names only
    /// what is on now.
    static func offlineReply(route: PrivacyAsk.Route, offlineMode: Bool, searchReady: Bool, updateCheckOn: Bool,
                             hostedVoice: Bool, localModelsLine: String, chatLocalModel: String? = nil) -> String {
        let chatName = catalogModel(chatLocalModel).map { Cookbook.personName(for: $0.id) }
        var out: String
        switch route {
        case .thisMac(let model):
            out = "Yes, for chat: it runs on \(chatName ?? model), on this Mac, so it answers with no "
                + "internet connection."
        case .otherMachine(let model, let host):
            out = "Chat runs on \(chatName ?? model) on \(host), so it needs that machine reachable over your network."
        case .anthropic:
            out = "Not for chat right now: it runs on Claude through Anthropic, which needs the internet. A model on "
                + "this Mac answers with no connection. " + localModelsLine
        case .custom(let name, let host):
            out = "Not for chat right now: it goes to \(name) at \(host), which needs the network. A model on this "
                + "Mac answers with no connection. " + localModelsLine
        case .none(let step):
            out = "Chat has no model to answer with yet."
            if let step { out += " " + step }
        }
        var online = ["the weather (Open-Meteo)"]
        if searchReady { online.append("web search") }
        if hostedVoice { online.append("the ElevenLabs voice") }
        if updateCheckOn { online.append("the daily update check") }
        out += " What still needs the internet: " + list(online) + "."
        if offlineMode { out += " Offline mode is on, so web search is off." }
        return out
    }

    /// Chat's local model in the catalog, named by its id ("Grux Local 2B",
    /// "Qwen 3.8 27B"): the route carries the composer's name ("Grux Local",
    /// "Qwen3.8"), which hid the size. Only when chat routes to it, so a
    /// custom endpoint on this Mac (LM Studio) keeps its own name.
    private static func catalogModel(_ id: String?) -> CookbookModel? {
        guard let id, !id.isEmpty else { return nil }
        return Cookbook.catalog.first { Cookbook.sameModel($0.id, id) }
    }

    /// Whether Ollama holds the pick. Local Models' list (`managerTags`) is
    /// empty at every launch until that pane opens, while the launch discovery
    /// reads the same server (`registryHolds`, `ModelRegistry.ollamaHolds`), so
    /// a pick pulled before this launch read "click PULL" (wave 65 round 3).
    static func pickInstalled(_ pickId: String, managerTags: [String], registryHolds: Bool) -> Bool {
        registryHolds || OllamaManager.isInstalled(pickId, in: managerTags)
    }

    private static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }

    @MainActor
    static func reply(_ kind: Kind, state: AppState) -> String {
        let route = PrivacyAsk.routes(state: state).route
        let door = HowItWorksCopy.localModelsLine(door: FeatureRegistry.disposition(for: "cookbook"),
                                                  developerUnlocked: state.config.developerSurfacesUnlocked)
        // Chat sends to its local model on a "local" preset pin, or with no
        // Anthropic pin while the registry routes local (`PrivacyAsk.route`).
        let pin = PresetStore.shared.activeChatApplication()?.providerOverride
        let routesLocal = pin == "local" || (pin != "anthropic" && ModelRegistry.shared.resolvedProvider == .local)
        let chatLocal = routesLocal ? state.config.offlineLLMModel : nil
        switch kind {
        case .smarterModel:
            let pick = Cookbook.headline(for: HardwareProfile.detect())
            let key = KeychainStore.getWithoutWaiting(.anthropicApiKey)
                .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return smarterReply(chosen: ModelRegistry.shared.activeProvider, route: route, chatLocalModel: chatLocal,
                                claudeModel: state.config.model, pick: pick,
                                pickInstalled: pick.map {
                                    pickInstalled($0.id, managerTags: OllamaManager.shared.installedTags,
                                                  registryHolds: ModelRegistry.shared.ollamaHolds($0.id))
                                } ?? false,
                                claudeKey: key, localModelsLine: door,
                                localModelAvailable: ModelRegistry.shared.localUsable,
                                claudeChoices: ClaudeModelCatalog.shared.ids)
        case .offline:
            let hasSearchKey = KeychainStore.getWithoutWaiting(.braveApiKey)
                .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true
            return offlineReply(route: route, offlineMode: state.offlineMode,
                                searchReady: WebResearch.blocker(offline: state.offlineMode,
                                                                 enabled: state.config.webResearchEnabled,
                                                                 hasSearchKey: hasSearchKey) == nil,
                                updateCheckOn: state.config.updateCheckEnabled,
                                hostedVoice: state.config.speakRepliesAloud
                                    && SpeechEngine.usesElevenLabs(
                                        choice: state.config.useElevenLabs,
                                        hasKey: KeychainStore.getWithoutWaiting(.elevenLabsApiKey)
                                            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                                            ?? KeychainStore.exists(.elevenLabsApiKey),
                                        offline: state.offlineMode),
                                localModelsLine: door, chatLocalModel: chatLocal)
        case .identity:
            return identityReply(name: UserIdentity.assistantName, route: route, chatLocalModel: chatLocal,
                                 claudeModel: state.config.model)
        }
    }
}
