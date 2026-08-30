import Foundation
#if canImport(WebKit)
import WebKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// Export pipeline for Design Studio projects. Turns a project's on-disk site/
// folder into shareable artifacts: a vector PDF, a full-page PNG, a portable
// ZIP of the whole project, and a best-effort Markdown transcription.
//
// The renderer is behind the HTMLRendering seam so the filename convention, the
// exports/ directory handling, the ZIP spawn, and the Markdown transcription
// are all unit-testable without ever touching WebKit. Only PDF and PNG need a
// real web engine, and both take an injectable renderer.
//
// Output convention (all four formats):
//   <project>/exports/<slug>-<yyyyMMdd-HHmmss>.<ext>
//   <project>/exports/<brandSlug>-<slug>-<yyyyMMdd-HHmmss>.<ext>   (brand set)
//
// House rules: no em/en dashes anywhere, no vendor or model names in output.

// The rendering seam. A live WebKit implementation drives an offscreen
// WKWebView; tests inject a fake that returns canned bytes.
@MainActor
protocol HTMLRendering {
    // Load indexURL (with read access fenced to allowedRoot) and return a
    // vector PDF of the rendered page.
    func renderPDF(indexURL: URL, allowedRoot: URL) async throws -> Data
    // Load indexURL and return a full-content-size PNG snapshot.
    func renderPNG(indexURL: URL, allowedRoot: URL) async throws -> Data
}

@MainActor
enum ExportPipeline {

    enum ExportError: Error, LocalizedError {
        case missingIndex(URL)
        case missingSite(URL)
        case renderTimeout
        case renderFailed(String)
        case zipFailed(Int32)
        case writeFailed(URL)
        case writesSuspended
        case webKitUnavailable

        var errorDescription: String? {
            switch self {
            case .missingIndex(let url): return "No index.html found at \(url.path)"
            case .missingSite(let url): return "No site folder found at \(url.path)"
            case .renderTimeout: return "Rendering the page timed out after 30 seconds"
            case .renderFailed(let m): return "Rendering failed: \(m)"
            case .zipFailed(let code): return "The zip step exited with status \(code)"
            case .writeFailed(let url): return "Could not write the export to \(url.path)"
            case .writesSuspended: return "A restore is in progress, so exports are paused"
            case .webKitUnavailable: return "WebKit is not available in this build"
            }
        }
    }

    // Everything an export needs. projectDir is the project root that contains
    // site/, exports/, and (optionally) versions/.
    struct Request {
        let projectDir: URL
        let slug: String
        let brandSlug: String?

        init(projectDir: URL, slug: String, brandSlug: String? = nil) {
            self.projectDir = projectDir
            self.slug = slug
            self.brandSlug = brandSlug
        }

        var siteDir: URL { projectDir.appendingPathComponent("site", isDirectory: true) }
        var indexURL: URL { siteDir.appendingPathComponent("index.html") }
    }

    // The default live renderer. Constructed lazily so tests that never call
    // PDF/PNG never instantiate WebKit.
    static func liveRenderer() -> HTMLRendering {
        #if canImport(WebKit)
        return WebKitRenderer()
        #else
        return UnavailableRenderer()
        #endif
    }

    // MARK: - PDF

    @discardableResult
    static func exportPDF(_ request: Request, renderer: HTMLRendering? = nil) async throws -> URL {
        guard !Persistence.writesSuspended else { throw ExportError.writesSuspended }
        try validateSite(request)
        let engine = renderer ?? liveRenderer()
        let data = try await engine.renderPDF(indexURL: request.indexURL, allowedRoot: request.siteDir)
        return try writeOutput(data, request: request, ext: "pdf")
    }

    // MARK: - PNG

    @discardableResult
    static func exportPNG(_ request: Request, renderer: HTMLRendering? = nil) async throws -> URL {
        guard !Persistence.writesSuspended else { throw ExportError.writesSuspended }
        try validateSite(request)
        let engine = renderer ?? liveRenderer()
        let data = try await engine.renderPNG(indexURL: request.indexURL, allowedRoot: request.siteDir)
        return try writeOutput(data, request: request, ext: "png")
    }

