import SwiftUI
import AppKit

// Research tab: history list on the left, composer + live progress + cited
// report on the right. Reports render through MarkdownText; the sources list
// links out; Export writes the .md wherever the user picks. Mirrors
// NotesView's split layout and the tight control scale.
struct ResearchView: View {
    @ObservedObject private var store = ResearchStore.shared

    @State private var selection: UUID?
    @State private var question = ""

    private var selected: ResearchJob? { selection.flatMap { store.job(id: $0) } }

    var body: some View {
        GruxListDetailScaffold {
            listColumn
        } detail: {
            detailColumn
        }
        .onAppear {
            if selection == nil { selection = store.ordered.first?.id }
        }
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            GruxToolbar("Research") {
                Spacer()
                GruxToolbarButton(title: "New", systemImage: "plus.magnifyingglass",
                                  prominent: true, helpText: "New deep research run") {
                    selection = nil
                    question = ""
                }
            }

            if store.ordered.isEmpty {
                GruxEmptyState(
                    icon: "text.magnifyingglass",
                    line: "No research yet",
                    voiceHint: "Grux, research...",
                    compact: true
                )
            } else {
                List(selection: $selection) {
                    ForEach(store.ordered) { job in
                        jobRow(job)
                            .tag(job.id)
                            .contextMenu {
                                DestructiveMenuButton(
                                    "Delete",
                                    question: "Delete this research run?",
                                    detail: "The findings, sources and synthesis for this run are "
                                        + "removed. Running it again costs another set of model "
                                        + "calls. This cannot be undone.",
                                    confirmLabel: "Delete run"
                                ) {
                                    if selection == job.id { selection = nil }
                                    store.delete(id: job.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func jobRow(_ job: ResearchJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(job.displayTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
                .lineLimit(2)
            HStack(spacing: GruxSpacing.xs + 2) {
                phaseChip(job.phase)
                Text(job.createdAt, style: .date)
                    .font(.system(size: 10))
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private func phaseChip(_ phase: ResearchPhase) -> some View {
        Text(phase.label.uppercased())
            .font(GruxType.microCaps)
            .kerning(0.8)
            .foregroundStyle(phaseColor(phase))
            .padding(.horizontal, GruxSpacing.xs + 2)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(phaseColor(phase).opacity(0.14))
            )
    }

    private func phaseColor(_ phase: ResearchPhase) -> Color {
        switch phase {
        case .done: return GruxTheme.successMint
        case .failed: return GruxTheme.destructiveRose
        case .queued: return GruxTheme.textTertiary
        default: return GruxTheme.accentCo
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let job = selected {
            jobDetail(job)
        } else {
            composer
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.m) {
            Text("Deep Research")
                .font(GruxType.title)
                .foregroundStyle(GruxTheme.textPrimary)
            Text("One question in, a cited multi-source report out. Plans 3-6 angles, gathers the live web in parallel, synthesizes with inline numbered citations.")
                .font(GruxType.body)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $question)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                // Paper cut: ghost placeholder so the empty box invites a
                // question instead of reading as dead space.
                .overlay(alignment: .topLeading) {
                    if question.isEmpty {
                        Text("What should Grux dig into?")
                            .font(.system(size: 14))
                            .foregroundStyle(GruxTheme.textTertiary)
                            .padding(.top, 10)
                            .padding(.leading, GruxSpacing.m)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, GruxSpacing.m)
                .padding(.vertical, 10)
                .frame(height: 90)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            HStack {
                Button(action: run) {
                    Label("Run deep research", systemImage: "sparkle.magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(GruxTheme.accentPrimary)
                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
            }
            Spacer()
        }
        .padding(GruxSpacing.l)
    }

    private func run() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        question = ""
        Task {
            let id = await DeepResearchEngine.shared.start(question: q)
            await MainActor.run { selection = id }
        }
    }

    private func jobDetail(_ job: ResearchJob) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GruxSpacing.l) {
                HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.s) {
                    phaseChip(job.phase)
                    Spacer()
                    if job.phase == .done {
                        Button(action: { exportMarkdown(job) }) {
                            Label("Export .md", systemImage: "square.and.arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                Text(job.question)
                    .font(GruxType.title)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if !job.phase.isTerminal {
                    progressBlock(job)
                }

                if let err = job.errorMessage, job.phase == .failed {
                    Text(err)
                        .font(GruxType.body)
                        .foregroundStyle(GruxTheme.destructiveRose)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !job.reportMarkdown.isEmpty {
                    // The synthesized report is the longest stretch of
                    // model-written prose in the app and had no scrubbing at
                    // all. stripDashesOnly rather than clean, deliberately:
                    // this is markdown, so the whitespace tidy in clean() would
                    // collapse indentation inside fenced code blocks and
                    // nested lists. Scrubbed here at the render boundary so
                    // reports already saved in the store are covered too.
                    MarkdownText(content: DashSanitizer.stripDashesOnly(job.reportMarkdown))
                        .markdownFont(.system(size: 13))
                        .textSelection(.enabled)
                }

                if !job.sources.isEmpty {
                    sourcesBlock(job)
                }
            }
            .padding(GruxSpacing.l)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func progressBlock(_ job: ResearchJob) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            HStack(spacing: GruxSpacing.s) {
                ProgressView()
                    .controlSize(.small)
                Text(job.phase.label)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.accentCo)
            }
            ForEach(Array(job.progressLines.suffix(8).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(GruxType.mono)
                    .foregroundStyle(GruxTheme.textSecondary)
            }
        }
        .padding(GruxSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: GruxTheme.Radius.chip)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func sourcesBlock(_ job: ResearchJob) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs + 2) {
            GruxSectionLabel("SOURCES")
            ForEach(Array(job.sources.enumerated()), id: \.element.id) { i, src in
                HStack(alignment: .firstTextBaseline, spacing: GruxSpacing.s) {
                    Text("[\(i + 1)]")
                        .font(GruxType.mono)
                        .foregroundStyle(GruxTheme.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        if let url = URL(string: src.url) {
                            Link(src.title, destination: url)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(GruxTheme.accentCo)
                        } else {
                            Text(src.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(GruxTheme.textPrimary)
                        }
                        Text(src.url)
                            .font(.system(size: 10))
                            .foregroundStyle(GruxTheme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Export

    private func exportMarkdown(_ job: ResearchJob) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename(job)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? job.reportMarkdown.data(using: .utf8)?.write(to: url, options: .atomic)
        }
    }

    private func suggestedFilename(_ job: ResearchJob) -> String {
        let slug = job.displayTitle
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
        return "research-\(slug.isEmpty ? job.id.uuidString.lowercased() : slug).md"
    }
}
