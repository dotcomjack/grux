import Foundation

// MARK: - Seams
//
// The engine binds to these protocols with nil hooks by default. Sibling
// workstreams (design systems, iteration/critique, pricing, the agent CLI
// bridge) bind real implementations at integration time via the settable
// static hooks on DesignStudioEngine. Until then generation still runs; the
// design-system block is empty, no critique is appended, and the cost line is
// hidden.

// Supplies the active brand's design-system markdown, injected into the
// generation system prompt after the cached instruction block.
protocol DesignSystemProviding {
    func activeSystemMarkdown(brandSlug: String?) -> String?
    // The active (or slug-fallback) system's slug, for the view's design-system
    // chip. nil when no system resolves for the brand.
    func activeSystemLabel(brandSlug: String?) -> String?
    // Character count of the active system markdown, resolved through the store's
    // cache so the per-keystroke estimate never re-reads the DESIGN.md from disk.
    func activeSystemCharCount(brandSlug: String?) -> Int
    // Markdown for a per-project pinned system file, or nil when the pin does not
    // resolve (the engine then falls back to the brand's active system).
    func systemMarkdown(forPinnedFile file: String) -> String?
}

// Post-generation critique (contrast, spacing, brand fit). Returns a short
// verdict summary appended to the assistant transcript message, or nil.
protocol DesignCritiquing {
    func critique(html: String, brandSlug: String?) async -> String?
}

// Pre-run cost estimate for the picker. Every rendering of the result carries
// the word "estimated" per the Foundry labeling rule.
protocol DesignRunEstimating {
    func estimate(for context: DesignEstimateContext) -> DesignRunEstimate?
}

// The subscription-CLI execution bridge. Bound by the agent workstream; until
// then the subscriptionCLI route throws a clear notImplemented message.
protocol DesignAgentDelegating {
    func runGeneration(projectId: UUID, brief: String, config: DesignRunConfig) async throws
    // Cancel the in-flight subscription run, if any. A no-op when nothing runs.
    func cancelActiveRun() async
}

// What the estimator needs to price a pending run. Pure value type.
struct DesignEstimateContext: Sendable {
    let brief: String
    let route: ExecutionRoute
    let modelId: String?
    let brandSlug: String?
    let approxInputTokens: Int
    let maxOutputTokens: Int
}

enum DesignStudioError: Error, LocalizedError {
    case notImplemented(String)
    case noProject
    case missingKey

    var errorDescription: String? {
        switch self {
        case .notImplemented(let s): return s
        case .noProject: return "That design project no longer exists."
        case .missingKey: return "No API key is set. Add one in Settings to run on the API route."
        }
    }
}

// MARK: - DesignStudioEngine
//
// Owns the Design Studio generation run. It does NOT touch ChatService; it
// copies the shape of ChatService.send (resolve routing once on the main actor,
// build its own system prompt, stream via backend.streamCompleteWithTools,
// switch on ClaudeStreamEvent) but feeds every .textDelta into a
// DesignArtifactParser instead of a chat bubble, and writes each completed
// artifact file through DesignProjectStore. Generation runs use maxTokens 8000.
@MainActor
final class DesignStudioEngine: ObservableObject {
    static let shared = DesignStudioEngine()

    // Integration seams (bound by sibling workstreams). MainActor-isolated.
    static var designSystemProvider: DesignSystemProviding?
    static var critic: DesignCritiquing?
    static var estimator: DesignRunEstimating?
    static var agentDelegate: DesignAgentDelegating?

    // Max output tokens for a generation run. Prototypes are large; 8000 gives
    // room for a full index.html plus styles.
    static let maxGenerationTokens = 8000

    // Generation sends only the most recent messages (see buildMessages), and the
    // estimate prices the SAME window. One source of truth for the count so the
    // two never drift.
    static let transcriptWindow = 20

    // Draft runs trade fidelity for speed and cost: the cheap Haiku model and a
    // smaller output budget. Honored by BOTH estimate() and generate().
    static let draftModelId = "claude-haiku-4-5-20251001"
    static let draftMaxTokens = 4000

