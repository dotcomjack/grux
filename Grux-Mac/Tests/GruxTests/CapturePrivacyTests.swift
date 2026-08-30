import XCTest
@testable import Grux

/// The privacy layer decides whether Grux is allowed to photograph what is on
/// screen. Before this existed the app had exactly one exclusion, a check that
/// skipped ANALYSIS when Grux itself was frontmost, and nothing that stopped a
/// frame containing an open password manager from being encoded and posted to a
/// vision API on a timer.
///
/// These test the decision function directly rather than driving
/// ScreenCaptureKit, because the decision is where the bugs are and the
/// compositor is Apple's. What is deliberately NOT claimed here: that the
/// resulting frame has no password manager pixels in it. That needs a real
/// capture with a real window on a real display, and it is stated as unproven
/// rather than implied by a green test.
final class CapturePrivacyTests: XCTestCase {

    private let bundleIds = CapturePrivacy.defaultExcludedBundleIds
    private let titles = CapturePrivacy.defaultExcludedTitlePatterns

    private func block(_ bundleId: String, _ title: String) -> String? {
        CapturePrivacy.frontmostBlockReason(
            bundleId: bundleId, windowTitle: title,
            bundleIds: bundleIds, titlePatterns: titles)
    }

    func testPasswordManagersAreBlocked() {
        XCTAssertNotNil(block("com.1password.1password", "1Password"))
        XCTAssertNotNil(block("com.bitwarden.desktop", "Bitwarden"))
        XCTAssertNotNil(block("org.keepassxc.keepassxc", "KeePassXC"))
        XCTAssertNotNil(block("com.apple.keychainaccess", "Keychain Access"))
    }

    /// Bundle ids are case insensitive because macOS treats them that way and a
    /// list that only matches one casing fails silently: the app is simply never
    /// excluded, which is indistinguishable from a working list until it matters.
    func testBundleMatchingIsCaseInsensitive() {
        XCTAssertNotNil(block("COM.1PASSWORD.1PASSWORD", "1Password"))
    }

    /// The net under the bundle list. A credential shown inside an app that is
    /// not a credential app is the case the bundle list structurally cannot see.
    func testTitlePatternsCatchCredentialsInOrdinaryApps() {
        XCTAssertNotNil(block("com.google.Chrome", "Change your password | Acme"))
        XCTAssertNotNil(block("com.apple.TextEdit", "wallet recovery phrase.txt"))
        XCTAssertNotNil(block("com.googlecode.iterm2", "ssh private key setup"))
    }

    func testOrdinaryWorkIsNotBlocked() {
        XCTAssertNil(block("com.microsoft.VSCode", "FocusWatcher.swift"))
        XCTAssertNil(block("com.google.Chrome", "Swift Forums, actors"))
        XCTAssertNil(block("com.apple.Terminal", "make build"))
        XCTAssertNil(block("com.tinyspeck.slackmacgap", "general"))
    }

    /// A whitespace-only pattern must not match everything.
    ///
    /// The first version of this test used the EMPTY string and was vacuous:
    /// Swift's `range(of: "")` returns nil, so `contains("")` is false and the
    /// test passed with the guard deliberately removed. It was found by planting
    /// that removal and watching the suite stay green, which is the only reason
    /// anyone would ever notice. A single SPACE is the real hazard, because it
    /// is not empty and it IS a substring of nearly every window title, so one
    /// stray space in the settings editor would switch off all screen capture
    /// with no symptom other than Grux quietly going blind.
    func testWhitespaceOnlyPatternDoesNotBlockEverything() {
        XCTAssertNil(CapturePrivacy.frontmostBlockReason(
            bundleId: "com.microsoft.VSCode", windowTitle: "main file.swift",
            bundleIds: [], titlePatterns: [" ", "", "\t"]))
        XCTAssertFalse(CapturePrivacy.matches(" ", "main file.swift"))
        XCTAssertFalse(CapturePrivacy.matches("", "main file.swift"))
        // And a real pattern still matches once padding is trimmed off it.
        XCTAssertTrue(CapturePrivacy.matches("  password  ", "reset your password"))
    }

