import XCTest
@testable import Grux

/// D189, sense pass 25 (D186's own live proof, 7:28 AM Nov 7, grux-local:2b with
/// the ABOUT_YOU block in the prompt): "Can I use a smarter model?" got "You'll
/// need to add a new one in the Models tab" (there is no Models tab; Local
/// Models offers Grux Local 4B with PULL, and a Claude key works), and "Do you
/// work without internet?" got "Yes, I run locally on this Mac so I don't need
/// an internet connection to operate." (weather, web search and the update
/// check go online). A prompt fact does not make a 2B model answer right, so
/// these questions are answered from Grux's own state, with no model.
@MainActor
final class SelfAskTests: XCTestCase {

    static let smarterAsks = [
        "Can I use a smarter model?",
        "can i use a better model",
        "Hi Grux, can I use a bigger model?",
        "How do I get a smarter model?",
        "How can I make you smarter?",
        "Can you be smarter?",
        "Is there a better model?",
        "Can I switch models?",
        "How do I change the model?",
        "Can I use Claude?",
        "What model are you?",
        "Which model do you use?",
        "Can I use a smarter model, please?",
        "Can I use a smarter model? Thanks!",
        // D200 item 16 (sense pass 28, thread 9ABC7FE6): "right now" sent
        // this to grux-local:2b, which added "I don't have access to the full
        // list of available models."
        "Which model are you using right now?",
        "What model are you using now?",
        "Which model are you currently using?",
        "What model are you running on at the moment?",
        "What model is this?",
        "What's your model?",
        "What model is chat using right now?",
        // W71-P3 item 1: the when words led the sentence, the subject was
        // Grux, or "running" and "current" were said; each went to the model.
        "Right now, which model are you using?",
        "At the moment, what model are you using?",
        "What model is Grux using right now?",
        "Which model does Grux use?",
        "What model are you running right now?",
        "What model are you currently running?",
        "What's your current model?",
        "What is your current model?",
    ]

    static let offlineAsks = [
        "Do you work without internet?",
        "Do you work without the internet?",
        "do you work without an internet connection",
        "Do you work offline?",
        "Can you work offline?",
        "Does Grux work offline?",
        "Do you need the internet?",
        "Do you need an internet connection?",
        "Do you need wifi?",
        "Can I use you offline?",
        "Will you work without wi-fi?",
        "Hey, do you work offline?",
    ]

    /// Share the words, ask something else: left with the model.
    static let notAsks = [
        "Can I use a smarter model for coding in Python?",
        "What model is best for writing code?",
        "Is there a better model of the iPhone?",
        "Can I use a smarter model? Also add milk to my list.",
        "Do you work without internet on weekends?",
        "Does my phone work offline?",
        "Do I need the internet for Spotify?",
        "Can you work offline on my essay?",
        "Write about smarter models",
        "Which model are you using for my essay right now?",
        "What model is this car?",
        "Now write me a poem",
        "Right now, write me a poem",
        "At the moment, what model is best for writing code?",
        "What's the current model of the iPhone?",
        "What model is Grux using for my essay right now?",
        "Right now",
        "",
    ]

    /// Wave 71 round 1 P2: "What model is this?" after a photo of a car asks
    /// about the car. The "this" asks are Grux's own only in a chat whose
    /// every earlier message was an opening, as PrivacyAsk's are.
    func testAThisAskMidConversationStaysWithTheModel() {
        XCTAssertEqual(SelfAsk.kind(of: "What model is this?"), .smarterModel)
        XCTAssertEqual(SelfAsk.kind(of: "What model is this?", earlier: ["Hi!", "What can you do?"]), .smarterModel)
        XCTAssertNil(SelfAsk.kind(of: "What model is this?", earlier: ["Here is a photo of my neighbour's car"]))
        XCTAssertNil(SelfAsk.kind(of: "Which model is this?", earlier: ["Look at this laptop listing"]))
        XCTAssertEqual(SelfAsk.kind(of: "Which model are you using?", earlier: ["Plan my move"]), .smarterModel)
    }

