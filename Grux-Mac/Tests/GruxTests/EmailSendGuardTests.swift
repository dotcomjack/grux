import XCTest
@testable import Grux

// Regression coverage for the audit-swarm fixes on the send path:
// idempotency (no double-send) and the widened banned-offer token list.
@MainActor
final class EmailSendGuardTests: XCTestCase {

    // sendDraft must refuse any draft that is not .staged, so two UI surfaces (or
    // an auto-send racing a manual tap) cannot double-deliver. An already-sent
    // draft returns failure WITHOUT touching the network.
    func testSendDraftRefusesNonStagedDraft() async {
        let id = "sendguard-sent-\(UUID().uuidString.prefix(8))"
        SupportDraftStore.shared.upsert(SupportDraft(
            // A fictional inbox built through the roster-free initializer. The
            // roster lives in the user's own ~/.grux/brands.json now, so a test
            // that named a real brand would pass or fail on whether one
            // person's config file happened to be on the machine.
            id: id, createdAt: Date(), inbox: SupportInbox(id: "test-brand"),
            brandVoice: "test-brand", category: .shipping,
            fromName: "T", fromEmail: "t@example.com", subject: "s", incomingPreview: "",
            draftReply: "Hi, all set. Acme Organics", originalReply: "Hi, all set. Acme Organics",
            urgency: .normal, needsReview: false, reviewReason: nil, sourceMessageId: "",
            status: .sent))                      // already sent
        defer { SupportDraftStore.shared.remove(id) }

        let res = await EmailTriageEngine.shared.sendDraft(id)
        if case .success = res { XCTFail("a non-staged draft must not send") }
    }

    // These two assert on `universalBannedOffers`, the floor that applies to
    // every voice including one the roster has never heard of. A phrase from a
    // brand's own `bannedOffers` would make the test pass only on a machine
    // whose ~/.grux/brands.json happens to list it, which is exactly the
    // one-person coupling the roster move removed.
    func testBannedTokensFlagsShippingPromises() {
        let flagged = EmailTriageEngine.bannedTokensFound(
            in: "Hi, I will add free shipping so it arrives faster. Acme Organics",
            voice: "test-brand")
        XCTAssertTrue(flagged.contains("free shipping"))
    }

    func testBannedTokensRespectsDenialForShippingPromise() {
        // A denial of the same phrase must NOT flag (negation-aware).
        let flagged = EmailTriageEngine.bannedTokensFound(
            in: "We do not offer free shipping. Acme Organics",
            voice: "test-brand")
        XCTAssertFalse(flagged.contains("free shipping"))
    }

    func testBannedTokensDoesNotFlagBrandSignature() {
        // "organic" is an attribute claim that also shows up inside brand names, so
        // it must never be a banned token, or a reply would flag on its own
        // signature. The fixture signs off with a name that contains it.
        let flagged = EmailTriageEngine.bannedTokensFound(
            in: "Thanks for reaching out. Acme Organics", voice: "test-brand")
        XCTAssertTrue(flagged.isEmpty)
    }
}
