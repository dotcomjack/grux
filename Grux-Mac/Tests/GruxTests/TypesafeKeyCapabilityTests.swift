import XCTest
@testable import Grux

/// The TypeSafe decision key can be stored through the credential door.
///
/// It could only be entered in Settings or on the first run, because it was not
/// a `key.*` capability. So `grux-cli connect key.typesafe` and the control
/// socket's `grux_connect` both refused it with "No capability called
/// key.typesafe", and the only other way to put it in the Keychain was the
/// `security` tool. An item created that way is not owned by Grux, and macOS
/// asked for a password on every rebuilt binary; once that held the main actor
/// for 78 seconds.
///
/// Under test `KeychainStore` answers from an in-process dictionary and the
/// status file lands in the test directory, so nothing here touches the real
/// Keychain or `~/.grux`.
@MainActor
final class TypesafeKeyCapabilityTests: XCTestCase {

    private var saved = ""

    override func setUp() {
        super.setUp()
        saved = KeychainStore.get(.typesafeApiKey)
        _ = KeychainStore.delete(.typesafeApiKey)
    }

    override func tearDown() {
        if saved.isEmpty {
            _ = KeychainStore.delete(.typesafeApiKey)
        } else {
            _ = KeychainStore.set(.typesafeApiKey, saved)
        }
        super.tearDown()
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testConnectStoresTheTypesafeKey() {
        let result = GruxControlTools.connect(capability: "key.typesafe", value: "ts-test-value")
        XCTAssertEqual(result["isError"] as? Bool, false, "connect refused: \(text(result))")
        XCTAssertEqual(KeychainStore.get(.typesafeApiKey), "ts-test-value",
                       "connect answered but the decision key slot does not hold the value")
    }

    func testDisconnectForgetsTheTypesafeKey() {
        _ = KeychainStore.set(.typesafeApiKey, "ts-test-value")
        let result = GruxControlTools.disconnect(capability: "key.typesafe")
        XCTAssertEqual(result["isError"] as? Bool, false, "disconnect refused: \(text(result))")
        XCTAssertEqual(KeychainStore.get(.typesafeApiKey), "")
    }

    /// The first run gives the Decisions key its own screen after the extras, so the
    /// setup plan must not offer it again as a generic extra now that `chat` declares it.
    func testTheSetupPlanDoesNotOfferTheKeyTwice() throws {
        let chat = try XCTUnwrap(FeatureRegistry.rows.first { $0.id == "chat" })
        XCTAssertTrue(chat.optional.contains(.keyTypesafe),
                      "control: chat no longer declares the key, so this proves nothing")
        let plan = SetupOrder.plan(features: [chat], listening: false, listeningStarted: false,
                                   satisfied: { _ in false })
        XCTAssertFalse(plan.optional.isEmpty, "control: chat offered no extras at all")
        XCTAssertFalse(plan.optional.map(\.requirement).contains(.keyTypesafe),
                       "the Decisions key is offered as an extra AND on its own screen")
    }

    /// THE CONTROL: the door still refuses a name that is not a credential, so a
    /// pass above is not a door that now accepts anything.
    func testConnectStillRefusesAnUnknownKey() {
        let result = GruxControlTools.connect(capability: "key.nosuchthing", value: "x")
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(KeychainStore.get(.typesafeApiKey), "", "an unknown id wrote the decision key slot")
    }
}
