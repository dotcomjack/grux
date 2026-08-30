import AppKit
import Foundation
import GruxMCPCore
import GruxShellCore

/// The app's control plane: MCP over a Unix domain socket at `~/.grux/mcp.sock`.
///
/// ## Why a socket and not a port
///
/// The MCP specification's own security guidance for a local server is to use stdio, and
/// where that is not possible, "restricted IPC mechanisms like unix domain sockets" rather
/// than HTTP. Stdio is not available to a long-lived app: nothing spawns Grux per request.
/// Loopback HTTP would work and is what most implementations reach for, and it drags in
/// Origin validation and a DNS-rebinding defence for a server that has no business being
/// reachable by a web page in the first place.
///
/// A socket file also carries its access control in the filesystem. Mode 0600 means the
/// owner and nobody else, enforced by the kernel rather than by a token this process would
/// have to mint, store and compare. And it keeps the promise the whole product rests on:
/// **Grux opens no network port.** A `lsof` for a listening TCP socket comes back empty,
/// and there is a test that says so.
///
/// ## Why it is not the other MCP server
///
/// `GruxMCPServer` is a separate, read-only, Foundation-only process over stdio. It cannot
/// drive the app: it shares no memory and no state with it. This one runs INSIDE the app,
/// which is the only place a permission can be requested under Grux's own signature, and it
/// is therefore the only one that may change anything. Two servers, one wire format, and
/// deliberately different powers.
@MainActor
final class GruxControlSocket {

    static let shared = GruxControlSocket()

    /// Beside `setup-status.json` and the file triggers. One machine-interface directory.
    nonisolated static var socketPath: String {
        NSHomeDirectory() + "/.grux/mcp.sock"
    }

    /// Owner read and write. Nothing else, ever.
    nonisolated static let socketMode: mode_t = 0o600

    static let serverName = "grux-control"
    static let serverVersion = "1.0.0"

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// LIVE CONNECTIONS ARE HELD HERE, and forgetting to do that is a bug that looks like a
    /// dead server. A connection was originally created inside the accept task and never
    /// retained, so it deallocated the moment `run()` returned and took its dispatch source
    /// with it. The socket accepted, the client connected, the request was written, and no
    /// reply ever came: there was nothing left alive to read it.
    private var connections: [ObjectIdentifier: GruxControlConnection] = [:]
    private let queue = DispatchQueue(label: "grux.control.socket", qos: .userInitiated)

    private init() {}

    // MARK: - Lifecycle

    @discardableResult
    func start(at path: String = GruxControlSocket.socketPath) -> Bool {
        stop()

        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // PROBE BEFORE STEALING, and this is a bug that was measured rather than imagined.
        //
        // A unix socket holds no lock on its path, so `unlink` then `bind` always succeeds:
        // the newcomer takes the name and the incumbent is left listening on an inode
        // nothing can reach. On 2026-08-28 a second Grux launched from .build did exactly
        // that to the healthy app running from /Applications, and the symptom was a socket
        // file that existed and never answered.
        //
        // So: if something is already accepting on this path, another Grux owns it and this
        // one does not serve. A stale node from a crash accepts nothing, which is the case
        // the unlink is actually for.
        if Self.somethingIsListening(at: path) { return false }
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // sun_path is 104 bytes on Darwin and truncation would bind the WRONG path, which
        // would look like a working server nothing could find.
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { close(fd); return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        src, maxLen - 1)
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0 else { close(fd); return false }

        // CHMOD AFTER BIND, not before, and never trust umask.
        //
        // bind() creates the node with 0777 masked by the process umask, so on a machine
        // with a permissive umask the socket would be world writable and any local process
        // could drive Grux. Setting the mode explicitly is the access control; there is no
        // token behind it.
        guard chmod(path, Self.socketMode) == 0 else {
            close(fd)
            unlink(path)
            return false
        }

        guard listen(fd, 8) == 0 else { close(fd); unlink(path); return false }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne(on: fd) }
        source.resume()
        acceptSource = source
        return true
    }

    /// Take ownership of an accepted client and keep it alive until the peer hangs up.
    fileprivate func adopt(_ fd: Int32) {
        let conn = GruxControlConnection(fd: fd) { [weak self] finished in
            self?.connections.removeValue(forKey: ObjectIdentifier(finished))
        }
        connections[ObjectIdentifier(conn)] = conn
        conn.run()
    }

    /// For the tests. A listener with no live connections has either never been used or has
    /// cleaned up after itself, and both are worth being able to assert.
    var liveConnectionCount: Int { connections.count }

    /// Is a live peer accepting on this path? A connect that succeeds means yes.
    ///
    /// Cheap and synchronous on purpose: it runs once at launch and a unix connect to a
    /// dead node fails immediately with ECONNREFUSED rather than hanging.
    nonisolated static func somethingIsListening(at path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        src, maxLen - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } == 0
        }
    }

    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        connections.values.forEach { $0.closeConnection() }
        connections.removeAll()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    // MARK: - Connections

    private nonisolated func acceptOne(on fd: Int32) {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        // A dead peer must surface as a caught EPIPE on write, never as a fatal signal that
        // takes the whole app down with it.
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        Task { @MainActor in GruxControlSocket.shared.adopt(client) }
    }
}

/// One client. Reads newline-delimited JSON-RPC, answers on the main actor.
@MainActor
final class GruxControlConnection {

