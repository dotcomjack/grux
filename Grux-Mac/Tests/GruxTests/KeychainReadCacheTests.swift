import XCTest
@testable import Grux

/// Wave 40 P3s 5 and 6: a read that began before a write must not cache the
/// old value, and the change notice must name its key where an observer that
/// filters can find it.
final class KeychainReadCacheTests: XCTestCase {

    func test_aReadThatBeganBeforeAWrite_cachesNothing() {
        let cache = KeychainReadCache()
        // set: invalidate, then a read starts and sees the old item ...
        cache.invalidate("k")
        let read = cache.begin("k")
        // ... the write lands and invalidates again ...
        cache.invalidate("k")
        // ... and the read comes back with the old value.
        XCTAssertFalse(cache.store("k", "old", readAt: read))
        XCTAssertNil(cache.value("k"), "the old value was cached after the write")
    }

    func test_aReadThatBeganBeforeADelete_cachesNothing() {
        let cache = KeychainReadCache()
        let read = cache.begin("k")
        cache.invalidate("k")
        XCTAssertFalse(cache.store("k", "gone", readAt: read))
        XCTAssertNil(cache.value("k"))
    }

    /// On, under and over: a read with no write in between caches; one that
    /// spans one invalidation or two does not; a read begun after both caches.
    func test_everyInterleaving() {
        for invalidationsDuringRead in 0...2 {
            let cache = KeychainReadCache()
            let read = cache.begin("k")
            for _ in 0..<invalidationsDuringRead { cache.invalidate("k") }
            let stored = cache.store("k", "v", readAt: read)
            XCTAssertEqual(stored, invalidationsDuringRead == 0, "\(invalidationsDuringRead) invalidations")
            XCTAssertEqual(cache.value("k"), invalidationsDuringRead == 0 ? "v" : nil)
            let fresh = cache.begin("k")
            XCTAssertTrue(cache.store("k", "new", readAt: fresh))
            XCTAssertEqual(cache.value("k"), "new")
        }
    }

    func test_keysAreIndependent() {
        let cache = KeychainReadCache()
        let a = cache.begin("a")
        cache.invalidate("b")
        XCTAssertTrue(cache.store("a", "v", readAt: a))
        XCTAssertEqual(cache.value("a"), "v")
    }

    /// The store's own write paths turn reads away after the write as well as before it.
    func test_setAndDeleteInvalidateAfterTheWrite() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/KeychainStore.swift")
        let src = try String(contentsOf: url, encoding: .utf8)
        for (name, write) in [("set", "write(key, value)"), ("delete", "remove(key)")] {
            let start = try XCTUnwrap(src.range(of: "static func \(name)(_ key: Key"))
            let end = try XCTUnwrap(src.range(of: "\n    }\n", range: start.upperBound..<src.endIndex))
            let body = String(src[start.upperBound..<end.lowerBound])
            let w = try XCTUnwrap(body.range(of: write), "\(name) no longer calls \(write)")
            // After the write: in a `defer` (runs once the write returns) or below it.
            XCTAssertTrue(body.contains("defer { invalidate(key)") || body[w.upperBound...].contains("invalidate(key)"),
                          "\(name) must invalidate again after the write, or a read begun during it caches the old value")
            XCTAssertTrue(body[..<w.lowerBound].replacingOccurrences(of: "defer { invalidate(key)", with: "")
                            .contains("invalidate(key)"), "\(name) must invalidate before the write")
        }
        XCTAssertTrue(src.contains("readAt: generation"), "KeychainStore.get must store under the generation it read at")
    }

    @MainActor
    func test_theNoticeCarriesItsKeyInUserInfo() {
        var seen: String?
        let token = NotificationCenter.default.addObserver(forName: KeychainStore.didChange, object: nil,
                                                           queue: nil) { note in
            seen = note.userInfo?[KeychainStore.changedKey] as? String
        }
        defer { NotificationCenter.default.removeObserver(token) }
        _ = KeychainStore.set(.braveApiKey, "brv_test")
        XCTAssertEqual(seen, KeychainStore.Key.braveApiKey.rawValue)
        _ = KeychainStore.delete(.braveApiKey)
    }
}
