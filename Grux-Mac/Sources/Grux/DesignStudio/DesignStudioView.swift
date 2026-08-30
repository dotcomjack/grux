import SwiftUI

// The Design Studio tab: a split chat + live preview workbench. Left rail holds
// the project list, the chat transcript, the brief composer, and the run
// controls (brand, route, draft, estimated cost). Right pane is the sandboxed
// preview plus the version strip. Panes keep minWidths summing under the 560
// widest-pane budget (240 sidebar + 560 = the 840 window floor).
struct DesignStudioView: View {
    @ObservedObject private var store = DesignProjectStore.shared
    @ObservedObject private var engine = DesignStudioEngine.shared
    @ObservedObject private var brandRegistry = CreativeBrandRegistry.shared

    @State private var selection: UUID?
    @State private var brief: String = ""
    @State private var route: ExecutionRoute = .api
    @State private var draftMode = false
    @State private var pickedBrandSlug: String?
    @State private var previewRevision = 0
    @State private var showVersions = false
    @State private var ctxToast: String?
    // Delete + rename flows are confirmed (delete) or edited (rename) through a
    // dialog/alert bound to these, so a context-menu tap never mutates on disk.
    @State private var pendingDeleteProject: DesignProject?
    @State private var renameProject: DesignProject?
    @State private var renameText: String = ""
    // engine.lastError is private(set), so the banner tracks the last message the
    // user dismissed and hides while it matches. Cleared when a fresh run starts
    // so an identical error on the next run still surfaces.
    @State private var dismissedErrorMessage: String?
    @FocusState private var briefFocused: Bool

    private var selectedProject: DesignProject? {
        guard let selection else { return nil }
        return store.projects.first { $0.id == selection }
    }

    private var currentConfig: DesignRunConfig {
        DesignRunConfig(
            route: route,
            modelId: nil,
            brandSlug: pickedBrandSlug,
            draftMode: draftMode,
            temperature: nil
        )
    }

    // MARK: - Run-state helpers

    private var briefIsEmpty: Bool {
        brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isRunning(_ id: UUID) -> Bool {
        engine.isGenerating && engine.runningProjectId == id
    }

    private var selectionIsRunning: Bool {
        guard let selection else { return false }
        return isRunning(selection)
    }

    private var runningProjectTitle: String? {
        guard let rid = engine.runningProjectId else { return nil }
        return store.project(id: rid)?.title
    }

    private var activeError: String? {
        guard let err = engine.lastError, err != dismissedErrorMessage else { return nil }
        return err
    }

    private var activeDesignSystemCaption: String {
        if let label = engine.activeDesignSystemLabel(brandSlug: pickedBrandSlug) {
            return "system: \(label)"
        }
        return "no design system"
    }

    // Resolve a stored slug to a human brand name (curated or registry) so no raw
    // slug ever renders. Falls back to the deterministic CreativeBrand mapping
    // when the empire registry has not loaded yet.
    private func brandDisplayName(forSlug slug: String) -> String {
        if let match = brandRegistry.brands.first(where: { $0.slug == slug }) {
            return match.displayName
        }
        return CreativeBrand(slug: slug).displayName
    }

    var body: some View {
        HSplitView {
            leftRail
                .frame(minWidth: 240, idealWidth: 320, maxHeight: .infinity)
            rightPane
                .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GruxTheme.base)
        .foregroundStyle(GruxTheme.textPrimary)
        .overlay(alignment: .top) { ctxToastOverlay }
        .onAppear {
            // A chat handoff (design_open_project) sets pendingOpenProjectId
            // before the view mounts; honor it and clear it BEFORE the
            // first-project fallback so the handoff target wins.
            if let pending = engine.pendingOpenProjectId {
                selection = pending
                engine.pendingOpenProjectId = nil
            } else if selection == nil {
                selection = store.list().first?.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gruxDesignArtifactsUpdated)) { _ in
            previewRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .gruxDesignRunStateChanged)) { _ in
            previewRevision += 1
        }
        .onChange(of: engine.pendingOpenProjectId) { _, newValue in
            // Already-mounted handoff: select and clear so a repeat command
            // (same project id) re-fires instead of being swallowed.
            if let newValue {
                selection = newValue
                engine.pendingOpenProjectId = nil
            }
        }
        .onChange(of: engine.isGenerating) { _, generating in
            if generating { dismissedErrorMessage = nil }
        }
        .confirmationDialog(
            "Delete this design project?",
            isPresented: Binding(
                get: { pendingDeleteProject != nil },
                set: { if !$0 { pendingDeleteProject = nil } }
            ),
            presenting: pendingDeleteProject
        ) { proj in
            Button("Delete \(proj.title)", role: .destructive) { performDelete(proj) }
            Button("Cancel", role: .cancel) { pendingDeleteProject = nil }
        } message: { proj in
            Text("\(proj.title) and its version history will be permanently removed. This cannot be undone.")
        }
        .alert(
            "Rename project",
            isPresented: Binding(
                get: { renameProject != nil },
                set: { if !$0 { renameProject = nil } }
            ),
            presenting: renameProject
        ) { proj in
            TextField("Title", text: $renameText)
            Button("Save") {
                store.rename(id: proj.id, title: renameText)
                renameProject = nil
            }
            Button("Cancel", role: .cancel) { renameProject = nil }
        } message: { _ in
            Text("Give this design project a new name.")
        }
    }

