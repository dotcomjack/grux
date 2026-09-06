import Foundation
import GruxGuardrails

/// The app's policy wrapper around `GruxGuardrails.URLGuard`.
///
/// ## The split, and why it is here rather than in the package
///
/// Two different jobs used to live in one file. Deciding whether a URL is safe is pure,
/// table-driven and has nothing to do with this app, so it belongs in the package.
/// Reading the user's saved policy, honouring their off switch and writing the denial to
/// the audit log is entirely about this app, so it stays.
///
/// The pure half here had drifted behind the package. Probed 2026-09-06, the app allowed
/// `http://[64:ff9b:1::7f00:1]/`, the NAT64 local-use prefix, which translates straight
/// to the loopback interface. That is GHSA-w4h7-gx69-h4q4, disclosed against the package
/// at 0.3.0 and fixed there, and still live here because nothing connected the two. The
/// hex-label and decimal loopback forms were already denied, and `127.0.0.1` and
/// `169.254.169.254` denied as controls, so the guard worked and that one allowance was
/// a real hole rather than a broken probe.
///
/// ## Names
///
/// `builtinLANHosts` is `trustedLANHosts` in the package. Same meaning, same empty
/// default, and the default is empty for the same reason it always was: a shipped LAN
/// exemption is a hole in somebody else's network, not a convenience.
typealias URLGuardDecision = GruxGuardrails.URLGuardDecision
typealias URLGuardConfig = GruxGuardrails.URLGuardConfig

enum URLGuard {

    /// Infrastructure hosts that stay reachable in the DEFAULT policy.
    ///
    /// EMPTY, deliberately. Grux used to ship two of its author's private Tailscale
    /// hostnames here, which meant every install carried a standing exemption for a
    /// machine its user does not own. A user who runs a LAN service adds its host in
    /// Settings > Security and gets the same exemption, scoped to their own machine.
    static let defaultLANHosts: [String] = []

    /// Policy-backed check used by tool call sites. Thread-safe, synchronous.
    /// Returns `.allowed` without evaluation when the user disabled URL guard.
    static func check(_ raw: String, purpose: String) -> URLGuardDecision {
        let policy = SecurityPolicyStore.shared.policy
        guard policy.urlGuardEnabled else { return .allowed }
        let config = URLGuardConfig(
            allowlist: policy.urlAllowlist,
            denylist: policy.urlDenylist,
            trustedLANHosts: defaultLANHosts
        )
        let decision = GruxGuardrails.URLGuard.evaluate(raw, config: config)
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

    /// Pure policy evaluation, delegated whole. Kept as a named entry point because the
    /// app's test suite drives it with a table and because deleting it would churn call
    /// sites for no gain.
    static func evaluate(_ raw: String, config: URLGuardConfig = URLGuardConfig()) -> URLGuardDecision {
        GruxGuardrails.URLGuard.evaluate(raw, config: config)
    }

    /// Collapses a package reason string into the audit log's tag vocabulary.
    ///
    /// STAYS IN THE APP on purpose. The tags are this log's schema, not the package's,
    /// and an alert keyed on `PRIVATE_NETWORK` breaks silently if the package ever
    /// rewords a reason. That exact failure is disclosed in the package's own 0.3.0
    /// notes, where a grown IPv4 table left Oracle Cloud metadata reporting as
    /// `URL_DENIED`, so anything watching `PRIVATE_NETWORK` stopped seeing it.
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
