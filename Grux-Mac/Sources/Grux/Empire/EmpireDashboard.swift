import SwiftUI

// Empire-wide ops snapshot: revenue per brand, app installs, support volume, the
// open-PR queue, and infra health, in one dense pane at the top of the Empire
// Dashboard. The heavy aggregation runs in a separate snapshot service you host
// yourself; Grux just polls the cached JSON so the UI is instant. No host ships
// baked in, see EmpireSnapshotService.
//
// SUBSTITUTIONS (documented in the service README):
//   - Installs default to a public ratings proxy (iTunes lookup userRatingCount)
//     because true unit downloads need an ASC vendor number not in the keystore.
//   - Revenue (Stripe) shows n/a until a restricted Stripe key is provisioned.
//   - Support volume shows n/a when the mail provider is not programmatically
//     readable in this environment.
//
// Mirrors the PRDigestStore pull pattern: failover base URLs (tailnet -> localhost
// -> LAN), a persisted cache so the pane has something before the first live pull,
// and a ~/.grux/empire-snapshot.md mirror for CLI smoke tests.

// MARK: - Models (decode the companion snapshot JSON; lenient/optional throughout)

struct EmpireSnapshot: Codable, Equatable {
    var generatedAt: String
    var generatedAtEpoch: Double
    var tookMs: Int
    var source: String
    var brandCount: Int
    var brands: [EmpireBrand]
    var totals: EmpireTotals
    var sources: [String: EmpireSourceMeta]
    var errors: [String]
}

struct EmpireBrand: Codable, Equatable, Identifiable {
    var key: String
    var name: String
    var primary: Bool
    var revenueCents: Int?
    var revenueCurrency: String?
    var revenueSource: String
    var installs: Int?
    var installsWindow: String?
    var installsSource: String
    var ratingCount: Int?
    var rating: Double?
    var version: String?
    var openPRs: Int
    var support: Int?
    var infra: EmpireInfra

    var id: String { key }
}

struct EmpireInfra: Codable, Equatable {
    var healthy: Int
    var total: Int
    var degraded: Int
}

struct EmpireTotals: Codable, Equatable {
    var revenueCents: Int?
    var revenueCurrency: String?
    var installs: Int?
    var ratingCount: Int?
    var openPRs: Int
    var support: Int?
    var infraHealthy: Int
    var infraTotal: Int
}

// Per-source health badge data. Unknown extra fields (appCount, serviceCount, …)
// are ignored by Codable, so this stays small and stable.
struct EmpireSourceMeta: Codable, Equatable {
    var ok: Bool?
    var configured: Bool?
    var mode: String?
    var note: String?
}

// MARK: - Store

@MainActor
final class EmpireSnapshotStore: ObservableObject {
    static let shared = EmpireSnapshotStore()

    @Published private(set) var snapshot: EmpireSnapshot?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var isFetching = false
    @Published private(set) var lastError: String?
    @Published private(set) var servingStale = false

    private var loaded = false

    private var jsonURL: URL { Persistence.supportDir.appendingPathComponent("empire-snapshot.json") }
    private var mdURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".grux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("empire-snapshot.md")
    }

    private init() {}

    func load() {
        guard !loaded else { return }
        loaded = true
        if let data = try? Data(contentsOf: jsonURL),
           let cached = try? JSONDecoder().decode(EmpireSnapshot.self, from: data) {
            self.snapshot = cached
        }
    }

    func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        lastError = nil
        defer { isFetching = false }

        do {
            let fresh = try await EmpireSnapshotService.fetchLatest()
            apply(fresh)
        } catch {
            self.lastError = error.localizedDescription
            self.servingStale = (self.snapshot != nil)
            WakeLog.shared.log("empire-snapshot: pull failed: \(error.localizedDescription)")
        }
    }

    private func apply(_ s: EmpireSnapshot) {
        self.snapshot = s
        self.lastUpdated = Date()
        self.servingStale = false
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: jsonURL, options: .atomic)
        }
        writeMarkdownMirror(s)
    }

    // Human + CLI readable mirror at ~/.grux/empire-snapshot.md so a smoke test can
    // grep the result without parsing app state. Same convention as pr-digest.md.
    private func writeMarkdownMirror(_ s: EmpireSnapshot) {
        func money(_ cents: Int?, _ ccy: String?) -> String {
            guard let c = cents else { return "n/a" }
            return String(format: "$%.2f %@", Double(c) / 100.0, (ccy ?? "usd").uppercased())
        }
        var lines: [String] = []
        lines.append("# Empire Ops Snapshot")
        lines.append("")
        lines.append("Generated: \(s.generatedAt) | source: \(s.source) | \(s.brandCount) brands | \(s.tookMs)ms")
        lines.append("")
        let t = s.totals
        lines.append("Totals: revenue \(money(t.revenueCents, t.revenueCurrency)) | installs \(t.installs.map(String.init) ?? "n/a") | ratings \(t.ratingCount ?? 0) | open PRs \(t.openPRs) | infra \(t.infraHealthy)/\(t.infraTotal) healthy")
        lines.append("")
        lines.append("Sources: " + s.sources.keys.sorted().map { k -> String in
            let m = s.sources[k]
            let state = (m?.ok == true) ? "ok" : ((m?.configured == true) ? "cfg" : "off")
            return "\(k)=\(state)"
        }.joined(separator: " | "))
        lines.append("")
        for b in s.brands {
            let rev = money(b.revenueCents, b.revenueCurrency)
            let inst = b.installs.map(String.init) ?? "n/a"
            lines.append("## \(b.name)")
            lines.append("revenue \(rev) | installs \(inst) (\(b.installsSource)) | ratings \(b.ratingCount ?? 0) | open PRs \(b.openPRs) | infra \(b.infra.healthy)/\(b.infra.total)")
            lines.append("")
        }
        try? lines.joined(separator: "\n").write(to: mdURL, atomically: true, encoding: .utf8)
    }
}

