import Foundation

// DesignSystemModels: the portable DESIGN.md schema.
//
// A design system is nine markdown sections (color, typography, spacing,
// layout, components, motion, voice, brand, anti-patterns) plus an optional
// pair of structured token conveniences (paletteHex, typeScale) that are
// DERIVED from the section bodies at parse time, never stored separately. That
// derivation is what makes round-trip lossless: render() reproduces every
// section body verbatim, so re-parsing yields identical derived tokens.
//
// The on-disk format is intentionally the same shape Open Design publishes as
// DESIGN.md (an H1 title, an optional lead paragraph, then a run of H2 section
// blocks) so a system exported from Open Design imports here directly, and a
// system generated here reads cleanly in their tooling.
//
// Pure data, Foundation only. No engine or store dependencies. House rules:
// zero em/en dashes anywhere in this file OR in any markdown it emits, and any
// generated dollar amount reads as $N.

struct DesignSystem: Equatable, Sendable {

    // MARK: - The nine canonical sections

    enum Section: String, CaseIterable, Hashable, Sendable {
        case color
        case typography
        case spacing
        case layout
        case components
        case motion
        case voice
        case brand
        case antiPatterns

        // The canonical H2 heading text render() emits.
        var heading: String {
            switch self {
            case .color:        return "Color"
            case .typography:   return "Typography"
            case .spacing:      return "Spacing"
            case .layout:       return "Layout"
            case .components:   return "Components"
            case .motion:       return "Motion"
            case .voice:        return "Voice"
            case .brand:        return "Brand"
            case .antiPatterns: return "Anti-Patterns"
            }
        }

        // Alias tokens (compacted: lowercased, letters and digits only) that a
        // parsed H2 heading may carry. Lets a foreign DESIGN.md whose headings
        // read "Colour Palette", "Voice & Tone", or "Don'ts" map onto the
        // canonical section without the author having to match our spelling.
        private static let compactAliasMap: [String: Section] = {
            let table: [Section: [String]] = [
                .color:        ["color", "colors", "colour", "colours", "palette", "colorpalette", "colourpalette"],
                .typography:   ["typography", "type", "typeface", "typefaces", "font", "fonts", "text", "typescale"],
                .spacing:      ["spacing", "space", "spacingscale", "rhythm", "spacingrhythm"],
                .layout:       ["layout", "layouts", "grid", "grids", "structure", "layoutgrid"],
                .components:   ["components", "component", "uicomponents", "elements", "controls"],
                .motion:       ["motion", "animation", "animations", "transition", "transitions", "movement", "motionanimation"],
                .voice:        ["voice", "voicetone", "voiceandtone", "tone", "copy", "copywriting", "writing", "content", "voicecopy"],
                .brand:        ["brand", "branding", "identity", "brandidentity", "about", "overview"],
                .antiPatterns: ["antipatterns", "antipattern", "donts", "dont", "donot", "donots", "avoid", "never", "dosanddonts", "dosdonts"]
            ]
            var map: [String: Section] = [:]
            for (section, aliases) in table {
                for alias in aliases { map[alias] = section }
            }
            return map
        }()

