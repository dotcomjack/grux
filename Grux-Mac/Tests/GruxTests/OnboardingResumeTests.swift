import XCTest
@testable import Grux

/// The branch that answered a question it could not answer.
///
/// `OnboardingModel.init` used to resolve "there is a model key but no
/// onboarding.json" to `.done`. Onboarding WRITES that key at step 3 of 10, so
/// the test it was really applying was "did this person get as far as pasting a
/// key", which is true for everybody who quit at step 4 as well as everybody who
/// finished. Deleting an app leaves Keychain items and removes Application
/// Support, so a reinstall is the ordinary way to reach this branch.
///
/// Measured on the Mac Mini, 2026-08-30: Grux launched at 10:58:58 and wrote
/// `{"level":"plusPermissions","skipped":[],"skippedFirstLook":false,
/// "stage":"done"}` at 10:59, every field but `stage` at its property default,
/// which is the signature of this branch rather than of any user transition.
@MainActor
final class OnboardingResumeTests: XCTestCase {
    private typealias Stage = OnboardingModel.Stage
    private typealias Level = OnboardingModel.Level

    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Anti-vacuity. Every assertion below is about a stage that has to exist.
    func testTheWelcomeBackStageExists() {
        XCTAssertTrue(Stage.allCases.contains(.welcomeBack))
        XCTAssertEqual(Stage.welcomeBack.rawValue, "welcomeBack")
    }

    /// The stage must read as "not finished" to every gate in the app.
    ///
    /// Nothing outside OnboardingModel asks which stage it is; nine call sites
    /// ask `stage == .done`. That is what keeps the focus watcher, the overlay
    /// and the orb shut while Grux does not know whether setup happened.
    func testWelcomeBackIsNotDone() {
        XCTAssertNotEqual(Stage.welcomeBack, .done)
    }

    /// THE CONSENT CLAIM, which is the reason this is a defect and not a wrinkle.
    ///
    /// `firstFrameWasReviewed` is how Grux records that a person was shown a real
    /// captured frame and agreed to it. The old branch persisted `.done` with
    /// `skippedFirstLook == false` at the DEFAULT level, and that level includes
    /// `.firstLook`, so all three conjuncts held and Grux recorded a review that
    /// never happened.
    func testTheOldMigrationClaimedAFrameReviewThatNeverHappened() {
        // Anti-vacuity: assert the old shape DID claim it, so this test would
        // have failed on the code being replaced rather than passing vacuously.
        XCTAssertTrue(
            CapabilityResolver.firstFrameWasReviewed(
                stage: .done, skippedFirstLook: false, level: .plusPermissions),
            "The exact state the old branch wrote must be the state that claims a review, "
                + "or this test is not about the bug.")

        // And the state it writes now must not.
        XCTAssertFalse(
            CapabilityResolver.firstFrameWasReviewed(
                stage: .welcomeBack, skippedFirstLook: false, level: .plusPermissions))
    }

    /// "I am already set up" must not re-tell the same lie one click later.
    ///
    /// It finishes with `skippedFirstLook: true`, which is the honest record:
    /// this person was not shown a frame in this install. The cost is that the
    /// focus surface renders needs-setup and points at the control that walks
    /// the flow, which is the correct outcome rather than a consolation.
    func testKeepingExistingSetupDoesNotClaimAFrameReview() {
        for level in Level.allCases {
            XCTAssertFalse(
                CapabilityResolver.firstFrameWasReviewed(
                    stage: .done, skippedFirstLook: true, level: level),
                "level \(level.rawValue) claimed a frame review after keepExistingSetup()")
        }
    }

    /// The real method, driven, with the file protected.
    ///
    /// `keepExistingSetup()` persists, and the file it persists to is the
    /// developer's own `onboarding.json`. `Persistence.writesSuspended` is the
    /// existing kill switch for exactly that hazard, so the transition runs in
    /// memory and disk is never touched.
    ///
    /// The pure-function test above does NOT cover this: it asserts what
    /// `skippedFirstLook: true` MEANS, and stays green if the call site quietly
    /// passes `false`. Measured with the plant harness, which is why this test
    /// exists.
    func testKeepingExistingSetupRecordsTheSkipRatherThanAReview() {
        let model = OnboardingModel.shared
        let savedStage = model.stage
        let savedSkip = model.skippedFirstLook
        Persistence.writesSuspended = true
        defer {
            if savedStage == .done {
                model.finish(skippedFirstLook: savedSkip)
            } else {
                model.reset()
                var hops = 0
                while model.stage != savedStage, model.stage != .done, hops < 20 {
                    model.advance(from: model.stage)
                    hops += 1
                }
            }
            Persistence.writesSuspended = false
        }

        model.keepExistingSetup()

        XCTAssertEqual(model.stage, .done, "It has to actually leave the flow.")
        XCTAssertTrue(model.skippedFirstLook,
                      "Leaving by 'I am already set up' must record that no frame was shown.")
        XCTAssertFalse(
            CapabilityResolver.firstFrameWasReviewed(
                stage: model.stage, skippedFirstLook: model.skippedFirstLook,
                level: model.level),
            "The state it just wrote still claims a frame review.")
    }

