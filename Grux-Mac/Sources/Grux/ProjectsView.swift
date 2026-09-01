import SwiftUI
import Foundation
import AppKit
import GruxShellCore

// MARK: - ProjectsObserver
//
// @MainActor ObservableObject that owns the merged registry + local snapshot.
// Polls every 30s; refreshes immediately on demand (pull-to-refresh, tab
// appear, status toggles). Kept separate from the view so the whole app
// can grab a shared instance if another surface wants it later.

@MainActor
final class ProjectsObserver: ObservableObject {
    static let shared = ProjectsObserver()

    @Published var snapshot: ProjectsIndex.Snapshot?
    @Published var isRefreshing: Bool = false
    @Published var filter: String = ""

    private var timer: Timer?
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        isRefreshing = true
        let snap = await ProjectsIndex.snapshot()
        snapshot = snap
        isRefreshing = false
    }

    func toggleStatus(_ p: ProjectEntry) async {
        guard let remote = p.remote else { return }
        let current = remote.status == "active"
        _ = await ProjectRegistryClient.setStatus(id: remote.id, active: !current)
        await refresh()
    }

    // Filtered view - name or rootPath substring, case-insensitive.
    var filteredEntries: [ProjectEntry] {
        guard let entries = snapshot?.entries else { return [] }
        let q = filter.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return entries }
        return entries.filter {
            $0.name.localizedCaseInsensitiveContains(q) ||
            $0.rootPath.localizedCaseInsensitiveContains(q) ||
            $0.id.localizedCaseInsensitiveContains(q)
        }
    }
}

// MARK: - ProjectsView
//
// Grid of project cards for the "Projects" sidebar tab. Click a card to
// open the detail sheet with history + actions.

struct ProjectsView: View {
    @StateObject private var obs = ProjectsObserver.shared
    @State private var openEntry: ProjectEntry?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if let snap = obs.snapshot {
                if snap.entries.isEmpty {
                    emptyState(snap: snap)
                } else {
                    grid
                }
            } else {
                ProgressView("Loading projects…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            obs.start()
            Task { await obs.refresh() }
        }
        .sheet(item: $openEntry) { e in
            ProjectDetailSheet(entry: e) { openEntry = nil }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: GruxSpacing.m) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(.purple)
            Text("Projects").font(GruxType.title)

            if let snap = obs.snapshot {
                sourcePill(snap)
            }

            Spacer()

            TextField("filter", text: $obs.filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)

            Button {
                Task { await obs.refresh() }
            } label: {
                Image(systemName: obs.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .rotationEffect(.degrees(obs.isRefreshing ? 360 : 0))
                    // Gated like every other loop in the app. A spinner that
                    // is honestly reporting work still has no business turning
                    // while the user asked for less motion, or while the window
                    // it lives in is behind something else.
                    .animation(MotionTokens.gated(obs.isRefreshing
                               ? .linear(duration: 1).repeatForever(autoreverses: false)
                               : .default), value: obs.isRefreshing)
            }
            .help("Refresh now")
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, GruxSpacing.l).padding(.vertical, GruxSpacing.m)
    }

