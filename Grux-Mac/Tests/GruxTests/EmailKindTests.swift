import XCTest
@testable import Grux

final class EmailKindTests: XCTestCase {

    private func detect(_ email: String, name: String = "", subject: String = "",
                        isBulk: Bool = false, isAutoSubmitted: Bool = false) -> EmailKind {
        EmailKind.detect(fromEmail: email, fromName: name, subject: subject,
                         isBulk: isBulk, isAutoSubmitted: isAutoSubmitted)
    }

    // MARK: automated

    func testAutomatedRealWalmartNoReply() {
        // The real Walmart case: mpsend. host plus a no-reply local part.
        XCTAssertEqual(detect("no-reply@mpsend.walmart.com"), .automated)
    }

    func testAutomatedMailerDaemon() {
        XCTAssertEqual(detect("mailer-daemon@x.com"), .automated)
    }

    func testAutoSubmittedForcesAutomatedEvenForPlainAddress() {
        XCTAssertEqual(detect("jane.doe@gmail.com", isAutoSubmitted: true), .automated)
    }

    // MARK: marketing

    func testBulkFlagIsMarketing() {
        XCTAssertEqual(detect("hello@brand.com", isBulk: true), .marketing)
    }

    func testNewsletterLocalPartIsMarketing() {
        XCTAssertEqual(detect("newsletter@brand.com"), .marketing)
    }

    func testMarketingLocalPartIsMarketing() {
        XCTAssertEqual(detect("marketing@brand.com"), .marketing)
    }

    // MARK: personal

    func testPlainHumanIsPersonal() {
        XCTAssertEqual(detect("jane.doe@gmail.com"), .personal)
    }

    func testDomainContainingNewsStaysPersonal() {
        // Local-part is "user"; "news" only appears in the domain, so not marketing.
        XCTAssertEqual(detect("user@newsite.com"), .personal)
    }

    // MARK: automated beats marketing

    func testAutomatedBeatsMarketing() {
        // no-reply newsletter with bulk flag: automated wins.
        XCTAssertEqual(detect("noreply@newsletter.brand.com", isBulk: true), .automated)
    }

    // MARK: false-positive protection (never drop a real human) [review-swarm]

    func testHumanAtBouncexDomainStaysPersonal() {
        // "bounce" appears only in the DOMAIN of a real adtech company; the local
        // part is a person. Must not be classified automated.
        XCTAssertEqual(detect("john@bouncex.com"), .personal)
    }

    func testHumanLocalPartContainingBounceStaysPersonal() {
        // "bouncer" contains "bounce" but is not a bounce mailbox.
        XCTAssertEqual(detect("ann.bouncer@gmail.com"), .personal)
    }

    func testNotificationInDomainStaysPersonal() {
        XCTAssertEqual(detect("sales@notificationsystems.com"), .personal)
    }

    func testHumanHandleStartingWithNewsStaysPersonal() {
        // "newsguy" starts with "news" but is a real handle, not marketing.
        XCTAssertEqual(detect("newsguy@brand.com"), .personal)
    }

    func testBoundedBounceMailboxIsAutomated() {
        // A genuine bounce mailbox (exact or separator-bounded) is still caught.
        XCTAssertEqual(detect("bounces@list.brand.com"), .automated)
        XCTAssertEqual(detect("list-bounces@brand.com"), .automated)
    }

    func testExactNewsLocalPartIsMarketing() {
        XCTAssertEqual(detect("news@brand.com"), .marketing)
    }

    // MARK: sub-addressing + transactional senders

    // The live miss that prompted this: a Stripe receipt was classed .personal
    // and staged as a repliable support draft, so a courteous reply was drafted
    // to a billing robot about a purchase nobody made.
    func testStripeReceiptWithPlusAddressingIsAutomated() {
        XCTAssertEqual(detect("invoice+statements+billing@stripe.com"), .automated)
    }

    func testTransactionalBaseLocalPartsAreAutomated() {
        for local in ["invoice", "invoices", "receipt", "receipts", "statement", "statements"] {
            XCTAssertEqual(detect("\(local)@vendor.com"), .automated, "\(local) should be automated")
            XCTAssertEqual(detect("\(local)+tag@vendor.com"), .automated, "\(local)+tag should be automated")
        }
    }

    // THE ONE THAT MATTERS. A plus tag is chosen by the SENDER, so the base
    // local-part is who they are and the tag is arbitrary. Treating "+" as an
    // ordinary separator would match it as a suffix too and drop a real person
    // into .automated, which is the expensive error EmailKind opens by warning
    // about. Jane is a human filing her own mail, not an invoice robot.
    func testHumanUsingAPlusTagStaysPersonal() {
        XCTAssertEqual(detect("jane+invoice@gmail.com"), .personal)
        XCTAssertEqual(detect("dave+receipts@gmail.com"), .personal)
        XCTAssertEqual(detect("sam+newsletter@gmail.com"), .personal)
        XCTAssertEqual(detect("kim+bounce@gmail.com"), .personal)
    }

    // Sub-addressing must not break the tokens that already worked.
    func testExistingTokensStillMatchThroughAPlusTag() {
        XCTAssertEqual(detect("bounce+xyz@list.brand.com"), .automated)
        XCTAssertEqual(detect("notifications+123@github.com"), .automated)
        XCTAssertEqual(detect("newsletter+weekly@brand.com"), .marketing)
    }

    // Words that a real person plausibly owns must stay personal, which is why
    // "billing", "accounts" and "support" are deliberately absent from the
    // transactional list.
    func testHumanSoundingBillingAddressesStayPersonal() {
        XCTAssertEqual(detect("billing@smallco.com"), .personal)
        XCTAssertEqual(detect("accounts@smallco.com"), .personal)
        XCTAssertEqual(detect("support@smallco.com"), .personal)
        XCTAssertEqual(detect("invoicing@smallco.com"), .personal)
    }

    // MARK: labels + cases

    func testLabelStrings() {
        XCTAssertEqual(EmailKind.automated.label, "No-reply / automated")
        XCTAssertEqual(EmailKind.marketing.label, "Marketing / promotional")
        XCTAssertEqual(EmailKind.personal.label, "Personal / business")
    }

    func testCaseIterableHasExactlyThreeCases() {
        XCTAssertEqual(EmailKind.allCases.count, 3)
        XCTAssertEqual(EmailKind.allCases, [.automated, .marketing, .personal])
    }
}
