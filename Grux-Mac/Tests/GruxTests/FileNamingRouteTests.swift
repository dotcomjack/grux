import XCTest
@testable import Grux

/// FILE TEXT NEVER LEAVES THIS MAC.
///
/// The router's "local" route sends to whatever the Ollama base URL holds, and
/// that has held hosted providers and LAN machines, so the namer checks the
/// address itself, refuses anything that is not loopback or not Ollama, and
/// builds its own backend from the address it checked. The ambient
/// helper is not allowed either: it falls back to the cloud when its local
/// call fails. The last test reads the feature's source and fails the day a
/// cloud route appears in it.
@MainActor
final class FileNamingRouteTests: XCTestCase {

    private var savedBaseURL = ""
    private var savedModel = ""
    private var savedWritesSuspended = false
    private var stubs: [OllamaStub] = []

    override func setUp() async throws {
        try await super.setUp()
        savedBaseURL = AppState.shared.config.ollamaBaseURL
        savedModel = AppState.shared.config.offlineLLMModel
        savedWritesSuspended = Persistence.writesSuspended
        // In-memory state only, as in ChatBackgroundRoutingTests: the real
        // config.json stays out of the run.
        Persistence.writesSuspended = true
        ModelRegistry.shared.resetLocalForTest()
    }

    override func tearDown() async throws {
        for stub in stubs { stub.stop() }
        stubs = []
        AppState.shared.config.ollamaBaseURL = savedBaseURL
        AppState.shared.config.offlineLLMModel = savedModel
        Persistence.writesSuspended = savedWritesSuspended
        ModelRegistry.shared.resetLocalForTest()
        try await super.tearDown()
    }

    // MARK: - The address

    func testAHostedBaseURLGivesNoRoute() async {
        AppState.shared.config.ollamaBaseURL = "https://models.example.com/api"
        let resolution = await FileNamingRoute.resolution()
        XCTAssertEqual(resolution.statusName, "notLoopback")
        let route = await FileNamingRoute.resolve()
        XCTAssertNil(route)
    }

    func testALANBaseURLGivesNoRoute() async {
        AppState.shared.config.ollamaBaseURL = "http://192.168.1.20:11434"
        let resolution = await FileNamingRoute.resolution()
        XCTAssertEqual(resolution.statusName, "notLoopback", "a LAN server is another machine")
    }

    /// Loopback, but nothing listens on port 1: no model, and no fallback.
    func testALoopbackServerWithNoModelGivesNoRoute() async {
        AppState.shared.config.ollamaBaseURL = "http://127.0.0.1:1"
        let resolution = await FileNamingRoute.resolution()
        XCTAssertEqual(resolution.statusName, "noLocalModel")
        XCTAssertNil(resolution.route)
    }

    func testOnlyLoopbackAddressesAreAllowed() {
        XCTAssertTrue(FileNamingRoute.isAllowedServer(baseURL: "http://localhost:11434"))
        XCTAssertTrue(FileNamingRoute.isAllowedServer(baseURL: "http://127.0.0.1:11434"))
        XCTAssertTrue(FileNamingRoute.isAllowedServer(baseURL: " http://127.0.0.1:11434 "))
        XCTAssertTrue(FileNamingRoute.isAllowedServer(baseURL: "http://127.0.0.1:11434/v1"))
        XCTAssertTrue(FileNamingRoute.isAllowedServer(baseURL: "http://[::1]:11434"))
        XCTAssertTrue(FileNamingRoute.isAllowedServer(baseURL: "http://127.4.5.6:11434"))
        XCTAssertFalse(FileNamingRoute.isAllowedServer(baseURL: "http://192.168.1.20:11434"))
        XCTAssertFalse(FileNamingRoute.isAllowedServer(baseURL: "http://10.0.0.5:11434"))
        XCTAssertFalse(FileNamingRoute.isAllowedServer(baseURL: "http://studio.local:11434"))
        XCTAssertFalse(FileNamingRoute.isAllowedServer(baseURL: "https://models.example.com"))
        XCTAssertFalse(FileNamingRoute.isAllowedServer(baseURL: ""))
    }

