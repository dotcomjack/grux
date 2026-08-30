import SwiftUI
import AppKit
import PDFKit

// MARK: - DocumentEditorView
//
// Editor sheet for a single library document. Editable kinds (markdown /
// plain text) get a TextEditor + live MarkdownText preview side by side,
// a version-history drawer with restore, and an AI-assist popover that sends
// the body + an instruction through the edit seam. PDFs get a PDFKit page
// view plus the AcroForm field inspector. Autosave is debounced 600ms so
// every keystroke doesn't hit disk; each flush snapshots the prior version.
struct DocumentEditorView: View {
    let documentId: UUID

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = DocumentStore.shared

    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var dirty = false
    @State private var showPreview = true
    @State private var showVersions = false
    @State private var versions: [DocumentVersion] = []

    // AI assist
    @State private var showAssist = false
    @State private var assistInstruction = ""
    @State private var assistRunning = false
    @State private var assistError: String? = nil

    // Debounced autosave task, re-created on every keystroke.
    @State private var saveTask: Task<Void, Never>? = nil

    private var document: GruxDocument? {
        store.document(id: documentId)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().opacity(0.3)
            if let doc = document {
                if doc.kind.isEditable {
                    editableBody
                } else if doc.kind == .pdf {
                    PDFDetailPane(documentId: doc.id)
                } else {
                    readOnlyBody
                }
            } else {
                GruxEmptyState(
                    icon: "doc",
                    line: "Document not found"
                )
            }
        }
        .background(GruxTheme.base)
        .onAppear(perform: loadDocument)
        .onDisappear {
            saveTask?.cancel()
            flushSaveNow()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: GruxSpacing.s) {
            Image(systemName: document?.kind.iconName ?? "doc")
                .font(.system(size: 12))
                .foregroundStyle(GruxTheme.accentPrimaryLight)

            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
                .frame(maxWidth: 320)
                .onSubmit { commitTitle() }

            if dirty {
                Text("editing")
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.0)
                    .foregroundStyle(GruxTheme.textTertiary)
            }

            Spacer()

