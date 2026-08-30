import XCTest
@testable import Grux
import GruxMCPCore

/// THE CONTROL PLANE, AND THE PROMISE IT MUST NOT BREAK.
///
/// Grux's whole posture is that it opens nothing. The app now hosts an MCP server so a CLI
/// and an external agent can drive it, and the way that stays true is a Unix domain socket
/// at 0600 rather than a loopback port: the access control is the filesystem mode, enforced
/// by the kernel, rather than a token this process would have to mint and compare.
///
/// The MCP specification's own guidance for a local server says stdio, and where that is
/// impossible, a restricted IPC mechanism like a unix socket rather than HTTP. Stdio is
/// impossible here because nothing spawns a long-lived app per request.
@MainActor
final class ControlSocketTests: XCTestCase {

    /// THE TOOL SURFACE, WRITTEN OUT BY HAND.
    ///
    /// Deliberately a literal and not derived from `GruxControlTools.definitions`, because a
    /// check that reads the thing it is checking cannot fail. Adding a tool means editing
    /// this list, and that edit IS the decision: every entry is a new thing an agent on
    /// somebody's Mac can make Grux do.
    ///
    /// It is hoisted out of the assertion because thirteen tools arrived at once, written in
    /// parallel, and a literal buried mid-test is a literal every one of them forgets. A red
    /// suite that names one sibling's omission is the measured way a parallel run stalls:
    /// everybody diagnoses it correctly and nobody owns it.
    static let declaredTools: Set<String> = [
        "grux_status", "grux_refresh_status", "grux_set_features", "grux_toggle_feature",
        "grux_handoff", "grux_shell_snapshots", "grux_shell_undo",
        "grux_connect", "grux_disconnect", "grux_config", "grux_note", "grux_brands",
        "grux_request_permission",
        "grux_reset", "grux_repair", "grux_add", "grux_remove", "grux_approvals",
        "grux_model", "grux_run", "grux_ask", "grux_agent", "grux_open", "grux_meeting",
        "grux_shell", "grux_transcribe",
    ]

    /// A tool the app ADVERTISES and cannot DO is worse than one it never mentioned.
    ///
    /// The name set above cannot catch this: a definition with no `case` is advertised by
    /// `tools/list`, passes the set comparison, and answers "Unknown tool" the first time an
    /// agent believes the advertisement. So this reads the source and requires every
    /// definition to have a case and every case to have a definition, both ways.
    func testEveryDeclaredToolIsAlsoDispatched() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/GruxControlSocket.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        func matches(_ pattern: String) throws -> Set<String> {
            let re = try NSRegularExpression(pattern: pattern)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            return Set(re.matches(in: source, range: range).compactMap {
                Range($0.range(at: 1), in: source).map { r in String(source[r]) }
            })
        }
        let defined = try matches("\"name\": \"(grux_[a-z_]+)\"")
        let dispatched = try matches("case \"(grux_[a-z_]+)\":")

        // POSITIVE CONTROL. Two empty sets are equal, and that pass would mean the file
        // moved or the shape changed rather than that anything is consistent.
        XCTAssertGreaterThanOrEqual(defined.count, 20,
            "parsed \(defined.count) tool definitions out of the source, so the shape changed")

