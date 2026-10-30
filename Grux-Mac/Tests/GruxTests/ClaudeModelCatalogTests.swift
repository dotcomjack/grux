import XCTest
@testable import Grux

/// The Chat picker's Claude list, the temperature rule and the 5.5 rates.
/// Measured 2026-10-29: the picker offered Fable 5, Opus 4.8, Sonnet 5 and
/// Haiku 4.5 while the Models API listed the 5.5 line, and Fable 5 and Sonnet 5
/// were sent a temperature on every turn.
@MainActor
final class ClaudeModelCatalogTests: XCTestCase {

    /// The ids and dates the Models API returned on 2026-10-29, in its order.
    static let liveListing = #"""
    {"data":[
     {"type":"model","id":"claude-haiku-5-5","created_at":"2026-10-07T18:00:00Z"},
     {"type":"model","id":"claude-sonnet-5-5","created_at":"2026-09-28T00:00:00Z"},
     {"type":"model","id":"claude-opus-5-5","created_at":"2026-09-21T16:24:00Z"},
     {"type":"model","id":"claude-fable-5-1","created_at":"2026-08-28T00:00:00Z"},
     {"type":"model","id":"claude-opus-5","created_at":"2026-07-24T00:00:00Z"},
     {"type":"model","id":"claude-sonnet-5","created_at":"2026-06-29T00:00:00Z"},
     {"type":"model","id":"claude-fable-5","created_at":"2026-06-07T00:00:00Z"},
     {"type":"model","id":"claude-opus-4-8","created_at":"2026-05-28T00:00:00Z"},
     {"type":"model","id":"claude-sonnet-4-6","created_at":"2026-02-17T00:00:00Z"},
     {"type":"model","id":"claude-haiku-4-5-20251001","created_at":"2025-10-15T00:00:00Z"}
    ],"has_more":false,"first_id":"claude-haiku-5-5","last_id":"claude-haiku-4-5-20251001"}
    """#

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        try await super.setUp()
        suite = "ClaudeModelCatalogTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        CatalogStubProtocol.reply = (200, Self.liveListing)
        CatalogStubProtocol.requests = []
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try await super.tearDown()
    }

    // MARK: - Reading the listing

    func testTheLiveListingGivesTheNewestOfEachFamily() {
        XCTAssertEqual(ClaudeModelCatalog.newestPerFamily(fromListing: Data(Self.liveListing.utf8)),
                       ["claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
    }

    func testNewestIsByDateNotByPosition() {
        let body = #"{"data":[{"id":"claude-opus-4-8","created_at":"2026-05-28T00:00:00Z"},"#
            + #"{"id":"claude-opus-5-5","created_at":"2026-09-21T16:24:00Z"}]}"#
        XCTAssertEqual(ClaudeModelCatalog.newestPerFamily(fromListing: Data(body.utf8)), ["claude-opus-5-5"])
    }

    func testAFamilyThePickerDoesNotOfferIsLeftOut() {
        XCTAssertNil(ClaudeModelCatalog.family(of: "claude-mythos-5-1"))
        XCTAssertNil(ClaudeModelCatalog.family(of: "gpt-5"))
        XCTAssertEqual(ClaudeModelCatalog.family(of: "claude-haiku-4-5-20251001"), "haiku")
    }

    func testAnErrorBodyIsNotAListing() {
        let body = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        XCTAssertNil(ClaudeModelCatalog.newestPerFamily(fromListing: Data(body.utf8)))
    }

    // MARK: - Asking the API

    func testWithNothingSavedThePickerShowsTheFallback() {
        let catalog = ClaudeModelCatalog(defaults: defaults, session: CatalogStubProtocol.session())
        XCTAssertEqual(catalog.ids, ClaudeModelCatalog.fallback)
    }

    func testARefreshReplacesTheListAndKeepsItForTheNextLaunch() async {
        CatalogStubProtocol.reply = (200, #"{"data":[{"id":"claude-opus-6","created_at":"2027-01-01T00:00:00Z"}]}"#)
        let catalog = ClaudeModelCatalog(defaults: defaults, session: CatalogStubProtocol.session())
        await catalog.refreshIfNeeded(apiKey: "k")
        XCTAssertEqual(catalog.ids, ["claude-opus-6"])
        let next = ClaudeModelCatalog(defaults: defaults, session: CatalogStubProtocol.session())
        XCTAssertEqual(next.ids, ["claude-opus-6"], "the next launch starts from the last good list")
        let sent = try? XCTUnwrap(CatalogStubProtocol.requests.first)
        XCTAssertEqual(sent?.url?.path, "/v1/models")
        XCTAssertEqual(sent?.value(forHTTPHeaderField: "x-api-key"), "k")
        XCTAssertNotNil(sent?.value(forHTTPHeaderField: "anthropic-version"))
    }

    func testARefusalLeavesTheListAndIsTriedAgain() async {
        CatalogStubProtocol.reply = (401, #"{"type":"error","error":{"type":"authentication_error"}}"#)
        let catalog = ClaudeModelCatalog(defaults: defaults, session: CatalogStubProtocol.session())
        await catalog.refreshIfNeeded(apiKey: "k")
        XCTAssertEqual(catalog.ids, ClaudeModelCatalog.fallback)
        CatalogStubProtocol.reply = (200, Self.liveListing)
        await catalog.refreshIfNeeded(apiKey: "k")
        XCTAssertEqual(CatalogStubProtocol.requests.count, 2, "a failed ask is retried")
        await catalog.refreshIfNeeded(apiKey: "k")
        XCTAssertEqual(CatalogStubProtocol.requests.count, 2, "a good answer is asked for once a launch")
    }

    func testNoKeyAsksNothing() async {
        let catalog = ClaudeModelCatalog(defaults: defaults, session: CatalogStubProtocol.session())
        await catalog.refreshIfNeeded(apiKey: "  ")
        XCTAssertTrue(CatalogStubProtocol.requests.isEmpty)
    }

    func testThePickerReadsTheCatalogAndHoldsNoModelList() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: root.appendingPathComponent("Sources/Grux/ChatView.swift"), encoding: .utf8)
        let body = try XCTUnwrap(src.components(separatedBy: "private var cloudModelOptions: [String] {")
            .dropFirst().first?.prefix(400))
        XCTAssertTrue(body.contains("modelCatalog.ids"), "the picker no longer reads the catalog")
        XCTAssertNil(body.range(of: #""claude-[a-z]+-\d"#, options: .regularExpression),
                     "a literal model list is back in the picker")
        XCTAssertTrue(src.contains("modelCatalog.refreshIfNeeded(apiKey:"), "nothing asks the API")
    }

    // MARK: - Temperature

    func testOnlyTheModelsThatTakeATemperatureGetOne() {
        for id in ["claude-haiku-4-5-20251001", "claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-6",
                   "claude-sonnet-4-5-20250929", "claude-opus-4-5-20251101", "claude-3-5-sonnet-20241022"] {
            XCTAssertFalse(ClaudeClient.modelDeprecatesTemperature(id), "\(id) takes a temperature")
        }
        for id in ["claude-fable-5", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5",
                   "claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-4-8", "claude-opus-4-7",
                   "claude-someday-9"] {
            XCTAssertTrue(ClaudeClient.modelDeprecatesTemperature(id), "\(id) answers a temperature with a 400")
        }
    }

    // MARK: - Rates and names

    /// Every field, from Anthropic's pricing page on 2026-10-29. Input and
    /// output alone let two wrong cache-read rates through review.
    func testThe55LineIsPricedAtItsOwnRates() {
        let expected: [(String, ModelRates.Rates)] = [
            ("claude-fable-5-1", .init(input: 10.00, output: 50.00, cacheRead: 0.25, cacheWrite: 12.50)),
            ("claude-opus-5-5", .init(input: 4.00, output: 20.00, cacheRead: 0.20, cacheWrite: 5.00)),
            ("claude-opus-5", .init(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25)),
            ("claude-sonnet-5-5", .init(input: 2.00, output: 10.00, cacheRead: 0.10, cacheWrite: 2.50)),
            ("claude-haiku-5-5", .init(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)),
        ]
        for (id, want) in expected {
            let r = ModelRates.rates(forModelID: id, source: .anthropic)
            XCTAssertEqual(r.input, want.input, accuracy: 1e-9, "\(id) input")
            XCTAssertEqual(r.output, want.output, accuracy: 1e-9, "\(id) output")
            XCTAssertEqual(r.cacheRead, want.cacheRead, accuracy: 1e-9, "\(id) cacheRead")
            XCTAssertEqual(r.cacheWrite, want.cacheWrite, accuracy: 1e-9, "\(id) cacheWrite")
        }
        for id in ClaudeModelCatalog.fallback {
            XCTAssertTrue(expected.contains { $0.0 == id }, "\(id) is offered with no priced row")
        }
    }

    func testAHyphenatedVersionReadsAsAVersion() {
        XCTAssertEqual(ComposerFooter.displayName(id: "claude-opus-5-5", registryName: nil), "Opus 5.5")
        XCTAssertEqual(ComposerFooter.displayName(id: "claude-fable-5-1", registryName: nil), "Fable 5.1")
        XCTAssertEqual(ComposerFooter.displayName(id: "claude-haiku-4-5-20251001", registryName: nil), "Haiku 4.5")
        XCTAssertEqual(ComposerFooter.displayName(id: "claude-opus-5", registryName: nil), "Opus 5")
        XCTAssertEqual(ComposerFooter.displayName(id: "deepseek/deepseek-v4-flash-0731", registryName: nil),
                       "Deepseek V4 Flash 0731")
    }
}

/// Answers every request on a session the test owns, so no call leaves the
/// process, and records what was asked.
final class CatalogStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _reply: (Int, String) = (200, "{}")
    private static var _requests: [URLRequest] = []
    static var reply: (Int, String) {
        get { lock.lock(); defer { lock.unlock() }; return _reply }
        set { lock.lock(); _reply = newValue; lock.unlock() }
    }
    static var requests: [URLRequest] {
        get { lock.lock(); defer { lock.unlock() }; return _requests }
        set { lock.lock(); _requests = newValue; lock.unlock() }
    }

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [CatalogStubProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self._requests.append(request); Self.lock.unlock()
        let (status, body) = Self.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
