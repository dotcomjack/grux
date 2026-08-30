import Foundation
import Network
import OSLog

// Grux's inbound HTTP control surface. A tiny, dependency-free HTTP/1.1 server
// over NWListener so a companion PR-digest service on the local network can
// PUSH the nightly open-PR digest straight into Grux the moment it is built.
//
// This is the "/api/inbox" endpoint the spec asks Grux to expose. Like the
// iPhone receiver it accepts connections from the private network, but on a
// FIXED port rather than a kernel-assigned one, because the pushing service has
// to know where to aim. Two things keep that safe:
//   1. A bearer token (shared secret in ~/.grux/pr-inbox-token.txt, 0600). A
//      POST without the matching token gets 401. The pushing service reads the
//      same token from its own gitignored .env.
//   2. The only mutation it allows is "replace the cached PR digest with a newer
//      one" (PRDigestStore.ingest rejects anything not strictly newer). Worst
//      case for a tailnet/LAN attacker is a stale-looking PR list, never code
//      execution or data exfiltration.
//
// Routes:
//   POST /api/inbox   (Bearer auth) -> body is a PRDigest JSON -> ingest()
//   GET  /health                    -> liveness JSON
//
// Port 3852 mirrors the digest service's own port (same number, the two ends
// of one pipeline, different hosts).
//
// Concurrency: lifecycle (start/listener/boundPort) is MainActor; the per-
// connection HTTP handling is nonisolated and runs on the network queue,
// hopping back to MainActor only to read/mutate the MainActor-isolated
// PRDigestStore.

final class PRInboxServer {
    static let shared = PRInboxServer()

    static let port: UInt16 = 3852
    private static let log = Logger(subsystem: "com.gruxai.grux", category: "PRInbox")
    private static let maxBodyBytes = 4 * 1024 * 1024

    @MainActor private var listener: NWListener?
    @MainActor private(set) var boundPort: UInt16 = 0

    private init() {}

