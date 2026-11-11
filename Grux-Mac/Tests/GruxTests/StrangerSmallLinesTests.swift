import XCTest
@testable import Grux

/// D115 items 5, 7, 8 and 11, and D88 (sense passes 7 and 10): small lines a
/// stranger reads in their first minutes that did not say what is true.
final class StrangerSmallLinesTests: XCTestCase {

    // MARK: item 8, the setup card's second line

    /// "Focus log needs 4 more things" sat above "Nothing else is needed.",
    /// which reads as if the four were not needed either.
    func test_aCardWithNothingReadyYetSaysTheListedItemsAreAllItNeeds() {
        let four = CapabilitySetupCard.copy(featureLabel: "Focus log",
                                            blocking: [.permScreenRecording, .permAccessibility, .stepFirstFrameReviewed, .stepAgentCliInstalled],
                                            listedEntries: 4,
                                            missing: [.permScreenRecording, .permAccessibility, .stepFirstFrameReviewed, .stepAgentCliInstalled],
                                            signInExpired: false)
        XCTAssertEqual(four.headline, "Focus log needs 4 more things")
        XCTAssertEqual(four.subtitle, "Once these are done, it is ready.")

        let one = CapabilitySetupCard.copy(featureLabel: "Mailbox", blocking: [.endpointImap], listedEntries: 1,
                                           missing: [.endpointImap], signInExpired: false)
        XCTAssertEqual(one.headline, "Mailbox needs one more thing")
        XCTAssertEqual(one.subtitle, "Once this is done, it is ready.")

        for ready in 0...3 {
            for listed in 1...4 {
                let s = CapabilitySetupCard.subtitle(readyBesides: ready, listed: listed)
                XCTAssertFalse(s.lowercased().contains("nothing else"), "\(s) under a card that lists \(listed)")
                XCTAssertNil(s.rangeOfCharacter(from: .decimalDigits), "the subtitle repeats a count: \(s)")
            }
        }
    }

    // MARK: item 5, the Reactor's readouts

    /// The Mailbox and Meta Ads cards showed "··" as their number above "Not
    /// set up", and the ring read "MAIL ··". A word says it.
    func test_aReactorReadoutIsAWordOrANumberNeverDots() {
        let readouts: [String] = [
            ReactorView.mailboxReadout(hasAccount: false, unread: 0, newest: "").value,
            ReactorView.mailRingReadout(hasAccount: false, unread: 0),
            ReactorView.metaAdsReadout(spendCents: nil, mode: nil, attention: 0, notSetUp: true).value,
            ReactorView.metaAdsReadout(spendCents: nil, mode: nil, attention: 0, notSetUp: false).value,
            ReactorView.calendarDeniedReadout.value,
            ReactorView.taskRingReadout(done: 0, total: 0),
            ReactorView.taskRingReadout(done: 2, total: 5),
        ]
        for r in readouts {
            XCTAssertNotNil(r.rangeOfCharacter(from: .alphanumerics), "a readout with no word or number: \(r)")
        }
        XCTAssertEqual(ReactorView.mailboxReadout(hasAccount: false, unread: 0, newest: "").value, "Off")
        XCTAssertEqual(ReactorView.metaAdsReadout(spendCents: nil, mode: nil, attention: 0, notSetUp: false).value, "Offline")
    }

    /// "TASKS 2/5" said nothing about what the 2 was.
    func test_theTaskRingSaysWhatItCounts() {
        XCTAssertEqual(ReactorView.taskRingReadout(done: 2, total: 5), "2 of 5 done")
        XCTAssertEqual(ReactorView.taskRingReadout(done: 0, total: 0), "none")
    }

    func test_theReactorDrawsNoDotPlaceholder() throws {
        let src = try Self.source("Sources/Grux/Reactor/ReactorView.swift")
        XCTAssertFalse(src.contains("\"··\""), "a dot placeholder is back in the Reactor")
        XCTAssertTrue(src.contains("readout: Self.taskRingReadout(done: done, total: taskTotal)"),
                      "the task ring builds its own readout")
    }

    // MARK: item 7, Speakers before Meetings is set up

    /// D208 item 7 (sense pass 30, `speakers-1.png`): the line counted what
    /// Meetings still needs but named none of it and had no way there. It
    /// names each missing item, by the label the Meetings card lists it under.
    func test_speakersSaysMeetingsNeedsSetUpFirst() {
        XCTAssertEqual(SpeakersView.emptyLine(meetingsMissing: [.permMicrophone, .permSystemAudio, .stepSpeechModelDownloaded]),
                       "Meetings needs 3 more things before it can record: Microphone, System audio capture and Fetch the speech model. Set them up, then record a meeting and click a speaker chip in its transcript to give that voice a name.")
        XCTAssertEqual(SpeakersView.emptyLine(meetingsMissing: [.permSystemAudio, .stepSpeechModelDownloaded]),
                       "Meetings needs 2 more things before it can record: System audio capture and Fetch the speech model. Set them up, then record a meeting and click a speaker chip in its transcript to give that voice a name.")
        XCTAssertEqual(SpeakersView.emptyLine(meetingsMissing: [.permMicrophone]),
                       "Meetings needs one more thing before it can record: Microphone. Set it up, then record a meeting and click a speaker chip in its transcript to give that voice a name.")
        XCTAssertEqual(SpeakersView.emptyLine(meetingsMissing: []),
                       "Record a meeting, then click a speaker chip in its transcript to give that voice a name.")
    }

