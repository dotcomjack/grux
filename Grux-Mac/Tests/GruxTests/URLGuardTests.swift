import XCTest
@testable import Grux

// Item 31 coverage: URLGuard policy table. Drives the pure
// URLGuard.evaluate(_:config:) with explicit configs, no disk, no audit state.

final class URLGuardTests: XCTestCase {

    private let defaults = URLGuardConfig()

    private func isAllowed(_ url: String, config: URLGuardConfig? = nil) -> Bool {
        URLGuard.evaluate(url, config: config ?? defaults).isAllowed
    }

    // MARK: - Default policy table

    func testDefaultPolicyTable() {
        let table: [(url: String, allowed: Bool)] = [
            // Ordinary public web: allowed
            ("https://example.com/page", true),
            ("https://www.anthropic.com", true),
            ("http://news.ycombinator.com/item?id=1", true),
            // Schemes other than http/https: denied
            ("file:///etc/passwd", false),
            ("javascript:alert(1)", false),
            ("data:text/html,hello", false),
            ("chrome://settings", false),
            // Credential-bearing: denied
            ("http://user:pass@example.com/", false),
            ("https://admin@example.com/", false),
            // Loopback + localhost: denied
            ("http://localhost:3000", false),
            ("http://127.0.0.1:8080/", false),
            ("http://[::1]/", false),
            // Private IPv4 ranges: denied
            ("http://10.0.0.1/", false),
            ("http://192.168.1.5/admin", false),
            ("http://172.16.0.1/", false),
            ("http://172.20.3.4/", false),
            ("http://172.31.255.255/", false),
            ("http://169.254.10.10/", false),
            ("http://100.100.1.1/", false),     // CGNAT / tailnet range
            ("http://0.0.0.0/", false),
            // 172.x outside the /12 is public: allowed
            ("http://172.32.0.1/", true),
            ("http://172.15.0.1/", true),
            // mDNS + bare intranet hostnames: denied
            ("http://something.local/", false),
            ("http://intranet/", false),
            ("http://router/", false),
            // No LAN host is exempt out of the box: the builtin exemption list
            // ships empty, so a private service needs a user allowlist entry.
            ("http://media-box:3847/api/images/render", false),
            ("http://media-box.local:3849/api/llm/local", false),
            // Junk: denied
            ("", false),
            ("not a url at all", false)
        ]
        for row in table {
            let decision = URLGuard.evaluate(row.url, config: defaults)
            XCTAssertEqual(decision.isAllowed, row.allowed,
                           "URL '\(row.url)' expected allowed=\(row.allowed), got \(decision)")
        }
    }

    // MARK: - User denylist

    func testDenylistBlocksHostAndSubdomains() {
        let config = URLGuardConfig(denylist: ["evil.com"])
        XCTAssertFalse(isAllowed("https://evil.com/x", config: config))
        XCTAssertFalse(isAllowed("https://sub.evil.com/", config: config))
        // Suffix matching is segment-aware: notevil.com is a different host.
        XCTAssertTrue(isAllowed("https://notevil.com/", config: config))
    }

    func testTrailingDotCannotBypassDenylist() {
        // "evil.com." resolves identically to "evil.com": the dot must be
        // normalized BEFORE denylist matching, not just in the private-
        // network checks that run last.
        let config = URLGuardConfig(denylist: ["evil.com"])
        XCTAssertFalse(isAllowed("https://evil.com./x", config: config))
        XCTAssertFalse(isAllowed("https://sub.evil.com./", config: config))
    }

    func testTrailingDotStillMatchesAllowlist() {
        let config = URLGuardConfig(allowlist: ["mything.local"])
        XCTAssertTrue(isAllowed("http://mything.local./status", config: config))
    }

    func testDenylistBeatsAllowlist() {
        let config = URLGuardConfig(allowlist: ["both.com"], denylist: ["both.com"])
        XCTAssertFalse(isAllowed("https://both.com/", config: config))
    }