    private let fd: Int32
    private let splitter = GruxMCPCore.MCPLineSplitter()
    private var source: DispatchSourceRead?
    private let readQueue = DispatchQueue(label: "grux.control.conn")
    private let onFinish: (GruxControlConnection) -> Void

    init(fd: Int32, onFinish: @escaping (GruxControlConnection) -> Void) {
        self.fd = fd
        self.onFinish = onFinish
    }

    /// Named for what it does rather than `close`, which would shadow the POSIX
    /// `close(2)` this file also calls and produced a compile error that read as a
    /// type problem rather than a naming one.
    func closeConnection() { finish() }

    func run() {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(self.fd, &buf, buf.count)
            guard n > 0 else {
                Task { @MainActor in self.finish() }
                return
            }
            let chunk = Data(buf[0..<n])
            Task { @MainActor in self.consume(chunk) }
        }
        src.setCancelHandler { [fd = self.fd] in close(fd) }
        src.resume()
        source = src
    }

    private func finish() {
        guard source != nil else { return }
        source?.cancel()
        source = nil
        onFinish(self)
    }

    /// Frames waiting to be answered, and whether something is already answering them.
    ///
    /// Both live on the MainActor, which is the only thing that touches them, so neither
    /// needs a lock.
    private var pending: [Data] = []
    private var pumping = false

    /// SPLIT SYNCHRONOUSLY, ANSWER SERIALLY.
    ///
    /// `MCPLineSplitter` is stateful ACROSS chunks: it holds the tail of a partial frame.
    /// The read handler starts one `Task { @MainActor }` per chunk, and while `consume` had
    /// no suspension point those tasks each ran to completion atomically, so feeding was
    /// ordered by construction. Handling a tool call is asynchronous now, and an `await`
    /// inside this function would let a second chunk's task run at the suspension point and
    /// feed the splitter out of order, which does not lose a frame, it CORRUPTS one: the
    /// tail of frame N gets a later chunk's bytes glued to it.
    ///
    /// So splitting stays synchronous and keeps byte order, and the resulting frames go on a
    /// queue drained one at a time. Responses then also leave in request order, which is not
    /// required by JSON-RPC but is what every client here expects.
    private func consume(_ chunk: Data) {
        pending.append(contentsOf: splitter.feed(chunk))
        pump()
    }

    private func pump() {
        guard !pumping else { return }
        pumping = true
        Task { @MainActor [weak self] in
            while let self, !self.pending.isEmpty {
                let line = self.pending.removeFirst()
                guard let object = try? JSONSerialization.jsonObject(with: line)
                        as? [String: Any] else { continue }
                guard let response = await self.handle(object),
                      let frame = MCPWire.encode(response) else { continue }
                // The connection can be finished while a tool is still running. Writing to a
                // closed descriptor is not a crash here (SO_NOSIGPIPE), but answering a
                // client that has gone is pointless, and it would hold the queue open.
                guard self.source != nil else { break }
                frame.withUnsafeBytes { raw in
                    _ = write(self.fd, raw.baseAddress, raw.count)
                }
            }
            self?.pumping = false
        }
    }

    // MARK: - Dispatch

    func handle(_ request: [String: Any]) async -> [String: Any]? {
        let method = request["method"] as? String ?? ""
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return MCPWire.ok(id: id, result: [
                "protocolVersion": MCPWire.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": GruxControlSocket.serverName,
                               "version": GruxControlSocket.serverVersion],
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return MCPWire.ok(id: id, result: [String: Any]())
        case "tools/list":
            return MCPWire.ok(id: id, result: ["tools": GruxControlTools.definitions])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            return MCPWire.ok(id: id,
                              result: await GruxControlTools.call(name: name, arguments: args))
        default:
            guard id != nil else { return nil }
            return MCPWire.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }
}

/// What the control plane may actually do.
///
/// Deliberately small. Every addition here is a new thing an agent on this machine can make
/// Grux do, so the list grows by decision rather than by convenience.
@MainActor
enum GruxControlTools {

