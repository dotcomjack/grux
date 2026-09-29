import XCTest
import WebKit
@testable import Grux

/// sweep-9: Design Studio's preview drew blank on two opens of an installed
/// build with nothing in wake.log but the tab opening, and no web view in Grux
/// handled a lost content process. Whatever the blank was, a lost content
/// process now leaves a wake.log line and one reload.
@MainActor
final class WebContentRecoveryTests: XCTestCase {

    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("web-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("site"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Calls the preview's own navigation delegate method, as WebKit does.
    func test_thePreviewReloadsOnceAfterItsContentProcessEnds() throws {
        let site = dir.appendingPathComponent("site")
        let index = site.appendingPathComponent("index.html")
        try "<html><body style='background:#fff'>Preview</body></html>".write(to: index, atomically: true, encoding: .utf8)
        let engine = DesignStudioEngine(store: DesignProjectStore(rootDir: dir.appendingPathComponent("store")))
        let coordinator = DesignPreviewView.Coordinator(engine: engine)
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        coordinator.webView = web
        coordinator.rulesDidAttach(indexURL: index, siteRoot: site, revision: 1)
        XCTAssertEqual(coordinator.loadCount, 1, "control: the page loaded once")

        coordinator.webViewWebContentProcessDidTerminate(web)
        XCTAssertEqual(coordinator.loadCount, 2, "the preview did not reload after its content process ended")

        // A page that loses its process on every load must not reload forever.
        coordinator.webViewWebContentProcessDidTerminate(web)
        XCTAssertEqual(coordinator.loadCount, 2, "a second end right after the reload reloaded again")
    }

    func test_theRecoveryLogsTheSurfaceAndReloadsOncePerWindow() {
        let recovery = WebContentRecovery(surface: "Design Studio preview")
        var reloads = 0
        let start = Date()
        let first = recovery.contentProcessEnded(now: start) { reloads += 1 }
        XCTAssertTrue(first.contains("Design Studio preview"), first)
        XCTAssertEqual(reloads, 1)
        let again = recovery.contentProcessEnded(now: start.addingTimeInterval(5)) { reloads += 1 }
        XCTAssertEqual(reloads, 1, "reloaded again inside the retry window")
        XCTAssertTrue(again.contains("Design Studio preview"), again)
        recovery.contentProcessEnded(now: start.addingTimeInterval(WebContentRecovery.retryWindow + 1)) { reloads += 1 }
        XCTAssertEqual(reloads, 2, "a later end did not reload")
    }

    /// Code with its comments removed, so a word in a comment proves nothing.
    static func code(_ source: String) -> String {
        source.replacingOccurrences(of: #"(?s)/\*.*?\*/"#, with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let r = line.range(of: "//") else { return line }
                return line[..<r.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// Each type in `code` (class, struct, enum, actor or extension): its
    /// declaration line and its body, braces matched. A nested type is its
    /// own entry, and is also inside its parent's body.
    static func types(_ code: String) -> [(header: String, body: String)] {
        let chars = Array(code)
        let decl = try! NSRegularExpression(pattern: #"\b(class|struct|enum|actor|extension)\s+\w+[^{};]*\{"#)
        var out: [(String, String)] = []
        for m in decl.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let r = Range(m.range, in: code) else { continue }
            let open = code.distance(from: code.startIndex, to: r.upperBound) - 1
            var depth = 0
            var end = open
            for i in open..<chars.count {
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1; if depth == 0 { end = i; break } }
            }
            out.append((String(code[r]), String(chars[open...end])))
        }
        return out
    }

    /// Whether code that makes web views handles a lost content process for
    /// each, type by type: every navigation delegate declares the handler
    /// itself (a real method, never a comment), and every type that makes a
    /// web view sets a navigation delegate on it.
    static func handlesLostContentProcess(_ source: String) -> Bool {
        let code = code(source)
        guard code.contains("WKWebView(") else { return true }
        let handler = #"func\s+webViewWebContentProcessDidTerminate\s*\(\s*_\s+\w+\s*:\s*WKWebView\s*\)"#
        let types = types(code)
        let delegates = types.filter { $0.header.contains("WKNavigationDelegate") }
        guard !delegates.isEmpty else { return false }
        for t in delegates where t.body.range(of: handler, options: .regularExpression) == nil { return false }
        for t in types where t.body.contains("WKWebView(")
            && t.body.range(of: #"\.navigationDelegate\s*=\s*(?!nil)\S"#, options: .regularExpression) == nil {
            return false
        }
        return true
    }
    func test_theSweepOnlyCountsARealHandlerThatIsTheDelegate() {
        // The handler's name only in comments: a trailing one and a block,
        // which a filter on whole comment lines still let through.
        let commentOnly = """
            struct View {
                func make() -> WKWebView {
                    let w = WKWebView() // webViewWebContentProcessDidTerminate is handled elsewhere
                    w.navigationDelegate = context.coordinator
                    return w
                }
                final class Coordinator: NSObject, WKNavigationDelegate {
                    /* func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {} */
                }
            }
            """
        XCTAssertFalse(Self.handlesLostContentProcess(commentOnly), "a comment naming the handler passed as a handler")
        let notDelegate = """
            struct View {
                func make() -> WKWebView { WKWebView() }
                final class Coordinator: NSObject, WKNavigationDelegate {
                    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {}
                }
            }
            """
        XCTAssertFalse(Self.handlesLostContentProcess(notDelegate), "a handler no web view has as its delegate passed")
        let real = """
            struct View {
                func make() -> WKWebView {
                    let w = WKWebView()
                    w.navigationDelegate = context.coordinator
                    return w
                }
                final class Coordinator: NSObject, WKNavigationDelegate {
                    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {}
                }
            }
            """
        XCTAssertTrue(Self.handlesLostContentProcess(real), "control: a real handler on the delegate passes")
        // REVIEW-2: two web views with a coordinator each, only one of which
        // handles a lost process. Counted across the file this passed.
        let oneOfTwo = """
            struct First: NSViewRepresentable {
                func makeNSView(context: Context) -> WKWebView {
                    let w = WKWebView()
                    w.navigationDelegate = context.coordinator
                    return w
                }
                final class Coordinator: NSObject, WKNavigationDelegate {
                    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
                }
            }
            struct Second: NSViewRepresentable {
                func makeNSView(context: Context) -> WKWebView {
                    let w = WKWebView()
                    w.navigationDelegate = context.coordinator
                    return w
                }
                final class Coordinator: NSObject, WKNavigationDelegate {
                    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}
                }
            }
            """
        XCTAssertFalse(Self.handlesLostContentProcess(oneOfTwo), "a second web view whose delegate ignores a lost process passed")
    }

    /// Every file that makes a WKWebView handles a lost content process, so
    /// the next web view added cannot go blank silently either.
    func test_everyWebViewHandlesALostContentProcess() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var makers: [String] = []
        var missing: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard Self.code(text).contains("WKWebView(") else { continue }
            makers.append(file.lastPathComponent)
            if !Self.handlesLostContentProcess(text) { missing.append(file.lastPathComponent) }
        }
        XCTAssertGreaterThanOrEqual(makers.count, 4, "control: the sweep found the files that make web views: \(makers)")
        XCTAssertEqual(missing.sorted(), [], "a web view with no handler for a lost content process")
    }

    /// An export whose page process ends fails at once, with a plain reason,
    /// instead of waiting out its timeout.
    func test_anExportFailsAtOnceWhenItsPageProcessEnds() {
        let waiter = LoadWaiter()
        var reason: String?
        waiter.onFinish = { reason = $0?.localizedDescription }
        waiter.webViewWebContentProcessDidTerminate(WKWebView(frame: .zero))
        XCTAssertEqual(reason, LoadWaiter.lostRendererReason, "the export was not told its page process ended")
    }

    // MARK: - SWEEP-13: the first open drew blank for about 8 s

    /// The preview says it is loading until its first navigation ends, and
    /// says so once.
    func test_thePreviewSaysItIsLoadingUntilItsFirstPageEnds() throws {
        let engine = DesignStudioEngine(store: DesignProjectStore(rootDir: dir.appendingPathComponent("store")))
        let coordinator = DesignPreviewView.Coordinator(engine: engine)
        var ended = 0
        coordinator.onFirstNavigationEnded = { ended += 1 }
        let web = WKWebView(frame: .zero)
        XCTAssertEqual(ended, 0, "control: nothing has loaded")
        coordinator.webView(web, didFinish: nil)
        XCTAssertEqual(ended, 1, "the loading state never learns the first page drew")
        coordinator.webView(web, didFinish: nil)
        XCTAssertEqual(ended, 1, "a later page ended the first load again")

        let failed = DesignPreviewView.Coordinator(engine: engine)
        var failedEnded = 0
        failed.onFirstNavigationEnded = { failedEnded += 1 }
        failed.webView(web, didFailProvisionalNavigation: nil, withError: URLError(.cannotOpenFile))
        XCTAssertEqual(failedEnded, 1, "a first page that failed left the loading state up for good")

        XCTAssertEqual(ToolReplyCopy.problems(in: DesignPreviewPane.loadingLine), [])
        // Design Studio shows the pane, which carries the loading state.
        let studio = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/DesignStudio/DesignStudioView.swift"), encoding: .utf8)
        XCTAssertTrue(studio.contains("DesignPreviewPane("), "Design Studio shows the preview without its loading state")
        XCTAssertFalse(studio.contains("DesignPreviewView("), "Design Studio shows the bare preview")
    }
}
