import XCTest
@testable import GruxAgentCore

final class DaytonaFactoryTests: XCTestCase {

    private func endpoints() -> DaytonaEndpoints {
        DaytonaEndpoints(
            createURL: "https://app.daytona.io/api/sandbox",
            execURLTemplate: "https://proxy.app.daytona.io/toolbox/{id}/process/execute",
            deleteURLTemplate: "https://app.daytona.io/api/sandbox/{id}",
            listURL: "https://app.daytona.io/api/sandbox",
            authHeaderName: "Authorization"
        )
    }

    private func factory(_ transport: FakeDaytona, now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_700_000_000) }) -> DaytonaFactory {
        DaytonaFactory(transport: transport, endpoints: endpoints(), now: now)
    }

    func testScoreCreatesExecutesAndDeletesEvenWhenExecExitsTwo() async throws {
        let transport = FakeDaytona()
        transport.execBody = Data(#"{"exitCode":2,"result":"no"}"#.utf8)
        let diff = "hello diff\n"
        let score = try await factory(transport).score(FactoryJob(
            diff: diff,
            scoreCommand: "echo caller-command",
            timeoutSec: 120
        ))
        XCTAssertEqual(score.exitCode, 2)
        XCTAssertEqual(score.sandboxId, "sb-1")
        XCTAssertEqual(transport.methods, ["POST", "POST", "DELETE"])
        let exec = try XCTUnwrap(transport.bodies[1])
        XCTAssertTrue(exec.contains(#""timeout":120"#))
        XCTAssertTrue(exec.contains("https://github.com/dotcomjack/grux.git"))
        XCTAssertTrue(exec.contains("git apply --check /tmp/job.diff"))
        XCTAssertTrue(exec.contains("bash factory/score.sh"))
        XCTAssertFalse(exec.contains("caller-command"))
        XCTAssertTrue(transport.requests[2].url?.absoluteString.contains("sb-1") == true)
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testExecThrowStillDeletes() async {
        let transport = FakeDaytona()
        transport.throwOnExec = true
        do {
            _ = try await factory(transport).score(FactoryJob(diff: "x\n", scoreCommand: "true", timeoutSec: 30))
            XCTFail("expected throw")
        } catch {
        }
        XCTAssertEqual(transport.methods, ["POST", "POST", "DELETE"])
    }

    func testPrivacyRefuseSendsNothing() async {
        let transport = FakeDaytona()
        do {
            _ = try await factory(transport).score(FactoryJob(
                diff: "see ~/.grux/mail/inbox.json\n",
                scoreCommand: "bash factory/score.sh",
                timeoutSec: 30
            ))
            XCTFail("expected throw")
        } catch let error as FactoryRefusal {
            XCTAssertEqual(error.reason, "banned-path")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    func testReapDeletesOnlyOldFactorySandboxes() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        let old = formatter.string(from: now.addingTimeInterval(-21 * 60))
        let young = formatter.string(from: now.addingTimeInterval(-5 * 60))
        let transport = FakeDaytona()
        transport.listBody = Data("""
        {"sandboxes":[
          {"id":"old","labels":{"grux.factory":"1"},"createdAt":"\(old)"},
          {"id":"young","labels":{"grux.factory":"1"},"createdAt":"\(young)"},
          {"id":"other","labels":{"keep":"1"},"createdAt":"\(old)"}
        ]}
        """.utf8)
        let deleted = try await factory(transport, now: { now }).reap(olderThan: 20 * 60)
        XCTAssertEqual(deleted, ["old"])
        let deletes = transport.requests.filter { $0.httpMethod == "DELETE" }
        XCTAssertEqual(deletes.count, 1)
        XCTAssertTrue(deletes[0].url?.absoluteString.contains("old") == true)
    }

    func testReapReadsTheLiveItemsList() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        let old = formatter.string(from: now.addingTimeInterval(-21 * 60))
        let transport = FakeDaytona()
        transport.listBody = Data("""
        {"items":[
          {"id":"old","labels":{"grux.factory":"1"},"createdAt":"\(old)"}
        ],"nextCursor":null}
        """.utf8)
        let deleted = try await factory(transport, now: { now }).reap(olderThan: 20 * 60)
        XCTAssertEqual(deleted, ["old"])
    }

    func testExecBodySetsTimeout() async throws {
        let transport = FakeDaytona()
        _ = try await factory(transport).score(FactoryJob(diff: "a\n", scoreCommand: "true", timeoutSec: 120))
        let exec = try XCTUnwrap(transport.bodies[1])
        XCTAssertTrue(exec.contains(#""timeout":120"#))
    }

    func testCreateBodyIsTheSmallSnapshot() async throws {
        let transport = FakeDaytona()
        _ = try await factory(transport).score(FactoryJob(diff: "a\n", scoreCommand: "true", timeoutSec: 30))
        let create = try XCTUnwrap(transport.bodies[0])
        XCTAssertTrue(create.contains(#""snapshot":"daytona-small""#))
        XCTAssertFalse(create.contains(#""cpu":2"#))
    }

    func testCreateThrowDoesNotDelete() async {
        let transport = FakeDaytona()
        transport.throwOnCreate = true
        do {
            _ = try await factory(transport).score(FactoryJob(diff: "a\n", scoreCommand: "true", timeoutSec: 30))
            XCTFail("expected throw")
        } catch {
        }
        XCTAssertEqual(transport.methods, ["POST"])
        XCTAssertFalse(transport.methods.contains("DELETE"))
    }
}

final class FakeDaytona: DaytonaTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var execBody = Data(#"{"exitCode":0,"result":"ok"}"#.utf8)
    var listBody = Data()
    var throwOnExec = false
    var throwOnCreate = false

    var methods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { $0.httpMethod ?? "" }
    }

    var bodies: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { req in
            guard let body = req.httpBody else { return "" }
            return String(decoding: body, as: UTF8.self)
        }
    }

    func send(_ request: URLRequest) async throws -> (Int, Data) {
        lock.lock()
        requests.append(request)
        lock.unlock()
        let url = request.url?.absoluteString ?? ""
        let method = request.httpMethod ?? "GET"
        if method == "POST" && url.contains("/process/execute") {
            if throwOnExec { throw FakeDaytonaError() }
            return (200, execBody)
        }
        if method == "POST" && url.contains("/api/sandbox") {
            if throwOnCreate { throw FakeDaytonaError() }
            return (200, Data(#"{"id":"sb-1"}"#.utf8))
        }
        if method == "GET" {
            return (200, listBody)
        }
        return (200, Data())
    }
}

struct FakeDaytonaError: Error {}