    // Shared-secret token file (~/.grux/pr-inbox-token.txt). Created on first
    // read if absent so Grux is self-sufficient; the deploy script syncs the
    // same value to the companion service. nonisolated: pure file I/O, no actor state.
    private static var tokenURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pr-inbox-token.txt")
    }

    static func expectedToken() -> String {
        if let s = try? String(contentsOf: tokenURL, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            // Never mint an all-zero (predictable) token. Fall back to the RAW
            // bytes of two UUIDs (32 bytes total), not their hex strings, so we
            // keep real entropy instead of 32 ASCII chars drawn from 16 values.
            var u1 = UUID().uuid
            var u2 = UUID().uuid
            let raw = withUnsafeBytes(of: &u1) { Array($0) } + withUnsafeBytes(of: &u2) { Array($0) }
            bytes = Array(raw.prefix(32))
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        // Create the file 0600 up front so the secret never sits world-readable
        // in the gap between write and chmod.
        FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return token
    }

    @MainActor
    func start() {
        guard listener == nil else { return }
        let token = Self.expectedToken()   // ensure the file exists for the companion service

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // No requiredInterfaceType: bind all interfaces so the companion service
        // can reach us over the private network (and LAN). Auth + newer-only ingest are the guard.

        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }
        let l: NWListener
        do {
            l = try NWListener(using: params, on: port)
        } catch {
            // EADDRINUSE or similar: log and rely on the PULL fallback. The
            // dashboard still pulls from the companion service, so a busy port is not fatal.
            Self.log.error("PRInbox listener init failed on :\(Self.port, privacy: .public): \(String(describing: error), privacy: .public)")
            WakeLog.shared.log("pr-inbox: listener init failed (\(error.localizedDescription)); pull fallback still active")
            return
        }

        l.stateUpdateHandler = { st in
            switch st {
            case .ready:
                Task { @MainActor in
                    PRInboxServer.shared.boundPort = PRInboxServer.port
                    PRInboxServer.log.log("PRInbox listening on :\(PRInboxServer.port, privacy: .public)")
                }
            case .failed(let err):
                PRInboxServer.log.error("PRInbox listener failed: \(String(describing: err), privacy: .public)")
            default:
                break
            }
        }
        l.newConnectionHandler = { conn in
            Self.accept(conn, token: token)
        }
        l.start(queue: .global(qos: .utility))
        self.listener = l
    }

    // MARK: - Connection handling (nonisolated, runs on the network queue)

    private static func accept(_ conn: NWConnection, token: String) {
        conn.start(queue: .global(qos: .utility))
        // Cap total connection lifetime. conn.receive only fires on bytes,
        // error, or close, so an idle or mid-request peer would otherwise pin a
        // connection + buffer forever (a pre-auth slow-loris over the tailnet).
        // The deadline cancels it unconditionally; respond() cancels it early on
        // the happy path. 20s is generous for a sub-second tailnet digest POST.
        let deadline = DispatchWorkItem { conn.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        receive(conn, token: token, deadline: deadline, buffer: Data())
    }

    // Accumulate until we have the full request (headers + Content-Length body),
    // then handle and close. Single request per connection, no keep-alive.
    private static func receive(_ conn: NWConnection, token: String, deadline: DispatchWorkItem, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buf = buffer
            if let data, !data.isEmpty { buf.append(data) }

            if buf.count > maxBodyBytes {
                respond(conn, deadline: deadline, status: "413 Payload Too Large", json: ["error": "body too large"])
                return
            }

            if let (headEnd, contentLength) = headerComplete(buf) {
                let have = buf.count - headEnd
                if have >= contentLength || error != nil || isComplete {
                    handle(conn, token: token, deadline: deadline, raw: buf, bodyStart: headEnd, contentLength: contentLength)
                    return
                }
            } else if error != nil || isComplete {
                deadline.cancel()
                conn.cancel()   // ended before a full header block arrived
                return
            }
            receive(conn, token: token, deadline: deadline, buffer: buf)
        }
    }

    // Returns (indexAfterHeaders, contentLength) once "\r\n\r\n" is present.
    private static func headerComplete(_ buf: Data) -> (Int, Int)? {
        let sep = Data([0x0d, 0x0a, 0x0d, 0x0a])   // \r\n\r\n
        guard let range = buf.range(of: sep) else { return nil }
        let headEnd = range.upperBound
        let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        var contentLength = 0
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == "content-length" {
                contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return (headEnd, contentLength)
    }

    private static func handle(_ conn: NWConnection, token: String, deadline: DispatchWorkItem, raw: Data, bodyStart: Int, contentLength: Int) {
        let headerData = raw.subdata(in: raw.startIndex..<bodyStart)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            respond(conn, deadline: deadline, status: "400 Bad Request", json: ["error": "empty request"]); return
        }
        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2 else {
            respond(conn, deadline: deadline, status: "400 Bad Request", json: ["error": "malformed request line"]); return
        }
        let method = String(tokens[0]).uppercased()
        let path = String(tokens[1]).split(separator: "?").first.map(String.init) ?? String(tokens[1])

        if method == "GET" && path == "/health" {
            Task { @MainActor in
                let has = PRDigestStore.shared.digest != nil
                respond(conn, deadline: deadline, status: "200 OK", json: [
                    "ok": true,
                    "service": "grux-pr-inbox",
                    "port": Int(port),
                    "hasDigest": has,
                ])
            }
            return
        }

        // All POST routes share the same bearer auth (one Grux server, one
        // shared token). /api/inbox = PR digest; /api/inbox/tests = nightly
        // tests; /api/inbox/social-ops = Social Ops change-events from the companion service.
        if method == "POST" && (path == "/api/inbox" || path == "/api/inbox/tests" || path == "/api/inbox/social-ops") {
            // Accept "Bearer <t>" / "bearer <t>" (RFC scheme is case-insensitive),
            // anchored so the prefix can't be matched mid-token.
            var presented = headerValue("authorization", in: lines) ?? ""
            if presented.lowercased().hasPrefix("bearer ") {
                presented = String(presented.dropFirst("bearer ".count))
            }
            presented = presented.trimmingCharacters(in: .whitespaces)
            guard !presented.isEmpty, constantTimeEqual(presented, token) else {
                log.error("PRInbox POST rejected: bad/missing token")
                respond(conn, deadline: deadline, status: "401 Unauthorized", json: ["error": "bad token"])
                return
            }
            let end = min(bodyStart + contentLength, raw.count)
            let body = raw.subdata(in: bodyStart..<end)

            // Social Ops change-event. Routed by an explicit path OR by a
            // {"kind":"social-ops"} body on the shared /api/inbox endpoint, so
            // the companion service's push script can target either. We hand the parsed body to
            // the coordinator (refresh store, alert on new red, relay to phone).
            let parsedBody = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let isSocialOps = path == "/api/inbox/social-ops"
                || (parsedBody?["kind"] as? String) == "social-ops"
            if isSocialOps {
                let dict = parsedBody ?? [:]
                Task { @MainActor in
                    SocialOpsCoordinator.shared.handleMiniEvent(dict)
                    respond(conn, deadline: deadline, status: "200 OK", json: [
                        "ok": true,
                        "kind": "social-ops",
                    ])
                }
                return
            }

            if path == "/api/inbox/tests" {
                do {
                    let digest = try JSONDecoder().decode(TestDigest.self, from: body)
                    let src = digest.source.isEmpty ? "mini-push" : digest.source
                    Task { @MainActor in
                        let accepted = TestDigestStore.shared.ingest(digest, source: src)
                        respond(conn, deadline: deadline, status: "200 OK", json: [
                            "ok": true,
                            "accepted": accepted,    // false when the push was not newer
                            "passCount": digest.passCount,
                            "failCount": digest.failCount,
                        ])
                    }
                } catch {
                    log.error("PRInbox tests POST decode failed: \(String(describing: error), privacy: .public)")
                    respond(conn, deadline: deadline, status: "400 Bad Request", json: ["error": "invalid test report json: \(error.localizedDescription)"])
                }
                return
            }

            do {
                let digest = try JSONDecoder().decode(PRDigest.self, from: body)
                let src = digest.source.isEmpty ? "mini-push" : digest.source
                Task { @MainActor in
                    let accepted = PRDigestStore.shared.ingest(digest, source: src)
                    respond(conn, deadline: deadline, status: "200 OK", json: [
                        "ok": true,
                        "accepted": accepted,    // false when the push was not newer
                        "openCount": digest.openCount,
                    ])
                }
            } catch {
                log.error("PRInbox POST decode failed: \(String(describing: error), privacy: .public)")
                respond(conn, deadline: deadline, status: "400 Bad Request", json: ["error": "invalid digest json: \(error.localizedDescription)"])
            }
            return
        }

        respond(conn, deadline: deadline, status: "404 Not Found", json: ["error": "no route", "path": path])
    }

    // Length-leaking but value-constant comparison: never short-circuits on the
    // first differing byte, so it gives no timing oracle on the token bytes.
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        var diff = ab.count ^ bb.count
        let n = min(ab.count, bb.count)
        var i = 0
        while i < n { diff |= Int(ab[i] ^ bb[i]); i += 1 }
        return diff == 0
    }

    private static func headerValue(_ name: String, in lines: [Substring]) -> String? {
        let lower = name.lowercased()
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased().trimmingCharacters(in: .whitespaces) == lower {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func respond(_ conn: NWConnection, deadline: DispatchWorkItem, status: String, json: [String: Any]) {
        deadline.cancel()   // request handled; release the lifetime cap
        let bodyData = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}
