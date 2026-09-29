import XCTest
@testable import Grux

/// THE FOUR THINGS A WIPED MAC SHOWED ON 2026-09-22.
///
/// Walking a genuine first run found a flow that asked for what it could read,
/// asked for a key without looking whether one was needed, hid its own primary
/// button below the fold, and skipped the step it had just promised. None of it
/// failed a test, because none of it is wrong in any single function: it is all
/// in the seams between a view's layout and what the machine already knows.
@MainActor
final class FirstRunVisualFrictionTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: - 1. The name macOS already knows

    func test_theSuggestedNameIsTheFirstWordOfARealName() {
        XCTAssertEqual(Identity.suggestedName(fullName: "Ada Lovelace"), "Ada")
        XCTAssertEqual(Identity.suggestedName(fullName: "  Ada Lovelace  "), "Ada")
        XCTAssertEqual(Identity.suggestedName(fullName: "Ada"), "Ada")
        XCTAssertEqual(Identity.suggestedName(fullName: "Mary-Jane Watson"), "Mary-Jane")
        XCTAssertEqual(Identity.suggestedName(fullName: "O'Brien Smith"), "O'Brien")
        // A lowercase full name still carries a surname, so it is a name.
        XCTAssertEqual(Identity.suggestedName(fullName: "ada lovelace"), "ada")
    }

    /// A WRONG PREFILL IS WORSE THAN AN EMPTY FIELD, because it is accepted
    /// without being read and then Grux uses it forever.
    func test_aShortAccountNameIsNotOfferedAsAName() {
        XCTAssertEqual(Identity.suggestedName(fullName: "svcacct"), "",
                       "a lowercase single word is an account short name, not a name")
        XCTAssertEqual(Identity.suggestedName(fullName: "admin"), "")
        XCTAssertEqual(Identity.suggestedName(fullName: ""), "")
        XCTAssertEqual(Identity.suggestedName(fullName: "   "), "")
        XCTAssertEqual(Identity.suggestedName(fullName: "d"), "", "one letter is not a name")
        XCTAssertEqual(Identity.suggestedName(fullName: "501"), "")
        XCTAssertEqual(Identity.suggestedName(fullName: "ada.lovelace@example.com"), "",
                       "a managed Mac can carry the login address as the full name")
        XCTAssertEqual(Identity.suggestedName(fullName: "Ada2 Lovelace"), "",
                       "digits mean this is an identifier, not a name")
    }

    func test_theIdentityScreenFillsTheFieldBeforeItAsks() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingView.swift")
        let step = try XCTUnwrap(body(of: "struct IdentityStep", in: src))
        XCTAssertTrue(step.contains("Identity.systemSuggestion"),
                      "the name field ships empty again, though macOS already knows the name")
    }

    // MARK: - 2. Look before asking for a key

    func test_theModelGateProbesBeforeItAsks() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingView.swift")
        let step = try XCTUnwrap(body(of: "struct ModelKeyStep", in: src))
        XCTAssertTrue(step.contains("probeForLocalModel"),
                      "the model gate asks for an Anthropic key without looking whether a local model is already running")
        XCTAssertTrue(step.contains(".task { await probeForLocalModel() }"),
                      "the probe exists but nothing runs it when the screen appears")
    }

    func test_theProbeOnlySpeaksWhenItFoundSomething() {
        XCTAssertNil(ModelGate.Probe.none.model)
        XCTAssertEqual(ModelGate.Probe.found("qwen3:8b").model, "qwen3:8b")
        XCTAssertTrue(ModelGate.foundDetail(model: "qwen3:8b").contains("qwen3:8b"),
                      "the screen must name what it found, not just claim it found something")
    }

    // MARK: - 3. The primary action cannot scroll away

    /// Every screen a stranger walks declares its action for the pinned bar.
    func test_everyScreenOnTheStrangerPathPinsItsPrimaryAction() throws {
        let view = try source("Sources/Grux/Onboarding/OnboardingView.swift")
        let screens = try source("Sources/Grux/Onboarding/FirstRunScreens.swift")
        let steps = try source("Sources/Grux/Onboarding/OnboardingSteps.swift")

        for (name, src) in [("struct IdentityStep", view), ("struct ModelKeyStep", view),
                            ("struct YourGruxStep", screens),
                            ("struct HowItWorksStep", steps), ("struct UpdateStep", steps)] {
            let step = try XCTUnwrap(body(of: name, in: src), "\(name) not found at all")
            XCTAssertTrue(step.contains(".onboardingPrimary("),
                          "\(name) keeps its button inside the scroll area, where content height can push it off screen")
        }
    }

    /// And the bar is rendered OUTSIDE the scroll area, which is the whole
    /// point: a footer inside a `ScrollView` scrolls with everything else.
    func test_theFooterBarIsNotInsideTheScrollView() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingView.swift")
        let body = try XCTUnwrap(self.body(of: "struct OnboardingView", in: src))
        XCTAssertTrue(body.contains("OnboardingFooterBar"), "control: the footer is not rendered at all")

        let scrollStart = try XCTUnwrap(body.range(of: "ScrollView {"))
        // The chain ends at the modifier applied to the ScrollView itself.
        let scrollEnd = try XCTUnwrap(body.range(of: ".scrollIndicators(", range: scrollStart.upperBound..<body.endIndex))
        let inside = String(body[scrollStart.upperBound..<scrollEnd.lowerBound])
        XCTAssertFalse(inside.contains("OnboardingFooterBar"),
                       "the pinned bar is inside the ScrollView, so it scrolls away with the content it was meant to outlive")
    }

    /// MOVING THE BUTTON OUT OF THE CONTENT BROKE THE RETURN KEY, and only on
    /// the two screens with a text field, because a focused field swallows the
    /// key before the pinned button's shortcut ever sees it. Measured on a
    /// wiped Mac: typing a name and pressing Return did nothing.
    func test_theTwoScreensWithAFieldStillSubmitOnReturn() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingView.swift")

        let identity = withoutComments(try XCTUnwrap(body(of: "struct IdentityStep", in: src)))
        XCTAssertTrue(identity.contains(".onSubmit { commit() }"),
                      "Return in the name field goes nowhere, because the button is no longer in the content")
        // BOTH HALVES. `onSubmit` fires only on a field that holds focus, and
        // this screen held focus nowhere, so Return reached neither the field
        // nor the pinned button's default action.
        XCTAssertTrue(identity.contains(".focused($nameFocused)") && identity.contains("nameFocused = true"),
                      "the name field never takes focus, so its onSubmit can never fire")

        let gate = withoutComments(try XCTUnwrap(body(of: "struct ModelKeyStep", in: src)))
        XCTAssertTrue(gate.contains(".onSubmit {"),
                      "Return after pasting a key goes nowhere")
        XCTAssertTrue(gate.contains("runPrimary()"), "the field's Return must run the same action as the bar")
    }

    func test_twoActionsThatReadTheSameAreTheSameBar() {
        // Equality ignores the closures on purpose: comparing them would make
        // the preference change on every redraw and drive an update loop.
        let a = OnboardingPrimaryAction(title: "Continue", enabled: true, secondaryTitle: nil,
                                        run: {}, runSecondary: nil)
        let b = OnboardingPrimaryAction(title: "Continue", enabled: true, secondaryTitle: nil,
                                        run: { XCTFail("never run") }, runSecondary: nil)
        XCTAssertEqual(a, b)
        let disabled = OnboardingPrimaryAction(title: "Continue", enabled: false, secondaryTitle: nil,
                                               run: {}, runSecondary: nil)
        XCTAssertNotEqual(a, disabled, "the bar must redraw when the button becomes disabled")
    }

    // MARK: - 4. Setup may not skip itself

    /// The property that makes the skip bug impossible to reason away: a plan
    /// built from ANY feature always has something to show, because a feature is
    /// either ready or it is not.
    func test_anyChosenFeatureProducesAtLeastOneScreen() {
        let ids = IntentToFeatures.keyless(answer: "run my inbox and help me ship code")
        let chosen = Set(YourGrux.withRequired(ids))
        let rows = FeatureRegistry.rows.filter { chosen.contains($0.id) }
        XCTAssertFalse(rows.isEmpty, "control: the answer picked nothing, so this proves nothing")

        for satisfied in [false, true] {
            let plan = SetupOrder.plan(features: rows, listening: true, listeningStarted: satisfied,
                                       satisfied: { _ in satisfied })
            let screens = SetupOrder.screens(for: plan, oneAtATime: true, extrasAccepted: false)
            XCTAssertFalse(screens.isEmpty,
                           "with \(rows.count) features and satisfied=\(satisfied) the setup step had nothing to show")
        }
    }

    /// The skip decision must be taken against a plan VALUE. Reading the
    /// `@State` it was written to on the line before is what skipped the whole
    /// step on a real first run.
    func test_theSkipDecisionDoesNotGoThroughTheStateItJustWrote() throws {
        let src = try source("Sources/Grux/Onboarding/FirstRunScreens.swift")
        // WITHOUT COMMENTS. The comment above the fix quotes the exact line the
        // fix removed, which is the whole point of writing it down, and a scan
        // that reads prose fails on the explanation rather than on the code.
        let step = withoutComments(try XCTUnwrap(body(of: "struct SetupStep", in: src)))
        XCTAssertTrue(step.contains("finish()"), "control: the scan lost the code along with the prose")
        XCTAssertFalse(step.contains("if screens.isEmpty { finish() }"),
                       "the skip reads the computed property backed by @State, which returns [] until the plan propagates")
        XCTAssertTrue(step.contains("Setup.screens(for: live"),
                      "the skip must be computed from the plan it just built, not from state")
    }

    /// THE SECOND WAY OUT OF THE SAME STEP, and the one that actually fired.
    /// "No screen at this index" means either "the plan is not built" or "we
    /// walked past the end", and only the second is finished.
    func test_theStepOnlyEndsWhenItHasRunOutOfScreens() throws {
        let src = try source("Sources/Grux/Onboarding/FirstRunScreens.swift")
        let step = withoutComments(try XCTUnwrap(body(of: "struct SetupStep", in: src)))
        XCTAssertFalse(step.contains("onAppear { if plan != nil { finish() } }"),
                       "a non-nil plan is not the same as having shown every screen")
        XCTAssertTrue(step.contains("index >= screens.count"),
                      "the step must end on running out of screens, not on the plan existing")
    }

    /// FIXING THE SKIP EXPOSED A SCREEN NOBODY HAD SEEN. The mail server card
    /// rendered a title, who it was for, and then nothing: `why` is empty for
    /// everything that is configured rather than granted, and `instructions`
    /// holds only the text AFTER the first sentence, which for a one-sentence
    /// remediation is nothing. The ask itself was rendered nowhere.
    func test_everySetupCardExplainsItself() {
        for req in SetupRequirement.allCases {
            let item = SetupOrder.Item(requirement: req, neededBy: ["mailbox"])
            let shown = Setup.why(item).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(shown.isEmpty,
                           "\(req.rawValue) draws a card with a title and no explanation under it")
        }
    }

    func test_theAskIsTheFirstSentenceAndInstructionsAreTheRest() {
        for req in SetupRequirement.allCases {
            XCTAssertFalse(req.ask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(req.rawValue) has no ask at all")
            // Together they are the whole remediation, so nothing is dropped
            // and nothing is said twice.
            let rejoined = (req.ask + " " + req.instructions).trimmingCharacters(in: .whitespaces)
            XCTAssertEqual(rejoined, req.remediation.trimmingCharacters(in: .whitespaces),
                           "\(req.rawValue) loses or duplicates text between the ask and the instructions")
        }
    }

    // MARK: - helper

    /// Drops whole-line `//` comments, so a guard checks the code and not the
    /// paragraph explaining the guard. Lines with trailing comments and any
    /// URL inside a string are left alone, because only fully commented lines
    /// are removed.
    private func withoutComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// The text of a declaration, from its name to the line that closes it at
    /// column 0. Scoped so a neighbouring type cannot satisfy an assertion.
    private func body(of declaration: String, in source: String) -> String? {
        guard let start = source.range(of: declaration) else { return nil }
        let rest = source[start.upperBound...]
        guard let end = rest.range(of: "\n}\n") else { return String(rest) }
        return String(rest[rest.startIndex..<end.lowerBound])
    }
}
