import SwiftUI

/// The top of Settings, Models while Chat has nothing to talk to.
///
/// After "Skip for now" at the model step there was no way in the app to get
/// a model: "Connect a model" opened Settings on General, Models offered only
/// "Discover local models" against a server holding none, and the only route
/// left was restarting onboarding (W4 pass 2, 2026-10-13). This offers what
/// first run offers: with Ollama answering and no model, it downloads the one
/// this Mac runs best; with no Ollama, where to get it.
struct ConnectModelSection: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var registry = ModelRegistry.shared
    @ObservedObject private var ollama = OllamaManager.shared
    @State private var pulling: CookbookModel?
    @State private var error: String?
    @State private var checking = false
    /// Set before the first await, so a second press cannot start a second pull.
    @State private var fetching = false
    /// A fixed route, for rendering one state without a server.
    private let preview: ConnectModelCopy.LocalRoute?

    init(preview: ConnectModelCopy.LocalRoute? = nil) { self.preview = preview }

    var body: some View {
        if preview != nil || !ChatReadiness.current().canSend {
            Section(ConnectModelCopy.title) {
                Text(ConnectModelCopy.lead)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                localRoute
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(ConnectModelCopy.keyRoute)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var localRoute: some View {
        switch preview ?? ConnectModelCopy.route(reachable: registry.local != nil, usable: registry.localUsable,
                                                 pick: Cookbook.headline(for: HardwareProfile.detect())) {
        case .download(let pick):
            HStack(spacing: 8) {
                Button(ConnectModelCopy.download(pick)) { fetch() }
                    .disabled(fetching)
                if let pulling {
                    ProgressView().controlSize(.small)
                    Text(ConnectModelCopy.downloading(pulling, ollama.pulls[pulling.id]))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .getOllama:
            Text(ConnectModelCopy.whatOllamaIs)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link(ModelGate.ollamaLink, destination: ModelGate.ollamaURL)
                    .font(.caption)
                    .gruxLink()
                Button(ConnectModelCopy.checkAgain) {
                    checking = true
                    Task { await registry.discoverLocal(); checking = false }
                }
                .disabled(checking)
            }
        case .noFit:
            Text(ConnectModelCopy.noFit)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .ready:
            EmptyView()
        }
    }

    private func fetch() {
        guard !fetching else { return }
        fetching = true
        error = nil
        Task {
            error = await LocalModelFetch.fetchHeadline { pulling = $0 }
            fetching = false
        }
    }
}

/// What the section says and which local route it offers, pure so every
/// state is checkable without a server.
enum ConnectModelCopy {
    static let title = "Connect a model"
    static let lead = "Chat needs a model. A local one runs on this Mac at no cost per use and is weaker at hard work; a key is faster and sharper."
    static let keyRoute = "Or paste an Anthropic API key under Anthropic API below."
    static let whatOllamaIs = "Ollama is a free app that serves models on your own Mac. Install it and open it, then check again."
    static let checkAgain = "Check again"
    static let noFit = "Ollama is running, but this Mac does not have the memory for any model Grux can fetch. Paste a key instead."

    enum LocalRoute: Equatable {
        case download(CookbookModel)
        case getOllama
        case noFit
        case ready
    }

    static func route(reachable: Bool, usable: Bool, pick: CookbookModel?) -> LocalRoute {
        guard reachable else { return .getOllama }
        if usable { return .ready }
        return pick.map(LocalRoute.download) ?? .noFit
    }

    static func download(_ m: CookbookModel) -> String {
        String(format: "Download %@ (%.1f GB)", m.displayName, m.diskGB)
    }

    /// The progress line, from what Ollama streams: bytes and percent once
    /// it reports sizes, the model's size before that. Shared by first run
    /// and Settings so the two cannot drift.
    static func downloading(_ m: CookbookModel, _ p: OllamaManager.PullProgress?) -> String {
        if let done = p?.completedBytes, let total = p?.totalBytes, total > 0 {
            return String(format: "Downloading %@: %.1f of %.1f GB, %d%%",
                          m.displayName, done / 1e9, total / 1e9, Int(min(1, done / total) * 100))
        }
        return String(format: "Downloading %@, %.1f GB", m.displayName, m.diskGB)
    }

    /// Said only when the download has ended without the model: Ollama's own
    /// error or HTTP status when it gave one.
    static func downloadFailed(_ m: CookbookModel, _ ended: OllamaManager.PullProgress?) -> String {
        if let ended, ended.failed {
            return "Downloading \(m.displayName) stopped: \(ended.status). Try again, or paste a key."
        }
        return "Downloading \(m.displayName) ended without the model. Try again, or paste a key."
    }
}

/// Fetches this Mac's best local model into a running Ollama and points chat
/// at it, the way first run's "Use a local model instead" does.
@MainActor
enum LocalModelFetch {
    /// nil when a usable model is installed and discovered, otherwise the
    /// sentence to show.
    static func fetchHeadline(onPulling: (CookbookModel?) -> Void) async -> String? {
        guard let pick = Cookbook.headline(for: HardwareProfile.detect()) else { return ConnectModelCopy.noFit }
        if let refusal = await OllamaManager.shared.pullRefusal(for: pick.id), !refusal.fits {
            return String(format: "%@ needs %.1f GB free and %@ has %.1f GB. Free some space, or paste a key instead.",
                          pick.displayName, refusal.requiredGB, refusal.measuredPath, refusal.availableGB)
        }
        onPulling(pick)
        let ended = await OllamaManager.shared.pullToEnd(pick.id)
        onPulling(nil)
        await OllamaManager.shared.refreshInstalled()
        guard !GruxConfig.usableLocalModels(OllamaManager.shared.installedTags).isEmpty else {
            return ConnectModelCopy.downloadFailed(pick, ended)
        }
        // Chat reads `offlineLLMModel` and the background path `localLLMModel`:
        // both point at what is actually here, as first run does.
        if let adopt = GruxConfig.installedModelToAdopt(configured: AppState.shared.config.offlineLLMModel,
                                                        installed: OllamaManager.shared.installedTags,
                                                        headline: pick.id) {
            AppState.shared.config.offlineLLMModel = adopt
            AppState.shared.config.localLLMModel = adopt
            AppState.shared.saveConfig()
        }
        await ModelRegistry.shared.discoverLocal()
        return nil
    }
}
