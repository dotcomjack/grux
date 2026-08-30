import Foundation
import GruxAgentCore

// Phase 4 integration: binds the Design Studio engine's seams to their real
// implementations across the campaign workstreams. Called once at launch from
// applicationDidFinishLaunching. Each binding is intentionally a thin adapter;
// the heavy machinery lives in its owning subsystem.

@MainActor
enum DesignStudioIntegration {
    static func wireSeams() {
        DesignStudioEngine.designSystemProvider = StudioDesignSystemProvider()
        DesignStudioEngine.critic = StudioCritic()
        DesignStudioEngine.estimator = StudioRunEstimator()
        DesignStudioEngine.agentDelegate = StudioAgentDelegate()
        // Let the store consult the engine so restore/delete no-op on a project
        // that is mid-generation.
        DesignProjectStore.shared.isProjectRunning = { projectId in
            DesignStudioEngine.shared.isRunning(projectId: projectId)
        }
        InspectorScriptProvider.script = InspectorScript.script
    }
}

// MARK: - Design system seam (WS-D)

private struct StudioDesignSystemProvider: DesignSystemProviding {
    func activeSystemMarkdown(brandSlug: String?) -> String? {
        guard let slug = brandSlug, !slug.isEmpty else { return nil }
        return MainActor.assumeIsolated {
            DesignSystemStore.shared.activeSystemMarkdown(brandSlug: slug)
        }
    }

    func activeSystemLabel(brandSlug: String?) -> String? {
        guard let slug = brandSlug, !slug.isEmpty else { return nil }
        return MainActor.assumeIsolated {
            DesignSystemStore.shared.resolvedActiveSystemSlug(brandSlug: slug)
        }
    }

    func activeSystemCharCount(brandSlug: String?) -> Int {
        guard let slug = brandSlug, !slug.isEmpty else { return 0 }
        return MainActor.assumeIsolated {
            DesignSystemStore.shared.activeSystemCharCount(brandSlug: slug)
        }
    }

    // Resolve a project's pinned system file to markdown: an exact slug match, a
    // slugified basename match (strips directory, extension, and a trailing
    // "-design"), or a readable file on disk. nil when none resolve.
    func systemMarkdown(forPinnedFile file: String) -> String? {
        let trimmed = file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return MainActor.assumeIsolated {
            let store = DesignSystemStore.shared
            if store.entry(slug: trimmed) != nil { return store.markdown(slug: trimmed) }
            let base = (trimmed as NSString).lastPathComponent
            var stem = ((base as NSString).deletingPathExtension).lowercased()
            if stem.hasSuffix("-design") { stem = String(stem.dropLast("-design".count)) }
            let slug = DesignSystem.slugify(stem)
            if !slug.isEmpty, store.entry(slug: slug) != nil { return store.markdown(slug: slug) }
            let expanded = (trimmed as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return try? String(contentsOfFile: expanded, encoding: .utf8)
            }
            return nil
        }
    }
}

// MARK: - Critique seam (WS-E)

private struct StudioCritic: DesignCritiquing {
    func critique(html: String, brandSlug: String?) async -> String? {
        let (systemMarkdown, keyMissing): (String?, Bool) = await MainActor.run {
            let md: String? = {
                guard let slug = brandSlug, !slug.isEmpty else { return nil }
                return DesignSystemStore.shared.activeSystemMarkdown(brandSlug: slug)
            }()
            return (md, AppState.shared.anthropicKey.isEmpty)
        }

        // The gate needs an API key. Without one it fails closed, so say the
        // review was skipped rather than going silent (which reads as "passed").
        if keyMissing {
            return "(critique skipped: no API key)"
        }

        let verdict = await CritiqueGate.run(
            html: html,
            brandSlug: brandSlug,
            designSystemMarkdown: systemMarkdown
        )
        switch verdict.status {
        case .pass:
            return "Critique: pass on all \(verdict.dimensions.count) dimensions."
        case .fail:
            let blockers = verdict.dimensions.filter { $0.blocks }
                .prefix(2)
                .map { "\($0.name): \($0.reason)" }
                .joined(separator: " | ")
            return "Critique: \(blockers.isEmpty ? verdict.summary : blockers)"
        case .error:
            // A critique outage never blocks the artifact, but note the skip so
            // the transcript does not imply the design was reviewed and cleared.
            return "(critique skipped: reviewer unavailable)"
        case .pending, .running:
            return nil
        }
    }
}