    /// A window with no title must not be treated as matching.
    func testEmptyTitleIsNotAMatch() {
        XCTAssertNil(block("com.microsoft.VSCode", ""))
    }

    func testExclusionListsCanBeEmptiedDeliberately() {
        XCTAssertNil(CapturePrivacy.frontmostBlockReason(
            bundleId: "com.1password.1password", windowTitle: "1Password",
            bundleIds: [], titlePatterns: []))
    }

    /// The reason string reaches the user, in the Focus log and in what the
    /// model is told, so it has to say which rule fired.
    func testReasonNamesTheMatchedPattern() {
        let reason = block("com.google.Chrome", "Reset your PASSWORD")
        XCTAssertEqual(reason, "window title matched \"password\"")
        XCTAssertEqual(block("com.1password.1password", "x"), "excluded app")
    }

    /// The settings editor turns free text into a list. A blank line becoming an
    /// empty pattern is the footgun above, and a duplicate is just noise.
    func testSettingsEditorParsingDropsBlanksAndDuplicates() {
        let parsed = SettingsView.linesToList("""
        com.1password.1password

           com.bitwarden.desktop
        COM.1PASSWORD.1PASSWORD
        """)
        XCTAssertEqual(parsed, ["com.1password.1password", "com.bitwarden.desktop"])
    }

    func testCapturePrivacyDefaultsAreOnForANewConfig() {
        XCTAssertFalse(GruxConfig.default.captureExcludedBundleIds.isEmpty)
        XCTAssertTrue(GruxConfig.default.captureExcludedBundleIds.contains("com.1password.1password"))
        XCTAssertFalse(GruxConfig.default.captureExcludedTitlePatterns.isEmpty)
    }

    /// A config file written before this feature existed must come back with the
    /// exclusions ON. Defaulting a missing privacy control to empty would mean
    /// every existing install silently upgraded into no protection.
    func testOldConfigWithoutTheKeysInheritsTheDefaults() throws {
        let json = #"{"anthropicApiKey":"","model":"claude-haiku-4-5-20251001","captureIntervalSeconds":30,"driftThreshold":2,"autoPromoteDetectedTask":true,"notificationsEnabled":true,"screenAnalysisEnabled":true,"launchAtLogin":false,"snoozeMinutes":15,"activeHoursStart":9,"activeHoursEnd":18}"#
        let cfg = try JSONDecoder().decode(GruxConfig.self, from: Data(json.utf8))
        XCTAssertTrue(cfg.captureExcludedBundleIds.contains("com.1password.1password"))
        XCTAssertFalse(cfg.captureExcludedTitlePatterns.isEmpty)
    }

    /// An empty list is a real choice and must survive a save/load round trip,
    /// which is why the decoder uses decodeIfPresent rather than treating empty
    /// as missing and helpfully restoring the defaults.
    func testDeliberatelyEmptiedListsSurviveARoundTrip() throws {
        var cfg = GruxConfig.default
        cfg.captureExcludedBundleIds = []
        cfg.captureExcludedTitlePatterns = []
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(GruxConfig.self, from: data)
        XCTAssertTrue(back.captureExcludedBundleIds.isEmpty)
        XCTAssertTrue(back.captureExcludedTitlePatterns.isEmpty)
    }

    /// 17 must not render as 17:00. House rule, and it was live in the Focus
    /// banner as "9:00-17:00".
    func testActiveHoursRenderAsStandardTime() {
        XCTAssertEqual(FocusLogView.clockLabel(17), "5:00 PM")
        XCTAssertEqual(FocusLogView.clockLabel(9), "9:00 AM")
        XCTAssertEqual(FocusLogView.clockLabel(0), "12:00 AM")
        XCTAssertEqual(FocusLogView.clockLabel(12), "12:00 PM")
    }
}
