//
//  PromptCompiler.swift
//  Grux Creative Studio - dynamic image direction
//
//  Turns structured controls + a freeform addon + the active recipe + the
//  per-brand style profile into ONE qwen-style imperative directive string that
//  is sent to POST /api/images/render-dynamic on the companion service.
//
//  This is the heart of the "dynamic" feel. It is a pure, deterministic,
//  dependency-free function (Foundation only) so it is trivially unit-testable
//  and stable: the same inputs always produce the same directive.
//
//  Prompt-style contract (proven against qwen-image-edit-plus):
//    - Lead with an imperative edit command ("Change the white background.").
//    - One concise paragraph of imperative scene direction.
//    - Do NOT append the product-preservation sentence here. The pipeline
//      (core/pipeline.render_dynamic) appends "Keep the product exactly as it
//      appears... Photorealistic editorial product photography." after this
//      string. Duplicating it makes the prompt verbose and pushes qwen toward
//      its soft-bokeh default.
//
//  Hard rule: no em dashes, no en dashes anywhere in generated copy.
//

import Foundation

// MARK: - Aspect presets

/// Output aspect presets. `rawValue` is exactly the string the
/// /api/images/render-dynamic endpoint expects in its `aspect` field.
enum AspectPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case square = "1:1"
    case portrait45 = "4:5"
    case vertical = "9:16"
    case landscape = "16:9"

    var id: String { rawValue }

    /// Short human label for chips.
    var label: String { rawValue }

    /// Where this aspect is typically used, for UI sublines.
    var platformHint: String {
        switch self {
        case .square: return "Feed"
        case .portrait45: return "IG portrait"
        case .vertical: return "Reels / TikTok"
        case .landscape: return "LinkedIn / X"
        }
    }
}

// MARK: - Structured scene controls

/// The structured knobs surfaced in the Studio composer. Every field is
/// optional so a partial direction still compiles; missing knobs are simply
/// omitted from the directive rather than guessed.
struct SceneControls: Codable, Equatable, Sendable {
    var setting: String?      // "a sunlit loft", "a warm kitchen"
    var surface: String?      // "reclaimed oak counter", "veined marble ledge"
    var lighting: String?     // "soft window light", "golden hour"
    var timeOfDay: String?    // "morning", "late afternoon"
    var mood: String?         // "calm and editorial", "warm and lived-in"
    var lens: String?         // "shallow depth of field", "macro detail"
    var props: [String]       // ["a ceramic mug", "a eucalyptus sprig"]
    var strictBrand: Bool     // enforce palette + brand style cues

    init(
        setting: String? = nil,
        surface: String? = nil,
        lighting: String? = nil,
        timeOfDay: String? = nil,
        mood: String? = nil,
        lens: String? = nil,
        props: [String] = [],
        strictBrand: Bool = false
    ) {
        self.setting = setting
        self.surface = surface
        self.lighting = lighting
        self.timeOfDay = timeOfDay
        self.mood = mood
        self.lens = lens
        self.props = props
        self.strictBrand = strictBrand
    }

    static let empty = SceneControls()

    /// True when no structured knob carries information. Used to decide whether
    /// the freeform addon should stand on its own.
    var isEmpty: Bool {
        clean(setting) == nil
            && clean(surface) == nil
            && clean(lighting) == nil
            && clean(timeOfDay) == nil
            && clean(mood) == nil
            && clean(lens) == nil
            && props.compactMap(clean).isEmpty
    }
}

// MARK: - Per-brand style

/// Distilled brand visual identity used for "strict brand mode" enforcement and
/// as a source of sensible defaults. Persisted alongside recipes as part of the
/// PerBrandProfile in a later phase; defined here so the compiler is the single
/// source of truth for the type.
struct BrandStyle: Codable, Equatable, Sendable {
    var slug: String
    var paletteWords: [String]     // human color words for the directive, e.g. ["paper-cream", "warm black", "one postal-red accent"]
    var paletteHex: [String]       // hex, for swatches in the UI (not injected into the prompt)
    var styleNotes: String         // one imperative clause appended in strict mode
    var doNotClause: String?       // optional negative guidance ("no human hands or faces")
    var defaultSurfaces: [String]
    var defaultLighting: [String]
    var puzzleRule: String?        // optional correctness clause injected only when the scene mentions a puzzle/tiles

