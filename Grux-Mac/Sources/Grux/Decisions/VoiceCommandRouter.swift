import Foundation
import Combine

struct VoiceCommand {
    let id: String
    let phrases: [String]
    let klass: HandsFreeClass
    let run: () async -> String
}

struct VoiceDecisionEvent: Identifiable, Equatable {
    enum Outcome: Equatable { case executed, askedFirst, refused, ignored }
    let id = UUID()
    let at = Date()
    let heard: String
    let commandId: String
    let confidence: Double
    let latencyMs: Int
    let provider: DecisionProviderKind
    let outcome: Outcome
    /// What was actually done: the command's own report ("opened calendar"),
    /// "asked first", "sent to chat", or what a dry run would have done.
    var action: String = ""
    /// True when the decision was made but its effect was held back.
    var dryRun: Bool = false
}

/// Turns each transcript chunk into one question: which command, if any. The
/// vocabulary is built fresh per chunk from the live sidebar and the person's
/// own macros, so a new macro is speakable the moment it is saved.
@MainActor
final class VoiceCommandRouter: ObservableObject {
    static let shared: VoiceCommandRouter = {
        let r = VoiceCommandRouter(engine: DecisionEngine.shared,
                                   threshold: { AppState.shared.config.listeningThreshold })
        // Only the ONE router the app runs posts banners. A router a test
        // builds keeps the no-op default, so the suite can never write a real
        // notification or flip listeningBannerExplained in the live config.
        r.banner = { NotificationManager.shared.sendVoiceDecision($0) }
        r.sendToChatDecided = { await ChatService.shared.send(userText: $0, preDecidedPIM: $1) }
        r.runningApps = { WindowTargets.runningAppNames() }
        r.focusApp = { WindowTargets.focus(appNamed: $0) }
        r.hideApp = { WindowTargets.hide(appNamed: $0) }
        r.hideAll = { WindowTargets.hideAllExceptGrux() }
        r.tabsShowing = { !OnboardingModel.shared.isPresenting }
        return r
    }()

    @Published private(set) var events: [VoiceDecisionEvent] = []
    private let maxEvents = 200

    private let engine: DecisionEngine
    private let threshold: () -> Double
    private let macros: @MainActor () -> [Macro]

    // Seams for tests and for the app to wire at launch. Defaults reach the
    // real surfaces.
    var navigate: @MainActor (String) -> Void = { AppDelegate.shared?.openLaunchWindow(tab: $0) }
    /// Whether the window is showing tabs at all. First run replaces the whole
    /// shell (`LaunchRootView`), so a tab opened behind it is not on screen and
    /// the report must not say it is. True by default and wired only on the
    /// shared router, like `runningApps`, so a router a test builds does not
    /// depend on the suite's onboarding state.
    var tabsShowing: @MainActor () -> Bool = { true }
    var runMacro: (String) async -> String = { await VoiceMacroRegistry.shared.run(name: $0) }
    var askFirst: @MainActor (VoiceCommand) -> Void = { cmd in
        ApprovalQueue.shared.enqueue(askFirstAction(cmd), urgent: true, persona: .owner,
                                     reason: "Spoken command that asks first")
    }

    /// The tool an approved asked-first card replays through
    /// (`ApprovalQueue.approveAndExecute` -> `ChatService.dispatchTool`).
    /// Never offered to the model: only a card this router queued names it.
    static let replayTool = "voice_command"

    /// The card for a command that asks first. It carries a replay of the
    /// command's id, and only the id, so approving it runs what the card says
    /// and nothing the heard words could steer. Without it a yes was recorded
    /// and nothing was performed.
    static func askFirstAction(_ cmd: VoiceCommand) -> ProposedAction {
        var detail: [String: String] = ["__replay_tool": replayTool]
        if let json = JaxToolGate.encodeInput(["id": cmd.id]) { detail["__replay_input"] = json }
        return ProposedAction(kind: .other, summary: "You said: \(cmd.phrases.first ?? cmd.id)",
                              target: cmd.id, detail: detail)
    }

