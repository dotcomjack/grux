import Foundation

// Item 31: allow/deny policy for every URL Grux is asked to open or fetch
// (BrowserTool.openURL, WebResearch page fetches, future tool surfaces).
//
// Default posture:
//   - http/https only (file:, javascript:, data:, chrome: all denied)
//   - credential-bearing URLs (user:pass@host) always denied, no override
//   - private-IP ranges, loopback, link-local, .local mDNS, and bare
//     intranet hostnames denied by default, with NO host exempted out of the
//     box: a fresh install trusts nobody's LAN
//   - user allowlist/denylist persisted in SecurityPolicy (JSON on disk);
//     entries match the host and all subdomains; denylist beats allowlist
//   - a LAN box of your own (a home server, a local model proxy) is reachable
//     by adding its host to that allowlist, which is the same lever
//
// Decision order: parse/scheme -> credentials -> user denylist ->
// builtin LAN exemptions -> user allowlist -> private-network checks -> allow.
//
// `evaluate(_:config:)` is pure and synchronous for table-driven tests;
// `check(_:purpose:)` reads the persisted policy and writes audit lines.

enum URLGuardDecision: Equatable {
    case allowed
    case denied(reason: String)

    var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

struct URLGuardConfig: Equatable {
    var allowlist: [String] = []
    var denylist: [String] = []
    /// LAN hosts exempted from the private-network denial before the user
    /// allowlist is consulted. Exact host match. Empty by default; this is an
    /// injection point for tests and for an embedder that ships its own
    /// service, not a place to compile somebody's home network in.
    var builtinLANHosts: [String] = URLGuard.defaultLANHosts
}

enum URLGuard {

    /// Infrastructure hosts that stay reachable in the DEFAULT policy.
    ///
    /// EMPTY, deliberately. Grux used to ship two of its author's private
    /// Tailscale hostnames here, which meant every install carried a standing
    /// exemption for a machine its user does not own. Empty is already a
    /// supported state at the one call site below (`contains(host)` on an
    /// empty array simply never matches and evaluation falls through to the
    /// user allowlist), so nothing degrades: a user who runs a LAN service
    /// adds its host to the allowlist in Settings > Security and gets exactly
    /// the same exemption, scoped to their own machine.
    static let defaultLANHosts: [String] = []

