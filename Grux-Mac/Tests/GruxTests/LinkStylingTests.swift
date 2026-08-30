import XCTest
@testable import Grux

/// Every `Link` in the app has to say what colour it is.
///
/// SwiftUI paints `Link` with `NSColor.linkColor`, the system blue, and it does
/// NOT follow `.tint`. Grux is violet on near black, so an unstyled `Link` is
/// the only blue on the screen. Two shipped that way, and both were the "go and
/// fetch an API key" links, which is the worst place for the app to suddenly
/// look like something else: the onboarding model key step and the Brave key row
/// in Settings.
///
/// Nothing could have caught it before a render. It is not a crash, not a layout
/// break, and the source reads fine. The three onboarding steps were `private`
/// besides, so the render harness could not even reach the screen it was on.
final class LinkStylingTests: XCTestCase {

    /// `Link(` with a word boundary in front, so `CardLink(` and
    /// `SpeakerContactLink(` are not counted. Both are ordinary types in this
    /// codebase whose names end in Link, and a naive substring search reports
    /// nine offenders where there are two.
    private static func unstyledLinks(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        var hits: [Int] = []
        for (i, raw) in lines.enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // COMMENTS ARE EXCLUDED BY PREFIX, NEVER BY CONTAINS.
            // A filter that drops any line containing "//" also drops every line
            // holding a URL, which is every line that declares a Link. That
            // exact filter reported this codebase clean while both offenders sat
            // in it.
            if trimmed.hasPrefix("//") { continue }

            guard let r = raw.range(of: "Link(") else { continue }
            if r.lowerBound > raw.startIndex {
                let before = raw[raw.index(before: r.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }

            // The modifiers land on the following lines, so look ahead a little.
            let window = lines[i..<min(i + 8, lines.count)].joined(separator: "\n")
            if !window.contains("foregroundStyle") && !window.contains("gruxLink") {
                hits.append(i + 1)
            }
        }
        return hits
    }

    /// CONTROLS FIRST, both directions, because the detector above is the part
    /// that has actually been wrong. Three separate versions of this scan gave a
    /// confidently wrong answer before this test existed: one counted
    /// `CardLink`, one counted `SpeakerContactLink`, and one silently excluded
    /// every real hit because URLs contain a double slash.
    func testTheDetectorItselfWorks() {
        let offender = """
        VStack {
            Link("Get a key", destination: URL(string: "https://example.com/x")!)
                .font(.caption)
        }
        """
        XCTAssertEqual(Self.unstyledLinks(in: offender), [2],
                       "control: a genuinely unstyled Link must be found, URL slashes and all")

        let styled = """
        VStack {
            Link("Get a key", destination: URL(string: "https://example.com/x")!)
                .font(.caption)
                .gruxLink()
        }
        """
        XCTAssertTrue(Self.unstyledLinks(in: styled).isEmpty,
                      "control: a styled Link must not be reported")

        let notALink = """
        VStack {
            CardLink(label: "Open calendar") { state.requestedTab = "calendar" }
            SpeakerContactLink(speakerProfileId: a, contactIdentifier: b)
        }
        """
        XCTAssertTrue(Self.unstyledLinks(in: notALink).isEmpty,
                      "control: types whose names merely END in Link are not SwiftUI Links")

        let comment = """
        VStack {
            // Link("Get a key", destination: someURL)
            Text("hi")
        }
        """
        XCTAssertTrue(Self.unstyledLinks(in: comment).isEmpty,
                      "control: a commented out Link is not a shipping Link")
    }

    /// Every real SwiftUI `Link(` use, styled or not. Same word-boundary and
    /// comment rules as `unstyledLinks`, minus the styling question.
    private static func allLinks(in source: String) -> [Int] {
        let lines = source.components(separatedBy: "\n")
        var hits: [Int] = []
        for (i, raw) in lines.enumerated() {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            guard let r = raw.range(of: "Link(") else { continue }
            if r.lowerBound > raw.startIndex {
                let before = raw[raw.index(before: r.lowerBound)]
                if before.isLetter || before.isNumber || before == "_" { continue }
            }
            hits.append(i + 1)
        }
        return hits
    }

    private static func sourcesRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    /// THE COMMENT IS CHECKED, NOT TRUSTED.
    ///
    /// `GruxLink`'s doc comment claimed "9 of the 10 `Link` uses in `Sources/`
    /// set no foreground style at all, six of them in `HomeView`". Every number
    /// in that sentence is wrong. `Sources/` has three real SwiftUI `Link` uses;
    /// `HomeView`'s six are `CardLink`, a different local type, which the
    /// detector at the top of this file deliberately excludes and which this
    /// file's own header counts correctly as "Two shipped that way".
    ///
    /// A wrong measurement in a doc comment is not cosmetic. It is the
    /// justification for the change sitting immediately below it, and the next
    /// reader reconciling the two goes looking for seven links that do not
    /// exist and concludes the test under-covers. Tying the sentence to the
    /// same detector the sweep uses is what stops it drifting again.
    func testTheGruxLinkDocCommentMatchesWhatIsActuallyInTheTree() throws {
        let root = Self.sourcesRoot()
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("cannot walk \(root.path)")
        }

        var total = 0
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            // The modifier's own declaration is `func gruxLink()`, not a Link.
            total += Self.allLinks(in: try String(contentsOf: url, encoding: .utf8)).count
        }