    /// Runs a command the person approved after Grux asked first. The
    /// vocabulary is built fresh, so a macro deleted or switched off since the
    /// card was queued is an error, and a command voice may never run is
    /// refused however the card was answered.
    func runApproved(id: String) async -> String {
        guard id != Self.sayToChat, id != LocalDecisionProvider.notACommand,
              let cmd = vocabulary().first(where: { $0.id == id }) else {
            return "error: '\(id)' is not a command Grux has any more, so nothing was run."
        }
        if cmd.klass == .never {
            return "refused: '\(id)' never runs by voice. Nothing was run."
        }
        return "ok: \(await cmd.run())"
    }
    /// Through `MicController`, never the bare flag: only it stops and
    /// restarts the listeners, so the flag alone read MUTED while the
    /// microphone stayed held.
    var setMuted: @MainActor (Bool) -> Void = { $0 ? MicController.mute(source: "spoken command") : MicController.unmute() }
    /// One banner per executed decision. Defaults to doing NOTHING, and the
    /// shared instance wires the real one. Every other seam here defaults to
    /// the real surface, and this one deliberately does not: posting a banner
    /// also flips `listeningBannerExplained` and saves the config, so a
    /// default that reached the real surface would let the suite write to the
    /// running app's settings.
    var banner: @MainActor (VoiceDecisionEvent) -> Void = { _ in }
    var sendToChat: (String) async -> Void = { await ChatService.shared.send(userText: $0) }
    /// Where the router notes what it dropped, for tests.
    var log: @MainActor (String) -> Void = { WakeLog.shared.log($0) }
    /// Hands the words to Chat WITH the answer this event already got for
    /// Chat's own gate, so Chat does not ask again. Only the shared router
    /// wires it; a router a test builds falls back to `sendToChat`.
    var sendToChatDecided: ((String, ChatIntentClassifier.PreDecidedPIM?) async -> Void)?
    /// The newest hand-off to Chat. The decision does not wait for Chat's
    /// reply (a model turn can take 25 s); each hand-off waits for the one
    /// before it, so words reach Chat in the order they were said.
    private(set) var chatHandOff: Task<Void, Never>?
    /// The pattern matcher Chat will run on the same words. A seam so a test
    /// can pin a plan without depending on today's date.
    var pimPlanner: @MainActor (String) -> PIMPlan? = { ChatIntentClassifier.pimRoute(utterance: $0) }

    /// The gate's name on the engine and in the ledger.
    static let gate = "voice"

    /// The on-device score that means "they said this command outright": an
    /// exact phrase covering at least half of what was said
    /// (`LocalDecisionProvider.phraseCoverage`). Below this the device is
    /// guessing and the provider decides.
    static let fastLocalFloor = 0.95

    /// Running apps as spoken targets (P-R-4). Empty by default and wired only
    /// on the shared router, like `banner`, so a router a test builds never
    /// depends on what happens to be running on the machine.
    var runningApps: @MainActor () -> [String] = { [] }
    var focusApp: @MainActor (String) -> Bool = { _ in false }
    var hideApp: @MainActor (String) -> Bool = { _ in false }
    var hideAll: @MainActor () -> Int = { 0 }

    /// The second gate on a voice event that asks which running app a request
    /// means ("bring up my browser"), and the generic option that goes with it.
    nonisolated static let appIntentGate = "app.intent"
    nonisolated static let genericAppFocus = "app.focus"
    nonisolated static let noApp = "none"

    /// Running apps that can be spoken targets: every one except an app whose
    /// name is also a Grux tab, which is left to the tab.
    func speakableApps() -> [String] {
        let tabLabels = Set(SidebarIA.groups.flatMap(\.items).map { $0.label.lowercased() })
        return runningApps().filter { !tabLabels.contains($0.lowercased()) }
    }
    /// Grux's own last reply and how long ago it landed, for continuity: a
    /// person answering Grux does not say its name first.
    var recentReply: @MainActor () -> (age: TimeInterval, text: String)? = {
        guard let last = AppState.shared.chat.last(where: { $0.role == .assistant && !$0.isNotice }) else { return nil }
        return (Date().timeIntervalSince(last.timestamp), last.content)
    }
    /// Within this many seconds of Grux speaking, the next thing said is a
    /// reply to Grux unless it is plainly a command for something else.
    static let followUpWindow: TimeInterval = 45

    /// Inside the follow-up window, a provider saying "not for Grux" at this
    /// confidence or more is believed. It was 0.8, and measured 2026-09-21 on
    /// the running app during a meeting in the room, that made a loop: Grux
    /// replied, the next line of the meeting (judged not for Grux at 0.65 and
    /// 0.77) went to Chat anyway, Grux replied to THAT, and the window opened
    /// again. The provider sees Grux's last words in the state, so a real
    /// answer to Grux comes back as say:chat, which this bar does not touch.
    static let followUpChatterBar = 0.6

