import XCTest
import AppKit
import SwiftUI
@testable import Grux

/// D157 item 3, sense pass 19 (`focus-1.png`): Focus log's card read "needs 4
/// more things" and one of them, "Review the first capture", had no button,
/// because the card read it as a step the feature completes by running. It is
/// not: `FocusWatcher.skipReason` refuses every capture until it is done, so a
/// person who added the key, granted Screen Recording and confirmed the list
/// still had a card with one thing left and nothing to press.
@MainActor
final class SetupCardFirstCaptureTests: XCTestCase {

    func testTheFirstCaptureIsReviewedOnTheCard() {
        XCTAssertEqual(CapabilitySetupCard.stepRoute(for: .stepFirstFrameReviewed), .reviewFrame)
        XCTAssertEqual(CapabilitySetupCard.actionTitle(for: .stepFirstFrameReviewed), "Review")
        XCTAssertFalse(CapabilitySetupCard.completedByUse.contains(.stepFirstFrameReviewed),
                       "Focus log captures nothing until this is done, so running it cannot complete it")
    }

    /// THE CLASS: a step that blocks a feature gets a button on that feature's
    /// card, unless it is named as one the feature completes while its card is
    /// up. A new blocking step with neither fails here, the day it is added.
    func testEveryBlockingStepHasAButtonOrIsCompletedByUse() {
        var checked = 0
        for row in FeatureRegistry.rows {
            for step in row.steps {
                checked += 1
                if CapabilitySetupCard.knownWithoutButton.contains(step) {
                    XCTAssertNil(CapabilitySetupCard.actionTitle(for: step),
                                 "\(step.rawValue) has a button now, so take it off knownWithoutButton")
                    continue
                }
                if CapabilitySetupCard.completedByUse.contains(step) {
                    XCTAssertNil(CapabilitySetupCard.actionTitle(for: step),
                                 "\(step.rawValue) is completed by use and also has a button")
                    continue
                }
                XCTAssertNotNil(CapabilitySetupCard.actionTitle(for: step), """
                    \(row.id)'s card lists \(step.rawValue) ("\(step.label)") with no button, and it is \
                    not named in completedByUse: a card with one thing left and nothing to press.
                    """)
            }
        }
        XCTAssertGreaterThan(checked, 0, "control: no blocking steps found")
    }

    /// "Looks right" agrees to what was shown, so it needs a frame on screen:
    /// no permission, a spinner or a failure is not a reviewed capture.
    func testLooksRightNeedsAFrameOnScreen() {
        let ready = FirstFrameReview.Phase.ready(image: NSImage(size: NSSize(width: 4, height: 4)),
                                                 redacted: "text", redactionCount: 0, app: "Notes")
        XCTAssertTrue(FirstFrameReview.canConfirm(ready))
        for phase: FirstFrameReview.Phase in [.needsPermission, .capturing, .failed("could not read")] {
            XCTAssertFalse(FirstFrameReview.canConfirm(phase), "\(phase)")
        }
    }

