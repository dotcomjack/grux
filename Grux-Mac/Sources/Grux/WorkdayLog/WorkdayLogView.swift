import SwiftUI
import AppKit

// Two-pane browser for workday logs. Left rail = index.json (most recent
// first). Right pane = rendered markdown of the selected log.

struct WorkdayLogView: View {
    let onClose: () -> Void

    @State private var entries: [WorkdayLogIndexEntry] = []
    @State private var selectedDayKey: String?
    @State private var selectedLog: WorkdayLog?
    @State private var isLoadingSelection = false
    @State private var isGenerating = false
    @State private var generationError: String?

    var body: some View {
        ZStack {
            // Glass background
            VisualEffectView(material: .hudWindow, blending: .behindWindow)
                .ignoresSafeArea()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack(spacing: 0) {
                // 260 is the index column's IDEAL and its ceiling, not a fixed
                // size. The panel is a fixed 980pt wide today so this still
                // renders at 260, but as a range the index gives ground first,
                // down to GruxLayout.listColumnMin, if the panel is ever
                // resized or this view is embedded in the main window. With a
                // hard width the log text is what absorbs every lost point, and
                // it clips rather than reflows.
                sidebar.frame(minWidth: GruxLayout.listColumnMin, idealWidth: 260, maxWidth: 260)
                Divider().opacity(0.4)
                rightPane
            }
            .padding(12)
        }
        .frame(minWidth: 900, minHeight: 620)
        .onAppear(perform: reloadAll)
        .onReceive(NotificationCenter.default.publisher(for: .gruxWorkdayLogSaved)) { _ in
            reloadAll()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WORKDAY LOG")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(1.4)
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }

            Button(action: generateNow) {
                HStack(spacing: 6) {
                    Image(systemName: isGenerating ? "hourglass" : "sparkles")
                    Text(isGenerating ? "Generating…" : "Generate today's log now")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(GruxTheme.accentPrimary.opacity(0.35)))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .disabled(isGenerating)

            if let err = generationError {
                Text(err).font(.caption2).foregroundColor(.red.opacity(0.9))
            }

            Divider().opacity(0.3)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if entries.isEmpty {
                        Text("No logs yet. The first one lands at 6am, or click Generate now.")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.55))
                            .padding(.top, 8)
                    }
                    ForEach(entries) { entry in
                        Button(action: { select(entry.dayKey) }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.dayKey)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                Text(entry.narrativeSnippet.isEmpty ? "(no narrative)" : entry.narrativeSnippet)
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.6))
                                    .lineLimit(2)
                                if !entry.tags.isEmpty {
                                    Text(entry.tags.prefix(4).joined(separator: " · "))
                                        .font(.system(size: 10))
                                        .foregroundColor(.white.opacity(0.4))
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(selectedDayKey == entry.dayKey
                                          ? Color.white.opacity(0.15)
                                          : Color.white.opacity(0.04))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Right pane

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let log = selectedLog {
                HStack {
                    Text(log.dayKey)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    if let url = WorkdayLogStore.markdownMirrorURL(for: log.dayKey) {
                        Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("Reveal in Finder")
                            }
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 4)

                ScrollView {
                    let md = WorkdayLogRenderer.renderMarkdown(log)
                    if let attributed = try? AttributedString(
                        markdown: md,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    ) {
                        Text(attributed)
                            .textSelection(.enabled)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    } else {
                        Text(md)
                            .textSelection(.enabled)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white.opacity(0.95))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
            } else if isLoadingSelection {
                Spacer(); ProgressView().tint(.white); Spacer()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 32))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Pick a day on the left, or generate today's log now.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.leading, 12)
    }

    // MARK: - Data flow

    private func reloadAll() {
        let list = WorkdayLogStore.list()
        entries = list
        if selectedDayKey == nil, let first = list.first {
            select(first.dayKey)
        } else if let sel = selectedDayKey {
            // Refresh current selection if it changed
            selectedLog = WorkdayLogStore.load(dayKey: sel)
        }
    }

    private func select(_ dayKey: String) {
        selectedDayKey = dayKey
        isLoadingSelection = true
        DispatchQueue.main.async {
            selectedLog = WorkdayLogStore.load(dayKey: dayKey)
            isLoadingSelection = false
        }
    }

    private func generateNow() {
        guard !isGenerating else { return }
        isGenerating = true
        generationError = nil
        let dayKey = WorkdayLogScheduler.currentDayKey()
        Task { @MainActor in
            let log = await WorkdayLogScheduler.shared.generateWorkdayLogNow(forDayKey: dayKey)
            isGenerating = false
            selectedDayKey = log.dayKey
            selectedLog = log
            reloadAll()
        }
    }
}

// Small AppKit wrapper so the panel can use hud material. DailyRecapView
// already uses a different utility - we avoid colliding by namespacing.
private struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