        // Resolve a raw H2 heading string to a canonical section, or nil when it
        // is an unknown section (which the parser preserves in `extras`).
        static func match(heading: String) -> Section? {
            let compact = heading.lowercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init)
                .joined()
            return compactAliasMap[compact]
        }
    }

    // MARK: - Stored state

    var name: String
    var slug: String
    // Optional intro paragraph that sits between the H1 title and the first H2
    // section, preserved so an imported file round-trips exactly.
    var lead: String
    // The nine known sections. A key is present only when its body is non-empty.
    var sections: [Section: String]
    // Unknown H2 headings, keyed by their exact original heading text so render()
    // can reproduce them. This is what keeps round-trip lossless for foreign
    // files that carry sections we do not model.
    var extras: [String: String]
    // Derived tokens (populated by parse, recomputed on every parse): a map of
    // palette token label to hex, and the ordered type scale steps.
    var paletteHex: [String: String]
    var typeScale: [String]

    init(
        name: String,
        slug: String,
        lead: String = "",
        sections: [Section: String] = [:],
        extras: [String: String] = [:],
        paletteHex: [String: String] = [:],
        typeScale: [String] = []
    ) {
        self.name = name
        self.slug = slug
        self.lead = lead
        self.sections = sections
        self.extras = extras
        self.paletteHex = paletteHex
        self.typeScale = typeScale
    }

    // MARK: - Parse

    // Parse a DESIGN.md markdown string. Maps H2 headings case-insensitively
    // onto the nine sections, tolerating unknown, missing, and reordered
    // sections (unknowns land in `extras`). The `slug` argument is authoritative
    // when supplied (the store passes the folder slug, the generator passes the
    // brand slug); when nil it is derived from the H1 title.
    static func parse(markdown: String, slug: String? = nil) -> DesignSystem {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var name = ""
        var leadLines: [String] = []
        var currentHeading: String? = nil
        var currentBody: [String] = []
        var sections: [Section: String] = [:]
        var extras: [String: String] = [:]

        func trimmedBody(_ lines: [String]) -> String {
            lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func flush() {
            guard let heading = currentHeading else { return }
            let body = trimmedBody(currentBody)
            currentBody = []
            if let section = Section.match(heading: heading) {
                if body.isEmpty { return } // known-but-empty sections are treated as absent
                if let existing = sections[section], !existing.isEmpty {
                    sections[section] = existing + "\n\n" + body
                } else {
                    sections[section] = body
                }
            } else {
                let key = heading
                if let existing = extras[key], !existing.isEmpty {
                    extras[key] = existing + "\n\n" + body
                } else {
                    extras[key] = body // unknown sections are preserved even when empty
                }
            }
        }

        for line in lines {
            if line.hasPrefix("## ") && !line.hasPrefix("### ") {
                flush()
                currentHeading = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("# ") && !line.hasPrefix("## ") {
                let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if name.isEmpty && currentHeading == nil {
                    name = title
                } else if currentHeading != nil {
                    currentBody.append(line)
                } else {
                    leadLines.append(line)
                }
            } else if currentHeading != nil {
                currentBody.append(line)
            } else {
                leadLines.append(line)
            }
        }
        flush()

        let lead = trimmedBody(leadLines)
        let resolvedSlug = slug ?? slugify(name)
        var system = DesignSystem(
            name: name,
            slug: resolvedSlug,
            lead: lead,
            sections: sections,
            extras: extras
        )
        system.paletteHex = system.derivePaletteHex()
        system.typeScale = system.deriveTypeScale()
        return system
    }

    // MARK: - Render

    // Emit canonical DESIGN.md markdown: H1 title, optional lead, the present
    // sections in canonical order, then unknown sections sorted by heading.
    // Bodies are reproduced verbatim, which is what makes parse(render(x))
    // recover x exactly (including the derived tokens).
    func render() -> String {
        var blocks: [String] = []
        if !name.isEmpty { blocks.append("# \(name)") }
        if !lead.isEmpty { blocks.append(lead) }
        for section in Section.allCases {
            guard let body = sections[section], !body.isEmpty else { continue }
            blocks.append("## \(section.heading)\n\n\(body)")
        }
        for heading in extras.keys.sorted() {
            let body = extras[heading] ?? ""
            if body.isEmpty {
                blocks.append("## \(heading)")
            } else {
                blocks.append("## \(heading)\n\n\(body)")
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: - System prompt injection

    // A compact form for injection into a reviewer or generator system prompt.
    // Leads with the palette and type scale (the tokens a critic checks against)
    // then a short snippet of the components, voice, and anti-patterns law.
    func systemPromptBlock() -> String {
        var lines: [String] = []
        lines.append("DESIGN SYSTEM: \(name) (\(slug))")
        if !paletteHex.isEmpty {
            let swatches = paletteHex.keys.sorted().prefix(12)
                .map { "\($0)=\(paletteHex[$0] ?? "")" }
                .joined(separator: ", ")
            lines.append("palette: \(swatches)")
        }
        if !typeScale.isEmpty {
            lines.append("type scale: \(typeScale.prefix(12).joined(separator: ", "))")
        }
        if let components = sections[.components] {
            lines.append("components: \(Self.snippet(components, cap: 260))")
        }
        if let voice = sections[.voice] {
            lines.append("voice: \(Self.snippet(voice, cap: 260))")
        }
        if let anti = sections[.antiPatterns] {
            lines.append("anti-patterns: \(Self.snippet(anti, cap: 220))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Derived token extraction

    // Pull palette tokens from the color section. Recognizes markdown table
    // rows ("| ink | #0A0A0A |"), list items ("- ink: #0A0A0A"), and bare hex.
    // The label is whatever precedes the hex, cleaned of table pipes, bullets,
    // and punctuation; an unlabeled hex is keyed by the hex itself.
    private func derivePaletteHex() -> [String: String] {
        guard let body = sections[.color] else { return [:] }
        var out: [String: String] = [:]
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let hexRange = Self.firstHexRange(in: line) else { continue }
            let hex = String(line[hexRange]).uppercased()
            let before = String(line[line.startIndex..<hexRange.lowerBound])
            let label = before
                .replacingOccurrences(of: "|", with: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -*`:#•").union(.whitespaces))
            let key = label.isEmpty ? hex.lowercased() : label.lowercased()
            if out[key] == nil { out[key] = hex }
        }
        return out
    }

    // Pull the type scale from the typography section: every size-with-unit
    // token (12px, 1.25rem, 14pt) in document order, de-duplicated.
    private func deriveTypeScale() -> [String] {
        guard let body = sections[.typography] else { return [] }
        var out: [String] = []
        var seen: Set<String> = []
        let scalars = Array(body.lowercased())
        var i = 0
        while i < scalars.count {
            if scalars[i].isNumber {
                var j = i
                while j < scalars.count && (scalars[j].isNumber || scalars[j] == ".") { j += 1 }
                let numberEnd = j
                for unit in ["px", "rem", "pt"] {
                    let u = Array(unit)
                    if j + u.count <= scalars.count && Array(scalars[j..<j + u.count]) == u {
                        let token = String(scalars[i..<numberEnd]) + unit
                        if !seen.contains(token) { seen.insert(token); out.append(token) }
                        j += u.count
                        break
                    }
                }
                i = max(j, i + 1)
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: - Small pure helpers

    // Lowercased, hyphen-joined, alphanumeric-only slug. Empty input yields a
    // safe non-empty default so a folder name is always valid.
    static func slugify(_ raw: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in raw.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "system" : trimmed
    }

    private static func snippet(_ text: String, cap: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if flat.count <= cap { return flat }
        return String(flat.prefix(cap)) + "..."
    }

    // Locate the first "#RRGGBB" or "#RGB" hex token in a line.
    private static func firstHexRange(in line: String) -> Range<String.Index>? {
        var idx = line.startIndex
        while idx < line.endIndex {
            if line[idx] == "#" {
                var cursor = line.index(after: idx)
                var count = 0
                while cursor < line.endIndex, line[cursor].isHexDigit, count < 6 {
                    cursor = line.index(after: cursor)
                    count += 1
                }
                if count == 3 || count == 6 {
                    // Reject a 4 or 5 digit run (not a valid hex color).
                    let atBoundary = cursor == line.endIndex || !line[cursor].isHexDigit
                    if atBoundary { return idx..<cursor }
                }
            }
            idx = line.index(after: idx)
        }
        return nil
    }
}