    // MARK: - Resume

    /// EVERY unfinished stage puts the flow back on screen.
    ///
    /// This is the whole of resume, and until now it rested on one manual run on
    /// the Mac Mini. `LaunchRootView` replaces the entire shell when
    /// `isPresenting` is true, so if this relationship ever inverts or gains an
    /// exception, somebody who quit halfway lands in the app with their setup
    /// half done and nothing says so. That is the bug this file exists for,
    /// arriving by a different door.
    func testEveryUnfinishedStagePutsTheFlowBackOnScreen() {
        for stage in Stage.allCases where stage != .done {
            XCTAssertTrue(OnboardingModel.presents(stage),
                          "stage \(stage.rawValue) would drop the user into the app shell "
                            + "with setup unfinished")
        }
        XCTAssertFalse(OnboardingModel.presents(.done),
                       "Finished setup must not re-present the flow forever.")
    }

    /// The stage survives the round trip to disk, or there is nothing to resume.
    ///
    /// `rawValue` is the storage format and the pinned list guards renames, but
    /// nothing checked that a mid-flow State actually reloads as itself. Written
    /// through the real `Persistence` pair, to a temp file, so the encoder and
    /// decoder that run in production are the ones under test.
    func testAnInterruptedStageSurvivesQuittingAndReloading() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-resume-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        for stage in Stage.allCases where stage != .done {
            let saved = OnboardingModel.State(stage: stage, skippedFirstLook: false,
                                              level: .everything, skipped: ["a.b"])
            Persistence.save(saved, to: url)
            let loaded = Persistence.load(OnboardingModel.State.self, from: url,
                                          fallback: .initial)
            XCTAssertEqual(loaded.stage, stage,
                           "stage \(stage.rawValue) did not survive the round trip")
            XCTAssertEqual(loaded.skipped, ["a.b"],
                           "the skip ledger was dropped reloading \(stage.rawValue)")
        }
    }

    /// A missing file must not read as a finished setup.
    ///
    /// `State.initial` is the fallback for a file that will not decode, and if it
    /// ever became `.done` a single corrupt byte would silently mark somebody
    /// set up, which is this file's whole subject.
    func testTheFallbackStateIsTheStartOfTheFlowAndNotTheEnd() {
        XCTAssertEqual(OnboardingModel.State.initial.stage, .level)
        XCTAssertTrue(OnboardingModel.presents(OnboardingModel.State.initial.stage))
    }

    /// The shell is replaced, not overlaid, and it is driven by the model.
    ///
    /// Pinned in source because the routing is a view body: if this `if` is ever
    /// removed the two tests above keep passing while resume stops happening.
    func testLaunchRootViewRoutesOnTheModel() throws {
        let src = try source("Sources/Grux/LaunchRootView.swift")
        let lines = src.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.contains("if onboarding.isPresenting {") })
        else {
            return XCTFail("LaunchRootView no longer routes on isPresenting, so an "
                            + "interrupted setup will not come back.")
        }
        let window = lines[i ..< min(i + 8, lines.count)].joined(separator: "\n")
        XCTAssertTrue(window.contains("OnboardingView()"),
                      "isPresenting no longer leads to OnboardingView.")
    }

    /// The branch itself, read from source.
    ///
    /// `init` is unreachable from a test: the model is a singleton whose `init`
    /// is private and which reads the real `onboarding.json`, so driving it would
    /// rewrite the running user's install state as a side effect of asserting.
    /// The invariant is still worth pinning, so it is pinned where it lives.
    ///
    /// Anchored on the `exists` call and read as a WINDOW rather than by
    /// stripping comments: this file's own comments discuss `.done` several
    /// times, and a scan that looked for the token anywhere nearby would report
    /// prose as code.
    func testTheKeychainBranchDoesNotResolveToDone() throws {
        let src = try source("Sources/Grux/Onboarding/OnboardingModel.swift")
        let lines = src.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: {
            $0.contains("} else if KeychainStore.exists(.anthropicApiKey) {")
        }) else {
            return XCTFail("The keychain migration branch was renamed or removed.")
        }
        // Bounded at the NEXT branch, not at a guessed line count. A fixed
        // window of 14 lines ran straight into the `else` below and collected
        // its `stage = .level`, which is a second assignment this test has no
        // business reading.
        let rest = lines[(i + 1)...]
        let end = rest.firstIndex(where: { $0.hasSuffix("} else {") || $0 == "        }" })
            ?? rest.endIndex
        let body = rest[..<end].filter { $0.contains("stage = ") }
        XCTAssertEqual(body.count, 1, "Expected exactly one stage assignment, saw \(body)")
        XCTAssertTrue(body.first?.contains("stage = .welcomeBack") == true,
                      "The keychain branch assigns \(body.first ?? "nothing")")
    }
}