    // View state.
    @Published private(set) var isGenerating = false
    @Published private(set) var runningProjectId: UUID?
    @Published private(set) var liveStatus: String?
    @Published private(set) var lastError: String?
    // Latest inspector payload (raw JSON string posted by the preview's isolated
    // world). The iteration workstream ships the real inspector JS + consumer;
    // this is the store-and-forward seam.
    @Published var lastInspectPayload: String?
    // Set by design_open_project (or any programmatic "go to this project"). The
    // DesignStudioView observes it, selects the project, then clears it.
    @Published var pendingOpenProjectId: UUID?

    private let store: DesignProjectStore

    // The in-flight API/local streaming task, retained so cancelRun() can stop it.
    // Cancelling it terminates the AsyncThrowingStream (onTermination cancels the
    // underlying network task).
    private var streamTask: Task<Void, Never>?
    // Set by cancelRun() so the route helpers skip their failure/summary path and
    // let the shared defer in generate() unwind isGenerating and liveStatus.
    private var cancelRequested = false
    // Coalesces per-file artifact-updated posts so a multi-file run reloads the
    // preview once, not once per file (no flash of unstyled content).
    private var artifactsDebounceTask: Task<Void, Never>?

    // Cheap per-keystroke pricing of the transcript window. The estimate runs on
    // every keystroke of the brief, and generation sends only the last
    // `transcriptWindow` messages, so the estimate must price that same window.
    // Reading the transcript off disk each keystroke would defeat the store's
    // char-count cache, so memoize the window's char count per project and
    // recompute from disk ONLY when the cheap cached TOTAL char count shows the
    // transcript actually changed (a generation appended messages).
    private struct TranscriptWindowMemo { let totalChars: Int; let windowChars: Int }
    private var transcriptWindowMemo: [UUID: TranscriptWindowMemo] = [:]

    private init() {
        self.store = DesignProjectStore.shared
    }

    // MARK: - Run control

    // Stop the active run on whichever route is live. Sets a transient "Stopped"
    // status and a transcript line; the shared defer in generate() then clears
    // isGenerating and the live status as the run unwinds.
    func cancelRun() {
        guard isGenerating else { return }
        cancelRequested = true
        liveStatus = "Stopped"
        // API / local route: cancel the retained streaming task.
        streamTask?.cancel()
        // Subscription route: reach the retained AgentBridgeRunner via the delegate.
        Task { @MainActor in await Self.agentDelegate?.cancelActiveRun() }
        if let pid = runningProjectId {
            store.appendMessage(id: pid, DesignChatMessage(role: .assistant, text: "Run stopped."))
        }
    }

    // The active (or slug-fallback) design system slug for the current brand,
    // shown as the view's design-system chip. nil when no system resolves.
    func activeDesignSystemLabel(brandSlug: String?) -> String? {
        Self.designSystemProvider?.activeSystemLabel(brandSlug: brandSlug)
    }

    // Whether a generation is running on a specific project. The view disables
    // destructive controls and restore/delete no-op against it.
    func isRunning(projectId: UUID) -> Bool {
        isGenerating && runningProjectId == projectId
    }

    // Fold an external run status (from the subscription CLI event sink) into the
    // live status, but only while a run is active so a late event cannot flash a
    // stale line after the run ends.
    func updateLiveStatus(_ status: String?) {
        guard isGenerating else { return }
        liveStatus = status
    }