    func testDenylistCanBlockBuiltinLANHost() {
        // Positive control first: a host in the builtin LAN list IS exempt from
        // the private-network denial. Without this the assertion below would
        // pass even if builtinLANHosts were ignored entirely.
        let exempt = URLGuardConfig(builtinLANHosts: ["media-box"])
        XCTAssertTrue(isAllowed("http://media-box:3847/api/images/render", config: exempt))
        // The user denylist still beats it: denylist matching runs first.
        let config = URLGuardConfig(denylist: ["media-box"], builtinLANHosts: ["media-box"])
        XCTAssertFalse(isAllowed("http://media-box:3847/api/images/render", config: config))
    }

    // MARK: - User allowlist

    func testAllowlistOverridesPrivateNetworkDenials() {
        let config = URLGuardConfig(allowlist: ["mything.local", "192.168.1.50"])
        XCTAssertTrue(isAllowed("http://mything.local/status", config: config))
        XCTAssertTrue(isAllowed("http://192.168.1.50:8080/", config: config))
        // Other private hosts stay denied.
        XCTAssertFalse(isAllowed("http://other.local/", config: config))
        XCTAssertFalse(isAllowed("http://192.168.1.51/", config: config))
    }

    func testAllowlistNeverOverridesCredentialCheck() {
        let config = URLGuardConfig(allowlist: ["example.com"])
        XCTAssertFalse(isAllowed("https://user:secret@example.com/", config: config))
    }

    func testAllowlistMatchesSubdomains() {
        let config = URLGuardConfig(allowlist: ["corp.example"])
        XCTAssertTrue(isAllowed("https://api.corp.example/", config: config))
    }

    // MARK: - IPv6 smuggling + non-canonical IPv4 spellings

    func testIPv4MappedIPv6CannotReachPrivateTargets() {
        // IPv4-mapped IPv6 loopback/private, both dotted and hex spellings.
        XCTAssertFalse(isAllowed("http://[::ffff:127.0.0.1]/"))
        XCTAssertFalse(isAllowed("http://[::ffff:7f00:1]/"))
        XCTAssertFalse(isAllowed("http://[::ffff:10.0.0.1]/"))
        XCTAssertFalse(isAllowed("http://[::ffff:192.168.1.5]/"))
        XCTAssertFalse(isAllowed("http://[::ffff:169.254.169.254]/")) // cloud metadata
        XCTAssertFalse(isAllowed("http://[64:ff9b::7f00:1]/"))        // NAT64 loopback
        // Embedded PUBLIC IPv4 stays allowed.
        XCTAssertTrue(isAllowed("http://[::ffff:8.8.8.8]/"))
    }

    func testIPv6Classification() {
        XCTAssertTrue(isAllowed("http://[2606:4700::6810:84e5]/")) // public
        XCTAssertFalse(isAllowed("http://[fe80::1]/"))             // link-local
        XCTAssertFalse(isAllowed("http://[fd00::1]/"))             // unique-local
        XCTAssertFalse(isAllowed("http://[ff02::1]/"))             // multicast
        XCTAssertFalse(isAllowed("http://[::]/"))                  // unspecified
    }

    func testNonCanonicalIPv4SpellingsAreDenied() {
        XCTAssertFalse(isAllowed("http://0177.0.0.1/"))  // octal octet (resolves to 127)
        XCTAssertFalse(isAllowed("http://0x7f.0.0.1/"))  // hex octet
        XCTAssertFalse(isAllowed("http://127.1/"))       // two-part shorthand
        XCTAssertFalse(isAllowed("http://2130706433/"))  // bare 32-bit integer
        XCTAssertFalse(isAllowed("http://127.0.0.1./"))  // trailing-dot FQDN spelling
        XCTAssertFalse(isAllowed("http://localhost./"))
        // Canonical public IPv4 is unaffected.
        XCTAssertTrue(isAllowed("http://8.8.8.8/"))
    }

    // MARK: - Case handling

    func testHostMatchingIsCaseInsensitive() {
        let config = URLGuardConfig(denylist: ["evil.com"])
        XCTAssertFalse(isAllowed("https://EVIL.com/", config: config))
        XCTAssertFalse(isAllowed("HTTPS://sub.Evil.COM/", config: config))
    }
}
