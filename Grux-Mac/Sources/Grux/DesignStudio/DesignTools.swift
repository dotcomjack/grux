import Foundation

// Claude-tool adapter for the Design Studio. Same shape as DocumentTools /
// AgentTools: claudeTools() + toolNames + async dispatch returning "ok:" /
// "error:" strings. NOT registered in ChatService here; the integrator wires
// registration + dispatch per INTEGRATION.md (integration manifest rule).
enum DesignTools {

    static let toolNames: Set<String> = [
        "design_create_project",
        "design_generate",
        "design_list_projects",
        "design_open_project",
        "design_restore_version"
    ]

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "design_create_project",
                description: "Create a new Design Studio project (a folder of web artifact files the user can preview and iterate on). Use when they ask to build a landing page, prototype, deck, or live dashboard. Returns the project id. Follow with design_generate to actually build it.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Short project title, under 80 chars."],
                        "kind": ["type": "string", "enum": ["prototype", "deck", "dashboard"], "description": "Artifact kind. Default prototype. For raster images or video use creative_render_image (Media Studio)."],
                        "brand": ["type": "string", "description": "Optional brand slug from the project registry, so that brand's design system is applied. Omit when there is no brand."],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Optional tags."]
                    ],
                    "required": ["title"]
                ]
            ),
            ClaudeTool(
                name: "design_generate",
                description: "Run a generation on an existing Design Studio project: the model writes the site/ files (index.html plus CSS/JS) from your brief. Streams in the Design Studio tab; snapshots the prior version so it stays reversible. Generation runs on the API route. The subscription and local model routes are the user's choice inside the Design Studio, not selectable from chat. Create the project first with design_create_project.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "Project id OR exact title OR title substring."],
                        "brief": ["type": "string", "description": "What to build or change. Be specific: audience, sections, tone, brand."]
                    ],
                    "required": ["project", "brief"]
                ]
            ),
            ClaudeTool(
                name: "design_list_projects",
                description: "List the user's Design Studio projects (ids, titles, kinds, brands, starred, updated dates). Use before creating a project to avoid duplicates, or when they mention 'that prototype' / 'my landing page'.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "Optional search over titles, slugs, previews, tags."],
                        "limit": ["type": "integer", "description": "Max rows. Default 20, max 50."]
                    ]
                ]
            ),
            ClaudeTool(
                name: "design_open_project",
                description: "Open the Design Studio tab and select a project so the user can see its live preview and version history.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "Project id OR exact title OR title substring."]
                    ],
                    "required": ["project"]
                ]
            ),
            ClaudeTool(
                name: "design_restore_version",
                description: "Restore a Design Studio project to an earlier snapshot. With no version id, restores the most recent prior snapshot. The restore itself is snapshotted first, so it is undoable.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "project": ["type": "string", "description": "Project id OR exact title OR title substring."],
                        "version": ["type": "string", "description": "Optional version id. Omit to restore the most recent prior snapshot."]
                    ],
                    "required": ["project"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "design_create_project":
            let title = (input["title"] as? String) ?? ""
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "error: empty title"
            }
            let kind = DesignArtifactKind(rawValue: (input["kind"] as? String) ?? "prototype") ?? .prototype
            let brand = (input["brand"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tags = (input["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
            return await MainActor.run { () -> String in
                let proj = DesignProjectStore.shared.create(
                    title: title,
                    kind: kind,
                    brandSlug: (brand?.isEmpty ?? true) ? nil : brand,
                    tags: tags
                )
                return "ok: created design project '\(proj.title)' id=\(proj.id.uuidString) slug=\(proj.slug)"
            }

        case "design_generate":
            let hint = (input["project"] as? String) ?? ""
            let brief = (input["brief"] as? String) ?? ""
            guard !brief.trimmingCharacters(in: .whitespaces).isEmpty else {
                return "error: empty brief"
            }
            // A chat-invoked generation is ALWAYS the api route (an ordinary,
            // ungated chat turn that spends API tokens). The route is deliberately
            // NOT read from model input: subscriptionCLI/localModel spawn a local
            // Claude Code subprocess with bypassPermissions, so choosing them must
            // stay a human action in the Design Studio UI, never a prompt-injectable
            // field. JaxToolGate carries a defense-in-depth guard that backs this up.
            let route = ExecutionRoute.api
            return await MainActor.run { () -> String in
                guard let proj = DesignProjectStore.shared.resolve(hint) else {
                    return "error: no design project matched '\(hint)'. Create one first with design_create_project."
                }
                let engine = DesignStudioEngine.shared
                guard !engine.isGenerating else {
                    return "error: a design generation is already running. Wait for it to finish."
                }
                let config = DesignRunConfig(route: route, brandSlug: proj.brandSlug)
                engine.pendingOpenProjectId = proj.id
                AppState.shared.requestedTab = "designStudio"
                let projectId = proj.id
                Task { await engine.generate(projectId: projectId, brief: brief, config: config) }
                return "ok: started generation on '\(proj.title)'. Opening the Design Studio tab so the user can watch it build."
            }

        case "design_list_projects":
            let query = input["query"] as? String
            let limit = min(50, max(1, (input["limit"] as? Int) ?? 20))
            return await MainActor.run { () -> String in
                let rows = DesignProjectStore.shared.list(query: query)
                if rows.isEmpty { return "(no design projects yet)" }
                return rows.prefix(limit).map { formatRow($0) }.joined(separator: "\n")
            }

        case "design_open_project":
            let hint = (input["project"] as? String) ?? ""
            return await MainActor.run { () -> String in
                guard let proj = DesignProjectStore.shared.resolve(hint) else {
                    return "error: no design project matched '\(hint)'"
                }
                DesignStudioEngine.shared.pendingOpenProjectId = proj.id
                AppState.shared.requestedTab = "designStudio"
                return "ok: opened '\(proj.title)' in the Design Studio"
            }

        case "design_restore_version":
            let hint = (input["project"] as? String) ?? ""
            let versionHint = (input["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return await MainActor.run { () -> String in
                let store = DesignProjectStore.shared
                guard let proj = store.resolve(hint) else {
                    return "error: no design project matched '\(hint)'"
                }
                let engine = DesignStudioEngine.shared
                if engine.isGenerating, engine.runningProjectId == proj.id {
                    return "error: a generation is running on this project, stop it before restoring"
                }
                let versions = store.versions(id: proj.id)
                guard !versions.isEmpty else {
                    return "error: '\(proj.title)' has no version history to restore."
                }
                let target: DesignVersion
                if let versionHint, !versionHint.isEmpty {
                    guard let id = UUID(uuidString: versionHint),
                          let match = versions.first(where: { $0.id == id }) else {
                        return "error: no version '\(versionHint)' on '\(proj.title)'"
                    }
                    target = match
                } else {
                    target = versions.last!   // most recent prior snapshot
                }
                guard store.restore(id: proj.id, versionId: target.id) else {
                    return "error: restore failed for '\(proj.title)'"
                }
                return "ok: restored '\(proj.title)' to snapshot '\(target.label)' from \(Self.stamp(target.savedAt))"
            }

        default:
            return "error: unknown design tool '\(name)'"
        }
    }

    // MARK: - Formatting

    @MainActor
    private static func formatRow(_ proj: DesignProject) -> String {
        var flags: [String] = [proj.kind.displayName]
        if let brand = proj.brandSlug, !brand.isEmpty { flags.append("brand: \(brand)") }
        if proj.starred { flags.append("starred") }
        if !proj.tags.isEmpty { flags.append("tags: " + proj.tags.joined(separator: ", ")) }
        let tail = proj.preview.map { "\n  -> \($0.prefix(110))" } ?? ""
        return "- id=\(proj.id.uuidString) . \(proj.title) . \(stamp(proj.updatedAt)) . \(flags.joined(separator: " . "))\(tail)"
    }

    private static func stamp(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MMM d h:mm a"
        df.timeZone = .current
        return df.string(from: date)
    }
}