    /// The count in the line is the count the Meetings card's headline reads,
    /// for every subset of what Meetings needs, so the two never disagree.
    @MainActor
    func test_speakersCountsWhatTheMeetingsCardCounts() throws {
        let row = try XCTUnwrap(FeatureRegistry.row(forTab: "meetings"))
        let all = row.requires + row.steps
        for mask in 1..<(1 << all.count) {
            let missing = all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let entries = CapabilitySetupLayout.entries(missing: missing, groups: row.anyOf)
            let card = CapabilitySetupCard.copy(featureLabel: "Meetings", blocking: all, listedEntries: entries.count,
                                                missing: missing, signInExpired: false)
            let line = SpeakersView.emptyLine(meetingsMissing: missing)
            let head = card.headline + " before it can record: "
            XCTAssertTrue(line.hasPrefix(head), "\(line) does not start with the card's \(card.headline)")
            for item in missing { XCTAssertTrue(line.contains(item.label), "\(line) leaves out \(item.label)") }
        }
    }

    /// A button goes to the Meetings card that lists each item with its own
    /// button, only while something is missing.
    func test_speakersHasAWayToMeetingsSetup() throws {
        let src = try Self.source("Sources/Grux/Meeting/SpeakersView.swift")
        XCTAssertTrue(src.contains("Self.emptyLine(meetingsMissing: meetingsMissing)"))
        XCTAssertTrue(src.contains("let meetingsMissing = FeatureRegistry.missing(forTab: \"meetings\")"))
        XCTAssertTrue(src.contains("if !meetingsMissing.isEmpty"), "the button shows only while Meetings needs something")
        XCTAssertTrue(src.contains("Button(Self.setUpMeetingsButton) { AppState.shared.requestedTab = \"meetings\" }"))
        XCTAssertEqual(SpeakersView.setUpMeetingsButton, "Set up Meetings")
    }

    // MARK: D88, Social's subtitle

    func test_socialsSubtitleSaysWhatTheTabIsToday() {
        XCTAssertEqual(SocialView.subtitle(hasDashboard: false), "No dashboard set yet")
        XCTAssertEqual(SocialView.subtitle(hasDashboard: true), "Your posting dashboard, embedded")
    }

    // MARK: item 11, a heading that repeats the pane bar

    /// Integrations, Local Models and Social printed their name a second time
    /// in title type under the pane bar that already says it (the class audit
    /// item 7 fixed for Notes, Documents, Labs and Tuning). Every title-sized
    /// literal heading that is a pane's name asks `PaneHeading` first.
    /// D208 item 9: Folders wrote its `.font` on the heading's own line, which
    /// the scan skipped, so "Folders" printed under a "Folders" bar; the scan
    /// takes the font on the same line or the next.
    func test_everyTitleHeadingThatIsAPaneNameAsksBeforeDrawing() throws {
        var keys = SidebarIA.allItems.map(\.key) + SidebarIA.railOrder.map(\.key) + SidebarIA.brandScopedOrder.map(\.key)
        keys += ["settings", "labs", "tuning", "cookbook"]
        let names = Set(keys.flatMap { PaneHeading.names(forKey: $0) }.map { $0.lowercased() })
        XCTAssertTrue(names.contains("integrations"))
        XCTAssertTrue(names.contains("local models"), "the scan no longer knows the Local Models pane's name")

        let dir = Self.root.appendingPathComponent("Sources/Grux")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let heading = try NSRegularExpression(
            pattern: #"Text\("([^"\\]+)"\)\s*\.font\((GruxType\.(title|largeTitle|display)|\.title|\.largeTitle)\b"#)
        var offenders: [String] = []
        var scanned = 0
        for url in files {
            let src = try String(contentsOf: url, encoding: .utf8)
            let ns = src as NSString
            for m in heading.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
                let literal = ns.substring(with: m.range(at: 1))
                guard names.contains(literal.lowercased()) else { continue }
                scanned += 1
                let tail = ns.substring(from: m.range.location + m.range.length).prefix(400)
                let asks = tail.contains("\n") && tail.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(6).contains { $0.contains(".unlessPaneTitle(\"\(literal)\")") }
                if !asks && !src.contains("PaneHeading.repeats(\"\(literal)\"") {
                    offenders.append("\(url.lastPathComponent): \(literal)")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 3, "the scan found too few headings; it is reading the wrong thing")
        XCTAssertEqual(offenders, [], "a heading repeats the pane bar's title")
    }

    func test_unlessPaneTitleHidesOnlyARepeat() {
        XCTAssertTrue(PaneHeading.repeats("Local Models", paneTitles: PaneHeading.names(forKey: "cookbook")))
        XCTAssertTrue(PaneHeading.repeats("Focus Log", paneTitles: PaneHeading.names(forKey: "focus")))
        XCTAssertFalse(PaneHeading.repeats("Speakers", paneTitles: PaneHeading.names(forKey: "meetings")),
                       "Speakers inside Meetings is a section, not a repeat")
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func source(_ rel: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
    }
}
