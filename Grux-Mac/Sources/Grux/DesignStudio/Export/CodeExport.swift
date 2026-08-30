import Foundation

// Design-to-code export. Pure string transforms over generated HTML/CSS, so
// the whole surface is unit-testable without WebKit, a store, or any UI.
//
// Two targets:
//   1. astroComponent(html:css:name:) wraps a design's markup into a props-less
//      .astro component with a scoped <style> block. High fidelity: Astro ships
//      the HTML and CSS essentially verbatim.
//   2. swiftUIView(html:name:) is a FIRST-PASS best-effort translation of a
//      constrained HTML subset into a SwiftUI View body. It is explicitly a
//      generated starting point, not production code: anything it does not
//      recognize is preserved as a clearly marked comment so nothing is
//      silently dropped.
//
// House rules: no em/en dashes anywhere, no vendor or model names in generated
// output (the generated files ship to users), $N dollar formatting if money
// ever appears in copy.
enum CodeExport {

    // MARK: - Astro

    // Wrap a design's HTML body and CSS into a single props-less Astro
    // component. Astro scopes any <style> block to the component automatically,
    // so the passed CSS lands as component-local styling with no extra work.
    static func astroComponent(html: String, css: String, name: String) -> String {
        let componentName = pascalCase(name.isEmpty ? "Design" : name)
        let rootClass = kebabCase(name.isEmpty ? "design" : name) + "-root"
        let body = extractBody(from: html)
        let indentedBody = indent(body.trimmedLines(), by: 2)

        var out = ""
        out += "---\n"
        out += "// Generated Astro component: \(componentName)\n"
        out += "// Generated starting point from a Grux design. Review before shipping.\n"
        out += "---\n\n"
        out += "<div class=\"\(rootClass)\">\n"
        out += indentedBody
        if !indentedBody.hasSuffix("\n") { out += "\n" }
        out += "</div>\n"

        let trimmedCSS = css.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCSS.isEmpty {
            out += "\n<style>\n"
            out += indent(trimmedCSS, by: 2)
            if !out.hasSuffix("\n") { out += "\n" }
            out += "</style>\n"
        }
        return out
    }

    // MARK: - SwiftUI

    // First-pass HTML to SwiftUI. Recognizes headings, paragraphs, images,
    // buttons/links, and div/section stacks (row vs column inferred from a
    // flex-direction hint). Everything else is emitted as a comment listing the
    // skipped tag so the output is an honest starting point, never a lie.
    static func swiftUIView(html: String, name: String) -> String {
        let viewName = pascalCase(name.isEmpty ? "Design" : name) + "View"
        let body = extractBody(from: html)
        let nodes = HTMLMiniParser.parse(body)

        var skipped: Set<String> = []
        let bodyLines = renderStack(nodes, axis: .vertical, indentLevel: 3, skipped: &skipped)

        var out = ""
        out += "// GENERATED SwiftUI view: \(viewName)\n"
        out += "// First-pass translation of an HTML design. This is a generated\n"
        out += "// starting point, not production code: review the layout, wire up real\n"
        out += "// data, and replace placeholder URLs before shipping.\n"
        out += "import SwiftUI\n\n"
        out += "struct \(viewName): View {\n"
        out += "    var body: some View {\n"
        out += "        VStack(alignment: .leading, spacing: 12) {\n"
        if bodyLines.isEmpty {
            out += "            EmptyView() // no recognized elements in the source markup\n"
        } else {
            out += bodyLines.joined(separator: "\n") + "\n"
        }
        if !skipped.isEmpty {
            let list = skipped.sorted().joined(separator: ", ")
            out += "            // Unsupported elements were skipped: \(list)\n"
        }
        out += "        }\n"
        out += "        .padding()\n"
        out += "    }\n"
        out += "}\n"
        return out
    }

    // MARK: - SwiftUI rendering

    private enum Axis { case vertical, horizontal }