enum EmpireSnapshotService {
    // No host ships baked in. Point GRUX_EMPIRE_SNAPSHOT_URL at the snapshot
    // service's base URL (a LAN box, a tunnel, localhost) to turn the pane on.
    // Unset means no candidates, and refresh() reports that it needs setting up
    // rather than failing loudly.
    static var baseURLs: [String] {
        let raw = (ProcessInfo.processInfo.environment["GRUX_EMPIRE_SNAPSHOT_URL"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? [] : [raw]
    }

    struct FetchError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func fetchLatest() async throws -> EmpireSnapshot {
        var lastErr = "no snapshot host configured (set GRUX_EMPIRE_SNAPSHOT_URL)"
        for base in baseURLs {
            guard let url = URL(string: base + "/api/empire/snapshot") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    lastErr = "no HTTP response from \(base)"
                    continue
                }
                if http.statusCode == 404 {
                    throw FetchError(message: "service has no snapshot yet (404); it builds on boot")
                }
                guard (200..<300).contains(http.statusCode) else {
                    lastErr = "\(base) returned HTTP \(http.statusCode)"
                    continue
                }
                return try JSONDecoder().decode(EmpireSnapshot.self, from: data)
            } catch let e as FetchError {
                throw e
            } catch {
                lastErr = "\(base): \(error.localizedDescription)"
                continue
            }
        }
        throw FetchError(message: lastErr)
    }
}

// MARK: - View