    /// The reply whose follow-up window a keyless install has already spent
    /// its one grace chunk on (operator ruling A7, 2026-09-27). The on-device
    /// matcher cannot tell an answer to Grux from a television line, so it
    /// used to send EVERY line said within 45 s of a reply to Chat (measured
    /// iter 7: "the finder of lost things was on TV", 25 s after a reply).
    /// Now the first such line still reaches Grux and ends that reply's
    /// window; a new reply opens a new one. Kept as when the reply landed and
    /// what it said, because `recentReply` carries no id.
    private var graceSpentOn: (landed: Date, text: String)?

    private func graceSpent(on reply: (age: TimeInterval, text: String)) -> Bool {
        guard let spent = graceSpentOn, spent.text == reply.text else { return false }
        return abs(spent.landed.timeIntervalSince(Date().addingTimeInterval(-reply.age))) < 2
    }

    /// The one non-command outcome that still reaches Grux: the person spoke
    /// to it directly, so the words go to Chat as dictation. Everything that
    /// is not this and not a command is chatter and is ignored.
    static let sayToChat = "say:chat"

    /// What a REVERSIBLE command does at a given confidence.
    ///
    /// Below the bar it used to ask, always, which put an approval and an
    /// interruption in front of the person for a tab switch nobody had asked
    /// for. Measured on this install: "open contacts" at 0.64, heard in room
    /// talk at 3:52 PM, queued an approval. The costs run the other way:
    /// acting on a reversible thing is cheap and undoable, asking about one
    /// costs attention, and being asked about something you never said is the
    /// worst of the three.
    ///
    /// So a half-heard reversible command is ignored unless it was ADDRESSED
    /// to Grux, by name or inside the follow-up window, where the person is
    /// plainly talking to it and a question is welcome. Sending, deleting and
    /// spending are `asksFirst` and are untouched: they ask however they were
    /// heard.
    static func onTheSpot(confidence: Double, threshold: Double,
                          addressed: Bool) -> VoiceDecisionEvent.Outcome {
        if confidence >= threshold { return .executed }
        return addressed ? .askedFirst : .ignored
    }

    init(engine: DecisionEngine, threshold: @escaping () -> Double,
         macros: @escaping @MainActor () -> [Macro] = { VoiceMacroRegistry.shared.macros }) {
        self.engine = engine
        self.threshold = threshold
        self.macros = macros
    }

    // MARK: Vocabulary

    func vocabulary() -> [VoiceCommand] {
        var out: [VoiceCommand] = []
        for group in SidebarIA.groups {
            for item in group.items {
                let label = item.label.lowercased()
                let key = item.key
                out.append(VoiceCommand(id: "tab:\(key)",
                                        phrases: ["open \(label)", "open my \(label)", "show \(label)", "go to \(label)", "show me \(label)"],
                                        klass: .onTheSpot,
                                        run: { [navigate, tabsShowing] in
                                            navigate(key)
                                            return tabsShowing() ? "opened \(label)" : "setup is showing, \(label) not opened yet"
                                        }))
            }
        }
        out.append(VoiceCommand(id: "mute", phrases: ["mute", "stop listening", "grux mute"], klass: .onTheSpot,
                                run: { [setMuted] in setMuted(true); return "muted" }))
        out.append(VoiceCommand(id: "unmute", phrases: ["unmute", "start listening again"], klass: .onTheSpot,
                                run: { [setMuted] in setMuted(false); return "listening" }))
        // Running apps. An app whose name is also a Grux tab ("Notes") is left
        // to the tab, so "open notes" keeps meaning what it meant.
        for name in speakableApps() {
            out.append(VoiceCommand(id: "app.focus:\(name)", phrases: WindowTargets.focusPhrases(forApp: name),
                                    klass: .onTheSpot,
                                    run: { [focusApp] in focusApp(name) ? "brought \(name) forward" : "\(name) is not running" }))
            out.append(VoiceCommand(id: "app.hide:\(name)", phrases: WindowTargets.hidePhrases(forApp: name),
                                    klass: .onTheSpot,
                                    run: { [hideApp] in hideApp(name) ? "hid \(name)" : "\(name) is not running" }))
        }
        out.append(VoiceCommand(id: "close_all", phrases: WindowTargets.closeEverythingPhrases, klass: .onTheSpot,
                                run: { [hideAll] in "hid \(hideAll()) apps" }))
        for m in macros() where m.enabled {
            let klass = HandsFreePolicy.classify(macro: m)
            let name = m.name
            // A wake phrase addresses Grux; it cannot also name a macro. A
            // macro whose only triggers are wake phrases stays runnable from
            // Commands and is simply not speakable.
            let triggers = m.triggers.filter { !AmbientListener.startsWithWake($0) }
            guard !triggers.isEmpty else { continue }
            out.append(VoiceCommand(id: "macro:\(name)", phrases: triggers, klass: klass,
                                    run: { [runMacro] in await runMacro(name) }))
        }
        out.append(VoiceCommand(id: Self.sayToChat,
                                phrases: ["hey grux", "okay grux", "ok grux", "yo grux", "grux"],
                                klass: .onTheSpot, run: { "" }))
        out.append(VoiceCommand(id: LocalDecisionProvider.notACommand,
                                phrases: ["talking to someone else", "thinking out loud", "a television, a video or music", "nothing for Grux to do"],
                                klass: .onTheSpot, run: { "" }))
        return out
    }