    init(
        slug: String,
        paletteWords: [String] = [],
        paletteHex: [String] = [],
        styleNotes: String = "",
        doNotClause: String? = nil,
        defaultSurfaces: [String] = [],
        defaultLighting: [String] = [],
        puzzleRule: String? = nil
    ) {
        self.slug = slug
        self.paletteWords = paletteWords
        self.paletteHex = paletteHex
        self.styleNotes = styleNotes
        self.doNotClause = doNotClause
        self.defaultSurfaces = defaultSurfaces
        self.defaultLighting = defaultLighting
        self.puzzleRule = puzzleRule
    }

    /// Neutral fallback for any brand we have no profile for (registry-only
    /// brands). Strict mode still works, it just enforces clean photography
    /// rather than a specific palette.
    static func generic(slug: String) -> BrandStyle {
        BrandStyle(
            slug: slug,
            paletteWords: [],
            paletteHex: [],
            styleNotes: "clean, honest, editorial product photography with natural directional light and a single soft shadow",
            doNotClause: "no text overlays, no watermarks, no people",
            defaultSurfaces: ["a clean wood surface", "a stone ledge"],
            defaultLighting: ["soft directional daylight"]
        )
    }
}

// MARK: - Brand style registry

/// The user's own brand style profiles, keyed by brand slug.
///
/// EMPTY by default, and that is the point: Grux ships with nobody's brand book
/// compiled in. A slug this library has never been told about resolves to
/// ``BrandStyle/generic(slug:)``, so an unconfigured install still renders clean
/// editorial photography rather than erroring or naming a brand it invented.
///
/// Populate it from settings, from an import, or per call. Callers that already
/// hold a profile should pass it straight to
/// ``PromptCompiler/compileDirective(controls:freeform:style:)`` and skip this
/// registry entirely.
enum BrandStyleLibrary {
    /// User-configured styles. Assign to add a brand; empty means "not set up".
    static var userStyles: [String: BrandStyle] = [:]

    /// Resolve a brand slug to its configured style, or a neutral generic profile.
    static func style(for slug: String) -> BrandStyle {
        userStyles[slug] ?? BrandStyle.generic(slug: slug)
    }
}

// MARK: - The compiler

enum PromptCompiler {

