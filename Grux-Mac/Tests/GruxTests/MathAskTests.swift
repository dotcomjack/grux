import XCTest
@testable import Grux

/// D155: a sum or a tip is worked out exactly, with no model. Sense pass 19
/// (11:10 AM Nov 4) asked Grux Local 2B "What's 18% tip on $64.50?" and it
/// answered "$11.21"; the tip is $11.61.
final class MathAskTests: XCTestCase {
    func testTheSenseFailureIsAnsweredExactly() {
        XCTAssertEqual(MathAsk.reply(for: "What's 18% tip on $64.50?"),
                       "An 18% tip on $64.50 is $11.61, so $76.11 in all.")
    }

    func testPercentForms() {
        let cases: [(String, String)] = [
            ("what is 15% of 80", "15% of 80 is 12."),
            ("15 percent of 80?", "15% of 80 is 12."),
            ("how much is 7 percent of $1,200", "7% of $1,200.00 is $84.00."),
            ("Calculate a 20% tip on $85", "A 20% tip on $85.00 is $17.00, so $102.00 in all."),
            ("what's a 15% tip for 42 dollars", "A 15% tip on $42.00 is $6.30, so $48.30 in all."),
            ("What's the tip on $49.99 at 18%?", "An 18% tip on $49.99 is $9.00, so $58.99 in all."),
            ("20% off $49.99", "20% off $49.99 is $39.99, so you save $10.00."),
            ("what is 12.5% of 64", "12.5% of 64 is 8."),
            ("what's 1% of 3", "1% of 3 is 0.03."),
            ("Grux, what's 8% tip on 20", "An 8% tip on 20.00 is 1.60, so 21.60 in all."),
        ]
        for (ask, want) in cases { XCTAssertEqual(MathAsk.reply(for: ask), want, ask) }
    }

    func testExpressions() {
        let cases: [(String, String)] = [
            ("what's 12 x 7?", "12 × 7 is 84."),
            ("2+2", "2 + 2 is 4."),
            ("what is (3 + 4) * 2", "(3 + 4) × 2 is 14."),
            ("22 / 7", "22 ÷ 7 is about 3.142857."),
            ("What's 1,250 * 3", "1,250 × 3 is 3,750."),
            ("what's 100 divided by 8", "100 ÷ 8 is 12.5."),
            ("10 - 3", "10 - 3 is 7."),
            ("what is 6 minus 10", "6 - 10 is -4."),
            ("-5 + 3", "-5 + 3 is -2."),
            ("$120 / 4", "$120 ÷ 4 is $30.00."),
            ("$20 / 3", "$20 ÷ 3 is about $6.67."),
            ("$60 / $4", "$60 ÷ $4 is 15."),
            ("$12.50 + $3.25 + $8", "$12.50 + $3.25 + $8 is $23.75."),
            ("what's 0.1 + 0.2", "0.1 + 0.2 is 0.3."),
            ("calculate 3 times 4 plus 1", "3 × 4 + 1 is 13."),
            ("what's 12 × 3 ÷ 4", "12 × 3 ÷ 4 is 9."),
            ("5 / 0", "5 ÷ 0 has no answer: nothing divides by zero."),
            ("what is 1/3 + 1/3", "1 ÷ 3 + 1 ÷ 3 is about 0.666667."),
        ]
        for (ask, want) in cases { XCTAssertEqual(MathAsk.reply(for: ask), want, ask) }
    }

    /// Precision first: anything that is not exactly a sum or a percent goes
    /// to the model, so a miss costs a model answer, never a wrong number.
    func testWhatIsNotArithmeticStaysWithTheModel() {
        for text in ["What's 9/11", "24/7", "what is 555-1234", "2020-2024", "11/4/2026", "what's a 2x4",
                     "what is 3.14", "What's the weather in Boston?", "Remind me at 9", "what's 2^10",
                     "what is 18% of my rent", "what is 15% of 80 and 20% of 90", "tip 18%",
                     "what's $5 * $4", "how many cents are in a quarter", "", "what's the 20% tip rule",
                     "what is 5 +", "what's 1e9 + 1", "what is 1,2 + 3", "(2 + 3", "2 + 3)", "what's 2 + + 3",
                     "5 / $2", "what's 5 x", "x 5", "What is 2 + 2 in binary?", "1-2", "what's 3 % 2",
                     "50% of the time", "100%", "what is 2", "+", "( )"] {
            XCTAssertNil(MathAsk.reply(for: text), text)
        }
    }

    /// Bounds, on each side: 15 digits in a number and a result under 10^15
    /// are worked out; one more digit, or a result at 10^15, is not.
    func testBoundsOnEachSide() {
        XCTAssertEqual(MathAsk.reply(for: "999999999999999 + 0"), "999999999999999 + 0 is 999,999,999,999,999.")
        XCTAssertNil(MathAsk.reply(for: "1000000000000000 + 0"))
        XCTAssertNil(MathAsk.reply(for: "999999999999999 + 1"))
        XCTAssertEqual(MathAsk.reply(for: "99999999999999 + 1"), "99999999999999 + 1 is 100,000,000,000,000.")
        XCTAssertEqual(MathAsk.reply(for: "-999999999999999 + 0"), "-999999999999999 + 0 is -999,999,999,999,999.")
        XCTAssertNil(MathAsk.reply(for: "-999999999999999 - 1"))
        // Six decimals are shown whole; a seventh makes the answer "about".
        XCTAssertEqual(MathAsk.reply(for: "1 / 64"), "1 ÷ 64 is 0.015625.")
        XCTAssertEqual(MathAsk.reply(for: "1 / 128"), "1 ÷ 128 is about 0.007813.")
        XCTAssertEqual(MathAsk.reply(for: "$1 / 4"), "$1 ÷ 4 is $0.25.")
        XCTAssertEqual(MathAsk.reply(for: "$1 / 8"), "$1 ÷ 8 is about $0.13.")
    }
}
