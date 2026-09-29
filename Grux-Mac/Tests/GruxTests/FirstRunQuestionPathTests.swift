import XCTest
@testable import Grux

/// P-F-1: the question path. First run is the question alone (shape A), then a
/// flow built from the answer: "Here's your Grux", the name, the model (three
/// ways), How Grux works, setup one thing at a time, and Chat.
@MainActor
final class FirstRunQuestionPathTests: XCTestCase {
    typealias Stage = OnboardingModel.Stage

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The body of `name` in `src`, to its closing brace: a top-level type
    /// ends at "\n}\n", a member at "\n    }\n", so an assertion reads only
    /// that screen or that function and cannot pass on text elsewhere.
    private func body(of name: String, in src: String, member: Bool = false) throws -> String {
        let start = try XCTUnwrap(src.range(of: name), "\(name) is missing")
        let rest = src[start.lowerBound...]
        let close = member ? "\n    }\n" : "\n}\n"
        let end = try XCTUnwrap(rest.dropFirst(name.count).range(of: close), "\(name) has no end").upperBound
        return String(rest[..<end])
    }

    // MARK: - The order

    func test_theQuestionComesFirst_andTheFlowIsPersonalBeforeItAsks() {
        let flow = OnboardingModel.questionStages
        XCTAssertEqual(flow, [.prompt, .yourGrux, .identity, .modelKey, .howItWorks, .setup, .update, .done])
        XCTAssertFalse(flow.contains(.level), "the levels are behind \"pick from a list\", not in this flow")
        for stage in [Stage.permissions, .firstLook, .clone, .connections] {
            XCTAssertFalse(flow.contains(stage), "\(stage) is asked by setup, for what the answer picked")
        }
        let i = { (s: Stage) in flow.firstIndex(of: s)! }
        XCTAssertLessThan(i(.yourGrux), i(.identity), "what Grux will do is shown before anything is asked")
        XCTAssertLessThan(i(.identity), i(.modelKey), "the name before any credential")
        XCTAssertLessThan(i(.howItWorks), i(.setup), "setup's permissions come after the screen that explains Grux")
    }

    func test_walkingTheQuestionPathVisitsEveryStageOnce_andEnds() {
        var seen: [Stage] = [.prompt]
        var current = Stage.prompt
        while let next = OnboardingModel.stage(after: current, in: OnboardingModel.questionStages) {
            seen.append(next); current = next
            if seen.count > 20 { break }
        }
        XCTAssertEqual(seen, OnboardingModel.questionStages)
    }

    func test_theLevelsAreExactlyWhatTheyWere() {
        for level in OnboardingModel.Level.allCases {
            XCTAssertEqual(OnboardingModel.stages(path: .list, level: level), OnboardingModel.stages(for: level))
            XCTAssertEqual(OnboardingModel.stages(path: .question, level: level), OnboardingModel.questionStages,
                           "the level must not change the question path")
        }
    }

    // MARK: - What a stranger starts with, and what an older file decodes to

    func test_aNewInstallStartsAtTheQuestion_andHasReviewedNoFrame() {
        let s = OnboardingModel.State.initial
        XCTAssertEqual(s.stage, .prompt)
        XCTAssertEqual(s.path, .question)
        XCTAssertEqual(s.answer, "")
        XCTAssertTrue(s.skippedFirstLook, "a new install has been shown no frame")
    }