    // Schedule a debounced artifacts-updated post. Multiple file writes within the
    // window coalesce into a single preview reload.
    func scheduleArtifactsUpdate(projectId: UUID) {
        artifactsDebounceTask?.cancel()
        artifactsDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            NotificationCenter.default.post(name: .gruxDesignArtifactsUpdated, object: projectId)
            self?.artifactsDebounceTask = nil
        }
    }

    // Fire the artifacts-updated post now and drop any pending debounce, so the
    // final reload of a run is immediate and never doubled by a trailing timer.
    private func flushArtifactsUpdate(projectId: UUID) {
        artifactsDebounceTask?.cancel()
        artifactsDebounceTask = nil
        NotificationCenter.default.post(name: .gruxDesignArtifactsUpdated, object: projectId)
    }

    // Test / preview seam.
    init(store: DesignProjectStore) {
        self.store = store
    }

    // MARK: - Estimate

    // Build the estimate context from the pending run and hand it to the bound
    // estimator, if any. Returns nil when no estimator is bound (the view then
    // hides the cost line rather than guessing).
    func estimate(brief: String, config: DesignRunConfig, projectId: UUID?) -> DesignRunEstimate? {
        guard let estimator = Self.estimator else { return nil }
        // Price the SAME transcript window generation sends (the last
        // `transcriptWindow` messages), NOT the whole history, or a long project
        // overstates cost. The cached total char count keeps this cheap per keystroke.
        let transcriptChars = projectId.map { transcriptWindowChars(projectId: $0) } ?? 0
        // Fold in the design-system markdown generation actually injects, resolved
        // the SAME pin-then-brand way (a pinned system, not just the brand's active
        // one). It is part of the system prompt on every run, so leaving it out, or
        // pricing the wrong system, desyncs the estimate from the run.
        let designSystemChars = resolvedDesignSystemCharCount(projectId: projectId, config: config)
        let approxInput = Self.approxInputTokens(
            transcriptChars: transcriptChars,
            briefChars: brief.count,
            designSystemChars: designSystemChars,
            systemPromptBudget: systemPromptCharBudget
        )
        let ctx = DesignEstimateContext(
            brief: brief,
            route: config.route,
            modelId: Self.effectiveModel(draftMode: config.draftMode, requested: config.modelId),
            brandSlug: config.brandSlug,
            approxInputTokens: approxInput,
            maxOutputTokens: Self.effectiveMaxTokens(draftMode: config.draftMode)
        )
        return estimator.estimate(for: ctx)
    }

    // Rough char budget for the fixed system prompt, used only for the estimate.
    private let systemPromptCharBudget = 2400

    // Pure input-token estimate: every char bucket folded, then chars/4. Kept
    // static and side-effect free so the design-system folding is unit-testable.
    static func approxInputTokens(transcriptChars: Int, briefChars: Int, designSystemChars: Int, systemPromptBudget: Int) -> Int {
        max(1, (transcriptChars + briefChars + designSystemChars + systemPromptBudget) / 4)
    }

    // Draft mode swaps in the cheap Haiku model; otherwise the requested model
    // (or the caller's default downstream) stands.
    static func effectiveModel(draftMode: Bool, requested: String?) -> String? {
        draftMode ? draftModelId : requested
    }

    // Draft mode caps the output budget; a full run gets the large budget.
    static func effectiveMaxTokens(draftMode: Bool) -> Int {
        draftMode ? draftMaxTokens : maxGenerationTokens
    }

    // Char count of the last `transcriptWindow` messages, matching what
    // buildMessages actually sends the model. Uses the store's cached TOTAL char
    // count as a cheap change-detector so chat.json is re-read only when the
    // transcript changed, not on every keystroke.
    private func transcriptWindowChars(projectId: UUID) -> Int {
        let total = store.transcriptCharCount(id: projectId)
        if let memo = transcriptWindowMemo[projectId], memo.totalChars == total {
            return memo.windowChars
        }
        let windowChars = store.transcript(id: projectId)
            .suffix(Self.transcriptWindow)
            .reduce(0) { $0 + $1.text.count }
        transcriptWindowMemo[projectId] = TranscriptWindowMemo(totalChars: total, windowChars: windowChars)
        return windowChars
    }

    // Char count of the design system generation will actually inject, resolved
    // the SAME pin-then-brand way as resolvedDesignSystemMarkdown so the estimate
    // prices what the run sends. The brand-active path is the store's cached
    // count; a slug pin resolves in memory through the provider seam.
    private func resolvedDesignSystemCharCount(projectId: UUID?, config: DesignRunConfig) -> Int {
        if let pid = projectId,
           let pin = store.project(id: pid)?.designSystemFile,
           !pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let md = Self.designSystemProvider?.systemMarkdown(forPinnedFile: pin),
           !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return md.count
        }
        return Self.designSystemProvider?.activeSystemCharCount(brandSlug: config.brandSlug) ?? 0
    }

    // MARK: - Generation

    // Kick a generation run. Appends the brief as a user turn, streams the
    // model, writes artifact files, snapshots once before the first write, and
    // appends the model's prose as an assistant turn. Safe to call from a
    // Button; it manages isGenerating itself.
    func generate(projectId: UUID, brief: String, config: DesignRunConfig) async {
        let trimmedBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBrief.isEmpty else { return }
        guard !isGenerating else { return }
        guard store.project(id: projectId) != nil else { return }

        isGenerating = true
        runningProjectId = projectId
        cancelRequested = false
        lastError = nil
        liveStatus = "Thinking"
        NotificationCenter.default.post(name: .gruxDesignRunStateChanged, object: projectId)
        defer {
            isGenerating = false
            runningProjectId = nil
            liveStatus = nil
            streamTask = nil
            NotificationCenter.default.post(name: .gruxDesignRunStateChanged, object: projectId)
        }

        store.appendMessage(id: projectId, DesignChatMessage(role: .user, text: trimmedBrief))

        // Persist the run's effective config onto the project's brand so the
        // design-system seam and future runs stay consistent.
        if let brand = config.brandSlug {
            store.setBrand(id: projectId, brandSlug: brand)
        }

        // The subscription-CLI route rides the agent bridge, not the HTTP
        // backends, so it branches before resolvedRouting.
        if config.route == .subscriptionCLI {
            await runSubscription(projectId: projectId, brief: trimmedBrief, config: config)
            return
        }

        // API / local route. Run the stream inside a retained task so cancelRun()
        // can stop it; await its value so the shared defer unwinds after.
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAPIStream(projectId: projectId, brief: trimmedBrief, config: config)
        }
        streamTask = task
        await task.value
    }

    // MARK: - API / local streaming route

    private func runAPIStream(projectId: UUID, brief: String, config: DesignRunConfig) async {
        // Cancelled before the stream even opened (e.g. during "Thinking"):
        // cancelRun() already recorded "Run stopped.", so bail before any work.
        if cancelRequested || Task.isCancelled { return }
        // Draft mode swaps the API model for cheap Haiku and shrinks the budget.
        // A local run keeps its own model (Haiku is an API model), but still
        // honors the smaller draft budget.
        let modelOverride: String? = config.route == .api
            ? Self.effectiveModel(draftMode: config.draftMode, requested: config.modelId)
            : config.modelId
        let maxTokens = Self.effectiveMaxTokens(draftMode: config.draftMode)

        // Resolve routing ONCE on the main actor (Sendable values only) so there
        // is no cross-actor hop inside the stream loop. Same seam ChatService
        // uses; the Studio just passes its own provider string per run.
        let routing = ModelRegistry.shared.resolvedRouting(
            provider: config.route.providerString,
            modelOverride: modelOverride
        )
        let backend = routing.backend
        let modelId = routing.modelId
        let apiKey = routing.apiKey

        // Missing-key guard on the API route: fail with the friendly copy BEFORE
        // opening the stream, rather than letting an empty key surface as a raw
        // HTTP error deep in the SSE loop.
        if config.route == .api, apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recordFailure(projectId: projectId, error: DesignStudioError.missingKey)
            return
        }

        let systemBlocks = buildSystemBlocks(projectId: projectId, config: config)
        let messages = buildMessages(projectId: projectId)

        let parser = DesignArtifactParser()
        var assistantProse = ""
        var didSnapshot = false
        var filesWritten: [String] = []

        func apply(_ events: [DesignArtifactEvent]) {
            for event in events {
                switch event {
                case .fileStarted(let path):
                    // Snapshot the PRIOR site/ once, before this run's first
                    // write, so a restore returns the pre-generation tree.
                    if !didSnapshot {
                        _ = store.snapshot(id: projectId, label: "generation")
                        didSnapshot = true
                    }
                    liveStatus = "Writing \(path)"
                case .fileChunk:
                    break // engine writes on completion; live streaming of bytes is the iteration workstream's job
                case .fileCompleted(let path, let fullText):
                    if store.writeArtifact(id: projectId, relativePath: path, content: fullText) {
                        filesWritten.append(path)
                        scheduleArtifactsUpdate(projectId: projectId)
                    }
                case .passthroughText(let text):
                    assistantProse += text
                }
            }
        }

        do {
            let stream = await backend.streamCompleteWithTools(
                apiKey: apiKey,
                model: modelId,
                systemBlocks: systemBlocks,
                messages: messages,
                tools: [],
                maxTokens: maxTokens,
                temperature: config.temperature ?? 0.7,
                spanName: "studio.generate",
                feature: "design_studio"
            )
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(let t):
                    apply(parser.parse(t))
                case .textBlockStart, .textBlockStop, .toolUseStart,
                     .toolUseInputDelta, .toolUseStop, .messageStop:
                    break
                }
            }
            // A cancelled run stops here: cancelRun() already recorded "Run
            // stopped.", so no summary and no failure line.
            if cancelRequested || Task.isCancelled { return }
            apply(parser.finish())

            liveStatus = "Reviewing design"
            let critiqueLine = await runCritique(projectId: projectId, brandSlug: config.brandSlug)
            // Cancelled DURING the critique await: cancelRun() already recorded
            // "Run stopped.", so bail before appending a success summary + critique
            // line (which would double up with the stop line).
            if cancelRequested || Task.isCancelled { return }

            let summary = Self.composeAssistantSummary(
                prose: assistantProse,
                filesWritten: filesWritten,
                critique: critiqueLine
            )
            store.appendMessage(id: projectId, DesignChatMessage(role: .assistant, text: summary))
            if let first = filesWritten.first {
                store.setPreview(id: projectId, preview: "Last run wrote \(filesWritten.count) file\(filesWritten.count == 1 ? "" : "s"), incl. \(first)")
            }
            flushArtifactsUpdate(projectId: projectId)
        } catch {
            // Cancellation surfaces here as a thrown error on some paths; it is
            // already handled by cancelRun(), so do not double-report it.
            if cancelRequested || Task.isCancelled { return }
            recordFailure(projectId: projectId, error: error)
        }
    }

    // MARK: - Subscription CLI route

    private func runSubscription(projectId: UUID, brief: String, config: DesignRunConfig) async {
        do {
            guard let delegate = Self.agentDelegate else {
                throw DesignStudioError.notImplemented(
                    "The subscription route could not start. Pick API key or Local model for now."
                )
            }
            try await delegate.runGeneration(projectId: projectId, brief: brief, config: config)
            flushArtifactsUpdate(projectId: projectId)

            // Critique the generated index.html on a successful subscription run
            // too, so the anti-slop gate covers every route, not just the API one.
            if cancelRequested { return }
            liveStatus = "Reviewing design"
            let critiqueLine = await runCritique(projectId: projectId, brandSlug: config.brandSlug)
            // Cancelled DURING the critique await: cancelRun() already recorded
            // "Run stopped.", so do not append the critique line on top of it.
            if cancelRequested || Task.isCancelled { return }
            if let critiqueLine, !critiqueLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                store.appendMessage(id: projectId, DesignChatMessage(role: .assistant, text: critiqueLine))
            }
        } catch {
            if cancelRequested { return }
            recordFailure(projectId: projectId, error: error)
        }
    }

    // Post-generation critique via the seam, run against the site's index.html.
    // Returns nil when no critic is bound or there is no index to review.
    private func runCritique(projectId: UUID, brandSlug: String?) async -> String? {
        guard let critic = Self.critic,
              let indexURL = store.siteIndexURL(id: projectId),
              let html = try? String(contentsOf: indexURL, encoding: .utf8) else { return nil }
        return await critic.critique(html: html, brandSlug: brandSlug)
    }

    private func recordFailure(projectId: UUID, error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = message
        store.appendMessage(id: projectId, DesignChatMessage(role: .assistant, text: "Run failed: \(message)"))
    }

    // MARK: - Prompt assembly

    // Two blocks: a cached stable instruction block, then the per-run
    // design-system markdown so the cache prefix stays byte-identical across
    // runs (the rule ChatService follows for its preset block).
    private func buildSystemBlocks(projectId: UUID, config: DesignRunConfig) -> [[String: Any]] {
        var blocks: [[String: Any]] = [
            [
                "type": "text",
                "text": Self.generationInstructions,
                "cache_control": ["type": "ephemeral"]
            ]
        ]
        if let ds = resolvedDesignSystemMarkdown(projectId: projectId, config: config),
           !ds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append([
                "type": "text",
                "text": "ACTIVE_DESIGN_SYSTEM\nApply this brand system to every choice (color, type, spacing, voice):\n\n\(ds)"
            ])
        }
        return blocks
    }

    // Prefer a per-project pinned system file; fall back to the brand's active
    // system. Resolving the pin stays behind the provider seam so the engine
    // keeps no direct store dependency and the seam signature stays intact.
    private func resolvedDesignSystemMarkdown(projectId: UUID, config: DesignRunConfig) -> String? {
        if let pin = store.project(id: projectId)?.designSystemFile,
           !pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let md = Self.designSystemProvider?.systemMarkdown(forPinnedFile: pin),
           !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return md
        }
        return Self.designSystemProvider?.activeSystemMarkdown(brandSlug: config.brandSlug)
    }

    private func buildMessages(projectId: UUID) -> [[String: Any]] {
        store.transcript(id: projectId).suffix(Self.transcriptWindow).map { m in
            ["role": m.role.rawValue, "content": m.text]
        }
    }

    // The design-generation contract. No em/en dashes, $N money format, and the
    // exact artifact emission format the DesignArtifactParser expects.
    static let generationInstructions: String = """
    You are the Grux Design Studio generator. You build complete, self contained web \
    prototypes, decks, and live dashboards that render inside a sandboxed offline preview.

    OUTPUT FORMAT (strict). Wrap every file you write in this exact delimiter pair, one per file:
    <grux-artifact path="site/index.html">
    ...the full file contents...
    </grux-artifact>

    Rules for artifacts:
    - Paths are project relative and MUST live under site/. Never use an absolute path, never use "..".
    - Always write a site/index.html entry point. Split large CSS or JS into site/styles.css and \
    site/app.js and reference them with relative paths.
    - The preview has NO network access. Do not link external stylesheets, fonts, scripts, images, \
    or analytics. Inline your CSS and JS or ship them as site/ files. Use system fonts or embedded \
    data URIs only. No CDN links.
    - Produce production grade, responsive, accessible markup. Real content, not lorem ipsum.

    Voice and copy rules for any text inside the design:
    - Never use an em dash or en dash. Use a comma, period, colon, or split the sentence.
    - Write dollar amounts as $50, never "50 dollars" or "fifty dollars".

    Outside the artifact blocks, speak briefly to the user: one or two sentences on what you built \
    and what to try next. Keep prose short; the artifacts are the deliverable.
    """

    // Assemble the assistant transcript line from the model prose plus a
    // deterministic file summary and optional critique.
    static func composeAssistantSummary(prose: String, filesWritten: [String], critique: String?) -> String {
        var parts: [String] = []
        let cleanProse = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanProse.isEmpty { parts.append(cleanProse) }
        if filesWritten.isEmpty {
            if cleanProse.isEmpty { parts.append("No files were written this run.") }
        } else {
            parts.append("Wrote \(filesWritten.count) file\(filesWritten.count == 1 ? "" : "s"): \(filesWritten.joined(separator: ", ")).")
        }
        // The critic seam already carries its own "Critique: " prefix (or a
        // "(critique skipped ...)" note); append it verbatim so the label is not
        // doubled.
        if let critique, !critique.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(critique)
        }
        return parts.joined(separator: "\n\n")
    }
}
