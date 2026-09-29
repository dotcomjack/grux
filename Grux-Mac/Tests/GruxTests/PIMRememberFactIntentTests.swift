import XCTest
@testable import Grux

// Pins "remember that my X is Y" on the deterministic PIM path (A28c, ruling
// 0t). Measured iter 53: with thread history the local model answered
// "remember that X" with text 3 of 3 times and saved nothing. Only
// first-person fact statements have one reading; "remember that trip" is
// conversation and stays with the model.
final class PIMRememberFactIntentTests: XCTestCase {

    func test_firstPersonFactsMatch() {
        for (u, fact) in [("remember that my dentist is Dr. Lee on Fifth Street", "My dentist is Dr. Lee on Fifth Street"),
                          ("remember my wifi password is on the router label", "My wifi password is on the router label"),
                          ("remember that my kids are Maya and Leo", "My kids are Maya and Leo"),
                          ("Remember that I take my coffee black", "I take my coffee black"),
                          ("remember that I prefer meetings after 10 AM.", "I prefer meetings after 10 AM"),
                          ("hey grux, remember that my car is a blue Civic", "My car is a blue Civic"),
                          // RV11: the contractions and "I am" are the same statement.
                          ("remember that I'm allergic to penicillin", "I'm allergic to penicillin"),
                          ("remember that I\u{2019}m allergic to penicillin", "I\u{2019}m allergic to penicillin"),
                          ("remember that I am allergic to penicillin", "I am allergic to penicillin"),
                          ("remember that I've moved to Ferndale", "I've moved to Ferndale"),
                          ("remember that I'd rather sit by the window", "I'd rather sit by the window"),
                          ("remember that I'll be out of town Friday", "I'll be out of town Friday")] {
            let m = PIMIntents.match(u)
            XCTAssertEqual(m?.kind, .rememberFact, u)
            XCTAssertEqual(m?.slots.title, fact, u)
        }
    }

    func test_conversationDoesNotFire() {
        for u in ["remember that trip",
                  "remember that time we drove to Tahoe",
                  "remember that time I lost my keys",
                  "remember that song from the wedding",
                  "remember that?",
                  "do you remember that my dentist is Dr. Lee?",
                  "remember that my flight was delayed last week?",
                  "I remember that my dad is a pilot",
                  "remember my birthday",
                  "remember that my",
                  "remember that I",
                  "remember that I'm",
                  "remember that I'm right?",
                  "do you remember that I'm allergic to penicillin?",
                  "remember that time I'm talking about",
                  "remember that it is raining"] {
            let kind = PIMIntents.match(u)?.kind
            XCTAssertNotEqual(kind, .rememberFact, "should stay conversation: \(u)")
        }
    }

    func test_otherKindsKeepTheirWords() {
        XCTAssertEqual(PIMIntents.match("take a note that my dentist is Dr. Lee")?.kind, .takeNote)
        XCTAssertEqual(PIMIntents.match("remind me to call my dentist")?.kind, .addTask)
    }

    func test_planSavesTheFactThroughTheTool() throws {
        let plan = try XCTUnwrap(PIMIntents.plan(for: "remember that my dentist is Dr. Lee"))
        XCTAssertEqual(plan.toolName, "remember_fact")
        XCTAssertEqual(plan.toolInput?["fact"] as? String, "My dentist is Dr. Lee")
        XCTAssertEqual(plan.cardTitle, "My dentist is Dr. Lee")
        XCTAssertTrue(plan.requiresUndoWindow, "a saved fact must carry the 5 s undo")
        XCTAssertFalse(plan.kind.isJudged,
                       "ruling 0t: a first-person fact takes the deterministic path, the card's undo is the check")
        XCTAssertTrue(JaxToolGate.safeReadOnlyTools.contains("remember_fact"),
                      "the person asked for it, so no second approval (A10b)")
    }
}
