import XCTest
@testable import GruxAgentCore

// The claude CLI reports a failed run (expired OAuth, API error, usage
// limit) as `"type":"result","subtype":"success","is_error":true`. Measured
// live on the Mini 2026-09-27 (ledger A16): the worker exited 1 with
// `Failed to authenticate: OAuth session expired...` and Grux logged
// `success=true`, so a Schedule and a workflow agent phase reported done.
final class AgentErrorResultTests: XCTestCase {

    private static let authFailureLines = [
        #"{"type":"system","subtype":"init","session_id":"s-auth","model":"claude-sonnet-4-6"}"#,
        #"{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"Failed to authenticate: OAuth session expired and could not be refreshed"}]}}"#,
        #"{"type":"result","subtype":"success","is_error":true,"duration_ms":12,"result":"Failed to authenticate: OAuth session expired and could not be refreshed","total_cost_usd":0}"#
    ]

    func testResultMarkedIsErrorIsNotASuccess() {
        let ev = StreamJSONParser.parse(line: Self.authFailureLines[2])
        guard case .finalResult(let text, _, let success, _) = ev else {
            return XCTFail("expected finalResult, got \(String(describing: ev))")
        }
        XCTAssertTrue(text.hasPrefix("Failed to authenticate"))
        XCTAssertFalse(success, "a result the CLI marked is_error must not read as success")
    }

    func testResultWithIsErrorFalseStillSucceeds() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0.01}"#
        guard case .finalResult(_, _, let success, _) = StreamJSONParser.parse(line: line) else {
            return XCTFail("expected finalResult")
        }
        XCTAssertTrue(success)
    }

    // A fake `claude` that prints the auth-failure stream and exits with
    // `exitCode`. Returns its directory; the caller removes it.
    private func makeFakeClaude(exitCode: Int32) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-error-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fake = dir.appendingPathComponent("claude")
        let body = Self.authFailureLines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n")
        try "#!/bin/sh\ncat >/dev/null\n\(body)\nexit \(exitCode)\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        return dir
    }

    // The worker must report failure and keep the CLI's words.
    private func runFakeWorker(exitCode: Int32) async throws -> SwarmWorkerResult {
        let dir = try makeFakeClaude(exitCode: exitCode)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("claude")

        let previous = ProcessInfo.processInfo.environment["CLAUDE_BIN"]
        setenv("CLAUDE_BIN", fake.path, 1)
        defer {
            if let previous { setenv("CLAUDE_BIN", previous, 1) } else { unsetenv("CLAUDE_BIN") }
        }
        let spec = SwarmWorkerSpec(
            role: .generic,
            label: "auth-fail",
            goal: "say hi",
            cwd: dir.path,
            model: "claude-sonnet-4-6",
            budgetUSD: 1.0
        )
        let worker = SwarmWorker(spec: spec, observer: nil)
        return await worker.run(scaffold: "", ttlSeconds: 60)
    }

    func testWorkerThatExitsOneWithAuthFailureIsAFailure() async throws {
        let result = try await runFakeWorker(exitCode: 1)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.success, "exit 1 with an is_error result was reported as success")
        XCTAssertEqual(result.errorMessage,
                       "Failed to authenticate: OAuth session expired and could not be refreshed")
        XCTAssertNotEqual(result.interruption?.kind, .authLimitHit, "an auth failure is not the monthly usage limit")
    }

    func testErrorResultIsAFailureEvenWhenTheProcessExitsZero() async throws {
        let result = try await runFakeWorker(exitCode: 0)
        XCTAssertFalse(result.success, "exit 0 must not rescue a result the CLI marked is_error")
    }

    // Same verdict on the adapter path (AgentBridgeRunner, ClaudeCodeAdapter).
    private func runFakeBridge(exitCode: Int32) async throws -> BridgeRunResult {
        let dir = try makeFakeClaude(exitCode: exitCode)
        defer { try? FileManager.default.removeItem(at: dir) }
        let invocation = AdapterInvocation(
            executablePath: dir.appendingPathComponent("claude").path,
            args: [],
            env: ["PATH": "/usr/bin:/bin"],
            stdinPayload: "say hi\n",
            cwd: dir.path
        )
        let runner = AgentBridgeRunner(adapter: ClaudeCodeAdapter(), invocation: invocation, observer: nil)
        return await runner.run(ttlSeconds: 60)
    }

    func testBridgeRunWithAuthFailureIsAFailure() async throws {
        let result = try await runFakeBridge(exitCode: 1)
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertFalse(result.success)
    }

    func testBridgeErrorResultIsAFailureEvenWhenTheProcessExitsZero() async throws {
        let result = try await runFakeBridge(exitCode: 0)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(result.success, "exit 0 must not rescue a result the CLI marked is_error")
    }
}
