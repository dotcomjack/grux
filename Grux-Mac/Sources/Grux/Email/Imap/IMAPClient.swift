import Foundation
import Network

// Minimal RFC 3501 IMAP4 client over Network.framework with TLS. Zero
// third-party dependencies, matching the no-third-party-HTTP convention the
// rest of Grux uses (Claude.swift, ResendClient.swift).
//
// Scope (pragmatic, per the roadmap brief): LOGIN, LIST, SELECT, SEARCH
// UNSEEN, FETCH headers + body text, LOGOUT. IDLE is intentionally NOT
// implemented; InboxSyncEngine polls on a timer instead, which is simpler,
// survives sleep/wake, and is plenty for a personal multi-account inbox.
//
// Connection model: one actor per connection. Commands run strictly
// sequentially (actor isolation guarantees it), each command sends a tagged
// line and reads logical lines until its tagged completion arrives. All
// protocol parsing lives in ImapParser so it stays unit-testable offline.
//
// Auth note: most providers need an app password (Gmail, Fastmail) or basic
// auth enabled (M365). We do plain LOGIN over TLS; OAUTHBEARER/XOAUTH2 is out
// of scope for v1 and surfaces as a clear loginFailed error.
actor IMAPClient {

    enum IMAPError: Error, LocalizedError {
        case notConnected
        case connectFailed(String)
        case timeout(String)
        case loginFailed(String)
        case commandFailed(String, String)
        case serverClosed

        var errorDescription: String? {
            switch self {
            case .notConnected: return "IMAP: not connected."
            case .connectFailed(let s): return "IMAP connect failed: \(s)"
            case .timeout(let what): return "IMAP timed out (\(what))."
            case .loginFailed(let s): return "IMAP login failed: \(s.isEmpty ? "check username and app password" : s)"
            case .commandFailed(let cmd, let info): return "IMAP \(cmd) failed: \(info)"
            case .serverClosed: return "IMAP: server closed the connection."
            }
        }
    }

    // One fetched message summary (headers only; body fetched separately so
    // the sync engine can skip bodies for messages it already has).
    struct FetchedHeader {
        let sequenceNumber: Int
        let messageId: String
        let fromName: String
        let fromEmail: String
        let to: String
        let subject: String
        let date: Date?
        let flags: [String]

        var isUnseen: Bool { !flags.contains(where: { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }) }
    }

    private let host: String
    private let port: UInt16
    private let useTLS: Bool

    private var connection: NWConnection?
    private var buffer = Data()
    private var lineQueue: [ImapParser.LogicalLine] = []
    private var tagCounter = 0

    init(host: String, port: UInt16 = 993, useTLS: Bool = true) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
    }

    // MARK: - Lifecycle

    func connect(timeout: TimeInterval = 15) async throws {
        guard connection == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw IMAPError.connectFailed("bad port \(port)")
        }
        let params: NWParameters
        if useTLS {
            params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        connection = conn

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.once { cont.resume() }
                case .failed(let error):
                    gate.once { cont.resume(throwing: IMAPError.connectFailed(error.localizedDescription)) }
                case .cancelled:
                    gate.once { cont.resume(throwing: IMAPError.connectFailed("cancelled")) }
                default:
                    break
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.once {
                    conn.cancel()
                    cont.resume(throwing: IMAPError.timeout("connect to \(self.host):\(self.port)"))
                }
            }
            conn.start(queue: .global(qos: .userInitiated))
        }
        // Late state changes (e.g. the server dropping us mid-session) are
        // surfaced through receive errors, so the handler can go quiet now.
        conn.stateUpdateHandler = nil

        // Server greeting: "* OK ..." (or "* PREAUTH ..." on rare setups).
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let line = try await nextLine(deadline: deadline)
            let upper = line.text.uppercased()
            if upper.hasPrefix("* OK") || upper.hasPrefix("* PREAUTH") { break }
            if upper.hasPrefix("* BYE") { throw IMAPError.connectFailed(line.text) }
        }
    }

    func close() {
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        lineQueue.removeAll()
    }

    // MARK: - Commands

    func login(username: String, password: String) async throws {
        let result = try await runCommand("LOGIN \(Self.quote(username)) \(Self.quote(password))", timeout: 20)
        guard result.status.isOK else { throw IMAPError.loginFailed(result.status.info) }
    }

    func listMailboxes() async throws -> [String] {
        let result = try await runCommand("LIST \"\" \"*\"", timeout: 20)
        guard result.status.isOK else { throw IMAPError.commandFailed("LIST", result.status.info) }
        return result.untagged.compactMap { ImapParser.listMailboxName(in: $0) }
    }

    // Selects a mailbox; returns the EXISTS message count.
    @discardableResult
    func select(_ mailbox: String = "INBOX") async throws -> Int {
        let result = try await runCommand("SELECT \(Self.quote(mailbox))", timeout: 20)
        guard result.status.isOK else { throw IMAPError.commandFailed("SELECT \(mailbox)", result.status.info) }
        for line in result.untagged {
            if let n = ImapParser.existsCount(in: line.text) { return n }
        }
        return 0
    }

    func searchUnseen() async throws -> [Int] {
        let result = try await runCommand("SEARCH UNSEEN", timeout: 30)
        guard result.status.isOK else { throw IMAPError.commandFailed("SEARCH UNSEEN", result.status.info) }
        var numbers: [Int] = []
        for line in result.untagged {
            numbers.append(contentsOf: ImapParser.searchNumbers(in: line.text))
        }
        return numbers.sorted()
    }

    // Fetches header summaries for the given sequence numbers. Uses
    // BODY.PEEK so messages stay unread on the server.
    func fetchHeaders(sequenceNumbers: [Int]) async throws -> [FetchedHeader] {
        guard !sequenceNumbers.isEmpty else { return [] }
        let set = sequenceNumbers.map(String.init).joined(separator: ",")
        let cmd = "FETCH \(set) (FLAGS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE MESSAGE-ID)])"
        let result = try await runCommand(cmd, timeout: 60)
        guard result.status.isOK else { throw IMAPError.commandFailed("FETCH headers", result.status.info) }

        var out: [FetchedHeader] = []
        for line in result.untagged {
            guard let seq = ImapParser.fetchSequenceNumber(in: line.text) else { continue }
            guard let headerData = ImapParser.bodySections(in: line).first(where: { $0.section.hasPrefix("HEADER") })?.data else { continue }
            let headers = ImapParser.parseHeaders(headerData)
            let (name, email) = ImapParser.parseAddress(headers["from"] ?? "")
            out.append(FetchedHeader(
                sequenceNumber: seq,
                messageId: (headers["message-id"] ?? "").trimmingCharacters(in: .whitespaces),
                fromName: name,
                fromEmail: email,
                to: headers["to"] ?? "",
                subject: headers["subject"] ?? "(no subject)",
                date: ImapParser.rfc5322Date(headers["date"] ?? ""),
                flags: ImapParser.flags(in: line.text)
            ))
        }
        return out
    }

    // Fetches the message body as best-effort plain text (multipart-aware).
    func fetchBodyText(sequenceNumber: Int) async throws -> String {
        let cmd = "FETCH \(sequenceNumber) (BODY.PEEK[HEADER.FIELDS (CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT])"
        let result = try await runCommand(cmd, timeout: 60)
        guard result.status.isOK else { throw IMAPError.commandFailed("FETCH body", result.status.info) }

        var contentType = "text/plain"
        var transferEncoding = ""
        var bodyData = Data()
        for line in result.untagged {
            guard ImapParser.fetchSequenceNumber(in: line.text) != nil else { continue }
            for (section, data) in ImapParser.bodySections(in: line) {
                if section.hasPrefix("HEADER") {
                    let headers = ImapParser.parseHeaders(data)
                    contentType = headers["content-type"] ?? contentType
                    transferEncoding = headers["content-transfer-encoding"] ?? transferEncoding
                } else if section.hasPrefix("TEXT") {
                    bodyData = data
                }
            }
        }
        guard !bodyData.isEmpty else { return "" }
        return ImapParser.plainTextBody(raw: bodyData, contentType: contentType, transferEncoding: transferEncoding)
    }

    func logout() async {
        _ = try? await runCommand("LOGOUT", timeout: 10)
        close()
    }

    // MARK: - Wire plumbing

    private struct CommandResult {
        let untagged: [ImapParser.LogicalLine]
        let status: ImapParser.TaggedStatus
    }

    private func runCommand(_ command: String, timeout: TimeInterval) async throws -> CommandResult {
        guard let conn = connection else { throw IMAPError.notConnected }
        tagCounter += 1
        let tag = String(format: "A%03d", tagCounter)
        try await sendRaw("\(tag) \(command)\r\n", over: conn)

        let deadline = Date().addingTimeInterval(timeout)
        var untagged: [ImapParser.LogicalLine] = []
        while true {
            let line = try await nextLine(deadline: deadline)
            if let status = ImapParser.taggedStatus(line: line.text, tag: tag) {
                return CommandResult(untagged: untagged, status: status)
            }
            // "+ " continuation requests should not occur for the commands we
            // issue (no client literals); ignore them defensively.
            if line.text.hasPrefix("+") { continue }
            untagged.append(line)
        }
    }

    private func nextLine(deadline: Date) async throws -> ImapParser.LogicalLine {
        while true {
            if !lineQueue.isEmpty { return lineQueue.removeFirst() }
            let drained = ImapParser.drainLogicalLines(&buffer)
            if !drained.isEmpty {
                lineQueue.append(contentsOf: drained)
                continue
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                close()
                throw IMAPError.timeout("read")
            }
            buffer.append(try await receiveChunk(timeout: remaining))
        }
    }

    private func receiveChunk(timeout: TimeInterval) async throws -> Data {
        guard let conn = connection else { throw IMAPError.notConnected }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let gate = ResumeGate()
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                gate.once {
                    if let error {
                        cont.resume(throwing: IMAPError.connectFailed(error.localizedDescription))
                    } else if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: IMAPError.serverClosed)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                gate.once {
                    conn.cancel()
                    cont.resume(throwing: IMAPError.timeout("read"))
                }
            }
        }
    }

    private func sendRaw(_ s: String, over conn: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = ResumeGate()
            conn.send(content: Data(s.utf8), completion: .contentProcessed { error in
                gate.once {
                    if let error {
                        cont.resume(throwing: IMAPError.connectFailed(error.localizedDescription))
                    } else {
                        cont.resume()
                    }
                }
            })
        }
    }

    // RFC 3501 quoted string. Sufficient for real-world usernames, passwords,
    // and mailbox names; characters that would require a literal are rare in
    // those and surface as a NO/BAD we report cleanly.
    static func quote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        + "\""
    }
}

// Ensures a CheckedContinuation resumes exactly once even when an NW callback
// races the timeout timer. NWConnection callbacks run off-actor, hence the
// lock instead of actor isolation.
private final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func once(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
