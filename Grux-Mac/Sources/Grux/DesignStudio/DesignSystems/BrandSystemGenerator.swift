import Foundation
import GruxShellCore

// BrandSystemGenerator: turns whatever brand ground truth this machine holds
// into a portable DESIGN.md per brand.
//
// Inputs are injected so the whole thing is testable with zero network and zero
// main-actor catalog access:
//   - the registry project roster (default: live ProjectRegistryClient.fetchProjects)
//   - the per-brand visual identity (default: BrandStyleLibrary)
//   - the per-brand grounding facts (default: empty; the live path grounds from
//     ProductCatalog on the main actor)
//   - the per-brand support contact (default: empty; the live path reads
//     ProductCatalog on the main actor)
//
// No brand roster is compiled in. Brands come from the project registry, so a
// machine with an empty registry generates nothing and reports it, rather than
// shipping somebody else's portfolio.
//
// Every generated system carries the baked house law: the tight-control
// component scale, the copy-law voice (no em or en dash, dollars as $N, no
// medical claims, the support contact when one is known, and never naming the
// tech stack or vendors in public copy), and the matching anti-patterns. A brand
// with a palette and style notes in BrandStyle gets those too; every other brand
// gets a clean generic system named for the brand.
//
// Zero em/en dashes anywhere, including inside the markdown this file emits.
struct BrandSystemGenerator {

    var styleProvider: (String) -> BrandStyle
    var contextProvider: (String) -> String
    var supportEmailProvider: (String) -> String

    init(
        styleProvider: @escaping (String) -> BrandStyle = { BrandStyleLibrary.style(for: $0) },
        contextProvider: @escaping (String) -> String = { _ in "" },
        supportEmailProvider: @escaping (String) -> String = { _ in "" }
    ) {
        self.styleProvider = styleProvider
        self.contextProvider = contextProvider
        self.supportEmailProvider = supportEmailProvider
    }

    // MARK: - Public build API

    // Build one system for an arbitrary brand slug + display name.
    func system(forBrandSlug brandSlug: String, displayName: String) -> DesignSystem {
        let markdown = markdown(forBrandSlug: brandSlug, displayName: displayName)
        return DesignSystem.parse(markdown: markdown, slug: DesignSystem.slugify(brandSlug))
    }

    // Build systems for every active registry project. Pure and network-free,
    // feed it fixture projects in tests.
    func systems(projects: [RemoteProject]) -> [DesignSystem] {
        systems(brands: Self.brandList(projects: projects))
    }

    private func systems(brands: [(slug: String, name: String)]) -> [DesignSystem] {
        brands.map { system(forBrandSlug: $0.slug, displayName: $0.name) }
    }

    // MARK: - Live generate-and-write

    // Fetch the registry (or accept injected fixture projects), ground each brand
    // from the live catalog on the main actor, build, and write every system to
    // the store. No network when projects are injected.
    @MainActor
    @discardableResult
    func generateAll(projects: [RemoteProject]? = nil, into store: DesignSystemStore? = nil) async -> [DesignSystem] {
        let target = store ?? DesignSystemStore.shared
        let roster: [RemoteProject]
        if let projects {
            roster = projects
        } else {
            roster = (await ProjectRegistryClient.fetchProjects()).projects
        }
        let brands = Self.brandList(projects: roster)

        // Resolve grounding context here, on the main actor, from the live
        // catalog, then fold it behind whatever was injected so a test-supplied
        // contextProvider still wins.
        let catalog = ProductCatalog.shared
        var groundedBlocks: [String: String] = [:]
        var groundedSupport: [String: String] = [:]
        for brand in brands {
            groundedBlocks[brand.slug] = catalog.contextBlock(brand: brand.slug)
            groundedSupport[brand.slug] = catalog.supportEmail(brand: brand.slug) ?? ""
        }

        let injected = self.contextProvider
        let injectedSupport = self.supportEmailProvider
        var live = self
        live.contextProvider = { slug in
            let custom = injected(slug)
            return custom.isEmpty ? (groundedBlocks[slug] ?? "") : custom
        }
        live.supportEmailProvider = { slug in
            let custom = injectedSupport(slug)
            return custom.isEmpty ? (groundedSupport[slug] ?? "") : custom
        }

        let built = live.systems(brands: brands)
        for sys in built { target.save(system: sys) }
        return built
    }

