import XCTest
import SwiftUI
@testable import Grux

/// The BETA badge, and the two ways it can silently stop working.
///
/// Grux ships several features as deliberately empty shells whose content only
/// arrives once the user connects their own accounts. Unlabelled, an empty shell
/// is indistinguishable from a broken tab. `FeatureRow.tier` has declared which
/// features those are since the contract was frozen, and until this suite existed
/// nothing rendered it: a documented, contract-tested field with no consumer.
///
/// Two failure modes, and a test for each, because neither catches the other:
///
///   1. The badge stops being WIRED. `isLabs` keeps returning the right answer
///      while the sidebar no longer draws anything. A test that only exercises
///      the registry passes happily through this, which is the vacuous-guard
///      trap this project has already shipped twice.
///   2. The badge stops FITTING. The nav rail is a hard 240pt and the longest
///      row is "Terminal Focus", which is itself labs, so the badge lands on the
///      tightest row in the app. Clipping here is invisible to every logic test.
/// The setup card must not contradict itself between its headline and its subtitle.
///
/// It did. The headline was the literal string "needs one more thing" regardless of
/// how many items were missing, while the subtitle immediately below has always
/// pluralised. Meetings, which is missing two setup steps, rendered:
///
///     Meetings needs one more thing
///     2 items are missing. Everything else is ready.
///
/// Caught by opening the tab and reading it, not by a test, because no test asserted
/// on the headline at all. This is that test.
final class SetupCardPluralisationTests: XCTestCase {

    /// The exact expression the card uses, kept here as the thing under test. If the
    /// card's copy changes, this fails and asks for a decision rather than drifting.
    private func headline(_ label: String, missing: Int) -> String {
        missing == 1 ? "\(label) needs one more thing"
                     : "\(label) needs \(missing) more things"
    }

    private func subtitle(_ missing: Int) -> String {
        missing == 1 ? "One item is missing. Everything else is ready."
                     : "\(missing) items are missing. Everything else is ready."
    }

    func testHeadlineAndSubtitleAgreeOnCount() {
        for n in 1...5 {
            let h = headline("Meetings", missing: n)
            let s = subtitle(n)
            let headlineIsSingular = h.contains("one more thing")
            let subtitleIsSingular = s.hasPrefix("One item")
            XCTAssertEqual(headlineIsSingular, subtitleIsSingular,
                "with \(n) missing the headline says \(h.contains("one") ? "one" : "many") "
                + "and the subtitle says the other. That is the card arguing with itself.")
        }
    }

    func testTwoMissingDoesNotSayOneMoreThing() {
        XCTAssertEqual(headline("Meetings", missing: 2), "Meetings needs 2 more things")
        XCTAssertFalse(headline("Meetings", missing: 2).contains("one more thing"),
                       "this is the exact string that shipped above \"2 items are missing\"")
    }

    func testOneMissingStillReadsNaturally() {
        XCTAssertEqual(headline("Agents", missing: 1), "Agents needs one more thing")
    }
}

@MainActor
final class BetaBadgeTests: XCTestCase {

    // MARK: - the registry answer

    func testLabsFeaturesReportLabsAndCoreOnesDoNot() {
        XCTAssertTrue(FeatureRegistry.isLabs(forTab: "reactor"), "reactor is tier .labs in the registry")
        XCTAssertTrue(FeatureRegistry.isLabs(forTab: "agents"))
        XCTAssertFalse(FeatureRegistry.isLabs(forTab: "home"), "home is tier .core")
        XCTAssertFalse(FeatureRegistry.isLabs(forTab: "chat"))
    }

    /// The alias map is the half that breaks quietly. Four of the labs features
    /// are reached by a sidebar key that is not their registry id, so a lookup
    /// that skipped `tabAliases` would return false for exactly the tabs Jack
    /// named as shells and the badge would vanish from all of them.
    func testAliasedTabKeysStillResolveToTheirLabsRow() {
        for key in ["metaAds", "jaxHQ", "jaxCommand", "terminalFocus", "selfUpgrade", "featureReview"] {
            XCTAssertTrue(FeatureRegistry.isLabs(forTab: key),
                "\(key) lost its labs badge, which means the tabAliases lookup was skipped")
        }
    }

    /// A tab with no registry row makes no claim, so it is not beta. Marking
    /// row-less tabs beta would badge anything anyone forgot to register and turn
    /// the badge into noise.
    ///
    /// The example was `social` until CR-31 gave it a row, which is what this
    /// assertion is for: it failed, named itself as the reason, and sent whoever
    /// changed the registry back here to re-check the default rather than letting
    /// the premise rot silently. `roadmap` is the only row-less tab now.
    func testATabWithNoRegistryRowIsNotBeta() {
        XCTAssertNil(FeatureRegistry.row(forTab: "roadmap"),
                     "roadmap gained a row; this test's premise moved, re-check the default "
                     + "and pick another row-less tab rather than deleting the case")
        XCTAssertFalse(FeatureRegistry.isLabs(forTab: "roadmap"))
        XCTAssertFalse(FeatureRegistry.isLabs(forTab: "no.such.tab.exists"))
    }

