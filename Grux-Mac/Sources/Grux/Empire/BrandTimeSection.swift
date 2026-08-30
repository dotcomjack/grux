import SwiftUI

// SwiftUI section that renders the latest BrandAttribution.DailyReport for
// today. Lives inside the EmpireDashboard scroll view. Self-contained: owns
// its own observable store, its own recompute button, and its own row layout.
// EmpireDashboardWindow just drops `BrandTimeSection()` after the App Store
// section.

@MainActor
final class BrandTimeStore: ObservableObject {
    static let shared = BrandTimeStore()

    @Published private(set) var report: BrandAttribution.DailyReport?
    @Published private(set) var lastComputed: Date?
    @Published private(set) var isComputing: Bool = false

    private init() {}

    func recompute() {
        guard !isComputing else { return }
        isComputing = true
        Task.detached(priority: .utility) { [weak self] in
            let now = Date()
            let r = BrandAttribution.computeAndWriteToday(now: now)
            await MainActor.run {
                guard let self else { return }
                self.report = r
                self.lastComputed = now
                self.isComputing = false
            }
        }
    }

    // Used by callers (e.g. the fire-brand-time-test trigger) that already
    // ran BrandAttribution.computeAndWriteToday() themselves. Skips the inner
    // detached recompute so we don't write the file twice in a row.
    func setReport(_ r: BrandAttribution.DailyReport, computedAt: Date) {
        self.report = r
        self.lastComputed = computedAt
        self.isComputing = false
    }
}

struct BrandTimeSection: View {
    // ObservedObject (not StateObject) because the store is a long-lived
    // singleton this view does not own. StateObject would attempt to wire its
    // lifetime to the view's identity, which is wrong for shared state.
    @ObservedObject private var store = BrandTimeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.orange)
                Text("Time per Brand, Today").font(.headline)
                Spacer()
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if store.isComputing {
                    ProgressView().controlSize(.mini)
                }
                Button { store.recompute() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isComputing)
                .help("Recompute now")
            }
            if let report = store.report {
                if report.brands.isEmpty {
                    Text("No brand-attributable activity yet today.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(report.brands, id: \.brand) { row in
                            brandRow(row, totalActive: max(report.totalActiveSeconds, 1))
                        }
                    }
                    HStack(spacing: 12) {
                        Text("Total active: \(formatHM(report.totalActiveSeconds))")
                        Text("Unattributed: \(formatHM(report.unattributedSeconds))")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                }
            } else if !store.isComputing {
                Text("Computing first report…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if store.report == nil
               || Date().timeIntervalSince(store.lastComputed ?? .distantPast) > 300 {
                store.recompute()
            }
        }
    }

    private var subtitle: String {
        guard let t = store.lastComputed else { return "not yet computed" }
        let f = DateFormatter()
        f.timeStyle = .short
        return "computed \(f.string(from: t))"
    }

    private func brandRow(
        _ row: BrandAttribution.BrandBreakdown,
        totalActive: Int
    ) -> some View {
        let pct = Double(row.totalSeconds) / Double(totalActive)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.brand).font(.body.weight(.semibold))
                HStack(spacing: 8) {
                    Text("\(Int((pct * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    if row.gitCommits > 0 {
                        Text("\(row.gitCommits) commit\(row.gitCommits == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if row.chromeSeconds > 0 {
                        Text("web \(formatHM(row.chromeSeconds))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            ProgressView(value: pct)
                .progressViewStyle(.linear)
                .tint(.orange)
                .frame(width: 140)
            Text(formatHM(row.totalSeconds))
                .font(.body.monospacedDigit())
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.20), lineWidth: 1)
        )
    }

    private func formatHM(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}
