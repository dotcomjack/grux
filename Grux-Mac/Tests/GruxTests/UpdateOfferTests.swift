import XCTest
@testable import Grux

// U5 to U7 of the update check (spec docs/superpowers/specs/2026-10-17-update-check-scope.md):
// the Now row with Download and Not now (the brew command on a Homebrew install), the
// switch and Check now in Settings, General, the first-run line, and the README line.
final class UpdateOfferTests: XCTestCase {

    // MARK: - U5, the Now row

    func testTheRowOffersTheDownloadAndNotNow() {
        var s = RelevanceState()
        s.updateOffer = UpdateOffer(version: "3.2.0", viaHomebrew: false)
        let row = Relevance.now(s).first { $0.id.hasPrefix("update.") }
        XCTAssertEqual(row?.title, "Grux AI 3.2.0 is available")
        XCTAssertEqual(row?.detail, "Download")
        XCTAssertEqual(row?.action, .downloadUpdate)
        XCTAssertEqual(row?.dismiss, .dismissUpdate(version: "3.2.0"))
    }

    func testAHomebrewInstallIsToldTheBrewCommand() {
        var s = RelevanceState()
        s.updateOffer = UpdateOffer(version: "3.2.0", viaHomebrew: true)
        let row = Relevance.now(s).first { $0.id.hasPrefix("update.") }
        XCTAssertEqual(row?.detail, "brew upgrade --cask grux")
        XCTAssertEqual(row?.action, .copyBrewUpgrade)
        XCTAssertEqual(row?.dismiss, .dismissUpdate(version: "3.2.0"))
    }

    func testNoOfferNoRow() {
        XCTAssertNil(Relevance.now(RelevanceState()).first { $0.id.hasPrefix("update.") })
        XCTAssertNil(Relevance.now(RelevanceState()).first { $0.dismiss != nil }, "no other row grows a Not now")
    }

    func testTheDownloadIsTheStableLatestDmg() {
        XCTAssertEqual(UpdateCheck.downloadURL.absoluteString,
                       "https://github.com/dotcomjack/grux/releases/latest/download/Grux.dmg")
        XCTAssertEqual(UpdateCheck.brewCommand, "brew upgrade --cask grux")
    }

    func testHomebrewIsReadFromTheCaskroom() {
        XCTAssertTrue(UpdateCheck.installedByHomebrew(appPath: "/opt/homebrew/Caskroom/grux/3.1.0/Grux.app",
                                                      resolvedPath: "/opt/homebrew/Caskroom/grux/3.1.0/Grux.app",
                                                      caskroomHasGrux: false))
        XCTAssertTrue(UpdateCheck.installedByHomebrew(appPath: "/Applications/Grux.app",
                                                      resolvedPath: "/usr/local/Caskroom/grux/3.1.0/Grux.app",
                                                      caskroomHasGrux: false), "a brew symlink")
        XCTAssertTrue(UpdateCheck.installedByHomebrew(appPath: "/Applications/Grux.app",
                                                      resolvedPath: "/Applications/Grux.app",
                                                      caskroomHasGrux: true), "brew moved the app and keeps its Caskroom entry")
        XCTAssertFalse(UpdateCheck.installedByHomebrew(appPath: "/Applications/Grux.app",
                                                       resolvedPath: "/Applications/Grux.app",
                                                       caskroomHasGrux: false))
    }

    /// The download never opens a browser on a headless Mac; it says what it withheld.
    @MainActor
    func testTheDownloadIsWithheldWhenHeadless() {
        var opened: [URL] = []
        var withheld: [String] = []
        UpdateDownload.open(headless: true, open: { opened.append($0) }, withhold: { withheld.append($0) })
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(withheld.count, 1)
        UpdateDownload.open(headless: false, open: { opened.append($0) }, withhold: { withheld.append($0) })
        XCTAssertEqual(opened, [UpdateCheck.downloadURL])
    }

    // MARK: - U5, Not now and the compared version

    private var tempState: URL!

