import XCTest
@testable import Grux

/// D178, live on grux-local:2b (sense pass 22): "Write a two sentence bio for
/// my coffee cart, in the first person, starting with when I opened it" got
/// "I opened my coffee cart in 2018 ...", and six more shops the same; on
/// 2026-11-06 all seven said 2024 and "the corner of Elm and Main". A line
/// naming what the ask never gave (`logs/d178/probe-*.txt`: an instruction
/// line alone left most years in place and added refusals) follows the writing.
final class InventedFactsTests: XCTestCase {
    let bio = "Write a two sentence bio for my coffee cart, in the first person, starting with when I opened it"

    func testAYearAndAStreetTheAskNeverGaveAreNamed() throws {
        let reply = "I opened the coffee cart in 2024 to bring you fresh brews every morning. It's now a beloved spot on the corner of Elm and Main."
        let out = try XCTUnwrap(InventedFacts.check(reply: reply, ask: bio, grounded: bio))
        XCTAssertTrue(out.hasPrefix(reply), out)
        XCTAssertTrue(out.contains("2024"), out)
        XCTAssertTrue(out.contains("the corner of Elm and Main"), out)
        XCTAssertTrue(out.contains("you did not give"), out)
    }

    func testASpanOfYearsAndAStreetNameAreNamed() throws {
        let reply = "I opened my bookshop six years ago on Maple Street. Now it is a hub for readers."
        let out = try XCTUnwrap(InventedFacts.check(reply: reply, ask: bio, grounded: bio))
        XCTAssertTrue(out.contains("six years"), out)
        XCTAssertTrue(out.contains("Maple Street"), out)
        let digits = "I've been running this repair shop for 15 years."
        XCTAssertTrue(try XCTUnwrap(InventedFacts.check(reply: digits, ask: bio, grounded: bio)).contains("15 years"))
    }

    /// What the ask or the turn's context gave is the person's, not made up.
    func testWhatWasGivenIsNeverNamed() {
        let ask = "Write a two sentence bio for our bakery website: we opened in 1985 and started baking sourdough in 2010"
        XCTAssertNil(InventedFacts.check(
            reply: "In 1985, we opened our doors, and since 2010 our passion has been sourdough. For over 40 years we've served the neighborhood.",
            ask: ask, grounded: ask, now: Self.nov2026))
        XCTAssertNil(InventedFacts.check(reply: "I opened my coffee cart in 2019 on Pine Street.",
                                         ask: bio, grounded: bio + "\nMEMORY: they opened the cart in 2019 on Pine Street"))
        XCTAssertNil(InventedFacts.check(reply: "I opened my coffee cart in [year]. It is a beloved spot in [town].",
                                         ask: bio, grounded: bio))
    }

    /// W59-FIX round 1 P2: what the person gave in another form is given:
    /// "40th" is 40 years, "ten" is 10, "Elm St." is Elm Street, "Elm and
    /// Main" is their corner, "'85" is 1985. P3: a slogan is not a street.
    func testWhatWasGivenInAnotherFormIsNeverNamed() {
        for (ask, reply) in [
            ("Write a toast for my parents' 40th anniversary.", "Here's to 40 years of love."),
            ("Write a LinkedIn post about my 10 year work anniversary", "Ten years ago I joined, and after 10 years I still love it."),
            ("Write a card for my wife, we've been married ten years", "After 10 years together, I love you more."),
            ("Write a two sentence bio for my bakery on Elm St.", "We bake every morning on Elm Street."),
            ("Write a bio for my coffee cart at Elm and Main.", "Find us on the corner of Elm and Main."),
            ("Write a bio for my cafe on Maple Street", "Our Maple Street cafe opened in spring."),
            ("Write a bio for my diner, open since '85", "We have served pancakes since 1985."),
            ("Write a slogan for my coffee cart", "Coffee Your Way, every morning."),
        ] {
            XCTAssertNil(InventedFacts.check(reply: reply, ask: ask, grounded: ask), "\(ask) -> \(reply)")
        }
        let joined = InventedFacts.check(reply: "Bean There Cafe\nMaple Street", ask: bio, grounded: bio) ?? ""
        XCTAssertTrue(joined.hasSuffix("you did not give Maple Street, so I made it up."), joined)
        // A different number or street is still named.
        XCTAssertNotNil(InventedFacts.check(reply: "Here's to 25 years of love.",
                                            ask: "Write a toast for my parents' 40th anniversary.",
                                            grounded: "Write a toast for my parents' 40th anniversary."))
        XCTAssertNotNil(InventedFacts.check(reply: "Visit us on Oak Street.", ask: "Write a bio for my bakery on Elm St.",
                                            grounded: "Write a bio for my bakery on Elm St."))
    }

