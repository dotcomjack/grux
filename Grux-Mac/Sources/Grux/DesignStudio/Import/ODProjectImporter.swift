import Foundation

// Importer for a competitor design tool's on-disk PROJECT DIRECTORY (not a
// ZIP). Such a project directory typically mixes three kinds of content:
//   1. DESIGN.md portable design-system files (one or more, anywhere in the
//      tree). These are the valuable, portable part.
//   2. Rendered HTML artifact folders (an index plus co-located web assets).
//   3. Proprietary project metadata, usually a SQLite database plus binary
//      caches.
//
// What v1 IMPORTS:
//   - Every DESIGN.md it finds, copied into the design-systems incoming/
//     staging folder for the design-system store to ingest. The returned list
//     lets the caller drive that ingestion.
//   - The HTML artifacts and their co-located web assets, mapped into a new
//     Grux design project's site/ folder (only when at least one HTML file is
//     present).
//
// What v1 does NOT import (documented so callers do not expect it):
//   - The proprietary SQLite metadata database and any binary caches. Their
//     schema is undocumented and unstable; parsing it is out of scope for v1.
//     We take only the portable, human-meaningful artifacts (DESIGN.md + HTML).
enum ODProjectImporter {

    enum ImportError: Error, LocalizedError {
        case sourceMissing(URL)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let url): return "No project directory found at \(url.path)"
            }
        }
    }

    struct Result {
        // nil when the project had no HTML artifacts to build a project from.
        let slug: String?
        let projectDir: URL?
        // Staged DESIGN.md copies, for the design-system store to ingest.
        let designSystemFiles: [URL]
        let htmlFileCount: Int
    }

    @discardableResult
    static func importProject(
        at sourceDir: URL,
        into designRoot: URL = DesignImportSupport.defaultDesignRoot(),
        designSystemsRoot: URL = DesignImportSupport.defaultDesignSystemsRoot(),
        title: String? = nil
    ) throws -> Result {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ImportError.sourceMissing(sourceDir)
        }

        let allFiles = DesignImportSupport.recursiveFiles(under: sourceDir)

        // 1. Stage every DESIGN.md into design-systems/incoming/.
        let incoming = designSystemsRoot.appendingPathComponent("incoming", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        var staged: [URL] = []
        let designDocs = allFiles.filter { $0.lastPathComponent.lowercased() == "design.md" }
        for doc in designDocs {
            // Prefix with the containing folder name to keep multiple DESIGN.md
            // files from colliding in the flat staging folder.
            let parent = doc.deletingLastPathComponent().lastPathComponent
            let stem = DesignImportSupport.sanitizeSlug(parent.isEmpty ? "design" : parent)
            var dest = incoming.appendingPathComponent("\(stem)-DESIGN.md")
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = incoming.appendingPathComponent("\(stem)-\(n)-DESIGN.md")
                n += 1
            }
            if (try? fm.copyItem(at: doc, to: dest)) != nil { staged.append(dest) }
        }

        // 2. Copy HTML artifacts and their co-located web assets into site/.
        let htmlFiles = allFiles.filter { ["html", "htm"].contains($0.pathExtension.lowercased()) }
        guard !htmlFiles.isEmpty else {
            // Design systems still imported; no renderable project to create.
            return Result(slug: nil, projectDir: nil, designSystemFiles: staged, htmlFileCount: 0)
        }

        // Directories that contain at least one HTML file: their web assets are
        // considered part of an artifact and come along.
        let htmlDirs = Set(htmlFiles.map { $0.deletingLastPathComponent().standardizedFileURL.path })

        let baseName = title ?? sourceDir.lastPathComponent
        let slug = DesignImportSupport.uniqueSlug(base: baseName, in: designRoot)
        let projectDir = designRoot.appendingPathComponent(slug, isDirectory: true)
        let siteDir = projectDir.appendingPathComponent("site", isDirectory: true)
        try fm.createDirectory(at: siteDir, withIntermediateDirectories: true)

        var htmlCount = 0
        for file in allFiles {
            let inHTMLDir = htmlDirs.contains(file.deletingLastPathComponent().standardizedFileURL.path)
            let isHTML = ["html", "htm"].contains(file.pathExtension.lowercased())
            let isCoLocatedAsset = inHTMLDir && DesignImportSupport.isWebFile(file)
            guard isHTML || isCoLocatedAsset else { continue }
            let rel = DesignImportSupport.relativePath(of: file, under: sourceDir)
            let dest = siteDir.appendingPathComponent(rel)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            if (try? fm.copyItem(at: file, to: dest)) != nil, isHTML { htmlCount += 1 }
        }

        DesignImportSupport.ensureIndexHTML(in: siteDir, mainHTML: DesignImportSupport.pickMainHTML(htmlFiles, under: sourceDir))

        let firstDesignSystem = staged.first?.lastPathComponent
        var project = DesignImportSupport.makeProject(slug: slug, title: baseName, tags: ["imported"])
        project.designSystemFile = firstDesignSystem
        DesignImportSupport.writeProjectJSON(project, to: projectDir)

        return Result(slug: slug, projectDir: projectDir, designSystemFiles: staged, htmlFileCount: htmlCount)
    }
}
