import XCTest
@testable import Grux

/// Guards for the first-run flow and the contract types under it.
///
/// The tests worth having here are not "does the enum have three cases". They
/// are the ones that catch a REGRESSION a stranger would hit and the owner never
/// would, because his install has been set up for a year: an id that drifted
/// from the frozen contract, a remediation string that grew past the ceiling,
/// a greeting that renders a dangling comma when no name is set, and a
/// redaction counter that reports zero on text that was actually redacted.
final class OnboardingTests: XCTestCase {

    // MARK: - Contract conformance

    /// The contract is frozen and its ids are a closed set. A typo here is not
    /// a compile error, it is a capability that silently never resolves, so it
    /// gets asserted against the literal strings from `docs/contract.md`.
    func testCapabilityIdsMatchTheFrozenContract() {
        XCTAssertEqual(SetupRequirement.keyAnthropic.rawValue, "key.anthropic")
        XCTAssertEqual(SetupRequirement.permScreenRecording.rawValue, "perm.screen_recording")
        XCTAssertEqual(SetupRequirement.stepFirstFrameReviewed.rawValue, "step.first_frame_reviewed")
    }

    /// Every id must carry one of the four sanctioned class prefixes. This is
    /// the rule that stops a future case being called `onboarding.name` and
    /// quietly leaving the vocabulary.
    func testEveryIdUsesAContractClassPrefix() {
        let allowed = ["key.", "perm.", "endpoint.", "step."]
        for req in SetupRequirement.allCases {
            XCTAssertTrue(allowed.contains { req.rawValue.hasPrefix($0) },
                          "\(req.rawValue) is outside the closed capability vocabulary")
        }
    }

    /// Contract 1.4: remediation is exact UI text, under 140 characters. It is
    /// rendered directly into a setup card, so an overlong one is a layout bug
    /// that only shows up on the screen nobody on the team ever sees.
    func testRemediationTextFitsTheContractCeiling() {
        for req in SetupRequirement.allCases {
            XCTAssertLessThan(req.remediation.count, 140,
                              "\(req.rawValue) remediation is \(req.remediation.count) chars")
            XCTAssertFalse(req.remediation.isEmpty, "\(req.rawValue) has no remediation")
            XCTAssertFalse(req.label.isEmpty, "\(req.rawValue) has no label")
        }
    }

    /// House rule, mechanically checkable, and the kind of thing that survives
    /// a hundred reviews because nobody looks for a character they cannot see.
    func testNoDashesAnywhereInUserFacingSetupCopy() {
        for req in SetupRequirement.allCases {
            for s in [req.label, req.remediation] {
                XCTAssertFalse(s.contains("\u{2014}"), "em dash in \(req.rawValue): \(s)")
                XCTAssertFalse(s.contains("\u{2013}"), "en dash in \(req.rawValue): \(s)")
            }
        }
    }

    /// Second person is the whole de-personalization strategy for prompt and
    /// setup copy: it needs no configuration and cannot go stale. A remediation
    /// naming a specific person is the regression this guards.
    func testSetupCopyNamesNobody() {
        let banned = ["jack", "dotcomjack", "detroit", "dcj"]
        for req in SetupRequirement.allCases {
            let hay = (req.label + " " + req.remediation).lowercased()
            for word in banned {
                XCTAssertFalse(hay.contains(word), "\(req.rawValue) still names \(word)")
            }
        }
    }

    // MARK: - Stage ordering

    /// The stage rawValues are a storage format: `OnboardingModel.State` is
    /// persisted to disk, so renaming a case strands a user mid-flow at a stage
    /// that no longer decodes. Pinning them makes that a test failure rather
    /// than a support ticket.
    func testStageRawValuesArePersistedAndStable() {
        XCTAssertEqual(OnboardingModel.Stage.modelKey.rawValue, "modelKey")
        XCTAssertEqual(OnboardingModel.Stage.identity.rawValue, "identity")
        XCTAssertEqual(OnboardingModel.Stage.firstLook.rawValue, "firstLook")
        XCTAssertEqual(OnboardingModel.Stage.done.rawValue, "done")
    }

