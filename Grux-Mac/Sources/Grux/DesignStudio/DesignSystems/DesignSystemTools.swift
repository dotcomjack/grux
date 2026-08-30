import Foundation

// Claude-tool adapter for portable design systems. Same shape as DocumentTools
// and AgentTools: a claudeTools() catalog, a toolNames set, and an async
// dispatch(name:input:) that hops to the main actor and returns plain
// "ok: ..." / "error: ..." strings.
//
// NOTE: this family is deliberately NOT registered in ChatService here. The
// integration manifest (INTEGRATION.md) carries the two lines the studio-core
// stream adds to ChatService.allTools() and dispatchTool() so registration
// lands in exactly one place.
enum DesignSystemTools {

    static let toolNames: Set<String> = [
        "design_system_list",
        "design_system_activate",
        "design_system_generate_brand",
        "design_system_import"
    ]

    static func claudeTools() -> [ClaudeTool] {
        [
            ClaudeTool(
                name: "design_system_list",
                description: "List the portable design systems Grux has generated or imported (slug + name). Use when the user asks 'what design systems do we have', before activating one for a brand, or to confirm a generate/import landed. Each system is a DESIGN.md with color, typography, spacing, layout, components, motion, voice, brand, and anti-patterns sections.",
                inputSchema: [
                    "type": "object",
                    "properties": [:]
                ]
            ),
            ClaudeTool(
                name: "design_system_generate_brand",
                description: "Generate (and save + activate) a portable DESIGN.md design system for one brand, seeded from that brand's real palette, style notes, product facts, and the baked house law (tight-control component scale, copy law, anti-patterns). Pass brand 'all' to generate systems for every known brand (curated brands plus every active registry project) in one call. Use when the user says 'make a design system for X', 'give <brand> a DESIGN.md', 'generate design systems for everything', or before a design run that needs a brand's system. Returns each new system's slug.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "brand": ["type": "string", "description": "Brand slug or name, a registry brand, or 'all' for every brand."]
                    ],
                    "required": ["brand"]
                ]
            ),
            ClaudeTool(
                name: "design_system_activate",
                description: "Bind a brand to an existing design system so design runs for that brand inject the system's DESIGN.md. Use after generating or importing a system, or when the user says 'use system X for brand Y'. Both arguments are required.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "brand": ["type": "string", "description": "Brand slug the system should apply to."],
                        "slug": ["type": "string", "description": "Slug of the design system to activate (see design_system_list)."]
                    ],
                    "required": ["brand", "slug"]
                ]
            ),
            ClaudeTool(
                name: "design_system_import",
                description: "Import an external DESIGN.md file (for example one published by Open Design) into Grux's design systems. The file is validated, slugged, and copied in verbatim. Use when the user points at a DESIGN.md path they want Grux to use. Returns the imported system's slug.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string", "description": "Absolute path (or ~-relative path) to a DESIGN.md markdown file."]
                    ],
                    "required": ["path"]
                ]
            )
        ]
    }

    static func dispatch(name: String, input: [String: Any]) async -> String {
        switch name {
        case "design_system_list":
            return await MainActor.run { () -> String in
                let rows = DesignSystemStore.shared.list()
                if rows.isEmpty {
                    return "(no design systems yet, run design_system_generate_brand)"
                }
                return rows.map { "\($0.slug) | \($0.name)" }.joined(separator: "\n")
            }

        case "design_system_generate_brand":
            let brand = ((input["brand"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !brand.isEmpty else { return "error: design_system_generate_brand needs a brand" }

            // "all" generates the whole brand roster (curated brands plus every
            // active registry project) and activates each brand to its own system.
            if brand.caseInsensitiveCompare("all") == .orderedSame {
                let systems = await BrandSystemGenerator().generateAll()
                return await MainActor.run { () -> String in
                    let store = DesignSystemStore.shared
                    for system in systems {
                        _ = store.setActiveSystem(brandSlug: system.slug, slug: system.slug)
                    }
                    guard !systems.isEmpty else { return "error: no brands to generate" }
                    let lines = systems.map { "ok: \($0.name) (\($0.slug))" }.joined(separator: "\n")
                    return "generated \(systems.count) design system\(systems.count == 1 ? "" : "s") and activated each:\n\(lines)"
                }
            }

            return await MainActor.run { () -> String in
                let slug = DesignSystem.slugify(brand)
                let display = prettyName(forSlug: slug, raw: brand)
                let block = ProductCatalog.shared.contextBlock(brand: slug)
                let generator = BrandSystemGenerator(contextProvider: { _ in block })
                let system = generator.system(forBrandSlug: slug, displayName: display)
                let store = DesignSystemStore.shared
                store.save(system: system)
                // Auto-activate what we just generated so a design run for this
                // brand picks it up with no separate activate step.
                _ = store.setActiveSystem(brandSlug: slug, slug: system.slug)
                return "ok: generated design system '\(system.name)' (\(system.slug)) and activated it for '\(slug)'"
            }

        case "design_system_activate":
            let brand = ((input["brand"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let slug = ((input["slug"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !brand.isEmpty, !slug.isEmpty else { return "error: design_system_activate needs brand and slug" }
            return await MainActor.run { () -> String in
                let store = DesignSystemStore.shared
                guard store.setActiveSystem(brandSlug: brand, slug: slug) else {
                    let available = store.list().map { $0.slug }.joined(separator: ", ")
                    return "error: no design system with slug '\(slug)'. Available: \(available.isEmpty ? "(none)" : available)"
                }
                return "ok: '\(DesignSystem.slugify(brand))' now uses design system '\(slug)'"
            }

        case "design_system_import":
            let path = ((input["path"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return "error: design_system_import needs a path" }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            return await MainActor.run { () -> String in
                guard let system = DesignSystemStore.shared.importFile(url: url) else {
                    return "error: could not import a design system from '\(path)' (missing file or not a DESIGN.md)"
                }
                return "ok: imported '\(system.name)' as slug '\(system.slug)'"
            }

        default:
            return "error: unknown design system tool '\(name)'"
        }
    }

    // A human display name for a brand slug: the curated name when known, else a
    // title-cased version of the raw input.
    private static func prettyName(forSlug slug: String, raw: String) -> String {
        if let curated = BrandSystemGenerator.curated.first(where: { $0.slug == slug }) {
            return curated.name
        }
        let source = raw.isEmpty ? slug : raw
        let words = source
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? slug : joined
    }
}
