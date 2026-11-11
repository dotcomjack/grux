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
        XCTAssertEqual(keyCapabilities.count, 12)  // 12 until CR-37 retired the registrar key, 11 until key.typesafe
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
        // `fal` was dropped 2026-09-22: fal.ai is out of the business model,
        // and the alias pointed at `data.fal`, an anchor no pane has drawn
        // since the vendor was replaced. A deep link to nowhere is worse than
        // no deep link, because it lands the reader at the top of a pane with
        // no sign that anything was meant to be there.
        XCTAssertNil(SettingsTabAliases.map["fal"], "the retired fal deep link is back")
        XCTAssertNil(SettingsSearchRegistry.entries.first { $0.id == "data.fal" })
        XCTAssertEqual(SettingsTabAliases.resolve("models").pane, .models)
    }

    /// D49 (sense pass 3): the header said "All of them are empty until you paste one" on a Mac
    /// with a key set. It states how many are set, and claims empty only when none is.
    func testTheHeaderSaysHowManyKeysAreSet() {
        let none = CapabilityCredentialsSection.headerLine(configured: 0, offered: 6)
        XCTAssertTrue(none.contains("None is set yet"), none)
        for k in [1, 5, 6] {
            let line = CapabilityCredentialsSection.headerLine(configured: k, offered: 6)
            XCTAssertTrue(line.contains("\(k) of 6 set"), line)
            XCTAssertFalse(line.lowercased().contains("empty") || line.contains("None"), line)
        }
        for line in [none, CapabilityCredentialsSection.headerLine(configured: 2, offered: 6)] {
            XCTAssertTrue(line.contains("Keychain"), line)
        }
    }

    /// D63 (sense pass 4): inside Settings the row read "Add your Anthropic API key in Settings
    /// to use Claude." above the very field. The row says what the key unlocks; the setup card,
    /// shown outside Settings, keeps saying where to go.
    func testACredentialRowInSettingsDoesNotSendYouToSettings() {
        let keys = SetupRequirement.allCases.filter { $0.kind == .key }
        XCTAssertFalse(keys.isEmpty)
        for req in keys {
            let line = CapabilityCredentialsSection.rowLine(req)
            XCTAssertFalse(line.contains("Settings"), "\(req.rawValue): \(line)")
            XCTAssertEqual(line, req.remediation.replacingOccurrences(of: " in Settings", with: "")
                               .replacingOccurrences(of: " in Integrations", with: ""),
                           "\(req.rawValue): the row keeps every other word of the contract sentence")
        }
        XCTAssertEqual(CapabilityCredentialsSection.rowLine(.keyAnthropic),
                       "Add your Anthropic API key to use Claude. Get one at console.anthropic.com. "
                       + "Many features run on a local model with no key.")
        XCTAssertEqual(CapabilityCredentialsSection.rowLine(.keyReplicate),
                       "Add a Replicate API token to generate images.")
        XCTAssertTrue(SetupRequirement.keyAnthropic.remediation.contains("in Settings"),
                      "the setup card outside Settings still says where to go")
    }

    /// D135 item 6 (sense pass 14, `settings-capabilities-page1.png`): the TypeSafe row read
    /// "Add a TypeSafe key in Integrations" above its own field and Save. A row in this
    /// section holds the field, so it sends a person nowhere else.
    func testACredentialRowSendsYouNowhereElse() {
        for req in SetupRequirement.allCases where req.kind == .key {
            let line = CapabilityCredentialsSection.rowLine(req)
            XCTAssertFalse(line.contains(" in Integrations"), "\(req.rawValue): \(line)")
        }
        XCTAssertEqual(CapabilityCredentialsSection.rowLine(.keyTypesafe),
                       "Optional. Add a TypeSafe key so Grux understands asks it cannot match word for word. "
                       + "Without one, it decides on this Mac.")
        XCTAssertTrue(SetupRequirement.keyTypesafe.remediation.contains("in Integrations"),
                      "the setup card outside Settings still says where to go")
    }
}