    // MARK: - ZIP

    // Zip the whole project (site/, project.json, DESIGN.md, etc.) into a
    // portable archive, excluding the regenerable versions/ snapshots and the
    // exports/ folder itself. Built in a temp location and moved into place so
    // the archive never tries to include itself.
    @discardableResult
    static func exportZIP(_ request: Request) async throws -> URL {
        guard !Persistence.writesSuspended else { throw ExportError.writesSuspended }
        guard FileManager.default.fileExists(atPath: request.projectDir.path) else {
            throw ExportError.missingSite(request.projectDir)
        }
        let outputURL = try exportsURL(request: request, ext: "zip")
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-export-\(UUID().uuidString).zip")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = request.projectDir
        process.arguments = [
            "-r", "-q", tmpURL.path, ".",
            "-x", "versions/*", "-x", "./versions/*",
            "-x", "exports/*", "-x", "./exports/*"
        ]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()
        // zip exit code 12 means "nothing to do" which can happen on an empty
        // project; treat only a genuine failure (nonzero and no output file) as
        // an error.
        if process.terminationStatus != 0 && !FileManager.default.fileExists(atPath: tmpURL.path) {
            throw ExportError.zipFailed(process.terminationStatus)
        }
        // Move into exports/. Remove any stale file at the destination first.
        try? FileManager.default.removeItem(at: outputURL)
        do {
            try FileManager.default.moveItem(at: tmpURL, to: outputURL)
        } catch {
            throw ExportError.writeFailed(outputURL)
        }
        return outputURL
    }

    // MARK: - Markdown

    // Walk the site/ folder and transcribe each HTML file into readable
    // Markdown, best effort: headings become #, paragraphs become text, list
    // items become bullets, script/style are dropped. index.html sorts first.
    @discardableResult
    static func exportMarkdown(_ request: Request) throws -> URL {
        guard !Persistence.writesSuspended else { throw ExportError.writesSuspended }
        try validateSite(request)
        let fm = FileManager.default
        let htmlFiles = (try? fm.contentsOfDirectory(at: request.siteDir, includingPropertiesForKeys: nil))?
            .filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
            .sorted { a, b in
                if a.lastPathComponent == "index.html" { return true }
                if b.lastPathComponent == "index.html" { return false }
                return a.lastPathComponent < b.lastPathComponent
            } ?? []

        var doc = "# \(request.slug)\n\n"
        if htmlFiles.isEmpty {
            doc += "_No HTML files were found in this project's site folder._\n"
        }
        for file in htmlFiles {
            guard let html = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if htmlFiles.count > 1 {
                doc += "## \(file.lastPathComponent)\n\n"
            }
            doc += MarkdownTranscriber.markdown(fromHTML: html)
            doc += "\n\n"
        }

        let outputURL = try exportsURL(request: request, ext: "md")
        guard let data = doc.data(using: .utf8), Persistence.write(data, to: outputURL) else {
            throw ExportError.writeFailed(outputURL)
        }
        return outputURL
    }

    // MARK: - Shared helpers

    private static func validateSite(_ request: Request) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: request.siteDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ExportError.missingSite(request.siteDir)
        }
    }

    private static func writeOutput(_ data: Data, request: Request, ext: String) throws -> URL {
        let outputURL = try exportsURL(request: request, ext: ext)
        guard Persistence.write(data, to: outputURL) else {
            throw ExportError.writeFailed(outputURL)
        }
        return outputURL
    }

    static func exportsURL(request: Request, ext: String) throws -> URL {
        let exportsDir = request.projectDir.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        return exportsDir.appendingPathComponent(fileName(request: request, ext: ext))
    }

    static func fileName(request: Request, ext: String) -> String {
        let stamp = timestamp()
        if let brand = request.brandSlug, !brand.isEmpty {
            return "\(brand)-\(request.slug)-\(stamp).\(ext)"
        }
        return "\(request.slug)-\(stamp).\(ext)"
    }

    private static func timestamp() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df.string(from: Date())
    }
}