    /// W59-FIX round 2 P2: the prompt's own numbers ("1 to 3 short
    /// sentences", the NOW line) never make a made-up span read as given; a
    /// street word given alone ("my farmers market stand") never makes "Market
    /// Street" read as given; "twenty-five years" is one number.
    func testThePromptsNumbersAndABareWordAreNotGiven() throws {
        let ask = "Write a two sentence bio for my coffee cart"
        let prompt = ask + "\nReply in 1 to 3 short sentences, one to three at most. NOW: Thursday, Nov 6 2026 9:10 AM. last 20 min. WORKING RIGHT NOW (5)"
        for reply in ["We've been brewing for five years.", "Twenty years of coffee.", "For 12 years we have served you."] {
            XCTAssertNotNil(InventedFacts.check(reply: reply, ask: ask, grounded: prompt, personal: ask), reply)
        }
        for (ask, street) in [("Write a two sentence bio for my farmers market stand", "Market Street"),
                              ("Write a bio for my church bake sale", "Church Street"),
                              ("Write a bio for my lake house rental", "Lake Drive"),
                              ("Write a bio for my bakery in the park", "Park Avenue")] {
            let out = InventedFacts.check(reply: "Find us every Saturday on \(street).", ask: ask, grounded: ask) ?? ""
            XCTAssertTrue(out.contains("you did not give \(street)"), "\(ask): \(out)")
        }
        let toast = "Write a toast for our 25th anniversary"
        XCTAssertNil(InventedFacts.check(reply: "Here's to twenty-five years.", ask: toast, grounded: toast))
        let out = try XCTUnwrap(InventedFacts.check(reply: "Here's to thirty-five years.", ask: toast, grounded: toast))
        XCTAssertTrue(out.contains("you did not give thirty-five years"), out)
        // A street given with its own street word stays given.
        XCTAssertNil(InventedFacts.check(reply: "We are at 12 Oak Street.", ask: "Write a bio for my shop at 12 Oak St",
                                         grounded: "Write a bio for my shop at 12 Oak St"))
    }

    /// W59-FIX round 3 P2: a span in memory or the person's profile is given;
    /// the prompt's own headers ("last 20 min") still are not. A corner the
    /// person gave as "Elm & Main" or "Elm St. and Main St." is given; one
    /// street of a corner is not the corner.
    func testMemorySpansAndCornerFormsAreGiven() {
        let ask = "Write a bio for my bakery"
        let blocks: [[String: Any]] = [["type": "text", "text": """
            RECENT_SPOKEN_MEMORIES (historical context from ambient session, last 20 min - already handled):
            (none)

            RELEVANT_MEMORIES (top 3 matches from Grux's persistent memory):
            - I've been baking for 15 years
            """]]
        let personal = InventedFacts.personal(ask: ask, messages: [], systemBlocks: blocks)
        XCTAssertNil(InventedFacts.check(reply: "For 15 years we have baked.", ask: ask, grounded: personal, personal: personal))
        XCTAssertNotNil(InventedFacts.check(reply: "For 20 years we have baked.", ask: ask, grounded: personal, personal: personal))
        for given in ["Write a bio for my coffee cart at Elm & Main", "Write a bio for my coffee cart at Elm St. and Main St."] {
            XCTAssertNil(InventedFacts.check(reply: "Find us on the corner of Elm and Main.", ask: given, grounded: given), given)
        }
        let one = "Write a bio for my coffee cart at the corner of Elm and Oak"
        XCTAssertNotNil(InventedFacts.check(reply: "Find us on the corner of Elm and Main.", ask: one, grounded: one))
    }

