import XCTest
@testable import Grux

/// The phone tunnel is gutted. These lock the two halves of that decision, because
/// each half silently breaks the other if it drifts back on its own.
///
/// Half one: `CloudflareTunnelManager` spawns nothing. It used to run
/// `cloudflared tunnel --url http://localhost:<port>`, scrape the ephemeral
/// trycloudflare hostname out of stderr, and restart forever. When nothing reaped
/// the child, 30 quick tunnels reparented to launchd and each held a public
/// ingress to a loopback port that no longer existed.
///
/// Half two: `PhoneReceiverService` binds the LOCAL NETWORK, not loopback. This is
/// the half that is easy to lose. Loopback was correct while cloudflared fronted
/// the listener, and re-adding it now would not harden anything: the pairing QR
/// advertises this Mac's Bonjour name, so a loopback listener refuses every
/// connection the QR can produce. The feature would be dead and every string in
/// the pairing window and Settings would be a lie, with no test failing and no
/// crash to notice.
///
/// Source scanning rather than behaviour because the defect is the presence of the
/// code, not a value it computes. A spawn that never happens to fire during a test
/// run still ships.
final class PhoneTunnelInertTests: XCTestCase {

    private var sourcesDirectory: URL {
        // Tests/GruxTests/<this file> -> up three -> Grux-Mac, then Sources.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func source(_ relativePath: String) throws -> String {
        let url = sourcesDirectory.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Strip `//` line comments so the guards below judge CODE. The explanatory
    /// comments in both files deliberately name `cloudflared` and `loopback` to
    /// record why they are gone, and a scanner that cannot tell prose from code
    /// would force those explanations to be deleted to stay green.
    /// A `//` preceded by `:` is a URL scheme, not a comment. Missing that made the
    /// first version of this helper cut `ws://…` down to `ws:` and fail the very
    /// assertion it existed to serve, which is how this note got written.
    private func codeOnly(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let s = String(line)
                var from = s.startIndex
                while let r = s.range(of: "//", range: from..<s.endIndex) {
                    if r.lowerBound > s.startIndex,
                       s[s.index(before: r.lowerBound)] == ":" {
                        from = r.upperBound
                        continue
                    }
                    return String(s[s.startIndex..<r.lowerBound])
                }
                return s
            }
            .joined(separator: "\n")
    }

    func testTunnelManagerSpawnsNothing() throws {
        let code = codeOnly(try source("Grux/iPhone/CloudflareTunnelManager.swift"))
        for banned in ["Process(", "trycloudflare", "/bin/cloudflared", "--url",
                       "executableURL", "terminationHandler", "NSRegularExpression"] {
            XCTAssertFalse(
                code.contains(banned),
                "CloudflareTunnelManager is supposed to be inert, but its code still "
                + "contains \(banned). Spawning belongs in this file or nowhere; if the "
                + "tunnel is being re-enabled, it needs a matching reap at the "
                + "applicationWillTerminate call site or the orphan bug returns."
            )
        }
    }

    /// Red-provable by restoring `params.requiredInterfaceType = .loopback`.
    func testPhoneListenerBindsLocalNetworkNotLoopback() throws {
        let code = codeOnly(try source("Grux/iPhone/PhoneReceiverService.swift"))
        XCTAssertFalse(
            code.contains("requiredInterfaceType = .loopback"),
            "PhoneReceiverService is back to binding loopback only. With no tunnel in "
            + "front of it that kills phone pairing outright: the QR advertises this "
            + "Mac's .local name and a loopback listener refuses it. Either bind the "
            + "local network, or change the pairing window and Settings to stop "
            + "promising same-network pairing."
        )
    }

    /// The pairing window must not advertise a reach the listener cannot deliver.
    /// It previously fell back to a LAN address only when the tunnel had not come
    /// up yet; that fallback is now the only path, so nothing may reintroduce a
    /// wss:// tunnel URL into the QR.
    func testPairingWindowAdvertisesNoTunnelURL() throws {
        let code = codeOnly(try source("Grux/iPhone/PhonePairingView.swift"))
        XCTAssertFalse(
            code.contains("tunnelURL"),
            "PhonePairingView reads a tunnel URL again. There is no tunnel, so the QR "
            + "would encode an address nothing serves."
        )
        XCTAssertTrue(
            code.contains("ws://"),
            "PhonePairingView no longer builds a ws:// LAN address, which is the only "
            + "address the phone can reach."
        )
    }

    /// Calling the inert entry points must stay harmless and cheap. If either
    /// starts doing work again this is the cheapest place it shows up.
    @MainActor
    func testStartAndStopAreNoOps() {
        CloudflareTunnelManager.shared.start(forwardingTo: 55000)
        CloudflareTunnelManager.shared.stop()
        // Reaching here without a spawned child, a crash, or a hang is the assertion.
        // Deliberately not asserting on a global `pgrep`: a tunnel this test did not
        // start, run by the developer for something else entirely, would fail it for
        // the wrong reason, and a guard that cries wolf gets deleted.
        XCTAssertTrue(true)
    }
}