    /// Wave 71 round 2 P2: a photo sent with no words (or with only "Hi")
    /// reached the "this" check as "" or "Hi", an opening, so "What model is
    /// this?" about the photo still got Grux's own model. A turn that carries
    /// an image is never an opening, for the self and the privacy asks alike.
    func testATurnWithAnImageIsNeverAnOpening() {
        let photo = Data([0xFF, 0xD8, 0xFF])
        let chat = [ChatMessage(role: .user, content: "", imageData: photo, imageMediaType: "image/jpeg"),
                    ChatMessage(role: .assistant, content: "That is a red sedan."),
                    ChatMessage(role: .user, content: "What model is this?")]
        let earlier = CapabilityAsk.earlierTurns(chat)
        XCTAssertNil(SelfAsk.kind(of: "What model is this?", earlier: earlier))
        XCTAssertFalse(PrivacyAsk.matches("Is this private?", earlier: earlier))
        let hi = [ChatMessage(role: .user, content: "Hi", imageData: photo, imageMediaType: "image/png"),
                  ChatMessage(role: .user, content: "What model is this?")]
        XCTAssertNil(SelfAsk.kind(of: "What model is this?", earlier: CapabilityAsk.earlierTurns(hi)))
        XCTAssertFalse(CapabilityAsk.isOpening(""))
        // Words alone still open a chat, and notices are not the person's.
        let plain = [ChatMessage(role: .user, content: "Hi!"), ChatMessage(role: .user, content: "note", isNotice: true),
                     ChatMessage(role: .user, content: "What model is this?")]
        XCTAssertEqual(CapabilityAsk.earlierTurns(plain), ["Hi!"])
        XCTAssertEqual(SelfAsk.kind(of: "What model is this?", earlier: CapabilityAsk.earlierTurns(plain)), .smarterModel)
    }

    /// Wave 71 round 3 P2: a first message that is only an emoji or a mark
    /// ("👋", ":)", "?") is typed, so it still opens a chat; only a turn with
    /// no text at all (an image sent alone) opens nothing.
    func testATypedTurnWithNoLettersStillOpens() {
        for first in ["\u{1F44B}", ":)", "?", "...", "\u{1F642}"] {
            XCTAssertTrue(CapabilityAsk.isOpening(first), first)
            XCTAssertEqual(SelfAsk.kind(of: "What model is this?", earlier: [first]), .smarterModel, first)
            XCTAssertTrue(PrivacyAsk.matches("Is this private?", earlier: [first]), first)
            XCTAssertTrue(CapabilityAsk.matches("Where do I start?", earlier: [first]), first)
        }
        XCTAssertFalse(CapabilityAsk.isOpening(" \n"))
        // The capability ask reads a photo turn as the others do.
        let photo = ChatMessage(role: .user, content: "Hi", imageData: Data([1]), imageMediaType: "image/png")
        XCTAssertEqual(CapabilityAsk.modelAsks([photo]), [""])
    }