    override func setUp() {
        super.setUp()
        tempState = FileManager.default.temporaryDirectory.appendingPathComponent("update-offer-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempState)
        super.tearDown()
    }

    @MainActor
    private func checker(latest: @escaping () -> String, installed: String = "3.1.0") -> (UpdateChecker, () -> Int) {
        var requests = 0
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let c = UpdateChecker(environment: UpdateChecker.Environment(
            now: { now = now.addingTimeInterval(25 * 3600); return now },
            installedVersion: { installed },
            enabled: { true }, firstRunDone: { true }, network: { .online },
            fetch: { _ in
                requests += 1
                return (Data(#"{"tag_name":"\#(latest())","draft":false,"prerelease":false}"#.utf8), 200)
            },
            stateURL: tempState, log: { _ in }))
        return (c, { requests })
    }

    @MainActor
    func testNotNowHidesThatVersionAndANewerOneShowsAgain() async {
        var tag = "v3.2.0"
        let (c, _) = checker(latest: { tag })
        _ = await c.run(manual: false)
        XCTAssertEqual(c.available, "3.2.0")

        c.notNow(version: "3.2.0")
        XCTAssertNil(c.available)
        _ = await c.run(manual: false)
        XCTAssertNil(c.available, "the same version stays hidden")

        let (relaunched, requests) = checker(latest: { tag })
        XCTAssertNil(relaunched.available, "and across a relaunch")
        XCTAssertEqual(requests(), 0)

        tag = "v3.3.0"
        _ = await c.run(manual: false)
        XCTAssertEqual(c.available, "3.3.0")
    }

    @MainActor
    func testAnOfferSurvivesARelaunchWithoutARequest() async {
        let (c, _) = checker(latest: { "v3.2.0" })
        _ = await c.run(manual: false)
        let (relaunched, requests) = checker(latest: { "v3.2.0" })
        XCTAssertEqual(relaunched.available, "3.2.0", "read back from the last answer on disk")
        XCTAssertEqual(requests(), 0)
        let (upgraded, _) = checker(latest: { "v3.2.0" }, installed: "3.2.0")
        XCTAssertNil(upgraded.available, "after the person upgrades, the old offer is gone")
    }

    /// The debug seam for the live proof: a file names the version to compare as.
    func testTheComparedVersionSeam() {
        XCTAssertEqual(UpdateCheck.comparedVersion(bundle: "3.1.0", pretend: nil), "3.1.0")
        XCTAssertEqual(UpdateCheck.comparedVersion(bundle: "3.1.0", pretend: " 3.0.0\n"), "3.0.0")
        XCTAssertEqual(UpdateCheck.comparedVersion(bundle: "3.1.0", pretend: ""), "3.1.0")
        XCTAssertEqual(UpdateCheck.comparedVersion(bundle: "3.1.0", pretend: "not a version"), "3.1.0")
    }

    // MARK: - U6, findable

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    func testFirstRunNamesIt() throws {
        let steps = try Self.source("Sources/Grux/Onboarding/OnboardingSteps.swift")
        XCTAssertTrue(steps.contains("How Grux works"), "control")
        XCTAssertTrue(steps.contains("Once a day Grux checks GitHub's public release page for a new version"))
        XCTAssertTrue(steps.contains("Settings, General turns it off"))
    }

    func testSettingsGeneralHasTheSwitchAndCheckNow() throws {
        let settings = try Self.source("Sources/Grux/SettingsView.swift")
        XCTAssertTrue(settings.contains(#"Toggle("Check for new versions""#))
        XCTAssertTrue(settings.contains("state.config.updateCheckEnabled = "), "the switch writes the config")
        XCTAssertTrue(settings.contains(#"Button("Check now")"#))
        XCTAssertTrue(settings.contains("UpdateChecker.shared.run(manual: true)"))
        XCTAssertTrue(settings.contains("Text(UpdateCheck.settingsExplanation)"))
        let entry = SettingsSearchRegistry.entries.first { $0.id == "general.about" }
        XCTAssertTrue(entry?.keywords.contains("check for new versions") == true)
        XCTAssertTrue(entry?.keywords.contains("update") == true)
    }

    func testTheOffStateIsExplained() {
        let e = UpdateCheck.settingsExplanation.lowercased()
        for phrase in ["once a day", "github's public release page", "nothing about you",
                       "never downloads or installs", "off means it never asks", "check now asks once"] {
            XCTAssertTrue(e.contains(phrase), phrase)
        }
        // Round 2 P2: the system user agent names the Grux and macOS versions, so the
        // request is not the same for everyone; the explanation says what it does carry.
        XCTAssertFalse(e.contains("same for everyone"))
        XCTAssertTrue(e.contains("your grux and macos versions"))
    }

    /// Round 2 P2: Not now pressed while a check is out must survive that check.
    @MainActor
    func testNotNowDuringACheckInFlightSticks() async {
        var holder: UpdateChecker?
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let c = UpdateChecker(environment: UpdateChecker.Environment(
            now: { now = now.addingTimeInterval(25 * 3600); return now },
            installedVersion: { "3.1.0" }, enabled: { true }, firstRunDone: { true },
            network: { .online },
            fetch: { _ in
                // The person presses Not now while the request is out.
                await MainActor.run { holder?.notNow(version: "3.2.0") }
                return (Data(#"{"tag_name":"v3.2.0","draft":false,"prerelease":false}"#.utf8), 200)
            },
            stateURL: tempState, log: { _ in }))
        holder = c
        _ = await c.run(manual: true)
        XCTAssertNil(c.available, "the row stays hidden")
        let (relaunched, _) = checker(latest: { "v3.2.0" })
        XCTAssertNil(relaunched.available, "and the dismissal is still on disk")
    }

    // MARK: - U7, the README says it exactly as the spec words it

    func testTheReadmeSaysWhatItDoes() throws {
        // Compared with line breaks folded, because the README wraps its paragraphs.
        let readme = try Self.source("../README.md")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(readme.contains("Grux checks GitHub's public release page once a day to tell you about new versions. It sends nothing about you, never installs anything by itself, and you can turn it off."))
        XCTAssertFalse(readme.lowercased().contains("phoning home"))
    }
}
