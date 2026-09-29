import XCTest
@testable import Grux

/// A setup card that names a missing thing must offer a way to deal with it,
/// and must not draw it as already done.
///
/// BOTH DEFECTS WERE SEEN ON ONE REAL SCREEN, 2026-09-24. Jax Command said
/// "needs one more thing", the thing was "Choose what gets indexed", and:
///
///  - it carried `checkmark.circle`, the universal symbol for DONE, on the one
///    row that was not done;
///  - it offered no button at all, under a sentence that reads "Pick which of
///    your messages, notes and sent mail Grux may index", which is an
///    instruction with nowhere to carry it out.
///
/// The missing button had a real reason behind it. These are CONSENT steps:
/// `CapabilityResolver.selfAttestedSteps` holds them and the CLI refuses to
/// answer them, because nobody may consent on somebody's behalf. But "no agent
/// may answer this" had been implemented as "nothing may offer it", and those
/// are different things. The person is allowed to answer; they simply had one
/// chance during first-run and no way back to it.
@MainActor
final class SetupCardDeadEndTests: XCTestCase {

    /// The three steps whose only home is the first-run walk.
    ///
    /// NOT every self-attested step, and the difference matters. Being
    /// self-attested says WHO may answer (only the person, never an agent). It
    /// does not say WHERE. `stepYoutubeTranscriptsEnabled` is self-attested and
    /// its remediation says "Turn it on in Settings", so routing it to
    /// first-run would send somebody to re-walk setup for a toggle;
    /// `stepFirstFrameReviewed` is completed by using the feature. An earlier
    /// version of this fix routed all six and `TerminalSessionsOnboardingTests`
    /// caught it, which is the whole point of that file's known-unrouted list.
    private let firstRunOnly: [SetupRequirement] = [
        .stepRecordingConsentAcknowledged,
        .stepCaptureExclusionsConfirmed,
        .stepCorpusSourcesConfirmed,
    ]

    func testEveryConsentStepHasSomewhereToGo() {
        for step in firstRunOnly {
            XCTAssertEqual(SettingsTabAliases.stepDestination(step), "first-run", """
                \(step.rawValue) is answered only during the first-run walk and has no \
                destination, so its card names something missing, prints an instruction, and \
                offers no way to act on it. That is the dead end this file exists to prevent.
                """)
        }
    }

    /// The other side: a self-attested step is NOT automatically a first-run
    /// step, and treating it as one sends people to the wrong place.
    func testSelfAttestationDoesNotImplyFirstRun() {
        XCTAssertTrue(CapabilityResolver.selfAttestedSteps.contains(.stepYoutubeTranscriptsEnabled),
                      "fixture assumption broke")
        XCTAssertNotEqual(SettingsTabAliases.stepDestination(.stepYoutubeTranscriptsEnabled), "first-run", """
            the YouTube step routes to first-run, but its remediation says to turn it on in \
            Settings. Sending somebody to re-walk setup for a toggle is a worse lie than no button.
            """)
    }

    /// And the destination has to resolve to a real place, not just be
    /// non-nil. A tag that does not resolve is the same dead end wearing a
    /// button.
    func testThoseDestinationsResolveToARealSettingsLocation() {
        for step in firstRunOnly {
            guard let tag = SettingsTabAliases.stepDestination(step) else { continue }
            let where_ = SettingsTabAliases.resolve(tag)
            XCTAssertNotNil(where_.anchor ?? where_.sub ?? where_.pane.rawValue, """
                \(step.rawValue) routes to "\(tag)", which does not resolve to a settings \
                location. The button would land the person nowhere.
                """)
        }
    }

    /// The specific one from the screenshot.
    func testChooseWhatGetsIndexedIsReachable() {
        XCTAssertEqual(SettingsTabAliases.stepDestination(.stepCorpusSourcesConfirmed), "first-run",
                       "the corpus consent step lost its route back to first-run")
        XCTAssertTrue(SettingsTabAliases.stepNeedsFirstRun(.stepCorpusSourcesConfirmed))
    }

    /// A step the FEATURE completes must still get NO button. Sending someone
    /// to a settings pane for something that happens by opening Meetings would
    /// be a worse lie than silence.
    func testAFeatureCompletedStepStillOffersNothing() {
        XCTAssertFalse(CapabilityResolver.selfAttestedSteps.contains(.stepSpeechModelDownloaded),
                       "fixture assumption broke: the speech model step is now self-attested")
        XCTAssertNil(SettingsTabAliases.stepDestination(.stepSpeechModelDownloaded), """
            the speech model step gained a destination. It is completed by opening Meetings, \
            so a button would send the person somewhere that cannot satisfy it.
            """)
    }

    /// No row on this card may wear a completion symbol. Every row on it is by
    /// definition a thing that is NOT done.
    func testNoRowOnTheCardIsDrawnAsDone() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/CapabilitySetupCard.swift"),
                             encoding: .utf8)
        // Comments stripped first. Without this the check fails on its own
        // explanation: the fix's comment NAMES the symbol it removed, and a
        // file that documents a hazard gets reported as causing it. The
        // sibling VoiceProcessingGuardTests learned this the same way.
        let code = src.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let icons = try XCTUnwrap(code.components(separatedBy: "private func icon(for requirement:").dropFirst().first)
        let body = String(icons.prefix(700))
        XCTAssertFalse(body.contains("checkmark"), """
            an icon on the setup card is a checkmark again. Every row on this card is a \
            MISSING item, so a tick says the opposite of what the card is for.
            """)
    }
}