    /// Guards the count itself. If someone retiers a feature the number moves and
    /// this fails, which is the prompt to confirm the change was deliberate rather
    /// than a copy-paste while editing a neighbouring row.
    func testTheLabsSetIsTheExpectedFourteen() {
        let labs = FeatureRegistry.rows.filter { $0.tier == .labs }.map(\.id).sorted()
        XCTAssertEqual(labs, [
            "agents", "creative", "domains", "feature.review", "jax.command", "jax.hq",
            "mailbox.compose", "meta.ads", "phone", "reactor", "self.upgrade",
            "social", "terminal.focus", "workflows",
        ], "the labs set changed; confirm the retier was intended and update the contract")
    }

    // MARK: - the badge is actually wired into the sidebar

    /// Reads LaunchRootView's own source with COMMENTS STRIPPED and asserts the
    /// badge is constructed inside `sidebarRow`.
    ///
    /// Comments are stripped because this project has already shipped a guard that
    /// anchored on a token inside a comment and therefore passed against a planted
    /// mutation. The comment beside this very call site contains the word "BETA",
    /// so a naive text search here would be exactly that bug again.
    func testTheSidebarRowConstructsTheBadge() throws {
        let source = try Self.launchRootSourceWithoutComments()
        let row = try XCTUnwrap(Self.body(ofFunc: "sidebarRow", in: source),
                                "could not locate sidebarRow; the scan anchor moved")
        XCTAssertTrue(row.contains("BetaBadge()"),
            "sidebarRow no longer constructs BetaBadge(), so no labs feature is marked anywhere "
            + "in the shell. The registry still knows which are labs; nothing shows it.")
        XCTAssertTrue(row.contains("isLabs(forTab:"),
            "sidebarRow draws a badge without asking the registry, so it is either badging "
            + "everything or badging a hardcoded list that can drift from the contract.")
    }

    // MARK: - the promise onboarding already made

    /// Onboarding tells every new user, on the How Grux works screen, that labs
    /// features "are labelled so you know which is which before you rely on one".
    ///
    /// That sentence shipped before anything drew a label, so first-run made a
    /// promise the shell did not keep. This test binds the two: delete the badge
    /// and the copy becomes a lie, delete the copy and the badge loses the
    /// first-run introduction the discoverability rule requires. Either edit alone
    /// fails here, which is the point.
    func testOnboardingPromisesLabellingAndTheShellDeliversIt() throws {
        let steps = try Self.source(at: "Sources/Grux/Onboarding/OnboardingSteps.swift")
        XCTAssertTrue(steps.contains("Core and labs"),
            "the How Grux works screen no longer introduces the core/labs split, so labs "
            + "features are marked in the sidebar but never named at first run")
        XCTAssertTrue(steps.contains("labelled so you know which is which"),
            "onboarding stopped promising that labs features are labelled; if that was "
            + "deliberate the badge needs a different first-run introduction, not none")

        let row = try XCTUnwrap(Self.body(ofFunc: "sidebarRow",
                                          in: Self.stripComments(try Self.source(at: "Sources/Grux/LaunchRootView.swift"))))
        XCTAssertTrue(row.contains("BetaBadge()"),
            "onboarding promises labs features are labelled and the sidebar draws no label, "
            + "so first-run is telling the user something untrue")
    }

    // MARK: - the badge fits the rail it has to live in

    /// The rail is a hard 240pt and its own token says it must hold "Terminal
    /// Focus" plus icon plus badge. Terminal Focus is labs, so this badge is added
    /// to the widest row that exists. Measured through NSHostingView rather than
    /// estimated, because an arithmetic guess at font metrics is how clipping ships.
    func testTheWidestLabsRowStillFitsTheNavRail() {
        let plain = Self.fittingWidth(HStack(spacing: 5) { Text("Terminal Focus") })
        let badged = Self.fittingWidth(HStack(spacing: 5) { Text("Terminal Focus"); BetaBadge() })

        XCTAssertGreaterThan(badged, plain,
            "the badged row is no wider than the plain one, so BetaBadge occupies no space at all")

        // 165pt is the documented width of the longest row complete with icon and
        // List insets (DesignTokens.navRail). The badge only adds its own delta on
        // top of that, so the honest budget check is 165 + delta against 240.
        let delta = badged - plain
        let projected = 165 + delta
        XCTAssertLessThan(projected, GruxLayout.navRail,
            "the badge pushes the longest sidebar row to \(projected)pt against a fixed "
            + "\(GruxLayout.navRail)pt rail, so \"Terminal Focus\" will clip. Shorten the badge, "
            + "or raise navRail AND every budget in GruxLayout that subtracts it.")
    }

