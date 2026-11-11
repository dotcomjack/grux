import XCTest
@testable import Grux

/// D188, live 2026-11-07 2:03 PM on grux-local:2b (sense pass 25, a fresh
/// thread): "Rewrite this to sound friendlier: Send me the report by 5." came
/// back "Send me the report by 5.", the person's own words, shown as if the
/// rewrite were done. D183 measured that no framing makes this model rewrite
/// reliably, so Grux says so: a local reply to a rewrite, summary, translation
/// or proofread that is the pasted text word for word keeps the text and gets
/// one line after it saying nothing was changed and what to try. Only wrapping
/// quotes and spacing are not a change (W64-FIX P2-2).
final class UnchangedTransformTests: XCTestCase {

    private let line = DraftAsk.unchangedLine

    func testAnEchoOfThePastedTextIsNamed() throws {
        let cases: [(ask: String, reply: String)] = [
            ("Rewrite this to sound friendlier: Send me the report by 5.", "Send me the report by 5."),
            // Wrapping quotes and spacing are not a change.
            ("Rewrite this to sound friendlier: Send me the report by 5.", "\"Send me the report  by 5.\""),
            ("Rewrite this to sound friendlier: Send me the report by 5.", "\u{201C}Send me the report by 5.\u{201D}\n"),
            ("Paraphrase the following:\nThe meeting moved to Thursday because two people were out.",
             "The meeting moved to Thursday because two people were out."),
            ("The meeting moved to Thursday because two people were out.\n\nShorten this.",
             "The meeting moved to Thursday because two people were out."),
            ("Translate \"your table has been booked\" into Spanish", "\"your table has been booked\""),
        ]
        for c in cases {
            let out = try XCTUnwrap(DraftAsk.unchangedTransform(reply: c.reply, ask: c.ask), c.ask)
            XCTAssertTrue(out.hasPrefix(c.reply.trimmingCharacters(in: .whitespacesAndNewlines)), out)
            XCTAssertTrue(out.hasSuffix(line), out)
        }
    }

    /// One word changed, added or dropped is a rewrite, however small: no line.
    func testAnyChangedWordIsNotAnEcho() {
        let ask = "Rewrite this to sound friendlier: Send me the report by 5."
        for reply in [
            "Send me the report by 5, please.",       // one word added
            "Send me the report by 5 thanks",         // one word added, no stop
            "Send the report by 5.",                  // one word dropped
            "Please send me the report by 5.",
            "Could you send me the report by 5?",
            "I can send that to you by 5.",           // D183's answer, not an echo
            "",
        ] {
            XCTAssertNil(DraftAsk.unchangedTransform(reply: reply, ask: ask), reply)
        }
    }

    /// For a proofread, a capital, a stop or a comma is a change (W64-FIX P2-2);
    /// the exact text, quoted or spaced differently, is still an echo.
    func testForAProofreadCaseAndPunctuationAreChanges() throws {
        let ask = "Proofread this: Send me the report by 5."
        for reply in ["send me the report by 5.", "Send me the report by 5", "Send me the report by 5!",
                      "Send me, the report by 5."] {
            XCTAssertNil(DraftAsk.unchangedTransform(reply: reply, ask: ask), reply)
        }
        for reply in ["Send me the report by 5.", "\"Send me the report  by 5.\""] {
            XCTAssertNotNil(DraftAsk.unchangedTransform(reply: reply, ask: ask), reply)
        }
        XCTAssertNotNil(DraftAsk.unchangedTransform(reply: "Send me the report by 5.",
                                                    ask: "Send me the report by 5.\n\nPolish this."))
    }

    /// W64-FIX round 2 P2-2: case and punctuation count only where they are
    /// the job (proofread, polish, clean up, tidy up). A rewrite typed in
    /// lowercase that came back capitalised with a stop is still an echo.
    func testARewriteOnlyCapitalisedIsStillAnEcho() throws {
        for (ask, reply) in [
            ("rewrite this to sound friendlier: send me the report by 5", "Send me the report by 5."),
            ("translate this into French: the order has shipped today", "The order has shipped today."),
            ("Summarize this: we moved the launch to friday", "\"We moved the launch to Friday!\""),
        ] {
            let out = try XCTUnwrap(DraftAsk.unchangedTransform(reply: reply, ask: ask), ask)
            XCTAssertTrue(out.hasSuffix(line), out)
        }
    }

    /// W64-FIX round 3 P2-2: a format job named anywhere in the instruction,
    /// not only as its first verb, makes capitals and punctuation count.
    func testAFormatJobAnywhereInTheInstructionCounts() {
        let text = "i think we should meet on monday at the cafe"
        let fixed = "I think we should meet on Monday at the cafe."
        for ask in ["Rewrite and proofread this: " + text, "Could you rewrite and polish this: " + text,
                    "Rewrite this with proper capitalization: " + text,
                    "Rewrite this and fix the grammar: " + text,
                    "Shorten this and fix the spelling and punctuation: " + text,
                    text + "\n\nRewrite this and fix the capitals."] {
            XCTAssertNil(DraftAsk.unchangedTransform(reply: fixed, ask: ask), ask)
            XCTAssertNotNil(DraftAsk.unchangedTransform(reply: text, ask: ask), "an exact echo is still named: \(ask)")
        }
    }

