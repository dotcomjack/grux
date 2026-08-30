import XCTest
@testable import Grux

// AmbientCoach.sanitizeCoachReply is the single place a model-written nudge is
// cleaned before it reaches the HUD and the spoken path. It already stripped
// code fences, JSON envelopes and stray quotes; it did NOT strip the two banned
// dashes, so a nudge could put one on screen. These lock both halves.
final class AmbientCoachSanitizeTests: XCTestCase {

    func testStripsBannedDashesFromAPlainNudge() {
        let out = AmbientCoach.sanitizeCoachReply("You have been at this a while \u{2014} take five.")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2014}"), "em dash reached the HUD: \(out)")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2013}"))
    }

    // The dash scrub must run AFTER the envelope is unwrapped, not before, or a
    // dash inside the JSON payload survives into the extracted text.
    func testStripsDashesInsideAJSONEnvelope() {
        let out = AmbientCoach.sanitizeCoachReply(#"{"speech": "Ship it \#u{2014} then rest."}"#)
        XCTAssertFalse(out.unicodeScalars.contains("\u{2014}"), "em dash survived the envelope: \(out)")
        XCTAssertTrue(out.contains("Ship it"))
        XCTAssertTrue(out.contains("then rest"))
    }

    func testStripsDashesInsideACodeFence() {
        let out = AmbientCoach.sanitizeCoachReply("```\nBreak time \u{2013} stand up.\n```")
        XCTAssertFalse(out.unicodeScalars.contains("\u{2013}"), "en dash survived the fence: \(out)")
    }

    // ASCII hyphens are not the banned characters and must survive, or ordinary
    // words get mangled into commas.
    func testPreservesAsciiHyphens() {
        let out = AmbientCoach.sanitizeCoachReply("Try a self-review of the e-mail draft.")
        XCTAssertTrue(out.contains("self-review"), "ASCII hyphen mangled: \(out)")
        XCTAssertTrue(out.contains("e-mail"), "ASCII hyphen mangled: \(out)")
    }
}