    /// Compile a single qwen-style directive from structured controls, a
    /// freeform addon, and a brand style. Deterministic and pure.
    ///
    /// - Parameters:
    ///   - controls: the structured knobs (any subset may be set).
    ///   - freeform: the "and also..." text, appended verbatim (trimmed).
    ///   - style: the brand style, used when `controls.strictBrand` is true and
    ///            as a source of fallback surface/lighting when those knobs are
    ///            empty but strict mode is on.
    /// - Returns: one concise imperative paragraph. Never empty: if there is no
    ///            input at all it returns a safe neutral directive.
    static func compileDirective(
        controls: SceneControls,
        freeform: String,
        style: BrandStyle
    ) -> String {
        var sentences: [String] = []

        // 1. The proven imperative lead.
        sentences.append("Change the white background.")

        // 2. Placement: surface and/or setting. Fall back to a brand default
        //    surface only when strict mode is on and nothing was specified.
        let surface = clean(controls.surface)
            ?? (controls.strictBrand ? style.defaultSurfaces.first : nil)
        let setting = clean(controls.setting)
        if let surface, let setting {
            sentences.append("The product now rests on \(surface) in \(setting).")
        } else if let surface {
            sentences.append("The product now rests on \(surface).")
        } else if let setting {
            sentences.append("The product is now placed in \(setting).")
        }

        // 3. Light + time of day.
        let lighting = clean(controls.lighting)
            ?? (controls.strictBrand ? style.defaultLighting.first : nil)
        let timeOfDay = clean(controls.timeOfDay)
        if let lighting, let timeOfDay {
            sentences.append("Lit by \(lighting) in the \(timeOfDay), casting one soft natural shadow.")
        } else if let lighting {
            sentences.append("Lit by \(lighting), casting one soft natural shadow.")
        } else if let timeOfDay {
            sentences.append("Set in the \(timeOfDay) with soft natural light and one gentle shadow.")
        }

        // 4. Mood.
        if let mood = clean(controls.mood) {
            sentences.append("The overall mood is \(mood).")
        }

        // 5. Lens / depth.
        if let lens = clean(controls.lens) {
            sentences.append("Shot with \(lens).")
        }

        // 6. Props.
        let props = controls.props.compactMap(clean)
        if !props.isEmpty {
            sentences.append("Include \(joinList(props)) softly arranged in the scene.")
        }

        // 7. Strict brand enforcement: palette + style notes + negative cues.
        if controls.strictBrand {
            if !style.paletteWords.isEmpty {
                sentences.append("Hold to the brand palette of \(joinList(style.paletteWords)).")
            }
            if !style.styleNotes.isEmpty {
                sentences.append(ensureSentence(style.styleNotes))
            }
            if let doNot = style.doNotClause, !doNot.isEmpty {
                sentences.append(ensureSentence(doNot))
            }
        }

        // Safety net: if only the lead survived (no scene content yet), give
        // qwen a usable neutral scene rather than just "Change the white
        // background." on its own. Checked here, before the always-on copy zone
        // and freeform, so the count test stays meaningful.
        if sentences.count == 1 {
            sentences.append("The product now rests on a clean neutral surface with soft directional daylight and one gentle shadow.")
        }

        // 7c. Puzzle correctness. A "make it a puzzle" render must show REAL
        //     interlocking jigsaw tiles with a flat rectangular outer border,
        //     never tabs protruding off the edge and never non-matching
        //     tab/socket seams. A brand style supplies the clause; it is injected
        //     whenever the scene mentions a puzzle/jigsaw/tiles, regardless of
        //     strict mode.
        if let puzzleRule = style.puzzleRule, !puzzleRule.isEmpty {
            let haystack = (
                [freeform, controls.surface, controls.setting, controls.mood, controls.lens, controls.timeOfDay].compactMap(clean)
                + controls.props.compactMap(clean)
            ).joined(separator: " ").lowercased()
            if haystack.contains("puzzle") || haystack.contains("jigsaw") || haystack.contains("tile") {
                sentences.append(ensureSentence(puzzleRule))
            }
        }

        // 8. Copy zone. Overlaid headlines live in the EMPTY part of a creative,
        //    never on the subject, so we compose with a clean copy zone to one
        //    side. The headline later sits in its own column and wraps there; the
        //    generated image itself stays text-free.
        sentences.append("Leave a clean area of negative space to one side, away from the product, with room for a headline to be overlaid later in its own column.")

        // 9. Freeform addon, verbatim (trimmed). Always last so the operator's
        //    explicit words win over the structured scaffolding.
        if let extra = clean(freeform) {
            sentences.append(ensureSentence(extra))
        }

        return sentences.joined(separator: " ")
    }

    /// Convenience overload that resolves the brand style from the registry by
    /// slug, falling back to the neutral generic profile when none is configured.
    static func compileDirective(
        controls: SceneControls,
        freeform: String,
        brandSlug: String
    ) -> String {
        compileDirective(
            controls: controls,
            freeform: freeform,
            style: BrandStyleLibrary.style(for: brandSlug)
        )
    }
}

// MARK: - Small pure helpers (file-private)

/// Trim whitespace and return nil for empty strings.
private func clean(_ s: String?) -> String? {
    guard let s else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

/// Join a list into readable prose: "a, b and c".
private func joinList(_ items: [String]) -> String {
    switch items.count {
    case 0: return ""
    case 1: return items[0]
    case 2: return "\(items[0]) and \(items[1])"
    default:
        let head = items.dropLast().joined(separator: ", ")
        return "\(head) and \(items[items.count - 1])"
    }
}

/// Uppercase only the first character, leave the rest untouched.
private func capitalizeFirst(_ s: String) -> String {
    guard let first = s.first else { return s }
    return String(first).uppercased() + s.dropFirst()
}

/// Ensure a fragment reads as a sentence (capital first letter, trailing
/// period). Leaves existing terminal punctuation alone.
private func ensureSentence(_ s: String) -> String {
    let capped = capitalizeFirst(s)
    let last = capped.last
    if last == "." || last == "!" || last == "?" {
        return capped
    }
    return capped + "."
}
