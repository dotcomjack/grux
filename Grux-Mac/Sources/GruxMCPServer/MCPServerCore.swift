import Foundation
import GruxMCPCore

// Standalone read-only MCP server core (shipped copy).
//
// This is the binary Claude Code (or any MCP client) spawns. It is a separate
// executable target on purpose: the Grux app pulls in AppKit and WebKit, and a
// stdio MCP server must stay a lean Foundation-only process, so it cannot
// import the app target.
//
// This file is a faithful, self-contained copy of the tested reference in the
// app target (Sources/Grux/DesignStudio/Export/MCPServerLogic.swift). Both are
// Foundation-only and JSONSerialization-based so they stay byte-for-byte
// comparable. Keep them in sync. Post-integration the shared core should move
// into a single Foundation-only library both targets depend on (see
// INTEGRATION.md) so this copy can be deleted.
//
// All tools are READ-ONLY: the server never writes to disk. House rules: no
// em/en dashes, and no internal vendor or model names in any tool name,
// description, or output an external agent could read.

struct MCPServerRoots {
    let documentsRoot: URL   // ~/Documents/Grux
    let supportRoot: URL     // ~/Library/Application Support/Grux

    static func live() -> MCPServerRoots {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        return MCPServerRoots(
            documentsRoot: home.appendingPathComponent("Documents/Grux", isDirectory: true),
            supportRoot: support.appendingPathComponent("Grux", isDirectory: true)
        )
    }

    var designDir: URL { documentsRoot.appendingPathComponent("design", isDirectory: true) }
    var designSystemsDir: URL { documentsRoot.appendingPathComponent("design-systems", isDirectory: true) }
    var skillsURL: URL { supportRoot.appendingPathComponent("skills.json") }
    var projectsCacheURL: URL { supportRoot.appendingPathComponent("projects-cache.json") }
}

final class MCPServerCore {
    static let protocolVersion = MCPWire.protocolVersion
    static let serverName = "grux-mcp"
    static let serverVersion = "1.0.0"

    let roots: MCPServerRoots
    private let readHandle: FileHandle
    private let writeHandle: FileHandle
    private let writeQueue = DispatchQueue(label: "grux.mcp.server.write")
    private let splitter = MCPLineSplitter()

    init(readHandle: FileHandle = .nullDevice, writeHandle: FileHandle = .nullDevice, roots: MCPServerRoots) {
        self.readHandle = readHandle
        self.writeHandle = writeHandle
        self.roots = roots
    }

    // MARK: - Transport

