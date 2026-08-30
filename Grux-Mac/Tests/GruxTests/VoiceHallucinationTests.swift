import XCTest
@testable import Grux

// Regression coverage for the Whisper hallucination guard. A near-silent or
// noisy capture could echo the vocab roster back as a looped phrase
// ("IOS Widget V2, Northwind IOS Widget V2, Northwind ...").
// Auto-sending that made Grux message itself, and the repeat then tripped a
// false "you're looping, you okay? third time in a row" reply. The detector
// must catch that loop while never rejecting ordinary dictated speech.
//
// The roster terms below are placeholders. The guard is driven entirely by the
// roster it is handed, so the fixtures only have to exercise the shape: a
// transcript made almost entirely of roster words versus a real command that
// carries ordinary glue and verbs alongside one roster word.
final class VoiceHallucinationTests: XCTestCase {

    private func isHallucination(_ s: String) -> Bool {
        VoiceInput.looksLikeRepeatedHallucination(s)
    }

    func test_rosterEchoLoop_isRejected() {
        XCTAssertTrue(isHallucination(
            "IOS Widget V2, Northwind IOS Widget V2, Northwind IOS Widget V2, Northwind"))
    }

    func test_simpleRepeatedPhrase_isRejected() {
        XCTAssertTrue(isHallucination("open chrome open chrome open chrome"))
        XCTAssertTrue(isHallucination("the the the the the the the the"))
    }

    func test_normalSpeech_isAccepted() {
        for s in [
            "add a task to verify the qwen routing is live",
            "what's the weather today and tomorrow",
            "remind me to call the dentist at three",
            "play lose yourself by eminem",
            "draft an email to the supplier about the delay",
        ] {
            XCTAssertFalse(isHallucination(s), "\"\(s)\" is normal speech and must not be rejected")
        }
    }

    func test_shortUtterances_areAccepted() {
        // Too short to judge as a loop; never reject.
        for s in ["hello", "yes do it", "stop", "okay thanks"] {
            XCTAssertFalse(isHallucination(s), "\"\(s)\" is too short to be a loop")
        }
    }

    func test_naturalRepeatWord_isAccepted() {
        // A real sentence that happens to repeat a word should not trip the
        // distinct-ratio heuristic (ratio stays well above the floor).
        XCTAssertFalse(isHallucination("I really really want to ship the app today"))
    }

    // MARK: - Roster-echo (the "IOS Widget V2, Northwind" self-message bug)

    // Shaped like what WhisperVocab.rosterWordSet() produces from multi-word
    // vocab terms (individual lowercased words, version/platform tokens kept,
    // common English dropped). The specific words are arbitrary: the detector
    // is passed its roster, so this fixture stands on its own.
    private let roster: Set<String> = [
        "grux", "gruxai", "northwind", "acme", "widget", "ios", "v2",
        "contoso", "anthropic", "fabrikam",
    ]

    private func isEcho(_ s: String) -> Bool {
        VoiceInput.looksLikeRosterEcho(s, roster: roster)
    }

    func test_rosterEcho_garbledBrandList_isRejected() {
        XCTAssertTrue(isEcho("IOS Widget V2, Northwind"))
        XCTAssertTrue(isEcho("Northwind, GruxAI, Anthropic"))
    }

    func test_legitCommandWithBrandWord_isAccepted() {
        // A real command carries non-roster glue/verbs, so it must survive even
        // though it contains a brand term.
        for s in ["play Northwind", "open Acme", "what is the status of GruxAI",
                  "ship the widget to testflight", "draft an email about Northwind"] {
            XCTAssertFalse(isEcho(s), "\"\(s)\" is a real command and must not be rejected as roster echo")
        }
    }

    func test_rosterEcho_emptyRosterOrShort_isAccepted() {
        XCTAssertFalse(VoiceInput.looksLikeRosterEcho("Northwind GruxAI", roster: []))
        XCTAssertFalse(isEcho("Northwind"))
    }
}
