import XCTest
@testable import Grux

/// D210 item 14. Live Nov 9 4:04 PM: "Please remember that I take my coffee
/// black." came back "Got it, I will remember: I take my coffee black", which
/// reads as Grux's own coffee, with no period. The fact is kept in the
/// person's words; the reply says it back in Grux's voice.
@MainActor
final class RememberReplyVoiceTests: XCTestCase {

    private func reply(_ fact: String) -> String {
        ToolReplyCopy.forPerson(tool: "remember_fact", input: ["fact": fact], result: "ok: saved fact '\(fact)'")
    }

    func testTheLiveCaseSaysYourCoffee() {
        XCTAssertEqual(reply("I take my coffee black"), "Got it, I will remember: you take your coffee black.")
    }

    func testEveryFirstPersonFormTurnsToYou() {
        XCTAssertEqual(reply("I'm allergic to peanuts"), "Got it, I will remember: you're allergic to peanuts.")
        XCTAssertEqual(reply("I am left handed"), "Got it, I will remember: you are left handed.")
        XCTAssertEqual(reply("I was born in Ohio"), "Got it, I will remember: you were born in Ohio.")
        XCTAssertEqual(reply("I've moved to Denver"), "Got it, I will remember: you've moved to Denver.")
        XCTAssertEqual(reply("I’d rather not get calls before 9"), "Got it, I will remember: you’d rather not get calls before 9.")
        XCTAssertEqual(reply("Mornings suit me best, the blue mug is mine"),
                       "Got it, I will remember: Mornings suit you best, the blue mug is yours.")
        XCTAssertEqual(reply("my dentist is Dr. Lee"), "Got it, I will remember: your dentist is Dr. Lee.")
        XCTAssertEqual(reply("I teach myself piano."), "Got it, I will remember: you teach yourself piano.")
    }

    /// A word that only contains "i" or "my" is not a pronoun.
    func testWordsThatOnlyLookLikePronounsStay() {
        XCTAssertEqual(reply("Sam prefers short answers."), "Got it, I will remember: Sam prefers short answers.")
        XCTAssertEqual(reply("Mia likes my mystery novels"), "Got it, I will remember: Mia likes your mystery novels.")
        XCTAssertEqual(reply("Wi-Fi password lives in iCloud"), "Got it, I will remember: Wi-Fi password lives in iCloud.")
    }

    /// "Call me Sam when you greet me" cannot be turned around word by word
    /// (me becomes you, you would become I): it is said back as their words.
    func testAFactThatAlsoSaysYouIsQuotedAsTheirWords() {
        XCTAssertEqual(reply("call me Sam when you greet me"),
                       "Got it, I will remember, in your words: \"call me Sam when you greet me.\"")
    }

    func testAFactWithNoPersonEndsAsASentence() {
        XCTAssertEqual(reply("the office code is 4412"), "Got it, I will remember: the office code is 4412.")
        XCTAssertEqual(reply("Is the gym open Sundays?"), "Got it, I will remember: Is the gym open Sundays?")
    }
}
