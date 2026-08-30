import Foundation

// Importer for a competitor design tool's export ZIP. The archive is a static
// web bundle (an index HTML plus co-located CSS, JS, and asset files). We do
// not parse any proprietary project metadata the tool may embed: we take the
// rendered web artifact and map it into a fresh Grux design project.
//
// Tolerance is the whole point of an importer: unknown files are never dropped,
// they are copied under site/assets/ so nothing is lost and the page still
// renders from disk.
enum ClaudeDesignImporter {

    enum ImportError: Error, LocalizedError {
        case archiveMissing(URL)
        case unzipFailed(Int32)
        case noHTMLFound

        var errorDescription: String? {
            switch self {
            case .archiveMissing(let url): return "No archive found at \(url.path)"
            case .unzipFailed(let code): return "The unzip step exited with status \(code)"
            case .noHTMLFound: return "The archive contained no HTML file to import"
            }
        }
    }

    struct Result {
        let slug: String
        let projectDir: URL
        let fileCount: Int
    }

    // Import a design-export ZIP into designRoot (defaults to the real
    // ~/Documents/Grux/design). Tests pass a temp designRoot.
    @discardableResult
    static func importArchive(
        at zipURL: URL,
        into designRoot: URL = DesignImportSupport.defaultDesignRoot(),
        title: String? = nil
    ) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: zipURL.path) else { throw ImportError.archiveMissing(zipURL) }

        // Unzip to a scratch directory.
        let scratch = fm.temporaryDirectory.appendingPathComponent("grux-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", zipURL.path, "-d", scratch.path]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        unzip.standardError = pipe
        try unzip.run()
        unzip.waitUntilExit()
        // unzip returns 1 for non-fatal warnings; only fail when nothing landed.
        let extracted = (try? fm.contentsOfDirectory(atPath: scratch.path))?.isEmpty == false
        if unzip.terminationStatus > 1 && !extracted {
            throw ImportError.unzipFailed(unzip.terminationStatus)
        }

        // Some archives wrap everything in a single top-level folder; unwrap it
        // so relative paths stay shallow.
        let contentRoot = DesignImportSupport.unwrapSingleRoot(scratch)

        // Find the main HTML file (index.html wins, else the shallowest .html).
        let allFiles = DesignImportSupport.recursiveFiles(under: contentRoot)
        let htmlFiles = allFiles.filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
        guard !htmlFiles.isEmpty else { throw ImportError.noHTMLFound }

        // Build a unique slug and the project folder.
        let baseName = title ?? contentRoot.lastPathComponent
        let slug = DesignImportSupport.uniqueSlug(base: baseName, in: designRoot)
        let projectDir = designRoot.appendingPathComponent(slug, isDirectory: true)
        let siteDir = projectDir.appendingPathComponent("site", isDirectory: true)
        try fm.createDirectory(at: siteDir, withIntermediateDirectories: true)

        // Copy every file. Recognized web files keep their relative path so the
        // page renders; unknown files land flattened under site/assets/.
        var copied = 0
        for file in allFiles {
            let rel = DesignImportSupport.relativePath(of: file, under: contentRoot)
            let destination: URL
            if DesignImportSupport.isWebFile(file) {
                destination = siteDir.appendingPathComponent(rel)
            } else {
                destination = siteDir.appendingPathComponent("assets", isDirectory: true)
                    .appendingPathComponent(file.lastPathComponent)
            }
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            if (try? fm.copyItem(at: file, to: destination)) != nil { copied += 1 }
        }

        // Guarantee a site/index.html so the preview and exporter find an entry.
        DesignImportSupport.ensureIndexHTML(in: siteDir, mainHTML: DesignImportSupport.pickMainHTML(htmlFiles, under: contentRoot))

        // Write project.json using the shared Design Studio model.
        let project = DesignImportSupport.makeProject(slug: slug, title: baseName, tags: ["imported"])
        DesignImportSupport.writeProjectJSON(project, to: projectDir)

        return Result(slug: slug, projectDir: projectDir, fileCount: copied)
    }
}