struct EmpireOpsSection: View {
    @ObservedObject private var store = EmpireSnapshotStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let err = store.lastError, store.snapshot == nil {
                errorBanner(err)
            }
            if let snap = store.snapshot {
                totalsStrip(snap.totals)
                sourceBadges(snap.sources)
                brandTable(snap.brands)
            } else if store.isFetching {
                loading
            } else {
                empty
            }
        }
        .onAppear {
            store.load()
            if store.lastUpdated == nil
                || Date().timeIntervalSince(store.lastUpdated!) > 60 {
                Task { await store.refresh() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group.fill").foregroundStyle(.mint)
            Text("Empire Ops").font(.headline)
            if store.servingStale {
                Text("CACHED")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.orange.opacity(0.2))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
            Spacer()
            Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            if store.isFetching { ProgressView().controlSize(.mini) }
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isFetching)
            .help("Pull a fresh snapshot from the render service")
        }
    }

    private var subtitle: String {
        guard let s = store.snapshot else { return "revenue · installs · support · PRs · infra" }
        var parts = ["\(s.brandCount) brands"]
        if let t = store.lastUpdated {
            let f = DateFormatter(); f.timeStyle = .short
            parts.append("updated \(f.string(from: t))")
        }
        parts.append("src \(s.source)")
        return parts.joined(separator: " · ")
    }

    // Big KPI tiles across the top: the empire at a glance.
    private func totalsStrip(_ t: EmpireTotals) -> some View {
        let installsStr = t.installs.map { $0.formatted() }
            ?? (t.ratingCount.map { "\($0.formatted())★" } ?? "n/a")
        return HStack(spacing: 10) {
            kpiTile("Revenue 30d", money(t.revenueCents, t.revenueCurrency), .green, "dollarsign.circle.fill")
            kpiTile("Installs", installsStr, .cyan, "arrow.down.app.fill")
            kpiTile("Open PRs", "\(t.openPRs)", t.openPRs > 0 ? .purple : .secondary, "arrow.triangle.pull")
            // Zero-guard mirrors brandRow(): 0/0 (no tracked services) is neutral,
            // not a false "all healthy" green.
            kpiTile("Infra", "\(t.infraHealthy)/\(t.infraTotal)",
                    t.infraTotal == 0 ? .secondary : (t.infraHealthy == t.infraTotal ? .green : .orange),
                    "server.rack")
            kpiTile("Support", t.support.map(String.init) ?? "n/a", .secondary, "envelope.fill")
        }
    }

    private func kpiTile(_ label: String, _ value: String, _ color: Color, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                Text(label.uppercased()).font(.system(size: 9, weight: .heavy)).foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }

    private func sourceBadges(_ sources: [String: EmpireSourceMeta]) -> some View {
        let order = ["stripe", "asc", "github", "render", "cloudflare", "support"]
        return HStack(spacing: 6) {
            ForEach(order, id: \.self) { key in
                if let m = sources[key] {
                    let ok = m.ok == true
                    let cfg = m.configured == true
                    let color: Color = ok ? .green : (cfg ? .orange : Color(nsColor: .systemGray))
                    let label = ok ? "ok" : (cfg ? "cfg" : "n/a")
                    Text("\(key) \(label)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(color.opacity(0.15))
                        .foregroundStyle(color)
                        .clipShape(Capsule())
                        .help(m.note ?? "\(key): \(label)")
                }
            }
            Spacer()
        }
    }

    // Dense per-brand table. Brands are rows, KPIs are columns. Brands the
    // snapshot marks primary float to the top, then the rest, then unmapped.
    private func brandTable(_ brands: [EmpireBrand]) -> some View {
        let sorted = brands.sorted { a, b in
            if a.key == "_other" { return false }
            if b.key == "_other" { return true }
            if a.primary != b.primary { return a.primary }
            return a.name < b.name
        }
        return VStack(spacing: 4) {
            tableHeaderRow
            ForEach(sorted) { brandRow($0) }
        }
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 8) {
            Text("BRAND").frame(width: 150, alignment: .leading)
            Spacer()
            Text("REV 30d").frame(width: 78, alignment: .trailing)
            Text("INSTALLS").frame(width: 78, alignment: .trailing)
            Text("PRs").frame(width: 40, alignment: .trailing)
            Text("INFRA").frame(width: 56, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .heavy))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
    }

    private func brandRow(_ b: EmpireBrand) -> some View {
        let installs = b.installs.map { $0.formatted() }
            ?? (b.ratingCount.map { "\($0)★" } ?? "-")
        let infraColor: Color = b.infra.total == 0 ? .secondary
            : (b.infra.healthy == b.infra.total ? .green : .orange)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(b.name).font(.system(size: 12, weight: .semibold))
                    if b.primary {
                        Circle().fill(Color.mint).frame(width: 5, height: 5)
                    }
                }
                if let v = b.version {
                    Text("v\(v)").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 150, alignment: .leading)
            Spacer()
            cell(money(b.revenueCents, b.revenueCurrency), b.revenueSource == "stripe" ? .green : .secondary, width: 78)
            cell(installs, b.installs != nil ? .cyan : .secondary, width: 78)
            cell("\(b.openPRs)", b.openPRs > 0 ? .purple : .secondary, width: 40)
            cell(b.infra.total == 0 ? "-" : "\(b.infra.healthy)/\(b.infra.total)", infraColor, width: 56)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor).opacity(0.28)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
    }

    private func cell(_ value: String, _ color: Color, width: CGFloat) -> some View {
        Text(value)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1).minimumScaleFactor(0.7)
            .frame(width: width, alignment: .trailing)
    }

    private func money(_ cents: Int?, _ ccy: String?) -> String {
        guard let c = cents else { return "n/a" }
        let v = Double(c) / 100.0
        if v >= 1000 { return String(format: "$%.0fk", v / 1000.0) }
        return String(format: "$%.0f", v)
    }

    private var loading: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Pulling the empire snapshot from the render service…")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "rectangle.3.group")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("No snapshot yet").font(.subheadline.bold())
            Text("Refresh to pull revenue, installs, PRs, and infra health.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled)
            Spacer()
            Button("Retry") { Task { await store.refresh() } }
                .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
