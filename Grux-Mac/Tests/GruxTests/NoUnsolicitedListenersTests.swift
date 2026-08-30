import XCTest
@testable import Grux

/// A fresh install must not open a network listener OR reach out on its own.
///
/// Found by running `lsof` against the live app rather than reading the source:
/// Grux owned exactly one listening socket, `*:3852` on ALL interfaces, opened
/// unconditionally at launch by `PRInboxServer` for the PR-digest inbox. That is
/// a feature which needs a companion service pushing to it, so on any install
/// without one the socket was open and unusable.
///
/// The comment on the line ten lines above it already stated the rule, for the
/// phone companion: "Skipping it here is what keeps an unpaired install from
/// sitting on a listening socket it never uses." The digest inbox simply never
/// followed it.
///
/// The token guard on non-loopback requests was real and is not the point. An
/// unconfigured feature should not be reachable at all.
@MainActor
final class NoUnsolicitedListenersTests: XCTestCase {

    /// Everything that opens a listening socket, with the config flag that must
    /// gate it. Adding a listener without adding a row here is the failure this
    /// suite is for.
    private static let listeners: [(name: String, flag: (GruxConfig) -> Bool)] = [
        ("PhoneReceiverService", { $0.phoneCompanionEnabled }),
        ("PRInboxServer",        { $0.prInboxEnabled }),
        // Outbound rather than a listener, and it belongs in the same table for
        // the same reason: `start()` swept immediately and every 12h, scanning
        // the filesystem for a credential file and calling Apple if it found
        // one. Three separate features shipped with an unconditional `start()`
        // (phone receiver, digest inbox, ASC sweep), so the failure is a pattern
        // and not an oversight, and one table is what makes the next one fail
        // here instead of in the wild.
        ("ASCStateMonitor",      { $0.ascMonitorEnabled }),
    ]

    /// A default config is what a stranger gets on first launch. Every listener
    /// must be off in it.
    func testDefaultConfigOpensNoListener() throws {
        // `.default` is literally what AppState uses when no config.json exists
        // (`Persistence.load(..., fallback: .default)`), so this is the exact
        // value a first launch runs on.
        let fresh = GruxConfig.default
        for l in Self.listeners {
            XCTAssertFalse(l.flag(fresh),
                "\(l.name) is enabled in a default config, so a fresh install opens a "
                + "listening socket the user never asked for")
        }
    }

    /// The upgrade path: an existing config.json written before the flag
    /// existed. `decodeIfPresent ?? false` is what keeps that safe, and this
    /// proves it rather than assuming it, by round-tripping a config with the
    /// new keys stripped back out.
    func testConfigThatPredatesTheFlagOpensNoListener() throws {
        var enc = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(GruxConfig.default)) as! [String: Any]
        for l in ["prInboxEnabled", "phoneCompanionEnabled"] { enc.removeValue(forKey: l) }
        let old = try JSONSerialization.data(withJSONObject: enc)
        let decoded = try JSONDecoder().decode(GruxConfig.self, from: old)
        for l in Self.listeners {
            XCTAssertFalse(l.flag(decoded),
                "\(l.name) defaults ON when decoding a config that predates it, so an "
                + "upgrade silently opens a socket")
        }
    }

    /// The launch path must consult the flag. A default of false is worthless if
    /// the call site ignores it, which is exactly how PRInboxServer shipped: the
    /// feature had no flag at all and started every time.
    func testEveryListenerStartIsGuardedAtItsLaunchCallSite() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/GruxApp.swift")
        let src = try String(contentsOf: app, encoding: .utf8)

        for (service, flag) in [("PhoneReceiverService", "phoneCompanionEnabled"),
                                ("PRInboxServer", "prInboxEnabled"),
                                ("ASCStateMonitor", "ascMonitorEnabled")] {
            guard let call = src.range(of: "\(service).shared.start()") else {
                XCTFail("\(service).shared.start() is no longer called from GruxApp; update this test")
                continue
            }
            // The guard sits immediately above the call. 400 characters back is
            // enough for the comment block plus the `if`, and short enough that
            // an unrelated flag elsewhere cannot satisfy it.
            let start = src.index(call.lowerBound, offsetBy: -400, limitedBy: src.startIndex)
                ?? src.startIndex
            let window = String(src[start..<call.lowerBound])
            XCTAssertTrue(window.contains(flag),
                "\(service).shared.start() is not guarded by config.\(flag) at its launch "
                + "call site, so it runs on every launch regardless of the setting")
        }
    }

    /// Off must mean off across a relaunch, not just for this session. The flag
    /// is read at launch, so a value that does not survive encoding would come
    /// back on.
    func testTheFlagSurvivesARoundTrip() throws {
        var c = GruxConfig.default
        c.prInboxEnabled = true
        let back = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(c))
        XCTAssertTrue(back.prInboxEnabled, "the flag does not persist, so the user's choice is lost")

        var off = GruxConfig.default
        off.prInboxEnabled = false
        let backOff = try JSONDecoder().decode(GruxConfig.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(backOff.prInboxEnabled, "off does not survive a relaunch")
    }
}