            if document?.kind.isEditable == true {
                assistButton

                Button {
                    showPreview.toggle()
                } label: {
                    Image(systemName: showPreview ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(showPreview ? GruxTheme.accentPrimaryLight : GruxTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help(showPreview ? "Hide preview" : "Show live preview")

                Button {
                    refreshVersions()
                    showVersions.toggle()
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(showVersions ? GruxTheme.accentPrimaryLight : GruxTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Version history")
            }

            if let doc = document {
                Button {
                    _ = store.toggleStar(id: doc.id)
                } label: {
                    Image(systemName: doc.starred ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(doc.starred ? GruxTheme.warnAmber : GruxTheme.textTertiary)
                }
                .buttonStyle(.plain)
            }

            // Close affordance: icon only, no chrome (house close-icon rule).
            Button {
                flushSaveNow()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(GruxTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, GruxSpacing.m)
        .padding(.vertical, GruxSpacing.s)
    }

    private var assistButton: some View {
        Button {
            assistError = nil
            showAssist.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10, weight: .bold))
                Text("AI assist")
                    .font(GruxTheme.Font.microCaps)
                    .kerning(1.0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, GruxSpacing.m - 2).padding(.vertical, GruxSpacing.xs + 1)
            .background(Capsule().fill(GruxTheme.iridescent))
            .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showAssist, arrowEdge: .bottom) {
            assistPopover
        }
    }

    private var assistPopover: some View {
        VStack(alignment: .leading, spacing: GruxSpacing.s) {
            Text("Tell Grux how to edit this document")
                .font(GruxTheme.Font.caption)
                .foregroundStyle(GruxTheme.textSecondary)
            // 280 twice below, fixed on purpose. This is a popover: it hangs in
            // its own window sized to this content, not inside the resizable
            // pane, so a fixed width has nothing to overflow. The error line
            // matches the field so the popover does not jump width the moment
            // an error appears. Change one number and you change both.
            TextField("e.g. tighten the intro, fix typos", text: $assistInstruction)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 280)
                .onSubmit { runAssist() }
            if let assistError {
                Text(assistError)
                    .font(.system(size: 10))
                    .foregroundStyle(GruxTheme.destructiveRose)
                    .frame(width: 280, alignment: .leading)
            }
            HStack {
                Spacer()
                if assistRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run") { runAssist() }
                        .font(.system(size: 12, weight: .semibold))
                        .disabled(assistInstruction.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(GruxSpacing.m)
    }

    // MARK: - Editable body

    private var editableBody: some View {
        HSplitView {
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(GruxTheme.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.25))
                .frame(minWidth: 280)
                .onChange(of: text) { _, _ in
                    guard loaded else { return }
                    dirty = true
                    scheduleSave()
                }

            if showPreview {
                ScrollView {
                    MarkdownText(content: text)
                        .markdownFont(.system(size: 13))
                        .padding(GruxSpacing.l)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 280)
                .background(GruxTheme.base)
            }

            if showVersions {
                versionDrawer
                    .frame(minWidth: 200, maxWidth: 260)
            }
        }
    }

    private var readOnlyBody: some View {
        ScrollView {
            Text(store.content(id: documentId) ?? "(no extractable text)")
                .font(.system(size: 12))
                .foregroundStyle(GruxTheme.textSecondary)
                .textSelection(.enabled)
                .padding(GruxSpacing.l)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Version drawer

    private var versionDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                GruxSectionLabel("HISTORY")
                Spacer()
                Text("\(versions.count)/\(DocumentStore.maxVersions)")
                    .font(GruxType.microCaps)
                    .foregroundStyle(GruxTheme.textTertiary)
            }
            .padding(.horizontal, GruxSpacing.m)
            .padding(.vertical, GruxSpacing.s)
            Divider().opacity(0.3)
            if versions.isEmpty {
                Text("No versions yet. Each save snapshots the previous state.")
                    .font(.system(size: 11))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(GruxSpacing.m)
                Spacer()
            } else {
                List(versions.reversed()) { version in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(version.label)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(GruxTheme.textPrimary)
                            Spacer()
                            DestructiveButton(
                                "Restore",
                                question: "Replace the document with this version?",
                                detail: "The current text is overwritten by the version you "
                                    + "selected. The current text is saved as a new version first, "
                                    + "so you can restore back to it.",
                                confirmLabel: "Restore this version"
                            ) {
                                restoreVersion(version)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .buttonStyle(.plain)
                            .foregroundStyle(GruxTheme.accentPrimaryLight)
                        }
                        Text(Self.versionDateFormatter.string(from: version.savedAt))
                            .font(.system(size: 10))
                            .foregroundStyle(GruxTheme.textTertiary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.black.opacity(0.20))
    }

    // MARK: - Load / save

    private func loadDocument() {
        guard let doc = document else { return }
        title = doc.title
        if doc.kind.isEditable {
            text = store.content(id: doc.id) ?? ""
        }
        refreshVersions()
        // Defer the loaded flag a tick so the initial text assignment doesn't
        // register as a dirty edit.
        DispatchQueue.main.async { loaded = true }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            flushSaveNow()
        }
    }

    private func flushSaveNow() {
        guard loaded, dirty, let doc = document, doc.kind.isEditable else { return }
        _ = store.update(id: doc.id, content: text)
        dirty = false
        refreshVersions()
    }

    private func commitTitle() {
        guard let doc = document else { return }
        _ = store.rename(id: doc.id, title: title)
    }

    private func refreshVersions() {
        versions = store.versions(id: documentId)
    }

    private func restoreVersion(_ version: DocumentVersion) {
        // Flush the in-progress edit first so it's snapshotted, then restore.
        flushSaveNow()
        guard let restored = store.restore(id: documentId, versionId: version.id) else { return }
        _ = restored
        text = store.content(id: documentId) ?? text
        dirty = false
        refreshVersions()
    }

    // MARK: - AI assist

    private func runAssist() {
        let instruction = assistInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !assistRunning else { return }
        flushSaveNow()
        assistRunning = true
        assistError = nil
        let body = text
        Task { @MainActor in
            defer { assistRunning = false }
            do {
                let rewritten = try await DocumentAIAssist.rewrite(content: body, instruction: instruction)
                guard !rewritten.isEmpty else {
                    assistError = "Model returned an empty result"
                    return
                }
                _ = store.update(id: documentId, content: rewritten, versionLabel: "ai assist")
                text = rewritten
                dirty = false
                refreshVersions()
                assistInstruction = ""
                showAssist = false
            } catch {
                assistError = error.localizedDescription
            }
        }
    }

    private static let versionDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "MMM d, h:mm:ss a"
        // Whatever timezone this Mac is set to. Version stamps are read by the
        // person sitting at the machine, so pinning one zone was wrong.
        df.timeZone = .current
        return df
    }()
}

// MARK: - DocumentAIAssist
//
// The edit_document seam. The editor's AI-assist button and any future
// callers route through here: one Claude completion that rewrites the whole
// body per the instruction. Uses the same key + client plumbing as
// WebResearch (ClaudeClient + AppState.anthropicKey), Sonnet for quality.
enum DocumentAIAssist {

    /// Trims the reply and enforces the house no-dash rule on it.
    ///
    /// The system prompt above already tells the model never to emit an em or
    /// en dash, and that is not enough on its own: DashSanitizer exists because
    /// "the LLM drafters are also told to avoid them in their system prompts,
    /// but models slip". Every other generated surface learned that the hard
    /// way; this one was still relying on the instruction alone.
    ///
    /// Cleaned at CREATION rather than at the render boundary, which is the
    /// opposite of the call made for Feature Review and Research, and the
    /// difference is worth stating. Those render prose that is merely stored.
    /// This rewrite is written straight back into the USER'S DOCUMENT, so
    /// scrubbing at render would show them clean text while the saved file kept
    /// the dash. Model output that becomes user data has to be clean before it
    /// persists.
    ///
    /// stripDashesOnly, not clean(): a document is markdown, and clean()'s
    /// whitespace tidy would collapse indentation inside fenced code blocks and
    /// nested lists. Split out as a pure function so it is testable without a
    /// network call.
    nonisolated static func normalizeRewrite(_ raw: String) -> String {
        DashSanitizer.stripDashesOnly(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @MainActor
    static func rewrite(content: String, instruction: String) async throws -> String {
        // ROUTED, AND THE ROUTE PICKS THE MODEL. Document assist built its own
        // ClaudeClient and gated on AppState.anthropicKey, so a local-only or
        // custom-endpoint user got ClaudeError.missingKey on every rewrite while
        // the Chat tab worked.
        //
        // The first cut of that fix pinned "claude-sonnet-4-6" as the override
        // to hold the quality tier, and resolvedRouting returned that id AFTER
        // the backend had resolved, so an offline install POSTed an Anthropic
        // model id to Ollama and the user got a raw 404 in the editor on a
        // rewrite that worked the day before: missingKey traded for
        // model-not-found. A tier is a preference, a backend is a fact, so the
        // routed model wins. On a local route that is the model the user
        // actually has; on the Anthropic route it is config.model, the model
        // they chose and pay for.
        //
        // Resolved ONCE, before the prompt.
        // THE TIER IS RESTORED, and it is safe now for a reason that did not
        // exist when it was dropped. resolvedRouting refuses an Anthropic model
        // id on a route that cannot serve it, so this override holds on the
        // Anthropic route and falls back to the routed model on a local or
        // custom one. Dropping it entirely also fixed the 404, and it fixed it
        // by quietly downgrading a paying user from Sonnet to Haiku on a
        // feature nobody had asked to change. A preference honoured only where
        // it can be honoured costs nothing and keeps the behaviour that shipped.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: "claude-sonnet-4-6")
        guard !routing.apiKey.isEmpty else {
            throw ClaudeError.missingKey
        }
        let system = """
        You are Grux's document editor. Rewrite the document below according to the instruction.
        Rules:
        - Return ONLY the full rewritten document body. No preamble, no commentary, no code fences around the whole document.
        - Preserve the document's format (markdown stays markdown).
        - Apply the instruction surgically: keep everything the instruction doesn't ask you to change.
        - Never use em dashes or en dashes anywhere in the output.
        """
        let user = """
        INSTRUCTION: \(instruction)

        DOCUMENT:
        \(content)
        """
        let reply = try await routing.backend.complete(
            apiKey: routing.apiKey,
            model: routing.modelId,
            system: system,
            messages: [ClaudeMessage(role: "user", content: user)],
            maxTokens: 8192,
            temperature: 0.3,
            spanName: "claude.document_assist",
            feature: "documents"
        )
        let cleaned = Self.normalizeRewrite(reply)

        // POST-vet the rewrite against the real catalog before it can be
        // written back to the document. A rewrite can drift a product price,
        // size, or SKU off-catalog. An ungrounded product fact is true
        // confusion, so refuse to return the draft rather than let it land in
        // the doc. The instruction is the brief (brand detection); the body is
        // what is audited. Clean rewrites pass through untouched.
        let verdict = GroundingGate.vet(draft: cleaned, brief: instruction)
        guard verdict.surfaceable else {
            throw DocumentAssistError.ungrounded(verdict.refusalLine)
        }
        return cleaned
    }
}

enum DocumentAssistError: LocalizedError {
    case ungrounded(String)
    var errorDescription: String? {
        switch self {
        case .ungrounded(let line): return line
        }
    }
}

// MARK: - PDFDetailPane
//
// Read-only PDF surface inside the editor sheet: PDFKit page view on the
// left, AcroForm field inspector + fill controls on the right.
private struct PDFDetailPane: View {
    let documentId: UUID

    @State private var fields: [PDFFormFieldInfo] = []
    @State private var fieldValues: [String: String] = [:]
    @State private var fillResult: String? = nil

    private var pdfURL: URL? {
        DocumentStore.shared.contentURL(id: documentId)
    }

    var body: some View {
        HSplitView {
            if let url = pdfURL {
                PDFKitRepresentable(url: url)
                    .frame(minWidth: 320)
            } else {
                Text("PDF file missing")
                    .font(GruxTheme.Font.body)
                    .foregroundStyle(GruxTheme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            formPane
                .frame(minWidth: 240, maxWidth: 320)
        }
        .onAppear(perform: loadFields)
    }

    private var formPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            GruxSectionLabel("FORM FIELDS")
                .padding(.horizontal, GruxSpacing.m)
                .padding(.vertical, GruxSpacing.s)
            Divider().opacity(0.3)
            if fields.isEmpty {
                Text("No fillable form fields in this PDF.")
                    .font(.system(size: 11))
                    .foregroundStyle(GruxTheme.textTertiary)
                    .padding(GruxSpacing.m)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: GruxSpacing.m - 2) {
                        ForEach(fields, id: \.name) { field in
                            fieldRow(field)
                        }
                    }
                    .padding(GruxSpacing.m)
                }
                Divider().opacity(0.3)
                HStack {
                    if let fillResult {
                        Text(fillResult)
                            .font(.system(size: 10))
                            .foregroundStyle(GruxTheme.successMint)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Save filled copy") { saveFilledCopy() }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .padding(.horizontal, GruxSpacing.m - 2).padding(.vertical, GruxSpacing.xs + 1)
                        .background(Capsule().fill(GruxTheme.iridescent))
                }
                .padding(GruxSpacing.m - 2)
            }
        }
        .background(Color.black.opacity(0.20))
    }

    @ViewBuilder
    private func fieldRow(_ field: PDFFormFieldInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(field.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(GruxTheme.textPrimary)
            if field.type == "checkbox" {
                Toggle(isOn: Binding(
                    get: { (fieldValues[field.name] ?? field.value) == "true" },
                    set: { fieldValues[field.name] = $0 ? "true" : "false" }
                )) {
                    Text("Checked")
                        .font(.system(size: 11))
                        .foregroundStyle(GruxTheme.textSecondary)
                }
                .toggleStyle(.checkbox)
            } else {
                TextField("", text: Binding(
                    get: { fieldValues[field.name] ?? field.value },
                    set: { fieldValues[field.name] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
            }
        }
    }

    private func loadFields() {
        guard let url = pdfURL else { return }
        fields = PDFSupport.listFormFields(url: url)
    }

    private func saveFilledCopy() {
        guard let url = pdfURL else { return }
        let panel = NSSavePanel()
        panel.title = "Save filled PDF"
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + "-filled.pdf"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var merged: [String: String] = [:]
        for field in fields {
            merged[field.name] = fieldValues[field.name] ?? field.value
        }
        do {
            let filled = try PDFSupport.fillForm(at: url, values: merged, outputURL: dest)
            fillResult = "Filled \(filled.count) field\(filled.count == 1 ? "" : "s")"
        } catch {
            fillResult = "Error: \(error.localizedDescription)"
        }
    }
}

// Minimal PDFKit host, read-only continuous scroll with auto-scaling.
private struct PDFKitRepresentable: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = NSColor.black.withAlphaComponent(0.85)
        view.document = PDFDocument(url: url)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