    /// An unknown or absent stage must decode to the beginning, not throw. A
    /// config file from a future build landing on an older one is a crash on
    /// launch if this is wrong, and launch crashes are unrecoverable for the
    /// user.
    func testStateDecodesFromAnEmptyObject() throws {
        let s = try JSONDecoder().decode(OnboardingModel.State.self,
                                         from: Data("{}".utf8))
        // `.level`, the new beginning: the flow now opens by asking how much of
        // it the user wants. `.modelKey` was the first stage before that screen
        // existed.
        XCTAssertEqual(s.stage, .level)
        XCTAssertFalse(s.skippedFirstLook)
        XCTAssertTrue(s.skipped.isEmpty)
    }

    // MARK: - Redaction counter

    /// The count is shown next to the claim "N secrets removed", so a counter
    /// that is quietly always zero turns evidence back into a promise.
    func testRedactionCounterCountsMarkers() {
        XCTAssertEqual(FirstFrameReview.countRedactions("nothing here"), 0)
        XCTAssertEqual(FirstFrameReview.countRedactions("key [REDACTED:HIGH_ENTROPY] done"), 1)
        XCTAssertEqual(
            FirstFrameReview.countRedactions("[REDACTED:A] and [REDACTED:B] and [REDACTED:C]"), 3)
    }

    /// End to end against the REAL redactor, not a fixture. The screen claims
    /// the text shown is what the live capture path would send, and that claim
    /// is only true while this passes.
    func testTheReviewShowsWhatTheRealRedactorProduces() {
        let secret = "sk-ant-api03-" + String(repeating: "A1b2C3d4", count: 8)
        let redacted = SecretRedactor.redact("my key is \(secret) ok")
        XCTAssertFalse(redacted.contains(secret), "the previewed text still carries the secret")
        XCTAssertGreaterThan(FirstFrameReview.countRedactions(redacted), 0,
                             "redactor fired but the counter reported nothing")
    }
}

/// `OnboardingModel.reset()` and the Settings row that finally calls it.
///
/// The method shipped with a doc comment explaining that a one-time flow with no
/// way back is a trap, and then nothing outside `Onboarding/` referenced
/// `OnboardingModel` at all except the launch gate. So the trap was live and the
/// escape hatch was dead code. Asserting the row exists is not enough: a row
/// wired to a transition nobody has ever run is the same defect one layer down.
///
/// **Why these drive the real singleton.** `OnboardingModel.init` is private, so
/// `shared` is the only instance that exists and there is no seam to inject. It
/// persists to `Persistence.supportDir/onboarding.json`, which on a developer
/// machine is the live install, so `withOnboardingStateRestored` snapshots both
/// halves (the file bytes and the in-memory stage) and puts them back. Same
/// shape as `PresetStoreTests.withConfigSnapshot`.
final class OnboardingResetTests: XCTestCase {

    private static var stateURL: URL {
        Persistence.supportDir.appendingPathComponent("onboarding.json")
    }

    /// The whole point of the Settings row: someone who clicked through the flow
    /// gets returned to the first gate, with any stale rejection cleared.
    @MainActor
    func testResetReturnsToTheFirstStageAndClearsTheKeyError() {
        withOnboardingStateRestored {
            let model = OnboardingModel.shared
            // Mid-flow with a rejected key showing, which is the messiest state
            // a real user can be sitting in when they reach for Settings.
            model.completeModelKey()
            model.completeIdentity()
            model.keyError = "That key was rejected. Check you copied all of it."
            // Deliberately NOT asserting a named stage here any more. This used
            // to say `.firstLook`, which was the third of three gates, and the
            // assertion broke the moment a screen was inserted before it even
            // though the behaviour under test was unchanged. What this setup
            // needs is "somewhere in the middle", so that is what it checks.
            XCTAssertNotEqual(model.stage, .level, "test setup did not reach a later stage")
            XCTAssertNotEqual(model.stage, .done, "test setup ran past the end of the flow")

            model.reset()

            XCTAssertEqual(model.stage, .level, "reset must land on the first screen, not the next one")
            XCTAssertNil(model.keyError,
                         "a stale rejection would greet the user beside a key they have since fixed")
            XCTAssertTrue(model.isPresenting,
                          "reset that leaves isPresenting false is a no-op: the flow never comes back on screen")
        }
    }