    static let instructions =
        "Which of these did the person just ask Grux to do, if any? Grux is a voice assistant in the room. "
        + "\(sayToChat) means the words were said TO Grux and should reach its chat: a question or request for it, anything in the second person about what Grux did or said ('you responded', 'why did you', 'that was wrong'), an answer to something Grux just said, or Grux's name. People rarely say its name once a conversation is going. "
        + "\(LocalDecisionProvider.notACommand) means the words were plainly not for Grux: a television, a video, song lyrics, another person in the room, or the person muttering about something unrelated."

    private func criteria(for vocab: [VoiceCommand]) -> [String: String] {
        var c: [String: String] = [:]
        for v in vocab { c[v.id] = v.phrases.joined(separator: " | ") }
        return c
    }

    /// The options worth offering for THIS chunk (P-R-2).
    ///
    /// Every macro rode on every chunk: 103 speakable macros, about 6,600
    /// characters of trigger phrases, most of a 4,450 token call. Measured
    /// 2026-09-21 on the live provider over twelve cases (television,
    /// bystander, room chatter, addressed words, tabs, macros, mute): offering
    /// only the macros that share a word with what was heard gave the SAME
    /// choice on all twelve, at a median 1,762 input tokens instead of 4,450
    /// and 366 ms instead of 412.
    ///
    /// Tabs, mute, unmute, say:chat and not_a_command are always offered, so a
    /// tab asked for by another name can still be understood. Macros are
    /// filtered by `LocalDecisionProvider.couldMatch` against the whole state,
    /// the on-device matcher's own test: a macro it rejects scores 0 on device
    /// and can never win, so a keyless install answers exactly as before.
    ///
    /// Running apps (P-R-4) are offered only when their NAME was heard. Their
    /// phrases all share the verbs ("open", "bring up"), so filtering on the
    /// phrases let any "open ..." pull in every app, twenty apps at two
    /// commands each. An app offered on a verb alone scores at most 0.6 times
    /// one word in five on device (0.12), so it can never win there: dropping
    /// it changes no keyless outcome, which `VoiceVocabularyTrimTests` pins.
    static func offered(_ vocab: [VoiceCommand], state: String) -> [VoiceCommand] {
        vocab.filter { v in
            if v.id.hasPrefix("app."), let name = v.id.split(separator: ":", maxSplits: 1).last {
                return LocalDecisionProvider.couldMatch(state: state, description: String(name))
            }
            return !v.id.hasPrefix("macro:")
                || LocalDecisionProvider.couldMatch(state: state, description: v.phrases.joined(separator: " | "))
        }
    }

    /// Words that ask for something to be brought forward. A cheap, local gate
    /// on whether the which-app question is worth a place on the call.
    static let focusVerbs = ["open ", "switch to", "bring up", "pull up", "focus ", "go to ", "show me "]

    /// The verb has to START within the first four words. A request puts it up
    /// front ("open the...", "can you pull up..."); room talk puts it anywhere.
    /// Measured live 2026-09-21: "We just kind of want to open it up to you
    /// guys" put the question on the call, answered none, and cost 3,469 input
    /// tokens against 2,149 for the voice question alone.
    static let focusVerbWithinWords = 4

