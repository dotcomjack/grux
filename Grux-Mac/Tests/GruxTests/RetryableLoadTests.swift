import XCTest
@testable import Grux

/// The Whisper model load behind dictation, ambient listening, meeting capture and
/// `grux transcribe`. Measured 2026-09-27: a load that failed once (a model folder Grux
/// could not read) stayed the answer until relaunch, so `grux transcribe` refused in 24 ms
/// after the folder was readable again, and blamed the network for a permission.
@MainActor
final class RetryableLoadTests: XCTestCase {
    private struct Boom: Error, LocalizedError {
        var errorDescription: String? { "the model folder is not readable" }
    }

    /// Counts calls and fails the ones it is told to.
    private final class Loader {
        var calls = 0
        var failFirst: Int
        init(failFirst: Int) { self.failFirst = failFirst }
        func load() throws -> String {
            calls += 1
            if calls <= failFirst { throw Boom() }
            return "kit"
        }
    }

    func test_aFailedLoad_isTriedAgainOnTheNextAsk() async {
        let loader = Loader(failFirst: 1)
        let gate = RetryableLoad<String> { try loader.load() }

        let first = await gate.get()
        XCTAssertNil(first)
        XCTAssertEqual(gate.lastFailure?.localizedDescription, "the model folder is not readable")

        let second = await gate.get()
        XCTAssertEqual(second, "kit", "a failed load was kept as the answer, so nothing loads until relaunch")
        XCTAssertEqual(loader.calls, 2)
        XCTAssertNil(gate.lastFailure, "a success clears the old reason")
    }

    func test_aSuccessfulLoad_isKept() async {
        let loader = Loader(failFirst: 0)
        let gate = RetryableLoad<String> { try loader.load() }
        _ = await gate.get()
        let again = await gate.get()
        XCTAssertEqual(again, "kit")
        XCTAssertEqual(gate.value, "kit")
        XCTAssertEqual(loader.calls, 1, "a loaded model was loaded twice")
    }

    func test_callersDuringALoad_shareIt() async {
        var calls = 0
        let gate = RetryableLoad<String> {
            calls += 1
            try await Task.sleep(nanoseconds: 50_000_000)
            return "kit"
        }
        async let a = gate.get()
        async let b = gate.get()
        let (ra, rb) = await (a, b)
        XCTAssertEqual(ra, "kit")
        XCTAssertEqual(rb, "kit")
        XCTAssertEqual(calls, 1, "two callers started two model loads")
    }

    // MARK: What `grux transcribe` says when the model will not load

    func test_transcribeRefusal_namesTheRealReason_andSaysAskingAgainRetries() {
        let text = GruxControlTools.speechModelUnavailable(reason: "Model not found.\nError: couldn't be moved because you don't have permission to access \"openai_whisper-small.en\".")
        XCTAssertTrue(text.contains("you don't have permission"), text)
        XCTAssertFalse(text.contains("\n"), "the reason is folded onto one line: \(text)")
        XCTAssertFalse(text.contains("network"), "a known reason is not blamed on the network: \(text)")
        XCTAssertTrue(text.contains("again"), "the caller is told a second ask loads again: \(text)")
    }

    func test_transcribeRefusal_withNoReason_keepsTheFirstLoadHint() {
        let text = GruxControlTools.speechModelUnavailable(reason: nil)
        XCTAssertTrue(text.contains("network"), text)
    }
}