    /// Policy-backed check used by tool call sites. Thread-safe, synchronous.
    /// Returns .allowed without evaluation when the user disabled URL guard.
    static func check(_ raw: String, purpose: String) -> URLGuardDecision {
        let policy = SecurityPolicyStore.shared.policy
        guard policy.urlGuardEnabled else { return .allowed }
        let config = URLGuardConfig(allowlist: policy.urlAllowlist, denylist: policy.urlDenylist)
        let decision = evaluate(raw, config: config)
        if case .denied(let reason) = decision {
            let host = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))?.host ?? "?"
            Task {
                await SecurityAuditLog.shared.record(
                    kind: "url_guard", source: purpose,
                    verdict: "denied", tags: [reasonTag(reason)],
                    detail: "host=\(host) reason=\(reason)")
            }
        }
        return decision
    }

    /// Pure policy evaluation. No I/O, no global state: this is what the
    /// test suite drives with a table.
    static func evaluate(_ raw: String, config: URLGuardConfig) -> URLGuardDecision {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .denied(reason: "empty URL") }
        guard let url = URL(string: trimmed) else { return .denied(reason: "unparseable URL") }

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .denied(reason: "scheme '\(url.scheme ?? "none")' not allowed (http/https only)")
        }

        // Credential-bearing URLs are always denied. An allowlist entry does
        // NOT override this: user:pass@ in a URL the model composed is either
        // a phishing shape or a secret leaking into browser history.
        if let user = url.user, !user.isEmpty {
            return .denied(reason: "credential-bearing URL")
        }
        if let pass = url.password, !pass.isEmpty {
            return .denied(reason: "credential-bearing URL")
        }

        guard let rawHost = url.host, !rawHost.isEmpty else {
            return .denied(reason: "missing host")
        }
        // A single trailing dot is a valid FQDN spelling ("evil.com.",
        // "127.0.0.1.") that resolves identically. Normalize it away BEFORE
        // any host comparison, or one appended dot bypasses the user
        // denylist and the builtin/allowlist matching below.
        var host = rawHost.lowercased()
        if host.hasSuffix(".") { host = String(host.dropLast()) }

        // User denylist wins over everything past the credential check.
        if matches(host: host, list: config.denylist) {
            return .denied(reason: "host on user denylist")
        }

        // Builtin LAN exemptions (empty by default), then the user allowlist.
        // Either one skips the private-network checks below.
        if config.builtinLANHosts.contains(host) { return .allowed }
        if matches(host: host, list: config.allowlist) { return .allowed }

        if let reason = privateNetworkReason(host: host) {
            return .denied(reason: reason)
        }

        return .allowed
    }

    // MARK: - Host matching

    /// Entry "example.com" matches "example.com" and "sub.example.com".
    private static func matches(host: String, list: [String]) -> Bool {
        for entry in list {
            let e = entry.lowercased().trimmingCharacters(in: .whitespaces)
            guard !e.isEmpty else { continue }
            if host == e { return true }
            if host.hasSuffix("." + e) { return true }
        }
        return false
    }

    // MARK: - Private network detection

    private static func privateNetworkReason(host: String) -> String? {
        // Trailing-dot FQDN spelling is already normalized in evaluate()
        // (before the denylist/allowlist matching); strip again here so any
        // future direct caller stays safe. Idempotent.
        var host = host
        if host.hasSuffix(".") { host = String(host.dropLast()) }

        if host == "localhost" || host.hasSuffix(".localhost") { return "loopback (localhost)" }
        if host == "0.0.0.0" { return "unspecified address" }

        // IPv4 literal (strict dotted-quad decimal only).
        if let octets = ipv4Octets(host) {
            return privateIPv4Reason(octets)
        }

        // Numeric hosts that did NOT parse as strict dotted-quad decimal
        // (octal "0177.0.0.1", hex "0x7f.0.0.1", shorthand "127.1", bare
        // integer "2130706433") are resolver-dependent IP spellings: the
        // system resolver may read them as loopback or private even though
        // they dodge the canonical parse. Fail closed.
        if isNumericIPLikeHost(host) {
            return "ambiguous numeric IP literal"
        }

        // IPv6 literal (URL.host strips the brackets). Parse via inet_pton
        // so IPv4-mapped/compatible forms ("::ffff:127.0.0.1", hex
        // "::ffff:7f00:1") cannot smuggle a private IPv4 target past
        // string-prefix checks.
        if host.contains(":") {
            return ipv6Reason(host)
        }

        // mDNS / Bonjour hosts are LAN by definition.
        if host.hasSuffix(".local") { return "mDNS .local host (LAN)" }

        // Bare single-label hostnames ("intranet", "router") resolve via
        // local search domains: treat as private.
        if !host.contains(".") { return "single-label intranet hostname" }

        return nil
    }

    private static func privateIPv4Reason(_ octets: (Int, Int, Int, Int)) -> String? {
        let (a, b, c, d) = octets
        if a == 0 && b == 0 && c == 0 && d == 0 { return "unspecified address" }
        if a == 127 { return "loopback IP" }
        if a == 10 { return "private IP (10.0.0.0/8)" }
        if a == 172 && (16...31).contains(b) { return "private IP (172.16.0.0/12)" }
        if a == 192 && b == 168 { return "private IP (192.168.0.0/16)" }
        if a == 169 && b == 254 { return "link-local IP (169.254.0.0/16)" }
        if a == 100 && (64...127).contains(b) { return "carrier-grade NAT IP (100.64.0.0/10)" }
        return nil // public IPv4
    }

    // Strict dotted-quad decimal only: exactly four ASCII-digit labels with
    // no leading zeros, each 0...255. Anything looser (octal, hex, shorthand)
    // is handled by isNumericIPLikeHost and denied as ambiguous.
    private static func ipv4Octets(_ host: String) -> (Int, Int, Int, Int)? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3,
                  p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(p.count > 1 && p.first == "0"),
                  let v = Int(p), (0...255).contains(v) else { return nil }
            octets.append(v)
        }
        return (octets[0], octets[1], octets[2], octets[3])
    }

    // True when every dot-separated label is a number in some radix
    // (decimal or 0x hex). Such a host can only be an IP literal; real
    // domains always end in a non-numeric TLD.
    private static func isNumericIPLikeHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty else { return false }
            let isDecimal = label.allSatisfy { $0.isASCII && $0.isNumber }
            let lower = label.lowercased()
            let isHex = lower.hasPrefix("0x") && lower.count > 2
                && lower.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
            if !(isDecimal || isHex) { return false }
        }
        return true
    }

    // Byte-level IPv6 classification. Unparseable literals fail closed;
    // mapped/compatible/NAT64 forms are judged by their embedded IPv4 target.
    private static func ipv6Reason(_ host: String) -> String? {
        // Zone-indexed literals (fe80::1%en0) are interface-scoped: parse
        // the address part, the zone cannot make a private address public.
        let bare = String(host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0])
        var addr = in6_addr()
        guard inet_pton(AF_INET6, bare, &addr) == 1 else {
            return "unparseable IPv6 literal"
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: &addr) { raw in
            for i in 0..<16 { bytes[i] = raw[i] }
        }

        if bytes.allSatisfy({ $0 == 0 }) { return "unspecified IPv6" }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return "loopback IPv6" }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return "link-local IPv6" }
        if (bytes[0] & 0xfe) == 0xfc { return "unique-local IPv6" }
        if bytes[0] == 0xff { return "multicast IPv6" }

        // IPv4-mapped (::ffff:a.b.c.d), IPv4-compatible (::a.b.c.d), and
        // NAT64 well-known prefix (64:ff9b::/96) all target an IPv4 host:
        // apply the IPv4 policy to the embedded address.
        let first10Zero = bytes[0..<10].allSatisfy { $0 == 0 }
        let mapped = first10Zero && bytes[10] == 0xff && bytes[11] == 0xff
        let compatible = first10Zero && bytes[10] == 0 && bytes[11] == 0
        let nat64 = bytes[0] == 0x00 && bytes[1] == 0x64
            && bytes[2] == 0xff && bytes[3] == 0x9b
            && bytes[4..<12].allSatisfy { $0 == 0 }
        if mapped || compatible || nat64 {
            let v4 = (Int(bytes[12]), Int(bytes[13]), Int(bytes[14]), Int(bytes[15]))
            if let reason = privateIPv4Reason(v4) {
                return "\(reason) (embedded in IPv6)"
            }
            return nil // embedded public IPv4
        }

        return nil // public IPv6
    }

    private static func reasonTag(_ reason: String) -> String {
        if reason.contains("credential") { return "CREDENTIAL_URL" }
        if reason.contains("denylist") { return "USER_DENYLIST" }
        if reason.contains("scheme") { return "BAD_SCHEME" }
        if reason.contains("loopback") || reason.contains("private")
            || reason.contains("link-local") || reason.contains(".local")
            || reason.contains("intranet") || reason.contains("NAT")
            || reason.contains("unspecified") || reason.contains("ambiguous")
            || reason.contains("multicast") || reason.contains("unparseable") { return "PRIVATE_NETWORK" }
        return "URL_DENIED"
    }
}