    /// Reset has to survive a quit. `stage` is read from disk on next launch, so
    /// a reset that only moved memory would evaporate the moment the user
    /// relaunched mid-flow, and the trap would still be shut behind them.
    @MainActor
    func testResetPersistsTheFirstStageForTheNextLaunch() {
        withOnboardingStateRestored {
            OnboardingModel.shared.finish(skippedFirstLook: false)
            OnboardingModel.shared.reset()

            let onDisk = Persistence.load(OnboardingModel.State.self,
                                          from: Self.stateURL,
                                          fallback: OnboardingModel.State.initial)
            // `.level` now, not `.modelKey`: the flow begins by asking how much
            // of it the user wants.
            XCTAssertEqual(onDisk.stage, .level, "reset never reached disk")
        }
    }

    /// The row is only reachable if search can find it. `general.firstRun` is not
    /// a phrase anyone types, so the keyword list is the actual affordance and it
    /// is worth a test that a stranger's words land on the right section.
    func testSearchFindsTheFirstRunRowByTheWordsPeopleActuallyType() {
        for query in ["onboarding", "welcome", "start over", "first run", "wizard"] {
            let ids = SettingsSearchRegistry.matches(query).map(\.id)
            XCTAssertTrue(ids.contains("general.firstRun"),
                          "searching \"\(query)\" does not surface the first-run row, it found \(ids)")
        }
        // The section also has to survive the filter it just matched, or search
        // jumps to a pane where the row has been hidden.
        XCTAssertTrue(SettingsSearchRegistry.sectionVisible(anchor: "general.firstRun", query: "onboarding"))
    }

    // MARK: - Singleton guard

    /// Snapshot and restore both halves of the shared model. The in-memory stage
    /// is walked home through the same public transitions the UI drives, because
    /// `stage` is `private(set)` and there is no setter to borrow. The original
    /// file bytes go back last and win, since those transitions rewrite the file
    /// with a `State` this test built and would drop `skippedFirstLook`.
    @MainActor
    private func withOnboardingStateRestored(_ body: () -> Void) {
        let url = Self.stateURL
        let savedBytes = try? Data(contentsOf: url)
        let savedStage = OnboardingModel.shared.stage
        let savedKeyError = OnboardingModel.shared.keyError
        defer {
            let model = OnboardingModel.shared
            model.reset()
            // Walk forward through the real transitions rather than naming each
            // stage's predecessors. The switch that used to live here listed
            // every stage by hand, so adding one to the flow broke this helper
            // in a file that has nothing to do with the change. Advancing until
            // the saved stage comes back around is the same restore and does not
            // care how long the flow is.
            var hops = 0
            while model.stage != savedStage, model.stage != .done, hops < 20 {
                model.advance(from: model.stage)
                hops += 1
            }
            model.keyError = savedKeyError
            if let savedBytes {
                try? savedBytes.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        body()
    }
}

/// The `GatePersona.jack` to `.owner` rename touched a PERSISTED raw value on
/// every queued approval, so it shipped with a back-compatible decoder. A
/// migration nobody exercises is a comment, not a migration.
final class GatePersonaMigrationTests: XCTestCase {

    private func decode(_ raw: String) throws -> GatePersona {
        try JSONDecoder().decode(GatePersona.self, from: Data("\"\(raw)\"".utf8))
    }

    /// The whole point: an approval queued before the rename still shows "you".
    func testTheOldSpellingStillDecodes() throws {
        XCTAssertEqual(try decode("jack"), .owner)
        XCTAssertEqual(try decode("jack").displayName, "you")
    }

    func testTheNewSpellingDecodes() throws {
        XCTAssertEqual(try decode("owner"), .owner)
        XCTAssertEqual(try decode("sarah"), .sarah)
    }

    /// Writes only the new spelling, so the queue migrates as it drains.
    func testItEncodesTheNewSpellingOnly() throws {
        let out = String(data: try JSONEncoder().encode(GatePersona.owner), encoding: .utf8)
        XCTAssertEqual(out, "\"owner\"")
    }

    /// An unrecognized token must not throw. A single bad value would otherwise
    /// take the whole queue file down and lose every pending approval.
    func testAnUnknownTokenDegradesInsteadOfThrowing() throws {
        XCTAssertEqual(try decode("something-from-a-future-build"), .none)
    }
}