    // MARK: - Brand roster

    // The canonical brand list: the curated brands first, then every active
    // registry project that is not already one of them, de-duplicated by slug.
    // `curated` ships empty, so out of the box this is exactly the registry.
    static func brandList(projects: [RemoteProject]) -> [(slug: String, name: String)] {
        var out: [(slug: String, name: String)] = curated
        var seen = Set(out.map { $0.slug })
        for project in projects {
            guard project.status.caseInsensitiveCompare("active") == .orderedSame else { continue }
            let source = project.slug.isEmpty ? project.name : project.slug
            let slug = DesignSystem.slugify(source)
            guard !slug.isEmpty, !curatedSkip.contains(slug), !seen.contains(slug) else { continue }
            let name = project.name.isEmpty ? slug : project.name
            out.append((slug: slug, name: name))
            seen.insert(slug)
        }
        return out
    }

    // Brands to generate ahead of the registry, as (slug, display name) pairs.
    // Empty by design: one person's portfolio does not belong in the binary.
    // The registry is the source of brands; an empty registry means no systems,
    // which the tool reports as "nothing to generate" rather than failing.
    static let curated: [(slug: String, name: String)] = []

    // Registry slugs that duplicate a curated brand under a different spelling.
    // Empty while `curated` is empty; the two move together.
    static let curatedSkip: Set<String> = []

    // MARK: - Per-brand markdown

