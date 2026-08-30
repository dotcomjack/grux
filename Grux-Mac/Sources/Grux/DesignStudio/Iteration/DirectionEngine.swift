import Foundation

// DirectionEngine: the five-direction picker. Instead of committing tokens to one
// full generation and hoping the vibe lands, Grux fans out five cheap direction
// SKETCHES first (name, thesis, palette, headline font, vibe words) so the user picks
// the lane before the expensive render. When the brand has a design system, the
// first direction is always the "on-system" one that uses its exact palette, so
// the safe on-brand choice is always on the table next to the exploratory ones.
//
// One cheap-model call (claude-haiku-4-5, 1200 max tokens) produces five numbered
// directions in a strict, single-line-per-direction format that parses fail-soft:
// a malformed line is skipped, and if fewer than two survive, a deterministic
// fallback set derived from the design-system palette stands in. No key means no
// model call: the deterministic fallback is returned directly.
//
// House style: a @MainActor async entry point for the model call, pure/nonisolated
// parse + fallback helpers for tests, zero em/en dashes, dollars as $N.

// MARK: - DesignDirection

struct DesignDirection: Codable, Hashable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let thesis: String
    let paletteHex: [String]
    let headlineFont: String
    let vibeWords: [String]
}

// MARK: - DirectionEngine

enum DirectionEngine {

    // The strict line format the model is asked to emit and parseDirections reads.
    // Six pipe-separated fields, one direction per line:
    //   DIRECTION | name | thesis | hex,hex,hex | headlineFont | vibe,vibe,vibe
    static let lineMarker = "DIRECTION |"

    // MARK: Public API

    @MainActor
    static func directions(brief: String,
                           brandSlug: String?,
                           designSystemMarkdown: String?,
                           apiKey: String) async -> [DesignDirection] {
        let palette = extractPalette(fromMarkdown: designSystemMarkdown ?? "")

        // No key: skip the model, return the deterministic set.
        guard !apiKey.isEmpty else {
            return fallbackDirections(fromPalette: palette)
        }

        let system = systemPrompt(hasDesignSystem: !palette.isEmpty, palette: palette)
        let user = userPrompt(brief: brief, brand: brandSlug, designSystem: designSystemMarkdown)
        var parsed: [DesignDirection] = []
        // ROUTED, AND THE ROUTE PICKS THE MODEL. This built its own ClaudeClient
        // and sent the caller's Anthropic key, so direction generation was
        // hosted-Anthropic-only and a local or custom-endpoint user silently got
        // the deterministic palette set forever.
        //
        // The first cut of that fix pinned a `directionsModel` constant holding
        // "claude-haiku-4-5" as the override, and resolvedRouting returned that
        // id AFTER the backend had resolved, so a local route would have POSTed
        // an Anthropic model id to Ollama, the catch below would have logged a
        // failure, and the user would have got the deterministic set forever
        // exactly as before. The constant is gone with the override: a
        // per-surface tier is a preference the route may not be able to honor,
        // and routing.modelId always can.
        //
        // Resolved ONCE, before the single call.
        let routing = ModelRegistry.shared.resolvedRouting(provider: nil, modelOverride: nil)
        do {
            let reply = try await routing.backend.complete(
                apiKey: routing.apiKey, model: routing.modelId, system: system,
                messages: [ClaudeMessage(role: "user", content: user)],
                maxTokens: 1200, temperature: 0.7,
                spanName: "studio.directions", feature: "design_studio")
            parsed = parseDirections(reply)
        } catch {
            WakeLog.shared.log("directionEngine: model call failed, using deterministic fallback (\(error.localizedDescription))")
            parsed = []
        }

        // Fail soft: too few usable directions -> the deterministic set.
        if parsed.count < 2 {
            return fallbackDirections(fromPalette: palette)
        }

        // When a design system exists, direction 1 MUST be on-system with its exact
        // palette. Force it deterministically rather than trusting the model to.
        if !palette.isEmpty {
            let onSystem = onSystemDirection(palette: palette, modelThesis: parsed.first?.thesis)
            var out = parsed
            out[0] = onSystem
            return out
        }
        return parsed
    }

    // MARK: Parsing (pure, nonisolated, unit-tested)