    func test_aFileFromBeforeTheQuestionStaysOnTheLevels() throws {
        let old = try JSONDecoder().decode(OnboardingModel.State.self,
                                           from: Data(#"{"stage":"permissions","level":"everything"}"#.utf8))
        XCTAssertEqual(old.path, .list, "an in-flight install would lose its place")
        XCTAssertEqual(old.answer, "")
        XCTAssertEqual(old.stage, .permissions)
    }

    // MARK: - Consent: a frame counts as reviewed only when it was shown

    func test_theQuestionPathNeverRecordsAFrameNobodySaw() {
        // Finished, first look never came up: not reviewed, whatever the level.
        for level in OnboardingModel.Level.allCases {
            XCTAssertFalse(CapabilityResolver.firstFrameWasReviewed(stage: .done, skippedFirstLook: true,
                                                                    level: level, path: .question))
        }
        // The first look's own Continue clears the flag: reviewed.
        XCTAssertTrue(CapabilityResolver.firstFrameWasReviewed(stage: .done, skippedFirstLook: false,
                                                               level: .essentials, path: .question))
        XCTAssertFalse(CapabilityResolver.firstFrameWasReviewed(stage: .setup, skippedFirstLook: false,
                                                                level: .essentials, path: .question))
        // The levels are unchanged.
        XCTAssertTrue(CapabilityResolver.firstFrameWasReviewed(stage: .done, skippedFirstLook: false, level: .plusPermissions))
        XCTAssertFalse(CapabilityResolver.firstFrameWasReviewed(stage: .done, skippedFirstLook: false, level: .essentials))
    }

    func test_theFirstLookInSetupRecordsTheReview() throws {
        let src = try source("Sources/Grux/Onboarding/FirstRunScreens.swift")
        let look = try XCTUnwrap(src.components(separatedBy: "req == .stepFirstFrameReviewed {").dropFirst().first)
        XCTAssertTrue(look.prefix(500).contains("model.recordFirstLookReviewed()"),
                      "the first look in setup never records that it was shown")
    }

    // MARK: - Chat, with a first exchange done (decision 13)

    func test_theFirstExchangeIsTheirOwnAnswer_onlyWhenAModelCanTakeIt() {
        XCTAssertEqual(OnboardingModel.firstExchange(path: .question, answer: "  run my inbox ", modelReady: true), "run my inbox")
        XCTAssertNil(OnboardingModel.firstExchange(path: .question, answer: "run my inbox", modelReady: false),
                     "a turn that fails is a worse first exchange than none")
        XCTAssertNil(OnboardingModel.firstExchange(path: .question, answer: "   ", modelReady: true))
        XCTAssertNil(OnboardingModel.firstExchange(path: .list, answer: "run my inbox", modelReady: true))
    }

    func test_theFirstExchangeIsSentFromFinish_andNeverUnderTest() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingModel.swift")
        let finish = try body(of: "func finish(skippedFirstLook: Bool, sendFirstExchange: Bool = true) {", in: src, member: true)
        XCTAssertTrue(finish.contains("!DecisionEngine.isUnderTest"), "a test run could send a chat turn")
        XCTAssertTrue(finish.contains("if sendFirstExchange,"), "a scripted finish could send the person's answer")
        XCTAssertTrue(finish.contains("ChatService.shared.send(userText: first)"))
        // Task 10 (R10.4): first run lands with Optimize open, and on Chat
        // only under the classic sidebar, whether or not a first exchange was
        // sent. The exchange still lands in the chat thread.
        let gate = try XCTUnwrap(finish.range(of: "!DecisionEngine.isUnderTest"))
        let landing = try XCTUnwrap(finish.range(of: "if AppState.shared.config.legacyShell { AppState.shared.requestedTab = \"chat\" }"),
                                    "the classic sidebar does not end on Chat")
        let hub = try XCTUnwrap(finish.range(of: "OptimizeHubState.shared.isExpanded = true"), "the flow does not open Optimize")
        let gated = finish[gate.lowerBound...].prefix { $0 != "}" }
        XCTAssertFalse(gated.contains("requestedTab"), "the landing only happens after a first exchange")
        XCTAssertGreaterThan(landing.lowerBound, gate.upperBound)
        XCTAssertGreaterThan(hub.lowerBound, gate.upperBound)
        XCTAssertEqual(finish.components(separatedBy: "requestedTab").count, 2, "finish moves the panel shell's request")
    }

    // MARK: - No macOS prompt before its screen explains it

    func test_theScreensBeforeSetupAskMacOSForNothing() throws {
        let screens = try source("Sources/Grux/Onboarding/FirstRunScreens.swift")
        let steps = try source("Sources/Grux/Onboarding/OnboardingSteps.swift")
        let view = try source("Sources/Grux/Onboarding/OnboardingView.swift")
        let asks = ["CapabilityRequest.request(", "requestAccess", "CGRequestScreenCaptureAccess",
                    "ListeningController", "requestAuthorization"]
        for (name, text) in [("YourGruxStep", try body(of: "struct YourGruxStep", in: screens)),
                             ("HowItWorksStep", try body(of: "struct HowItWorksStep", in: steps)),
                             ("IdentityStep", try body(of: "struct IdentityStep", in: view)),
                             ("ModelKeyStep", try body(of: "struct ModelKeyStep", in: view)),
                             ("FirstPromptStep", try body(of: "struct FirstPromptStep", in: screens))] {
            for ask in asks {
                XCTAssertFalse(text.contains(ask), "\(name) raises a macOS prompt (\(ask)) before setup explains it")
            }
        }
    }

    /// The one microphone on the question screen: an undecided microphone
    /// gets the explanation first, and dictation starts only from it.
    func test_theMicrophoneExplainsItselfBeforeMacOSAsks() throws {
        let prompt = try body(of: "struct FirstPromptStep", in: try source("Sources/Grux/Onboarding/FirstRunScreens.swift"))
        XCTAssertTrue(prompt.contains("case .authorized: startDictation()"), "a granted microphone should just start")
        XCTAssertTrue(prompt.contains("default: micExplained = true"), "an undecided microphone starts without explaining")
        XCTAssertEqual(prompt.components(separatedBy: "startDictation()").count - 1, 3,
                       "startDictation is reached from somewhere other than the granted case and the explanation's button")
        XCTAssertTrue(prompt.contains("Button(\"Use the microphone\") { micExplained = false; startDictation() }"))
        XCTAssertTrue(FirstPrompt.micExplanation.contains("asks macOS for the microphone"))
        XCTAssertTrue(FirstPrompt.micExplanation.contains("not listening"),
                      "dictation must not be mistaken for turning listening on")
    }

    /// In setup, every ask sits in a button on the item's own screen, whose
    /// reason is drawn above it; nothing asks on appear.
    func test_setupAsksOnlyFromAButtonOnTheItemsOwnScreen() throws {
        let setup = try body(of: "struct SetupStep", in: try source("Sources/Grux/Onboarding/FirstRunScreens.swift"))
        let onAppear = try XCTUnwrap(setup.components(separatedBy: ".onAppear {").dropFirst().first).prefix(200)
        XCTAssertFalse(onAppear.contains("request") || onAppear.contains("apply()"), "setup asks on appear")
        let card = try body(of: "private func itemCard(", in: setup, member: true)
        let why = try XCTUnwrap(card.range(of: "Setup.why(item)"))
        let act = try XCTUnwrap(card.range(of: "action(item, walking: walking)"))
        XCTAssertLessThan(why.lowerBound, act.lowerBound, "the control is drawn before its reason")
        var rest = Substring(setup)
        var asks = 0
        while let r = rest.range(of: "CapabilityRequest.request(") {
            asks += 1
            let before = setup[setup.startIndex..<r.lowerBound].suffix(400)
            XCTAssertTrue(before.contains("Button("), "a permission is requested outside a button")
            rest = rest[r.upperBound...]
        }
        XCTAssertEqual(asks, 1, "the scan found a different number of asks than exist")
    }

    // MARK: - One at a time, for everyone; the Decisions key in the extras

    func test_setupIsOneAtATimeForEveryone() throws {
        let setup = try body(of: "struct SetupStep", in: try source("Sources/Grux/Onboarding/FirstRunScreens.swift"))
        XCTAssertTrue(setup.contains("@State private var oneAtATime = true"))
        XCTAssertEqual(Setup.wholeList, "See the whole list")
    }

    private func plan(required: Int, optional: Int) -> SetupOrder.Plan {
        let reqs: [SetupRequirement] = [.permCalendar, .permContacts, .keySlack, .keyNotion]
        let opts: [SetupRequirement] = [.keyBrave, .keyReplicate, .stepYoutubeTranscriptsEnabled]
        return SetupOrder.Plan(ready: ["chat"],
                               required: reqs.prefix(required).map { .init(requirement: $0, neededBy: ["tasks"]) },
                               optional: opts.prefix(optional).map { .init(requirement: $0, neededBy: ["research"]) })
    }

    func test_theDecisionsKeyIsOfferedAmongTheExtras_andNLeftStaysTrue() {
        let p = plan(required: 2, optional: 2)
        let offered = SetupOrder.screens(for: p, oneAtATime: true, extrasAccepted: false, decisionsKey: true)
        XCTAssertEqual(offered.compactMap { if case .offerExtras(let n, _) = $0 { return n } else { return nil } }, [3],
                       "the offer does not count the Decisions key")
        XCTAssertFalse(offered.contains { if case .decisionsKey = $0 { return true } else { return false } },
                       "skipping the extras still showed the key")

        let taken = SetupOrder.screens(for: p, oneAtATime: true, extrasAccepted: true, decisionsKey: true)
        guard case .decisionsKey(let last)? = taken.last else { return XCTFail("the key is not the last extra") }
        XCTAssertEqual(last, 1)
        let asking = taken.filter { $0.remaining > 0 }
        XCTAssertEqual(asking.first?.remaining, asking.count, "\"N left\" on the first screen is not the number of screens")
        for (a, b) in zip(asking, asking.dropFirst()) { XCTAssertEqual(a.remaining - 1, b.remaining) }

        let list = SetupOrder.screens(for: p, oneAtATime: false, extrasAccepted: false, decisionsKey: true)
        XCTAssertTrue(list.contains { if case .decisionsKey = $0 { return true } else { return false } })
        XCTAssertEqual(SetupOrder.screens(for: p, oneAtATime: true, extrasAccepted: true),
                       SetupOrder.screens(for: p, oneAtATime: true, extrasAccepted: true, decisionsKey: false),
                       "the default must leave every existing caller as it was")
    }

    func test_theKeyIsOfferedOnlyToAnInstallWithoutOne_andNamedInHowGruxWorks() throws {
        XCTAssertTrue(try source("Sources/Grux/Onboarding/FirstRunScreens.swift")
            .contains("static var offersDecisionsKey: Bool { !DecisionEngine.shared.hasSavedKey }"))
        let names = HowItWorksStep.wayfinding.map(\.title)
        XCTAssertTrue(names.contains(HowItWorksCopy.decisionsKeyTitle), "How Grux works never names the Decisions key")
        XCTAssertTrue(names.contains(TuningCopy.title), "How Grux works never names Tuning")
        XCTAssertTrue(HowItWorksCopy.decisionsKeyBody.contains("Integrations"), "the key's permanent home is not named")
        XCTAssertTrue(HowItWorksCopy.decisionsKeyBody.contains("$0.02"))
    }

    // MARK: - The model, three ways

    func test_theModelGateOffersTheThreeChosenPaths() throws {
        let gate = try body(of: "struct ModelKeyStep", in: try source("Sources/Grux/Onboarding/OnboardingView.swift"))
        // What the screen DRAWS, not what the file merely defines: a path
        // written and never placed in the body is not a path.
        let drawn = try body(of: "var body: some View {", in: gate, member: true)
        XCTAssertTrue(drawn.contains("SecureField(\"sk-ant-...\""), "no Anthropic key field")
        XCTAssertTrue(drawn.contains("Button(\"Use a local model instead\")"), "no local model path")
        XCTAssertTrue(drawn.contains("openRouterPath"), "the OpenRouter path is defined and never drawn")
        XCTAssertTrue(gate.contains("Button(ModelPaths.openRouterButton)"), "no OpenRouter button")
        XCTAssertTrue(drawn.contains("Button(\"Keep the key I have\")"), "a re-run loses the way to keep its key")
        XCTAssertTrue(gate.contains("ModelRegistry.shared.resolvedProvider == .custom(ep.id)"),
                      "the OpenRouter path does not read its route back")
    }

    /// OpenRouter's model list is public, so only its key endpoint can tell a
    /// good key from a bad one (measured 2026-09-21: 401 bogus, 200 real).
    func test_theOpenRouterKeyIsJudgedByOpenRouter() {
        XCTAssertEqual(ModelPaths.verdict(status: 200), .accept)
        for bad in [401, 403, 402, 500, 0] {
            if case .accept = ModelPaths.verdict(status: bad) { XCTFail("\(bad) accepted a key OpenRouter did not") }
        }
        XCTAssertEqual(ModelPaths.openRouterBase, "https://openrouter.ai/api/v1")
        XCTAssertEqual(ModelPaths.openRouterModel, "deepseek/deepseek-v4-flash-0731")
    }

    // MARK: - Here's your Grux

    func test_yourGruxShowsWhatWasPicked_inPlainWords() {
        let picked = IntentToFeatures.keyless(answer: "")
        let shown = YourGrux.shown(picked)
        for plumbing in IntentToFeatures.always { XCTAssertFalse(shown.contains(plumbing), "\(plumbing) is plumbing") }
        for id in IntentToFeatures.floor {
            XCTAssertTrue(shown.contains(id), "the floor lost \(id)")
            let line = YourGrux.purpose(id)
            XCTAssertFalse(line.isEmpty, "\(id) has no line")
            XCTAssertEqual(line.first.map { String($0) }, line.first.map { String($0).uppercased() })
            XCTAssertTrue(line.hasSuffix("."))
        }
        let saved = YourGrux.withRequired(["mailbox"])
        for id in ["chat"] + IntentToFeatures.always { XCTAssertTrue(saved.contains(id), "\(id) was dropped from what is saved") }
        XCTAssertTrue(YourGrux.others(picked).allSatisfy { !picked.contains($0) })
        XCTAssertTrue(YourGrux.lead(answer: "", count: 5).contains("basics"))
        XCTAssertTrue(YourGrux.lead(answer: "run my inbox", count: 7).contains("nothing is asked for yet"))
    }

    // MARK: - Listening in setup

    func test_theListeningItemIsDoneOnlyWhenAnswered_andTheMicrophoneIsSharedHonestly() {
        let alone = SetupOrder.Item(requirement: .permMicrophone, neededBy: [SetupOrder.listeningId])
        let shared = SetupOrder.Item(requirement: .permMicrophone, neededBy: ["meetings", SetupOrder.listeningId])
        XCTAssertFalse(Setup.isDone(alone, listeningChosen: false, micGranted: true), "a saved mode is not this run's answer")
        XCTAssertTrue(Setup.isDone(alone, listeningChosen: true, micGranted: false), "\"keep it off\" is an answer")
        XCTAssertFalse(Setup.isDone(shared, listeningChosen: true, micGranted: false),
                       "keeping listening off left Meetings without the microphone it needs")
        XCTAssertTrue(Setup.isDone(shared, listeningChosen: true, micGranted: true))
    }

    // MARK: - The words

    func test_howGruxWorksSaysWhatListeningIsIn30() throws {
        let steps = try source("Sources/Grux/Onboarding/OnboardingSteps.swift")
        XCTAssertFalse(steps.contains("Two voice features ship switched off"), "the 2.x listening line is back")
        let line = try XCTUnwrap(steps.components(separatedBy: "point(\"What is off until you say so\",").dropFirst().first).prefix(900)
        for phrase in ["Listening is off until you turn it on", "Ambient mode", "wake word", "Tuning", "never leaves this Mac"] {
            XCTAssertTrue(line.contains(phrase), "the listening line lost \"\(phrase)\"")
        }
    }

    func test_theQuestionScreenSaysWhatTheAcceptedRenderSays() {
        XCTAssertEqual(FirstPrompt.listening.lead, "Listening is off until you turn it on, later in this setup.")
        XCTAssertEqual(FirstPrompt.pickFromAList, "I would rather pick from a list")
        for line in [FirstPrompt.listening.lead, FirstPrompt.listening.body, FirstPrompt.micExplanation,
                     FirstPrompt.micRefused, YourGrux.footnote, Setup.decisionsKeyWhy, ModelPaths.openRouterBody,
                     HowItWorksCopy.decisionsKeyBody] + YourGrux.floorPurposes.values {
            XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"), line)
        }
    }
}
