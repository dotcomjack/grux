import Foundation

/// A KEYCHAIN READ THAT IS WAITING ON A PERSON NEVER HOLDS THE CALLER.
///
/// `kSecUseAuthenticationUISkip` stops the unlock prompt, not the item's own
/// access prompt ("Grux wants to use your confidential information stored in
/// ..."), which macOS still raises when an item does not trust the binary
/// reading it. `SecItemCopyMatching` then blocks its thread until somebody
/// answers. Measured on the Mac Mini (A29): the decision key was read on the
/// main actor by the first keyed decision after a rebuild, the prompt came up,
/// and every door (fire-ambient-inject, `grux status`) stalled 2.5 minutes,
/// until a person clicked it.
///
/// `value` answers from the cache, or starts ONE read on a background queue
/// and answers nil at once. The caller treats nil as "no key yet" (on device,
/// exactly as a keyless install), and the next call after the read lands gets
/// the value. A failed read leaves nothing cached, so it is asked again later.
final class NonBlockingKeyRead<K: Hashable>: @unchecked Sendable {
    private let cached: (K) -> String?
    private let read: (K) -> Void
    private let lock = NSLock()
    private var inFlight: Set<K> = []
    private let queue = DispatchQueue(label: "grux.keychain.nonblocking", qos: .utility)

    /// `cached` answers without any Keychain call (nil = never read or failed);
    /// `read` does the blocking read and fills that cache on success.
    init(cached: @escaping (K) -> String?, read: @escaping (K) -> Void) {
        self.cached = cached
        self.read = read
    }

    func isPending(_ key: K) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.contains(key)
    }

    func value(_ key: K) -> String? {
        if let hit = cached(key) { return hit }
        lock.lock()
        let start = inFlight.insert(key).inserted
        lock.unlock()
        if start {
            queue.async {
                self.read(key)
                self.lock.lock(); self.inFlight.remove(key); self.lock.unlock()
            }
        }
        return nil
    }
}
