import XCTest
@testable import Grux

/// P-R-2: the voice call offers only the macros that could apply to what was
/// heard. Measured on the live provider over twelve cases: the same choice on
/// all twelve, at a median 1,762 input tokens instead of 4,450. The rule that
/// makes it safe is that a keyless install cannot tell the difference.
@MainActor
final class VoiceVocabularyTrimTests: XCTestCase {

    private func macro(_ name: String, _ triggers: [String]) -> Macro {
        Macro(name: name, triggers: triggers, description: "", rawActions: [.launchApp(name: "Notes")])
    }

    private lazy var macros: [Macro] = [
        macro("overlay_on", ["overlay on", "turn on the overlay", "focus overlay"]),
        macro("overlay_off", ["overlay off", "turn off the overlay", "kill the overlay", "hide overlay"]),
        macro("daddys_home", ["daddy's home", "daddys home"]),
        macro("dash_calendar", ["dash calendar", "calendar dashboard"]),
        macro("lights_low", ["lights low", "dim the lights"]),
        macro("tv", ["tv"]),
    ] + (0..<40).map { macro("filler_\($0)", ["zebra quantum \($0) protocol", "run filler \($0)"]) }

    private func router() -> VoiceCommandRouter {
        let e = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let ms = macros
        return VoiceCommandRouter(engine: e, threshold: { 0.7 }, macros: { ms })
    }

    private let corpus = [
        "Heard: That MGM really creates unforgettable moments. It's the best.",
        "Heard: Hey, did you feed the dog before you left?",
        "Heard: so anyway I was thinking about lunch",
        "Heard: open my calendar",
        "Heard: overlay on",
        "Heard: turn the overlay off please",
        "Heard: stop listening",
        "Heard: daddy's home",
        "Heard: dim the lights a bit",
        "Heard: turn on the tv",
        "Heard: run filler 7",
        "Heard: what's on my calendar today\nGrux last spoke 12s ago and said: I turned the overlay on for you",
    ]

    private func criteria(_ vocab: [VoiceCommand]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: vocab.map { ($0.id, $0.phrases.joined(separator: " | ")) })
    }

    /// Criterion 5: a keyless install answers exactly as before.
    func test_keylessAnswersAreUnchangedByTheTrim() {
        let r = router()
        let full = r.vocabulary()
        for state in corpus {
            let before = LocalDecisionProvider.matchChoice(state: state, criteria: criteria(full))
            let after = LocalDecisionProvider.matchChoice(state: state,
                                                          criteria: criteria(VoiceCommandRouter.offered(full, state: state)))
            guard case .choice(let a, let ac, _) = before, case .choice(let b, let bc, _) = after else {
                return XCTFail("not a choice")
            }
            XCTAssertEqual(a, b, "the keyless choice changed for \(state)")
            XCTAssertEqual(ac, bc, accuracy: 1e-12, "the keyless confidence changed for \(state)")
        }
    }

    /// The property the parity rests on: an option `couldMatch` rejects scores
    /// exactly zero on device.
    func test_anOptionCouldMatchRejectsScoresZeroOnDevice() {
        let crit = criteria(router().vocabulary())
        for state in corpus {
            guard case .choice(_, _, let probs) = LocalDecisionProvider.matchChoice(state: state, criteria: crit) else {
                return XCTFail("not a choice")
            }
            for (id, desc) in crit where id != LocalDecisionProvider.notACommand
                && !LocalDecisionProvider.couldMatch(state: state, description: desc) {
                XCTAssertEqual(probs[id] ?? 0, 0, "\(id) was rejected but scores on device for \(state)")
            }
        }
    }

    func test_chatterCarriesNoMacrosAndACommandCarriesItsOwn() {
        let full = router().vocabulary()
        let chatter = VoiceCommandRouter.offered(full, state: "Heard: so anyway I was thinking about lunch")
        XCTAssertEqual(chatter.filter { $0.id.hasPrefix("macro:") }.count, 0)
        let overlay = VoiceCommandRouter.offered(full, state: "Heard: turn the overlay off please").map(\.id)
        XCTAssertTrue(overlay.contains("macro:overlay_off"))
        XCTAssertFalse(overlay.contains("macro:filler_3"))
        XCTAssertLessThan(overlay.filter { $0.hasPrefix("macro:") }.count, 5)
    }

    /// Running apps are offered when their NAME is heard, not on a shared verb,
    /// and dropping the verb-only ones changes no keyless outcome.
    func test_appsAreOfferedByNameAndKeylessOutcomesHold() {
        let e = DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil))
        let r = VoiceCommandRouter(engine: e, threshold: { 0.7 }, macros: { [] })
        r.runningApps = { ["Safari", "Google Chrome", "Terminal", "Visual Studio Code", "Messages"] }
        let full = r.vocabulary()
        let bringUp = VoiceCommandRouter.offered(full, state: "Heard: bring up my browser").map(\.id)
        XCTAssertFalse(bringUp.contains { $0.hasPrefix("app.") }, "a verb alone pulled in app commands: \(bringUp)")
        let chrome = VoiceCommandRouter.offered(full, state: "Heard: switch to chrome").map(\.id)
        XCTAssertTrue(chrome.contains("app.focus:Google Chrome"))
        XCTAssertFalse(chrome.contains("app.focus:Safari"))
        for state in corpus + ["Heard: bring up my browser", "Heard: open the pod bay doors",
                               "Heard: switch to chrome", "Heard: hide messages", "Heard: focus terminal now"] {
            guard case .choice(let a, _, _) = LocalDecisionProvider.matchChoice(state: state, criteria: criteria(full)),
                  case .choice(let b, _, _) = LocalDecisionProvider.matchChoice(
                      state: state, criteria: criteria(VoiceCommandRouter.offered(full, state: state))) else {
                return XCTFail("not a choice")
            }
            XCTAssertEqual(a, b, "the keyless outcome changed for \(state)")
        }
    }

    /// Tabs and the always-present answers are never trimmed: a tab asked for by
    /// another name still has to be understandable, and the router depends on
    /// say:chat and not_a_command being there.
    func test_tabsAndTheAlwaysPresentAnswersAreAlwaysOffered() {
        let full = router().vocabulary()
        let offered = Set(VoiceCommandRouter.offered(full, state: "Heard: zzz").map(\.id))
        for v in full where !v.id.hasPrefix("macro:") {
            XCTAssertTrue(offered.contains(v.id), "\(v.id) was trimmed")
        }
        XCTAssertTrue(offered.isSuperset(of: [VoiceCommandRouter.sayToChat, LocalDecisionProvider.notACommand, "mute", "unmute"]))
    }
}