        XCTAssertGreaterThan(scanned, 100, "the walk found almost no Swift files, so it proved nothing")
        XCTAssertGreaterThan(total, 0, "control: no Links at all means the count below is meaningless")

        let doc = try String(contentsOf: root.appendingPathComponent("Grux/DesignSystem/GruxLink.swift"),
                             encoding: .utf8)

        XCTAssertTrue(doc.contains("\(total) real `Link` uses"),
                      "GruxLink's doc comment does not state the measured count. The tree has "
                      + "\(total) real Link uses right now and the comment has to say so.")
        XCTAssertFalse(doc.contains("9 of the 10"),
                       "the original wrong measurement is still in the comment")
        XCTAssertFalse(doc.contains("six of them in `HomeView`"),
                       "HomeView's six are CardLink, a different type this file's detector excludes")
    }

    /// And the claim the comment makes about how many shipped unstyled has to
    /// match this file's header, which says two. Both sentences describe one
    /// measurement, so they are checked against each other rather than each
    /// against somebody's memory.
    func testTheTwoUnstyledLinksAreNamedConsistently() throws {
        let root = Self.sourcesRoot()
        let doc = try String(contentsOf: root.appendingPathComponent("Grux/DesignSystem/GruxLink.swift"),
                             encoding: .utf8)

        XCTAssertTrue(doc.contains("Two of them"),
                      "the comment must state how many actually shipped in the system blue")
        // Both offenders are named in this file's header. They must be named in
        // the comment too, since "two" without which two is not a measurement.
        XCTAssertTrue(doc.contains("onboarding"), "the onboarding model key link is one of the two")
        XCTAssertTrue(doc.contains("Brave"), "the Brave key row in Settings is the other")
    }

    /// The sweep, over the real tree.
    func testNoLinkShipsWithTheSystemBlue() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")

        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("cannot walk \(root.path)")
        }

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            let src = try String(contentsOf: url, encoding: .utf8)
            for line in Self.unstyledLinks(in: src) {
                offenders.append("\(url.lastPathComponent):\(line)")
            }
        }

        // A sweep that walked nothing would pass silently, which is the whole
        // family of bug this file exists to stop.
        XCTAssertGreaterThan(scanned, 100, "the walk found almost no Swift files, so it proved nothing")
        XCTAssertEqual(offenders, [],
                       "these Links render in the system blue: \(offenders.joined(separator: ", "))")
    }
}
