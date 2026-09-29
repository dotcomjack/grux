import SwiftUI

struct EmpireDashboardWindow: View {
    @ObservedObject private var asc = ASCStateMonitor.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(Color.black.opacity(0.95))
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                // The badge sits in the title, not the sidebar, because this
                // surface has no sidebar row: it opens as its own window from
                // openEmpireDashboardWindow(), so `FeatureRegistry.isLabs(forTab:)`
                // has no key to look it up by and the shell has nothing to mark.
                // Giving it a registry row would not help; the row-to-badge path
                // runs through the sidebar. It is one of the four surfaces that
                // ship as an empty shell until the user connects their own
                // accounts, so it owes the reader the same warning the tabs give.
                HStack(spacing: 6) {
                    Text("Empire Dashboard").font(.title2.bold())
                    BetaBadge()
                }
                Text("Past 24 hours")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Empire-wide ops snapshot first: the one-glance cross-brand KPI
                // grid (revenue, installs, support, PR queue, infra health) backed
                // by the companion service's /api/empire/snapshot. Everything below it drills
                // into a single dimension; this is the executive summary.
                EmpireOpsSection()
                Divider().opacity(0.4)
                ascSection
                Divider().opacity(0.4)
                BrandTimeSection()
                Divider().opacity(0.4)
                BrandSentimentSection()
                Divider().opacity(0.4)
                PRDigestSection()
                Divider().opacity(0.4)
                TestDigestSection()
                Divider().opacity(0.4)
                BrandsPostingSection()
                Divider().opacity(0.4)
                SocialOpsSection()
                Divider().opacity(0.4)
                MetaAdsOpsSection()
            }
            .padding(16)
        }
    }

    // MARK: - App Store Submissions section
    //
    // Shows one row per project with a .grux/ship-config.json: current ASC
    // review state as a colored pill, version, last-checked timestamp, and a
    // button to open the inflight page in App Store Connect. Sweep is global
    // (independent of any V2 workflow run) and runs every 12 hours via
    // ASCStateMonitor. Click the refresh icon to force an immediate re-sweep.

    @ViewBuilder
    private var ascSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "app.badge.fill").foregroundStyle(.purple)
                Text("App Store Submissions").font(.headline)
                Spacer()
                Text(ascSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if asc.isSweeping {
                    ProgressView().controlSize(.mini)
                }
                Button { Task { await asc.sweep() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(asc.isSweeping)
                .help("Sweep all projects now")
            }
            if let err = asc.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if asc.records.isEmpty && !asc.isSweeping && asc.lastError == nil {
                Text("Sweeping…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(asc.records) { row in
                        ascRow(row)
                    }
                }
            }
        }
    }

    private var ascSubtitle: String {
        let cadence = "every 12h"
        guard let t = asc.lastSweep else { return "sweeps \(cadence)" }
        let f = DateFormatter()
        f.timeStyle = .short
        return "checked \(f.string(from: t)) · \(cadence)"
    }

    private func ascRow(_ r: ASCAppRecord) -> some View {
        HStack(spacing: 12) {
            ascPill(r)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.projectName).font(.body.weight(.semibold))
                Text(r.bundleId).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if r.versionString != "-" {
                Text("v\(r.versionString)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let url = r.inflightURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open in App Store Connect")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(ascStripeColor(r).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(ascStripeColor(r).opacity(0.35), lineWidth: 1)
        )
    }

    private func ascPill(_ r: ASCAppRecord) -> some View {
        Text(ascPillLabel(r))
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(ascStripeColor(r))
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private func ascStripeColor(_ r: ASCAppRecord) -> Color {
        switch r.health {
        case .live:     return .green
        case .queued:   return .blue
        case .rejected: return .red
        case .draft:    return Color(nsColor: .systemGray)
        case .unknown:  return Color(nsColor: .systemGray)
        }
    }

    private func ascPillLabel(_ r: ASCAppRecord) -> String {
        switch r.health {
        case .live:     return "LIVE"
        case .queued:   return "IN REVIEW"
        case .rejected: return "REJECTED"
        case .draft:    return "DRAFT"
        case .unknown:  return r.appStoreState
        }
    }

    private func metric(_ value: String, _ label: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 70, alignment: .trailing)
    }
}