    /// W59-FIX round 4 P2: a memory row's own numbering and time stamp
    /// ("  1. [fact · Nov 3, 14:05]", "  • [Nov 4 7:12 PM]") give no span;
    /// only the text the person told Grux does.
    func testAMemoryRowsNumberingAndStampGiveNothing() {
        let ask = "Write a two sentence bio for my coffee cart"
        let rows = (1...6).map { "  \($0). [fact · Nov \($0 + 2), 14:05] Likes oat milk" }.joined(separator: "\n")
        let blocks: [[String: Any]] = [["type": "text", "text": """
            RELEVANT_MEMORIES (top 6 matches from Grux's persistent memory, hybrid semantic + keyword ranking):
            \(rows)
              7. [fact · Nov 1, 9:30] Has run the cart for 15 years

            PENDING_MEMORIES (unreviewed items from the user's "remember this" inbox):
              • [Nov 4 7:12 PM] call the plumber
            """]]
        let personal = InventedFacts.personal(ask: ask, messages: [], systemBlocks: blocks)
        for reply in ["For five years we have served you.", "Twelve years of coffee.", "For 30 years now."] {
            XCTAssertNotNil(InventedFacts.check(reply: reply, ask: ask, grounded: personal, personal: personal), reply)
        }
        XCTAssertNil(InventedFacts.check(reply: "For 15 years we have served you.", ask: ask, grounded: personal, personal: personal))
    }

    /// W59-FIX round 5 P3: a person card's own count and date ("mentioned
    /// 14x, last Nov 23") give no span.
    func testAPersonCardsCountAndDateGiveNothing() {
        let ask = "Write a birthday card for my brother Sam"
        let blocks: [[String: Any]] = [["type": "text", "text": """
            PERSON_CONTEXT (dossiers Grux has built on people named in the user's latest message):
            Sam Lee: brother (mentioned 14x, last Nov 23)
              • loves fishing
            """]]
        let personal = InventedFacts.personal(ask: ask, messages: [], systemBlocks: blocks)
        XCTAssertFalse(InventedFacts.numbers(in: personal).contains(23), personal)
        XCTAssertFalse(InventedFacts.numbers(in: personal).contains(14), personal)
    }

    /// W59-FIX round 6 P2: a year the person gave in an earlier message, in
    /// memory or in a tool result makes a span counted from it given, as a
    /// year in the ask does ("opened it in 2019" then "for seven years").
    func testASpanCountedFromAYearGivenEarlierIsGiven() {
        let ask = "Write a two sentence bio for my coffee cart"
        let personal = InventedFacts.personal(ask: ask, messages: [["role": "user", "content": "I run a coffee cart. I opened it in 2019."],
                                                                   ["role": "assistant", "content": "Nice!"]])
        let reply = "Since 2019, our cart has served the best espresso in town. For seven years we have poured every cup with care."
        XCTAssertNil(InventedFacts.check(reply: reply, ask: ask, grounded: personal, personal: personal, now: Self.nov2026))
        let none = InventedFacts.personal(ask: ask, messages: [["role": "user", "content": "I run a coffee cart."]])
        XCTAssertNotNil(InventedFacts.check(reply: "For seven years we have poured every cup.", ask: ask, grounded: none, personal: none,
                                            now: Self.nov2026))
    }

