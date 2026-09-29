import XCTest
@testable import Grux

/// The phone tunnel is gone. These lock the two halves of that decision, because
/// each half silently breaks the other if it drifts back on its own.
///
/// Half one: nothing spawns a tunnel. `CloudflareTunnelManager` used to run
/// `cloudflared tunnel --url http://localhost:<port>`, scrape the ephemeral
/// trycloudflare hostname out of stderr, and restart forever. When nothing reaped
/// the child, 30 quick tunnels reparented to launchd and each held a public
/// ingress to a loopback port that no longer existed. It went inert on
/// 2026-08-12 and was deleted in P-R-7 (2026-09-21), along with the no-op
/// `stop()` that `applicationWillTerminate` kept calling, so a tunnel that comes
/// back has no reap waiting for it. That is what the first guard is for.
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
    /// comments in the sources deliberately name `cloudflared` and `loopback` to
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

    /// Every Swift file under `Sources/`, CODE only, lowercased, keyed by its path
    /// relative to `Sources/`.
    private func allSourceCode() throws -> [(path: String, code: String)] {
        let root = sourcesDirectory.standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [(path: String, code: String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            let rel = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            out.append((rel, codeOnly(text).lowercased()))
        }
        return out
    }

    /// Red-provable by planting a `cloudflared` spawn in any source file.
    ///
    /// The manager that owned the tunnel's lifetime, and the shutdown call that
    /// would have reaped it, are both gone. So the only honest guard left is on the
    /// thing itself: no code anywhere names the `cloudflared` binary or a
    /// trycloudflare host. Comments may, and do, because they record why it went.
    func testNoCodeSpawnsATunnel() throws {
        let files = try allSourceCode()
        // Anti-vacuity: a walk that found nothing would pass forever in silence.
        XCTAssertTrue(files.contains { $0.path == "Grux/iPhone/PhoneReceiverService.swift" },
                      "the source walk did not reach the phone receiver, so it proves nothing")
        for (path, code) in files {
            for banned in ["cloudflared", "trycloudflare"] {
                XCTAssertFalse(
                    code.contains(banned),
                    "\(path) names \(banned) in code. A tunnel is coming back: it needs an "
                    + "owner for its lifetime and a matching reap in "
                    + "applicationWillTerminate in the same change, or every quit "
                    + "reparents the child to launchd and the orphan bug returns."
                )
            }
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
}
