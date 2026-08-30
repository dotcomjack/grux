import SwiftUI

// SwiftUI section that renders the latest brand-sentiment digest pulled from the
// companion sentiment service. Lives inside the EmpireDashboard scroll view.
// Self-contained: observes the shared SentimentStore, owns its refresh button
// and row layout. EmpireDashboardWindow drops `BrandSentimentSection()` in.

struct BrandSentimentSection: View {
    @ObservedObject private var store = SentimentStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.pink)
                Text("Brand Sentiment").font(.headline)
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
                .help("Pull latest digest from the render service")
            }

            if store.servingStale, let err = store.lastError {
                Text("Showing cached digest. Last pull failed: \(err)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            } else if let err = store.lastError, store.digest == nil {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let digest = store.digest {
                let rows = digest.brands.sorted {
                    if $0.mentionCount != $1.mentionCount { return $0.mentionCount > $1.mentionCount }
                    return $0.score > $1.score
                }
                VStack(spacing: 6) {
                    ForEach(rows) { row in
                        brandRow(row)
                    }
                }
                HStack(spacing: 12) {
                    Text("\(digest.brandCount) brands")
                    Text("\(digest.totalMentions) mention\(digest.totalMentions == 1 ? "" : "s")")
                    if digest.fallbackUsed {
                        Text("Claude fallback used").foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            } else if !store.isFetching {
                Text("No digest yet. Click refresh to pull from the render service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            store.load()
            // Pull on open if we have nothing, or the cache is older than 30 min.
            if store.digest == nil
               || Date().timeIntervalSince(store.lastFetched ?? .distantPast) > 1800 {
                Task { await store.refresh() }
            }
        }
    }

    private var subtitle: String {
        guard let t = store.lastFetched else {
            return store.digest == nil ? "not yet pulled" : "cached"
        }
        let f = DateFormatter()
        f.timeStyle = .short
        return "pulled \(f.string(from: t))"
    }

    private func brandRow(_ row: BrandSentiment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                moodPill(row.mood)
                Text(row.name).font(.body.weight(.semibold))
                Spacer()
                if row.mentionCount > 0 {
                    Text("\(row.mentionCount) mention\(row.mentionCount == 1 ? "" : "s")")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(String(format: "%+.2f", row.score))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(moodColor(row.mood))
            }
            if !row.summary.isEmpty {
                Text(row.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let top = row.highlights.first, !top.isEmpty {
                Text("“\(top)”")
                    .font(.caption2.italic())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(moodColor(row.mood).opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(moodColor(row.mood).opacity(0.20), lineWidth: 1)
        )
    }

    private func moodPill(_ mood: String) -> some View {
        Text(mood.uppercased())
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(moodColor(mood))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private func moodColor(_ mood: String) -> Color {
        switch mood.lowercased() {
        case "positive": return .green
        case "negative": return .red
        case "mixed":    return .yellow
        default:          return Color(nsColor: .systemGray)  // quiet
        }
    }
}