    /// THE CHECK READS THE ADDRESS THE WAY THE REQUEST WILL. The old check cut
    /// the host its own way, so `http://evil.example#@localhost:11434` passed
    /// as localhost while Foundation connects to evil.example (review
    /// 2026-10-28). Each of these is refused.
    func testAnAddressFoundationReadsDifferentlyIsRefused() {
        let crafted = [
            "http://evil.example#@localhost:11434",
            "http://evil.example?@localhost:11434",
            "http://evil.example/#@127.0.0.1:11434",
            "http://localhost:11434@evil.example",
            "http://user@localhost:11434",
            "http://user:pass@127.0.0.1:11434",
            "http://localhost:11434/proxy",
            "http://localhost:11434?x=1",
            "http://127.1:11434",
            "http://0x7f.0.0.1:11434",
            "http://0177.0.0.1:11434",
            "http://127.000.000.001:11434",
            "http://localhost.:11434",
            "http://localhost.evil.example:11434",
            "http://127.0.0.1.evil.example:11434",
            "http://[::ffff:127.0.0.1]:11434",
            "ftp://localhost:11434",
            "localhost:11434",
        ]
        for raw in crafted {
            XCTAssertFalse(FileNamingRoute.isAllowedServer(baseURL: raw), "\(raw) was taken for this Mac")
            XCTAssertNil(FileNamingRoute.loopbackBase(raw), raw)
        }
        // Control: the address the backend is given is the host that was checked.
        XCTAssertEqual(FileNamingRoute.loopbackBase(" http://LocalHost:11434/v1/ "), "http://localhost:11434")
        XCTAssertEqual(FileNamingRoute.loopbackBase("http://[::1]:11434"), "http://[::1]:11434")
        XCTAssertEqual(FileNamingRoute.loopbackBase("https://127.0.0.1"), "https://127.0.0.1")
    }

    func testACraftedBaseURLGivesNoRoute() async {
        AppState.shared.config.ollamaBaseURL = "http://evil.example#@localhost:11434"
        let resolution = await FileNamingRoute.resolution()
        XCTAssertEqual(resolution.statusName, "notLoopback")
    }

    // MARK: - The server

    private func stub(_ routes: [String: String]) throws -> OllamaStub {
        let s = OllamaStub(routes: routes)
        try s.start()
        XCTAssertGreaterThan(s.port, 0, "the stub never bound a port")
        stubs.append(s)
        return s
    }