    /// The card's review lands where the walk's does, and nowhere new.
    func testAReviewOnTheCardIsRecordedWhereTheWalkRecordsIt() throws {
        let resolver = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/SetupCardFirstCaptureTests.swift", with: "Sources/Grux/Onboarding/CapabilityResolver.swift"))
        let body = try XCTUnwrap(resolver.components(separatedBy: "static func recordFirstFrameReviewedOnCard() {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        XCTAssertTrue(body.contains("OnboardingModel.shared.recordFirstLookReviewed()"), body)
        XCTAssertTrue(body.contains("markStepCompleted(.stepFirstFrameReviewed)"), body)
        // And that home is what the gate reads on the question path a first run takes.
        XCTAssertTrue(CapabilityResolver.firstFrameWasReviewed(stage: .done, skippedFirstLook: false,
                                                               level: .essentials, path: .question))
    }

    /// W52-FIX (wave 52 review, P2-3, was D161): on the older list path at
    /// Essentials, a level whose walk never shows the first look, the card's
    /// "Looks right" was recorded and the gate still read false, so the card
    /// kept the same step and the same Review every time. A frame the person
    /// reviewed now counts on every path and level; a level alone still never
    /// does, and a later "Not now" takes it back.
    func testAFrameReviewedOnTheCardCountsOnEveryPathAndLevel() throws {
        for path: OnboardingModel.Path in [.list, .question] {
            for level: OnboardingModel.Level in [.essentials, .plusPermissions, .everything] {
                XCTAssertTrue(CapabilityResolver.firstFrameWasReviewed(
                    stage: .done, skippedFirstLook: false, level: level, path: path, reviewedAFrame: true),
                    "\(path) \(level)")
                // Declined after, or setup not finished: not reviewed.
                XCTAssertFalse(CapabilityResolver.firstFrameWasReviewed(
                    stage: .done, skippedFirstLook: true, level: level, path: path, reviewedAFrame: true))
                XCTAssertFalse(CapabilityResolver.firstFrameWasReviewed(
                    stage: .setup, skippedFirstLook: false, level: level, path: path, reviewedAFrame: true))
            }
        }
        // The level alone, with no frame reviewed, is unchanged (the Mini's 2026 finding).
        XCTAssertFalse(CapabilityResolver.firstFrameWasReviewed(
            stage: .done, skippedFirstLook: false, level: .essentials, path: .list, reviewedAFrame: false))
        // The fact survives a relaunch, and a file from before it decodes as not reviewed.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("grux-w52-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let saved = OnboardingModel.State(stage: .done, skippedFirstLook: false, level: .essentials, skipped: [],
                                          path: .list, answer: "", reviewedAFrame: true)
        Persistence.save(saved, to: url)
        XCTAssertTrue(Persistence.load(OnboardingModel.State.self, from: url, fallback: .initial).reviewedAFrame)
        let old = try XCTUnwrap(#"{"stage":"done","skippedFirstLook":false,"level":"essentials","skipped":[],"path":"list","answer":""}"#
            .data(using: .utf8))
        XCTAssertFalse(try JSONDecoder().decode(OnboardingModel.State.self, from: old).reviewedAFrame)
    }

    /// The card's button opens the review, and its "Looks right" waits for a frame.
    func testTheCardOpensTheReviewAndItsButtonWaitsForAFrame() throws {
        let card = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/SetupCardFirstCaptureTests.swift", with: "Sources/Grux/Onboarding/CapabilitySetupCard.swift"))
        XCTAssertTrue(card.contains("case .reviewFrame:\n                reviewingFrame = true"), "the button does nothing")
        XCTAssertTrue(card.contains(".disabled(!canConfirm)"), "Looks right can be pressed with no frame")
        XCTAssertTrue(card.contains("FirstFrameReview { canConfirm = FirstFrameReview.canConfirm($0) }"))
    }

    /// W52-FIX (wave 52 review, P2-4): the card learns of a frame only through
    /// `onPhase`, and that was proven only as text, so dropping the line that
    /// reports it left "Looks right" disabled for good while every test passed.
    /// The review is hosted here with a loader that returns a frame (nothing
    /// is captured, no window is shown) and must tell the card.
    func testAFrameOnScreenReachesTheCard() {
        var seen: [FirstFrameReview.Phase] = []
        let frame = FirstFrameReview.Phase.ready(image: NSImage(size: NSSize(width: 4, height: 4)),
                                                 redacted: "text", redactionCount: 0, app: "Notes")
        let host = NSHostingView(rootView: FirstFrameReview(onPhase: { seen.append($0) }, loader: { frame }))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 300)
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(5)
        while seen.isEmpty, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(seen.last, frame, "the card never heard of the frame on screen")
        XCTAssertTrue(seen.last.map(FirstFrameReview.canConfirm) ?? false)
    }
}