    /// Line breaks are part of what a clean-up or proofread changes.
    func testALineBreakFixIsAChangeForACleanUp() {
        XCTAssertNil(DraftAsk.unchangedTransform(reply: "Send me the report by 5 please",
                                                 ask: "Clean up this:\nSend me the report\nby 5 please"))
    }

    /// W64-FIX P2-2: a proofread or tidy-up whose whole change is capitals or
    /// punctuation was told "this local model did not change it".
    func testACapitalOrPunctuationFixIsAChange() {
        for (ask, reply) in [
            ("Proofread this: i think we should meet on monday at the cafe",
             "I think we should meet on Monday at the cafe."),
            ("Proofread this: hi sam how are you doing today", "Hi Sam, how are you doing today?"),
            ("Clean up this: Meet at 5 pm on 3/4 in room two", "Meet at 5 pm on 3.4 in room two"),
        ] {
            XCTAssertNil(DraftAsk.unchangedTransform(reply: reply, ask: ask), reply)
        }
    }

    /// Only a transform of pasted text is checked: a reply that repeats a plain
    /// ask, or an ask that names the person's own things, gets nothing.
    func testOnlyATransformOfPastedTextIsChecked() {
        for (ask, reply) in [
            ("Send me the report by 5.", "Send me the report by 5."),
            ("Summarize my inbox: what's new?", "what's new?"),
            ("Rewrite: hi there", "hi there"),
            ("Summarize this and save it to my notes: The meeting moved to Thursday.", "The meeting moved to Thursday."),
        ] {
            XCTAssertNil(DraftAsk.unchangedTransform(reply: reply, ask: ask), ask)
        }
    }

    /// The pasted text is read from each shape the transform rule takes.
    func testThePastedTextIsReadFromEveryShape() {
        XCTAssertEqual(DraftAsk.pastedText("Rewrite this to sound friendlier: Send me the report by 5."),
                       "Send me the report by 5.")
        XCTAssertEqual(DraftAsk.pastedText("One two three four five.\n\nSummarize this."), "One two three four five.")
        XCTAssertEqual(DraftAsk.pastedText("Translate \"your table has been booked\" into Spanish"),
                       "your table has been booked")
        XCTAssertNil(DraftAsk.pastedText("Summarize this: we moved it"))  // 3 words: a topic
        XCTAssertNotNil(DraftAsk.pastedText("Summarize this: we moved it today"))  // 4 words: the text
    }

    /// The line says only what is true of any echo (a proofread of clean text
    /// is one too) and names where a larger model is.
    func testTheLineIsPlain() {
        XCTAssertTrue(line.contains("word for word"), line)
        XCTAssertTrue(line.contains("Cookbook"), line)
        XCTAssertFalse(line.contains("\u{2014}") || line.contains("\u{2013}"), line)
    }

    /// Wired into ChatService for local replies only, beside the other local checks.
    func testChatServiceAppliesItToLocalReplies() throws {
        let src = try String(contentsOfFile: #filePath.replacingOccurrences(
            of: "Tests/GruxTests/UnchangedTransformTests.swift", with: "Sources/Grux/ChatService.swift"))
        let call = try XCTUnwrap(src.range(of: "DraftAsk.unchangedTransform(reply: finalText, ask: userText)"))
        let before = src[src.index(call.lowerBound, offsetBy: -160)..<call.lowerBound]
        XCTAssertTrue(before.contains("pending.provider == \"local\""), String(before))
        // Live 2:40 PM: "Proofread this: Your order has shipped and we sent the
        // tracking number." came back word for word, but the action-claim check
        // had already added "I only wrote this..." for "we sent", so the reply
        // no longer matched. The echo is judged on the model's own reply, before
        // any check that adds a line after it.
        for later in ["ActionClaimGuard.vet(reply: finalText", "DraftAsk.checkingDays(reply: finalText",
                      "InventedFacts.check(reply: finalText", "CalendarClaimGuard.vet(reply: finalText"] {
            let at = try XCTUnwrap(src.range(of: later), later)
            XCTAssertLessThan(call.lowerBound, at.lowerBound, "the echo check runs before \(later)")
        }
    }

    /// The same live reply, with the note the action-claim check would add,
    /// is still named when judged first (the bare reply is what it reads).
    func testAnEchoThatSaysSentIsNamed() throws {
        let ask = "Proofread this: Your order has shipped and we sent the tracking number."
        let out = try XCTUnwrap(DraftAsk.unchangedTransform(
            reply: "Your order has shipped and we sent the tracking number.", ask: ask))
        XCTAssertTrue(out.hasSuffix(line), out)
    }
}
