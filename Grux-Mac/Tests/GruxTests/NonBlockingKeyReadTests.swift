import XCTest
@testable import Grux

/// A29: a Keychain read that is waiting on a person (an access prompt nobody
/// answers) must never hold the main actor. Measured on the Mac Mini: the
/// first keyed decision after a rebuild raised the decision key's prompt and
/// every door (fire-ambient-inject, `grux status`) stalled 2.5 minutes, until
/// somebody answered it.
final class NonBlockingKeyReadTests: XCTestCase {

    /// A fake keychain whose read blocks until the test lets it go, like a
    /// read sitting behind a SecurityAgent prompt.
    final class BlockingKeychain: @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var stored: [String: String] = [:]
        var cache: [String: String] = [:]
        var reads = 0
        var fail = false

        func cached(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return cache[k] }
        func read(_ k: String) {
            lock.lock(); reads += 1; lock.unlock()
            gate.wait()
            lock.lock(); defer { lock.unlock() }
            if !fail { cache[k] = stored[k] ?? "" }
        }
        var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return cond()
    }

    func test_pendingRead_answersNilAtOnce_thenTheValueOnceTheReadLands() {
        let kc = BlockingKeychain()
        kc.stored["decision"] = "k-123"
        let reader = NonBlockingKeyRead<String>(cached: kc.cached, read: kc.read)

        let start = Date()
        XCTAssertNil(reader.value("decision"), "a read still waiting must answer nil, never block")
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)

        kc.gate.signal()
        XCTAssertTrue(waitUntil { reader.value("decision") == "k-123" })
    }

    func test_onlyOneReadInFlight_whileThePromptIsUp() {
        let kc = BlockingKeychain()
        let reader = NonBlockingKeyRead<String>(cached: kc.cached, read: kc.read)
        for _ in 0..<20 { XCTAssertNil(reader.value("decision")) }
        XCTAssertTrue(waitUntil { kc.readCount == 1 })
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(kc.readCount, 1, "one prompt at a time, not one per decision")
        kc.gate.signal()
        XCTAssertTrue(waitUntil { reader.value("decision") == "" })
    }

    func test_failedRead_isAskedAgainLater() {
        let kc = BlockingKeychain()
        kc.fail = true
        kc.stored["decision"] = "k-123"
        let reader = NonBlockingKeyRead<String>(cached: kc.cached, read: kc.read)
        XCTAssertNil(reader.value("decision"))
        kc.gate.signal()
        XCTAssertTrue(waitUntil { !reader.isPending("decision") })
        kc.fail = false
        XCTAssertNil(reader.value("decision"), "a failed read is not pinned as an answer")
        kc.gate.signal()
        XCTAssertTrue(waitUntil { reader.value("decision") == "k-123" })
        XCTAssertEqual(kc.readCount, 2)
    }

    func test_cachedValue_isAnsweredWithoutAnyRead() {
        let kc = BlockingKeychain()
        kc.cache["decision"] = "k-9"
        let reader = NonBlockingKeyRead<String>(cached: kc.cached, read: kc.read)
        XCTAssertEqual(reader.value("decision"), "k-9")
        XCTAssertEqual(kc.readCount, 0)
    }

    /// The shared engine is the one every door reaches. It must read the key
    /// through the non-blocking door, never through the blocking `get`.
    func test_sharedDecisionEngine_readsTheKeyWithoutWaiting() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Decisions/DecisionEngine.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("KeychainStore.getWithoutWaiting(.typesafeApiKey)"))
        XCTAssertFalse(src.contains("KeychainStore.get(.typesafeApiKey)"),
                       "a blocking Keychain read on the main actor stalls every door while a prompt is up")
    }
}