    private static let ollama = ["/api/version": #"{"version":"0.22.0"}"#]

    private static func tags(_ names: [String]) -> String {
        #"{"models":["# + names.map { #"{"name":""# + $0 + #""}"# }.joined(separator: ",") + "]}"
    }

    /// A LOOPBACK SERVER THAT IS NOT OLLAMA GIVES NO ROUTE. An OpenAI
    /// compatible server on this Mac can be a proxy to anywhere; only Ollama's
    /// own `/api/version` counts (review 2026-10-28: nothing tested this).
    func testALoopbackServerThatIsNotOllamaGivesNoRoute() async throws {
        let compat = try stub(["/v1/models": #"{"data":[{"id":"grux-local:4b"}]}"#,
                               "/api/tags": Self.tags(["grux-local:4b"])])
        AppState.shared.config.ollamaBaseURL = compat.baseURL
        let resolution = await FileNamingRoute.resolution()
        XCTAssertEqual(resolution.statusName, "noLocalModel", "a server that is not Ollama became the route")
        XCTAssertTrue(compat.requestLines.contains { $0.hasPrefix("GET /api/version") },
                      "control: the route never asked the server what it is")

        // Control: the same models behind a server that IS Ollama make a route.
        var routes = Self.ollama
        routes["/api/tags"] = Self.tags(["grux-local:4b"])
        let real = try stub(routes)
        AppState.shared.config.ollamaBaseURL = real.baseURL
        let ok = await FileNamingRoute.resolution()
        XCTAssertEqual(ok.statusName, "ok", "control: an Ollama with a model gave no route")
        XCTAssertEqual(ok.route?.model, "grux-local:4b")
    }

    func testAnOllamaWithNothingPulledGivesNoRoute() async throws {
        var routes = Self.ollama
        routes["/api/tags"] = Self.tags([])
        let empty = try stub(routes)
        AppState.shared.config.ollamaBaseURL = empty.baseURL
        let resolution = await FileNamingRoute.resolution()
        XCTAssertEqual(resolution.statusName, "noLocalModel")
    }

    /// THE ROUTE NEVER USES A BACKEND DISCOVERY BUILT. Discovery binds its
    /// backend to the address it last saw and does not run again when the
    /// base URL changes, so the old route sent file text to wherever that was
    /// (review 2026-10-28). A test cannot bind a LAN address, so a second
    /// loopback stub plays the stale server: discovery runs against it, the
    /// config moves on, and it must receive nothing more.
    func testAStaleDiscoveredBackendIsNeverUsed() async throws {
        var staleRoutes = Self.ollama
        staleRoutes["/api/tags"] = Self.tags(["grux-local:4b"])
        let stale = try stub(staleRoutes)
        AppState.shared.config.ollamaBaseURL = stale.baseURL
        await ModelRegistry.shared.discoverLocal()
        XCTAssertTrue(ModelRegistry.shared.localUsable, "control: discovery did not take the stale server")

        // The config now names a server on this Mac that is not Ollama. The
        // old route passed the loopback check and handed back the stale backend.
        let other = try stub(["/v1/models": #"{"data":[]}"#])
        AppState.shared.config.ollamaBaseURL = other.baseURL
        let staleBefore = stale.requestLines.count
        let refused = await FileNamingRoute.resolution()
        XCTAssertEqual(refused.statusName, "noLocalModel", "the route fell back to the backend discovery built")
        XCTAssertEqual(stale.requestLines.count, staleBefore, "the stale server was asked")

        // And when the config names a real Ollama, the naming call goes there
        // and nowhere else.
        var liveRoutes = Self.ollama
        liveRoutes["/api/tags"] = Self.tags(["grux-local:4b"])
        liveRoutes["/api/chat"] = #"{"model":"grux-local:4b","message":{"role":"assistant","content":"Northwind Invoice"},"done":true}"#
        let live = try stub(liveRoutes)
        AppState.shared.config.ollamaBaseURL = live.baseURL
        let resolved = await FileNamingRoute.resolution()
        let route = try XCTUnwrap(resolved.route, "control: a real Ollama gave no route")
        _ = try? await route.backend.completeShortAnswer(
            apiKey: route.apiKey, model: route.model, system: "Name the file.",
            messages: [ClaudeMessage(role: "user", content: "Northwind Studio invoice")],
            maxTokens: 24, temperature: 0, spanName: "test.autoname", feature: "file_autoname_test")
        XCTAssertTrue(live.requestLines.contains { $0.hasPrefix("POST ") },
                      "the naming call did not reach the server the config names: \(live.requestLines)")
        XCTAssertEqual(stale.requestLines.count, staleBefore, "the naming call went to the stale server")
        XCTAssertFalse(other.requestLines.contains { $0.hasPrefix("POST ") })
    }

    // MARK: - The model

    func testTheGruxLocalSizeFollowsMemory() {
        XCTAssertEqual(FileNamingRoute.idealGruxLocalTag(memoryGB: 8), "gruxai.com/grux/grux-local:2b")
        XCTAssertEqual(FileNamingRoute.idealGruxLocalTag(memoryGB: 16), "gruxai.com/grux/grux-local:4b")
        XCTAssertEqual(FileNamingRoute.idealGruxLocalTag(memoryGB: 24), "gruxai.com/grux/grux-local:9b")
        XCTAssertEqual(FileNamingRoute.idealGruxLocalTag(memoryGB: 64), "gruxai.com/grux/grux-local:9b")
    }

    func testThePickPrefersTheRightSizeThenAnySizeThenTheChatModel() {
        let four = "gruxai.com/grux/grux-local:4b"
        let two = "gruxai.com/grux/grux-local:2b"
        XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: 16, installed: ["qwen3.5:4b", two, four], fallback: "llama3.2:3b"), four)
        XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: 8, installed: ["qwen3.5:4b", four], fallback: "llama3.2:3b"), four,
                       "an installed Grux Local of another size beats the chat model")
        XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: 16, installed: ["qwen3.5:4b", "llama3.2:3b"], fallback: "llama3.2:3b"), "llama3.2:3b",
                       "with no Grux Local the chat model is used, so no second model loads")
        XCTAssertNil(FileNamingRoute.pickModel(memoryGB: 16, installed: ["qwen3.5:4b"], fallback: "llama3.2:3b"),
                     "a chat model the server does not hold is no route")
        XCTAssertTrue(FileNamingRoute.sameTag(four + ":latest", four))
        XCTAssertFalse(FileNamingRoute.sameTag(two, four))
    }

    /// BOTH NAMES OLLAMA GIVES A GRUX LOCAL. Pulled from the registry it is
    /// `gruxai.com/grux/grux-local:4b`; built or copied locally it is
    /// `grux-local:4b`. The 16 GB test Mac listed the short form only, and
    /// the preview named files with qwen3.5:4b (review 2026-10-28).
    func testThePickKnowsBothNamesOfGruxLocal() {
        let measured = ["qwen3.5:4b", "grux-local:2b", "grux-local:4b", "grux-local:9b", "grux-local:latest"]
        let rows: [(memory: Double, installed: [String], expected: String, why: String)] = [
            (16, measured, "grux-local:4b", "the 16 GB test Mac's own list"),
            (8, measured, "grux-local:2b", "the short form, 8 GB size"),
            (32, measured, "grux-local:9b", "the short form, 24 GB and up size"),
            (16, ["qwen3.5:4b", "gruxai.com/grux/grux-local:4b"], "gruxai.com/grux/grux-local:4b", "the registry form"),
            (16, ["qwen3.5:4b", "grux-local:4b:latest"], "grux-local:4b:latest", "with :latest"),
            (16, ["qwen3.5:4b", "GRUX-LOCAL:4B"], "GRUX-LOCAL:4B", "any case"),
            (16, ["qwen3.5:4b", "grux-local:2b"], "grux-local:2b", "another size before the chat model"),
            (16, ["qwen3.5:4b", "grux-local:latest"], "grux-local:latest", "an untagged size before the chat model"),
            (16, ["qwen3.5:4b", "gruxai.com/grux/grux-local"], "gruxai.com/grux/grux-local", "the registry form untagged"),
            (16, ["qwen3.5:4b", "my-grux-local:4b", "grux-localish:4b"], "qwen3.5:4b", "a lookalike is not Grux Local"),
        ]
        for row in rows {
            XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: row.memory, installed: row.installed, fallback: "qwen3.5:4b"),
                           row.expected, row.why)
        }
        XCTAssertTrue(FileNamingRoute.sameTag("grux-local:4b", "gruxai.com/grux/grux-local:4b"))
        XCTAssertFalse(FileNamingRoute.isGruxLocal("qwen3.5:4b"))
    }

    /// Ollama forwards a `-cloud` tag to its hosted service, so a loopback
    /// address is not enough: the file's text would still leave the Mac.
    func testACloudTagIsNeverPicked() {
        XCTAssertNil(FileNamingRoute.pickModel(memoryGB: 16, installed: ["gpt-oss:120b-cloud"], fallback: "gpt-oss:120b-cloud"),
                     "the chat model is a cloud tag")
        XCTAssertEqual(FileNamingRoute.pickModel(memoryGB: 16, installed: ["gpt-oss:120b-cloud", "qwen3.5:4b"], fallback: "qwen3.5:4b"),
                       "qwen3.5:4b")
        XCTAssertTrue(FileNamingRoute.isCloudTag("gpt-oss:120b-cloud"))
        XCTAssertTrue(FileNamingRoute.isCloudTag("deepseek-v3.1:671b-cloud"))
        XCTAssertTrue(FileNamingRoute.isCloudTag("some-model:cloud"))
        XCTAssertFalse(FileNamingRoute.isCloudTag("grux-local:4b"), "control")
        XCTAssertFalse(FileNamingRoute.isCloudTag("qwen3.5:4b"), "control")
    }

    // MARK: - The source never names a cloud route

    private static let banned = ["AmbientLLM", "ClaudeClient", "provider: nil", "\"anthropic\""]

    /// The router's own local backend and model list. The route builds its
    /// backend from the address it checked and reads the models from that
    /// server, so none of these may appear (review 2026-10-28).
    private static let registryLocal = ["resolvedRouting", "ModelRegistry.shared", ".localTags",
                                        "localUsable", "localServedByOllama", "discoverLocal", "reg.local"]

    private static func hits(in text: String) -> [String] {
        banned.filter { text.contains($0) }
    }

    func testTheFeatureNeverNamesACloudRoute() throws {
        let folder = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/FileNaming")
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(files.count, 6, "the scan found too few files to be the FileNaming folder")
        var all = ""
        var found: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            all += text
            for hit in Self.hits(in: text) { found.append("\(url.lastPathComponent): \(hit)") }
        }
        XCTAssertEqual(found, [], "FileNaming names a route that can leave this Mac")
        let registry = Self.registryLocal.filter { all.contains($0) }
        XCTAssertEqual(registry, [], "FileNaming reaches for the router's discovered local backend")
        // Controls: the scan reads the real route, and the scanner can fail.
        XCTAssertTrue(all.contains("OpenAICompatBackend(baseURL: base)"), "control: the route's backend is not where the scan looked")
        XCTAssertTrue(all.contains("loopbackBase(cfg.ollamaBaseURL)"), "control: the loopback check is not where the scan looked")
        XCTAssertEqual(Self.registryLocal.filter { "let b = reg.resolvedRouting(provider: \"local\", modelOverride: m)".contains($0) },
                       ["resolvedRouting"], "control: the scanner misses the router's local route")
        XCTAssertEqual(Self.hits(in: "let r = reg.resolvedRouting(provider: nil, modelOverride: nil)"), ["provider: nil"],
                       "control: the scanner misses a planted cloud route")
        XCTAssertEqual(Self.hits(in: "await AmbientLLM.complete()").count, 1, "control: the scanner misses the ambient helper")
    }
}