    /// W59-FIX round 7 P2: a span is given only when its number was, or when
    /// it counts from a year given (now minus that year, one either side); a
    /// price, an order number or another span beside a year gives nothing.
    func testOnlyASpanThatCountsFromAGivenYearIsGiven() {
        let ask = "Write a two sentence bio for my coffee cart"
        let opened = InventedFacts.personal(ask: ask, messages: [["role": "user", "content": "I opened it in 2019."]])
        for (reply, named) in [("For over 30 years we have poured every cup.", true),
                               ("Our baristas bring 15 years of experience.", true),
                               ("For seven years we have poured every cup.", false),
                               ("For six years we have poured every cup.", false),
                               ("For eight years we have poured every cup.", false),
                               ("For nine years we have poured every cup.", true),
                               ("For five years we have poured every cup.", true)] {
            let out = InventedFacts.check(reply: reply, ask: ask, grounded: opened, personal: opened, now: Self.nov2026)
            XCTAssertEqual(out != nil, named, reply)
        }
        let rent = InventedFacts.personal(ask: ask, messages: [["role": "user", "content": "My rent is $1850 a month. Order #2041."]])
        XCTAssertNotNil(InventedFacts.check(reply: "For over 20 years, our cart has poured the best espresso.", ask: ask,
                                            grounded: rent, personal: rent, now: Self.nov2026))
    }
    /// W59-FIX round 8 P2: a span between two years the person gave, or up
    /// to a year ahead, counts too; exactly one off is given, two off is not.
    func testASpanBetweenTwoGivenYearsOrAheadIsGiven() {
        for (ask, reply, named) in [
            ("Write my retirement speech. I worked at Ford from 1985 to 2020.", "After 35 years at Ford, I am grateful.", false),
            ("Write my retirement speech. I worked at Ford from 1985 to 2020.", "After 36 years at Ford, I am grateful.", false),
            ("Write my retirement speech. I worked at Ford from 1985 to 2020.", "After 37 years at Ford, I am grateful.", true),
            ("Write a toast for us. We married in 1974 and renewed our vows in 2024.", "Fifty years after our wedding, we said yes again.", false),
            ("Write a bio for my bakery. We opened in 1985 and started sourdough in 2010.", "25 years later we began sourdough.", false),
            ("Write a short speech for my graduation. I graduate in 2028.", "In two years I will walk across that stage.", false),
            ("Write a short speech for my graduation. I graduate in 2028.", "In four years I will walk across that stage.", true),
        ] {
            let out = InventedFacts.check(reply: reply, ask: ask, grounded: ask, personal: ask, now: Self.nov2026)
            XCTAssertEqual(out != nil, named, "\(ask) -> \(reply)")
        }
    }
    /// W59-FIX round 9 P3: a number far ahead ("Order #2041", "555-2036") is
    /// not a year a span counts to; up to five years ahead is.
    func testANumberFarAheadIsNoYear() {
        let ask = "Write a two sentence bio for my coffee cart"
        for said in ["Order #2041 is in.", "Call 555-2036.", "We moved to 2031 Elm Street.", "It cost $2040."] {
            let p = InventedFacts.personal(ask: ask, messages: [["role": "user", "content": said]])
            for n in ["15", "10", "5", "14"] {
                XCTAssertNotNil(InventedFacts.check(reply: "For over \(n) years we have poured espresso.", ask: ask, grounded: p,
                                                    personal: p, now: Self.nov2026), "\(said) \(n)")
            }
        }
        // W59-FIX round 10 P2: a year far ahead, said as a year, still counts.
        let letter = "Write a letter to my daughter to open when she turns 18 in 2038."
        XCTAssertNil(InventedFacts.check(reply: "In twelve years, when you read this, I hope you smile.", ask: letter,
                                         grounded: letter, personal: letter, now: Self.nov2026))
        let retire = "Write a speech for my party. I retire in 2035."
        XCTAssertNil(InventedFacts.check(reply: "In nine years I will hang up my apron.", ask: retire, grounded: retire,
                                         personal: retire, now: Self.nov2026))
    }
    /// W59-FIX round 11 P2: a year range typed with a hyphen ("1985-2020"),
    /// "mid-2019" and "Est. 2019" are years; a phone number is not.
    func testAHyphenatedYearRangeCounts() {
        XCTAssertEqual(InventedFacts.yearMarks(in: "I worked at the mill 1985-2020."), [1985, 2020])
        XCTAssertEqual(InventedFacts.yearMarks(in: "We opened in mid-2019."), [2019])
        XCTAssertEqual(InventedFacts.yearMarks(in: "the 2019-2020 season"), [2019, 2020])
        XCTAssertEqual(InventedFacts.yearMarks(in: "Call 555-2036 or #2041, $2040, 2031 Elm Street"), [])
        let ask = "Write my retirement speech. I worked at the mill 1985-2020."
        XCTAssertNil(InventedFacts.check(reply: "After 35 years at the mill, I am ready to rest.", ask: ask, grounded: ask,
                                         personal: ask, now: Self.nov2026))
        let mid = "Write a bio for my bakery. We opened in mid-2019."
        XCTAssertNil(InventedFacts.check(reply: "For seven years we have baked bread.", ask: mid, grounded: mid,
                                         personal: mid, now: Self.nov2026))
    }
    /// W59-FIX round 12 P2: a range with a two-digit end ("1985-89",
    /// "2010-15") is a range; its end counts when it is later than the start.
    func testATwoDigitRangeEndCounts() {
        XCTAssertEqual(InventedFacts.yearMarks(in: "Army 1985-89, Ford 1990-2020"), [1985, 1989, 1990, 2020])
        XCTAssertEqual(InventedFacts.yearMarks(in: "the 2019-20 season"), [2019, 2020])
        XCTAssertEqual(InventedFacts.yearMarks(in: "on 2019-05-12"), [2019])
        XCTAssertEqual(InventedFacts.yearMarks(in: "Call 555-2036"), [])
        let ask = "Write my retirement speech. I served in the Army 1985-89 and worked at Ford 1990-2020."
        XCTAssertNil(InventedFacts.check(reply: "After four years in the Army and 30 years at Ford, I am grateful.", ask: ask,
                                         grounded: ask, personal: ask, now: Self.nov2026))
        let taught = "Write a bio for me. I taught at Lincoln High 2010-15."
        XCTAssertNil(InventedFacts.check(reply: "For five years I taught at Lincoln High.", ask: taught, grounded: taught,
                                         personal: taught, now: Self.nov2026))
    }
    /// W59-FIX round 13 P2: a year given as a range end ("2010-15") is given
    /// when the draft writes it out ("2015"); P3: an en dash or a spaced
    /// hyphen is a range too.
    func testARangeEndWrittenOutIsGiven() {
        for (ask, reply) in [("Write a bio for me. I taught at Lincoln High 2010-15.", "From 2010 to 2015 I taught at Lincoln High."),
                             ("Write a bio for me. I served in the Army 1985-89.", "From 1985 to 1989 I served in the Army."),
                             ("Write a bio for me. I coached the 2019-20 season.", "I coached the 2019-2020 season."),
                             ("Write a bio for me. I served in the Army 1985\u{2013}89.", "For four years I served in the Army."),
                             ("Write a bio for me. I served in the Army 1985 - 89.", "For four years I served in the Army.")] {
            XCTAssertNil(InventedFacts.check(reply: reply, ask: ask, grounded: ask, personal: ask, now: Self.nov2026), ask)
        }
    }
    /// W59-P3 (the round 13 regression): a spaced dash beside a lone number
    /// is not a range, so the year beside it stays given ("Founded 1985 - 3
    /// generations"); a real spaced range still reads both ends.
    func testASpacedDashBesideALoneNumberKeepsTheYear() {
        XCTAssertEqual(InventedFacts.yearMarks(in: "Founded 1985 - 3 generations"), [1985])
        XCTAssertEqual(InventedFacts.yearMarks(in: "Founded 1985 \u{2013} 3 generations"), [1985])
        XCTAssertEqual(InventedFacts.yearMarks(in: "Founded 1985 \u{2014} 300 loaves a day"), [1985])
        XCTAssertEqual(InventedFacts.yearMarks(in: "Generation 3 - 1985 to now"), [1985])
        XCTAssertEqual(InventedFacts.yearMarks(in: "Army 1985 - 89"), [1985, 1989])
        XCTAssertEqual(InventedFacts.yearMarks(in: "Ford 1990 \u{2013} 2020"), [1990, 2020])
        XCTAssertEqual(InventedFacts.yearMarks(in: "Ford 1990\u{2013}2020"), [1990, 2020])
        let ask = "Write a bio for our bakery. Founded 1985 - 3 generations of bakers."
        XCTAssertNil(InventedFacts.check(reply: "We have baked bread here since 1985.", ask: ask, grounded: ask,
                                         personal: ask, now: Self.nov2026))
        XCTAssertNotNil(InventedFacts.check(reply: "We have baked bread here since 1990.", ask: ask, grounded: ask,
                                            personal: ask, now: Self.nov2026))
        // The span counted from the given year is given too.
        XCTAssertNil(InventedFacts.check(reply: "For 41 years we have baked bread here.", ask: ask, grounded: ask,
                                         personal: ask, now: Self.nov2026))
    }
    static let nov2026 = DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 11, day: 6).date!

    /// Only writing about the person: a history of Rome carries its own years,
    /// and a question is not writing.
    func testOnlyWritingAboutThePersonIsChecked() {
        XCTAssertNil(InventedFacts.check(reply: "Rome was founded in 753 BC and the Colosseum opened in 80 AD, 1,900 years ago.",
                                         ask: "Write a short text about the history of Rome",
                                         grounded: "Write a short text about the history of Rome"))
        XCTAssertNil(InventedFacts.check(reply: "The shop opened in 2018.", ask: "When did the shop open?",
                                         grounded: "When did the shop open?"))
        XCTAssertNotNil(InventedFacts.check(reply: "Dear landlord, I have lived at 12 Oak Street since 2019.",
                                            ask: "Write a short email to my landlord about the broken heater",
                                            grounded: "Write a short email to my landlord about the broken heater"))
    }

    /// A year in the person's messages or the system prompt is given; one in
    /// an earlier reply of the model's own is not.
    func testGroundingIsThePersonsNotTheModels() {
        let grounded = InventedFacts.grounded(
            ask: bio,
            systemBlocks: [["type": "text", "text": "MEMORY: the bakery moved to Pine Street"]],
            messages: [["role": "user", "content": "my old cart"],
                       ["role": "assistant", "content": "I opened the coffee cart in 2024."],
                       ["role": "user", "content": [["type": "tool_result", "content": "Note: opened 2019"]]]])
        XCTAssertTrue(grounded.contains("Pine Street") && grounded.contains("2019") && grounded.contains("my old cart"))
        XCTAssertFalse(grounded.contains("2024"))
        XCTAssertNotNil(InventedFacts.check(reply: "I opened my coffee cart in 2024.", ask: bio, grounded: grounded))
    }

    /// Live 6:23 AM: the 2B model copied the line from an earlier reply in the
    /// thread, naming 1985, which the ask gave. A copy is never left standing.
    func testACopiedLineIsTakenOut() throws {
        let ask = "Write a two sentence bio for our bakery website: we opened in 1985 and started baking sourdough in 2010"
        let copied = "Check this before you use it: you did not give 1985 or the corner of Elm and Main, so I made them up."
        let reply = "I opened the bakery in 1985 and have been baking sourdough since 2010.\n\n" + copied
        let out = try XCTUnwrap(InventedFacts.check(reply: reply, ask: ask, grounded: ask))
        XCTAssertEqual(out, "I opened the bakery in 1985 and have been baking sourdough since 2010.")
        let both = "I opened the bakery in 1985 on the corner of Elm and Main.\n\n" + copied + "\n\n" + ActionClaimGuard.writtenOnlyNote
        let fixed = try XCTUnwrap(InventedFacts.check(reply: both, ask: ask, grounded: ask))
        XCTAssertFalse(fixed.contains("give 1985"), fixed)
        XCTAssertTrue(fixed.contains(ActionClaimGuard.writtenOnlyNote), fixed)
        XCTAssertTrue(fixed.hasSuffix("you did not give the corner of Elm and Main, so I made it up."), fixed)
    }

    /// Only the writing: not the paragraph Grux added after it.
    func testOnlyTheWritingIsRead() {
        let reply = "I opened my coffee cart in [year].\n\n" + ActionClaimGuard.writtenOnlyNote
        XCTAssertNil(InventedFacts.check(reply: reply, ask: bio, grounded: bio))
    }

    /// Order in the reply's checks: a local writing turn, after the claim guard.
    func testItRunsOnLocalTurnsAfterTheClaimGuard() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/ChatService.swift"), encoding: .utf8)
        let claim = try XCTUnwrap(src.range(of: "let claimCheck = ActionClaimGuard.vet("))
        let check = try XCTUnwrap(src.range(of: "InventedFacts.check(reply: finalText"))
        XCTAssertTrue(claim.lowerBound < check.lowerBound)
        let before = src[src.index(check.lowerBound, offsetBy: -200)..<check.lowerBound]
        XCTAssertTrue(before.contains("pending.provider == \"local\""))
    }
}