        XCTAssertEqual(defined.subtracting(dispatched), [],
            "advertised in tools/list and not handled in the switch, so calling it answers "
            + "\"Unknown tool\" after the app told an agent it existed")
        XCTAssertEqual(dispatched.subtracting(defined), [],
            "handled in the switch and never advertised, so nothing can discover it")
        XCTAssertEqual(defined, Self.declaredTools,
            "the source and the hand written list above disagree")
    }

    /// The control tools can WRITE. Any test in this class that touches one could leave
    /// global state behind for every class that runs after it, which is exactly what
    /// happened once: a sweep called grux_set_features with no features and ninety nine
    /// unrelated assertions failed in the same run. The sweep is gone; this is the net.
    private var savedSelection: Any?

    override func setUp() {
        super.setUp()
        savedSelection = UserDefaults.standard.object(forKey: FeatureSelection.defaultsKey)
    }

    override func tearDown() {
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: FeatureSelection.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: FeatureSelection.defaultsKey)
        }
        super.tearDown()
    }

    private func tempSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-ctl-\(UUID().uuidString.prefix(8))")
            .appendingPathComponent("mcp.sock").path
    }

    /// A round trip against the real listener, over a real socket.
    ///
    /// THE CLIENT I/O RUNS OFF THE MAIN ACTOR, and that is not a detail. The server answers
    /// on the main actor, so a test that blocks the main actor in a read loop waits forever
    /// for a reply that cannot be produced until the test yields. The first version of this
    /// helper did exactly that and every socket test reported zero replies, which reads like
    /// a broken server and is a deadlocked client.
    ///
    /// Returns raw frames rather than parsed objects so nothing non-Sendable crosses the
    /// boundary; the caller parses on its own actor.
    /// `pauseBetweenWrites` forces the server to do a separate `read` per frame.
    ///
    /// Without it the kernel coalesces every frame into one 64 KB read, so the server sees a
    /// single chunk and starts a single task, and any test claiming to exercise interleaving
    /// between chunks is not exercising anything.
    nonisolated private func roundTrip(_ requests: [[String: Any]],
                                       path: String,
                                       expecting: Int,
                                       pauseBetweenWrites: UInt32 = 0) async -> [[String: Any]] {
        let frames: [Data] = requests.compactMap { MCPWire.encode($0) }
        let raw: [Data] = await Task.detached(priority: .userInitiated) { () -> [Data] in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return [] }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                path.withCString { src in
                    strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                            src, maxLen - 1)
                }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connected = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
            }
            guard connected == 0 else { return [] }

            for frame in frames {
                _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if pauseBetweenWrites > 0 { usleep(pauseBetweenWrites) }
            }

            var tv = timeval()
            tv.tv_sec = 5
            tv.tv_usec = 0
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

            let splitter = GruxMCPCore.MCPLineSplitter()
            var out: [Data] = []
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while out.count < expecting {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                out.append(contentsOf: splitter.feed(Data(buf[0..<n])))
            }
            return out
        }.value

        return raw.compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
    }

    // MARK: - The promise

    /// THE ONE THAT PROTECTS THE PITCH. A socket file, not a port.
    func testTheSocketIsOwnerOnlyAndIsASocket() throws {
        let path = tempSocketPath()
        defer {
            GruxControlSocket.shared.stop()
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(GruxControlSocket.shared.start(at: path), "the listener did not start")

        var st = stat()
        XCTAssertEqual(stat(path, &st), 0, "nothing at \(path)")
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK, "\(path) is not a socket")

        let mode = st.st_mode & 0o777
        XCTAssertEqual(mode, GruxControlSocket.socketMode, String(
            format: "socket mode is %03o, must be %03o. bind() masks 0777 by the process "
            + "umask, so a permissive umask would leave this world writable and any local "
            + "process could drive Grux.", mode, GruxControlSocket.socketMode))
        XCTAssertEqual(mode & 0o077, 0, "group or other can reach the control plane")
    }

    /// The real path is the machine-interface directory, beside the status file and the
    /// triggers. A consumer should learn one directory.
    func testItLivesBesideTheRestOfTheMachineInterface() {
        XCTAssertTrue(GruxControlSocket.socketPath.hasSuffix("/.grux/mcp.sock"),
                      "the control socket left the machine-interface directory")
        XCTAssertEqual(URL(fileURLWithPath: GruxControlSocket.socketPath)
                        .deletingLastPathComponent().lastPathComponent, ".grux")
    }

    /// Restarting must not fail on the socket a previous run left behind, which is what
    /// EADDRINUSE means for a unix socket and what a crash guarantees will happen.
    func testItRecoversFromAStaleSocketFile() throws {
        let path = tempSocketPath()
        defer {
            GruxControlSocket.shared.stop()
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(GruxControlSocket.shared.start(at: path))
        GruxControlSocket.shared.stop()
        // stop() closes the fd but leaves the node, exactly as a crash would.
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "control: no stale node")
        XCTAssertTrue(GruxControlSocket.shared.start(at: path),
                      "a stale socket file blocked the restart, so a crash would need a "
                      + "manual rm before Grux could serve again")
    }

    /// A SECOND GRUX MUST NOT STEAL THE SOCKET FROM A LIVE ONE.
    ///
    /// A unix socket holds no lock on its path, so unlink-then-bind always succeeds and the
    /// incumbent is left listening on an inode nothing can reach. Measured 2026-08-28: a
    /// second Grux launched from .build took the path from the healthy app running out of
    /// /Applications, and the only symptom was a socket file that existed and never
    /// answered. Nothing logged, nothing crashed.
    ///
    /// The incumbent here is a RAW socket rather than the shared listener, because the real
    /// case is a second PROCESS. `start()` opens with `stop()`, so asking the singleton to
    /// start twice tears down its own listener first and would prove nothing.
    func testAliveSocketIsNotStolen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-rival-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("mcp.sock").path

        // Stand in for another Grux that already owns this path.
        let rival = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(rival, 0)
        defer { close(rival) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        src, maxLen - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            // Darwin.bind, because an unqualified `bind` resolves to a member here.
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(rival, $0, size)
            }
        }
        XCTAssertEqual(bound, 0, "control: the rival could not bind, so nothing is being defended")
        XCTAssertEqual(Darwin.listen(rival, 4), 0)

        XCTAssertTrue(GruxControlSocket.somethingIsListening(at: path),
                      "control: the probe cannot see a listener that is plainly accepting")

        defer { GruxControlSocket.shared.stop() }
        XCTAssertFalse(GruxControlSocket.shared.start(at: path),
            "Grux took a socket path another process was already accepting on. The incumbent "
            + "would be left listening on an unlinked inode nothing can reach.")

        XCTAssertTrue(GruxControlSocket.somethingIsListening(at: path),
                      "the rival stopped answering, so the path was stolen after all")
    }

    /// The other half: a node left by a crash accepts nothing and MUST be replaced, or a
    /// crash would need a manual rm before Grux could ever serve again.
    func testTheProbeSaysNoToADeadNode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-dead-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let missing = dir.appendingPathComponent("nothing.sock").path
        XCTAssertFalse(GruxControlSocket.somethingIsListening(at: missing),
                       "the probe claimed a listener on a path with no file")

        let plain = dir.appendingPathComponent("not-a-socket").path
        FileManager.default.createFile(atPath: plain, contents: Data())
        XCTAssertFalse(GruxControlSocket.somethingIsListening(at: plain),
                       "the probe claimed a listener on an ordinary file")
    }

    // MARK: - The protocol, over a real socket

    func testInitializeAndToolsListOverTheWire() async throws {
        let path = tempSocketPath()
        defer {
            GruxControlSocket.shared.stop()
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(GruxControlSocket.shared.start(at: path))

        let replies = await roundTrip([
            ["jsonrpc": "2.0", "id": 1, "method": "initialize"],
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"],
        ], path: path, expecting: 2)

        XCTAssertEqual(replies.count, 2, "got \(replies.count) replies, expected 2")

        let initResult = replies.first { ($0["id"] as? Int) == 1 }?["result"] as? [String: Any]
        XCTAssertEqual(initResult?["protocolVersion"] as? String, MCPWire.protocolVersion)
        let info = initResult?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, GruxControlSocket.serverName,
            "the control plane must not answer under the read-only server's name, or a "
            + "client cannot tell which of the two it reached")

        let tools = (replies.first { ($0["id"] as? Int) == 2 }?["result"]
                     as? [String: Any])?["tools"] as? [[String: Any]]
        let names = Set((tools ?? []).compactMap { $0["name"] as? String })
        XCTAssertEqual(names, Self.declaredTools,
                       "the tool surface changed. Every entry is a new thing an agent on this "
                       + "machine can make Grux do, so it grows by decision. "
                       + "grux_shell_undo in particular DISCARDS work.")
    }

    func testStatusOverTheWireCarriesEveryCapability() async throws {
        let path = tempSocketPath()
        defer {
            GruxControlSocket.shared.stop()
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(GruxControlSocket.shared.start(at: path))

        let replies = await roundTrip([[
            "jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": ["name": "grux_status", "arguments": [String: Any]()],
        ]], path: path, expecting: 1)

        let result = replies.first?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, false)
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let decoded = try JSONDecoder().decode(SetupStatusFile.Status.self,
                                               from: Data(text.utf8))
        XCTAssertEqual(Set(decoded.capabilities.map(\.id)),
                       Set(SetupRequirement.allCases.map(\.rawValue)))
        XCTAssertEqual(decoded.schema, SetupStatusFile.schemaVersion)
    }

    // MARK: - Refusals

    /// A tool that fails is not a protocol error. An agent reading a JSON-RPC error retries
    /// the call SHAPE, which will never help; an agent reading a tool result with isError
    /// reads the message and acts on it.
    func testAnUnknownToolIsAToolFailureNotAProtocolError() async throws {
        let path = tempSocketPath()
        defer {
            GruxControlSocket.shared.stop()
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(GruxControlSocket.shared.start(at: path))

        let replies = await roundTrip([[
            "jsonrpc": "2.0", "id": 9, "method": "tools/call",
            "params": ["name": "grux_delete_everything", "arguments": [String: Any]()],
        ]], path: path, expecting: 1)

        let reply = replies.first
        XCTAssertNil(reply?["error"], "an unknown tool came back as a protocol error")
        XCTAssertEqual((reply?["result"] as? [String: Any])?["isError"] as? Bool, true)
    }

    /// ANSWERS COME BACK IN THE ORDER THEY WERE ASKED, now that handling can suspend.
    ///
    /// Tool dispatch became asynchronous so a tool can do real work. The read handler starts
    /// one `Task { @MainActor }` per chunk, and while handling was synchronous each ran to
    /// completion atomically, so ordering held by construction. With an `await` inside, a
    /// second chunk's task can run at the first one's suspension point, and `MCPLineSplitter`
    /// is stateful ACROSS chunks: interleaved feeding does not lose a frame, it corrupts one,
    /// gluing a later chunk's bytes onto the tail of a partial frame. Hence a synchronous
    /// split and a serialized pump.
    ///
    /// MEASURED, NOT ASSERTED. Against the naive implementation, `await handle` inline in the
    /// per-chunk task with no pump, this fails deterministically, three runs out of three:
    ///
    ///     replies came back as [2, 4, 6, 8, 1, 3, 5, 7]
    ///
    /// Every instant `ping` overtook every suspending `grux_shell_snapshots`. With the pump
    /// it is [1...8] every time.
    ///
    /// TWO THINGS HAD TO BE TRUE BEFORE IT COULD CATCH ANYTHING, and neither was obvious.
    /// The writes need a pause between them or the kernel coalesces all eight frames into one
    /// 64 KB read, and one chunk is one task with nothing to interleave against. And the tool
    /// has to genuinely suspend: an earlier version of this test used `grux_status` and
    /// `ping`, and the naive implementation passed it every time, because an async function
    /// that never reaches a suspension point is not a test of concurrency.
    func testRepliesComeBackInOrderAndNoneAreLost() async throws {
        let path = tempSocketPath()
        defer {
            GruxControlSocket.shared.stop()
            try? FileManager.default.removeItem(
                atPath: (path as NSString).deletingLastPathComponent)
        }
        XCTAssertTrue(GruxControlSocket.shared.start(at: path))

        // A GENUINELY SUSPENDING TOOL ALTERNATING WITH AN INSTANT ONE. This is the whole
        // test. `grux_shell_snapshots` enumerates shadow repositories and shells out to git,
        // so it really does suspend; `ping` returns without yielding at all. If handling ran
        // inline in the per-chunk task, the pings would overtake the snapshot calls and the
        // ids would come back interleaved.
        //
        // An earlier version of this test used `grux_status` and `ping`, and the naive
        // implementation passed it every time, because neither of those ever reaches a
        // suspension point. An async function that never suspends is not a test of
        // concurrency.
        let requests: [[String: Any]] = (1...8).map { i in
            i % 2 == 0
                ? ["jsonrpc": "2.0", "id": i, "method": "ping", "params": [String: Any]()]
                : ["jsonrpc": "2.0", "id": i, "method": "tools/call",
                   "params": ["name": "grux_shell_snapshots", "arguments": [String: Any]()]]
        }

        // One read per frame. Without the pause the kernel delivers all eight as a single
        // chunk and the test silently stops covering the thing it is named for.
        let replies = await roundTrip(requests, path: path, expecting: requests.count,
                                      pauseBetweenWrites: 3000)

        let ids = replies.compactMap { $0["id"] as? Int }
        XCTAssertEqual(ids.count, requests.count,
            "got \(ids.count) replies for \(requests.count) requests, so a frame was lost "
            + "or two were glued together")
        XCTAssertEqual(ids, Array(1...requests.count),
            "replies came back as \(ids), out of the order they were asked in")
        XCTAssertEqual(Set(ids).count, ids.count, "an id came back twice")
        for r in replies {
            XCTAssertNil(r["error"], "a reply carried a protocol error: \(r)")
        }
    }

    /// Only a macOS permission may be requested this way. Asking for a key or a consent step
    /// through the permission door has to be refused by name, not silently ignored.
    func testOnlyPermissionsCanBeRequested() async {
        for id in ["key.anthropic", "step.recording_consent_acknowledged", "endpoint.ollama"] {
            let out = await GruxControlTools.call(name: "grux_request_permission",
                                            arguments: ["id": id])
            XCTAssertEqual(out["isError"] as? Bool, true, "\(id) was accepted as a permission")
        }
        let bogus = await GruxControlTools.call(name: "grux_request_permission",
                                          arguments: ["id": "perm.not_a_thing"])
        XCTAssertEqual(bogus["isError"] as? Bool, true, "an unknown id was accepted")
    }

    /// The four consent decisions have no path through the control plane at all. An agent
    /// that could tick one has not completed setup, it has removed the point of the step.
    func testNoToolCanSatisfyAConsentDecision() async {
        let consent = CapabilityResolver.selfAttestedSteps
            .filter { $0.rawValue.hasPrefix("step.") }
        XCTAssertFalse(consent.isEmpty, "control: no consent steps to check")

        // NOT A BLIND SWEEP OVER EVERY TOOL, and the first version was.
        //
        // It called every tool in the catalogue with a consent id as `arguments["id"]`.
        // Once `grux_set_features` joined the surface that meant calling it with no
        // features, which is a valid request meaning "choose nothing", so the sweep turned
        // all thirty nine features off and left them off. Ninety nine unrelated assertions
        // failed in the same run. A test that invokes an unknown tool surface with
        // improvised arguments is not a check, it is a fuzzer with side effects.
        //
        // Only the tool that takes a capability id is driven, and it is named.
        for step in consent {
            let out = await GruxControlTools.call(name: "grux_request_permission",
                                            arguments: ["id": step.rawValue])
            XCTAssertEqual(out["isError"] as? Bool, true,
                           "grux_request_permission accepted \(step.rawValue)")
        }
        // And no consent step is ever satisfiable by detection, whatever any tool does.
        for step in consent {
            XCTAssertFalse(CapabilityResolver.detectedSteps.contains(step),
                           "\(step.rawValue) became detectable, so consent is being inferred")
        }
        // The selection tools exist and are deliberately NOT driven here: this test is about
        // consent, and a test that changes unrelated global state to prove a point about
        // consent has stopped being a test about consent.
        let names = Set(GruxControlTools.definitions.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("grux_set_features"),
                      "control: the surface changed, re-read what this test does not drive")
    }
}
