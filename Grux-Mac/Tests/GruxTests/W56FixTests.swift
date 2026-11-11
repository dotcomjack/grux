import XCTest
@testable import Grux

/// Wave 56 review round 1 (W56-FIX).
@MainActor
final class W56FixTests: XCTestCase {

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: P2 1 and 2, P3 5: the privacy caption says what Grux does this minute

    /// Permission and analysis on, but Focus log skips every tick (first frame
    /// not reviewed, no task, no key): no present-tense claim, and the reason
    /// is the watcher's own.
    func test_aSkippingWatcherIsNotCapturing() {
        for skip in FocusWatcher.Skip.allCases where skip != .screenAnalysisOff && skip != .noScreenAccess {
            let line = CapturePrivacyCopy.lead(analysisOn: true, watching: true, skip: skip, permitted: true)
            XCTAssertFalse(line.hasPrefix("Grux photographs"), "\(skip): \(line)")
            XCTAssertTrue(line.contains("It takes no frame now: \(skip.line)"), "\(skip): \(line)")
        }
    }

    func test_capturingOnlyWhenTheWatcherRunsWithNoSkip() {
        let on = CapturePrivacyCopy.lead(analysisOn: true, watching: true, skip: nil, permitted: true)
        XCTAssertTrue(on.hasPrefix("Grux photographs your screen on a timer and sends the frame to a vision model."), on)
        XCTAssertFalse(on.contains("no frame now"), on)
        // Paused from the menu bar, analysis off, or not allowed.
        let paused = CapturePrivacyCopy.lead(analysisOn: true, watching: false, skip: nil, permitted: true)
        XCTAssertTrue(paused.contains("It takes no frame now: Focus is paused."), paused)
        let off = CapturePrivacyCopy.lead(analysisOn: false, watching: false, skip: nil, permitted: true)
        XCTAssertTrue(off.contains("It takes no frame now: \(FocusWatcher.Skip.screenAnalysisOff.line)"), off)
        let denied = CapturePrivacyCopy.lead(analysisOn: true, watching: true, skip: nil, permitted: false)
        XCTAssertTrue(denied.contains("It takes no frame now: \(FocusWatcher.Skip.noScreenAccess.line)"), denied)
    }

    /// `read_screen` sends a frame whenever Screen Recording is allowed, whatever
    /// the timer does; with it not allowed no frame can be taken at all.
    func test_theChatScreenToolIsNamedWhenItCanSend() {
        let ask = "Asking Grux to look at your screen sends one frame each time."
        for watching in [true, false] {
            XCTAssertTrue(CapturePrivacyCopy.lead(analysisOn: watching, watching: watching, skip: nil, permitted: true).contains(ask))
            XCTAssertFalse(CapturePrivacyCopy.lead(analysisOn: watching, watching: watching, skip: nil, permitted: false).contains(ask))
        }
    }

