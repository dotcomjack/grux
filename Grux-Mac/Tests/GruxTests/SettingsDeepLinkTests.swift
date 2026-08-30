import XCTest
@testable import Grux

/// Guards the two ways a Settings section is reached: the search field and the
/// `--open-settings-tab=<tag>` deep link.
///
/// Both fail the same silent way. `resolve` never throws and never returns nil:
/// an unknown tag falls back to the top of General, which looks exactly like a
/// working deep link that happens to land somewhere unhelpful. The first-run
/// row shipped in precisely that state, with a search entry and a scroll anchor
/// but no alias tag, so the tag that should have jumped to it quietly did
/// nothing and the row stayed below the fold.
final class SettingsDeepLinkTests: XCTestCase {

    // MARK: - The first-run door

    /// The only route back into onboarding. If this regresses, a user who
    /// clicked through the flow once can never see it again.
    func testFirstRunIsReachableByDeepLink() {
        for tag in ["first-run", "onboarding"] {
            let loc = SettingsTabAliases.resolve(tag)
            XCTAssertEqual(loc.pane, .general, "\(tag) resolved to the wrong pane")
            XCTAssertEqual(loc.anchor, "general.firstRun",
                           "\(tag) did not carry the scroll anchor, so it lands at the top of General")
        }
    }

    /// Tags are typed by a person, so casing and stray whitespace must not
    /// decide whether the deep link works.
    func testTagResolutionIsForgivingAboutCaseAndWhitespace() {
        XCTAssertEqual(SettingsTabAliases.resolve("  First-Run  ").anchor, "general.firstRun")
    }

    /// The fallback that makes every other failure here silent. Pinned so the
    /// behavior is deliberate rather than incidental.
    func testAnUnknownTagFallsBackToGeneralWithNoAnchor() {
        let loc = SettingsTabAliases.resolve("not-a-real-section")
        XCTAssertEqual(loc.pane, .general)
        XCTAssertNil(loc.anchor)
    }

    // MARK: - Registry consistency

    /// A search entry whose `id` and `anchor` disagree scrolls to nothing,
    /// because `id` doubles as the scroll target. This catches a copy-paste
    /// slip that no amount of clicking around would reveal quickly.
    func testEveryAnchoredSearchEntryPointsAtItsOwnId() {
        for entry in SettingsSearchRegistry.entries {
            guard let anchor = entry.location.anchor else { continue }
            XCTAssertEqual(anchor, entry.id,
                           "\(entry.title) anchors to \(anchor) but its id is \(entry.id)")
        }
    }

    /// Where an alias tag and a search entry describe the same section, they
    /// must agree. Two routes to one row that land in different places is worse
    /// than one route.
    func testAliasAndSearchAgreeWhereTheyOverlap() {
        let byAnchor = Dictionary(
            uniqueKeysWithValues: SettingsSearchRegistry.entries
                .compactMap { e in e.location.anchor.map { ($0, e.location) } })
        for (tag, loc) in SettingsTabAliases.map {
            guard let anchor = loc.anchor, let entry = byAnchor[anchor] else { continue }
            XCTAssertEqual(loc.pane, entry.pane,
                           "tag \(tag) and the search entry for \(anchor) disagree on the pane")
        }
    }

    // MARK: - Discoverability

    /// The words a person actually types. None of them appear in the section
    /// title, so the keyword list is carrying the whole discovery burden and a
    /// trimmed list would silently make the row unfindable.
    func testTheWordsSomeoneWouldActuallySearchFindTheFirstRunRow() {
        guard let entry = SettingsSearchRegistry.entries.first(where: { $0.id == "general.firstRun" }) else {
            return XCTFail("the first-run search entry is gone")
        }
        for query in ["onboarding", "welcome", "wizard", "tour", "start over",
                      "setup", "first run", "new user", "getting started"] {
            XCTAssertTrue(entry.matches(query), "searching \"\(query)\" does not find First-run setup")
        }
    }

    /// Guards the search itself, not just this entry: a query nobody registered
    /// must find nothing, or `matches` is returning true for everything and the
    /// test above proves nothing.
    func testAnUnrelatedQueryDoesNotMatchTheFirstRunRow() {
        guard let entry = SettingsSearchRegistry.entries.first(where: { $0.id == "general.firstRun" }) else {
            return XCTFail("the first-run search entry is gone")
        }
        XCTAssertFalse(entry.matches("bluetooth"))
        XCTAssertFalse(entry.matches("zzzz"))
    }
}
