import XCTest
@testable import Grux

/// A Vision request can call its completion handler with an error AND throw from
/// `perform`. Measured on macOS 27 (public CI run 43029551860, 2026-11-11): "SWIFT
/// TASK CONTINUATION MISUSE: performOCR(on:) tried to resume its continuation more
/// than once", a trap that kills the app. `VisionRequest.once` keeps the first
/// answer. These drive both paths through the seam the call sites use, and the
/// last one holds every Vision call in the tree to that seam.
final class VisionContinuationTests: XCTestCase {
    private struct Handler: Error, Equatable {}
    private struct Thrown: Error, Equatable {}

    func test_theHandlersErrorAndAThrowAnswerOnce() async {
        do {
            let _: String = try await VisionRequest.once { finish in
                finish(.failure(Handler()))
                throw Thrown()
            }
            XCTFail("a failed request returned a value")
        } catch {
            XCTAssertEqual(error as? Handler, Handler(), "the first answer is the handler's: \(error)")
        }
    }

    func test_aResultThenAThrowKeepsTheResult() async throws {
        let text: String = try await VisionRequest.once { finish in
            finish(.success("line one"))
            throw Thrown()
        }
        XCTAssertEqual(text, "line one")
    }

    func test_aThrowWithNoHandlerCallIsTheAnswer() async {
        do {
            let _: String = try await VisionRequest.once { _ in throw Thrown() }
            XCTFail("a throw returned a value")
        } catch {
            XCTAssertEqual(error as? Thrown, Thrown())
        }
    }

    func test_aHandlerCalledTwiceKeepsTheFirst() async throws {
        let n: Int = try await VisionRequest.once { finish in
            finish(.success(1))
            finish(.success(2))
            finish(.failure(Handler()))
        }
        XCTAssertEqual(n, 1)
    }

    func test_answersFromTwoThreadsAtOnceResumeOnce() async throws {
        for _ in 0..<200 {
            let n: Int = try await VisionRequest.once { finish in
                let group = DispatchGroup()
                for i in 0..<4 {
                    group.enter()
                    DispatchQueue.global().async { finish(.success(i)); group.leave() }
                }
                group.wait()
            }
            XCTAssertTrue((0..<4).contains(n))
        }
    }

    /// THE CLASS GUARD. A file that performs a Vision request and waits on a
    /// checked continuation of its own can resume it twice; only the seam may.
    func test_everyVisionCallWaitsThroughTheSeam() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 500, "the scan read too few files to mean anything")
        var performers: [String] = []
        var offenders: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("VNImageRequestHandler(") else { continue }
            performers.append(url.lastPathComponent)
            if url.lastPathComponent != "VisionRequest.swift",
               text.contains("withCheckedContinuation") || text.contains("withCheckedThrowingContinuation") {
                offenders.append(url.lastPathComponent)
            }
        }
        XCTAssertTrue(performers.contains("ScreenCapture.swift"),
                      "control: the scan cannot see a file known to perform a Vision request")
        XCTAssertEqual(offenders, [], "these wait on their own continuation around a Vision request; use VisionRequest.once")
    }
}
