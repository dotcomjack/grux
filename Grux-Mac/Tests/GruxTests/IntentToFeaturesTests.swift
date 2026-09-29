import XCTest
@testable import Grux

/// P-F-1, Task F2: the answer to "What do you want to do with Grux?" selects
/// registry rows. The keyless path is tested first and hardest, because a
/// stranger on a clean Mac has no key and this is the path they all take.
@MainActor
final class IntentToFeaturesTests: XCTestCase {

    private func engine(key: String = "k", _ provider: WorkJudgmentTests.Scripted,
                        ledger: DecisionLedger? = nil) -> DecisionEngine {
        DecisionEngine(keyLookup: { key }, ledger: ledger ?? DecisionLedger(storeURL: nil), remote: { _ in provider })
    }

    // MARK: - The keyless path

    func test_everyAnswerGetsTheFloor_soNobodyIsToldThereIsNothingForThem() {
        let odd = ["", "   ", "no", "I don't know", "asdfghjkl", "🙂", "nothing, just looking",
                   String(repeating: "x", count: 5000)]
        for answer in odd {
            let picked = IntentToFeatures.keyless(answer: answer)
            XCTAssertFalse(picked.isEmpty, "'\(answer.prefix(20))' selected zero features")
            for id in IntentToFeatures.floor + IntentToFeatures.always {
                XCTAssertTrue(picked.contains(id), "'\(answer.prefix(20))' lost \(id)")
            }
        }
    }

    func test_theFloorAndTheAlwaysRowsAreRealRegistryRows() {
        let known = Set(FeatureRegistry.rows.map(\.id))
        for id in IntentToFeatures.floor + IntentToFeatures.always + IntentToFeatures.codeRows {
            XCTAssertTrue(known.contains(id), "\(id) is not a registry row")
        }
        for id in IntentToFeatures.cues.keys {
            XCTAssertTrue(known.contains(id), "a cue names \(id), which is not a registry row")
        }
        XCTAssertEqual(Array(IntentToFeatures.floor), ["chat", "mailbox", "calendar", "notes", "tasks"],
                       "the plan names the floor: Chat, Mail, Calendar, Notes, Tasks")
    }

    func test_wordsTheAnswerUsesSelectTheirRows() {
        let picked = IntentToFeatures.keyless(answer: "Transcribe my meetings and keep me from getting distracted")
        XCTAssertTrue(picked.contains("meetings"))
        XCTAssertTrue(picked.contains("focus"))
        XCTAssertFalse(picked.contains("creative"), "nothing in that answer asks for images")
        let images = IntentToFeatures.keyless(answer: "make thumbnails and product photos for my shop")
        XCTAssertTrue(images.contains("creative"))
    }

    /// Short cues match whole words, so "ui" does not fire on "build" and
    /// "ads" does not fire on "roads".
    func test_shortCuesDoNotMatchInsideOtherWords() {
        let picked = IntentToFeatures.keyless(answer: "I plan road trips and build furniture quietly")
        XCTAssertFalse(picked.contains("design.studio"), "'ui' matched inside a word")
        XCTAssertFalse(picked.contains("meta.ads"), "'ads' matched inside 'roads'")
    }

    func test_iWriteCodeAndItsVariantsUnlockTheDeveloperDoor() {
        let variants = ["I write code", "I'm a software engineer", "coding", "help me program",
                        "I ship iOS apps in Swift and review pull requests", "I'm a developer",
                        "debugging my Python scripts", "working in the terminal all day"]
        for answer in variants {
            let picked = IntentToFeatures.keyless(answer: answer)
            XCTAssertTrue(IntentToFeatures.unlocksDeveloper(picked), "'\(answer)' did not unlock the Developer door")
        }
        let notCode = ["run my inbox", "keep my calendar straight", "plan my week", "write a novel"]
        for answer in notCode {
            XCTAssertFalse(IntentToFeatures.unlocksDeveloper(IntentToFeatures.keyless(answer: answer)),
                           "'\(answer)' unlocked the Developer door")
        }
    }

    func test_theDeveloperDoorIsUnlockedByTheRowsBehindIt_notByASecondList() {
        // Any row whose door is Developer unlocks it, including Local Models,
        // which somebody reaches by asking to stay offline rather than to code.
        XCTAssertTrue(IntentToFeatures.unlocksDeveloper(["cookbook"]))
        XCTAssertTrue(IntentToFeatures.keyless(answer: "keep everything offline on a local model").contains("cookbook"))
        for row in FeatureRegistry.rows {
            XCTAssertEqual(IntentToFeatures.unlocksDeveloper([row.id]), row.disposition == .developer, row.id)
        }
    }

    func test_applyingASelectionOnlyEverRaisesTheDeveloperSwitch() {
        var config = GruxConfig.default
        XCTAssertFalse(config.developerSurfacesUnlocked, "a fresh config starts locked")
        IntentToFeatures.apply(["chat", "notes"], to: &config)
        XCTAssertFalse(config.developerSurfacesUnlocked)
        IntentToFeatures.apply(["chat", "commands"], to: &config)
        XCTAssertTrue(config.developerSurfacesUnlocked)
        IntentToFeatures.apply(["chat"], to: &config)
        XCTAssertTrue(config.developerSurfacesUnlocked, "an answer without code locked a door somebody had opened")
    }

