import XCTest
@testable import Grux

/// Guards the property that made this section necessary: every credential the
/// contract defines must have somewhere to be typed, and a setup card must be
/// able to send the user to it.
///
/// The audit that preceded this found 8 key capabilities with NO field
/// anywhere in the app, while their remediation said to add them in Settings.
@MainActor
final class CapabilityCredentialsTests: XCTestCase {

    private var keyCapabilities: [SetupRequirement] {
        SetupRequirement.allCases.filter { $0.kind == .key }
    }

    /// Every credential must be storable, or its field cannot save anything.
    func testEveryCredentialHasAKeychainSlot() {
        let orphans = keyCapabilities
            .filter { CapabilityResolver.keychainKey(for: $0) == nil }
            .map(\.rawValue)
        XCTAssertTrue(orphans.isEmpty, "credentials with nowhere to store a value: \(orphans)")
        // 14 until CR-34 deleted the two scalar provider key capabilities on
        // 2026-08-28. A provider key is one key per user-added endpoint held by
        // CustomEndpointStore, not a slot on the app.
        XCTAssertEqual(keyCapabilities.count, 12)
    }

    /// Every credential must be reachable by a deep link, resolving to the pane,
    /// the sub-pane AND its own row anchor. A link that lands on the right pane
    /// but the wrong row is the "go and hunt for it" remediation this replaces.
    func testEveryCredentialDeepLinkResolvesToItsOwnRow() {
        for req in keyCapabilities {
            let loc = SettingsTabAliases.resolve(req.rawValue)
            XCTAssertEqual(loc.pane, .dataSecurity, "\(req.rawValue) resolved to \(loc.pane)")
            XCTAssertEqual(loc.sub, "capabilities", "\(req.rawValue) missed the capabilities sub-pane")
            XCTAssertEqual(loc.anchor, SettingsTabAliases.credentialAnchor(req),
                           "\(req.rawValue) did not resolve to its own row anchor")
        }
    }

    /// Non-credential capabilities must NOT be dragged into the credentials
    /// section, since a permission or a step has no field to fill in.
    func testNonCredentialCapabilitiesDoNotResolveToACredentialRow() {
        for req in SetupRequirement.allCases where req.kind != .key {
            let loc = SettingsTabAliases.resolve(req.rawValue)
            XCTAssertNil(loc.anchor.flatMap { $0.hasPrefix("credential.") ? $0 : nil },
                         "\(req.rawValue) resolved to a credential row, but it is a \(req.kind.rawValue)")
        }
    }

    /// The existing hand-written aliases must keep winning, so this addition
    /// cannot quietly re-route a tag somebody already depends on.
    func testExistingAliasesStillWin() {
        XCTAssertEqual(SettingsTabAliases.resolve("fal").anchor, "data.fal")
        XCTAssertEqual(SettingsTabAliases.resolve("models").pane, .models)
    }
}