    static let definitions: [[String: Any]] = [
        [
            "name": "grux_status",
            "description": "Everything Grux needs and whether this Mac has it: all capability "
                + "ids with their state, every feature with what is still blocking it, and a "
                + "self_attested flag on the answers nobody measured.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "grux_refresh_status",
            "description": "Recompute the setup status from the live machine and rewrite "
                + "~/.grux/setup-status.json. Use after installing something so Grux notices.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "grux_set_features",
            "description": "Replace the whole feature selection. Everything not named is "
                + "turned off. Pass an empty list to choose nothing, which is a real answer: "
                + "Grux then asks for nothing at all.",
            "inputSchema": [
                "type": "object",
                "properties": ["features": ["type": "array",
                                            "items": ["type": "string"],
                                            "description": "Feature ids."]],
                "required": ["features"],
            ],
        ],
        [
            "name": "grux_toggle_feature",
            "description": "Turn one feature on or off, leaving the rest alone. On an "
                + "install that has never chosen, this starts from everything on.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string"], "on": ["type": "boolean"]],
                "required": ["id", "on"],
            ],
        ],
        [
            "name": "grux_handoff",
            "description": "The prompt to paste into your own coding agent: what it may do, "
                + "what only you can do, what it must never do, and how to verify. Built "
                + "from what this Mac is actually missing. Pass features to scope it to just "
                + "those, for when you are adding one thing rather than setting up.",
            "inputSchema": [
                "type": "object",
                "properties": ["features": ["type": "array",
                                            "items": ["type": "string"],
                                            "description": "Feature ids. Omit for everything."]],
            ],
        ],
        [
            "name": "grux_shell_snapshots",
            "description": "Every shell session Grux can roll back, live or finished, newest "
                + "first, with the snapshots each one holds. A session whose folder is gone "
                + "is listed and marked not restorable rather than hidden.",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "grux_shell_undo",
            "description": "Roll a shell session's folder back to one snapshot. THIS DISCARDS "
                + "every change made after that snapshot, including work somebody did by hand "
                + "in the same folder. Returns the files it changed. Ask the person first.",
            "inputSchema": [
                "type": "object",
                "properties": ["snapshot_id": ["type": "string",
                                               "description": "From grux_shell_snapshots."]],
                "required": ["snapshot_id"],
            ],
        ],
        [
            "name": "grux_connect",
            "description": "Store one credential in the macOS Keychain. The VALUE never "
                + "appears in a log, a flag or an environment variable: the terminal reads "
                + "it with the echo off and hands it straight here.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "capability": ["type": "string", "description": "A key.* capability id."],
                    "value": ["type": "string", "description": "The credential itself."],
                ],
                "required": ["capability", "value"],
            ],
        ],
        [
            "name": "grux_disconnect",
            "description": "Forget one credential. Removes it from the Keychain. Whatever "
                + "features were using it stop working until it is set again.",
            "inputSchema": [
                "type": "object",
                "properties": ["capability": ["type": "string"]],
                "required": ["capability"],
            ],
        ],
        [
            "name": "grux_config",
            "description": "Read or write one of Grux's settings. Omit `value` to read, omit "
                + "`key` to list them all. These are addresses and paths, never secrets: a "
                + "credential goes through grux_connect and is never readable back.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "key": ["type": "string", "description": "A grux.* config key."],
                    "value": ["type": "string", "description": "Omit to read."],
                ],
            ],
        ],
        [
            "name": "grux_note",
            "description": "Write one note into Grux's notes. Returns its id. This is the "
                + "only writing tool here that creates something rather than changing a "
                + "setting, so it is deliberately narrow: a title, a body, tags.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "body": ["type": "string"],
                    "title": ["type": "string"],
                    "tags": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["body"],
            ],
        ],
        [
            "name": "grux_brands",
            "description": "The brands Grux knows about, and which one later commands are "
                + "about. Pass `use` to change it, omit to read.",
            "inputSchema": [
                "type": "object",
                "properties": ["use": ["type": "string", "description": "A brand name."]],
            ],
        ],
        [
            "name": "grux_request_permission",
            "description": "Ask macOS for one permission. Grux.app raises the dialog under its "
                + "own signature, because a request made from a terminal grants the permission "
                + "to the terminal. Returns immediately; poll grux_status for the answer.",
            "inputSchema": [
                "type": "object",
                "properties": ["id": ["type": "string",
                                      "description": "A perm.* capability id."]],
                "required": ["id"],
            ],
        ],
        [
            "name": "grux_reset",
            "description": "Put one scope back to never-asked. Scopes: features (forget the "
                + "selection so everything is on again), brand (forget which brand is "
                + "current), consent (forget the recording and microphone answers), all. "
                + "Never revokes a macOS permission: only the system can do that.",
            "inputSchema": [
                "type": "object",
                "properties": ["scope": ["type": "string",
                                         "description": "features, brand, consent or all."]],
                "required": ["scope"],
            ],
        ],
        [
            "name": "grux_repair",
            "description": "Fix something doctor found and can fix, one thing at a time. "
                + "Call with no id to list what is repairable right now.",
            "inputSchema": [
                "type": "object",
                "properties": ["what": ["type": "string",
                                        "description": "The id of one repair. Omit to list."]],
            ],
        ],
        [
            "name": "grux_add",
            "description": "Add one noun: project, mailbox, skill, schedule, repo, domain, "
                + "feature or brand. Call with no noun to list the nouns and what each one "
                + "actually bundles on this Mac.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "noun": ["type": "string", "description": "project, mailbox, skill, "
                             + "schedule, repo, domain, feature or brand."],
                    "value": ["type": "string", "description": "The path, address or name."],
                ],
            ],
        ],
        [
            "name": "grux_remove",
            "description": "Remove one noun Grux is tracking. Never deletes the thing "
                + "itself: a project stops being watched, its files stay where they are.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "noun": ["type": "string", "description": "The noun. Omit to list."],
                    "value": ["type": "string", "description": "Which one."],
                ],
            ],
        ],
        [
            "name": "grux_approvals",
            "description": "What the agent may do without asking, and the queue of things "
                + "waiting on an answer. Call with no action to read both.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "description": "mode, approve, skip. "
                               + "Omit to read."],
                    "mode": ["type": "string", "description": "For action=mode."],
                    "id": ["type": "string", "description": "For approve and skip."],
                ],
            ],
        ],
        [
            "name": "grux_model",
            "description": "Which model a surface uses. Call with nothing to list every "
                + "surface and its model. Names are not validated against a vendor: this "
                + "machine never asks one, and a wrong name surfaces when the surface runs.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "surface": ["type": "string", "description": "chat, vision, offline, "
                                + "local or voice. Omit to list."],
                    "name": ["type": "string", "description": "The model id to set."],
                ],
            ],
        ],
        [
            "name": "grux_run",
            "description": "Run one of the app's own commands by id or name. Call with "
                + "nothing to list what is runnable.",
            "inputSchema": [
                "type": "object",
                "properties": ["command": ["type": "string",
                                           "description": "A command id or macro name."]],
            ],
        ],
        [
            "name": "grux_ask",
            "description": "One question to the chat surface. The answer comes back as "
                + "text. Costs a model call and the ledger records it.",
            "inputSchema": [
                "type": "object",
                "properties": ["text": ["type": "string", "description": "The question."]],
                "required": ["text"],
            ],
        ],
        [
            "name": "grux_agent",
            "description": "Hand the agent a task. Returns the job id immediately rather "
                + "than blocking, because a swarm outlives a socket call.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "The task. Omit to list jobs."],
                    "job": ["type": "string", "description": "A job id to read back."],
                ],
            ],
        ],
        [
            "name": "grux_open",
            "description": "Bring a Grux window forward on this Mac. The one tool that "
                + "needs somebody to be sitting at the machine to be worth calling.",
            "inputSchema": [
                "type": "object",
                "properties": ["surface": ["type": "string",
                                           "description": "Which tab. Omit to list them."]],
            ],
        ],
        [
            "name": "grux_meeting",
            "description": "The meeting recorder: start, stop, or list what is recorded. "
                + "Starting one records audio, which is why it is a tool and not a read.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "description": "start, stop or list."],
                    "id": ["type": "string", "description": "A meeting id, for reading one."],
                ],
                "required": ["action"],
            ],
        ],
        [
            "name": "grux_shell",
            "description": "Run a shell command through the trust ceiling, snapshotted "
                + "first so grux undo can put it back. Refused outside the allowed roots.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The command line."],
                    "timeout_sec": ["type": "number", "description": "Seconds. Default 60."],
                ],
                "required": ["command"],
            ],
        ],
        [
            "name": "grux_transcribe",
            "description": "Transcribe an audio file on this Mac's GPU. Never uploads. Runs "
                + "in the app rather than in the binary so it reuses the model Grux already "
                + "has loaded instead of downloading a second copy.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string",
                                        "description": "An absolute path to an audio file."]],
                "required": ["path"],
            ],
        ],
    ]

    static func call(name: String, arguments: [String: Any]) async -> [String: Any] {
        switch name {
        case "grux_status":
            return status()
        case "grux_refresh_status":
            let ok = SetupStatusFile.write()
            return ok ? MCPWire.textResult("Refreshed \(SetupStatusFile.url.path)")
                      : MCPWire.textFailure("Could not write \(SetupStatusFile.url.path)")
        case "grux_set_features":
            return setFeatures(arguments["features"] as? [String] ?? [])
        case "grux_toggle_feature":
            return toggleFeature(arguments["id"] as? String ?? "",
                                 on: arguments["on"] as? Bool ?? true)
        case "grux_handoff":
            if let ids = arguments["features"] as? [String], !ids.isEmpty {
                let known = Set(FeatureRegistry.rows.map(\.id))
                let unknown = ids.filter { !known.contains($0) }
                guard unknown.isEmpty else {
                    return MCPWire.textFailure("No feature called "
                        + unknown.sorted().joined(separator: ", ") + ".")
                }
                return MCPWire.textResult(AgentHandoff.promptFor(features: Set(ids)))
            }
            // Reuses AgentHandoff rather than growing a second renderer. Its delegable list
            // was narrowed once after review because the first draft named five things and
            // three were wrong, and that judgement should not have to be made twice.
            return MCPWire.textResult(AgentHandoff.prompt())
        case "grux_shell_snapshots":
            return await shellSnapshots()
        case "grux_shell_undo":
            guard let id = arguments["snapshot_id"] as? String, !id.isEmpty else {
                return MCPWire.textFailure("grux_shell_undo needs a snapshot_id. "
                                         + "Call grux_shell_snapshots to see them.")
            }
            return await shellUndo(snapshotId: id)
        case "grux_connect":
            guard let id = arguments["capability"] as? String,
                  let value = arguments["value"] as? String, !value.isEmpty else {
                return MCPWire.textFailure("grux_connect needs a capability and a value.")
            }
            return connect(capability: id, value: value)
        case "grux_disconnect":
            guard let id = arguments["capability"] as? String else {
                return MCPWire.textFailure("grux_disconnect needs a capability.")
            }
            return disconnect(capability: id)
        case "grux_config":
            return config(key: arguments["key"] as? String,
                          value: arguments["value"] as? String)
        case "grux_note":
            guard let body = arguments["body"] as? String,
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return MCPWire.textFailure("grux_note needs a body.")
            }
            return note(body: body,
                        title: arguments["title"] as? String ?? "",
                        tags: arguments["tags"] as? [String] ?? [])
        case "grux_brands":
            return brands(use: arguments["use"] as? String)
        case "grux_request_permission":
            return requestPermission(arguments["id"] as? String ?? "")
        case "grux_reset":
            return reset(scope: arguments["scope"] as? String ?? "")
        case "grux_repair":
            return repair(what: arguments["what"] as? String)
        case "grux_add":
            return add(noun: arguments["noun"] as? String,
                       value: arguments["value"] as? String)
        case "grux_remove":
            return remove(noun: arguments["noun"] as? String,
                          value: arguments["value"] as? String)
        case "grux_approvals":
            return approvals(action: arguments["action"] as? String,
                             mode: arguments["mode"] as? String,
                             id: arguments["id"] as? String)
        case "grux_model":
            return model(surface: arguments["surface"] as? String,
                         name: arguments["name"] as? String)
        case "grux_run":
            return await run(command: arguments["command"] as? String)
        case "grux_ask":
            return await ask(text: arguments["text"] as? String ?? "")
        case "grux_agent":
            return await agent(text: arguments["text"] as? String,
                               job: arguments["job"] as? String)
        case "grux_open":
            return open(surface: arguments["surface"] as? String)
        case "grux_meeting":
            return await meeting(action: arguments["action"] as? String ?? "",
                                 id: arguments["id"] as? String)
        case "grux_shell":
            return await shell(command: arguments["command"] as? String ?? "",
                               timeoutSec: arguments["timeout_sec"] as? Double)
        case "grux_transcribe":
            return await transcribe(path: arguments["path"] as? String ?? "")
        default:
            return MCPWire.textFailure("Unknown tool: \(name)")
        }
    }

    private static func status() -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(SetupStatusFile.current()),
              let text = String(data: data, encoding: .utf8) else {
            return MCPWire.textFailure("Could not encode the setup status")
        }
        return MCPWire.textResult(text)
    }

    private static func setFeatures(_ ids: [String]) -> [String: Any] {
        let known = Set(FeatureRegistry.rows.map(\.id))
        let unknown = ids.filter { !known.contains($0) }
        // NAMED, not dropped. Silently ignoring a misspelled id would apply a selection the
        // caller did not ask for and report it as theirs.
        guard unknown.isEmpty else {
            return MCPWire.textFailure("No feature with id " + unknown.joined(separator: ", "))
        }
        FeatureSelection.choose(ids)
        let unmet = FeatureSelection.unmetDependencies()
        var text = "\(ids.count) feature\(ids.count == 1 ? "" : "s") on, "
            + "\(known.count - ids.count) off."
        if !unmet.isEmpty {
            // Warn, never silently fix. The settled decision is explicit that a selection
            // which cannot do what was asked must be expressible while somebody thinks
            // about it, not quietly corrected underneath them.
            text += " Warning: " + unmet.map {
                "\($0.feature.label) needs \($0.needs.joined(separator: ", ")), which "
                + "\($0.needs.count == 1 ? "is" : "are") off."
            }.joined(separator: " ")
        }
        return MCPWire.textResult(text)
    }

    private static func toggleFeature(_ id: String, on: Bool) -> [String: Any] {
        // The LABEL, not the id. Everything else a person reads uses labels, and "meetings
        // is now off" beside "Warning: Speakers needs meetings" is two registers in one
        // sentence. The id is for the agent and it already sent it.
        guard let row = FeatureRegistry.rows.first(where: { $0.id == id }) else {
            return MCPWire.textFailure("No feature with id \(id)")
        }
        on ? FeatureSelection.enable(id) : FeatureSelection.disable(id)
        let unmet = FeatureSelection.unmetDependencies()
        var text = "\(row.label) is now \(on ? "on" : "off")."
        if !unmet.isEmpty {
            text += " Warning: " + unmet.map {
                let names = $0.needs.compactMap { dep in
                    FeatureRegistry.rows.first { $0.id == dep }?.label ?? dep
                }
                return "\($0.feature.label) needs \(names.joined(separator: ", "))"
            }.joined(separator: "; ") + "."
        }
        return MCPWire.textResult(text)
    }

    private static func requestPermission(_ rawID: String) -> [String: Any] {
        guard let req = SetupRequirement(rawValue: rawID) else {
            return MCPWire.textFailure("No capability with id \(rawID)")
        }
        guard req.kind == .perm else {
            return MCPWire.textFailure(
                "\(rawID) is a \(req.kind.rawValue), not a macOS permission. "
                + "Only perm.* ids can be requested this way.")
        }
        if CapabilityResolver.isSatisfied(req) {
            return MCPWire.textResult("\(rawID) is already granted. Nothing was asked.")
        }
        // THE APP ASKS, NEVER THE CALLER. macOS attributes a TCC request to the responsible
        // process, so a prompt raised by a command line tool grants the permission to the
        // terminal that launched it and Grux still does not have it. Bringing the app
        // forward first is not politeness, it is the only way the grant lands on the right
        // bundle, and it is also why the person sees Grux's name on the dialog rather than
        // their shell's.
        NSApp.activate(ignoringOtherApps: true)

        // Fire and answer immediately, because a permission dialog is a person deciding and
        // this call must not hold a socket open across it. The status file is rewritten by
        // `writeAfter` once the dialog has actually been answered, which is the whole reason
        // that helper exists: writing at the moment the request was MADE is how
        // mic-status.json spent weeks reporting the state from before the change.
        Task { @MainActor in
            await SetupStatusFile.writeAfter {
                _ = await CapabilityRequest.request(req)
            }
        }
        return MCPWire.textResult(
            "Grux is asking for \(req.label). Answer the dialog, then read grux_status. "
            + "The status file is rewritten once you have answered, not before.")
    }

    // MARK: - Shell undo

    /// Live sessions and dead ones, merged, live winning.
    ///
    /// The two differ in a way that matters. A LIVE session's records are held in memory by
    /// the session itself, and that is the copy its own tooling mutates. A finished session
    /// has only what is on disk. Reading the live one from disk would be stale the moment the
    /// session took another snapshot, so the manager is asked first and the index fills in
    /// the rest.
    static func shellSnapshots() async -> [String: Any] {
        let live = await ShellSessionManager.shared.listSessions()
        var seen = Set<String>()
        var out: [[String: Any]] = []

        for info in live {
            seen.insert(info.sessionId)
            let records = (try? await ShellSessionManager.shared
                .listSnapshots(sessionId: info.sessionId)) ?? []
            out.append([
                "session_id": info.sessionId,
                "root_dir": info.rootDir,
                "live": true,
                "restorable": !records.isEmpty,
                "snapshots": records.map(describe),
            ])
        }

        for session in await ShellSnapshotIndex.sessions() where !seen.contains(session.sessionId) {
            out.append([
                "session_id": session.sessionId,
                "root_dir": session.rootDir ?? "",
                "live": false,
                "restorable": session.isRestorable,
                // WHY it cannot be restored, rather than a bare false. The two reasons need
                // different things from the reader: a folder that moved can be moved back, a
                // repository that never recorded its work tree cannot be helped.
                "not_restorable_because": session.isRestorable ? ""
                    : (session.rootDir == nil
                        ? "this snapshot repository does not record which folder it belongs to"
                        : (session.snapshots.isEmpty
                            ? "it holds no snapshots"
                            : "the folder it belongs to is no longer there")),
                "snapshots": session.snapshots.map(describe),
            ])
        }
        return MCPWire.textResult(json(["sessions": out]))
    }

    private static func describe(_ r: ShellSnapshotRecord) -> [String: Any] {
        ["id": r.snapshotId, "label": r.label, "trigger": r.trigger,
         "command_index": r.commandIndex,
         "created_at": ISO8601DateFormatter().string(from: r.createdAt)]
    }

    /// Roll one session's folder back.
    ///
    /// A LIVE session goes through its manager rather than through a fresh store. Restoring
    /// behind a live session's back would leave its in-memory record list describing a work
    /// tree that no longer matches it, and the next undo inside that session would target the
    /// wrong commit.
    static func shellUndo(snapshotId: String) async -> [String: Any] {
        for info in await ShellSessionManager.shared.listSessions() {
            let records = (try? await ShellSessionManager.shared
                .listSnapshots(sessionId: info.sessionId)) ?? []
            guard records.contains(where: { $0.snapshotId == snapshotId }) else { continue }
            do {
                let result = try await ShellSessionManager.shared
                    .undo(sessionId: info.sessionId, to: snapshotId)
                return MCPWire.textResult(json([
                    "restored_to": result.restoredTo, "changed": result.changed,
                    "session_id": info.sessionId, "live": true,
                ]))
            } catch {
                return MCPWire.textFailure("Could not undo: \(error)")
            }
        }

        guard let (session, _) = await ShellSnapshotIndex.locate(snapshotId: snapshotId) else {
            return MCPWire.textFailure("No snapshot called \(snapshotId). "
                                     + "Call grux_shell_snapshots to see them.")
        }
        guard let root = session.rootDir else {
            return MCPWire.textFailure("That snapshot's repository does not record which folder "
                                     + "it belongs to, so there is nothing safe to restore.")
        }
        guard FileManager.default.fileExists(atPath: root) else {
            return MCPWire.textFailure("The folder that snapshot belongs to is gone: \(root)")
        }

        let store = ShellSnapshotStore(sessionId: session.sessionId, rootDir: root)
        do {
            try await store.hydrate()
            let changed = try await store.restore(to: snapshotId)
            return MCPWire.textResult(json([
                "restored_to": snapshotId, "changed": changed,
                "session_id": session.sessionId, "live": false,
            ]))
        } catch {
            return MCPWire.textFailure("Could not undo: \(error)")
        }
    }

    private static func json(_ any: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: any,
                                                  options: [.prettyPrinted, .sortedKeys]),
              let t = String(data: d, encoding: .utf8) else { return "{}" }
        return t
    }

    // MARK: - Credentials

    /// Only a `key.*` capability, and only one Grux actually asks for.
    ///
    /// Refusing by name matters here. A permission or a consent step arriving through the
    /// credential door would either be silently ignored or, worse, written into the Keychain
    /// under a name nothing reads, and the person would believe they had connected something.
    private static func credentialKey(for id: String) -> (SetupRequirement, KeychainStore.Key)? {
        guard let requirement = SetupRequirement(rawValue: id), requirement.kind == .key,
              let key = CapabilityResolver.keychainKey(for: requirement) else { return nil }
        return (requirement, key)
    }

    static func connect(capability id: String, value: String) -> [String: Any] {
        guard let (requirement, key) = credentialKey(for: id) else {
            return MCPWire.textFailure(refusal(for: id))
        }
        guard KeychainStore.set(key, value) else {
            return MCPWire.textFailure("The Keychain refused to store \(requirement.label). "
                                       + "That is usually a locked login keychain.")
        }
        // The status document is how every read surface learns this changed, so refresh it
        // before answering rather than leaving the CLI to guess.
        SetupStatusFile.write()
        // NOTE the value is never echoed back, not even truncated. A prefix of a credential
        // is still a credential in a log.
        return MCPWire.textResult("\(requirement.label) is stored.")
    }

    static func disconnect(capability id: String) -> [String: Any] {
        guard let (requirement, key) = credentialKey(for: id) else {
            return MCPWire.textFailure(refusal(for: id))
        }
        guard KeychainStore.exists(key) else {
            // NOT AN ERROR. Forgetting something already forgotten is the state the caller
            // wanted, and failing here would make the command non-idempotent for no reason.
            return MCPWire.textResult("\(requirement.label) was not stored, so there was "
                                      + "nothing to forget.")
        }
        guard KeychainStore.delete(key) else {
            return MCPWire.textFailure("The Keychain refused to remove \(requirement.label).")
        }
        SetupStatusFile.write()
        return MCPWire.textResult("\(requirement.label) is forgotten.")
    }

    /// One sentence saying why an id was refused, and they are different reasons.
    private static func refusal(for id: String) -> String {
        guard let requirement = SetupRequirement(rawValue: id) else {
            return "No capability called \(id)."
        }
        switch requirement.kind {
        case .perm:
            return "\(requirement.label) is a macOS permission, not a credential. Nothing "
                 + "can store one: open Grux and it will ask."
        case .step:
            return "\(requirement.label) is a setup step, not a credential."
        case .endpoint:
            return "\(requirement.label) is an address rather than a secret. Set it in "
                 + "Settings, where it can be seen and corrected."
        case .key:
            return "\(requirement.label) has no Keychain entry mapped to it, which is a bug "
                 + "in Grux rather than something you did."
        }
    }

    // MARK: - Settings

    /// The settings this tool will read or write, and NOTHING ELSE.
    ///
    /// ## Why the list is ten and not fifty five
    ///
    /// `docs/contract.md` declares 55 config keys. Reconciled against the source: 8 of them
    /// are actually read anywhere, 47 are declared and implemented NOWHERE, and the
    /// capability resolver names 10 UserDefaults-backed keys of which 2 the contract does
    /// not declare at all.
    ///
    /// Exposing all 55 would present forty seven settings that do nothing as though they
    /// were settings. Somebody would set one, see no effect, and reasonably conclude the
    /// command is broken. So this exposes exactly the keys the app genuinely consults, and
    /// the gap between contract and implementation is a decision for the owner rather than
    /// something to paper over here.
    ///
    /// NO SECRET IS REACHABLE THROUGH THIS DOOR. Every key below is an address, a path or a
    /// list of accounts. Credentials live in the Keychain, arrive through `grux_connect`,
    /// and are never readable back by anything.
    static let settableKeys: [String] = [
        "grux.github.repos",
        "grux.mail.accounts",
        "grux.mail.graph_accounts",
        "grux.media.service_url",
        "grux.model.ollama_host",
        "grux.portfolio.registry_url",
        "grux.sandbox.watched_root",
        "grux.social.accounts",
        "grux.uptime.targets",
        "grux.webhook.inbox_port",
    ]

    static func config(key: String?, value: String?) -> [String: Any] {
        let defaults = UserDefaults.standard

        // LIST
        guard let key else {
            let rows = settableKeys.map { k -> [String: Any] in
                var row: [String: Any] = [
                    "key": k, "value": describe(defaults.object(forKey: k)),
                    "set": defaults.object(forKey: k) != nil,
                ]
                // WHAT THIS KEY IS FOR, AND WHETHER THAT IS ALREADY HANDLED.
                //
                // Several capabilities are satisfied by a real store rather than by their
                // config key: `endpoint.imap` reads EmailAccountStore, not
                // `grux.mail.accounts`. So a bare "not set" appeared beside working mail,
                // which is true about the key and false about the thing the reader cares
                // about. Measured: `grux config` listed all ten as not set while
                // `grux status` reported endpoint.imap, endpoint.microsoft_graph and
                // endpoint.ollama satisfied.
                if let requirement = SetupRequirement.allCases.first(where: {
                    CapabilityResolver.configKey(for: $0) == k
                }) {
                    row["capability"] = requirement.rawValue
                    row["capabilityLabel"] = requirement.label
                    row["capabilitySatisfied"] = CapabilityResolver.isSatisfied(requirement)
                }
                return row
            }
            // AND THE KEYS IMPLEMENTED UNDER A SWIFT NAME. Ten of the contract's keys are
            // literal UserDefaults strings and were the only ones listed here; the rest read
            // as unimplemented to a grep while being perfectly alive under another name. See
            // ConfigBridge for the measurement that corrected it.
            let bridged = ConfigBridge.entries.map { e -> [String: Any] in
                let value = e.read()
                var row: [String: Any] = [
                    "key": e.key, "value": value, "set": !value.isEmpty, "shape": e.shape,
                ]
                if let requirement = SetupRequirement.allCases.first(where: {
                    CapabilityResolver.configKey(for: $0) == e.key
                }) {
                    row["capability"] = requirement.rawValue
                    row["capabilityLabel"] = requirement.label
                    row["capabilitySatisfied"] = CapabilityResolver.isSatisfied(requirement)
                }
                return row
            }
            let all = (rows + bridged).sorted {
                ($0["key"] as? String ?? "") < ($1["key"] as? String ?? "")
            }
            return MCPWire.textResult(jsonText(["settings": all]))
        }

        // A bridged key is handled entirely by its entry: reading and writing both go
        // through the property that implements it, so the app and the CLI cannot end up
        // with two different opinions about the same setting.
        if let entry = ConfigBridge.entry(for: key) {
            guard let value else {
                let current = entry.read()
                return MCPWire.textResult(jsonText([
                    "key": key, "value": current, "set": !current.isEmpty, "shape": entry.shape,
                ]))
            }
            guard let written = entry.write(value) else {
                // NAMES WHAT IT WANTED. A refusal that only says no sends somebody back to
                // the documentation for a value they were one character away from.
                return MCPWire.textFailure(
                    "\(key) takes \(entry.shape). \"\(value)\" is not one of those, so nothing "
                    + "was changed.")
            }
            SetupStatusFile.write()
            return MCPWire.textResult(jsonText(["key": key, "value": written, "set": true]))
        }

        guard settableKeys.contains(key) else {
            // Named refusal, and it distinguishes the two reasons. A key the contract
            // declares but nothing implements is a different problem from a typo, and
            // sending somebody to check their spelling for the first one wastes their time.
            let declared = key.hasPrefix("grux.")
            return MCPWire.textFailure(declared
                ? "\(key) is not a setting Grux reads. The contract declares more keys than "
                + "the app implements, and this is one of them."
                : "No setting called \(key).")
        }

        // READ
        guard let value else {
            return MCPWire.textResult(jsonText([
                "key": key, "value": describe(defaults.object(forKey: key)),
                "set": defaults.object(forKey: key) != nil,
            ]))
        }

        // WRITE. A list-shaped key takes comma separated entries, because a shell cannot
        // hand over an array and asking somebody to write JSON at a prompt is hostile.
        if key.hasSuffix("accounts") || key.hasSuffix("repos") || key.hasSuffix("targets") {
            let entries = value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            defaults.set(entries, forKey: key)
        } else {
            defaults.set(value, forKey: key)
        }
        SetupStatusFile.write()
        return MCPWire.textResult(jsonText(["key": key, "value": value, "set": true]))
    }

    /// An array renders as what it is rather than as Swift's description of it.
    private static func describe(_ any: Any?) -> String {
        switch any {
        case let list as [Any]: return list.map { "\($0)" }.joined(separator: ", ")
        case let s as String:   return s
        case .some(let other):  return "\(other)"
        case .none:             return ""
        }
    }

    /// Internal rather than private BECAUSE THE HANDLERS LIVE IN OTHER FILES. Swift's
    /// `private` is file scoped, so an extension in GruxControlTools+Run.swift cannot see
    /// it, and the alternative is a second copy of three lines in every handler file.
    static func jsonText(_ any: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: any,
                                                  options: [.prettyPrinted, .sortedKeys]),
              let t = String(data: d, encoding: .utf8) else { return "{}" }
        return t
    }

    // MARK: - Notes and brands

    static func note(body: String, title: String, tags: [String]) -> [String: Any] {
        let note = NotesStore.shared.create(title: title, body: body, tags: tags)
        // The ID comes back so a caller can find it again. The BODY does not: it is what the
        // caller just sent, and echoing it doubles the size of every reply for nothing.
        return MCPWire.textResult(jsonText(["id": note.id.uuidString,
                                            "title": note.title]))
    }

    /// Which brand later commands are about.
    ///
    /// Stored under the same UserDefaults the rest of the app uses, so the app and the CLI
    /// cannot disagree about it. The brand LIST comes from `brand-attribution.json`, which is
    /// the file the empire dashboard already reads, rather than a second list that would
    /// drift from it within a week.
    static let currentBrandKey = "grux.brand.current"

    static func brands(use: String?) -> [String: Any] {
        let known = BrandAttribution.loadConfig().brands.map(\.name)

        guard let use else {
            return MCPWire.textResult(jsonText([
                "brands": known.sorted { $0.lowercased() < $1.lowercased() },
                "current": UserDefaults.standard.string(forKey: currentBrandKey) ?? "",
            ]))
        }

        if use == "none" {
            UserDefaults.standard.removeObject(forKey: currentBrandKey)
            return MCPWire.textResult(jsonText(["current": "", "brands": known]))
        }

        // MATCHED CASE INSENSITIVELY, because somebody types a name in lower case and the
        // ledger holds it in capitals. Refusing that teaches them nothing and costs them a
        // second attempt.
        guard let match = known.first(where: { $0.lowercased() == use.lowercased() }) else {
            // CASE INSENSITIVE, like every other list a person reads. A plain `<` on String
            // is an ASCII sort, so every capitalised name files before every lower case one:
            // "Zebra" lands ahead of "apple" because Z is 0x5A and a is 0x61. This is the
            // same defect swept out of the CLI earlier, reappearing in app-side code written
            // after that sweep, which is how you learn that fixing call sites does not fix
            // the habit.
            let names = known.sorted { $0.lowercased() < $1.lowercased() }
            return MCPWire.textFailure("No brand called \(use). Grux knows "
                + (names.isEmpty ? "none yet." : names.joined(separator: ", ") + "."))
        }
        UserDefaults.standard.set(match, forKey: currentBrandKey)
        return MCPWire.textResult(jsonText(["current": match, "brands": known]))
    }
}
