import XCTest
@testable import Grux

/// D164, sense pass 20 on grux-local:2b: "Write a note to Day One about today"
/// got "I have not done that. Want me to?" and "Write a note to Joplin about the
/// recipe" got "I can't write notes directly to your specific app like Joplin.
/// You'll have to..." with no note. Grux writes to no notes app but its own, so
/// it writes the person's words out to paste in, or asks for them, and offers
/// Grux's Notes.
@MainActor
final class ForeignNoteAskTests: XCTestCase {

    typealias Ask = ForeignNoteAsk.Ask

    /// The live asks and the shapes around them, read.
    static let elsewhere: [(String, Ask)] = [
        ("Write a note to Day One about today", Ask(app: "Day One", topic: "today", words: nil)),
        ("Write a note to Joplin about the recipe", Ask(app: "Joplin", topic: "the recipe", words: nil)),
        ("add a note in Obsidian about the trip: flights booked, hotel still open",
         Ask(app: "Obsidian", topic: "the trip", words: "flights booked, hotel still open")),
        ("Can you write a quick note in Apple Notes: buy milk", Ask(app: "Apple Notes", topic: nil, words: "buy milk")),
        ("jot down a note in evernote about the call", Ask(app: "Evernote", topic: "the call", words: nil)),
        ("Please make a note in Bear saying the book is due Friday.", Ask(app: "Bear", topic: nil, words: "the book is due Friday")),
        ("Grux, write a short note to my OneNote about the plan", Ask(app: "OneNote", topic: "the plan", words: nil)),
        ("write a journal entry in Day One about the hike", Ask(app: "Day One", topic: "the hike", words: nil)),
        ("Write a note in the Drafts app saying call Mom", Ask(app: "Drafts", topic: nil, words: "call Mom")),
        ("Put a note in Logseq.", Ask(app: "Logseq", topic: nil, words: nil)),
        ("write a note to Google Keep for the groceries", Ask(app: "Google Keep", topic: "the groceries", words: nil)),
        ("Can you write a note in Joplin?", Ask(app: "Joplin", topic: nil, words: nil)),
    ]

    /// Not a note for another app: a note to keep in Grux, an app Grux can write
    /// to (Notion), a message to a person, a question about the past, a compound
    /// ask, an everyday word that only looks like an app, or no note at all.
    static let notElsewhere = [
        "Make a note to call my boss", "write a note to self: buy milk", "write a note in Grux about the trip",
        "Write a note to Notion about the launch", "Draft a quick note to my boss that I'll be late tomorrow.",
        "Did you write a note to Joplin?", "I wrote a note in Bear", "Write a note to Joplin and remind me tomorrow",
        "write a note to reflect on today", "write a note on day one of the trip", "write a note to bear in mind",
        "write a note to Bearington about lunch", "Open Joplin", "write the recipe in Joplin",
        "write a note about Joplin", "",
    ]

    func testANoteForAnAppGruxCannotWriteToIsReadAndNothingElseIs() {
        for (ask, read) in Self.elsewhere { XCTAssertEqual(ForeignNoteAsk.match(ask), read, ask) }
        for ask in Self.notElsewhere {
            XCTAssertNil(ForeignNoteAsk.match(ask), ask)
            XCTAssertNil(ForeignNoteAsk.reply(for: ask), ask)
        }
    }

    /// An app named by an everyday word is one only when capitalized, on its
    /// first letter: on, under and over the rule.
    func testAnEverydayWordIsAnAppOnlyWhenCapitalized() {
        XCTAssertEqual(ForeignNoteAsk.match("Write a note to Bear about lunch")?.app, "Bear")
        XCTAssertNil(ForeignNoteAsk.match("Write a note to bear about lunch"))
        XCTAssertEqual(ForeignNoteAsk.match("write a note in Day one about lunch")?.app, "Day One")
        XCTAssertNil(ForeignNoteAsk.match("write a note in day One about lunch"))
        XCTAssertEqual(ForeignNoteAsk.match("write a note in Reflect: call the bank")?.words, "call the bank")
        XCTAssertNil(ForeignNoteAsk.match("write a note to reflect: call the bank"))
        // A name that is no everyday word counts in any case.
        XCTAssertEqual(ForeignNoteAsk.match("write a note in JOPLIN about lunch")?.app, "Joplin")
        XCTAssertEqual(ForeignNoteAsk.match("write a note in obsidian")?.app, "Obsidian")
        // The name ends at a word boundary: a longer word is no app.
        XCTAssertNil(ForeignNoteAsk.match("write a note in Bears about lunch"))
        XCTAssertNil(ForeignNoteAsk.match("write a note in Obsidianite"))
        XCTAssertEqual(ForeignNoteAsk.match("write a note in the Bear app")?.app, "Bear")
    }

    /// The words the person gave are the note, with what a yes would do.
    func testTheWordsGivenAreWrittenOutWithTheOffer() {
        XCTAssertEqual(ForeignNoteAsk.reply(for: "add a note in Obsidian about the trip: flights booked, hotel still open"),
                       "Here is your note for Obsidian, to paste in:\n\nThe trip\nflights booked, hotel still open\n\n"
                       + "Grux can't write to Obsidian. Want me to keep this note in Grux's Notes too?")
        XCTAssertEqual(ForeignNoteAsk.reply(for: "Can you write a quick note in Apple Notes: buy milk"),
                       "Here is your note for Apple Notes, to paste in:\n\nbuy milk\n\n"
                       + "Grux can't write to Apple Notes. Want me to keep this note in Grux's Notes too?")
    }

    /// The live asks gave no words: Grux asks for them, and the answer is the note.
    /// W53-FIX: an ask with no words is told how to send them; the next
    /// message is never read as the note (see `Wave53FixTests`).
    func testAnAskWithNoWordsIsToldHowToSendThem() throws {
        let asked = try XCTUnwrap(ForeignNoteAsk.reply(for: "Write a note to Joplin about the recipe"))
        XCTAssertEqual(asked, "Grux can't write to Joplin, but it can write the note out for you to paste in, "
                       + "or keep it in Grux's Notes. Send the words after a colon, like "
                       + "\"Write a note to Joplin about the recipe: your words\".")
        XCTAssertEqual(ForeignNoteAsk.reply(for: "Write a note to Joplin about the recipe: 2 cups flour, 1 egg, bake 20 minutes at 350"),
                       "Here is your note for Joplin, to paste in:\n\nThe recipe\n2 cups flour, 1 egg, bake 20 minutes at 350\n\n"
                       + "Grux can't write to Joplin. Want me to keep this note in Grux's Notes too?")
        let plain = try XCTUnwrap(ForeignNoteAsk.reply(for: "Put a note in Logseq."))
        XCTAssertEqual(plain, "Grux can't write to Logseq, but it can write the note out for you to paste in, "
                       + "or keep it in Grux's Notes. Send the words after a colon, like \"Write a note to Logseq: your words\".")
        for answer in ["2 cups flour", "Call the vet", "Keep it in Grux's Notes", "never mind", "yes", ""] {
            XCTAssertNil(ForeignNoteAsk.reply(for: answer), answer)
        }
    }
}
