import XCTest
@testable import Grux

// Regression coverage for the ConfidenceGate heuristic. The gate must flag TRUE
// confusion (empty turns, genuine unknown jargon) but must NOT mistake a plain
// English word for jargon. A prior bug treated "hello" as an unknown term and
// fired the "I do not know what hello means" clarify response on a basic greeting.
final class ConfidenceGateTests: XCTestCase {

    private func verdict(_ s: String) -> ConfidenceVerdict {
        ConfidenceGate.assessHeuristic(prompt: s, context: ConfidenceContext())
    }

    func test_plainEnglishGreetings_areNotConfused() {
        for word in ["hello", "hey", "thanks", "okay", "sorry", "yeah", "cool", "bye"] {
            XCTAssertFalse(verdict(word).isTrulyConfused,
                           "\"\(word)\" is a plain English word and must not trip the gate")
        }
    }

    func test_conversationalSlang_isNotConfused() {
        // Internet slang / interjections are conversation, not unknown jargon.
        for word in ["bruh", "lol", "fr", "ngl", "sheesh", "bet", "yo", "smh", "lmao"] {
            XCTAssertFalse(verdict(word).isTrulyConfused,
                           "\"\(word)\" is common slang and must not trip the clarify gate")
        }
    }

    func test_commonRealWords_areNotConfused() {
        // Real words that are NOT in the small hardcoded set but ARE in the
        // system dictionary, so the dictionary-backed check must clear them.
        for word in ["weather", "coffee", "remember", "schedule", "apple"] {
            XCTAssertFalse(verdict(word).isTrulyConfused,
                           "\"\(word)\" is a real word and must not trip the gate")
        }
    }

    func test_genuineUnknownJargon_isStillFlagged() {
        // A made-up token that is not in any dictionary, slang, or domain must
        // still flag as confusion, so the fix did not blunt the gate entirely.
        let v = verdict("zqxwvfgh")
        XCTAssertTrue(v.isTrulyConfused, "a non-word jargon token should still flag")
        XCTAssertNotNil(v.clarifyingQuestion)
    }

    func test_emptyTurn_isStillFlagged() {
        XCTAssertTrue(verdict("").isTrulyConfused, "an empty turn must still flag")
    }
}