    private func sourcePill(_ snap: ProjectsIndex.Snapshot) -> some View {
        let (label, color): (String, Color) = {
            switch snap.registrySource {
            case .macMini:   return ("live · remote host", .green)
            case .localhost: return ("live · localhost", .blue)
            case .cache:     return ("cached · \(relativeTime(snap.registryFetchedAt))", .orange)
            case .empty:     return ("offline", .red)
            }
        }()
        return HStack(spacing: GruxSpacing.xs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption.monospacedDigit())
            Text("·").foregroundStyle(.tertiary)
            Text("\(snap.entries.count) projects").font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, GruxSpacing.s).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.6))
    }

    // MARK: - Grid

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: GruxSpacing.m)],
                      spacing: GruxSpacing.m) {
                ForEach(obs.filteredEntries) { entry in
                    ProjectCard(entry: entry) { openEntry = entry }
                }
            }
            .padding(GruxSpacing.l)
        }
    }

    // MARK: - Empty state

    /// The empty state's copy, as data, so it can be asserted on.
    ///
    /// THE BUG THIS REPLACES. A new user has no registry and no cache, so
    /// `registrySource` is `.empty` and they were shown "The project registry is
    /// unreachable and no cached copy is on disk" followed by "Start the project
    /// registry at http://localhost:3847 or scaffold a Grux project."
    ///
    /// That is a developer instruction in a shipped app. It reports an internal
    /// component as broken, then asks somebody to start a server they have never
    /// heard of at a port they cannot be expected to know, to fix a state that is
    /// not broken at all. `endpointRegistry` is OPTIONAL in the feature registry,
    /// so Projects is deliberately not gated and this screen is the FIRST thing a
    /// stranger sees on the tab.
    ///
    /// Same rule as the chat suggestion chips: never instruct something the user
    /// cannot act on. What they can act on is the local path, which is how almost
    /// everybody will actually use this, so that is what the copy leads with.
    static func emptyCopy(registryMissing: Bool) -> (title: String, body: String, note: String?) {
        let roots = ProjectsIndex.scanRoots
            .map { ($0 as NSString).lastPathComponent }
            .map { "~/" + $0 }
            .joined(separator: ", ")
        let title = "No projects yet"
        let body = "Grux treats any folder holding a .grux/project.json as a project, and looks in \(roots). Add that file to something you already work in and it appears here."
        guard registryMissing else { return (title, body, nil) }
        // Stated as optional rather than as a failure, because for almost
        // everybody it is not one.
        let note = "You can also pull projects from a registry you run on another machine. Most people never will, and nothing here is broken without it."
        return (title, body, note)
    }

    private func emptyState(snap: ProjectsIndex.Snapshot) -> some View {
        let copy = Self.emptyCopy(registryMissing: snap.registrySource == .empty)
        return VStack(spacing: GruxSpacing.m) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(copy.title).font(.headline)
            Text(copy.body)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let note = copy.note {
                Text(note)
                    .font(.caption2).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Helpers

    private func relativeTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - ProjectCard

private struct ProjectCard: View {
    let entry: ProjectEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: GruxSpacing.m) {
                HStack(alignment: .center, spacing: GruxSpacing.s) {
                    Text(entry.name).font(.headline).lineLimit(1)
                    Spacer()
                    healthDot
                }

                HStack(spacing: GruxSpacing.xs + 2) {
                    tierPill
                    originPill
                    if let ms = healthMs { Text("\(ms)ms").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
                }

                if let remote = entry.remote {
                    row("globe", remote.healthUrl ?? "-")
                }
                if let local = entry.local, let app = local.lastAppPath {
                    row("app.badge.fill", (app as NSString).lastPathComponent)
                }
                row("folder", (entry.rootPath as NSString).abbreviatingWithTildeInPath)

                HStack(spacing: GruxSpacing.xs + 2) {
                    smallChip("Finder", systemImage: "folder") { revealInFinder(entry.rootPath) }
                    if let repo = entry.remote?.repoUrl {
                        smallChip("Repo", systemImage: "chevron.left.forwardslash.chevron.right") {
                            openURL(repo)
                        }
                    }
                    if let url = entry.remote?.healthUrl {
                        smallChip("Open", systemImage: "safari") { openURL(url) }
                    }
                    Spacer()
                }
            }
            .padding(GruxSpacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(borderColor.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var healthDot: some View {
        let c: Color = {
            switch entry.healthPill {
            case .healthy:   return .green
            case .down:      return .red
            case .scaffolded: return .purple
            case .unknown:   return .gray
            }
        }()
        return Circle().fill(c).frame(width: 10, height: 10)
            .shadow(color: c.opacity(0.6), radius: 3)
    }

    private var healthMs: Int? {
        if case .healthy(let ms) = entry.healthPill { return ms }
        return nil
    }

    private var tierPill: some View {
        let (label, color) = tierStyle(entry.displayTier)
        return Text(label)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.15)))
    }

    private var originPill: some View {
        let (label, color): (String, Color) = {
            switch entry.origin {
            case .registryManaged:     return ("Registry-managed", .purple)
            case .gruxScaffolded: return ("Grux-scaffolded", .green)
            case .both:           return ("Registry + Grux", .mint)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.6))
    }

    private var borderColor: Color {
        switch entry.healthPill {
        case .healthy: return .green
        case .down:    return .red
        case .scaffolded: return .purple
        case .unknown: return .gray
        }
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(spacing: GruxSpacing.xs + 2) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func smallChip(_ text: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: GruxSpacing.xs) {
                Image(systemName: systemImage).font(.caption2)
                Text(text).font(.caption2.weight(.medium))
            }
            .padding(.horizontal, GruxSpacing.s).padding(.vertical, 3)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail sheet

private struct ProjectDetailSheet: View {
    let entry: ProjectEntry
    let onDismiss: () -> Void
    @State private var history: [RemoteHealthPoint] = []
    @State private var isLoadingHistory = false
    @StateObject private var obs = ProjectsObserver.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: GruxSpacing.l) {
                    metaSection
                    actionsSection
                    if entry.remote != nil {
                        healthSection
                    }
                    if let shot = entry.local?.lastScreenshotPath, FileManager.default.fileExists(atPath: shot) {
                        screenshotSection(path: shot)
                    }
                }
                .padding(GruxSpacing.xl)
            }
            Divider().opacity(0.4)
            footer
        }
        .frame(minWidth: 640, minHeight: 560)
        .task { await loadHistory() }
    }

    private var header: some View {
        HStack(spacing: GruxSpacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(GruxType.title)
                Text(entry.id).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { onDismiss() }
        }
        .padding(GruxSpacing.l)
    }

    private var metaSection: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            row("Root", entry.rootPath)
            if let h = entry.remote?.healthUrl { row("Health URL", h) }
            if let r = entry.remote?.repoUrl { row("Repo", r) }
            if let bid = entry.local?.bundleId { row("Bundle ID", bid) }
            if let scheme = entry.local?.scheme { row("Scheme", scheme) }
            if let feats = entry.local?.features, !feats.isEmpty {
                row("Features", feats.joined(separator: ", "))
            }
            if let built = entry.local?.lastBuildAt {
                row("Last build", built.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text("ACTIONS").font(.caption.weight(.heavy)).kerning(1.2).foregroundStyle(.secondary)
            FlowHStack(spacing: GruxSpacing.s) {
                button("Reveal in Finder", systemImage: "folder.fill") {
                    revealInFinder(entry.rootPath)
                }
                if let xc = entry.local?.xcodeprojPath, FileManager.default.fileExists(atPath: xc) {
                    button("Open in Xcode", systemImage: "hammer.fill") { openPath(xc) }
                }
                button("Open in Terminal", systemImage: "terminal") {
                    openInTerminal(entry.rootPath)
                }
                if let url = entry.remote?.healthUrl { button("Open Site", systemImage: "safari.fill") { openURL(url) } }
                if let url = entry.remote?.repoUrl { button("Open Repo", systemImage: "chevron.left.forwardslash.chevron.right") { openURL(url) } }
                if entry.remote != nil {
                    button(entry.remote?.status == "active" ? "Pause in registry" : "Resume in registry",
                           systemImage: entry.remote?.status == "active" ? "pause.circle.fill" : "play.circle.fill") {
                        Task { await obs.toggleStatus(entry) }
                    }
                }
            }
        }
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text("HEALTH, last \(history.count) checks")
                .font(.caption.weight(.heavy)).kerning(1.2).foregroundStyle(.secondary)
            if isLoadingHistory {
                ProgressView().controlSize(.small)
            } else if history.isEmpty {
                // Fills itself, so it says what causes that rather than
                // offering a button the user is not the one to press.
                Text("No history yet. Health is recorded each time Grux sweeps your projects.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HealthSparkline(points: history)
                    .frame(height: 56)
                HStack {
                    Text(summary(history)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
    }

    private func screenshotSection(path: String) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text("LAST BUILD SCREENSHOT")
                .font(.caption.weight(.heavy)).kerning(1.2).foregroundStyle(.secondary)
            if let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 360)
                    .cornerRadius(8)
                    .onTapGesture { openPath(path) }
            }
            Text(path).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private var footer: some View {
        HStack {
            if let d = entry.remote?.lastHealth?.checkedAt {
                Text("last check: \(d)")
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Close") { onDismiss() }
        }
        .padding(GruxSpacing.m)
    }

    // MARK: helpers

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.m) {
            Text(label.uppercased())
                .font(.caption2.weight(.heavy)).kerning(1.2)
                .foregroundStyle(.tertiary)
                .frame(width: 100, alignment: .leading)
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
            Spacer()
        }
    }

    private func button(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage).font(.caption)
        }
        .controlSize(.small)
    }

    private func loadHistory() async {
        guard let slug = entry.remote?.slug else { return }
        isLoadingHistory = true
        history = await ProjectRegistryClient.fetchHistory(slug: slug)
        isLoadingHistory = false
    }

    private func summary(_ pts: [RemoteHealthPoint]) -> String {
        let up = pts.filter { $0.healthy == true }.count
        let total = pts.count
        let pct = total == 0 ? 0 : Int(round(Double(up) / Double(total) * 100))
        let avg = pts.compactMap { $0.responseTimeMs }
        let avgMs = avg.isEmpty ? 0 : avg.reduce(0, +) / avg.count
        return "\(pct)% up · avg \(avgMs)ms"
    }
}

