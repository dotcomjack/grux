import XCTest
@testable import Grux

/// D201 (found working D200 item 7): on a fresh Mac the Mail pane is only its setup card,
/// "Mail server ... in Settings", and Set it up sent `endpoint.imap` to Settings, which
/// resolved it to General: no mail form anywhere, so nobody could add an account. Chat's
/// card did the same with Ollama. Every endpoint a feature requires must open the place
/// that sets it up.
final class SetupCardEndpointRouteTests: XCTestCase {

    func test_theMailServerStepOpensTheMailAccountForm() {
        XCTAssertEqual(CapabilitySetupCard.endpointRoute(for: .endpointImap), .mailAccounts)
    }

    func test_theOllamaStepOpensConnectAModel() {
        XCTAssertEqual(CapabilitySetupCard.endpointRoute(for: .endpointOllama), .settings("connect"))
        XCTAssertEqual(SettingsTabAliases.resolve("connect"),
                       SettingsLocation(pane: .models, sub: "models", anchor: "models.connect"))
    }

    /// The class: no endpoint any feature's card lists may fall through to Settings,
    /// General, the place `resolve` sends a tag it does not know.
    func test_noRequiredEndpointLandsOnTheGeneralFallback() {
        let required = Set(FeatureRegistry.rows.flatMap(\.requires).filter { $0.kind == .endpoint })
        XCTAssertFalse(required.isEmpty)
        for requirement in required {
            switch CapabilitySetupCard.endpointRoute(for: requirement) {
            case .mailAccounts:
                continue
            case .settings(let tag):
                XCTAssertNotEqual(SettingsTabAliases.resolve(tag), SettingsLocation(pane: .general),
                                  "\(requirement.rawValue) opens Settings, General, which does not set it up")
            }
        }
    }

    func test_theMailServerLineNamesWhereTheFormIs() {
        let line = SetupRequirement.endpointImap.remediation
        XCTAssertFalse(line.contains("in Settings"), "Settings has no mail account form: \(line)")
        XCTAssertEqual(line, "Add a mail account in Mail: its address, its server and an app password from your provider. Set it up opens the form.")
        XCTAssertLessThanOrEqual(line.count, 140)
    }

    func test_theCardWiresTheRouteAndTheForm() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let card = try String(contentsOf: root.appendingPathComponent("Sources/Grux/Onboarding/CapabilitySetupCard.swift"),
                              encoding: .utf8)
        XCTAssertTrue(card.contains("Self.endpointRoute(for: requirement)"), "open() does not route endpoints")
        XCTAssertTrue(card.contains("MailAccountsSheet()"), "the card does not host the mail account form")
        // Closing the form redraws every gate, so an added account clears the card at once.
        XCTAssertTrue(card.contains("if !open { SetupRevision.shared.bump() }"))
    }
}
