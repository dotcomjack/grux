import Foundation

// WCAG 2.1 relative-luminance + contrast-ratio implementation.
//
// Formulas from https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
//
// Relative luminance (sRGB):
//   - Linearize each 8-bit sRGB channel: if c <= 0.03928 then c/12.92 else ((c+0.055)/1.055)^2.4
//   - L = 0.2126*R + 0.7152*G + 0.0722*B
//
// Contrast ratio:
//   ratio = (L1 + 0.05) / (L2 + 0.05)  where L1 = max(La, Lb), L2 = min(La, Lb)
//
// Returns ratios in the range 1.0 (no contrast) to 21.0 (white-on-black).
public struct WCAGColor: Equatable, Sendable {
    public let r: Double  // 0...1
    public let g: Double  // 0...1
    public let b: Double  // 0...1

    public init(r: Double, g: Double, b: Double) {
        self.r = max(0, min(1, r))
        self.g = max(0, min(1, g))
        self.b = max(0, min(1, b))
    }

    public static let white = WCAGColor(r: 1.0, g: 1.0, b: 1.0)
    public static let black = WCAGColor(r: 0.0, g: 0.0, b: 0.0)
}

public enum WCAGContrastChecker {

    // Linearize a single sRGB channel. See WCAG 2.1 section "Relative luminance".
    private static func linearize(_ channel: Double) -> Double {
        if channel <= 0.03928 {
            return channel / 12.92
        } else {
            return pow((channel + 0.055) / 1.055, 2.4)
        }
    }

    // Relative luminance in the range 0.0 (black) to 1.0 (white).
    public static func relativeLuminance(_ color: WCAGColor) -> Double {
        let r = linearize(color.r)
        let g = linearize(color.g)
        let b = linearize(color.b)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // Contrast ratio between two colors. Symmetric: ratio(a, b) == ratio(b, a).
    public static func contrastRatio(_ a: WCAGColor, _ b: WCAGColor) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        let lighter = max(la, lb)
        let darker = min(la, lb)
        return (lighter + 0.05) / (darker + 0.05)
    }

    // PASS thresholds per WCAG 2.1 success criterion 1.4.3 (Contrast Minimum):
    //   - Normal text: ≥4.5:1
    //   - Large text (≥18pt or ≥14pt bold): ≥3:1
    public static func passesAA(ratio: Double, isLargeText: Bool) -> Bool {
        return isLargeText ? ratio >= 3.0 : ratio >= 4.5
    }
}

// Light parser for color literals embedded in Swift source. Recognizes:
//   Color(red: 0.95, green: 0.20, blue: 0.10)
//   Color(red: 0.95, green: 0.20, blue: 0.10, opacity: 1.0)
//   UIColor(red: 0.95, green: 0.20, blue: 0.10, alpha: 1.0)
//
// Returns a tuple of (variableName?, color, isLikelyLargeText) - variable name
// is parsed from the leading `let foo = ...` if present, used by Rule 7 to
// guess whether a color is text-on-bg vs decorative.
public struct ParsedColorLiteral: Equatable, Sendable {
    public let name: String?
    public let color: WCAGColor
    public let isLikelyLargeText: Bool
    public let lineNumber: Int

    public init(name: String?, color: WCAGColor, isLikelyLargeText: Bool, lineNumber: Int) {
        self.name = name
        self.color = color
        self.isLikelyLargeText = isLikelyLargeText
        self.lineNumber = lineNumber
    }
}

public enum SwiftColorLiteralParser {

    // Find every `Color(red:green:blue:[opacity:])` and
    // `UIColor(red:green:blue:alpha:)` call. Best-effort regex (we don't
    // need perfect Swift parsing - just enough to catch the
    // Colors.swift-style declarations the audit targets).
    public static func parse(source: String) -> [ParsedColorLiteral] {
        var results: [ParsedColorLiteral] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        // Match: Color(red: 0.5, green: 0.3, blue: 0.1[, opacity: 1.0])
        //  or: UIColor(red: 0.5, green: 0.3, blue: 0.1, alpha: 1.0)
        let pattern = #"(?:UI)?Color\(\s*red:\s*([0-9]*\.?[0-9]+)\s*,\s*green:\s*([0-9]*\.?[0-9]+)\s*,\s*blue:\s*([0-9]*\.?[0-9]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return results
        }
        // Match leading `let foo =` on the same line.
        let namePattern = #"(?:let|var|static\s+let|public\s+static\s+let|public\s+let)\s+([A-Za-z_][A-Za-z0-9_]*)\s*"#
        let nameRegex = try? NSRegularExpression(pattern: namePattern, options: [])

        for (idx, lineSub) in lines.enumerated() {
            let line = String(lineSub)
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: line, options: [], range: range)
            guard !matches.isEmpty else { continue }
            // Try to find a leading variable name on the same line.
            var name: String? = nil
            if let nr = nameRegex,
               let nm = nr.firstMatch(in: line, options: [], range: range),
               nm.numberOfRanges >= 2 {
                name = nsLine.substring(with: nm.range(at: 1))
            }
            for m in matches {
                guard m.numberOfRanges >= 4 else { continue }
                let rs = nsLine.substring(with: m.range(at: 1))
                let gs = nsLine.substring(with: m.range(at: 2))
                let bs = nsLine.substring(with: m.range(at: 3))
                guard let rv = Double(rs), let gv = Double(gs), let bv = Double(bs) else { continue }
                // Heuristic: if the variable name contains "title" or
                // "headline" or "largeTitle", treat as large text (3:1
                // threshold). Default = small text (4.5:1).
                let lname = (name ?? "").lowercased()
                let largeText = lname.contains("largetitle") ||
                                lname.contains("title") ||
                                lname.contains("headline")
                results.append(ParsedColorLiteral(
                    name: name,
                    color: WCAGColor(r: rv, g: gv, b: bv),
                    isLikelyLargeText: largeText,
                    lineNumber: idx + 1
                ))
            }
        }
        return results
    }
}