/// A loopback HTTP server answering fixed bodies by path, and 404 for any
/// other path. Copied from OpenAICompatStreamFixtureTests' SSEFixtureServer,
/// which is file-private there: bound to 127.0.0.1 only (no firewall prompt,
/// unreachable from off the machine), `SO_NOSIGPIPE` so a client hanging up
/// cannot take the test process down, and every request line recorded so a
/// test can assert which server a call reached.
private final class OllamaStub: @unchecked Sendable {

    private let routes: [String: Data]
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var storedRequestLines: [String] = []

    private(set) var port: UInt16 = 0

    var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Every request line, in order.
    var requestLines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storedRequestLines
    }

    init(routes: [String: String]) {
        self.routes = routes.mapValues { Data($0.utf8) }
    }

    enum StubError: Error { case socketUnavailable, bindFailed }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StubError.socketUnavailable }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw StubError.bindFailed
        }

        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: actual.sin_port)
        listenFD = fd
        Thread.detachNewThread { self.acceptLoop(fd) }
    }

    func stop() {
        let fd = listenFD
        listenFD = -1
        if fd >= 0 { close(fd) }
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { return }
            var yes: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            serve(conn)
            close(conn)
        }
    }

    private func serve(_ conn: Int32) {
        var request = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        var headEnd: Range<Data.Index>? = nil
        while headEnd == nil {
            let n = read(conn, &buf, buf.count)
            if n <= 0 { return }
            request.append(contentsOf: buf[0..<n])
            headEnd = request.range(of: Data("\r\n\r\n".utf8))
        }
        guard let headEnd else { return }
        let head = String(decoding: request[..<headEnd.lowerBound], as: UTF8.self)
        let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
        lock.lock()
        storedRequestLines.append(line)
        lock.unlock()

        // Drain the body, so a client mid-send is never left stalled.
        var contentLength = 0
        for header in head.split(separator: "\r\n") where header.lowercased().hasPrefix("content-length:") {
            contentLength = Int(header.dropFirst("content-length:".count)
                .trimmingCharacters(in: .whitespaces)) ?? 0
        }
        var bodyRead = request.count - headEnd.upperBound
        while bodyRead < contentLength {
            let n = read(conn, &buf, buf.count)
            if n <= 0 { break }
            bodyRead += n
        }

        let parts = line.split(separator: " ")
        let target = parts.count > 1 ? String(parts[1]) : ""
        let path = target.split(separator: "?").first.map(String.init) ?? target
        let body = routes[path]
        let status = body == nil ? "404 Not Found" : "200 OK"
        let payload = body ?? Data(#"{"error":"not found"}"#.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n"
            + "Content-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        _ = writeAll(conn, Data(response.utf8)) && writeAll(conn, payload)
    }

    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { return false }
                sent += n
            }
            return true
        }
    }
}