    /// Both fast paths read the earlier turns through the one helper.
    func testChatReadsEarlierTurnsThroughTheHelper() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/ChatService.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("PrivacyAsk.matches(trimmed, earlier: CapabilityAsk.earlierTurns(state.chat))"))
        // W73-P3 item 1: and with the assistant's own name, read as a lead-in.
        XCTAssertTrue(src.contains("SelfAsk.kind(of: trimmed, earlier: CapabilityAsk.earlierTurns(state.chat),\n"
                                   + "                                                         name: UserIdentity.assistantName)"))
    }

    /// The chat path hands the earlier user turns to the self ask.
    func testChatPassesEarlierTurns() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/ChatService.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("SelfAsk.kind(of: trimmed, earlier:"), "the chat path must pass the earlier turns")
    }

    func testEverySmarterAskMatches() {
        for ask in Self.smarterAsks {
            XCTAssertEqual(SelfAsk.kind(of: ask), .smarterModel, ask)
        }
    }

    func testEveryOfflineAskMatches() {
        for ask in Self.offlineAsks {
            XCTAssertEqual(SelfAsk.kind(of: ask), .offline, ask)
        }
    }

    func testAsksAboutSomethingElseStayWithTheModel() {
        for ask in Self.notAsks {
            XCTAssertNil(SelfAsk.kind(of: ask), ask)
        }
    }

    // MARK: A smarter model

    static let twoB = Cookbook.catalog.first { $0.id == "gruxai.com/grux/grux-local:2b" }!
    static let fourB = Cookbook.catalog.first { $0.id == "gruxai.com/grux/grux-local:4b" }!
    static let paletteDoor = HowItWorksCopy.localModelsLine(door: .developer, developerUnlocked: false)

    func testOnTheSmallLocalModelItNamesTheBetterPickAndItsPullButton() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "Grux Local 2B"), chatLocalModel: Self.twoB.id,
                                         pick: Self.fourB, pickInstalled: false, claudeKey: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("Grux Local 2B"), reply)
        XCTAssertTrue(reply.contains("Grux Local 4B"), reply)
        XCTAssertTrue(reply.contains("PULL"), reply)
        XCTAssertTrue(reply.contains(Self.paletteDoor), reply)
        XCTAssertTrue(reply.contains("Anthropic API key in Settings, \(SettingsPane.models.label)"), reply)
        XCTAssertFalse(reply.contains("Models tab"), reply)
    }

    /// Live 7:24 PM Nov 7: the route's name is the composer's ("Grux Local"),
    /// so "Chat runs on Grux Local ... recommends Grux Local 4B" hid the size.
    func testACatalogModelIsNamedWithItsSize() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "Grux Local"), chatLocalModel: Self.twoB.id,
                                         pick: Self.fourB, pickInstalled: false, claudeKey: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.hasPrefix("Chat runs on Grux Local 2B"), reply)
        let offline = SelfAsk.offlineReply(route: .thisMac(model: "Grux Local"), offlineMode: false,
                                           searchReady: false, updateCheckOn: false, hostedVoice: false,
                                           localModelsLine: Self.paletteDoor, chatLocalModel: Self.twoB.id)
        XCTAssertTrue(offline.contains("Grux Local 2B"), offline)
    }

    /// A custom endpoint on this Mac is `.thisMac` under its own name: it is
    /// not chat's local model, whatever `offlineLLMModel` holds.
    func testALocalEndpointKeepsItsOwnName() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "LM Studio"), chatLocalModel: nil,
                                         pick: Self.fourB, pickInstalled: true, claudeKey: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.hasPrefix("Chat runs on LM Studio"), reply)
        XCTAssertFalse(reply.contains("already the local model"), reply)
    }

    func testAnInstalledPickIsChosenWithUse() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "Grux Local 2B"), chatLocalModel: Self.twoB.id,
                                         pick: Self.fourB, pickInstalled: true, claudeKey: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("USE"), reply)
        XCTAssertFalse(reply.contains("PULL"), reply)
    }

    func testOnThePickItSaysSoAndOffersClaude() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "Grux Local 4B"), chatLocalModel: Self.fourB.id,
                                         pick: Self.fourB, pickInstalled: true, claudeKey: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("already"), reply)
        XCTAssertFalse(reply.contains("PULL"), reply)
        XCTAssertTrue(reply.contains("Anthropic API key"), reply)
    }

    func testASavedKeyPointsAtUseClaude() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "Grux Local 2B"), chatLocalModel: Self.twoB.id,
                                         pick: Self.fourB, pickInstalled: false, claudeKey: true,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("Use Claude"), reply)
        XCTAssertFalse(reply.contains("add an Anthropic"), reply)
    }

    /// D210 item 2. With chat routed to a local model a key alone switches
    /// nothing: Settings, Models shows Use Claude once a key is saved, and
    /// only that press moves chat (`ClaudeSwitchOffer.needsKeyLine`).
    func testWithNoKeyOnALocalRouteItNamesUseClaudeToo() {
        for key in [false, nil] as [Bool?] {
            for route in [PrivacyAsk.Route.thisMac(model: "Grux Local 2B"),
                          .otherMachine(model: "Grux Local 2B", host: "studio.local")] {
                let reply = SelfAsk.smarterReply(chosen: .local, route: route, chatLocalModel: Self.twoB.id, pick: Self.fourB,
                                                 pickInstalled: false, claudeKey: key, localModelsLine: Self.paletteDoor)
                XCTAssertTrue(reply.contains("add an Anthropic API key in Settings, \(SettingsPane.models.label), "
                                             + "then click Use Claude there"), reply)
            }
        }
        let custom = SelfAsk.smarterReply(chosen: .local, route: .custom(name: "LM Studio", host: "127.0.0.1"), chatLocalModel: nil,
                                          pick: Self.fourB, pickInstalled: false, claudeKey: false,
                                          localModelsLine: Self.paletteDoor)
        XCTAssertTrue(custom.contains("then click Use Claude there"), custom)
    }

    /// With Claude the chosen provider and no model at all, a saved key is
    /// what chat falls back to: no press needed.
    func testWithNoModelAKeyAloneIsTheStep() {
        let reply = SelfAsk.smarterReply(chosen: .anthropic, route: .none(step: "Start Ollama first."), chatLocalModel: nil, pick: Self.twoB,
                                         pickInstalled: false, claudeKey: false, localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("add an Anthropic API key"), reply)
        XCTAssertFalse(reply.contains("Use Claude"), reply)
    }

    /// Wave 74 review P2-2: offline mode on (local chosen) and the local
    /// server down. A key does not rescue that (`ChatReadiness`
    /// `.offlinePinnedButNoLocalModel`); Use Claude does.
    func testOfflinePinnedWithNoServerNamesUseClaude() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .none(step: "Start Ollama first."), chatLocalModel: nil,
                                         pick: Self.twoB, pickInstalled: false, claudeKey: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("then click Use Claude there"), reply)
    }

    /// Wave 74 review P2-1: the ordinary local setup is Claude chosen, no key,
    /// Ollama answering, so chat routes local. No Use Claude button is drawn
    /// there (`ClaudeSwitchOffer.decide` is `.none`) and a saved key moves
    /// chat to Claude by itself, so the reply must not name the button.
    func testClaudeChosenRoutedLocalSaysAKeyAloneIsTheStep() {
        for route in [PrivacyAsk.Route.thisMac(model: "Grux Local 2B"),
                      .otherMachine(model: "Grux Local 2B", host: "studio.local")] {
            let reply = SelfAsk.smarterReply(chosen: .anthropic, route: route, chatLocalModel: Self.twoB.id,
                                             pick: Self.fourB, pickInstalled: false, claudeKey: false,
                                             localModelsLine: Self.paletteDoor)
            XCTAssertTrue(reply.contains("add an Anthropic API key in Settings, \(SettingsPane.models.label); "
                                         + "chat then answers with Claude"), reply)
            XCTAssertFalse(reply.contains("Use Claude"), reply)
        }
    }

    /// The step agrees with the Use Claude button's own rule for every chosen
    /// provider and every local state: it names the button exactly when a key
    /// saved now would make Settings draw it.
    func testTheStepAgreesWithTheButtonForEveryChoice() {
        let routes: [PrivacyAsk.Route] = [.thisMac(model: "Grux Local 2B"),
                                          .otherMachine(model: "Grux Local 2B", host: "studio.local"),
                                          .custom(name: "LM Studio", host: "127.0.0.1"),
                                          .none(step: "Start Ollama first.")]
        for chosen in [ActiveProvider.anthropic, .local, .custom(UUID())] {
            for route in routes {
                for local in [true, false] {
                    let reply = SelfAsk.smarterReply(chosen: chosen, route: route, chatLocalModel: nil, pick: Self.fourB,
                                                     pickInstalled: false, claudeKey: false,
                                                     localModelsLine: Self.paletteDoor, localModelAvailable: local)
                    let button = ClaudeSwitchOffer.decide(chosen: chosen, hasAnthropicKey: true,
                                                          localModelAvailable: local) == .button
                    XCTAssertEqual(reply.contains("Use Claude"), button, "\(chosen) \(route) local=\(local): \(reply)")
                }
            }
        }
    }

    func testOnClaudeItSaysChatIsOnClaude() {
        let reply = SelfAsk.smarterReply(chosen: .anthropic, route: .anthropic, chatLocalModel: nil, pick: Self.fourB,
                                         pickInstalled: false, claudeKey: true, localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("Claude"), reply)
        XCTAssertFalse(reply.contains("Anthropic API key in Settings"), reply)
        XCTAssertFalse(reply.contains("Use Claude"), reply)
    }

    func testWithNoModelItGivesTheStep() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .none(step: "Start Ollama first."), chatLocalModel: nil, pick: Self.twoB,
                                         pickInstalled: false, claudeKey: false, localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("Start Ollama first."), reply)
    }

    func testWithNothingThatFitsItSaysSo() {
        let reply = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "Grux Local 2B"), chatLocalModel: Self.twoB.id,
                                         pick: nil, pickInstalled: false, claudeKey: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertFalse(reply.contains("PULL"), reply)
        XCTAssertTrue(reply.contains("Anthropic API key"), reply)
    }

    // MARK: Without the internet

    func testOnThisMacChatWorksOfflineAndItNamesWhatDoesNot() {
        let reply = SelfAsk.offlineReply(route: .thisMac(model: "Grux Local 2B"), offlineMode: false,
                                         searchReady: true, updateCheckOn: true, hostedVoice: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.hasPrefix("Yes"), reply)
        XCTAssertTrue(reply.contains("Grux Local 2B"), reply)
        XCTAssertTrue(reply.contains("weather"), reply)
        XCTAssertTrue(reply.contains("web search"), reply)
        XCTAssertTrue(reply.contains("update check"), reply)
        XCTAssertFalse(reply.contains("ElevenLabs"), reply)
    }

    func testWhatIsOffIsNotNamedAsNeedingTheInternet() {
        let reply = SelfAsk.offlineReply(route: .thisMac(model: "Grux Local 2B"), offlineMode: true,
                                         searchReady: false, updateCheckOn: false, hostedVoice: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertFalse(reply.contains("web search,"), reply)
        XCTAssertFalse(reply.contains("update check"), reply)
        XCTAssertTrue(reply.contains("Offline mode is on"), reply)
        XCTAssertTrue(reply.contains("weather"), reply)
    }

    func testTheHostedVoiceIsNamed() {
        let reply = SelfAsk.offlineReply(route: .thisMac(model: "Grux Local 2B"), offlineMode: false,
                                         searchReady: false, updateCheckOn: false, hostedVoice: true,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("ElevenLabs"), reply)
    }

    func testOnClaudeChatNeedsTheInternetAndALocalModelIsTheWayOffline() {
        let reply = SelfAsk.offlineReply(route: .anthropic, offlineMode: false, searchReady: true,
                                         updateCheckOn: true, hostedVoice: false, localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.hasPrefix("Not"), reply)
        XCTAssertTrue(reply.contains("Anthropic"), reply)
        XCTAssertTrue(reply.contains(Self.paletteDoor), reply)
    }

    func testAnotherMachineIsNamed() {
        let reply = SelfAsk.offlineReply(route: .otherMachine(model: "qwen3.5:4b", host: "studio.local"),
                                         offlineMode: false, searchReady: false, updateCheckOn: false,
                                         hostedVoice: false, localModelsLine: Self.paletteDoor)
        XCTAssertTrue(reply.contains("studio.local"), reply)
        XCTAssertFalse(reply.hasPrefix("Yes"), reply)
    }

    func testRepliesCarryNoDashes() {
        let replies = [
            SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "Grux Local 2B"), chatLocalModel: Self.twoB.id, pick: Self.fourB,
                                 pickInstalled: false, claudeKey: false, localModelsLine: Self.paletteDoor),
            SelfAsk.offlineReply(route: .anthropic, offlineMode: true, searchReady: true, updateCheckOn: true,
                                 hostedVoice: true, localModelsLine: Self.paletteDoor),
        ]
        for reply in replies {
            XCTAssertFalse(reply.contains("\u{2014}") || reply.contains("\u{2013}"), reply)
        }
    }

    // MARK: Talks back, by the Tuning card's own name

    func testTurningTalksBackOffIsAVoiceAskForQuiet() {
        for ask in ["How do I turn off Talks back?", "How do I turn Talks back off?",
                    "how can i turn off talks back"] {
            XCTAssertTrue(VoiceAsk.matches(ask), ask)
            XCTAssertTrue(VoiceAsk.asksForQuiet(ask), ask)
        }
        XCTAssertTrue(VoiceAsk.matches("How do I turn on Talks back?"))
        XCTAssertFalse(VoiceAsk.asksForQuiet("How do I turn on Talks back?"))
        XCTAssertFalse(VoiceAsk.matches("How do I turn off Talks back for my kids' tablet?"))
    }

    /// The ask is answered above the model, so it never reaches it: the order
    /// in `ChatService.send` is pinned like the others.
    func testChatServiceAnswersItBeforeAnyModel() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/ChatService.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let ask = try XCTUnwrap(source.range(of: "SelfAsk.kind(of: trimmed, earlier:"))
        let readiness = try XCTUnwrap(source.range(of: "ChatReadiness.current()"))
        XCTAssertLessThan(ask.lowerBound, readiness.lowerBound)
    }

    // MARK: Wave 65 round 1

    /// P2-1: a fresh install has "Use ElevenLabs voice" on and no key, so the
    /// Mac's own voice reads replies, offline too. The offline answer named
    /// "the ElevenLabs voice" as needing the internet.
    func testTheElevenLabsVoiceNeedsAKey() {
        XCTAssertFalse(SpeechEngine.usesElevenLabs(choice: true, hasKey: false, offline: false), "no key: the Mac's voice")
        XCTAssertTrue(SpeechEngine.usesElevenLabs(choice: true, hasKey: true, offline: false))
        XCTAssertFalse(SpeechEngine.usesElevenLabs(choice: true, hasKey: true, offline: true))
        XCTAssertFalse(SpeechEngine.usesElevenLabs(choice: false, hasKey: true, offline: false))
        XCTAssertFalse(SpeechEngine.usesElevenLabs(choice: false, hasKey: false, offline: true))
    }

    /// The engine and both answers read that one rule, so they cannot drift.
    func testEveryElevenLabsGateReadsTheOneRule() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux")
        let engine = try String(contentsOf: root.appendingPathComponent("SpeechEngine.swift"), encoding: .utf8)
        // Wave 70: both speak paths ask `speaksWithElevenLabs`, which is this rule plus the
        // microphone question, so the Voice pane and the chat chip can read the same one.
        XCTAssertEqual(engine.components(separatedBy: "Self.speaksWithElevenLabs(").count - 1, 2, "speak and speakStreaming")
        XCTAssertTrue(engine.contains("usesElevenLabs(choice: choice, hasKey: hasKey, offline: offline) && !wouldAskForMic"),
                      "speaksWithElevenLabs no longer reads usesElevenLabs")
        XCTAssertFalse(engine.contains("useElevenLabs && !"))
        for file in ["Chat/SelfAsk.swift", "Chat/PrivacyAsk.swift"] {
            let src = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(src.contains("SpeechEngine.usesElevenLabs("), file)
            XCTAssertFalse(src.contains("useElevenLabs && !state.offlineMode"), file)
        }
    }

    /// P2-3: USE on a card sets chat's local model and nothing else, so on a
    /// route that is not the local model it changed nothing, and on a card
    /// already selected there is no USE at all. The model menu under the
    /// message box switches chat to the model and the route together.
    func testOffTheLocalRouteThePickIsChosenFromTheModelMenu() {
        let routes: [PrivacyAsk.Route] = [.anthropic, .custom(name: "OpenRouter", host: "openrouter.ai"),
                                          .thisMac(model: "LM Studio")]
        for route in routes {
            for key: Bool? in [true, false] {
                let installed = SelfAsk.smarterReply(chosen: .local, route: route, chatLocalModel: nil, claudeModel: "claude-sonnet-5",
                                                     pick: Self.fourB, pickInstalled: true, claudeKey: key,
                                                     localModelsLine: Self.paletteDoor)
                XCTAssertFalse(installed.contains("USE"), installed)
                XCTAssertTrue(installed.contains("pick it in the model menu under the message box"), installed)
                let pulled = SelfAsk.smarterReply(chosen: .local, route: route, chatLocalModel: nil, claudeModel: "claude-sonnet-5",
                                                  pick: Self.fourB, pickInstalled: false, claudeKey: key,
                                                  localModelsLine: Self.paletteDoor)
                XCTAssertFalse(pulled.contains("USE"), pulled)
                XCTAssertTrue(pulled.contains("click PULL on its card to download it, then pick it in the model menu under the message box"), pulled)
            }
        }
        // On the local route USE does switch chat, so it stays.
        let local = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: "Grux Local"), chatLocalModel: Self.twoB.id,
                                         pick: Self.fourB, pickInstalled: true, claudeKey: false,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertTrue(local.contains("click USE on its card"), local)
    }

    /// P2-2: chat on the default Haiku was told it ran on "the strongest model
    /// Grux can use", with stronger Claude models one menu away.
    /// 3.3 merge: the model menu draws ClaudeModelCatalog.ids, so the rank is
    /// read against that list (SelfAsk.reply passes it). The catalog's own
    /// fallback, a list ComposerFooter.claudeChoices does not hold.
    func testOnClaudeTheRankReadsTheListTheMenuDraws() {
        let menu = ClaudeModelCatalog.fallback
        XCTAssertNotEqual(menu, ComposerFooter.claudeChoices, "control: the two lists must differ to prove anything")
        let topName = ComposerFooter.displayName(id: menu[0], registryName: nil)
        let second = SelfAsk.smarterReply(chosen: .anthropic, route: .anthropic, chatLocalModel: nil, claudeModel: menu[1],
                                          pick: nil, pickInstalled: false, claudeKey: true,
                                          localModelsLine: Self.paletteDoor, claudeChoices: menu)
        XCTAssertTrue(second.contains("Stronger Claude models are in the model menu under the message box, starting with \(topName)"),
                      second)
        XCTAssertFalse(second.contains("Other Claude models"), "a model the menu lists was called typed: \(second)")
        let top = SelfAsk.smarterReply(chosen: .anthropic, route: .anthropic, chatLocalModel: nil, claudeModel: menu[0],
                                       pick: nil, pickInstalled: false, claudeKey: true,
                                       localModelsLine: Self.paletteDoor, claudeChoices: menu)
        XCTAssertTrue(top.contains("the strongest Claude model in the model menu"), top)
    }

    func testOnClaudeTheModelIsNamedAndOnlyTheTopOneIsTheStrongest() {
        let top = ComposerFooter.claudeChoices[0]
        let topName = ComposerFooter.displayName(id: top, registryName: nil)
        for id in ComposerFooter.claudeChoices.dropFirst() {
            let reply = SelfAsk.smarterReply(chosen: .anthropic, route: .anthropic, chatLocalModel: nil, claudeModel: id, pick: nil,
                                             pickInstalled: false, claudeKey: true, localModelsLine: Self.paletteDoor)
            XCTAssertFalse(reply.contains("strongest"), reply)
            XCTAssertTrue(reply.contains("Claude (\(ComposerFooter.displayName(id: id, registryName: nil)))"), reply)
            XCTAssertTrue(reply.contains("Stronger Claude models are in the model menu under the message box, starting with \(topName)"), reply)
        }
        let best = SelfAsk.smarterReply(chosen: .anthropic, route: .anthropic, chatLocalModel: nil, claudeModel: top, pick: nil,
                                        pickInstalled: false, claudeKey: true, localModelsLine: Self.paletteDoor)
        XCTAssertTrue(best.contains("the strongest Claude model in the model menu"), best)
        XCTAssertFalse(best.contains("Stronger"), best)
        // A model typed in Settings is not on the menu's list: no ranking claimed.
        let typed = SelfAsk.smarterReply(chosen: .anthropic, route: .anthropic, chatLocalModel: nil, claudeModel: "claude-opus-5-5",
                                         pick: nil, pickInstalled: false, claudeKey: true,
                                         localModelsLine: Self.paletteDoor)
        XCTAssertFalse(typed.contains("strongest"), typed)
        XCTAssertFalse(typed.contains("Stronger"), typed)
        XCTAssertTrue(typed.contains("Other Claude models are in the model menu under the message box"), typed)
    }

    /// Round 1 P3: the route carries the composer's name ("Qwen3.8"), never a
    /// prefix of the card's ("Qwen 3.8 27B"), so any catalog model but Grux
    /// Local lost its size and "already the pick" was missed. Chat's local
    /// model is named from its id.
    func testChatsLocalModelIsNamedFromItsIdForAnyCatalogModel() {
        for model in Cookbook.catalog {
            let reply = SelfAsk.smarterReply(chosen: .local, route: .thisMac(model: ComposerFooter.displayName(id: model.id, registryName: nil)),
                                             chatLocalModel: model.id, pick: model, pickInstalled: true, claudeKey: false,
                                             localModelsLine: Self.paletteDoor)
            XCTAssertTrue(reply.hasPrefix("Chat runs on \(Cookbook.personName(for: model.id)),"), reply)
            XCTAssertTrue(reply.contains("already the local model"), reply)
            XCTAssertFalse(reply.contains("USE"), reply)
        }
    }

    // MARK: Wave 65 round 3

    /// Local Models' installed list is empty at every launch until the pane
    /// opens; the launch discovery fills the registry's list. A pick already
    /// pulled read "click PULL" after a relaunch.
    func testAPickPulledBeforeThisLaunchReadsAsDownloaded() {
        let id = Self.fourB.id
        XCTAssertTrue(SelfAsk.pickInstalled(id, managerTags: [], registryHolds: true), "Local Models not opened yet")
        XCTAssertTrue(SelfAsk.pickInstalled(id, managerTags: [id], registryHolds: false))
        XCTAssertFalse(SelfAsk.pickInstalled(id, managerTags: [], registryHolds: false))
        XCTAssertFalse(SelfAsk.pickInstalled(id, managerTags: [Self.twoB.id], registryHolds: false))
    }

    /// The registry answers only for Ollama: an OpenAI-compatible server's
    /// names do not mean pulled. Read where the rule lives.
    func testTheRegistryAnswersOnlyForOllama() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Grux/Backend/ModelRegistry.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(src.contains("localServedByOllama && OllamaManager.isInstalled(modelId, in: localTags)"))
        let ask = try String(contentsOf: url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Chat/SelfAsk.swift"), encoding: .utf8)
        XCTAssertTrue(ask.contains("registryHolds: ModelRegistry.shared.ollamaHolds($0.id)"))
    }
}