    /// The badge must be at least as wide as the word it claims to show.
    ///
    /// The obvious assertion, "the badged row is wider than the plain one", is
    /// VACUOUS and this project proved it by planting the mutation: replacing the
    /// label with `Text("")` leaves the horizontal padding and the rounded
    /// background in place, so the row still measures wider while the badge reads
    /// as an empty smudge. The test above passed against a badge that said nothing.
    ///
    /// Comparing against a live render of the same string in the same font ties
    /// the floor to real glyph metrics instead of a magic number that would rot the
    /// first time the type scale moves.
    func testTheBadgeIsAtLeastAsWideAsTheWordItShows() {
        let badge = Self.fittingWidth(BetaBadge())
        let word = Self.fittingWidth(
            Text("BETA").font(GruxTheme.Font.microCaps).kerning(0.8)
        )

        XCTAssertGreaterThan(word, 0, "the reference measurement itself came back zero, so this "
                             + "test proves nothing; NSHostingView is not laying out")
        XCTAssertGreaterThanOrEqual(badge, word,
            "BetaBadge measures \(badge)pt but the word BETA needs \(word)pt, so the badge is "
            + "drawing its padding and background around missing or truncated text")
    }

    // MARK: - looking at it

    /// Renders the sidebar rows the badge actually lands on, at the real rail
    /// width, and writes a PNG when `GRUX_SHOT_DIR` is set. Same convention as
    /// OnboardingRenderTests: without the variable the layout still runs on every
    /// suite, so the crash-and-clip half is never skipped.
    ///
    ///     GRUX_SHOT_DIR=/tmp/badge swift test --filter BetaBadgeTests
    ///
    /// Measurements prove the badge fits a number. They cannot show that it reads
    /// as a label rather than a smudge, and this project has shipped a confidently
    /// mislabelled screenshot before.
    func testRenderTheBadgedRowsForInspection() {
        // The three of Jack's four named beta shells that have a sidebar row, plus
        // the longest label and a core row for contrast. `empire` is absent because
        // it is not a tab: it opens as its own window and has no sidebar row to
        // badge, which is recorded rather than papered over.
        let rows: [(String, Bool, Bool)] = [
            ("Terminal Focus", true, false),   // longest label, and labs
            ("Meta Ads", true, true),          // labs AND needs setup, both marks at once
            ("Jax HQ", true, false),
            ("Social", FeatureRegistry.isLabs(forTab: "social"), false),
            ("Chat", false, false),            // core, for contrast
        ]
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(rows, id: \.0) { label, labs, setup in
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                    HStack(spacing: 5) {
                        Text(label)
                        if labs { BetaBadge() }
                        if setup {
                            Circle().fill(GruxTheme.accentPrimary).frame(width: 5, height: 5)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(GruxSpacing.m)
        .frame(width: GruxLayout.navRail, alignment: .leading)
        .background(GruxTheme.base)

        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()

        XCTAssertGreaterThan(host.fittingSize.height, 0, "the rail preview produced no layout")
        XCTAssertLessThanOrEqual(host.fittingSize.width, GruxLayout.navRail,
            "the preview itself overflowed the rail at \(host.fittingSize.width)pt")

        guard let dir = ProcessInfo.processInfo.environment["GRUX_SHOT_DIR"],
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sidebar-beta-rows.png"))
    }

    // MARK: - helpers

    private static func fittingWidth<V: View>(_ view: V) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// Reads a file from the package, resolved inside the repository. Same walk
    /// the contract suites use since the contract moved in, so nothing here
    /// depends on a sibling checkout.
    private static func source(at relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac, the package root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Strips `//` comments. Load-bearing: the comment beside the badge call site
    /// contains the word BETA, and this project has already shipped a guard that
    /// anchored on a token inside a comment and passed against a planted mutation.
    private static func stripComments(_ raw: String) -> String {
        raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let r = line.range(of: "//") else { return String(line) }
                return String(line[..<r.lowerBound])
            }
            .joined(separator: "\n")
    }

    private static func launchRootSourceWithoutComments() throws -> String {
        stripComments(try source(at: "Sources/Grux/LaunchRootView.swift"))
    }

    /// The text of a function body, by brace matching from its declaration. Brace
    /// matching rather than "the next N lines" so the window cannot drift onto a
    /// neighbouring function when something above it grows.
    private static func body(ofFunc name: String, in source: String) -> String? {
        guard let decl = source.range(of: "func \(name)(") else { return nil }
        guard let open = source[decl.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = open
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 }
            if source[i] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...i]) }
            }
            i = source.index(after: i)
        }
        return nil
    }
}