// MARK: - Markdown transcription

// Reuses the HTMLMiniParser node tree (CodeExport.swift) and flattens it into
// Markdown. Deliberately lossy and best-effort: it is a readable transcript of
// a design, not a round-trippable format.
enum MarkdownTranscriber {
    static func markdown(fromHTML html: String) -> String {
        let body = extractBody(from: html)
        let nodes = HTMLMiniParser.parse(body)
        var lines: [String] = []
        for node in nodes { emit(node, into: &lines) }
        // Collapse runs of blank lines to a single blank line.
        var out: [String] = []
        for line in lines {
            if line.isEmpty, out.last == "" { continue }
            out.append(line)
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func emit(_ node: HTMLNode, into lines: inout [String]) {
        switch node.kind {
        case .text(let raw):
            let text = collapse(raw)
            if !text.isEmpty { lines.append(text); lines.append("") }
        case .element(let tag, let attributes):
            switch tag {
            case "h1": lines.append("# " + inner(node)); lines.append("")
            case "h2": lines.append("## " + inner(node)); lines.append("")
            case "h3": lines.append("### " + inner(node)); lines.append("")
            case "h4": lines.append("#### " + inner(node)); lines.append("")
            case "h5": lines.append("##### " + inner(node)); lines.append("")
            case "h6": lines.append("###### " + inner(node)); lines.append("")
            case "p", "blockquote":
                let t = inner(node)
                if !t.isEmpty { lines.append(tag == "blockquote" ? "> " + t : t); lines.append("") }
            case "li":
                let t = inner(node)
                if !t.isEmpty { lines.append("- " + t) }
            case "a":
                let t = inner(node)
                if let href = attributes["href"], !t.isEmpty {
                    lines.append("[\(t)](\(href))"); lines.append("")
                } else if !t.isEmpty {
                    lines.append(t); lines.append("")
                }
            case "img":
                let alt = attributes["alt"] ?? "image"
                let src = attributes["src"] ?? ""
                lines.append("![\(alt)](\(src))"); lines.append("")
            case "br", "hr":
                lines.append("")
            default:
                for child in node.children { emit(child, into: &lines) }
            }
        }
    }

    private static func inner(_ node: HTMLNode) -> String {
        var acc = ""
        gather(node, into: &acc)
        return collapse(acc)
    }

    private static func gather(_ node: HTMLNode, into acc: inout String) {
        switch node.kind {
        case .text(let raw): acc += raw
        case .element: for child in node.children { gather(child, into: &acc); acc += " " }
        }
    }

    private static func collapse(_ s: String) -> String {
        var decoded = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (k, v) in map { decoded = decoded.replacingOccurrences(of: k, with: v) }
        let parts = decoded.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func extractBody(from html: String) -> String {
        let lower = html.lowercased()
        guard let bodyOpen = lower.range(of: "<body") else { return html }
        guard let openEnd = html.range(of: ">", range: bodyOpen.upperBound..<html.endIndex) else { return html }
        let afterOpen = openEnd.upperBound
        if let closeRange = lower.range(of: "</body>", range: afterOpen..<html.endIndex) {
            return String(html[afterOpen..<closeRange.lowerBound])
        }
        return String(html[afterOpen...])
    }
}

// MARK: - WebKit live renderer

#if canImport(WebKit)
// Drives an offscreen WKWebView through a fenced local load and produces vector
// PDF or full-page PNG. Short-lived: one instance per export call. Network is
// blocked and reads are fenced to the artifact directory.
@MainActor
final class WebKitRenderer: NSObject, HTMLRendering {
    private let renderTimeout: TimeInterval = 30

    func renderPDF(indexURL: URL, allowedRoot: URL) async throws -> Data {
        let webView = try await loadedWebView(indexURL: indexURL, allowedRoot: allowedRoot)
        return try await withDeadline(renderTimeout) { resume in
            let config = WKPDFConfiguration()
            webView.createPDF(configuration: config) { result in
                switch result {
                case .success(let data): resume(.success(data))
                case .failure(let error): resume(.failure(ExportPipeline.ExportError.renderFailed(error.localizedDescription)))
                }
            }
        }
    }

    func renderPNG(indexURL: URL, allowedRoot: URL) async throws -> Data {
        let webView = try await loadedWebView(indexURL: indexURL, allowedRoot: allowedRoot)
        // Resize the offscreen view to the full content size so the snapshot is
        // not clipped to the initial viewport.
        if let height = try? await evalDouble(webView, "document.documentElement.scrollHeight"),
           let width = try? await evalDouble(webView, "document.documentElement.scrollWidth") {
            let w = max(width, 320)
            let h = max(height, 320)
            webView.frame = CGRect(x: 0, y: 0, width: w, height: h)
            // Let layout settle before the snapshot.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        let image: NSImage = try await withDeadline(renderTimeout) { resume in
            let config = WKSnapshotConfiguration()
            config.rect = .null // full content
            webView.takeSnapshot(with: config) { image, error in
                if let image {
                    resume(.success(image))
                } else {
                    resume(.failure(ExportPipeline.ExportError.renderFailed(error?.localizedDescription ?? "snapshot returned no image")))
                }
            }
        }
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw ExportPipeline.ExportError.renderFailed("could not encode PNG")
        }
        return png
    }

    // MARK: - Load

    private func loadedWebView(indexURL: URL, allowedRoot: URL) async throws -> WKWebView {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw ExportPipeline.ExportError.missingIndex(indexURL)
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)

        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let resume: (Error?) -> Void = { error in
                guard !resumed else { return }
                resumed = true
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            waiter.onFinish = { error in
                if let error {
                    resume(ExportPipeline.ExportError.renderFailed(error.localizedDescription))
                } else {
                    resume(nil)
                }
            }
            // Fail-closed timeout so a hung load never wedges the export.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(self.renderTimeout * 1_000_000_000))
                resume(ExportPipeline.ExportError.renderTimeout)
            }
            webView.loadFileURL(indexURL, allowingReadAccessTo: allowedRoot)
        }
        // Keep the delegate alive until here.
        withExtendedLifetime(waiter) {}
        return webView
    }