    // Parse the strict line format, skipping any malformed line. Robust to the
    // model wrapping lines in prose: only lines starting with the marker are read.
    nonisolated static func parseDirections(_ text: String) -> [DesignDirection] {
        var out: [DesignDirection] = []
        var seenNames = Set<String>()
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.uppercased().hasPrefix("DIRECTION |") else { continue }
            let body = String(line.dropFirst(lineMarker.count))
            let fields = body.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            // Need name, thesis, palette, font, vibe (5 fields after the marker).
            guard fields.count >= 5 else { continue }
            let name = fields[0]
            let thesis = fields[1]
            let palette = splitList(fields[2]).map(normalizeHex).filter { !$0.isEmpty }
            let font = fields[3]
            let vibe = splitList(fields[4])
            guard !name.isEmpty, !thesis.isEmpty else { continue }
            guard seenNames.insert(name.lowercased()).inserted else { continue }
            out.append(DesignDirection(name: name, thesis: thesis,
                                       paletteHex: palette.isEmpty ? ["#111111", "#F5F5F5", "#7C5CFF"] : palette,
                                       headlineFont: font.isEmpty ? "Inter" : font,
                                       vibeWords: vibe))
        }
        return out
    }

    // MARK: Fallback (pure, nonisolated, unit-tested)

    // Deterministic direction set used when the model is unavailable or its output
    // did not parse. Derived from the design-system palette when present so it is
    // still on-brand; otherwise a neutral default palette. Always returns at least
    // three directions, with the on-system one first when a palette exists.
    nonisolated static func fallbackDirections(fromPalette palette: [String]) -> [DesignDirection] {
        let neutral = ["#111111", "#F5F5F5", "#7C5CFF"]
        let base = palette.isEmpty ? neutral : palette
        var out: [DesignDirection] = []
        if !palette.isEmpty {
            out.append(onSystemDirection(palette: palette, modelThesis: nil))
        }
        out.append(DesignDirection(
            name: "High Contrast",
            thesis: "Bold type, heavy weight, a single accent doing all the work. Maximum focus on one message.",
            paletteHex: highContrast(from: base),
            headlineFont: "Inter Tight",
            vibeWords: ["bold", "confident", "focused"]))
        out.append(DesignDirection(
            name: "Editorial Minimal",
            thesis: "Generous whitespace, a restrained palette, and a quiet type scale. Lets the content breathe.",
            paletteHex: Array(base.prefix(3)),
            headlineFont: "Fraunces",
            vibeWords: ["calm", "premium", "considered"]))
        out.append(DesignDirection(
            name: "Warm Approachable",
            thesis: "Rounded shapes, softer contrast, and a friendly rhythm. Reads human, not corporate.",
            paletteHex: base.count >= 2 ? Array(base.suffix(3)) : neutral,
            headlineFont: "Nunito",
            vibeWords: ["friendly", "warm", "open"]))
        return out
    }

    // MARK: Palette extraction (pure, nonisolated, unit-tested)

    // Pull hex colors from the design-system markdown, in order, de-duplicated.
    nonisolated static func extractPalette(fromMarkdown md: String) -> [String] {
        guard !md.isEmpty else { return [] }
        let pattern = "#[0-9a-fA-F]{6}\\b"
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = md as NSString
        let matches = rx.matches(in: md, range: NSRange(location: 0, length: ns.length))
        var seen = Set<String>()
        var out: [String] = []
        for m in matches {
            let hex = normalizeHex(ns.substring(with: m.range))
            if seen.insert(hex).inserted { out.append(hex) }
        }
        return out
    }

    // MARK: Internals

    nonisolated private static func onSystemDirection(palette: [String], modelThesis: String?) -> DesignDirection {
        DesignDirection(
            name: "On-System",
            thesis: modelThesis?.isEmpty == false ? modelThesis! : "The safe, on-brand choice: your exact palette, type scale, and spacing tokens applied straight. No drift.",
            paletteHex: Array(palette.prefix(6)),
            headlineFont: "System",
            vibeWords: ["on-brand", "consistent", "trusted"])
    }

    // Reorder a palette so the darkest and lightest anchor the ends, for a high
    // contrast reading. Deterministic.
    nonisolated private static func highContrast(from palette: [String]) -> [String] {
        let sorted = palette.sorted { luminance($0) < luminance($1) }
        guard let dark = sorted.first, let light = sorted.last else { return palette }
        let accent = palette.first { $0 != dark && $0 != light } ?? light
        return [dark, light, accent]
    }

    nonisolated private static func luminance(_ hex: String) -> Double {
        let rgb = rgbComponents(hex)
        return 0.2126 * rgb.0 + 0.7152 * rgb.1 + 0.0722 * rgb.2
    }

    nonisolated private static func rgbComponents(_ hex: String) -> (Double, Double, Double) {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count >= 6, let v = Int(h.prefix(6), radix: 16) else { return (0, 0, 0) }
        let r = Double((v >> 16) & 0xFF)
        let g = Double((v >> 8) & 0xFF)
        let b = Double(v & 0xFF)
        return (r, g, b)
    }

    nonisolated private static func splitList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // Normalize to a clean lowercase #RRGGBB, or return empty so the caller drops
    // it. Anything that is not a 6-digit hex (a 3-digit shorthand, a name, junk)
    // is dropped rather than guessed at.
    nonisolated private static func normalizeHex(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespaces).lowercased()
        if !h.hasPrefix("#") { h = "#" + h }
        let body = h.dropFirst()
        guard body.count == 6, body.allSatisfy({ $0.isHexDigit }) else { return "" }
        return h
    }

    private static func systemPrompt(hasDesignSystem: Bool, palette: [String]) -> String {
        let onSystemLine = hasDesignSystem
            ? "Direction 1 MUST be on-system: it uses the brand's EXACT palette (\(palette.prefix(6).joined(separator: ", "))) and type scale, no drift. Directions 2 through 5 explore away from the system."
            : "There is no brand design system. All five directions explore freely."
        return """
        You are a senior design director sketching FIVE distinct visual directions for one brief. Each direction is a lane, not a finished design: a name, a one-line thesis, a small palette, a headline font, and three vibe words.

        \(onSystemLine)

        Output EXACTLY five lines and nothing else. Each line is one direction in this STRICT format, pipes included:
        DIRECTION | <name> | <one line thesis> | <hex,hex,hex> | <headline font> | <vibe,vibe,vibe>

        Rules: hex colors as #RRGGBB. No em dashes, no en dashes. Dollars as $N. Do not number the lines. Do not add any prose before or after the five lines.
        """
    }

    private static func userPrompt(brief: String, brand: String?, designSystem: String?) -> String {
        var s = "BRIEF: \(brief)\n"
        if let b = brand, !b.isEmpty { s += "BRAND: \(b)\n" }
        if let ds = designSystem, !ds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            s += "DESIGN SYSTEM:\n\(ds)\n"
        }
        s += "Give me the five directions now."
        return s
    }
}
