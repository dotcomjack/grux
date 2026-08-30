import XCTest
@testable import Grux

// Protocol-parsing tests for the minimal IMAP client. All canned server
// transcripts, zero network. Covers the response shapes the client actually
// issues: greeting, tagged status, SELECT, SEARCH UNSEEN, FETCH with
// header/body literals, plus the header decoding stack (RFC 2047 encoded
// words, quoted-printable, base64, multipart body extraction).
final class ImapParserTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - Logical line framing

    func testDrainSimpleLines() {
        var buf = data("* OK Dovecot ready.\r\nA001 OK LOGIN completed.\r\n")
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "* OK Dovecot ready.")
        XCTAssertEqual(lines[1].text, "A001 OK LOGIN completed.")
        XCTAssertTrue(buf.isEmpty, "fully consumed buffer should be empty")
    }

    func testDrainLeavesPartialLineInBuffer() {
        var buf = data("* OK ready\r\n* 5 EXI")
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(String(decoding: buf, as: UTF8.self), "* 5 EXI")

        // Completing the line on the next read drains it.
        buf.append(data("STS\r\n"))
        let more = ImapParser.drainLogicalLines(&buf)
        XCTAssertEqual(more.count, 1)
        XCTAssertEqual(more[0].text, "* 5 EXISTS")
        XCTAssertTrue(buf.isEmpty)
    }

    func testDrainLineWithLiteral() {
        let header = "Subject: Hello\r\n\r\n"
        var buf = data("* 1 FETCH (BODY[HEADER.FIELDS (SUBJECT)] {\(header.utf8.count)}\r\n\(header))\r\nA002 OK FETCH completed.\r\n")
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].literals.count, 1)
        XCTAssertEqual(String(decoding: lines[0].literals[0], as: UTF8.self), header)
        XCTAssertTrue(lines[0].text.contains("BODY[HEADER.FIELDS (SUBJECT)]"))
        XCTAssertTrue(lines[0].text.hasSuffix(")"), "post-literal continuation should be part of the logical line")
        XCTAssertEqual(lines[1].text, "A002 OK FETCH completed.")
    }

    func testDrainIncompleteLiteralWaitsForMoreData() {
        // Literal announces 50 bytes but only 10 have arrived.
        var buf = data("* 1 FETCH (BODY[TEXT] {50}\r\nonly ten b")
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(buf.isEmpty, "incomplete literal must stay buffered")
    }

    func testTrailingLiteralCount() {
        XCTAssertEqual(ImapParser.trailingLiteralCount("* 1 FETCH (BODY[TEXT] {342}"), 342)
        XCTAssertEqual(ImapParser.trailingLiteralCount("* 1 FETCH (BODY[TEXT] {7+}"), 7)
        XCTAssertNil(ImapParser.trailingLiteralCount("* 1 FETCH (FLAGS (\\Seen))"))
        XCTAssertNil(ImapParser.trailingLiteralCount("{}"))
        XCTAssertNil(ImapParser.trailingLiteralCount("not a literal {abc}"))
    }

    // MARK: - Tagged status

    func testTaggedStatusParsing() {
        let ok = ImapParser.taggedStatus(line: "A003 OK [READ-WRITE] SELECT completed.", tag: "A003")
        XCTAssertEqual(ok, .ok("[READ-WRITE] SELECT completed."))
        XCTAssertTrue(ok?.isOK ?? false)

        let no = ImapParser.taggedStatus(line: "A001 NO [AUTHENTICATIONFAILED] Invalid credentials", tag: "A001")
        if case .no(let info)? = no {
            XCTAssertTrue(info.contains("AUTHENTICATIONFAILED"))
        } else {
            XCTFail("expected NO status")
        }

        XCTAssertNil(ImapParser.taggedStatus(line: "* OK still going", tag: "A001"))
        XCTAssertNil(ImapParser.taggedStatus(line: "A002 OK done", tag: "A001"),
                     "a different tag must not match")
    }

    // MARK: - SEARCH / EXISTS / FETCH dispatch

    func testSearchNumbers() {
        XCTAssertEqual(ImapParser.searchNumbers(in: "* SEARCH 2 84 882"), [2, 84, 882])
        XCTAssertEqual(ImapParser.searchNumbers(in: "* SEARCH"), [])
        XCTAssertEqual(ImapParser.searchNumbers(in: "* 12 FETCH (FLAGS ())"), [])
    }

    func testExistsAndFetchSequenceNumbers() {
        XCTAssertEqual(ImapParser.existsCount(in: "* 23 EXISTS"), 23)
        XCTAssertNil(ImapParser.existsCount(in: "* 23 RECENT"))
        XCTAssertEqual(ImapParser.fetchSequenceNumber(in: "* 12 FETCH (FLAGS (\\Seen))"), 12)
        XCTAssertNil(ImapParser.fetchSequenceNumber(in: "* 23 EXISTS"))
    }

    func testFlagsParsing() {
        XCTAssertEqual(ImapParser.flags(in: "* 12 FETCH (FLAGS (\\Seen \\Answered) BODY[TEXT] {3}"),
                       ["\\Seen", "\\Answered"])
        XCTAssertEqual(ImapParser.flags(in: "* 12 FETCH (FLAGS () UID 4827)"), [])
    }

    func testBodySectionPairing() {
        let headerLiteral = "From: a@b.c\r\n\r\n"
        let textLiteral = "the body"
        var buf = data(
            "* 7 FETCH (FLAGS (\\Seen) BODY[HEADER.FIELDS (FROM)] {\(headerLiteral.utf8.count)}\r\n"
            + headerLiteral
            + " BODY[TEXT] {\(textLiteral.utf8.count)}\r\n"
            + textLiteral
            + ")\r\n"
        )
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertEqual(lines.count, 1)
        let sections = ImapParser.bodySections(in: lines[0])
        XCTAssertEqual(sections.count, 2)
        XCTAssertTrue(sections[0].section.hasPrefix("HEADER"))
        XCTAssertEqual(String(decoding: sections[0].data, as: UTF8.self), headerLiteral)
        XCTAssertEqual(sections[1].section, "TEXT")
        XCTAssertEqual(String(decoding: sections[1].data, as: UTF8.self), textLiteral)
    }

    // MARK: - LIST

    func testListMailboxNames() {
        var buf = data("* LIST (\\HasNoChildren) \"/\" \"Sent Items\"\r\n* LIST (\\HasNoChildren) \"/\" INBOX\r\n")
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertEqual(ImapParser.listMailboxName(in: lines[0]), "Sent Items")
        XCTAssertEqual(ImapParser.listMailboxName(in: lines[1]), "INBOX")
    }

    func testListMailboxNameFromLiteral() {
        let name = "Projets divers"
        var buf = data("* LIST (\\HasNoChildren) \"/\" {\(name.utf8.count)}\r\n\(name)\r\n")
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(ImapParser.listMailboxName(in: lines[0]), name)
    }

    // MARK: - Headers

    func testParseHeadersWithFoldingAndEncodedWords() {
        let raw = """
        From: =?utf-8?B?QWNtZSBTdXBwbHk=?= <support@example.com>\r
        Subject: Re: order\r
         status update\r
        Date: Tue, 09 Jun 2026 14:03:22 -0400\r
        Message-ID: <abc123@mail.example.com>\r
        \r

        """
        let headers = ImapParser.parseHeaders(Data(raw.utf8))
        XCTAssertEqual(headers["from"], "Acme Supply <support@example.com>")
        XCTAssertEqual(headers["subject"], "Re: order status update")
        XCTAssertEqual(headers["message-id"], "<abc123@mail.example.com>")
    }

    func testDecodeEncodedWordsQAndAdjacent() {
        // Q encoding with underscores as spaces.
        XCTAssertEqual(ImapParser.decodeEncodedWords("=?utf-8?Q?Caf=C3=A9_open?="), "Café open")
        // Adjacent encoded words: separating whitespace drops.
        XCTAssertEqual(ImapParser.decodeEncodedWords("=?utf-8?B?SGVs?= =?utf-8?B?bG8=?="), "Hello")
        // Plain text passes through unchanged.
        XCTAssertEqual(ImapParser.decodeEncodedWords("nothing encoded here"), "nothing encoded here")
        // Latin-1 charset.
        XCTAssertEqual(ImapParser.decodeEncodedWords("=?iso-8859-1?Q?n=E9?="), "né")
    }

    func testQuotedPrintableDecoding() {
        XCTAssertEqual(ImapParser.decodeQuotedPrintable("Hello=2C world"), "Hello, world")
        // Soft line break vanishes.
        XCTAssertEqual(ImapParser.decodeQuotedPrintable("long li=\r\nne"), "long line")
        // UTF-8 multibyte.
        XCTAssertEqual(ImapParser.decodeQuotedPrintable("caf=C3=A9"), "café")
        // Stray '=' that is not a valid escape passes through.
        XCTAssertEqual(ImapParser.decodeQuotedPrintable("a=b"), "a=b")
    }

    // MARK: - Addresses + dates

    func testParseAddress() {
        let a = ImapParser.parseAddress("Jane Doe <jane@example.com>")
        XCTAssertEqual(a.name, "Jane Doe")
        XCTAssertEqual(a.email, "jane@example.com")

        let b = ImapParser.parseAddress("\"Doe, Jane\" <jane@example.com>")
        XCTAssertEqual(b.name, "Doe, Jane")
        XCTAssertEqual(b.email, "jane@example.com")

        let c = ImapParser.parseAddress("jane@example.com")
        XCTAssertEqual(c.name, "")
        XCTAssertEqual(c.email, "jane@example.com")
    }

    func testRFC5322DateParsing() {
        let d = ImapParser.rfc5322Date("Tue, 09 Jun 2026 14:03:22 -0400")
        XCTAssertNotNil(d)
        if let d {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "GMT")!
            let parts = cal.dateComponents([.year, .month, .day, .hour], from: d)
            XCTAssertEqual(parts.year, 2026)
            XCTAssertEqual(parts.month, 6)
            XCTAssertEqual(parts.day, 9)
            XCTAssertEqual(parts.hour, 18) // 14:03 -0400 == 18:03 GMT
        }
        // Comment suffix tolerated.
        XCTAssertNotNil(ImapParser.rfc5322Date("Tue, 09 Jun 2026 14:03:22 +0000 (UTC)"))
        XCTAssertNil(ImapParser.rfc5322Date("not a date"))
    }

    // MARK: - Body extraction

    func testPlainTextSinglePart() {
        let body = ImapParser.plainTextBody(
            raw: data("Hi Dana,\r\nThe order shipped.\r\n"),
            contentType: "text/plain; charset=utf-8",
            transferEncoding: "7bit"
        )
        XCTAssertEqual(body, "Hi Dana,\r\nThe order shipped.")
    }

    func testPlainTextBase64Part() {
        let original = "Order #4471 arrived damaged. Refund please."
        let encoded = Data(original.utf8).base64EncodedString()
        let body = ImapParser.plainTextBody(
            raw: data(encoded),
            contentType: "text/plain; charset=utf-8",
            transferEncoding: "base64"
        )
        XCTAssertEqual(body, original)
    }

    func testMultipartAlternativePrefersPlainText() {
        let boundary = "b0undary42"
        let mime = """
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        The plain part: caf=C3=A9.\r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body><p>The <b>HTML</b> part.</p></body></html>\r
        --\(boundary)--\r

        """
        let body = ImapParser.plainTextBody(
            raw: data(mime),
            contentType: "multipart/alternative; boundary=\"\(boundary)\"",
            transferEncoding: ""
        )
        XCTAssertTrue(body.contains("The plain part: café."), "got: \(body)")
        XCTAssertFalse(body.contains("<html>"))
    }

    func testMultipartHtmlOnlyFallsBackToStrippedHtml() {
        let boundary = "xyz"
        let mime = """
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        \r
        <html><body>Hello<br>world &amp; friends</body></html>\r
        --\(boundary)--\r

        """
        let body = ImapParser.plainTextBody(
            raw: data(mime),
            contentType: "multipart/alternative; boundary=\(boundary)",
            transferEncoding: ""
        )
        XCTAssertTrue(body.contains("Hello"))
        XCTAssertTrue(body.contains("world & friends"))
        XCTAssertFalse(body.contains("<br>"))
    }

    func testStripHTMLRemovesStyleBlocks() {
        let html = "<style>p { color: red; }</style><p>Visible</p><script>alert(1)</script>"
        let text = ImapParser.stripHTML(html)
        XCTAssertTrue(text.contains("Visible"))
        XCTAssertFalse(text.contains("color: red"))
        XCTAssertFalse(text.contains("alert"))
    }

    func testBoundaryAndCharsetParameters() {
        XCTAssertEqual(ImapParser.boundaryParameter("multipart/mixed; boundary=\"abc def\""), "abc def")
        XCTAssertEqual(ImapParser.boundaryParameter("multipart/mixed; boundary=simple"), "simple")
        XCTAssertNil(ImapParser.boundaryParameter("text/plain; charset=utf-8"))
        XCTAssertEqual(ImapParser.charsetParameter("text/plain; charset=ISO-8859-1"), "ISO-8859-1")
        XCTAssertEqual(ImapParser.charsetParameter("text/plain"), "utf-8")
    }

    // MARK: - Quoting (client side)

    func testQuoteEscapesSpecials() {
        XCTAssertEqual(IMAPClient.quote(#"pass"word\x"#), #""pass\"word\\x""#)
        XCTAssertEqual(IMAPClient.quote("plain"), "\"plain\"")
    }

    // MARK: - Dedupe ids

    func testEmailMessageDedupeIdStability() {
        let acct = UUID()
        let a = EmailMessage.dedupeId(accountId: acct, messageId: "<m1@x>", fromEmail: "a@b.c", subject: "S", date: nil)
        let b = EmailMessage.dedupeId(accountId: acct, messageId: "<m1@x>", fromEmail: "different@b.c", subject: "Other", date: Date())
        XCTAssertEqual(a, b, "same Message-ID must dedupe regardless of other fields")

        let c = EmailMessage.dedupeId(accountId: acct, messageId: "", fromEmail: "a@b.c", subject: "S", date: nil)
        let d = EmailMessage.dedupeId(accountId: acct, messageId: "", fromEmail: "a@b.c", subject: "S", date: nil)
        XCTAssertEqual(c, d, "synthetic ids must be deterministic")
        XCTAssertNotEqual(a, c)

        let otherAcct = EmailMessage.dedupeId(accountId: UUID(), messageId: "<m1@x>", fromEmail: "a@b.c", subject: "S", date: nil)
        XCTAssertNotEqual(a, otherAcct, "same message in two accounts stays distinct")
    }

    // MARK: - End-to-end transcript

    // A condensed but realistic full-session transcript: greeting, LOGIN,
    // SELECT, SEARCH UNSEEN, FETCH headers, FETCH body. Drains in one pass to
    // prove the framing layer handles a mixed stream.
    func testFullSessionTranscript() {
        let header = "From: Dana R. <dana@example.com>\r\nTo: support@example.com\r\nSubject: =?utf-8?Q?Order_never_showed_up?=\r\nDate: Mon, 08 Jun 2026 09:12:44 -0400\r\nMessage-ID: <ord-4471@example.com>\r\n\r\n"
        let bodyText = "Hi, I ordered the lavender forest body wash 9 days ago.\r\n"
        let transcript =
            "* OK The Microsoft Exchange IMAP4 service is ready.\r\n"
            + "A001 OK LOGIN completed.\r\n"
            + "* 23 EXISTS\r\n"
            + "* 0 RECENT\r\n"
            + "A002 OK [READ-WRITE] SELECT completed.\r\n"
            + "* SEARCH 21 23\r\n"
            + "A003 OK SEARCH completed.\r\n"
            + "* 23 FETCH (FLAGS () BODY[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)] {\(header.utf8.count)}\r\n"
            + header
            + ")\r\n"
            + "A004 OK FETCH completed.\r\n"
            + "* 23 FETCH (BODY[HEADER.FIELDS (CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] {25}\r\n"
            + "Content-Type: text/plain\r\n"
            + " BODY[TEXT] {\(bodyText.utf8.count)}\r\n"
            + bodyText
            + ")\r\n"
            + "A005 OK FETCH completed.\r\n"

        var buf = data(transcript)
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertTrue(buf.isEmpty)
        XCTAssertEqual(lines.count, 11)

        // SEARCH result.
        let unseen = lines.flatMap { ImapParser.searchNumbers(in: $0.text) }
        XCTAssertEqual(unseen, [21, 23])

        // Header FETCH.
        let headerLine = lines.first { ImapParser.fetchSequenceNumber(in: $0.text) == 23 && $0.literals.count == 1 }
        XCTAssertNotNil(headerLine)
        if let headerLine {
            let sections = ImapParser.bodySections(in: headerLine)
            XCTAssertEqual(sections.count, 1)
            let headers = ImapParser.parseHeaders(sections[0].data)
            XCTAssertEqual(headers["subject"], "Order never showed up")
            let (name, email) = ImapParser.parseAddress(headers["from"] ?? "")
            XCTAssertEqual(name, "Dana R.")
            XCTAssertEqual(email, "dana@example.com")
            XCTAssertNotNil(ImapParser.rfc5322Date(headers["date"] ?? ""))
        }

        // Body FETCH (two literals on one logical line).
        let bodyLine = lines.first { $0.literals.count == 2 }
        XCTAssertNotNil(bodyLine)
        if let bodyLine {
            let sections = ImapParser.bodySections(in: bodyLine)
            XCTAssertEqual(sections.count, 2)
            XCTAssertTrue(sections[0].section.hasPrefix("HEADER"))
            XCTAssertEqual(sections[1].section, "TEXT")
            let text = ImapParser.plainTextBody(
                raw: sections[1].data,
                contentType: "text/plain",
                transferEncoding: ""
            )
            XCTAssertTrue(text.contains("lavender forest body wash"))
        }
    }

    // A hostile/buggy server can declare an absurd literal length. The old
    // code computed litStart + literalLen directly and trapped on overflow
    // (SIGTRAP), crashing the whole app. Now the oversized literal is rejected
    // and its bytes are left buffered for the (never-arriving) rest, so the
    // call returns cleanly with no complete line.
    func testOversizedLiteralLengthDoesNotCrash() {
        var buf = Data("* 1 FETCH (BODY[TEXT] {9223372036854775807}\r\n".utf8)
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertTrue(lines.isEmpty, "oversized literal must not yield a completed line")
        // Bytes stay buffered (the literal never completes); no crash.
        XCTAssertFalse(buf.isEmpty)
    }

    // A merely-large (non-overflowing) literal beyond the sane cap is also
    // refused rather than buffered to exhaustion.
    func testLiteralBeyondCapIsRejected() {
        var buf = Data("* 1 FETCH (BODY[TEXT] {2000000000}\r\nshort body\r\n".utf8)
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertTrue(lines.isEmpty, "literal above maxLiteralBytes must not complete")
    }

    // A literal within the cap still parses normally (regression guard).
    func testNormalLiteralStillParses() {
        var buf = Data("* 1 FETCH (BODY[TEXT] {5}\r\nhello\r\n".utf8)
        let lines = ImapParser.drainLogicalLines(&buf)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.literals.first, Data("hello".utf8))
    }
}