    // Blocking stdio serve loop. Reads newline-delimited JSON-RPC from the read
    // handle, writes responses on a serial queue, and exits cleanly on EOF.
    // Marks the write fd F_SETNOSIGPIPE so a dead reader surfaces as a caught
    // EPIPE, never a fatal signal.
    func run() {
        _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        let done = DispatchSemaphore(value: 0)
        readHandle.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                done.signal()
                return
            }
            for frame in self.drain(data) {
                self.writeQueue.async {
                    try? self.writeHandle.write(contentsOf: frame)
                }
            }
        }
        done.wait()
        // Flush any responses still queued so a fast EOF cannot exit the
        // process before the last writes reach stdout.
        writeQueue.sync {}
    }

    // MARK: - Framing

    func drain(_ data: Data) -> [Data] {
        var out: [Data] = []
        for line in splitter.feed(data) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard let response = handle(object) else { continue }
            if let frame = encode(response) { out.append(frame) }
        }
        return out
    }

    func encode(_ object: [String: Any]) -> Data? { MCPWire.encode(object) }

    // MARK: - Dispatch

    func handle(_ request: [String: Any]) -> [String: Any]? {
        let method = request["method"] as? String ?? ""
        let id = request["id"]
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return ok(id: id, result: [
                "protocolVersion": Self.protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": Self.serverVersion]
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return ok(id: id, result: [String: Any]())
        case "tools/list":
            return ok(id: id, result: ["tools": Self.toolDefinitions])
        case "tools/call":
            return handleToolCall(id: id, params: params)
        default:
            guard id != nil else { return nil }
            return error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func handleToolCall(id: Any?, params: [String: Any]) -> [String: Any]? {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "grux_list_design_projects":
            return ok(id: id, result: textResult(listDesignProjects()))
        case "grux_get_design_project":
            let slug = (arguments["slug"] as? String) ?? ""
            return ok(id: id, result: textResult(getDesignProject(slug: slug)))
        case "grux_list_design_systems":
            return ok(id: id, result: textResult(listDesignSystems()))
        case "grux_get_design_system":
            let slug = (arguments["slug"] as? String) ?? ""
            return ok(id: id, result: textResult(getDesignSystem(slug: slug)))
        case "grux_list_skills":
            return ok(id: id, result: textResult(listSkills()))
        case "grux_list_brands":
            return ok(id: id, result: textResult(listBrands()))
        default:
            return error(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    // MARK: - Tool implementations (read-only)

    private func listDesignProjects() -> String {
        let url = roots.designDir.appendingPathComponent("index.json")
        guard let entries = loadJSON(url) as? [[String: Any]], !entries.isEmpty else {
            return "No design projects found."
        }
        var lines: [String] = ["Design projects (\(entries.count)):"]
        for entry in entries {
            let slug = entry["slug"] as? String ?? "?"
            let title = entry["title"] as? String ?? slug
            let kind = entry["kind"] as? String ?? "prototype"
            let starred = (entry["starred"] as? Bool == true) ? " [starred]" : ""
            lines.append("- \(title) (slug: \(slug), kind: \(kind))\(starred)")
        }
        return lines.joined(separator: "\n")
    }

    private func getDesignProject(slug: String) -> String {
        guard !slug.isEmpty else { return "A slug is required." }
        let notFound = "No design project found for slug: \(slug)"
        // Reject a slug that could escape the design root before building a
        // path, then require the built directory (and the files under it) to
        // resolve strictly inside that root. getDesignProject reads
        // project.json directly rather than through the index, so it gates on
        // shape and containment, not on index membership.
        guard isSlugShapeSafe(slug) else { return notFound }
        let projectDir = roots.designDir.appendingPathComponent(slug, isDirectory: true)
        guard isContained(projectDir, within: roots.designDir) else { return notFound }
        let projectURL = projectDir.appendingPathComponent("project.json")
        guard isContained(projectURL, within: roots.designDir),
              let project = loadJSON(projectURL) as? [String: Any] else {
            return notFound
        }
        var lines: [String] = []
        lines.append("Title: \(project["title"] as? String ?? slug)")
        lines.append("Slug: \(project["slug"] as? String ?? slug)")
        lines.append("Kind: \(project["kind"] as? String ?? "prototype")")
        if let brand = project["brandSlug"] as? String { lines.append("Brand: \(brand)") }
        if let ds = project["designSystemFile"] as? String { lines.append("Design system: \(ds)") }
        if let tags = project["tags"] as? [String], !tags.isEmpty { lines.append("Tags: \(tags.joined(separator: ", "))") }

        let siteDir = projectDir.appendingPathComponent("site", isDirectory: true)
        let files = isContained(siteDir, within: roots.designDir)
            ? ((try? FileManager.default.contentsOfDirectory(atPath: siteDir.path))?.sorted() ?? [])
            : []
        if files.isEmpty {
            lines.append("Site files: none")
        } else {
            lines.append("Site files (\(files.count)): \(files.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private func listDesignSystems() -> String {
        let names = designSystemSlugs()
        guard !names.isEmpty else { return "No design systems found." }
        return "Design systems (\(names.count)):\n" + names.map { "- \($0)" }.joined(separator: "\n")
    }

    // The slugs listDesignSystems enumerates, factored out so getDesignSystem
    // can gate on the same set (only a listed design system may resolve).
    private func designSystemSlugs() -> [String] {
        let fm = FileManager.default
        var names: [String] = []
        guard let entries = try? fm.contentsOfDirectory(at: roots.designSystemsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return names
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                if entry.lastPathComponent == "incoming" {
                    let staged = (try? fm.contentsOfDirectory(atPath: entry.path))?.sorted() ?? []
                    for s in staged { names.append("incoming/\(s)") }
                } else if fm.fileExists(atPath: entry.appendingPathComponent("DESIGN.md").path) {
                    names.append(entry.lastPathComponent)
                }
            } else if entry.pathExtension.lowercased() == "md" {
                names.append(entry.deletingPathExtension().lastPathComponent)
            }
        }
        return names
    }

    private func getDesignSystem(slug: String) -> String {
        guard !slug.isEmpty else { return "A slug is required." }
        let notFound = "No design system found for slug: \(slug)"
        // Gate on slug shape and on the enumerated set before building a path,
        // so an unknown or hostile slug can never name a file to read.
        guard isSlugShapeSafe(slug), designSystemSlugs().contains(slug) else { return notFound }
        let fm = FileManager.default
        let root = roots.designSystemsDir
        let candidates = [
            root.appendingPathComponent(slug).appendingPathComponent("DESIGN.md"),
            root.appendingPathComponent("\(slug).md"),
            root.appendingPathComponent("incoming").appendingPathComponent(slug),
            root.appendingPathComponent("incoming").appendingPathComponent("\(slug).md")
        ]
        // Each candidate must still resolve inside the root, so a symlinked
        // entry cannot smuggle a read outside it.
        for url in candidates where isContained(url, within: root) && fm.fileExists(atPath: url.path) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            return String(text.prefix(8000))
        }
        return notFound
    }

    private func listSkills() -> String {
        guard let skills = loadJSON(roots.skillsURL) as? [[String: Any]], !skills.isEmpty else {
            return "No skills found."
        }
        var lines: [String] = ["Skills (\(skills.count)):"]
        for skill in skills {
            let name = skill["name"] as? String ?? "?"
            let trigger = skill["trigger"] as? String ?? ""
            lines.append("- \(name): \(trigger)")
        }
        return lines.joined(separator: "\n")
    }

    private func listBrands() -> String {
        guard let brands = loadJSON(roots.projectsCacheURL) as? [[String: Any]], !brands.isEmpty else {
            return "No brands found."
        }
        var lines: [String] = ["Brands (\(brands.count)):"]
        for brand in brands {
            let name = brand["name"] as? String ?? "?"
            let slug = brand["slug"] as? String ?? "?"
            let status = brand["status"] as? String ?? ""
            lines.append("- \(name) (slug: \(slug))\(status.isEmpty ? "" : ", status: \(status)")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Path containment (read-only safety)

    // A slug arrives from an external agent and is turned into an on-disk path.
    // Reject the shapes that let it escape its root before any path is built:
    // empty, absolute, home-relative, a parent-directory hop, or a stray null
    // or backslash. An interior "/" stays legal because a design system can
    // live under "incoming/<name>".
    private func isSlugShapeSafe(_ slug: String) -> Bool {
        if slug.isEmpty { return false }
        if slug.hasPrefix("/") || slug.hasPrefix("~") { return false }
        if slug.contains("..") { return false }
        if slug.contains("\0") || slug.contains("\\") { return false }
        return true
    }

    // True only when candidate, after standardizing and resolving symlinks,
    // lands inside root (resolved the same way). This is the real boundary
    // check: a symlink planted inside a root that points outward is resolved
    // and rejected here, not merely matched as a substring.
    private func isContained(_ candidate: URL, within root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let candidatePath = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    // MARK: - Response builders

    // Envelopes live in GruxMCPCore so both servers cannot drift into answering the same
    // protocol differently. These stay as thin names because the call sites read better.
    private func ok(id: Any?, result: [String: Any]) -> [String: Any] {
        MCPWire.ok(id: id, result: result)
    }

    private func error(id: Any?, code: Int, message: String) -> [String: Any] {
        MCPWire.error(id: id, code: code, message: message)
    }

    private func textResult(_ text: String) -> [String: Any] {
        MCPWire.textResult(text)
    }

    private func loadJSON(_ url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - Tool catalog

    static let toolDefinitions: [[String: Any]] = [
        [
            "name": "grux_list_design_projects",
            "description": "List the design projects saved in Grux (title, slug, kind).",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()]
        ],
        [
            "name": "grux_get_design_project",
            "description": "Get one design project's metadata and its site file listing.",
            "inputSchema": [
                "type": "object",
                "properties": ["slug": ["type": "string", "description": "The project slug."]],
                "required": ["slug"]
            ]
        ],
        [
            "name": "grux_list_design_systems",
            "description": "List the portable design systems available in Grux.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()]
        ],
        [
            "name": "grux_get_design_system",
            "description": "Get the full text of one design system by slug.",
            "inputSchema": [
                "type": "object",
                "properties": ["slug": ["type": "string", "description": "The design system slug."]],
                "required": ["slug"]
            ]
        ],
        [
            "name": "grux_list_skills",
            "description": "List the learned skills Grux has, with their triggers.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()]
        ],
        [
            "name": "grux_list_brands",
            "description": "List the brands and products Grux knows about.",
            "inputSchema": ["type": "object", "properties": [String: Any](), "required": [String]()]
        ]
    ]
}

// MCPServerLineSplitter moved to GruxMCPCore as MCPLineSplitter, 2026-08-28.
// The app's control socket needs the identical framing, and a second copy of a buffer
// that holds a partial line across reads is a second place to get it subtly wrong.

