import XCTest
@testable import Grux

/// D186: questions a stranger asks about Grux itself got the local model's
/// guess. Sense pass 24 (6:36 AM Nov 7, grux-local:2b): "Hi! What are you?"
/// got "I'm Jax, your digital mind. I think the way you do things and have the
/// same goals for everything we work on."; "Do you work without internet?" got
/// "I don't have an internet connection"; "Can I use a smarter model?" got
/// "switch to one through your system settings"; "How do I turn off Talks
/// back?" got "the Voice & Ambient app". The persona told every model it was
/// the person's clone, learned or not, and nothing in the prompt said what
/// Grux is, what chat runs on, or where its own controls are. Measured on the
/// dumped context (`logs/s24exp/`): a plain header for a person nothing is
/// learned about plus these facts answered all four right.
@MainActor
final class AboutYouTests: XCTestCase {

    // MARK: The header

    func test_aPersonNothingIsLearnedAboutIsNotToldTheAssistantThinksLikeThem() {
        let p = JaxProfile.persona(name: "Ada", learned: false)
        XCTAssertTrue(p.hasPrefix("You are Ada, the assistant inside Grux AI"), p)
        for claim in ["digital mind", "think the way they think", "unified clone", "the version of them"] {
            XCTAssertFalse(p.contains(claim), "a stranger's prompt still claims \"\(claim)\"")
        }
        XCTAssertTrue(p.contains("know only what they tell you"), p)
    }

    func test_theGuardrailsStayWhateverIsLearned() {
        for learned in [false, true] {
            let p = JaxProfile.persona(name: "Ada", learned: learned)
            XCTAssertTrue(p.contains("You NEVER move money"), "learned=\(learned)")
            XCTAssertTrue(p.contains("WHAT YOU MAY DO ON THEIR BEHALF:"), "learned=\(learned)")
            XCTAssertTrue(p.contains("Ada HQ approval queue"), "learned=\(learned)")
        }
    }

    func test_onceSomethingIsLearnedTheCloneHeaderReturns() {
        let p = JaxProfile.persona(name: "Ada", learned: true)
        XCTAssertTrue(p.hasPrefix("You are Ada, the user's digital mind."), p)
        XCTAssertTrue(p.contains("WHO YOU ARE TO THEM:"), p)
    }

    /// The live persona reads what the profile holds, at build time.
    func test_theLivePersonaFollowsWhatTheProfileHolds() {
        let profile = JaxProfile.shared
        let saved = (profile.heuristics, profile.values)
        defer { profile.heuristics = saved.0; profile.values = saved.1 }
        profile.heuristics = []; profile.values = []
        XCTAssertFalse(profile.persona.contains("digital mind"))
        profile.values = [JaxValue(text: "ship whole things")]
        XCTAssertTrue(profile.persona.contains("digital mind"))
        profile.values = []
        profile.heuristics = [JaxHeuristic(rule: "price by value")]
        XCTAssertTrue(profile.persona.contains("digital mind"))
    }

    // MARK: The facts

    func test_onThisMacTheFactsNameTheModelAndSayNoInternetIsNeeded() {
        let b = AboutYou.block(name: "Jax", route: .thisMac(model: "Grux Local 2B"), offline: false, localModelsLine: "Local Models has the full list.")
        XCTAssertTrue(b.hasPrefix("ABOUT_YOU"), b)
        XCTAssertTrue(b.contains("Your name is Jax. The app is Grux AI."), b)
        XCTAssertTrue(b.contains("Grux Local 2B, a model running on this Mac"), b)
        XCTAssertTrue(b.contains("with no internet connection"), b)
        XCTAssertFalse(b.contains("web search is off"), b)
    }

    func test_aBiggerModelAndTheVoiceSwitchAreWhereTheyReallyAre() {
        let b = AboutYou.block(name: "Jax", route: .thisMac(model: "Grux Local 2B"), offline: false,
                                localModelsLine: "Local Models, under Developer in the sidebar, has the full list.")
        XCTAssertTrue(b.contains("Local Models, under Developer in the sidebar, has the full list."), b)
        XCTAssertFalse(b.contains("Local Models tab"), b)
        XCTAssertTrue(b.contains("Settings, \(SettingsPane.models.label)"), b)
        XCTAssertTrue(b.contains(VoiceAsk.switchName), b)
        XCTAssertTrue(b.contains("Tuning, under \(TuningCopy.Card.talks.title)"), b)
        XCTAssertTrue(b.contains(VoiceAsk.muteButton), b)
    }

