import Foundation
import OSLog

// There is no cloud path for phone pairing, and this type is what says so. It
// spawns nothing, locates no binary, publishes no URL and never retries. Both
// entry points are no-ops. The name is a vendor's; nothing in this file
// contacts that vendor.
//
// Keeping one inert owner beats deleting it, because a tunnel has a LIFETIME
// and a lifetime needs a single owner. Two call sites already report into it:
// PhoneReceiverService hands over the port it just bound, and
// applicationWillTerminate announces shutdown. If a tunnel is ever added it
// belongs here, and the shutdown half is already wired. A spawn with no
// matching stop is the failure this shape exists to prevent, because a child
// process nothing reaps is reparented on every quit and they pile up unseen.
//
// What a user gives up meanwhile: pairing a phone from outside this Mac's
// network. The pairing window says that outright in its Reach row rather than
// spinning on a connection that is never coming.
@MainActor
final class CloudflareTunnelManager {
    static let shared = CloudflareTunnelManager()

    private let log = Logger(subsystem: "com.gruxai.grux", category: "CFTunnel")

    private init() {}

    // No-op. Called by PhoneReceiverService with the port it just bound. Logged
    // rather than silent so the wake log carries the decision, instead of
    // leaving whoever reads it to guess why the phone cannot reach this Mac
    // from anywhere else.
    func start(forwardingTo localPort: UInt16) {
        log.log("cloud tunnel disabled; phone pairing is same-network only (listener on port \(localPort, privacy: .public), local network)")
    }

    // No-op. Called from applicationWillTerminate. Nothing spawns a child, so
    // there is nothing to reap. The call stays so that adding a spawn cannot
    // ship without its matching stop.
    func stop() {}
}