    private func evalDouble(_ webView: WKWebView, _ js: String) async throws -> Double {
        try await withDeadline(renderTimeout) { resume in
            webView.evaluateJavaScript(js) { result, error in
                if let number = result as? NSNumber {
                    resume(.success(number.doubleValue))
                } else if let error {
                    resume(.failure(error))
                } else {
                    resume(.failure(ExportPipeline.ExportError.renderFailed("javascript returned no value")))
                }
            }
        }
    }

    // Race a WebKit completion against a deadline. The body wires a WebKit call
    // whose callback resumes via `resume`; whichever fires first (the callback
    // or the timeout) wins and the continuation resumes exactly once. Fails
    // closed with renderTimeout so a page that loads but never finishes
    // rendering can never hang an export forever. Mirrors the resumed-flag
    // idiom in loadedWebView; every access is on the main actor.
    private func withDeadline<T>(
        _ timeout: TimeInterval,
        _ body: (@escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            var resumed = false
            let resume: (Result<T, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                resume(.failure(ExportPipeline.ExportError.renderTimeout))
            }
            body(resume)
        }
    }
}

// WKNavigationDelegate captured off the MainActor: WebKit calls back on the
// main thread and we only touch the plain closure, so no isolation is needed.
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    var onFinish: ((Error?) -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish?(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish?(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFinish?(error)
    }

    // Only allow the initial local file load and about: schemes. Everything
    // else (a generated page trying to phone home) is cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        if scheme == "file" || scheme == "about" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }
}
#else
@MainActor
final class UnavailableRenderer: HTMLRendering {
    func renderPDF(indexURL: URL, allowedRoot: URL) async throws -> Data {
        throw ExportPipeline.ExportError.webKitUnavailable
    }
    func renderPNG(indexURL: URL, allowedRoot: URL) async throws -> Data {
        throw ExportPipeline.ExportError.webKitUnavailable
    }
}
#endif