// MARK: - Cost estimate seam (WS-B)

// The estimate runs on every composer keystroke (the brief is @State bound to a
// TextEditor), so the Anthropic-key presence, which only toggles the critique
// cost between zero and a fixed figure, is cached with a short TTL instead of
// reading the Keychain live per character. A Settings change is reflected within
// the TTL. This keeps AppState's read-live-no-@Published convention for the key
// itself while coalescing the hot typing path.
@MainActor
private enum AnthropicKeyPresence {
    static var cached = false
    static var checkedAt = Date.distantPast
    static let ttl: TimeInterval = 2

    static func current() -> Bool {
        let now = Date()
        if now.timeIntervalSince(checkedAt) > ttl {
            cached = !AppState.shared.anthropicKey.isEmpty
            checkedAt = now
        }
        return cached
    }
}

private struct StudioRunEstimator: DesignRunEstimating {
    func estimate(for context: DesignEstimateContext) -> DesignRunEstimate? {
        let (defaultModel, hasKey): (String, Bool) = MainActor.assumeIsolated {
            (AppState.shared.config.model, AnthropicKeyPresence.current())
        }
        let modelId = context.modelId ?? defaultModel
        // The post-generation critique spends real Anthropic API dollars on every
        // route when a key is present (it is skipped without one), so fold its
        // estimated cost into the comparison rather than letting the free routes
        // read $0 while the review is billed.
        let critiqueUSD = CostMeter.critiqueEstimatedUSD(
            generatedOutputTokens: context.maxOutputTokens,
            hasAnthropicKey: hasKey
        )
        let routes = CostMeter.routeComparison(
            inputTokens: context.approxInputTokens,
            maxOutputTokens: context.maxOutputTokens,
            modelId: modelId,
            critiqueUSD: critiqueUSD
        )
        guard !routes.isEmpty else { return nil }
        let primary = routes.first(where: { $0.route == context.route }) ?? routes[0]
        let alternatives = routes.filter { $0.route != primary.route }
        return DesignRunEstimate(
            inputTokens: context.approxInputTokens,
            maxOutputTokens: context.maxOutputTokens,
            primary: primary,
            alternatives: alternatives
        )
    }
}

// MARK: - Subscription CLI seam (WS-C)

// Runs a design generation through an installed coding-agent CLI (the Claude
// Code subscription route). The run works inside the project directory, which
// the bridge sandbox sanctions under ~/Documents/Grux/design. MainActor-isolated
// so the retained runner and sink are mutated without a data race; the long
// runner.run() await hops onto the runner actor and never blocks the main thread.
@MainActor
private final class StudioAgentDelegate: DesignAgentDelegating {
    private let registry = AgentCLIRegistry()
    // Retained for the whole run: the runner so cancelActiveRun() can stop it,
    // the sink so its events are not silently dropped (the runner holds it weakly).
    private var currentRunner: AgentBridgeRunner?
    private var currentSink: StudioAgentEventSink?

    func cancelActiveRun() async {
        await currentRunner?.cancel()
    }