    static func asksToBringSomethingForward(_ heard: String) -> Bool {
        let words = heard.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        let lead = words.prefix(focusVerbWithinWords + 1).joined(separator: " ") + " "
        return focusVerbs.contains { verb in
            guard let r = lead.range(of: verb) else { return false }
            let before = lead[lead.startIndex..<r.lowerBound].split(separator: " ").count
            return before < focusVerbWithinWords
        }
    }

    /// Worded with examples on purpose. Measured on the live provider over
    /// thirteen requests: "bring an app to the front by what it is" lost
    /// "switch to the terminal" to a Grux tab and "open the code
    /// editor" to not_a_command; this wording got both. With the rule below
    /// (both answers at or above the execute threshold) it acted correctly on
    /// 11 of 13 and WRONGLY on none, including two bystander lines ("I need to
    /// open Slack later tonight", "she said to switch to the terminal"). The
    /// two misses were genuinely ambiguous: two browsers running, and Grux's
    /// own Folders tab against Finder. A looser rule acted on the bystanders.
    static let genericAppFocusDescription =
        "open, switch to or bring up an app running on this Mac, named or described "
        + "(my browser, the terminal, my texts, the code editor)"

    static let appIntentInstructions =
        "Which of these running apps does the person want brought to the front? Pick an app only if they asked to "
        + "open, switch to or bring up that app, by its name or by what it is ('my browser', 'the terminal'). "
        + "\(noApp) means they did not ask for one of these apps, or asked for something inside Grux itself."

    // MARK: Routing

    /// How much of a decision's effect to hold back. The decision itself is
    /// always made and recorded in full; only the effect changes.
    enum DryRun: String {
        /// Everything the decision calls for happens.
        case none
        /// Anything whose effect leaves Grux is held back: another app brought
        /// forward or hidden, every app hidden, and macros, which can drive any
        /// app. Tabs and mute still happen. Dictation still reaches Chat, as a
        /// dry-run turn in which every tool that acts outside Grux only records
        /// (`JaxToolGate.dryRun`).
        case outsideGrux
        /// Nothing happens. The decision is recorded and that is all.
        case everything

        func covers(_ commandId: String) -> Bool {
            switch self {
            case .none: return false
            case .everything: return true
            case .outsideGrux: return VoiceCommandRouter.actsOutsideGrux(commandId)
            }
        }
    }

    /// Commands whose effect reaches beyond Grux's own windows.
    nonisolated static func actsOutsideGrux(_ commandId: String) -> Bool {
        commandId.hasPrefix("app.") || commandId == "close_all" || commandId.hasPrefix("macro:")
    }

