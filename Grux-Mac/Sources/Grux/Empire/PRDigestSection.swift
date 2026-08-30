import SwiftUI

// SwiftUI section that renders the nightly open-PR digest. Lives inside the
// EmpireDashboard scroll view, next to Brand Sentiment.
//
// SUBSTITUTION NOTE: the spec said "Grux renders in the Inbox view." Grux has no
// standalone Inbox tab (InboxStore powers the "remember this" memory inbox that
// surfaces inside chat, not a window). The Empire Dashboard is the established
// home for digests from the companion service, so the PR digest renders here, the same surface
// as Brand Sentiment. Documented in the catalog.

struct PRDigestSection: View {
    @ObservedObject private var store = PRDigestStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.pull")
                    .foregroundStyle(.purple)
                Text("Open Pull Requests").font(.headline)
                Spacer()
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
                .help("Pull the latest digest from the render service")
            }

            // The absence notice must never render as a pull FAILURE: the
            // no-cache branch stays quiet because the mounted notice below
            // says it better, keyed on the store's typed flag, never on
            // comparing the message string. The stale banner carries no
            // absence arm: absence and stale are disjoint, asserted by the
            // precondition on PrivateServiceFetch.Classification.
            if store.servingStale, let err = store.lastError {
                Text("Showing cached digest. Last pull failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let err = store.lastError, store.digest == nil,
                      !store.lastErrorIsAbsence {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let digest = store.digest {
                if !digest.headline.isEmpty {
                    Text(digest.headline)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Oldest first: the stalest PR is the one most likely rotting.
                let rows = digest.prs.sorted { $0.ageDays > $1.ageDays }
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        prRow(row)
                    }
                }
                HStack(spacing: 12) {
                    Text("\(digest.openCount) open")
                    Text("\(digest.repoCount) repo\(digest.repoCount == 1 ? "" : "s")")
                    Text("via \(digest.source)")
                    if digest.fallbackUsed {
                        Text("headline fallback").foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            } else if store.lastErrorIsAbsence {
                // Only when the pull proved absence. Mounting it on every nil
                // digest put an "absence is normal" card directly under the
                // technical banner of a configured host that is down.
                // Deliberately NOT gated on isFetching: the closure is the
                // recovery pull, so that gate unmounted the card the moment
                // its own recovery started and cancelled it mid-request (see
                // the mount rules on PrivateServiceNoticeView).
                PrivateServiceNoticeView(service: .pullRequestDigest) { await store.refresh() }
            } else if PrivateServiceFetch.awaitingFirstPull(
                hasPayload: store.digest != nil, verdict: store.lastVerdict) {
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
                     ? "Pulling the latest digest..."
                     : "No digest yet. Click refresh to pull one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            store.load()
            // Pull on open if we have nothing, or the cache is older than 30 min.
            if store.digest == nil
               || Date().timeIntervalSince(store.lastUpdated ?? .distantPast) > 1800 {
                Task { await store.refresh() }
            }
        }
    }

    private var subtitle: String {
        guard let t = store.lastUpdated else {
            return store.digest == nil ? "not yet pulled" : "cached"
        }
        let f = DateFormatter()
        f.timeStyle = .short
        return "updated \(f.string(from: t))"
    }

    private func prRow(_ row: PRItem) -> some View {
        let color = mergeColor(row.mergeable, draft: row.draft)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                mergePill(row.mergeable, draft: row.draft)
                Text(row.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(row.ageDays)d")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(row.ageDays >= 7 ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            }
            HStack(spacing: 8) {
                Text("\(repoShort(row.repo)) #\(row.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("by \(row.author)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("+\(row.additions)/-\(row.deletions)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(color.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color.opacity(0.20), lineWidth: 1)
        )
        .onTapGesture {
            if let url = URL(string: row.url) { NSWorkspace.shared.open(url) }
        }
        .help(row.url)
    }

    private func repoShort(_ full: String) -> String {
        full.split(separator: "/").last.map(String.init) ?? full
    }

    private func mergePill(_ state: String, draft: Bool) -> some View {
        let label = draft ? "DRAFT" : state.uppercased()
        return Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(mergeColor(state, draft: draft))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private func mergeColor(_ state: String, draft: Bool) -> Color {
        if draft { return Color(nsColor: .systemGray) }
        switch state.lowercased() {
        case "clean":            return .green
        case "dirty", "blocked": return .red
        case "unstable":         return .orange
        default:                 return .yellow   // unknown / still computing
        }
    }
}
