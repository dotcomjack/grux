import Foundation

// Pure RFC 3501 / RFC 2047 / RFC 2045 response parsing for the minimal IMAP
// client. Zero networking in this file so every function is unit-testable
// against canned server transcripts (see ImapParserTests).
//
// Pragmatic scope, per the roadmap brief: a clean reliable fetch path beats
// full RFC coverage. We handle the response shapes real servers (Fastmail,
// Gmail, M365, Dovecot) emit for LOGIN / LIST / SELECT / SEARCH / FETCH and
// the header encodings that actually occur in the wild (encoded-words,
// quoted-printable, base64, simple multipart). Exotic constructs degrade to
// raw text instead of crashing.
enum ImapParser {

    // One logical server response line. IMAP lines can embed length-prefixed
    // literals ({N}\r\n<N bytes>) mid-line; `text` is the concatenated
    // non-literal segments (the {N} markers stay in place as anchors) and
    // `literals` holds the raw literal payloads in order of appearance.
    struct LogicalLine: Equatable {
        var text: String
        var literals: [Data]
    }

    enum TaggedStatus: Equatable {
        case ok(String)
        case no(String)
        case bad(String)

        var isOK: Bool { if case .ok = self { return true }; return false }
        var info: String {
            switch self {
            case .ok(let s), .no(let s), .bad(let s): return s
            }
        }
    }

    // MARK: - Logical line framing

    // Pulls every COMPLETE logical line off the front of `buffer`, leaving any
    // partial trailing data (including an incomplete literal) in place for the
    // next network read.
    // Upper bound on a single IMAP literal. A literal larger than this is
    // treated as a malformed/hostile response: we stop draining and leave the
    // bytes in the buffer rather than trusting a 64-bit length from the wire
    // (an unbounded length both overflows litStart + literalLen and invites a
    // memory-exhaustion DoS). 64 MB comfortably covers real message bodies.
    static let maxLiteralBytes = 64 * 1024 * 1024

    static func drainLogicalLines(_ buffer: inout Data) -> [LogicalLine] {
        let d = Data(buffer) // fresh copy gives zero-based integer indices
        var lines: [LogicalLine] = []
        var consumed = 0

        while true {
            var cursor = consumed
            var segments: [String] = []
            var literals: [Data] = []
            var complete = false

            scan: while true {
                guard let crlf = findCRLF(in: d, from: cursor) else { break scan }
                let segment = String(decoding: d.subdata(in: cursor..<crlf), as: UTF8.self)
                if let literalLen = trailingLiteralCount(segment) {
                    // Reject a negative or absurd length before doing pointer
                    // math: a hostile server can claim {9223372036854775807}
                    // and overflow litStart + literalLen into a trap.
                    guard literalLen >= 0, literalLen <= Self.maxLiteralBytes else { break scan }
                    let litStart = crlf + 2
                    let (litEnd, overflow) = litStart.addingReportingOverflow(literalLen)
                    guard !overflow, litEnd <= d.count else { break scan } // literal not fully buffered yet
                    segments.append(segment)
                    literals.append(d.subdata(in: litStart..<litEnd))
                    cursor = litEnd
                } else {
                    segments.append(segment)
                    cursor = crlf + 2
                    complete = true
                    break scan
                }
            }

            guard complete else { break }
            lines.append(LogicalLine(text: segments.joined(), literals: literals))
            consumed = cursor
        }

        if consumed > 0 {
            buffer = d.subdata(in: consumed..<d.count)
        }
        return lines
    }

    private static func findCRLF(in d: Data, from start: Int) -> Int? {
        guard d.count >= 2 else { return nil }
        var i = max(0, start)
        while i < d.count - 1 {
            if d[i] == 0x0D && d[i + 1] == 0x0A { return i }
            i += 1
        }
        return nil
    }

    // "{123}" or "{123+}" at end of segment -> 123.
    static func trailingLiteralCount(_ segment: String) -> Int? {
        guard segment.hasSuffix("}"), let open = segment.lastIndex(of: "{") else { return nil }
        var inner = String(segment[segment.index(after: open)..<segment.index(before: segment.endIndex)])
        if inner.hasSuffix("+") { inner = String(inner.dropLast()) }
        guard !inner.isEmpty, inner.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(inner)
    }

    // MARK: - Status / untagged dispatch

    // "A003 OK [READ-WRITE] SELECT completed." -> .ok("[READ-WRITE] SELECT completed.")
    static func taggedStatus(line: String, tag: String) -> TaggedStatus? {
        guard line.hasPrefix(tag + " ") else { return nil }
        let rest = String(line.dropFirst(tag.count + 1))
        let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let word = parts.first else { return nil }
        let info = parts.count > 1 ? String(parts[1]) : ""
        switch word.uppercased() {
        case "OK": return .ok(info)
        case "NO": return .no(info)
        case "BAD": return .bad(info)
        default: return nil
        }
    }