    private func markdown(forBrandSlug brandSlug: String, displayName: String) -> String {
        let style = styleProvider(brandSlug)
        let grounding = contextProvider(brandSlug)

        var blocks: [String] = []
        blocks.append("# \(displayName)")
        blocks.append("The portable design system for \(displayName). Import it into Open Design or inject it into a generation run.")
        blocks.append(section(.color, colorBody(style: style)))
        blocks.append(section(.typography, Self.typographyBody))
        blocks.append(section(.spacing, Self.spacingBody))
        blocks.append(section(.layout, Self.layoutBody))
        blocks.append(section(.components, Self.componentsBody))
        blocks.append(section(.motion, Self.motionBody))
        blocks.append(section(.voice, voiceBody(brandSlug: brandSlug, style: style)))
        blocks.append(section(.brand, brandBody(displayName: displayName, style: style, grounding: grounding)))
        blocks.append(section(.antiPatterns, antiPatternsBody(style: style)))
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private func section(_ section: DesignSystem.Section, _ body: String) -> String {
        "## \(section.heading)\n\n\(body)"
    }

    // MARK: - Section bodies

    private func colorBody(style: BrandStyle) -> String {
        var lines: [String] = []
        if !style.paletteWords.isEmpty {
            lines.append("Palette words: \(style.paletteWords.joined(separator: ", ")).")
        }
        if !style.paletteHex.isEmpty {
            lines.append("")
            lines.append("| Token | Hex |")
            lines.append("| --- | --- |")
            for (i, hex) in style.paletteHex.enumerated() {
                let label = i < style.paletteWords.count ? style.paletteWords[i] : "accent-\(i + 1)"
                lines.append("| \(label) | \(hex) |")
            }
        } else {
            lines.append("No fixed hex palette is locked for this brand yet. Hold to clean, honest, neutral tones with a single confident accent, and never invent brand hex values.")
        }
        return lines.joined(separator: "\n")
    }

    private static let typographyBody = """
    Type scale (px): 12, 13, 14, 16, 20, 24, 32, 48.

    - 12px: fine print, captions, secondary metadata.
    - 13px: default button text and dense UI labels.
    - 14px: body copy, inputs, and standard controls.
    - 16px: comfortable reading body and list items.
    - 20px: subheads.
    - 24px: section titles.
    - 32px: page titles.
    - 48px: hero display.

    Use one humanist sans for UI and copy. Keep body line-height near 1.4.
    """

    private static let spacingBody = """
    Spacing rhythm (px): 4, 8, 12, 16, 24, 32, 48, 64.

    Compose every padding and gap from this scale. Buttons and inputs use the tight component paddings defined in the Components section, never ad hoc values.
    """

    private static let layoutBody = """
    - Content sits in a centered column with a sensible max width, never edge to edge on a wide screen.
    - Responsive by default: relative units, flex and grid, images capped at 100% width.
    - Wide content (tables, code, diagrams) scrolls inside its own container. The page body never scrolls sideways.
    - Respect device safe areas so no control hides under a notch or a fixed header.
    """

    // The baked tight-control scale. House law: tight, not chunky.
    private static let componentsBody = """
    Buttons, inputs, and close affordances follow the tight, not chunky scale.

    Buttons:
    - Default: padding 9px 18px, font-size 13px.
    - Small: padding 6px 12px, font-size 12px.
    - Large: padding 12px 22px, font-size 14px.
    - Radius: 999px pill for primary CTAs, 10px for utility and icon buttons.
    - Hover: color swap only, 160ms ease. Never animate padding or size.

    Inputs, textareas, selects:
    - padding 8px 12px, font-size 14px, line-height 1.4.
    - border-radius 8px, border 1px solid the strong line color.
    - Focus: gold border plus a subtle 3px ring, never a thick outline.

    Close (x) affordances render as an icon, not a button:
    - transparent background, no border, no shadow.
    - 28px by 28px, padding 4px, font-size 18px, radius 999px.
    - Hover: a very subtle background wash so it reads interactive without being chunky.
    """

    private static let motionBody = """
    - Transitions are 160ms ease. Animate color and opacity, never padding or size.
    - Motion is a quiet confirmation of an action, not decoration.
    - Respect the reduced-motion preference: drop non-essential animation when it is set.
    """

    private func voiceBody(brandSlug: String, style: BrandStyle) -> String {
        var lines: [String] = []
        lines.append("- Never use an em dash or an en dash. Use a comma, a period, a colon, parentheses, or a pipe instead.")
        lines.append("- Write dollar amounts as $N (for example $15), never spelled out in words.")
        lines.append("- No medical claims and no absolute guarantees.")
        let support = supportEmailProvider(brandSlug).trimmingCharacters(in: .whitespacesAndNewlines)
        if support.isEmpty {
            lines.append("- Never invent a support address. Cite one only when the brief supplies it.")
        } else {
            lines.append("- Support contact: \(support).")
        }
        lines.append("- Never reveal the tech stack, the model providers, or any vendor names in public copy. Stack stays private.")
        if !style.styleNotes.isEmpty {
            lines.append("- Match the brand's tone: \(Self.ensurePeriod(style.styleNotes))")
        }
        return lines.joined(separator: "\n")
    }

    private func brandBody(displayName: String, style: BrandStyle, grounding: String) -> String {
        var lines: [String] = []
        lines.append("\(displayName) keeps its own voice and visual identity.")
        if !style.styleNotes.isEmpty {
            lines.append("Visual style: \(Self.ensurePeriod(style.styleNotes))")
        }
        if let doNot = style.doNotClause, !doNot.isEmpty {
            lines.append("Avoid: \(Self.ensurePeriod(doNot))")
        }
        let ground = grounding.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ground.isEmpty {
            lines.append("")
            lines.append(ground)
        }
        return lines.joined(separator: "\n")
    }

    private func antiPatternsBody(style: BrandStyle) -> String {
        var lines: [String] = []
        lines.append("- Chunky buttons or inputs (oversized padding, thick outlines). Hold the tight scale in the Components section.")
        lines.append("- Any em dash or en dash. Split the sentence or use a comma.")
        lines.append("- Dollar amounts spelled out in words.")
        lines.append("- Naming the tech stack, model providers, or vendors in public copy.")
        lines.append("- Medical claims or absolute guarantees.")
        if let doNot = style.doNotClause, !doNot.isEmpty {
            lines.append("- Visual: \(Self.ensurePeriod(doNot))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func ensurePeriod(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = t.last else { return t }
        return (last == "." || last == "!" || last == "?") ? t : t + "."
    }
}