    private static func renderStack(_ nodes: [HTMLNode], axis: Axis, indentLevel: Int, skipped: inout Set<String>) -> [String] {
        var lines: [String] = []
        for node in nodes {
            lines.append(contentsOf: renderNode(node, indentLevel: indentLevel, skipped: &skipped))
        }
        return lines
    }

    private static func renderNode(_ node: HTMLNode, indentLevel: Int, skipped: inout Set<String>) -> [String] {
        let pad = String(repeating: " ", count: indentLevel * 4)
        switch node.kind {
        case .text(let raw):
            let text = collapseWhitespace(raw)
            guard !text.isEmpty else { return [] }
            return ["\(pad)Text(\"\(swiftEscaped(text))\")"]
        case .element(let tag, let attributes):
            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let inner = innerText(of: node)
                let font = headingFont(for: tag)
                return ["\(pad)Text(\"\(swiftEscaped(inner))\").font(\(font)).bold()"]
            case "p", "span", "strong", "em", "b", "i", "small", "label", "li", "blockquote":
                let inner = innerText(of: node)
                guard !inner.isEmpty else { return [] }
                return ["\(pad)Text(\"\(swiftEscaped(inner))\")"]
            case "img":
                let src = attributes["src"] ?? ""
                return ["\(pad)AsyncImage(url: URL(string: \"\(swiftEscaped(src))\"))"]
            case "button":
                let label = innerText(of: node)
                return ["\(pad)Button(\"\(swiftEscaped(label))\") { }"]
            case "a":
                let label = innerText(of: node)
                // A link styled as a button, or any anchor, maps to a Button
                // placeholder in this first pass (navigation is wired by hand).
                return ["\(pad)Button(\"\(swiftEscaped(label))\") { }"]
            case "br", "hr":
                return ["\(pad)Divider()"]
            case "div", "section", "main", "header", "footer", "nav", "article", "aside", "ul", "ol", "form":
                let axis = stackAxis(for: attributes)
                let container = axis == .horizontal ? "HStack" : "VStack"
                let alignment = axis == .horizontal ? ".center" : ".leading"
                var out = ["\(pad)\(container)(alignment: \(alignment), spacing: 8) {"]
                let childLines = renderStack(node.children, axis: axis, indentLevel: indentLevel + 1, skipped: &skipped)
                if childLines.isEmpty {
                    out.append("\(pad)    EmptyView()")
                } else {
                    out.append(contentsOf: childLines)
                }
                out.append("\(pad)}")
                return out
            default:
                skipped.insert(tag)
                return ["\(pad)// TODO: unsupported <\(tag)> element"]
            }
        }
    }

    private static func headingFont(for tag: String) -> String {
        switch tag {
        case "h1": return ".largeTitle"
        case "h2": return ".title"
        case "h3": return ".title2"
        case "h4": return ".title3"
        case "h5": return ".headline"
        default: return ".subheadline"
        }
    }

    // A row layout when the element declares flex-direction:row (or explicit
    // flex with no column direction). Everything else stacks vertically, which
    // is the safe default for a first pass.
    private static func stackAxis(for attributes: [String: String]) -> Axis {
        let style = (attributes["style"] ?? "").lowercased()
        let classes = (attributes["class"] ?? "").lowercased()
        let hasFlex = style.contains("display:flex") || style.contains("display: flex")
        let rowHint = style.contains("flex-direction:row") || style.contains("flex-direction: row")
            || classes.contains("row") || classes.contains("hstack")
        let columnHint = style.contains("flex-direction:column") || style.contains("flex-direction: column")
        if rowHint { return .horizontal }
        if hasFlex && !columnHint { return .horizontal }
        return .vertical
    }

    // MARK: - Text helpers

    private static func innerText(of node: HTMLNode) -> String {
        var acc = ""
        gatherText(node, into: &acc)
        return collapseWhitespace(acc)
    }

    private static func gatherText(_ node: HTMLNode, into acc: inout String) {
        switch node.kind {
        case .text(let raw):
            acc += raw
        case .element:
            for child in node.children { gatherText(child, into: &acc) }
            acc += " "
        }
    }

    private static func collapseWhitespace(_ s: String) -> String {
        let decoded = decodeEntities(s)
        let parts = decoded.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    // Escape a plain string for embedding in a Swift double-quoted literal.
    private static func swiftEscaped(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "\t", with: " ")
        return out
    }

    // MARK: - Shared string utilities

    private static func extractBody(from html: String) -> String {
        let lower = html.lowercased()
        guard let bodyOpen = lower.range(of: "<body") else { return html }
        guard let openEnd = html.range(of: ">", range: bodyOpen.upperBound..<html.endIndex) else { return html }
        let afterOpen = openEnd.upperBound
        if let closeRange = lower.range(of: "</body>", range: afterOpen..<html.endIndex) {
            return String(html[afterOpen..<closeRange.lowerBound])
        }
        return String(html[afterOpen...])
    }

    private static func pascalCase(_ s: String) -> String {
        let tokens = s.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        let joined = tokens.map { token -> String in
            let str = String(token)
            return str.prefix(1).uppercased() + str.dropFirst()
        }.joined()
        let cleaned = joined.isEmpty ? "Design" : joined
        // A component name must start with a letter.
        return cleaned.first!.isLetter ? cleaned : "Design" + cleaned
    }

    private static func kebabCase(_ s: String) -> String {
        let tokens = s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) })
        let joined = tokens.joined(separator: "-")
        return joined.isEmpty ? "design" : joined
    }

    private static func indent(_ text: String, by spaces: Int) -> String {
        let pad = String(repeating: " ", count: spaces)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
    }
}