    @discardableResult
    func consider(chunk: String, dryRun: DryRun = .none) async -> VoiceDecisionEvent? {
        let text = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 3 else { return nil }
        // The address ("hey Grux") is stripped before the question is asked, so
        // "hey Grux, open my calendar" matches the calendar and not a macro that
        // happens to be triggered by the greeting. Being addressed by name is
        // then what turns "nothing matched" into dictation.
        let reply = recentReply()
        let inConversation = (reply?.age ?? .infinity) <= Self.followUpWindow
        let byName = AmbientListener.startsWithWake(text)
        let body = AmbientListener.stripWakePrefix(text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 3 else { return nil }
        let vocab = vocabulary()
        var state = "\(LocalDecisionProvider.heardPrefix)\(body)"
        if let reply, reply.age <= 90 {
            state += "\nGrux last spoke \(Int(reply.age))s ago and said: \(reply.text.prefix(160))"
        }
        // ONE CALL FOR THE WHOLE UTTERANCE (P-R-1). If these words go on to
        // Chat and Chat's pattern matcher finds a plan, Chat's gate would ask
        // a second question about the same words in a second round trip. So
        // the plan is matched here, synchronously, and both questions ride
        // the voice event's one call. Chat reads its answer from the event.
        let event = engine.open(origin: Self.gate, state: state,
                                covering: [Self.gate, ChatIntentClassifier.pimGate, Self.appIntentGate])
        defer { engine.close(event) }
        // ANSWER ON DEVICE WHEN THE DEVICE IS ALREADY CERTAIN. Measured over
        // 603 real decisions in wake.log on 2026-09-23: Jev's median was 368ms
        // and the on-device provider's was 3ms. A spoken command cannot reach
        // execution inside 600ms while paying that round trip, and when the
        // person has said a command phrase outright the round trip cannot
        // change the answer.
        //
        // The bar is the HIGHER of the exact-phrase score and the person's own
        // listening threshold, never just the former. Settling on device at
        // 0.95 when their threshold is 0.97 would skip a call that might have
        // come back 0.99, and turn a command Grux used to obey into one it
        // ignores. Taking the max means the fast path can only ever settle an
        // answer that was going to execute anyway.
        event.fastLocal = DecisionEvent.FastLocalPath(
            gate: Self.gate,
            question: "intent",
            minConfidence: max(Self.fastLocalFloor, threshold()),
            // Neither of these is a specific command. `sayToChat` is a request
            // to start a conversation, which is exactly the judgment a
            // provider is for, and the generic app focus is meaningless until
            // the which-app question has been answered by something that is
            // not the on-device matcher.
            neverFast: [Self.sayToChat, Self.genericAppFocus])
        var offeredVocab = Self.offered(vocab, state: state)
        // Words the PIM matcher turned into a plan ask for that action, never
        // for a pane: offered "open notes", the judge answered "take a note the
        // blue folder is in the top drawer" with `tab:notes` (A34, 0.73) and
        // the note was never taken. The plan rides to Chat through `say:chat`.
        let plan = pimPlanner(body)
        if plan != nil { offeredVocab.removeAll { $0.id.hasPrefix("tab:") } }
        // WHICH APP (P-R-4), on the same call. Only with a provider that can
        // judge: on device a which-app question has nothing to go on, and a
        // keyless install must behave as before. Only when something was asked
        // to come forward and no running app was named, because a named app
        // already has its own command.
        let apps = speakableApps()
        let asksWhichApp = engine.hasRemoteKey && !apps.isEmpty
            && Self.asksToBringSomethingForward(body)
            && !offeredVocab.contains { $0.id.hasPrefix("app.focus:") }
        if asksWhichApp {
            offeredVocab.append(VoiceCommand(id: Self.genericAppFocus,
                                             phrases: [Self.genericAppFocusDescription],
                                             klass: .onTheSpot, run: { "" }))
        }
        event.ask(Self.gate, ["intent": .choice(instructions: Self.instructions, criteria: criteria(for: offeredVocab))])
        if asksWhichApp {
            var appCriteria = Dictionary(uniqueKeysWithValues: apps.map { ($0, "the app named \($0)") })
            appCriteria[Self.noApp] = "none of these apps"
            event.ask(Self.appIntentGate, context: "Apps running on this Mac: \(apps.joined(separator: ", ")).",
                      ["app": .choice(instructions: Self.appIntentInstructions, criteria: appCriteria)])
        }
        if let plan, plan.kind.isJudged {
            event.ask(ChatIntentClassifier.pimGate,
                      context: ChatIntentClassifier.pimState(plan: plan, utterance: body),
                      ChatIntentClassifier.pimQuestions)
        }
        await engine.resolve(event)
        let provider = event.provider ?? .local
        let result = (latencyMs: event.latencyMs, provider: provider)
        guard case .choice(let rawId, let rawConfidence, _)? = event.answer(Self.gate, "intent") else { return nil }
        var id = rawId
        var confidence = rawConfidence
        // The generic "bring an app forward" only acts with a confident target
        // from the which-app question. Without one it is not a specific
        // command, and the utterance takes the path it always took.
        if id == Self.genericAppFocus {
            if case .choice(let app, let c, _)? = event.answer(Self.appIntentGate, "app"),
               provider != .local, app != Self.noApp, apps.contains(app),
               c >= threshold(), confidence >= threshold() {
                id = "app.focus:\(app)"
                confidence = min(confidence, c)
            } else {
                id = LocalDecisionProvider.notACommand
                confidence = 0
            }
        }
        let notASpecificCommand = id == LocalDecisionProvider.notACommand || id == Self.sayToChat || confidence < 0.5
        // Said by name: for Grux, whatever the provider thought of the words.
        // Said inside the follow-up window: a reply to Grux, unless a provider
        // that can actually judge (Jev) is sure it was not for Grux, which is
        // how a television line ten seconds after Grux spoke stays ignored
        // while the person's answer to Grux does not need its name.
        let providerSureItIsChatter = result.provider != .local
            && id == LocalDecisionProvider.notACommand && confidence >= Self.followUpChatterBar
        // Keyless, the window holds one line the matcher called not a
        // command. Past that it is closed until Grux speaks again.
        let keylessGuess = result.provider == .local && rawId != Self.sayToChat
        var windowClosed = false
        if notASpecificCommand, !byName, inConversation, keylessGuess, let reply {
            if graceSpent(on: reply) {
                windowClosed = true
                log("voice: follow-up window closed (keyless, grace chunk already used), dropped: \(body.prefix(120))")
            } else if dryRun == .none {
                // A dry run reads the window and leaves it as it found it
                // (review RV10): the person's own grace chunk is still theirs.
                graceSpentOn = (Date().addingTimeInterval(-reply.age), reply.text)
            }
        }
        if notASpecificCommand, byName || (inConversation && !providerSureItIsChatter && !windowClosed) {
            id = Self.sayToChat
            confidence = 0.95
        }
        // The which-app answer needs no row of its own: the event's row
        // already carries `app.intent.app`. Being addressed does, because the
        // provider's row says the words were not for Grux.
        if id == Self.sayToChat, rawId != Self.sayToChat {
            let rule = byName ? "said to Grux by name" : "a reply inside the follow-up window"
            engine.recordOverride(surface: event.surface, heard: "\(LocalDecisionProvider.heardPrefix)\(body)",
                                  question: "\(Self.gate).intent", choice: id, confidence: confidence, rule: rule)
        }
        let outcome: VoiceDecisionEvent.Outcome
        var held = dryRun.covers(id)
        var action = ""
        if id == LocalDecisionProvider.notACommand || confidence < 0.5 {
            outcome = .ignored
        } else if id == Self.sayToChat {
            // Dictation never asks first: below the threshold it is chatter.
            if confidence >= threshold() {
                if held {
                    action = "dry run: would send to chat"
                } else {
                    // Chat's answer is read off the event here, before it
                    // closes, so the hand-off below never asks again.
                    let pre = plan.map { p in
                        ChatIntentClassifier.PreDecidedPIM(
                            utterance: body, planKind: p.kind, cardTitle: p.cardTitle,
                            decision: ChatIntentClassifier.pimDecision(
                                answer: event.answer(ChatIntentClassifier.pimGate, "meant"),
                                provider: provider, latencyMs: event.latencyMs, threshold: threshold()))
                    }
                    // Outside-Grux dry run: the turn runs, and every tool in it
                    // that acts outside Grux only records (review RV4).
                    let rehearsal = dryRun != .none
                    let previous = chatHandOff
                    chatHandOff = Task { [sendToChatDecided, sendToChat] in
                        await previous?.value
                        await JaxToolGate.$dryRun.withValue(rehearsal) {
                            if let handOff = sendToChatDecided { await handOff(body, pre) } else { await sendToChat(body) }
                        }
                    }
                    held = rehearsal
                    action = rehearsal ? "sent to chat as a dry run: tools that act outside Grux only record" : "sent to chat"
                }
                outcome = .executed
            } else {
                outcome = .ignored
            }
        } else if let cmd = vocab.first(where: { $0.id == id }) {
            switch cmd.klass {
            case .never:
                outcome = .refused
                action = "refused"
            case .asksFirst:
                action = held ? "dry run: would ask first" : "asked first"
                if !held { askFirst(cmd) }
                outcome = .askedFirst
            case .onTheSpot:
                switch Self.onTheSpot(confidence: confidence, threshold: threshold(),
                                      addressed: byName || inConversation) {
                case .executed:
                    action = held ? "dry run: would run \(id)" : await cmd.run()
                    outcome = .executed
                case .askedFirst:
                    action = held ? "dry run: would ask first" : "asked first"
                    if !held { askFirst(cmd) }
                    outcome = .askedFirst
                default: outcome = .ignored
                }
            }
        } else {
            outcome = .ignored
        }
        let decided = VoiceDecisionEvent(heard: text, commandId: id, confidence: confidence,
                                         latencyMs: result.latencyMs, provider: result.provider, outcome: outcome,
                                         action: action, dryRun: held && outcome != .ignored && outcome != .refused)
        events.append(decided)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        banner(decided)
        return decided
    }
}
