import SwiftUI

// Empire Dashboard section for the live Brands Poster engine: one row per
// autonomous posting account the user has configured, each with a derived
// status pill, today's post count against the cadence, remaining-today, the
// last-posted relative time, circuit state, and any standing error. Sits above
// the legacy per-platform SocialOps grid so live posting health is the first
// thing read.
//
// Read-only by design: there are NO cadence or ramp controls here. This mirrors
// SocialOpsSection's visual language (header, refresh, cached banner, tight
// pills) and its system-token convention (no GruxType/GruxTheme; SwiftUI system
// fonts + system colors), with the pill tint sourced from the model's derived
// BrandPostingPill so the worst state always reads at a glance.

struct BrandsPostingSection: View {
    @ObservedObject private var store = BrandsPosterStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(.pink)
                Text("Brands Poster").font(.headline)
                // Out-of-chain stale disclosure, mirroring MetaAdsOpsSection,
                // so the stale fact never depends on which banner branch the
                // chain below happens to take.
                if store.servingStale {
                    Text("CACHED")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.20))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
                cdpIndicator
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if store.isFetching {
                    ProgressView().controlSize(.mini)
                }
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isFetching)
                .help("Pull the latest posting status from the render service")
            }

            // Same honesty rule as PRDigestSection: the stale banner carries
            // no absence arm (the Classification precondition asserts the
            // disjointness) and always names the fault technically.
            if store.servingStale, let err = store.lastError {
                Text("Showing cached status. Last pull failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let err = store.lastError, store.status == nil,
                      !store.lastErrorIsAbsence {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let status = store.status, !status.brands.isEmpty {
                ForEach(status.brands.sorted(by: { $0.brand < $1.brand })) { rec in
                    row(rec)
                }
            } else if store.status != nil, store.lastError == nil {
                // Success with zero brands: the service answered and has no
                // accounts configured yet, which is neither a fault nor
                // absence, and a header over a blank pane says neither. No
                // absence arm: this store has no push path, so a held status
                // is always pull-proven and classify() pins isAbsence false
                // over it. A standing pull failure defers to the
                // cached-status story the banner above tells, which "the
                // service answered" would contradict.
                Text(Self.emptyStatusCopy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.status == nil, store.lastErrorIsAbsence {
                // Only when the pull proved absence AND nothing is held: any
                // held status, even an empty one, means a data channel
                // exists, and the three-paragraph onboarding card is the
                // wrong surface beside live data. Mounting it on every nil
                // status put an "absence is normal" card directly under the
                // technical banner of a configured host that is down.
                // Deliberately NOT gated on isFetching: the closure is the
                // recovery pull, so that gate unmounted the card the moment
                // its own recovery started and cancelled it mid-request (see
                // the mount rules on PrivateServiceNoticeView).
                PrivateServiceNoticeView(service: .brandsPoster) { await store.refresh() }
            } else if PrivateServiceFetch.awaitingFirstPull(
                hasPayload: store.status != nil, verdict: store.lastVerdict) {
                // THE ARM THAT WAS MISSING. No payload and no verdict is
                // reachable: pullOnce's cancellation path writes nothing, so
                // a section unmounted mid-pull left this pane holding a
                // header, a refresh button and empty space. Never silence.
                //
                // The copy splits on isFetching because the arm replaced an
                // `else if !store.isFetching`: during the very first pull
                // there is no payload and no verdict, so this pane told the
                // reader to click a Refresh button that is .disabled for the
                // length of that pull. An instruction that cannot be followed
                // while it is on screen is the defect one line up.
                Text(store.isFetching
                     ? "Pulling the latest status..."
                     : "No status yet. Click refresh to pull one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            store.load()
            if store.status == nil
               || Date().timeIntervalSince(store.lastUpdated ?? .distantPast) > 1800 {
                Task { await store.refresh() }
            }
            // RE-READ THE POLLER'S GATE, which was evaluated exactly once at launch.
            //
            // The panel tells somebody to point Grux at a host by writing
            // ~/.grux/social-ops-hosts.txt. They write it, press Retry, and the grid fills
            // in. But startPolling() had already run at launch, read the file before it
            // existed and returned, so the background watch whose stated purpose is that
            // "a posting account quietly going dark can never recur unseen" stayed off for
            // the whole session, with nothing on screen saying so. It is idempotent
            // (guard pollTimer == nil), so calling it again here costs nothing and is the
            // only thing between following the instructions and having to relaunch.
            store.startPolling()
        }
    }

    // One brand row: name + handle, status pill, posts/cadence + remaining,
    // last-posted relative time, circuit + failures when non-zero, last error
    // when present, and the owner marker.
    private func row(_ rec: BrandPostingRecord) -> some View {
        let pill = rec.statusPill
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(rec.brand)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text("@\(rec.handle)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(width: 110, alignment: .leading)

                statusPill(pill)

                Spacer()

                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(rec.postsToday) / \(rec.cadencePerDay)")
                        .font(.system(size: 13, weight: .medium))
                    Text("\(rec.remainingToday) left today")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: 10) {
                if let last = rec.lastPostedAt, let when = Self.relative(last) {
                    Text("last posted \(when)")
                } else {
                    Text("no posts yet")
                }
                if rec.circuitState != "closed" || rec.consecutiveFailures > 0 {
                    Text("circuit \(rec.circuitState)\(rec.consecutiveFailures > 0 ? ", \(rec.consecutiveFailures) fails" : "")")
                        .foregroundStyle(pill.tint)
                }
                Spacer()
                Text("owner: brands-poster")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if let err = rec.lastError, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(pill.tint)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // Tight, not chunky: utility radius 10, 1pt stroke, no chunky fill. Derived
    // tint comes from the model so the worst state colors the pill.
    private func statusPill(_ pill: BrandPostingPill) -> some View {
        let color = pill.tint
        return Text(pill.label)
            .font(.system(size: 13, weight: .bold))
            .padding(.horizontal, 10)
            .frame(minHeight: 24)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(color.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(color.opacity(0.45), lineWidth: 1)
            )
            .foregroundStyle(color)
    }

    // cdp_up dot: green when the content-decision pipeline is up, gray (with a
    // hint) when it is down, so a dead CDP is visible at the header.
    private var cdpIndicator: some View {
        let up = store.status?.cdpUp ?? false
        return HStack(spacing: 4) {
            Circle()
                .fill(store.status == nil ? Color(nsColor: .systemGray) : (up ? .green : .red))
                .frame(width: 7, height: 7)
            Text(store.status == nil ? "cdp ?" : (up ? "cdp up" : "cdp down"))
                .font(.caption2)
                .foregroundStyle(up ? Color.secondary : Color.red)
        }
        .help("Content-decision pipeline reachability reported by the remote service")
    }

    private var subtitle: String {
        guard let status = store.status else {
            return store.lastUpdated == nil ? "not yet pulled" : "cached"
        }
        if let when = Self.relative(status.updatedAt) {
            return "updated \(when)"
        }
        guard let t = store.lastUpdated else { return "cached" }
        return "updated \(Self.timeFormatter.string(from: t))"
    }

    // What an answered-but-empty status says. Success with zero brands reads
    // differently from absence: the service is there, so the panel says so
    // instead of rendering nothing under the header. Internal so the copy
    // tests can read the sentence the screen draws.
    static let emptyStatusCopy = "The posting service answered with no posting accounts configured yet. "
        + "Rows appear here once the engine posts for a brand."

    // MARK: - Time helpers (cached: SwiftUI recomputes body often, and these
    // formatters are expensive to construct on every render).

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        return f
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoFormatterNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    // Parse an ISO8601 timestamp (with or without fractional seconds) into a
    // relative string like "5m ago". Returns nil when the string does not parse,
    // so the caller can fall back to a neutral label.
    private static func relative(_ iso: String) -> String? {
        let date = isoFormatter.date(from: iso) ?? isoFormatterNoFraction.date(from: iso)
        guard let date else { return nil }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