// MARK: - HealthSparkline

private struct HealthSparkline: View {
    let points: [RemoteHealthPoint]

    var body: some View {
        GeometryReader { geo in
            let maxMs = max(1, points.compactMap { $0.responseTimeMs }.max() ?? 1)
            let step = points.count > 1 ? geo.size.width / CGFloat(points.count - 1) : 0

            ZStack {
                // Response-time polyline
                Path { p in
                    for (i, pt) in points.enumerated() {
                        let x = CGFloat(i) * step
                        let y = geo.size.height - (CGFloat(pt.responseTimeMs ?? 0) / CGFloat(maxMs)) * geo.size.height
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.green, lineWidth: 1.2)

                // Down markers - red vertical tick at any unhealthy check
                ForEach(Array(points.enumerated()), id: \.offset) { i, pt in
                    if pt.healthy == false {
                        let x = CGFloat(i) * step
                        Rectangle().fill(Color.red.opacity(0.6))
                            .frame(width: 1.5, height: geo.size.height)
                            .position(x: x, y: geo.size.height / 2)
                    }
                }
            }
        }
    }
}

// MARK: - Tier style

private func tierStyle(_ tier: String) -> (String, Color) {
    switch tier {
    case "Tier 1": return ("TIER 1", .red)
    case "Tier 2": return ("TIER 2", .orange)
    case "Tier 3": return ("TIER 3", .yellow)
    case "Grux":   return ("GRUX", .purple)
    default:       return (tier.uppercased(), .gray)
    }
}

// MARK: - Open helpers (file-scope so both card + sheet share)

fileprivate func openURL(_ s: String) {
    guard let u = URL(string: s) else { return }
    NSWorkspace.shared.open(u)
}

fileprivate func openPath(_ p: String) {
    let u = URL(fileURLWithPath: p)
    NSWorkspace.shared.open(u)
}

fileprivate func revealInFinder(_ path: String) {
    let u = URL(fileURLWithPath: path)
    NSWorkspace.shared.activateFileViewerSelecting([u])
}

fileprivate func openInTerminal(_ path: String) {
    let script = "tell application \"Terminal\" to do script \"cd \\\"\(path)\\\"\""
    let task = Process()
    task.launchPath = "/usr/bin/osascript"
    task.arguments = ["-e", script]
    try? task.run()
}

// MARK: - FlowHStack
//
// Wrapping HStack for the action chips - SwiftUI's built-in HStack doesn't
// wrap, and an adaptive LazyVGrid inside a sheet looks misaligned. This keeps
// chips left-packed with line breaks where the width ends.

private struct FlowHStack<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: () -> Content

    init(spacing: CGFloat = 8, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        // SwiftUI Layout protocol makes a real flow layout cleanly.
        FlowLayout(spacing: spacing) {
            content()
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += lineH + spacing; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
            maxX = max(maxX, x)
        }
        return CGSize(width: min(maxW, maxX), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            sv.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
