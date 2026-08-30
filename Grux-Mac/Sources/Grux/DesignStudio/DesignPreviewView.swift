import SwiftUI
import WebKit

// MARK: - Inspector script seam
//
// The iteration workstream ships the real element-picker JS. Until then this
// inert placeholder is injected into the isolated "gruxInspector" content world
// so the wiring (user script + message handler + engine payload sink) is proven
// end to end. Page JS cannot see this world. Swap `script` at integration time
// without touching this file.
enum InspectorScriptProvider {
    static var script: String = """
    // Grux Studio inspector placeholder (isolated world). The iteration
    // workstream replaces this with the real element picker, which posts
    // window.webkit.messageHandlers.gruxInspect.postMessage({selector, rect, styles}).
    (function () { /* no-op until the iteration workstream binds the real inspector */ })();
    """
}

// MARK: - Compiled no-network rule list (cached, not per-view)
//
// A content rule list that blocks every URL, then re-allows file: and about:
// only. Compilation is async, so it is compiled once and cached; every preview
// attaches the same list. This is the primary network fence for untrusted
// generated HTML (the app itself is not App-Sandboxed).
@MainActor
final class StudioContentRules {
    static let shared = StudioContentRules()

    private var cached: WKContentRuleList?
    private var compiling = false
    private var waiters: [(WKContentRuleList?) -> Void] = []

    // Block all, then ignore-previous-rules for file: and about: so local
    // artifact files and about:blank still load while the network stays shut.
    private static let encoded = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file://.*"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^about:.*"},"action":{"type":"ignore-previous-rules"}}]"#

    func rules(_ completion: @escaping (WKContentRuleList?) -> Void) {
        if let cached { completion(cached); return }
        waiters.append(completion)
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "grux-studio-block-net",
            encodedContentRuleList: Self.encoded
        ) { list, _ in
            Task { @MainActor in
                self.cached = list
                self.compiling = false
                let pending = self.waiters
                self.waiters = []
                pending.forEach { $0(list) }
            }
        }
    }
}

// MARK: - DesignPreviewView
//
// Sandboxed WKWebView that renders the project's site/ tree. Every layer of the
// UI contract's section 4 hardening is present: non-persistent data store,
// compiled no-network rule list, a navigation-delegate allowlist, fenced
// loadFileURL, an isolated-world inspector hook, and a revision-gated reload so
// SwiftUI's per-render updateNSView does not thrash the page.
struct DesignPreviewView: NSViewRepresentable {
    let indexURL: URL?
    let siteRoot: URL?
    // Bumped by the parent when artifacts change; drives reload. A plain
    // updateNSView call (same revision) never reloads.
    let revision: Int
    let engine: DesignStudioEngine

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        // Isolated-world inspector: injected script + message handler seam. Page
        // JS cannot reach this world.
        let inspectorWorld = WKContentWorld.world(name: "gruxInspector")
        let userScript = WKUserScript(
            source: InspectorScriptProvider.script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: inspectorWorld
        )
        controller.addUserScript(userScript)
        controller.add(context.coordinator, contentWorld: inspectorWorld, name: "gruxInspect")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()          // no cookies/cache leak
        config.defaultWebpagePreferences.allowsContentJavaScript = true  // generated JS must run
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = false
        config.preferences = prefs
        config.userContentController = controller

        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        Self.setDrawsBackground(web, false)                 // theme blends through margins
        context.coordinator.webView = web
        context.coordinator.contentController = controller

        // Attach the compiled no-network list (async), then do the first load.
        // The first load is fenced behind rulesDidAttach so no untrusted page
        // can reach the network before the rule list is in place.
        StudioContentRules.shared.rules { list in
            if let list { controller.add(list) }
            context.coordinator.rulesDidAttach(indexURL: indexURL, siteRoot: siteRoot, revision: revision)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.load(indexURL: indexURL, siteRoot: siteRoot, revision: revision, force: false)
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        // Break the WKUserContentController -> Coordinator strong reference.
        coordinator.contentController?.removeAllScriptMessageHandlers()
        web.navigationDelegate = nil
        web.uiDelegate = nil
    }

    // drawsBackground is private KVC; keep the single call site here.
    static func setDrawsBackground(_ web: WKWebView, _ value: Bool) {
        web.setValue(value, forKey: "drawsBackground")
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        weak var contentController: WKUserContentController?
        private weak var engine: DesignStudioEngine?

        private var loadedRevision = Int.min
        private var loadedPath: String?

        // The no-network rule list compiles asynchronously. Until it is
        // attached, every load is stashed instead of run, so the first render
        // of the session can never reach the network before the fence exists.
        private var rulesAttached = false
        private var pendingLoad: (indexURL: URL?, siteRoot: URL?, revision: Int)?

        init(engine: DesignStudioEngine) {
            self.engine = engine
        }

        // Called from the StudioContentRules completion once the rule list is
        // attached (or compilation has definitively finished). Runs the first,
        // now-fenced load: the most recent request that arrived while we were
        // still compiling, or the values captured when the view was created.
        @MainActor
        func rulesDidAttach(indexURL: URL?, siteRoot: URL?, revision: Int) {
            rulesAttached = true
            let target = pendingLoad ?? (indexURL: indexURL, siteRoot: siteRoot, revision: revision)
            pendingLoad = nil
            load(indexURL: target.indexURL, siteRoot: target.siteRoot, revision: target.revision, force: true)
        }

        @MainActor
        func load(indexURL: URL?, siteRoot: URL?, revision: Int, force: Bool) {
            // Fail closed: before the no-network rule list is attached, never
            // hand a load to WebKit. Stash the latest request; rulesDidAttach
            // replays it as a forced, fenced first load.
            guard rulesAttached else {
                pendingLoad = (indexURL: indexURL, siteRoot: siteRoot, revision: revision)
                return
            }
            guard let web = webView, let indexURL, let siteRoot else { return }
            // Reload only when the revision or file actually changed, not on
            // every SwiftUI render (the editor would flicker otherwise).
            if !force && revision == loadedRevision && indexURL.path == loadedPath { return }
            loadedRevision = revision
            loadedPath = indexURL.path
            web.loadFileURL(indexURL, allowingReadAccessTo: siteRoot)
        }

        // Belt-and-suspenders allowlist. about: and file: (already fenced to the
        // artifact dir by allowingReadAccessTo) pass; everything else is cancelled.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == "about" || url.isFileURL {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }

        // Route target=_blank / window.open to nothing.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            return nil
        }

        // Isolated-world inspector payload sink. Stores the latest payload on the
        // engine; the iteration workstream consumes it.
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "gruxInspect" else { return }
            let payload = Self.jsonString(from: message.body)
            let engine = self.engine
            Task { @MainActor in engine?.lastInspectPayload = payload }
        }

        static func jsonString(from body: Any) -> String {
            if let s = body as? String { return s }
            if JSONSerialization.isValidJSONObject(body),
               let data = try? JSONSerialization.data(withJSONObject: body),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return String(describing: body)
        }
    }
}
