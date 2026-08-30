import XCTest
@testable import Grux

// Tests for the pure parsing in the Graph mail path: the token response parser,
// the Graph message -> InboxMessage mapping, and the mailbox config lookup.
final class MailGraphTests: XCTestCase {

    func testParseTokenIntAndStringExpiry() {
        let intExp = #"{"token_type":"Bearer","expires_in":3599,"access_token":"abc.def"}"#.data(using: .utf8)!
        let a = MailGraphClient.parseToken(intExp)
        XCTAssertEqual(a?.token, "abc.def")
        XCTAssertEqual(a?.expiresIn, 3599)

        let strExp = #"{"access_token":"tok","expires_in":"1200"}"#.data(using: .utf8)!
        XCTAssertEqual(MailGraphClient.parseToken(strExp)?.expiresIn, 1200)

        XCTAssertNil(MailGraphClient.parseToken(#"{"error":"bad"}"#.data(using: .utf8)!))
    }

    func testMapMessagesStructuredFields() {
        let json = #"""
        {"value":[
          {"id":"AAA","subject":"Order shipping status","bodyPreview":"Hi I need help with an order.","from":{"emailAddress":{"name":"Dana Reyes","address":"dana@example.com"}}},
          {"id":"BBB","subject":"","bodyPreview":"hello","from":{"emailAddress":{"name":"","address":"x@y.com"}}}
        ]}
        """#.data(using: .utf8)!
        let msgs = MailGraphClient.mapMessages(json)
        XCTAssertEqual(msgs.count, 2)
        XCTAssertEqual(msgs[0].fromEmail, "dana@example.com")
        XCTAssertEqual(msgs[0].fromName, "Dana Reyes")
        XCTAssertEqual(msgs[0].subject, "Order shipping status")
        XCTAssertEqual(msgs[0].messageId, "AAA")
        XCTAssertEqual(msgs[1].subject, "(no subject)")   // empty subject normalized
        XCTAssertEqual(msgs[1].fromName, "x@y.com")        // empty name falls back to address
    }

    func testMapMessagesSkipsNoSenderAddress() {
        let json = #"{"value":[{"id":"C","subject":"x","bodyPreview":"y","from":{"emailAddress":{"name":"No Addr"}}}]}"#.data(using: .utf8)!
        XCTAssertTrue(MailGraphClient.mapMessages(json).isEmpty)  // no reply-to -> skipped
    }

    func testConfigAddressLookup() {
        let cfg = GraphMailConfig(tenantId: "t", clientId: "c", mailboxes: [
            GraphMailbox(inbox: "support", address: "support@example.com"),
            GraphMailbox(inbox: "personal", address: "me@example.com")
        ])
        XCTAssertTrue(cfg.isPresent)
        XCTAssertEqual(cfg.address(forInbox: "SUPPORT"), "support@example.com")  // case-insensitive
        XCTAssertEqual(cfg.address(forInbox: "personal"), "me@example.com")
        XCTAssertNil(cfg.address(forInbox: "unconfigured"))
    }

    func testHtmlToTextStripsTagsDecodesEntitiesAndKeepsQuotes() {
        let html = "<div>Hi Dana&nbsp;&amp; team</div><br><blockquote>On Jun 17, Support wrote:<br>order number?</blockquote><script>track()</script>"
        let t = MailGraphClient.htmlToText(html)
        XCTAssertTrue(t.contains("Hi Dana & team"))   // entities decoded
        XCTAssertTrue(t.contains("> "))                // blockquote -> quote marker (thread kept)
        XCTAssertTrue(t.contains("order number?"))
        XCTAssertFalse(t.contains("<"))                // tags stripped
        XCTAssertFalse(t.contains("track()"))          // script dropped
    }

    func testMapMessagesPopulatesFullBody() {
        let json = #"{"value":[{"id":"A","subject":"s","bodyPreview":"short preview","from":{"emailAddress":{"name":"J","address":"j@x.com"}},"body":{"contentType":"html","content":"<p>I cannot find it.</p><blockquote>share your order number</blockquote>"}}]}"#.data(using: .utf8)!
        let m = MailGraphClient.mapMessages(json)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].preview, "short preview")
        XCTAssertNotNil(m[0].body)
        XCTAssertTrue(m[0].body!.contains("I cannot find it."))
        XCTAssertTrue(m[0].body!.contains("share your order number"))  // quoted thread retained
    }

    // Header flags drive the reply-policy gate's bulk/automated detection.
    func testParseHeaderFlagsDetectsBulkAndAuto() {
        let listUnsub: [[String: Any]] = [["name": "List-Unsubscribe", "value": "<mailto:x@y.com>"]]
        XCTAssertTrue(MailGraphClient.parseHeaderFlags(listUnsub).isBulk)

        let precedence: [[String: Any]] = [["name": "Precedence", "value": "bulk"]]
        XCTAssertTrue(MailGraphClient.parseHeaderFlags(precedence).isBulk)

        let auto: [[String: Any]] = [["name": "Auto-Submitted", "value": "auto-generated"]]
        XCTAssertTrue(MailGraphClient.parseHeaderFlags(auto).isAutoSubmitted)

        let autoNo: [[String: Any]] = [["name": "Auto-Submitted", "value": "no"]]
        XCTAssertFalse(MailGraphClient.parseHeaderFlags(autoNo).isAutoSubmitted)

        let plain: [[String: Any]] = [["name": "Subject", "value": "hi"]]
        let flags = MailGraphClient.parseHeaderFlags(plain)
        XCTAssertFalse(flags.isBulk)
        XCTAssertFalse(flags.isAutoSubmitted)

        // nil / wrong-shape input is safe.
        XCTAssertFalse(MailGraphClient.parseHeaderFlags(nil).isBulk)
    }

    // A no-reply marketing message maps with both flags off-by-header but the
    // gate still catches it on the address; here we assert the header path wires
    // bulk through end to end via mapMessages.
    func testMapMessagesCarriesBulkFlag() {
        let json = #"{"value":[{"id":"A","subject":"Webinar","bodyPreview":"p","from":{"emailAddress":{"name":"Walmart","address":"no-reply@mpsend.walmart.com"}},"internetMessageHeaders":[{"name":"List-Unsubscribe","value":"<https://x>"}]}]}"#.data(using: .utf8)!
        let m = MailGraphClient.mapMessages(json)
        XCTAssertEqual(m.count, 1)
        XCTAssertTrue(m[0].isBulk)
    }
}