    func test_aRowThatDependsOnAnotherBringsItAlong() {
        let picked = IntentToFeatures.keyless(answer: "tell me who said what")
        XCTAssertTrue(picked.contains("speakers"))
        XCTAssertTrue(picked.contains("meetings"), "Speakers was selected without the Meetings it depends on")
    }

    func test_theSelectionComesBackInRegistryOrder() {
        let picked = IntentToFeatures.keyless(answer: "research, design mockups, meetings and code")
        let order = FeatureRegistry.rows.map(\.id).filter { picked.contains($0) }
        XCTAssertEqual(picked, order)
    }

    func test_askingForOneThingAtATimeIsHeard() {
        XCTAssertTrue(IntentToFeatures.asksForOneAtATime("I have ADHD, keep it simple"))
        XCTAssertTrue(IntentToFeatures.asksForOneAtATime("one thing at a time please"))
        XCTAssertTrue(IntentToFeatures.asksForOneAtATime("I get overwhelmed by setup screens"))
        XCTAssertFalse(IntentToFeatures.asksForOneAtATime("run my inbox and my calendar"))
    }

    // MARK: - The keyed path

    func test_keylessAsksNothingAndRecordsNothing() async {
        let provider = WorkJudgmentTests.Scripted { _ in .noul(0.99) }
        let ledger = DecisionLedger(storeURL: nil)
        let picked = await IntentToFeatures.select(answer: "run my inbox", engine: engine(key: "", provider, ledger: ledger),
                                                   threshold: 0.70)
        XCTAssertEqual(picked, IntentToFeatures.keyless(answer: "run my inbox"))
        XCTAssertEqual(provider.calls.count, 0)
        XCTAssertEqual(ledger.recent.count, 0, "a keyless install recorded a decision it never made")
    }

    func test_aKeyAddsWhatTheWordsMissed_inOneCall_andNeverRemovesAnything() async {
        let provider = WorkJudgmentTests.Scripted { name in
            switch name {
            case "creative": return .noul(0.91)
            case "research": return .noul(0.55)
            default: return .noul(0.05)
            }
        }
        let answer = "help me run my small bakery's online presence"
        let base = IntentToFeatures.keyless(answer: answer)
        let picked = await IntentToFeatures.select(answer: answer, engine: engine(provider), threshold: 0.70)
        XCTAssertEqual(provider.calls.count, 1, "one call for the whole answer")
        XCTAssertTrue(picked.contains("creative"), "a confident pick was dropped")
        XCTAssertFalse(picked.contains("research"), "a pick under the threshold was taken")
        for id in base { XCTAssertTrue(picked.contains(id), "the key removed \(id)") }
        let asked = Set(provider.calls.first?.questions.keys.map { $0 } ?? [])
        for id in base { XCTAssertFalse(asked.contains(IntentToFeatures.questionKey(for: id)), "\(id) was already chosen and was asked about") }
        XCTAssertTrue(provider.calls.first?.state.contains(answer) ?? false, "the engine never saw the answer")
    }

    func test_aFailedProviderFallsBackToTheKeylessAnswer() async {
        let provider = WorkJudgmentTests.Scripted { _ in .noul(0.99) }
        provider.fail = true
        let picked = await IntentToFeatures.select(answer: "run my inbox", engine: engine(provider), threshold: 0.70)
        XCTAssertEqual(picked, IntentToFeatures.keyless(answer: "run my inbox"),
                       "the on-device fallback voted on a question it cannot judge")
    }

    /// Every row the engine can be asked about carries the purpose line the
    /// calibration measured; a row asked about by bare label was never measured.
    func test_everyAskableRowHasTheCalibratedPurpose() {
        let asked = FeatureRegistry.rows.filter { !(IntentToFeatures.floor + IntentToFeatures.always).contains($0.id) }
        XCTAssertEqual(asked.count, 29)  // 30 until Terminal Focus left, 2026-09-27
        XCTAssertEqual(IntentToFeatures.threshold, 0.80, "the threshold moved away from the calibrated one")
        for row in asked {
            XCTAssertNotNil(IntentToFeatures.purposes[row.id], "\(row.id) would be asked about without its purpose")
            guard case .noul(let text) = IntentToFeatures.question(for: row) else { return XCTFail(row.id) }
            XCTAssertTrue(text.hasPrefix("The answer mentions something that \(row.label) is for."), text)
        }
    }

    func test_questionKeysAreSafeNames() {
        for row in FeatureRegistry.rows {
            let key = IntentToFeatures.questionKey(for: row.id)
            XCTAssertNil(key.range(of: "[^a-z0-9_]", options: .regularExpression), "\(key) is not a safe key")
        }
    }
}
