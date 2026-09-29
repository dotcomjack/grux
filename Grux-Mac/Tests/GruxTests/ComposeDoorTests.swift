import XCTest
@testable import Grux

/// COMPOSE AND SEND LIVES INSIDE MAIL, BEHIND ITS OWN CREDENTIAL.
///
/// Reading mail needs a mail server. Sending needs that and an email sending
/// key, because Grux has no SMTP client. Mail's Compose door asks `ComposeDoor`
/// what sending is missing and shows the setup card instead of a form when
/// anything is, so nobody writes a whole message only to be told at Send that
/// it cannot go.
///
/// Asked with a predicate rather than the live Keychain, so the rule holds on
/// a Mac that already has every key, which includes every Mac this is
/// developed on.
@MainActor
final class ComposeDoorTests: XCTestCase {

    /// The whole claim: the sending key is compose's OWN credential. Reading
    /// works without it, and the door is closed without it.
    func test_sendingNeedsAKeyThatReadingDoesNot() throws {
        let allButTheSendingKey: (SetupRequirement) -> Bool = { $0 != .keyResend }
        XCTAssertEqual(ComposeDoor.missing(satisfied: allButTheSendingKey), [.keyResend],
                       "the Compose door would open a form that cannot send")
        let mailbox = try XCTUnwrap(FeatureRegistry.row(id: "mailbox"))
        XCTAssertTrue(FeatureRegistry.unmetBlocking(of: mailbox, satisfied: allButTheSendingKey).isEmpty,
                      "reading mail now needs the sending key, so it is no longer compose's own credential")
    }

    /// And the door is not stuck shut: with sending set up there is nothing
    /// left to show but the form.
    func test_theDoorOpensOnceSendingIsSetUp() {
        XCTAssertTrue(ComposeDoor.missing(satisfied: { _ in true }).isEmpty)
    }

    /// The door answers for the row that folds into Mail, not for Mail itself.
    func test_theDoorAnswersForTheComposeRow() {
        XCTAssertEqual(FeatureRegistry.disposition(for: ComposeDoor.featureId),
                       .folds(into: "mailbox"))
    }
}