    /// The caption reads saved and live state, never the pane's unsaved toggle.
    func test_theSectionReadsSavedAndLiveState() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        guard let at = settings.range(of: "Section(\"Privacy and capture\")") else {
            return XCTFail("the Privacy and capture section moved; point this test at it")
        }
        let around = String(settings[at.lowerBound...].prefix(500))
        XCTAssertTrue(around.contains("CapturePrivacyCopy.lead(analysisOn: state.config.screenAnalysisEnabled, watching: state.watching, skip: state.focusSkip, permitted: state.screenPermissionGranted)"), around)
    }

    // MARK: P2 3: a topic is not a message to someone

    func test_writingAboutATopicIsNotADraft() {
        for ask in ["Write a text about the history of Rome",
                    "Write a text about climate change for my English class",
                    "write a response about the causes of World War I",
                    "write a message that prints hello world in Python",
                    "write a response regarding the essay prompt"] {
            XCTAssertFalse(DraftAsk.matches(ask), ask)
            XCTAssertNil(DraftAsk.greeting(ask: ask), ask)
        }
        // A message kind that is always a message keeps the topic reading.
        for ask in ["Can you write a letter about the noise upstairs?", "write an email about the late rent",
                    "Grux, write a reply that says yes", "write a text letting her know I landed",
                    "Draft a message saying I'll be late"] {
            XCTAssertTrue(DraftAsk.matches(ask), ask)
        }
    }

    // MARK: P2 4: the name after a connector that takes a person

    func test_theNameAfterAPersonConnectorGreets() {
        XCTAssertEqual(DraftAsk.greeting(ask: "compose a message wishing Sam a happy birthday"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "Write a quick reply thanking Sam for the note"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "Write a text letting Mom know I landed"), "Hi Mom,")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email asking Sam Lee for the slides"), "Hi [Name],")
        // No name there, a possessive, or a day: the placeholder stays.
        XCTAssertEqual(DraftAsk.greeting(ask: "write a text letting her know I landed"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write a polite email thanking the host"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email reminding Sam's team about Friday"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email reminding Friday attendees to bring a laptop"), "Hi [Name],")
    }

    // MARK: P3 6: a second action keeps the tools

    func test_aSecondActionKeepsTheTools() {
        XCTAssertFalse(DraftAsk.matches("Write an email declining the meeting and cancel it"))
        XCTAssertFalse(DraftAsk.matches("write a reply accepting the offer, then archive the thread"))
    }

    // MARK: round 2 P2 1: "that says" is still what the message says

    func test_thatSaysIsStillADraft() {
        for ask in ["Write a message that says I'll be late", "Draft a text that says I'm on my way",
                    "write a reply that says no", "write me an email re the party"] {
            XCTAssertTrue(DraftAsk.matches(ask), ask)
        }
        for ask in ["write a message that prints hello world in Python", "write a text about the history of Rome",
                    "write a response regarding the essay prompt"] {
            XCTAssertFalse(DraftAsk.matches(ask), ask)
        }
    }

    // MARK: round 2 P2 2: only a name is a name

    func test_theGreetingTakesOnlyAName() {
        XCTAssertEqual(DraftAsk.greeting(ask: "Write an email telling Sam I'm running late"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email telling Sam I'll be late"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write a text asking Sam If he can come"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write a text wishing Mom Happy Birthday"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write a message wishing Happy Holidays to my team"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write a message wishing Merry Christmas to everyone"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email asking Dr. Patel for a refill"), "Hi Dr. Patel,")
    }

    // MARK: round 3: "that explains" is an essay, "re-" is a word, a title takes the last name

    func test_thatOnlySaysOrTellsSomeone() {
        for ask in ["Write a text that explains the causes of World War I",
                    "Write a text that tells a story about a dragon for kids",
                    "write a response that explains why the sky is blue",
                    "Write a message that reads the file and prints it",
                    "write a message that asks the user for their name in Python",
                    "write a message that lets users log in",
                    "write a message that confirms the order in my Swift app",
                    "Write a response re-evaluating the argument in my essay",
                    "write a text re-explaining the rules of chess"] {
            XCTAssertFalse(DraftAsk.matches(ask), ask)
        }
        XCTAssertTrue(DraftAsk.matches("Write a message that says I'll be late"))
    }

    func test_aTitleTakesTheLastName() {
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email thanking Dr. Sarah Chen for the visit"), "Hi Dr. Chen,")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email asking Dr. Patel for a refill"), "Hi Dr. Patel,")
    }

    // MARK: round 4: a title's third word, "me", and a capitalized thing

    func test_aTitleTakesAThirdWordOnlyWhenItIsTheName() {
        XCTAssertEqual(DraftAsk.greeting(ask: "Write a message wishing Mrs. Jones Merry Christmas"), "Hi Mrs. Jones,")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email wishing Mr. Smith Happy Birthday"), "Hi Mr. Smith,")
        XCTAssertEqual(DraftAsk.greeting(ask: "write a message thanking Dr. Patel Monday for the visit"), "Hi Dr. Patel,")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email inviting Prof. Lee Thursday"), "Hi Prof. Lee,")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email thanking Dr. Sarah Chen for the visit"), "Hi Dr. Chen,")
    }

    func test_thatTellsOnlyAPerson() {
        for ask in ["write a message that asks me for my name and prints it",
                    "write a message that lets me know when the build finishes",
                    "Write a text that tells me a joke", "write a message that asks us to rate the app",
                    "Write a message that tells Python to print hello", "write a message that tells Git to ignore files",
                    "write a message that lets Users sign in", "write a text that asks If"] {
            XCTAssertFalse(DraftAsk.matches(ask), ask)
        }
    }

    // MARK: round 5: "my" and "our" need a person after them

    func test_myOrOurNeedsAPerson() {
        for ask in ["Write a text that tells my story", "Write a text that tells my life story",
                    "write a text that tells our story", "write a text that tells our history",
                    "write a message that tells my experience", "write a message that lets our users sign in"] {
            XCTAssertFalse(DraftAsk.matches(ask), ask)
        }
    }

    // MARK: round 6, the class fix: after message, text or response only "that says"

    /// Six rounds found a new essay or program behind "that tells/asks/lets"
    /// plus a word list ("my family history", "our customers' stories",
    /// "tells Git"). After these three kinds only "that says" is what a
    /// message says; an email, a letter or a reply still drafts with any
    /// connector, so the asks a person means as messages keep a way in.
    func test_afterAKindThatIsAlsoWritingOnlyThatSaysCounts() {
        for ask in ["Write a text that tells my family story for school", "write a text that tells my family history",
                    "write a message that tells our family history", "write a text that tells our team history",
                    "write a text that tells my kids' story", "write a message that tells my friends' story",
                    "write a text that tells our customers' stories", "write a message that lets our customers sign in",
                    "write a message that tells my", "write a text that tells her story",
                    // Missed as drafts by design (the model answers as before).
                    "write a text that tells her I'm here", "write a message that asks Sam to call me",
                    "write a text that lets my boss know I'm sick", "write a text that lets Mom know I landed"] {
            XCTAssertFalse(DraftAsk.matches(ask), ask)
        }
        for ask in ["write an email letting my boss know I'm sick", "write a text letting Mom know I landed",
                    "write a reply telling Sam I'm in", "write an email that tells my boss I'm out",
                    "Write a message that says I'll be late", "write a text saying I'm here"] {
            XCTAssertTrue(DraftAsk.matches(ask), ask)
        }
    }

    // MARK: round 7: a text or a response is as often writing as a message

    func test_aTextOrResponseDraftsOnlyWhenItAddressesSomeone() {
        for ask in ["write a text explaining the causes of the war", "Write a text explaining photosynthesis",
                    "write a response explaining why you agree or disagree", "Write a short response explaining your answer",
                    "write a text telling the story of Rome", "write a response confirming the hypothesis",
                    "write a response saying why the author is wrong", "write a text announcing the theme of the essay",
                    "write a message requesting nothing in particular about Rome",
                    // Missed as drafts by design (the model answers as before).
                    "write a response that says no", "write me a message re the party",
                    "Write a text telling Sam I'm running late"] {
            XCTAssertFalse(DraftAsk.matches(ask), ask)
        }
        for ask in ["please draft a response apologizing for the delay", "write a response thanking the panel",
                    "write a text letting her know I landed", "Draft a message saying I'll be late",
                    "write a message wishing Sam a happy birthday", "write an email explaining why I'm late",
                    "write a letter requesting a refund", "write a reply confirming Friday"] {
            XCTAssertTrue(DraftAsk.matches(ask), ask)
        }
    }

    // MARK: round 8, the class fix: a name stands alone or the placeholder stays

    /// A capitalized pair after "wishing" or "thanking" is as often a wish or
    /// a company as a person ("Eid Mubarak", "John Deere"), and the tagger
    /// joins both. A wrong name in the first line is worse than "[Name]".
    func test_aNameStandsAloneOrThePlaceholderStays() {
        for ask in ["Write a message wishing Eid Mubarak to my colleagues", "write a message wishing Eid Mubarak",
                    "write an email wishing Eid Mubarak to the team", "write a text wishing Ramadan Mubarak",
                    "write a message wishing Shana Tova to everyone", "write a message wishing Feliz Navidad",
                    "write a message wishing Eid Mubarak, from all of us", "write an email thanking John Deere for the tractor",
                    "write a text asking Alexa to play music", "write a text asking Siri to set a timer",
                    "write a message congratulating Team USA"] {
            XCTAssertEqual(DraftAsk.greeting(ask: ask), "Hi [Name],", ask)
        }
        XCTAssertEqual(DraftAsk.greeting(ask: "compose a message wishing Sam a happy birthday"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "Write an email telling Sam I'm running late"), "Hi [Name],")
        XCTAssertEqual(DraftAsk.greeting(ask: "Write a text letting Mom know I landed"), "Hi Mom,")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email wishing Mr. Smith Happy Birthday"), "Hi Mr. Smith,")
    }

    // MARK: round 9, the class fix: after a connector only a family word or a title names

    /// Every rule for reading a name after "wishing" let a wish through
    /// ("Eid Mubarak", then "Mazel tov", "Aloha"). After a connector Grux
    /// names only what cannot be a wish or a thing: a family word or a title
    /// and a name. "to Sarah" still names Sarah. "[Name]" is never wrong.
    func test_afterAConnectorOnlyAFamilyWordOrATitleNames() {
        for ask in ["write a message wishing Mazel tov to the couple", "write a text wishing Buena suerte to Sam",
                    "write a message wishing Feliz navidad to my team", "write a message wishing Buon compleanno to my aunt",
                    "write a message wishing Kung hei fat choy", "write a message wishing Salaam to my team",
                    "write a text wishing Aloha to everyone", "write a message wishing Mubarak",
                    "write an email asking Marriott for a refund", "compose a message wishing Sam a happy birthday"] {
            XCTAssertEqual(DraftAsk.greeting(ask: ask), "Hi [Name],", ask)
        }
        XCTAssertEqual(DraftAsk.greeting(ask: "Write a text letting Mom know I landed"), "Hi Mom,")
        XCTAssertEqual(DraftAsk.greeting(ask: "write an email asking Dr. Patel for a refill"), "Hi Dr. Patel,")
        XCTAssertEqual(DraftAsk.greeting(ask: "Write a short email to Sarah saying I'm late"), "Hi Sarah,")
    }
}