    func runGeneration(projectId: UUID, brief: String, config: DesignRunConfig) async throws {
        guard let siteURL = DesignProjectStore.shared.siteRootURL(id: projectId) else {
            throw DesignStudioError.noProject
        }
        let project = DesignProjectStore.shared.project(id: projectId)
        let systemMarkdown = project?.brandSlug.flatMap {
            DesignSystemStore.shared.activeSystemMarkdown(brandSlug: $0)
        }
        // Snapshot the pre-run tree so restore returns to before this run.
        _ = DesignProjectStore.shared.snapshot(id: projectId, label: "generation")
        let cwd = siteURL.deletingLastPathComponent().path

        guard let adapter = await registry.adapter(id: "claude") else {
            throw DesignStudioError.notImplemented("No Claude Code adapter is registered.")
        }
        guard let probe = await registry.detect(adapterId: "claude"), probe.isAvailable else {
            throw DesignStudioError.notImplemented(
                "Claude Code is not installed on this Mac, so the subscription route is unavailable. Pick API key or Local model."
            )
        }

        var prompt = """
        You are generating a self-contained web design artifact.
        Work ONLY inside the site/ directory of the current working directory.
        The entry file is site/index.html; keep CSS and JS in sibling files under site/.
        No external network resources. Never use an em dash or en dash in any copy.
        Dollar amounts in copy are written as $N.

        BRIEF:
        \(brief)
        """
        if let md = systemMarkdown, !md.isEmpty {
            prompt += "\n\nACTIVE DESIGN SYSTEM (obey its palette, type, spacing, components, voice and anti-patterns):\n\(md)"
        }

        let invocation = adapter.buildInvocation(
            prompt: prompt,
            cwd: cwd,
            model: config.modelId,
            extraArgs: []
        )
        // Bind a strongly-retained sink so the run's live progress (assistant
        // text, tool use, file writes) folds into the engine's live status and
        // triggers debounced preview reloads. The runner retains it weakly.
        let sink = StudioAgentEventSink(projectId: projectId)
        let runner = AgentBridgeRunner(adapter: adapter, invocation: invocation, observer: sink)
        currentSink = sink
        currentRunner = runner
        defer {
            currentRunner = nil
            currentSink = nil
        }
        let result = await runner.run(ttlSeconds: 1800)

        guard result.success else {
            // Fold the note and any partial summary into ONE failure message via
            // the thrown error, rather than appending a summary and then a
            // separate "Run failed" line.
            let note = result.note ?? "The subscription CLI run did not complete. Check that Claude Code is signed in."
            let detail = result.finalText.isEmpty ? note : "\(note): \(String(result.finalText.prefix(500)))"
            throw DesignStudioError.notImplemented(detail)
        }

        let summary = result.finalText.isEmpty
            ? (result.note ?? "Agent run finished with no summary.")
            : String(result.finalText.prefix(2000))
        DesignProjectStore.shared.appendMessage(
            id: projectId,
            DesignChatMessage(role: .assistant, text: summary)
        )
        // Reflect what actually landed on disk in the project preview line.
        let files = DesignProjectStore.shared.artifactFiles(id: projectId)
        if let first = files.first {
            DesignProjectStore.shared.setPreview(
                id: projectId,
                preview: "Last run wrote \(files.count) file\(files.count == 1 ? "" : "s"), incl. \(first)"
            )
        }
    }
}

// Folds a subscription run's AdapterEvents into the engine's live status on the
// MainActor. Final class with only immutable Sendable state so it satisfies the
// AgentBridgeObserver Sendable requirement; the runner holds it weakly, so the
// delegate keeps the strong reference for the run's lifetime.
private final class StudioAgentEventSink: AgentBridgeObserver {
    let projectId: UUID

    init(projectId: UUID) {
        self.projectId = projectId
    }

    func bridgeRun(_ runId: String, didEmit event: AdapterEvent) async {
        switch event {
        case .assistantText(let text, _):
            let snippet = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
            guard !snippet.isEmpty else { return }
            await MainActor.run { DesignStudioEngine.shared.updateLiveStatus(snippet) }
        case .toolUse(let name, _, _):
            await MainActor.run { DesignStudioEngine.shared.updateLiveStatus("Running \(name)") }
        case .fileArtifact(let path, _, _):
            let id = projectId
            await MainActor.run {
                DesignStudioEngine.shared.updateLiveStatus("Writing \(path)")
                DesignStudioEngine.shared.scheduleArtifactsUpdate(projectId: id)
            }
        default:
            break
        }
    }
}
