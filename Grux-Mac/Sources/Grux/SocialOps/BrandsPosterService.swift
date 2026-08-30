import Foundation

// Host-failover HTTP client for the brands-poster service (port 3856, the same
// service host as SocialOps). Mirrors SocialOpsService's posture
// exactly: a fixed base-URL precedence list, short timeouts, try each base in
// order, throw a single typed error when none answer. Read-only: this client
// only GETs the live posting status. There is no POST path, because this
// feature is pure observability (no cadence or ramp controls).
//
// Auth is borrowed from SocialOpsService.authHeaders(), the one reader of the
// shared ~/.grux/pr-inbox-token.txt secret; the host-failover loop itself
// lives once in PrivateServiceFetch.
//
// ONE HOSTS FILE SERVES BOTH ROUTES, BY DESIGN. This service and social ops
// are the same companion on the same port 3856, so the host somebody wrote in
// ~/.grux/social-ops-hosts.txt is this route's host too, and reading it
// through SocialOpsService.configuredHosts() (the one parser for that file)
// is what keeps the two from drifting. Compiling in loopback ONLY was the
// defect: BrandsPosterStore.startPolling already gates the whole feature on
// that file, so a user who configured a remote poster got a poller that ran
// against a host it never tried, every fetch failing at the transport level,
// every failure classified as absence ("an empty panel here is the normal
// state") over a service they had pointed Grux at, and the red needs_reauth
// notification never firing.
//
// With nothing configured and nothing listening on loopback, which is every
// install except the one this was written on, fetchPostingStatus throws
// PrivateServiceNotice.brandsPoster.explanation and BrandsPostingSection renders
// it where the row list would be. It carries its OWN notice rather than sharing
// the social-ops one even though both sit on 3856, because the sentence that
// earns a reader's attention is the one saying what THIS panel would show.

enum BrandsPosterService {
    // Configured hosts plus the local fallback, recomputed per call, exactly
    // as SocialOpsService.baseURLs composes the same file.
    static var baseURLs: [String] { SocialOpsService.configuredHosts() + [loopbackBase] }
    private static let loopbackBase = "http://localhost:3856"

    // GET /api/brands-poster/status -> full status of the autonomous posting
    // engine. The failover rule lives once in PrivateServiceFetch, and so does
    // the per-attempt HTTP shape.
    static func fetchPostingStatus() async throws -> BrandsPosterStatus {
        // userConfigured excludes the compiled-in loopback entry: only a host
        // from ~/.grux/social-ops-hosts.txt counts, so an untouched install
        // still gets the notice when localhost refuses, while a configured
        // host that is down gets named. ONE read of the hosts file feeds both
        // arguments, so the base list and the flag cannot disagree mid-edit.
        let configured = SocialOpsService.configuredHosts()
        return try await PrivateServiceFetch.run(
            service: "posting service",
            bases: configured + [loopbackBase],
            userConfigured: !configured.isEmpty,
            absenceExplanation: PrivateServiceNotice.brandsPoster.explanation,
            attempt: PrivateServiceFetch.jsonAttempt(
                BrandsPosterStatus.self,
                path: "/api/brands-poster/status",
                // Shared bearer secret at ~/.grux/pr-inbox-token.txt; the one
                // reader lives in SocialOpsService, and so does the rule for
                // which bases may receive it (loopback is trusted by peer
                // address and is handed nothing).
                headers: { SocialOpsService.authHeaders(for: $0) }
            )
        )
    }
}
