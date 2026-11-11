import XCTest
import Network
@testable import Grux

// The 3.2 update check (spec docs/superpowers/specs/2026-10-17-update-check-scope.md):
// one anonymous GET of GitHub's public latest-release page, at most once a day, never
// during first run, never offline or metered, off when the person turns it off, and
// "Check now" works with the toggle off. Every request here goes to a counting stub.
final class UpdateCheckTests: XCTestCase {

    // MARK: - U1, the version compare

    private func release(_ tag: String, draft: Bool = false, prerelease: Bool = false) -> UpdateCheck.Release {
        UpdateCheck.Release(tagName: tag, draft: draft, prerelease: prerelease)
    }

    func testANewerMinorIsAvailable() {
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.1.0", latest: release("v3.2.0")),
                       .newer(version: "3.2.0"))
    }

    func testTenComesAfterNine() {
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.9.0", latest: release("v3.10.0")),
                       .newer(version: "3.10.0"))
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.10.0", latest: release("v3.9.0")),
                       .upToDate(latest: "3.9.0"))
    }

    func testTheSameVersionIsUpToDate() {
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.1.0", latest: release("v3.1.0")),
                       .upToDate(latest: "3.1.0"))
        // A missing patch number is a zero, not a different version.
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.2", latest: release("3.2.0")),
                       .upToDate(latest: "3.2.0"))
    }

    func testAnOlderReleaseIsUpToDate() {
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.2.0", latest: release("v3.1.9")),
                       .upToDate(latest: "3.1.9"))
    }

    func testDraftsAndPrereleasesAreIgnored() {
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.1.0", latest: release("v3.2.0", draft: true)),
                       .ignored("a draft release"))
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.1.0", latest: release("v3.2.0", prerelease: true)),
                       .ignored("a prerelease"))
        // A prerelease tag on a release GitHub was not told is one.
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.1.0", latest: release("v3.2.0-beta.1")),
                       .ignored("a prerelease"))
    }

    func testATagThatIsNotAVersionIsIgnored() {
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.1.0", latest: release("nightly")),
                       .ignored("the tag nightly is not a version"))
        XCTAssertEqual(UpdateCheck.verdict(installed: "3.1.0", latest: release("v3..1")),
                       .ignored("the tag v3..1 is not a version"))
    }

    func testTheReleasePageDecodes() throws {
        let body = #"{"tag_name":"v3.1.0","name":"Grux AI 3.1","draft":false,"prerelease":false,"assets":[]}"#
        let r = try JSONDecoder().decode(UpdateCheck.Release.self, from: Data(body.utf8))
        XCTAssertEqual(r, release("v3.1.0"))
    }

    // MARK: - U2, the request carries nothing about the person

    func testTheRequestCarriesNothingAboutThePerson() {
        let r = UpdateCheck.request()
        XCTAssertEqual(r.url?.absoluteString, "https://api.github.com/repos/dotcomjack/grux/releases/latest")
        XCTAssertNil(r.url?.query, "no query string")
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertNil(r.httpBody)
        XCTAssertNil(r.httpBodyStream)
        XCTAssertEqual(r.allHTTPHeaderFields ?? [:],
                       ["Accept": "application/vnd.github+json", "Accept-Language": "en"],
                       "no install id, no key, no cookie: a format, and one language line for everyone")
        XCTAssertFalse(r.httpShouldHandleCookies)
    }

    func testTheSessionKeepsNoCookiesAndNoCache() {
        let c = UpdateCheck.sessionConfiguration()
        XCTAssertNil(c.httpCookieStorage)
        XCTAssertFalse(c.httpShouldSetCookies)
        XCTAssertEqual(c.httpCookieAcceptPolicy, .never)
        XCTAssertNil(c.urlCache)
        XCTAssertNil(c.urlCredentialStorage)
        XCTAssertTrue((c.httpAdditionalHeaders ?? [:]).isEmpty)
    }

    /// Wave 7 review P2-2: CFNetwork adds headers at send time that the URLRequest never
    /// shows (Accept-Language from the person's preferred languages, Accept-Encoding), so
    /// the claim is checked on the bytes that leave: the real session and the real
    /// request, aimed at a listener on this Mac's loopback.
    func testOnTheWireNothingAboutThePersonLeaves() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let captured = Captured()
        let ready = expectation(description: "listening")
        let got = expectation(description: "request received")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func read() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                    if let data { captured.append(data) }
                    if captured.headersComplete {
                        let body = #"{"tag_name":"v3.1.0","draft":false,"prerelease":false}"#
                        let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                            got.fulfill()
                        })
                    } else if !done && error == nil {
                        read()
                    }
                }
            }
            read()
        }
        listener.start(queue: .global())
        defer { listener.cancel() }
        wait(for: [ready], timeout: 10)
        let port = try XCTUnwrap(listener.port?.rawValue)

        var request = UpdateCheck.request()
        request.url = URL(string: "http://127.0.0.1:\(port)\(UpdateCheck.latestReleaseURL.path)")
        let session = URLSession(configuration: UpdateCheck.sessionConfiguration())
        defer { session.invalidateAndCancel() }
        let done = expectation(description: "reply read")
        session.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [got, done], timeout: 15)

        let headers = captured.headers()
        XCTAssertEqual(captured.requestLine(), "GET \(UpdateCheck.latestReleaseURL.path) HTTP/1.1")
        XCTAssertNil(headers["cookie"])
        XCTAssertNil(headers["authorization"])
        XCTAssertEqual(headers["accept"], "application/vnd.github+json")
        XCTAssertEqual(headers["accept-language"], "en", "the same language line for everyone, never the person's own")
        let allowed: Set<String> = ["host", "accept", "accept-language", "accept-encoding", "user-agent", "connection"]
        XCTAssertTrue(Set(headers.keys).isSubset(of: allowed), "unexpected headers: \(Set(headers.keys).subtracting(allowed))")
        let agent = headers["user-agent"] ?? ""
        XCTAssertFalse(agent.lowercased().contains(NSUserName().lowercased()), agent)
        XCTAssertFalse(agent.contains(Host.current().localizedName ?? "\u{0}"), agent)
    }

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = Data()
        func append(_ d: Data) { lock.lock(); bytes.append(d); lock.unlock() }
        private var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: bytes, as: UTF8.self) }
        var headersComplete: Bool { text.contains("\r\n\r\n") }
        func requestLine() -> String { text.components(separatedBy: "\r\n").first ?? "" }
        func headers() -> [String: String] {
            let head = text.components(separatedBy: "\r\n\r\n").first ?? ""
            var out: [String: String] = [:]
            for line in head.components(separatedBy: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                out[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            return out
        }
    }

    // MARK: - U3 and U4, when it asks

    private final class Counter: @unchecked Sendable {
        var requests: [URLRequest] = []
        var body = #"{"tag_name":"v3.1.0","draft":false,"prerelease":false}"#
        var status = 200
    }

    private var tempState: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        tempState = FileManager.default.temporaryDirectory
            .appendingPathComponent("update-check-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempState)
        super.tearDown()
    }

    @MainActor
    private func checker(_ counter: Counter, enabled: Bool = true, firstRunDone: Bool = true,
                         network: UpdateCheck.Network = .online, installed: String = "3.1.0") -> UpdateChecker {
        UpdateChecker(environment: UpdateChecker.Environment(
            now: { [unowned self] in self.clock },
            installedVersion: { installed },
            enabled: { enabled },
            firstRunDone: { firstRunDone },
            network: { network },
            fetch: { request in
                counter.requests.append(request)
                return (Data(counter.body.utf8), counter.status)
            },
            stateURL: tempState,
            log: { _ in }
        ))
    }

    @MainActor
    func testASecondCheckInside24HoursMakesNoRequest() async {
        let counter = Counter()
        let c = checker(counter)
        _ = await c.run(manual: false)
        XCTAssertEqual(counter.requests.count, 1)

        clock = clock.addingTimeInterval(24 * 3600 - 1)
        let second = await c.run(manual: false)
        XCTAssertEqual(counter.requests.count, 1, "one second short of a day asks nothing")
        if case .skipped = second {} else { XCTFail("expected a skip, got \(second)") }

        clock = clock.addingTimeInterval(1)
        _ = await c.run(manual: false)
        XCTAssertEqual(counter.requests.count, 2, "a full day later it asks again")
    }

    @MainActor
    func testTheDayIsRememberedAcrossARelaunch() async {
        let counter = Counter()
        _ = await checker(counter).run(manual: false)
        clock = clock.addingTimeInterval(3600)
        _ = await checker(counter).run(manual: false)
        XCTAssertEqual(counter.requests.count, 1, "a new checker reads the last check from disk")
    }

    @MainActor
    func testAFailedRequestStillCountsAsTheDaysCheck() async {
        let counter = Counter()
        counter.status = 503
        let first = await checker(counter).run(manual: false)
        if case .failed = first {} else { XCTFail("expected a failure, got \(first)") }
        clock = clock.addingTimeInterval(60)
        _ = await checker(counter).run(manual: false)
        XCTAssertEqual(counter.requests.count, 1, "a failing server is not asked again every launch")
    }

    @MainActor
    func testNeverDuringFirstRun() async {
        let counter = Counter()
        let outcome = await checker(counter, firstRunDone: false).run(manual: false)
        XCTAssertEqual(counter.requests.count, 0)
        XCTAssertEqual(outcome, .skipped("first run is not finished"))
    }

    @MainActor
    func testNeverOfflineOrOnAMeteredNetwork() async {
        let counter = Counter()
        for network in [UpdateCheck.Network.offline, .metered, .constrained] {
            let outcome = await checker(counter, network: network).run(manual: false)
            if case .skipped = outcome {} else { XCTFail("\(network): expected a skip, got \(outcome)") }
        }
        XCTAssertEqual(counter.requests.count, 0)
    }

    @MainActor
    func testOffMeansOff() async {
        let counter = Counter()
        let outcome = await checker(counter, enabled: false).run(manual: false)
        XCTAssertEqual(counter.requests.count, 0)
        XCTAssertEqual(outcome, .skipped("the check is turned off"))
    }

    @MainActor
    func testCheckNowWorksWithTheToggleOffAndInsideTheDay() async {
        let counter = Counter()
        _ = await checker(counter).run(manual: false)
        clock = clock.addingTimeInterval(60)
        let outcome = await checker(counter, enabled: false).run(manual: true)
        XCTAssertEqual(counter.requests.count, 2)
        XCTAssertEqual(outcome, .upToDate(latest: "3.1.0"))
    }

    @MainActor
    func testCheckNowNeverAsksDuringFirstRun() async {
        let counter = Counter()
        let outcome = await checker(counter, firstRunDone: false).run(manual: true)
        XCTAssertEqual(counter.requests.count, 0)
        XCTAssertEqual(outcome, .skipped("first run is not finished"))
    }

    @MainActor
    func testTheSwitchOffNeverProbesTheNetwork() async {
        let counter = Counter()
        var probes = 0
        let c = UpdateChecker(environment: UpdateChecker.Environment(
            now: { [unowned self] in self.clock }, installedVersion: { "3.1.0" },
            enabled: { false }, firstRunDone: { true },
            network: { probes += 1; return .online },
            fetch: { counter.requests.append($0); return (Data(counter.body.utf8), 200) },
            stateURL: tempState, log: { _ in }))
        _ = await c.run(manual: false)
        XCTAssertEqual(probes, 0)
        _ = await c.run(manual: true)
        XCTAssertEqual(probes, 1, "Check now does look at the network")
    }

    // MARK: - D129, About says what the last real check found and when

    // Settings, General, About read "not checked: checked less than a day ago" beside a
    // Now row offering 3.2.0: every hourly look inside the day overwrote the line with
    // its own skip, and a relaunch showed nothing until the next look.

    private var checkedNow: String { ", checked " + FoundrySchedule.when(clock, now: clock, calendar: .current) }

    @MainActor
    func testAnHourlyLookInsideTheDayKeepsTheLastResult() async {
        let counter = Counter()
        let c = checker(counter)
        _ = await c.run(manual: false)
        let found = "up to date (the latest release is 3.1.0)" + checkedNow
        XCTAssertEqual(c.lastLine, found)
        clock = clock.addingTimeInterval(3600)
        _ = await c.run(manual: false)
        XCTAssertEqual(c.lastLine, found, "a skipped look is not a result")
    }

    /// Wave 37: the line was text made at check time, and a skipped look leaves
    /// it, so Grux running past midnight said "checked today" about yesterday.
    @MainActor
    func testTheLineNamesTheDayWhenItIsRead() async {
        let counter = Counter()
        let c = checker(counter)
        let asked = clock
        _ = await c.run(manual: false)
        // One second inside the daily limit, and on the next calendar day.
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: asked)!
        clock = nextDay.addingTimeInterval(-1)
        if !Calendar.current.isDate(clock, inSameDayAs: nextDay) {
            clock = Calendar.current.startOfDay(for: nextDay).addingTimeInterval(1)
        }
        _ = await c.run(manual: false)
        XCTAssertEqual(counter.requests.count, 1, "inside the day, so not asked again")
        XCTAssertEqual(c.lastLine, "up to date (the latest release is 3.1.0), checked "
                       + FoundrySchedule.when(asked, now: clock, calendar: .current))
        XCTAssertTrue(c.lastLine?.contains("yesterday") == true, c.lastLine ?? "nil")
    }

    @MainActor
    func testARelaunchShowsTheLastResult() async {
        let counter = Counter()
        counter.body = #"{"tag_name":"v3.2.0","draft":false,"prerelease":false}"#
        _ = await checker(counter).run(manual: false)
        let expected = "Grux AI 3.2.0 is available" + checkedNow
        clock = clock.addingTimeInterval(60)
        XCTAssertEqual(checker(counter).lastLine, expected)
    }

    @MainActor
    func testAFailedCheckSaysSoAfterARelaunchToo() async {
        let counter = Counter()
        counter.status = 503
        let c = checker(counter)
        _ = await c.run(manual: false)
        let expected = "could not check: GitHub answered HTTP 503" + checkedNow
        XCTAssertEqual(c.lastLine, expected)
        XCTAssertEqual(checker(counter).lastLine, expected)

        counter.status = 200
        _ = await checker(counter).run(manual: true)
        XCTAssertEqual(checker(counter).lastLine, "up to date (the latest release is 3.1.0)" + checkedNow,
                       "a later answer replaces the failure")
    }

    @MainActor
    func testCheckNowThatCannotAskSaysWhy() async {
        let c = checker(Counter(), firstRunDone: false)
        _ = await c.run(manual: true)
        XCTAssertEqual(c.lastLine, "not checked: first run is not finished")
    }

    @MainActor
    func testAStateFileFromBeforeThisReadsItsLastAnswer() {
        // The file this Mini carried on 2026-11-02, written before the line was kept.
        Persistence.save(UpdateCheckState(lastCheckedAt: clock, latestTag: "v3.2.0", dismissedVersion: "3.1.0"),
                         to: tempState)
        XCTAssertEqual(checker(Counter()).lastLine, "Grux AI 3.2.0 is available" + checkedNow)
    }

    @MainActor
    func testNeverCheckedSaysNothing() {
        XCTAssertNil(checker(Counter()).lastLine)
    }

    func testTheNetworkIsClassifiedOfflineFirstThenMeteredThenLowData() {
        XCTAssertEqual(UpdateNetwork.classify(satisfied: true, expensive: false, constrained: false), .online)
        XCTAssertEqual(UpdateNetwork.classify(satisfied: false, expensive: true, constrained: true), .offline)
        XCTAssertEqual(UpdateNetwork.classify(satisfied: true, expensive: true, constrained: true), .metered)
        XCTAssertEqual(UpdateNetwork.classify(satisfied: true, expensive: false, constrained: true), .constrained)
    }

    @MainActor
    func testCheckNowStillNeedsANetwork() async {
        let counter = Counter()
        let outcome = await checker(counter, network: .offline).run(manual: true)
        XCTAssertEqual(counter.requests.count, 0)
        if case .skipped = outcome {} else { XCTFail("expected a skip, got \(outcome)") }
    }

    @MainActor
    func testANewerReleaseIsPublishedAndAnEqualOneClearsIt() async {
        let counter = Counter()
        counter.body = #"{"tag_name":"v3.2.0","draft":false,"prerelease":false}"#
        let c = checker(counter)
        let outcome = await c.run(manual: false)
        XCTAssertEqual(outcome, .newer(version: "3.2.0"))
        XCTAssertEqual(c.available, "3.2.0")

        counter.body = #"{"tag_name":"v3.1.0","draft":false,"prerelease":false}"#
        _ = await c.run(manual: true)
        XCTAssertNil(c.available)
    }

    @MainActor
    func testAReplyThatIsNotAReleaseFailsPlainly() async {
        let counter = Counter()
        counter.body = "<html>rate limited</html>"
        let outcome = await checker(counter).run(manual: false)
        if case .failed = outcome {} else { XCTFail("expected a failure, got \(outcome)") }
    }

    // MARK: - The default lives in one constant

    func testTheDefaultIsOnAndLivesInOneConstant() throws {
        XCTAssertTrue(UpdateCheck.onByDefault, "the spec's default; the owner's ruling flips this one line")
        XCTAssertEqual(GruxConfig.default.updateCheckEnabled, UpdateCheck.onByDefault)
        // An existing install's config.json, saved before this key existed.
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(GruxConfig.default)) as? [String: Any])
        XCTAssertNotNil(saved.removeValue(forKey: "updateCheckEnabled"), "the key is saved")
        let decoded = try JSONDecoder().decode(
            GruxConfig.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(decoded.updateCheckEnabled, UpdateCheck.onByDefault,
                       "an existing install with no key gets the same default")
    }

    func testTheSwitchSurvivesASave() throws {
        var config = GruxConfig.default
        config.updateCheckEnabled = !UpdateCheck.onByDefault
        let back = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(back.updateCheckEnabled, !UpdateCheck.onByDefault)
    }
}