    /// D189 leftover: the facts said "the Local Models tab" while Local Models sits
    /// behind the Developer door on a new install. They say where it opens the way
    /// first run and the self answers do, from the same line.
    @MainActor
    func test_theLiveFactsSayWhereLocalModelsOpensLikeFirstRun() {
        let state = AppState.shared
        let saved = state.config.developerSurfacesUnlocked
        defer { state.config.developerSurfacesUnlocked = saved }
        for unlocked in [false, true] {
            state.config.developerSurfacesUnlocked = unlocked
            let door = HowItWorksCopy.localModelsLine(door: FeatureRegistry.disposition(for: "cookbook"),
                                                      developerUnlocked: unlocked)
            let b = AboutYou.block(state: state)
            XCTAssertTrue(b.contains(door), "unlocked=\(unlocked): \(b)")
            XCTAssertFalse(b.contains("Local Models tab") && !door.contains("Local Models tab"), b)
        }
    }

    func test_offlineModeSaysWebSearchIsOff() {
        let b = AboutYou.block(name: "Jax", route: .thisMac(model: "Grux Local 2B"), offline: true, localModelsLine: "Local Models has the full list.")
        XCTAssertTrue(b.contains("Offline mode is on, so web search is off."), b)
    }

    func test_aCloudRouteIsNeverCalledOffline() {
        let b = AboutYou.block(name: "Jax", route: .anthropic, offline: false, localModelsLine: "Local Models has the full list.")
        XCTAssertTrue(b.contains("through the Anthropic API, over the internet"), b)
        XCTAssertFalse(b.contains("no internet"), b)
        XCTAssertFalse(b.contains("running on this Mac"), b)
    }

    func test_aModelOnAnotherMachineNamesThatMachine() {
        let b = AboutYou.block(name: "Jax", route: .otherMachine(model: "Qwen 3.5 4B", host: "studio.local"), offline: false, localModelsLine: "Local Models has the full list.")
        XCTAssertTrue(b.contains("Qwen 3.5 4B on studio.local"), b)
        XCTAssertFalse(b.contains("running on this Mac"), b)
        XCTAssertFalse(b.contains("no internet"), b)
    }

    func test_aCustomEndpointNamesItsHost() {
        let b = AboutYou.block(name: "Jax", route: .custom(name: "OpenRouter", host: "openrouter.ai"), offline: false, localModelsLine: "Local Models has the full list.")
        XCTAssertTrue(b.contains("OpenRouter at openrouter.ai"), b)
        XCTAssertFalse(b.contains("no internet"), b)
    }

    func test_withNoModelTheFactsSayWhatChatNeeds() {
        let b = AboutYou.block(name: "Jax", route: .none(step: "Chat needs a model first."), offline: false, localModelsLine: "Local Models has the full list.")
        XCTAssertTrue(b.contains("Chat needs a model first."), b)
        XCTAssertFalse(b.contains("Your replies come from"), b)
    }

    func test_theFactsCarryNoDash() {
        for route: PrivacyAsk.Route in [.thisMac(model: "m"), .anthropic, .none(step: nil),
                                        .otherMachine(model: "m", host: "h"), .custom(name: "n", host: "h")] {
            for offline in [false, true] {
                let b = AboutYou.block(name: "Jax", route: route, offline: offline, localModelsLine: "Local Models has the full list.")
                XCTAssertFalse(b.contains("\u{2014}") || b.contains("\u{2013}"), b)
            }
        }
    }

    // MARK: Wiring

    /// Both prompts carry the facts right after the header: the lean local one
    /// (the route this sense pass measured) and the full one.
    func test_everyChatPromptCarriesTheFactsAfterTheHeader() {
        let saved = AppState.shared.chat
        defer { AppState.shared.chat = saved }
        AppState.shared.chat = [ChatMessage(role: .user, content: "Hi! What are you?")]
        for lean in [true, false] {
            let p = ChatService.shared.assemblePendingContext(state: AppState.shared, lean: lean, window: 16_384)
            let text = p.systemBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            guard let about = text.range(of: "ABOUT_YOU"), let you = text.range(of: "You are ") else {
                return XCTFail("lean=\(lean): no ABOUT_YOU block in the chat prompt")
            }
            XCTAssertLessThan(you.lowerBound, about.lowerBound, "lean=\(lean)")
            if let voice = text.range(of: "VOICE & VIBE") {
                XCTAssertLessThan(about.lowerBound, voice.lowerBound, "lean=\(lean)")
            }
        }
    }
}