    // MARK: - Left rail

    private var leftRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            GruxToolbar("Design Studio", subtitle: "Chat plus live preview") {
                Spacer()
                GruxToolbarButton(title: "New", systemImage: "plus", prominent: false) {
                    newProject()
                }
            }
            Divider().overlay(Color.white.opacity(0.06))

            projectList
                .frame(maxHeight: 200)

            Divider().overlay(Color.white.opacity(0.06))

            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.white.opacity(0.06))

            if let errText = activeError {
                errorBanner(errText)
                    .padding(.horizontal, GruxSpacing.m)
                    .padding(.top, GruxSpacing.s)
            }

            composer
                .padding(GruxSpacing.m)
        }
        .background(Color.black.opacity(0.18))
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: GruxSpacing.xs) {
                if store.projects.isEmpty {
                    Text("No projects yet. Click New or write a brief below.")
                        .font(GruxType.caption)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(GruxSpacing.m)
                } else {
                    ForEach(store.list()) { proj in
                        projectRow(proj)
                    }
                }
            }
            .padding(.horizontal, GruxSpacing.s)
            .padding(.vertical, GruxSpacing.s)
        }
    }

    private func projectRow(_ proj: DesignProject) -> some View {
        let isSelected = proj.id == selection
        return HStack(spacing: GruxSpacing.s) {
            Image(systemName: proj.kind.iconName)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? GruxTheme.accentPrimary : GruxTheme.textTertiary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(proj.title)
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .lineLimit(1)
                if let brand = proj.brandSlug, !brand.isEmpty {
                    Text(brandDisplayName(forSlug: brand))
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if proj.starred {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(GruxTheme.warnAmber)
            }
        }
        .padding(.horizontal, GruxSpacing.s)
        .padding(.vertical, GruxSpacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? GruxTheme.accentPrimary.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = proj.id }
        .gruxHoverable(cornerRadius: 8)
        .contextMenu {
            Button(proj.starred ? "Unstar" : "Star") { store.toggleStar(id: proj.id) }
            Button("Rename") {
                renameText = proj.title
                renameProject = proj
            }
            Button("Delete", role: .destructive) { pendingDeleteProject = proj }
                .disabled(isRunning(proj.id))
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: GruxSpacing.s) {
                    if let id = selection {
                        // Reading previewRevision here keeps the transcript in
                        // sync as the run appends turns and writes files.
                        let _ = previewRevision
                        let messages = store.transcript(id: id)
                        if messages.isEmpty {
                            Text("Write a brief and Generate to start building.")
                                .font(GruxType.caption)
                                .foregroundStyle(GruxTheme.textTertiary)
                                .padding(GruxSpacing.m)
                        } else {
                            ForEach(messages) { msg in
                                messageBubble(msg)
                            }
                            Color.clear.frame(height: 1).id("transcript-bottom")
                        }
                        if engine.isGenerating, engine.runningProjectId == id, let status = engine.liveStatus {
                            HStack(spacing: GruxSpacing.xs) {
                                ProgressView().controlSize(.small)
                                Text(status)
                                    .font(GruxType.caption)
                                    .foregroundStyle(GruxTheme.textSecondary)
                            }
                            .padding(.horizontal, GruxSpacing.s)
                        }
                    } else {
                        Text("Select or create a project.")
                            .font(GruxType.caption)
                            .foregroundStyle(GruxTheme.textTertiary)
                            .padding(GruxSpacing.m)
                    }
                }
                .padding(.horizontal, GruxSpacing.s)
                .padding(.vertical, GruxSpacing.s)
            }
            .onChange(of: previewRevision) { _, _ in
                withAnimation { proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            }
        }
    }

    private func messageBubble(_ msg: DesignChatMessage) -> some View {
        let isUser = msg.role == .user
        return HStack {
            if isUser { Spacer(minLength: 24) }
            Text(msg.text)
                .font(GruxType.caption)
                .foregroundStyle(isUser ? Color.white : GruxTheme.textSecondary)
                .padding(.horizontal, GruxSpacing.s)
                .padding(.vertical, GruxSpacing.xs + 2)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isUser ? AnyShapeStyle(GruxTheme.iridescent) : AnyShapeStyle(Color.white.opacity(0.05)))
                )
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 24) }
        }
    }

    // Amber/red error banner shown directly above the composer whenever the
    // engine reports a failure the user has not dismissed. The close affordance
    // is an icon, not a chunky button, per the house close-icon rule.
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: GruxSpacing.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(GruxTheme.destructiveRose)
                .padding(.top, 1)
            Text(message)
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                dismissedErrorMessage = engine.lastError
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .gruxHoverable(cornerRadius: 999)
            .help("Dismiss")
        }
        .padding(.horizontal, GruxSpacing.s)
        .padding(.vertical, GruxSpacing.xs + 2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(GruxTheme.destructiveRose.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(GruxTheme.destructiveRose.opacity(0.35), lineWidth: 1)
        )
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            ZStack(alignment: .topLeading) {
                if brief.isEmpty {
                    Text("Describe what to build or change ...")
                        .font(GruxType.body)
                        .foregroundStyle(GruxTheme.textTertiary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $brief)
                    .font(GruxType.body)
                    .foregroundStyle(GruxTheme.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 56, maxHeight: 110)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .focused($briefFocused)
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(briefFocused ? GruxTheme.accentPrimary.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
            )

            runControls
        }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            HStack(alignment: .top, spacing: GruxSpacing.s) {
                VStack(alignment: .leading, spacing: 2) {
                    brandMenu
                    Text(activeDesignSystemCaption)
                        .font(GruxTheme.Font.microCaps)
                        .foregroundStyle(GruxTheme.textTertiary)
                }
                routeMenu
                Spacer(minLength: 0)
            }

            HStack(spacing: GruxSpacing.s) {
                Toggle(isOn: $draftMode) {
                    Text("Draft").font(GruxType.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(GruxTheme.accentPrimary)
                .help("Faster, cheaper first pass on a small model. The estimate reflects it.")

                Spacer()

                runActionButton
            }

            estimateLine
            if route == .subscriptionCLI {
                Text("Runs via Claude Code on your subscription, $0 metered.")
                    .font(GruxTheme.Font.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
        }
    }

    // Generate when idle, Stop when this project owns the run, disabled
    // "Building another project" when a different project is mid-run.
    @ViewBuilder
    private var runActionButton: some View {
        if selectionIsRunning {
            GruxChip(title: "Stop", systemImage: "stop.fill", style: .destructive) {
                engine.cancelRun()
            }
            .help("Stop this run")
        } else if engine.isGenerating {
            GruxToolbarButton(
                title: "Building another project",
                systemImage: "hourglass",
                prominent: false,
                helpText: runningProjectTitle.map { "Building \($0)" } ?? "Another project is building"
            ) { }
            .disabled(true)
            .opacity(0.5)
        } else {
            GruxToolbarButton(
                title: "Generate",
                systemImage: "sparkles",
                prominent: true,
                helpText: briefIsEmpty ? "Write a brief first." : "Generate"
            ) {
                runGenerate()
            }
            .disabled(briefIsEmpty)
            .opacity(briefIsEmpty ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private var estimateLine: some View {
        if let estimate = engine.estimate(brief: brief, config: currentConfig, projectId: selection) {
            Text(Self.estimateText(estimate))
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
        }
    }

    private var brandMenu: some View {
        Menu {
            Button("No brand (generic, no design system)") { pickedBrandSlug = nil }
            ForEach(brandRegistry.brands, id: \.slug) { brand in
                if brand.slug != "untagged" {
                    Button(brand.displayName) { pickedBrandSlug = brand.slug }
                }
            }
        } label: {
            controlChipLabel(icon: "tag.fill", text: pickedBrandSlug.map { brandDisplayName(forSlug: $0) } ?? "No brand")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var routeMenu: some View {
        Menu {
            Section("Run with") {
                ForEach(ExecutionRoute.allCases, id: \.self) { r in
                    Button(r.displayName) { route = r }
                }
            }
        } label: {
            controlChipLabel(icon: "bolt.fill", text: route.displayName)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("How this run executes and is billed.")
    }

    private func controlChipLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            Text(text).font(GruxType.caption).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
        }
        .foregroundStyle(GruxTheme.textSecondary)
        .padding(.horizontal, GruxSpacing.s)
        .padding(.vertical, GruxSpacing.xs + 1)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.8))
    }

    // MARK: - Right pane

    private var rightPane: some View {
        VStack(spacing: 0) {
            GruxToolbar(selectedProject?.title ?? "Design Studio",
                        subtitle: rightPaneSubtitle,
                        style: .display) {
                Spacer()
                if selectionIsRunning, let status = engine.liveStatus {
                    buildingBadge(status)
                }
                if selectedProject != nil {
                    GruxToolbarButton(title: showVersions ? "Hide history" : "History",
                                      systemImage: "clock.arrow.circlepath") {
                        showVersions.toggle()
                    }
                }
            }
            Divider().overlay(Color.white.opacity(0.06))

            previewArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showVersions, let id = selection {
                Divider().overlay(Color.white.opacity(0.06))
                versionStrip(id: id)
            }
        }
    }

    private func buildingBadge(_ status: String) -> some View {
        HStack(spacing: GruxSpacing.xs) {
            ProgressView().controlSize(.small)
            Text(Self.buildingLabel(status))
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textSecondary)
        }
        .padding(.horizontal, GruxSpacing.s)
        .padding(.vertical, GruxSpacing.xs)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.8))
    }

    private var rightPaneSubtitle: String? {
        guard let proj = selectedProject else { return nil }
        var parts = [proj.kind.displayName]
        if let brand = proj.brandSlug, !brand.isEmpty { parts.append(brandDisplayName(forSlug: brand)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var previewArea: some View {
        if let id = selection,
           let indexURL = store.siteIndexURL(id: id),
           let siteRoot = store.siteRootURL(id: id) {
            DesignPreviewView(indexURL: indexURL, siteRoot: siteRoot, revision: previewRevision, engine: engine)
                .id(id)
        } else if selection != nil {
            GruxEmptyState(
                icon: "paintbrush.pointed",
                line: "Nothing to preview yet",
                detail: "Write a brief and Generate to build the first version.",
                voiceHint: "Grux, build a landing page for ..."
            )
        } else {
            GruxEmptyState(
                icon: "square.grid.2x2",
                line: "Pick or create a project",
                detail: "Design Studio builds self contained web prototypes you can preview live.",
                ctaTitle: "New project",
                ctaAction: { newProject() }
            )
        }
    }

    private func versionStrip(id: UUID) -> some View {
        let versions = store.versions(id: id)
        return VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            Text("VERSION HISTORY")
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
                .padding(.horizontal, GruxSpacing.m)
                .padding(.top, GruxSpacing.s)
            if versions.isEmpty {
                Text("Versions appear after your second generation. Each run saves the previous site here first.")
                    .font(GruxType.caption)
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(.horizontal, GruxSpacing.m)
                    .padding(.bottom, GruxSpacing.s)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: GruxSpacing.s) {
                        ForEach(versions.reversed()) { version in
                            versionCard(id: id, version: version)
                        }
                    }
                    .padding(.horizontal, GruxSpacing.m)
                    .padding(.bottom, GruxSpacing.s)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.18))
    }

    private func versionCard(id: UUID, version: DesignVersion) -> some View {
        VStack(alignment: .leading, spacing: GruxSpacing.xs) {
            Text(Self.versionTitle(version))
                .font(GruxType.caption)
                .foregroundStyle(GruxTheme.textPrimary)
            Text(Self.byteText(version.byteCount))
                .font(GruxTheme.Font.microCaps)
                .foregroundStyle(GruxTheme.textTertiary)
            GruxChip(title: "Restore", systemImage: "arrow.uturn.backward", style: .secondary) {
                if store.restore(id: id, versionId: version.id) {
                    previewRevision += 1
                    toast("Restored \(Self.versionTitle(version)). The previous version was saved to history.")
                } else {
                    toast("Restore failed")
                }
            }
            .disabled(isRunning(id))
            .opacity(isRunning(id) ? 0.5 : 1)
        }
        .padding(GruxSpacing.s)
        .frame(width: 150, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Toast

    @ViewBuilder
    private var ctxToastOverlay: some View {
        if let msg = ctxToast {
            Text(msg)
                .font(.caption.bold())
                .padding(.horizontal, GruxSpacing.m).padding(.vertical, GruxSpacing.s)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [.purple.opacity(0.95), .indigo.opacity(0.95)],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                )
                .foregroundStyle(.white)
                .shadow(color: .purple.opacity(0.4), radius: 8, y: 2)
                .padding(.top, GruxSpacing.m)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    private func newProject() {
        let proj = store.create(title: "Untitled design", brandSlug: pickedBrandSlug)
        selection = proj.id
        briefFocused = true
    }

    private func runGenerate() {
        let text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !engine.isGenerating else { return }
        var targetId = selection
        if targetId == nil {
            let proj = store.create(title: Self.titleFromBrief(text), brandSlug: pickedBrandSlug)
            selection = proj.id
            targetId = proj.id
        }
        guard let id = targetId else { return }
        brief = ""
        let config = currentConfig
        toast("Generating ...")
        Task { await engine.generate(projectId: id, brief: text, config: config) }
    }

    private func performDelete(_ proj: DesignProject) {
        store.delete(id: proj.id)
        if selection == proj.id { selection = store.list().first?.id }
        toast("Deleted \(proj.title)")
        pendingDeleteProject = nil
    }

    private func toast(_ message: String) {
        withAnimation { ctxToast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { ctxToast = nil }
        }
    }

    // MARK: - Formatting helpers

    private static func titleFromBrief(_ brief: String) -> String {
        let words = brief.split(whereSeparator: { $0.isWhitespace }).prefix(6)
        let joined = words.joined(separator: " ")
        return String(joined.prefix(60))
    }

    // The estimator's label already carries the amount plus the word "estimated"
    // (Foundry labeling rule). Render it once, name its route, and list any
    // cheaper alternatives inline. Never re-add "estimated" or a second figure.
    private static func estimateText(_ estimate: DesignRunEstimate) -> String {
        var out = "\(estimate.primary.label), \(estimate.primary.route.displayName)"
        if !estimate.alternatives.isEmpty {
            let alts = estimate.alternatives.map { $0.label }.joined(separator: " | ")
            out += " | \(alts)"
        }
        return out
    }

    // A version card names why the snapshot exists plus the time it was saved.
    // "generation" snapshots the tree before a run; "restore" before a restore.
    private static func versionTitle(_ version: DesignVersion) -> String {
        let origin: String
        switch version.label.lowercased() {
        case "generation": origin = "Before run"
        case "restore": origin = "Before restore"
        default: origin = version.label.capitalized
        }
        return "\(origin), \(timeStamp(version.savedAt))"
    }

    private static func timeStamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        df.timeZone = .current
        return df.string(from: date)
    }

    // Compact building pill for the preview toolbar: append the live status only
    // when it is short enough to sit on one line, otherwise just "Building".
    private static func buildingLabel(_ status: String) -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed.count <= 18 {
            return "Building, \(trimmed)"
        }
        return "Building"
    }

    private static func byteText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}
