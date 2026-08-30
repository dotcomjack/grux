import SwiftUI

// SwiftUI section that renders the nightly empire test report. Lives inside the
// EmpireDashboard scroll view, right below the PR digest.
//
// SUBSTITUTION NOTE: the spec said "files report into Grux inbox". Grux has no
// standalone Inbox window (InboxStore powers the "remember this" memory inbox
// that surfaces inside chat). The Empire Dashboard is the established home for
// digests from the companion service (PR digest, sentiment, LLM spend), so the nightly test
// report renders here too. Documented in the catalog.

struct TestDigestSection: View {
    @ObservedObject private var store = TestDigestStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.teal)
                Text("Nightly Tests").font(.headline)
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
                .help("Pull the latest nightly test report from the render service")
            }

            // Same honesty rule as PRDigestSection: the stale banner carries
            // no absence arm (the Classification precondition asserts the
            // disjointness) and always names the fault technically.
            if store.servingStale, let err = store.lastError {
                Text("Showing cached report. Last pull failed: \(err)")
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
                let rows = digest.results.sorted { (rank($0.status)) < (rank($1.status)) }
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        repoRow(row)
                    }
                }
                HStack(spacing: 12) {
                    Text("\(digest.passCount) pass").foregroundStyle(.green)
                    if digest.failCount > 0 { Text("\(digest.failCount) fail").foregroundStyle(.red) }
                    if digest.errorCount > 0 { Text("\(digest.errorCount) error").foregroundStyle(.orange) }
                    if digest.skipCount > 0 { Text("\(digest.skipCount) skip") }
                    Text("via \(digest.source)")
                    Text("\(Int(digest.durationSec))s")
                    if digest.fallbackUsed {
                        Text("degraded coverage").foregroundStyle(.orange)
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
                PrivateServiceNoticeView(service: .nightlyTests) { await store.refresh() }
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
                     ? "Pulling the latest report..."
                     : "No report yet. Click refresh to pull one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            store.load()
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

    // Sort order: failures and errors float to the top.
    private func rank(_ status: String) -> Int {
        switch status.lowercased() {
        case "fail":  return 0
        case "error": return 1
        case "skip":  return 2
        default:      return 3   // pass
        }
    }

    private func repoRow(_ row: TestRepoResult) -> some View {
        let color = statusColor(row.status)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusPill(row.status)
                Text(row.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text("\(Int(row.durationSec))s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            // Per-check line: kind:status, with the failure summary inline.
            ForEach(Array(row.checks.enumerated()), id: \.offset) { _, c in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("\(c.kind): \(c.status)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(c.status == "pass" ? AnyShapeStyle(.secondary) : AnyShapeStyle(statusColor(c.status)))
                        Text(c.command)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if c.status != "pass", !c.summary.isEmpty, c.summary != "ok" {
                        Text(c.summary)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
            }
            Text(row.gitInfo)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
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
    }

    private func statusPill(_ status: String) -> some View {
        Text(status.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(statusColor(status))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "pass":  return .green
        case "fail":  return .red
        case "error": return .orange
        case "skip":  return Color(nsColor: .systemGray)
        default:      return .yellow
        }
    }
}
