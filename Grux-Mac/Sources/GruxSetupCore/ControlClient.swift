import Foundation

/// Talks to the running Grux over its control socket.
///
/// Reads come from `setup-status.json` and do not need the app to be running, which is
/// deliberate: the moment somebody most wants to ask what is wrong is the moment the app is
/// probably closed. Writes need the app, because the app is the only thing that can act
/// under its own signature, and this is how they get there.
public struct ControlClient: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        /// No socket file. Grux is not running, or is older than the control plane.
        case notRunning(path: String)
        /// The socket is there and refused or dropped us.
        case couldNotConnect(path: String, errno: Int32)
        /// Connected, asked, and nothing came back inside the deadline.
        case noAnswer(seconds: Double)
        /// It answered something this client cannot read.
        case badAnswer(String)
        /// The tool ran and reported that it could not do the thing.
        case toolFailed(String)
    }

    public let socketPath: String
    public let timeout: TimeInterval

    public init(socketPath: String = ControlClient.defaultSocketPath,
                timeout: TimeInterval = 10) {
        self.socketPath = socketPath
        self.timeout = timeout
    }

    public static var defaultSocketPath: String {
        NSHomeDirectory() + "/.grux/mcp.sock"
    }

    /// Whether the app is actually there to talk to.
    ///
    /// A CONNECT, NOT A FILE TEST, and the difference is a false claim on fourteen screens.
    /// This asked whether the socket FILE exists, and quitting Grux LEAVES THAT FILE BEHIND:
    /// measured on this Mac, `~/.grux/mcp.sock` survived a quit and a connect to it returned
    /// ECONNREFUSED. So with Grux closed, `grux doctor` drew "Grux is running" as satisfied,
    /// `grux status` reported the app up, and `grux setup` ticked the same row.
    ///
    /// A unix socket connect against a live listener costs microseconds and against a dead
    /// one fails immediately, so there is no reason to guess. The descriptor is closed on
    /// every path out: this is a probe, not a session.
    public var isAvailable: Bool {
        guard socketFileExists else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else { return false }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        src, maxLen - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        } == 0
    }

    /// Whether the socket FILE is there, which is a different question and still worth
    /// asking: it is what separates "Grux has never run" from "Grux ran and stopped", and
    /// those two get different sentences.
    public var socketFileExists: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }

    // MARK: - One call

    /// Call a tool and return its text content.
    ///
    /// Blocking on purpose. A CLI command is a single question with a single answer and
    /// there is nothing else for this process to do while it waits, so an async surface here
    /// would buy structure and no behaviour. The deadline is real: a hung app must produce a
    /// designed "no answer" state rather than a command that never returns.
    public func call(tool: String, arguments: [String: Any] = [:]) -> Result<String, Failure> {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]
        switch request(envelope) {
        case .failure(let why):
            return .failure(why)
        case .success(let object):
            if let err = object["error"] as? [String: Any] {
                return .failure(.badAnswer((err["message"] as? String) ?? "protocol error"))
            }
            guard let result = object["result"] as? [String: Any],
                  let content = result["content"] as? [[String: Any]],
                  let text = content.first?["text"] as? String else {
                return .failure(.badAnswer("the reply had no text content"))
            }
            // A TOOL FAILURE IS NOT A PROTOCOL FAILURE. The server says so with `isError`,
            // and collapsing the two would have the caller retry a request shape that was
            // never wrong. This surfaces the tool's own message instead.
            if (result["isError"] as? Bool) == true {
                return .failure(.toolFailed(text))
            }
            return .success(text)
        }
    }

    /// One JSON-RPC request, one JSON-RPC reply, both verbatim.
    ///
    /// `call` is the shape every command wants: name a tool, get its text. This is the shape
    /// `grux serve` wants, which is no shape at all. It bridges stdio to this socket for an
    /// agent that cannot open a unix socket, and a bridge that understood the messages it
    /// carried would have to be taught every method the app will ever add. So it carries
    /// them closed.
    ///
    /// `waitForReply: false` is for a NOTIFICATION, which is a request with no id and which
    /// the specification says gets no response. Waiting on one would block until the
    /// deadline every time, and a bridge that stalls ten seconds on every `notifications/
    /// initialized` is a bridge nobody can use.
    public func request(_ object: [String: Any],
                        waitForReply: Bool = true) -> Result<[String: Any], Failure> {
        // GUARDED ON THE FILE, NOT ON `isAvailable`. The two answer different questions and
        // the distinction is the designed one: no file at all means Grux has never run here,
        // while a file that refuses a connection means it ran and stopped. `Frame.explain`
        // writes a different sentence for each, and collapsing them onto the liveness probe
        // would lose the one that tells somebody the leftover socket is normal.
        guard socketFileExists else { return .failure(.notRunning(path: socketPath)) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.couldNotConnect(path: socketPath, errno: errno)) }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < maxLen else {
            return .failure(.couldNotConnect(path: socketPath, errno: ENAMETOOLONG))
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { src in
                strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self),
                        src, maxLen - 1)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
        }
        guard connected == 0 else {
            return .failure(.couldNotConnect(path: socketPath, errno: errno))
        }

        var tv = timeval()
        tv.tv_sec = Int(timeout)
        tv.tv_usec = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        // A dead peer must surface as an error return, not a signal that kills the process
        // mid-command.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        guard var body = try? JSONSerialization.data(withJSONObject: object) else {
            return .failure(.badAnswer("could not encode the request"))
        }
        body.append(0x0A)
        let wrote = body.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote == body.count else {
            return .failure(.couldNotConnect(path: socketPath, errno: errno))
        }

        guard waitForReply else { return .success([:]) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.contains(0x0A) { break }
        }
        guard let nl = buffer.firstIndex(of: 0x0A) else {
            return .failure(.noAnswer(seconds: timeout))
        }

        let line = buffer.subdata(in: buffer.startIndex..<nl)
        guard let reply = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return .failure(.badAnswer("the reply was not JSON"))
        }
        return .success(reply)
    }
}