// MARK: - Shared import support

// Helpers shared by the ZIP importer and the directory importer. Kept in one
// place so slug generation, project.json writing, and file classification stay
// identical across importers.
enum DesignImportSupport {

    static func defaultDesignRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Grux/design", isDirectory: true)
    }

    static func defaultDesignSystemsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Grux/design-systems", isDirectory: true)
    }

    private static let webExtensions: Set<String> = [
        "html", "htm", "css", "js", "mjs", "cjs", "json", "map", "txt", "md",
        "svg", "png", "jpg", "jpeg", "gif", "webp", "avif", "ico", "bmp",
        "woff", "woff2", "ttf", "otf", "eot"
    ]

    static func isWebFile(_ url: URL) -> Bool {
        webExtensions.contains(url.pathExtension.lowercased())
    }

    // All regular files under a directory, recursively, skipping hidden files
    // and the macOS resource-fork noise.
    static func recursiveFiles(under root: URL) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == ".DS_Store" { continue }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    // If a directory holds exactly one entry and it is a folder, treat that
    // folder as the real content root (archives often add a wrapper folder).
    static func unwrapSingleRoot(_ dir: URL) -> URL {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]),
              entries.count == 1,
              (try? entries[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return dir
        }
        return entries[0]
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let urlComponents = url.standardizedFileURL.pathComponents
        if urlComponents.count > rootComponents.count,
           Array(urlComponents.prefix(rootComponents.count)) == rootComponents {
            return urlComponents.dropFirst(rootComponents.count).joined(separator: "/")
        }
        return url.lastPathComponent
    }

    static func pickMainHTML(_ htmlFiles: [URL], under root: URL) -> URL? {
        if let index = htmlFiles.first(where: { $0.lastPathComponent.lowercased() == "index.html" }) {
            return index
        }
        // Shallowest path wins as the entry point.
        return htmlFiles.min { relativePath(of: $0, under: root).components(separatedBy: "/").count
            < relativePath(of: $1, under: root).components(separatedBy: "/").count }
    }

    // Ensure site/index.html exists. If the main HTML came in under a different
    // name or a subfolder, copy it to site/index.html so the entry point is
    // predictable for the preview and exporter.
    static func ensureIndexHTML(in siteDir: URL, mainHTML: URL?) {
        let fm = FileManager.default
        let indexURL = siteDir.appendingPathComponent("index.html")
        guard !fm.fileExists(atPath: indexURL.path), let mainHTML else { return }
        // mainHTML points at the SOURCE tree; the copied twin lives under site/
        // at the same relative path, but we do not know that path here, so copy
        // straight from the source file which is still on disk at call time.
        try? fm.copyItem(at: mainHTML, to: indexURL)
    }

    static func sanitizeSlug(_ raw: String) -> String {
        var out = ""
        var lastDash = true
        for ch in raw.lowercased() {
            if (ch.isLetter && ch.isASCII) || (ch.isNumber && ch.isASCII) {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        if out.isEmpty { out = "imported-design" }
        if out.count > 48 { out = String(out.prefix(48)) }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    // A slug that does not collide with an existing project folder.
    static func uniqueSlug(base: String, in designRoot: URL) -> String {
        let fm = FileManager.default
        let root = sanitizeSlug(base)
        var candidate = root
        var n = 2
        while fm.fileExists(atPath: designRoot.appendingPathComponent(candidate).path) {
            candidate = "\(root)-\(n)"
            n += 1
        }
        return candidate
    }

    static func makeProject(slug: String, title: String, kind: DesignArtifactKind = .prototype, brandSlug: String? = nil, tags: [String] = []) -> DesignProject {
        DesignProject(slug: slug, title: title, kind: kind, brandSlug: brandSlug, tags: tags)
    }

    static func writeProjectJSON(_ project: DesignProject, to projectDir: URL) {
        try? FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let url = projectDir.appendingPathComponent("project.json")
        Persistence.save(project, to: url)
    }
}
