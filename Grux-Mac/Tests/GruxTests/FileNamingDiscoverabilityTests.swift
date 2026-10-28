import XCTest
@testable import Grux

/// FILES THAT NAME THEMSELVES SHIPS OFF, SO IT HAS TO BE FINDABLE.
///
/// The house rule in `Grux-Mac/CLAUDE.md` ("nothing ships OFF and
/// undiscoverable") wants three things, and `OffByDefaultDiscoverabilityTests`
/// checks only the first: that the classified phrase is in the onboarding copy.
/// Nothing there checks the Settings home or the search. These do, one
/// condition per test, each with a control that proves the scan can see a
/// string that IS there, because a scan of the wrong file passes everything.
final class FileNamingDiscoverabilityTests: XCTestCase {

    private func macRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: macRoot().appendingPathComponent(relative), encoding: .utf8)
    }

    /// CONDITION 1: named at first run, inside the screen every path walks.
    func test_firstRunNamesIt() throws {
        let steps = try source("Sources/Grux/Onboarding/OnboardingSteps.swift")
        let start = try XCTUnwrap(steps.range(of: "struct HowItWorksStep"),
                                  "control: HowItWorksStep moved, so this test is aimed at the wrong place")
        let screen = String(steps[start.upperBound...])
        XCTAssertTrue(screen.contains("point(\"Screen control is off too\""),
                      "control: the scan cannot see the screen control point it sits beside")
        XCTAssertTrue(screen.contains("point(\"Files can name themselves\""),
                      "How Grux works never names Files that name themselves")
        // The off state, in the same breath: off until Settings, on this Mac,
        // and what it will never do.
        let line = try XCTUnwrap(screen.components(separatedBy: "point(\"Files can name themselves\",")
            .dropFirst().first).prefix(700)
        for phrase in ["stays off until you turn it on in Settings", "this Mac", "never moves a file",
                       "never renames one you named yourself", "undone"] {
            XCTAssertTrue(line.contains(phrase), "the first-run line lost \"\(phrase)\"")
        }
    }

    /// CONDITION 2: a permanent home, and the toggle really writes the flag.
    func test_settingsHasAToggleThatWritesTheFlag() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains("state.config.screenControlEnabled = v"),
                      "control: this is not the SettingsView that holds the capability toggles")
        XCTAssertTrue(settings.contains("state.config.fileNamingEnabled = v"),
                      "Settings has no control that turns on Files that name themselves")
        XCTAssertFalse(settings.contains("state.config.fileNamingEnabledd = v"),
                       "control: a string that is not there must not be found")
    }

    /// The section carries the anchor every deep link and search result scrolls to.
    func test_theSectionIsAnchored() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains(".id(\"data.screenControl\")"),
                      "control: the scan cannot see a known-present anchor")
        XCTAssertTrue(settings.contains(".id(\"data.fileNaming\")"),
                      "nothing draws the data.fileNaming anchor, so search and the rename link scroll to nothing")
        XCTAssertTrue(settings.contains("Section(\"Files that name themselves\")"),
                      "the Settings section lost its title")
    }

    /// CONDITION 3: its off state explained, in the section itself.
    func test_theOffStateIsExplainedInTheSection() throws {
        let settings = try source("Sources/Grux/SettingsView.swift")
        let section = try XCTUnwrap(settings.components(separatedBy: "Section(\"Files that name themselves\")")
            .dropFirst().first).prefix(2500)
        for phrase in ["Off by default", "on this Mac", "never a cloud model", "never moves a file",
                       "never touches a name you typed", "undone"] {
            XCTAssertTrue(section.contains(phrase), "the Settings caption lost \"\(phrase)\"")
        }
    }

    /// Search finds it by the verb a person uses, and by every keyword the spec named.
    func test_searchingFindsIt() {
        XCTAssertTrue(SettingsSearchRegistry.matches("rename").contains { $0.id == "data.fileNaming" },
                      "searching Settings for rename does not find Files that name themselves")
        for query in ["file names", "screenshot", "downloads", "pdf", "name files", "undo rename"] {
            XCTAssertTrue(SettingsSearchRegistry.matches(query).contains { $0.id == "data.fileNaming" },
                          "searching \"\(query)\" does not find Files that name themselves")
        }
        // Control both ways: the search is live, and it is not matching everything.
        XCTAssertTrue(SettingsSearchRegistry.matches("screen control").contains { $0.id == "data.screenControl" },
                      "control: search cannot find a known entry, so its answers mean nothing")
        XCTAssertFalse(SettingsSearchRegistry.matches("bluetooth").contains { $0.id == "data.fileNaming" },
                       "control: an unrelated query finds this entry, so matches is returning true for everything")
    }

    /// The deep link lands on the same section the search does.
    func test_theRenameTagLandsOnTheSection() {
        let loc = SettingsTabAliases.resolve("rename")
        XCTAssertEqual(loc.pane, .dataSecurity)
        XCTAssertEqual(loc.sub, "capabilities")
        XCTAssertEqual(loc.anchor, "data.fileNaming")
        XCTAssertNil(SettingsTabAliases.resolve("not-a-real-section").anchor,
                     "control: an unknown tag carries an anchor, so resolve is not reading the table")
    }
}