private extension String {
    // Drop leading and trailing fully-blank lines while keeping interior shape.
    func trimmedLines() -> String {
        var lines = self.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Minimal HTML parser

// A tiny, tolerant HTML tokenizer. It is NOT a spec-compliant parser: it is
// just enough to turn a constrained design subset into a node tree for the
// SwiftUI first pass. It skips comments, doctype, and the raw contents of
// <script>/<style> so their text never leaks into the output.
struct HTMLNode {
    enum Kind {
        case element(tag: String, attributes: [String: String])
        case text(String)
    }
    var kind: Kind
    var children: [HTMLNode]
}

enum HTMLMiniParser {
    private static let voidTags: Set<String> = ["img", "br", "hr", "input", "meta", "link", "source", "area", "col", "embed", "wbr"]
    private static let rawTextTags: Set<String> = ["script", "style"]
    // Hard cap on nesting depth. parseChildren recurses once per open element,
    // so pathologically nested import HTML (thousands of unclosed tags) would
    // overflow the stack and crash the whole app. Past this many levels an
    // opening tag is kept as a leaf and its would-be children flatten into
    // siblings instead of adding another stack frame.
    private static let maxDepth = 150

    static func parse(_ html: String) -> [HTMLNode] {
        var scanner = Scanner(html)
        return parseChildren(&scanner, closingTag: nil, depth: 0)
    }

    private static func parseChildren(_ scanner: inout Scanner, closingTag: String?, depth: Int) -> [HTMLNode] {
        var nodes: [HTMLNode] = []
        while !scanner.isAtEnd {
            if scanner.peek() == "<" {
                // Comment or doctype.
                if scanner.matches("<!--") {
                    scanner.skipUntil("-->")
                    continue
                }
                if scanner.matches("<!") {
                    scanner.skipPast(">")
                    continue
                }
                if scanner.matches("</") {
                    let tag = scanner.readTagName()
                    scanner.skipPast(">")
                    if let closingTag, tag == closingTag { return nodes }
                    // Stray close tag for a different element: ignore and go on.
                    continue
                }
                // Opening tag.
                scanner.advance() // consume '<'
                let tag = scanner.readTagName()
                let attributes = scanner.readAttributes()
                let selfClosed = scanner.consumeTagEnd()
                if tag.isEmpty { continue }
                if voidTags.contains(tag) || selfClosed {
                    nodes.append(HTMLNode(kind: .element(tag: tag, attributes: attributes), children: []))
                } else if rawTextTags.contains(tag) {
                    scanner.skipUntil("</\(tag)")
                    scanner.skipPast(">")
                    // Raw-text elements contribute no design nodes.
                } else if depth >= maxDepth {
                    // Past the depth cap: keep this element as a leaf and do not
                    // recurse. Its children parse as siblings at this level and
                    // the matching close tags fall through as strays, which
                    // bounds recursion without dropping the tag itself.
                    nodes.append(HTMLNode(kind: .element(tag: tag, attributes: attributes), children: []))
                } else {
                    let children = parseChildren(&scanner, closingTag: tag, depth: depth + 1)
                    nodes.append(HTMLNode(kind: .element(tag: tag, attributes: attributes), children: children))
                }
            } else {
                let text = scanner.readUntil("<")
                if !text.isEmpty {
                    nodes.append(HTMLNode(kind: .text(text), children: []))
                }
            }
        }
        return nodes
    }

    // A character scanner over the HTML string. Index-based so it never copies
    // the backing storage while walking.
    private struct Scanner {
        private let chars: [Character]
        private var index: Int = 0

        init(_ s: String) { chars = Array(s) }

        var isAtEnd: Bool { index >= chars.count }

        func peek() -> Character? { index < chars.count ? chars[index] : nil }

        mutating func advance() { index += 1 }

        mutating func matches(_ prefix: String) -> Bool {
            let p = Array(prefix)
            guard index + p.count <= chars.count else { return false }
            for i in 0..<p.count where chars[index + i] != p[i] { return false }
            index += p.count
            return true
        }

        mutating func readTagName() -> String {
            var name = ""
            while index < chars.count {
                let c = chars[index]
                if c.isLetter || c.isNumber || c == "-" || c == ":" {
                    name.append(Character(c.lowercased()))
                    index += 1
                } else {
                    break
                }
            }
            return name
        }

        mutating func readAttributes() -> [String: String] {
            var attrs: [String: String] = [:]
            while index < chars.count {
                skipSpaces()
                guard let c = peek() else { break }
                if c == ">" || c == "/" { break }
                var key = ""
                while index < chars.count {
                    let ch = chars[index]
                    if ch.isWhitespace || ch == "=" || ch == ">" || ch == "/" { break }
                    key.append(Character(ch.lowercased()))
                    index += 1
                }
                skipSpaces()
                var value = ""
                if peek() == "=" {
                    index += 1
                    skipSpaces()
                    if let q = peek(), q == "\"" || q == "'" {
                        index += 1
                        while index < chars.count, chars[index] != q {
                            value.append(chars[index]); index += 1
                        }
                        if index < chars.count { index += 1 } // closing quote
                    } else {
                        while index < chars.count {
                            let ch = chars[index]
                            if ch.isWhitespace || ch == ">" { break }
                            value.append(ch); index += 1
                        }
                    }
                }
                if !key.isEmpty { attrs[key] = value }
            }
            return attrs
        }

        // Consume the end of an opening tag. Returns true when it was a
        // self-closing tag ("/>").
        mutating func consumeTagEnd() -> Bool {
            skipSpaces()
            var selfClosed = false
            if peek() == "/" { selfClosed = true; index += 1 }
            if peek() == ">" { index += 1 }
            return selfClosed
        }

        mutating func readUntil(_ stop: Character) -> String {
            var out = ""
            while index < chars.count, chars[index] != stop {
                out.append(chars[index]); index += 1
            }
            return out
        }

        mutating func skipUntil(_ marker: String) {
            let m = Array(marker)
            while index < chars.count {
                if index + m.count <= chars.count {
                    var hit = true
                    for i in 0..<m.count where chars[index + i] != m[i] { hit = false; break }
                    if hit { index += m.count; return }
                }
                index += 1
            }
        }

        mutating func skipPast(_ stop: Character) {
            while index < chars.count {
                let c = chars[index]; index += 1
                if c == stop { return }
            }
        }

        private mutating func skipSpaces() {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }
    }
}