    // "* SEARCH 2 84 882" -> [2, 84, 882]
    static func searchNumbers(in line: String) -> [Int] {
        let upper = line.uppercased()
        guard upper.hasPrefix("* SEARCH") else { return [] }
        return line.split(separator: " ").compactMap { Int($0) }
    }

    // "* 12 FETCH (...)" -> 12 ; "* 23 EXISTS" -> nil
    static func fetchSequenceNumber(in line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "*", parts[2].uppercased() == "FETCH" else { return nil }
        return Int(parts[1])
    }

    // "* 23 EXISTS" -> 23
    static func existsCount(in line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard parts.count >= 3, parts[0] == "*", parts[2].uppercased() == "EXISTS" else { return nil }
        return Int(parts[1])
    }

    // Pairs each BODY[...] token in a FETCH response with its literal, in
    // order. Our FETCH commands always request literal-returning sections, so
    // positional pairing is reliable for the shapes we issue.
    static func bodySections(in line: LogicalLine) -> [(section: String, data: Data)] {
        var result: [(String, Data)] = []
        var searchFrom = line.text.startIndex
        var litIndex = 0
        while litIndex < line.literals.count,
              let r = line.text.range(of: "BODY[", options: [.caseInsensitive], range: searchFrom..<line.text.endIndex) {
            guard let close = line.text.range(of: "]", range: r.upperBound..<line.text.endIndex) else { break }
            let section = String(line.text[r.upperBound..<close.lowerBound]).uppercased()
            result.append((section, line.literals[litIndex]))
            litIndex += 1
            searchFrom = close.upperBound
        }
        return result
    }

    // "FLAGS (\Seen \Answered)" -> ["\\Seen", "\\Answered"]
    static func flags(in text: String) -> [String] {
        guard let r = text.range(of: "FLAGS (", options: [.caseInsensitive]),
              let close = text.range(of: ")", range: r.upperBound..<text.endIndex) else { return [] }
        return text[r.upperBound..<close.lowerBound]
            .split(separator: " ")
            .map(String.init)
    }

    // Mailbox name from a LIST response:
    //   * LIST (\HasNoChildren) "/" "Sent Items"   -> Sent Items
    //   * LIST (\HasNoChildren) "/" INBOX          -> INBOX
    //   * LIST (\HasNoChildren) "/" {5}<literal>   -> literal contents
    static func listMailboxName(in line: LogicalLine) -> String? {
        let upper = line.text.uppercased()
        guard upper.hasPrefix("* LIST") || upper.hasPrefix("* LSUB") else { return nil }
        if let lit = line.literals.last {
            return String(decoding: lit, as: UTF8.self)
        }
        let text = line.text
        // Last quoted string on the line is the mailbox (the delimiter is also
        // quoted, so require it to come after the closing paren of the flags).
        guard let parenClose = text.range(of: ")") else { return nil }
        let tail = String(text[parenClose.upperBound...]).trimmingCharacters(in: .whitespaces)
        // tail looks like: "/" "Sent Items"   or   "/" INBOX   or  NIL INBOX
        let afterDelimiter: String
        if tail.hasPrefix("\"") {
            // skip the quoted delimiter
            guard let secondQuote = tail.dropFirst().firstIndex(of: "\"") else { return nil }
            afterDelimiter = String(tail[tail.index(after: secondQuote)...]).trimmingCharacters(in: .whitespaces)
        } else {
            // unquoted delimiter atom (or NIL)
            let parts = tail.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            afterDelimiter = String(parts[1]).trimmingCharacters(in: .whitespaces)
        }
        if afterDelimiter.hasPrefix("\"") && afterDelimiter.hasSuffix("\"") && afterDelimiter.count >= 2 {
            return String(afterDelimiter.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return afterDelimiter.isEmpty ? nil : afterDelimiter
    }

    // MARK: - RFC 5322 headers

    // Parses a HEADER.FIELDS literal into lowercased name -> decoded value.
    // Handles folded continuation lines and RFC 2047 encoded words.
    static func parseHeaders(_ data: Data) -> [String: String] {
        let raw = decodeBytes(Array(data))
        var unfolded: [String] = []
        for line in raw.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if let first = s.first, first == " " || first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + s.trimmingCharacters(in: .whitespaces)
            } else if !s.isEmpty {
                unfolded.append(s)
            }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = decodeEncodedWords(value)
        }
        return headers
    }

    // MARK: - RFC 2047 encoded words

