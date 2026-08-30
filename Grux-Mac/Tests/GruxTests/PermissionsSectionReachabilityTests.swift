import XCTest
@testable import Grux

/// A permission explanation that exists but cannot be found is the defect this
/// suite guards, and it is the one the operator actually hit.
///
/// The copy was real and lived in onboarding. The only route back was Settings,
/// General, "Restart onboarding", which resets the whole flow. So after a
/// bundle-id change revoked all nine TCC grants, macOS re-prompted and the app
/// had nothing to say, months after first-run had happened.
///
/// These tests assert the panel is registered, anchored, and findable by the
/// words somebody actually types with a system dialog on screen: the NAME OF THE
/// PERMISSION, not the word "permissions".
@MainActor
final class PermissionsSectionReachabilityTests: XCTestCase {

    private let anchor = "general.permissions"

    private var entry: SettingsSearchEntry? {
        SettingsSearchRegistry.entries.first { $0.id == anchor }
    }

    func testThePanelIsRegisteredAndAnchored() throws {
        let e = try XCTUnwrap(entry, "no search entry for \(anchor); the panel is unreachable by search")
        XCTAssertEqual(e.location.anchor, anchor,
                       "the entry's anchor must match the section id or the jump lands nowhere")
        XCTAssertFalse(e.title.isEmpty)
    }

    /// The real test. Every permission the panel lists must be findable by its
    /// own label, because that is the word on the macOS dialog the user is
    /// staring at when they go looking.
    func testEveryListedPermissionIsFindableByItsOwnName() throws {
        let e = try XCTUnwrap(entry)
        for req in CapabilityRequest.onboardingOrder {
            let needle = req.label.lowercased()
            XCTAssertTrue(e.matches(needle),
                "searching Settings for \"\(req.label)\" does not surface the Permissions panel. "
                + "That is the exact moment somebody needs it.")
        }
    }

    /// The panel explains every permission it can ask for. A permission Grux
    /// requests but never explains is the original bug in miniature.
    func testEveryRequestablePermissionHasCopyToShow() {
        for req in CapabilityRequest.onboardingOrder {
            let shown = req.why.isEmpty ? req.rationale : req.why
            XCTAssertFalse(shown.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(req.rawValue) is in the request queue with nothing to display")
        }
    }

    /// Onboarding order and the panel are the same list on purpose: two lists
    /// drift, and the one that drifts is always the one nobody is looking at.
    ///
    /// Exactly one permission is legitimately absent. macOS grants system audio
    /// capture under Screen Recording, so `perm.system_audio` and
    /// `perm.screen_recording` are two ids behind one system switch, and listing
    /// both would show a second row that a user cannot act on independently.
    ///
    /// The exemption is named rather than tolerated: adding a new permission and
    /// forgetting to queue it fails here, and if macOS ever gives system audio
    /// its own switch the equivalence assertion below fails too.
    func testThePanelCoversEveryPermissionExceptTheOneMacOSBundles() {
        let listed = Set(CapabilityRequest.onboardingOrder.map(\.rawValue))
        let all = SetupRequirement.allCases.filter { $0.rawValue.hasPrefix("perm.") }

        let missing = all.map(\.rawValue).filter { !listed.contains($0) }
        XCTAssertEqual(missing, ["perm.system_audio"],
            "the only permission the panel may omit is the one macOS grants under another. "
            + "Missing: \(missing)")

        XCTAssertEqual(CapabilityResolver.isSatisfied(.permSystemAudio),
                       CapabilityResolver.isSatisfied(.permScreenRecording),
            "perm.system_audio is omitted from the panel because it resolves through Screen "
            + "Recording. It no longer does, so it needs its own row.")
    }

    /// Proves the search matcher can fail, so the assertions above mean
    /// something. A matcher that returns true for everything would pass every
    /// test in this file.
    func testTheSearchMatcherRejectsAnUnrelatedQuery() throws {
        let e = try XCTUnwrap(entry)
        XCTAssertFalse(e.matches("elevenlabs voice cloning"),
                       "the matcher matches unrelated text, so the reachability tests prove nothing")
    }
}
