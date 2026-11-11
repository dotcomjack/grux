import Foundation

/// A KEYCHAIN READ THAT BEGAN BEFORE A WRITE NEVER CACHES WHAT IT READ.
///
/// Wave 40 P3 6: `KeychainStore.set` dropped the cached value, then wrote. A read
/// on another thread that began between the two read the old item and cached
/// it after the write landed, so a key a person had just saved read as the old
/// one (or as not set) until Grux relaunched. Each key now carries a
/// generation: a read takes it before asking securityd, every invalidation
/// moves it on, and a read whose generation moved stores nothing.
final class KeychainReadCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var generations: [String: UInt64] = [:]

    /// The cached answer, or nil when the key was never read or was invalidated.
    func value(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    /// Taken before a read asks securityd; hand it back to `store`.
    func begin(_ key: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generations[key, default: 0]
    }

    /// Caches `value` only when nothing invalidated `key` since `begin`.
    @discardableResult
    func store(_ key: String, _ value: String, readAt generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generations[key, default: 0] == generation else { return false }
        values[key] = value
        return true
    }

    /// Drops the cached answer and turns away every read still out.
    func invalidate(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: key)
        generations[key, default: 0] &+= 1
    }
}