    // Decodes "=?utf-8?B?...?=" and "=?utf-8?Q?...?=" runs inside a header
    // value. Whitespace between two adjacent encoded words is dropped per the
    // RFC; everything else passes through untouched.
    static func decodeEncodedWords(_ value: String) -> String {
        guard value.contains("=?") else { return value }
        // Adjacent encoded words separated only by whitespace join directly.
        var s = value
        if let collapse = try? NSRegularExpression(pattern: #"(\?=)\s+(=\?)"#) {
            s = collapse.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2")
        }
        guard let rx = try? NSRegularExpression(pattern: #"=\?([^? ]+)\?([BbQq])\?([^? ]*)\?="#) else { return s }
        var out = ""
        var last = s.startIndex
        for m in rx.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let whole = Range(m.range, in: s),
                  let charsetR = Range(m.range(at: 1), in: s),
                  let encR = Range(m.range(at: 2), in: s),
                  let payloadR = Range(m.range(at: 3), in: s) else { continue }
            out += s[last..<whole.lowerBound]
            let charset = String(s[charsetR])
            let enc = String(s[encR]).uppercased()
            let payload = String(s[payloadR])
            if enc == "B" {
                if let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) {
                    out += decodeBytes(Array(data), charset: charset)
                } else {
                    out += s[whole]
                }
            } else {
                out += decodeQuotedPrintable(payload, underscoreIsSpace: true, charset: charset)
            }
            last = whole.upperBound
        }
        out += s[last...]
        return out
    }

    // MARK: - Quoted-printable (RFC 2045 section 6.7 + RFC 2047 Q)

    static func decodeQuotedPrintable(_ s: String, underscoreIsSpace: Bool = false, charset: String = "utf-8") -> String {
        let bytes = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "=") {
                // soft line break "=\r\n" or "=\n"
                if i + 2 < bytes.count, bytes[i + 1] == 0x0D, bytes[i + 2] == 0x0A {
                    i += 3
                    continue
                }
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A {
                    i += 2
                    continue
                }
                if i + 2 < bytes.count,
                   let hi = hexValue(bytes[i + 1]), let lo = hexValue(bytes[i + 2]) {
                    out.append(UInt8(hi << 4 | lo))
                    i += 3
                    continue
                }
                out.append(b)
                i += 1
            } else if underscoreIsSpace && b == UInt8(ascii: "_") {
                out.append(0x20)
                i += 1
            } else {
                out.append(b)
                i += 1
            }
        }
        return decodeBytes(out, charset: charset)
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(b - UInt8(ascii: "0"))
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(b - UInt8(ascii: "A")) + 10
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(b - UInt8(ascii: "a")) + 10
        default: return nil
        }
    }

    // Decode bytes in a named charset, defaulting to UTF-8 with a Latin-1
    // fallback (Latin-1 maps every byte, so this never returns garbage-empty).
    static func decodeBytes(_ bytes: [UInt8], charset: String = "utf-8") -> String {
        let data = Data(bytes)
        let cs = charset.lowercased()
        let encoding: String.Encoding
        if cs.contains("utf-8") || cs.contains("utf8") || cs.contains("ascii") {
            encoding = .utf8
        } else if cs.contains("8859-1") || cs.contains("latin") {
            encoding = .isoLatin1
        } else if cs.contains("1252") {
            encoding = .windowsCP1252
        } else if cs.contains("utf-16") {
            encoding = .utf16
        } else {
            encoding = .utf8
        }
        return String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    // MARK: - Addresses

    // "Jane Doe <jane@example.com>" -> ("Jane Doe", "jane@example.com")
    // "jane@example.com"            -> ("", "jane@example.com")
    static func parseAddress(_ s: String) -> (name: String, email: String) {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
            let email = String(trimmed[trimmed.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var name = String(trimmed[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            }
            return (name, email)
        }
        if trimmed.contains("@") { return ("", trimmed) }
        return (trimmed, "")
    }

    // MARK: - Dates

    private static let dateFormats = [
        "EEE, dd MMM yyyy HH:mm:ss Z",
        "dd MMM yyyy HH:mm:ss Z",
        "EEE, dd MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss Z"
    ]

    static func rfc5322Date(_ s: String) -> Date? {
        // Strip trailing comments like "(UTC)" / "(PDT)".
        var cleaned = s.trimmingCharacters(in: .whitespaces)
        if let paren = cleaned.firstIndex(of: "(") {
            cleaned = String(cleaned[..<paren]).trimmingCharacters(in: .whitespaces)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        for fmt in dateFormats {
            f.dateFormat = fmt
            if let d = f.date(from: cleaned) { return d }
        }
        return nil
    }

    // MARK: - Body text extraction

    // Best-effort plain text out of a BODY[TEXT] literal given the message's
    // Content-Type and Content-Transfer-Encoding headers. Handles single-part
    // text/plain and text/html plus one or two levels of multipart nesting
    // (mixed wrapping alternative is the common real-world shape).
    static func plainTextBody(raw: Data, contentType: String, transferEncoding: String) -> String {
        let ct = contentType.lowercased()
        if ct.contains("multipart"), let boundary = boundaryParameter(contentType) {
            if let best = bestTextPart(raw: raw, boundary: boundary, depth: 0) {
                return best.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let decoded = decodeTransfer(raw: raw, encoding: transferEncoding, charset: charsetParameter(contentType))
        if ct.contains("text/html") {
            return stripHTML(decoded).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func boundaryParameter(_ contentType: String) -> String? {
        parameter("boundary", in: contentType)
    }

    static func charsetParameter(_ contentType: String) -> String {
        parameter("charset", in: contentType) ?? "utf-8"
    }

    private static func parameter(_ name: String, in headerValue: String) -> String? {
        guard let r = headerValue.range(of: name + "=", options: [.caseInsensitive]) else { return nil }
        var rest = String(headerValue[r.upperBound...])
        if rest.hasPrefix("\"") {
            rest = String(rest.dropFirst())
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
        let end = rest.firstIndex(where: { $0 == ";" || $0 == " " || $0 == "\r" || $0 == "\n" }) ?? rest.endIndex
        let v = String(rest[..<end]).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    // Walks multipart parts, preferring text/plain, falling back to stripped
    // text/html, recursing into nested multiparts (capped at depth 3).
    private static func bestTextPart(raw: Data, boundary: String, depth: Int) -> String? {
        guard depth < 3 else { return nil }
        let body = decodeBytes(Array(raw))
        let marker = "--" + boundary
        let chunks = body.components(separatedBy: marker)
        var htmlFallback: String?
        for chunk in chunks {
            let trimmed = chunk.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
            guard !trimmed.isEmpty, !trimmed.hasPrefix("--") else { continue }
            let (partHeaders, partBody) = splitPart(trimmed)
            let partCT = (partHeaders["content-type"] ?? "text/plain").lowercased()
            let partCTE = partHeaders["content-transfer-encoding"] ?? ""
            if partCT.contains("multipart"), let inner = boundaryParameter(partHeaders["content-type"] ?? "") {
                if let nested = bestTextPart(raw: Data(partBody.utf8), boundary: inner, depth: depth + 1) {
                    return nested
                }
                continue
            }
            if partCT.contains("text/plain") {
                return decodeTransfer(raw: Data(partBody.utf8), encoding: partCTE,
                                      charset: charsetParameter(partHeaders["content-type"] ?? ""))
            }
            if partCT.contains("text/html") && htmlFallback == nil {
                let decoded = decodeTransfer(raw: Data(partBody.utf8), encoding: partCTE,
                                             charset: charsetParameter(partHeaders["content-type"] ?? ""))
                htmlFallback = stripHTML(decoded)
            }
        }
        return htmlFallback
    }

    // Splits a MIME part into (headers, body) at the first blank line.
    private static func splitPart(_ part: String) -> ([String: String], String) {
        let normalized = part.replacingOccurrences(of: "\r\n", with: "\n")
        guard let blank = normalized.range(of: "\n\n") else {
            return ([:], part)
        }
        let headerBlock = String(normalized[..<blank.lowerBound])
        let body = String(normalized[blank.upperBound...])
        return (parseHeaders(Data(headerBlock.utf8)), body)
    }

    static func decodeTransfer(raw: Data, encoding: String, charset: String = "utf-8") -> String {
        let enc = encoding.lowercased()
        if enc.contains("base64") {
            let compact = String(decoding: raw, as: UTF8.self)
                .components(separatedBy: .whitespacesAndNewlines).joined()
            if let data = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]) {
                return decodeBytes(Array(data), charset: charset)
            }
        }
        if enc.contains("quoted-printable") {
            return decodeQuotedPrintable(String(decoding: raw, as: UTF8.self), charset: charset)
        }
        return decodeBytes(Array(raw), charset: charset)
    }

    // Crude but dependable HTML to text: drop script/style blocks, turn the
    // common block-level closers into newlines, strip remaining tags, decode
    // the entities that matter in email bodies.
    static func stripHTML(_ html: String) -> String {
        var s = html
        for block in ["script", "style", "head"] {
            while let open = s.range(of: "<\(block)", options: [.caseInsensitive]),
                  let close = s.range(of: "</\(block)>", options: [.caseInsensitive], range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            }
        }
        for breaker in ["<br>", "<br/>", "<br />", "</p>", "</div>", "</tr>", "</li>", "</h1>", "</h2>", "</h3>"] {
            s = s.replacingOccurrences(of: breaker, with: "\n", options: [.caseInsensitive])
        }
        if let rx = try? NSRegularExpression(pattern: "<[^>]+>") {
            s = rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        let entities: [(String, String)] = [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")
        ]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Collapse runaway blank lines.
        while s.contains("\n\n\n") { s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return s
    }
}
