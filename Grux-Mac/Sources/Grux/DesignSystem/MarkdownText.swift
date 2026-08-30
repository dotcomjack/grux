import SwiftUI

// Block-aware markdown renderer used wherever assistant-generated text is
// shown (chat bubbles, nudges, reminders, focus coach). Apple's
// AttributedString(markdown:) only handles inline syntax - it leaves `---`,
// `# heading`, fenced code, and lists as raw glyphs. This view splits the
// source into blocks first, renders structural elements as real SwiftUI,
// and falls back to AttributedString for inline bold/italic/code/links.
struct MarkdownText: View {
    let content: String
    var font: Font = .body
    var foregroundColor: Color = GruxTheme.textPrimary
    var blockSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: blockSpacing) {
            ForEach(Array(MarkdownBlockParser.parse(content).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
    }

    @ViewBuilder
    private func render(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: headingSize(level), weight: .heavy))
                .foregroundStyle(foregroundColor)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(inline(text))
                .font(font)
                .foregroundStyle(foregroundColor)
                .fixedSize(horizontal: false, vertical: true)

        case .horizontalRule:
            Rectangle()
                .fill(foregroundColor.opacity(0.18))
                .frame(height: 1)
                .padding(.vertical, 2)

        case .codeBlock(let code):
            Text(code)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.black.opacity(0.30))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                )

        case .blockQuote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(GruxTheme.accentPrimary.opacity(0.55))
                    .frame(width: 2)
                Text(inline(text))
                    .font(font.italic())
                    .foregroundStyle(foregroundColor.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•")
                            .font(font)
                            .foregroundStyle(foregroundColor.opacity(0.55))
                        Text(inline(item))
                            .font(font)
                            .foregroundStyle(foregroundColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).")
                            .font(font)
                            .foregroundStyle(foregroundColor.opacity(0.55))
                            .monospacedDigit()
                        Text(inline(item))
                            .font(font)
                            .foregroundStyle(foregroundColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return attributed
        }
        return AttributedString(text)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 18
        case 3: return 16
        case 4: return 14
        default: return 13
        }
    }
}

// MARK: - Modifier-style customization

extension MarkdownText {
    func markdownFont(_ font: Font) -> MarkdownText {
        var copy = self
        copy.font = font
        return copy
    }

    func markdownForegroundColor(_ color: Color) -> MarkdownText {
        var copy = self
        copy.foregroundColor = color
        return copy
    }

    func markdownBlockSpacing(_ spacing: CGFloat) -> MarkdownText {
        var copy = self
        copy.blockSpacing = spacing
        return copy
    }
}

// MARK: - Block model

enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case horizontalRule
    case codeBlock(String)
    case blockQuote(String)
    case bulletList([String])
    case orderedList([String])
}

// MARK: - Parser

enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = source.components(separatedBy: "\n")

        var paragraphLines: [String] = []
        var bullets: [String] = []
        var ordered: [String] = []
        var quoteLines: [String] = []

        func flushParagraph() {
            if !paragraphLines.isEmpty {
                blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
                paragraphLines.removeAll()
            }
        }
        func flushBullets() {
            if !bullets.isEmpty {
                blocks.append(.bulletList(bullets))
                bullets.removeAll()
            }
        }
        func flushOrdered() {
            if !ordered.isEmpty {
                blocks.append(.orderedList(ordered))
                ordered.removeAll()
            }
        }
        func flushQuote() {
            if !quoteLines.isEmpty {
                blocks.append(.blockQuote(quoteLines.joined(separator: "\n")))
                quoteLines.removeAll()
            }
        }
        func flushAll() {
            flushParagraph(); flushBullets(); flushOrdered(); flushQuote()
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block ``` … ```
            if trimmed.hasPrefix("```") {
                flushAll()
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let inner = lines[i].trimmingCharacters(in: .whitespaces)
                    if inner.hasPrefix("```") { break }
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.codeBlock(code.joined(separator: "\n")))
                if i < lines.count { i += 1 }
                continue
            }

            // Horizontal rule
            if isHorizontalRule(trimmed) {
                flushAll()
                blocks.append(.horizontalRule)
                i += 1
                continue
            }

            // ATX heading
            if let h = parseHeading(trimmed) {
                flushAll()
                blocks.append(.heading(level: h.level, text: h.text))
                i += 1
                continue
            }

            // Block quote
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph(); flushBullets(); flushOrdered()
                let body = trimmed == ">" ? "" : String(trimmed.dropFirst(2))
                quoteLines.append(body)
                i += 1
                continue
            }

            // Bullet list
            if let item = parseBullet(trimmed) {
                flushParagraph(); flushOrdered(); flushQuote()
                bullets.append(item)
                i += 1
                continue
            }

            // Ordered list
            if let item = parseOrdered(trimmed) {
                flushParagraph(); flushBullets(); flushQuote()
                ordered.append(item)
                i += 1
                continue
            }

            // Blank line breaks paragraphs and lists
            if trimmed.isEmpty {
                flushAll()
                i += 1
                continue
            }

            // Default: accumulate paragraph
            flushBullets(); flushOrdered(); flushQuote()
            paragraphLines.append(raw)
            i += 1
        }
        flushAll()
        return blocks
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let chars = Set(line)
        return (chars == ["-"] || chars == ["*"] || chars == ["_"])
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        let text = String(line[line.index(after: idx)...])
            .trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func parseBullet(_ line: String) -> String? {
        if line.hasPrefix("- ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("* ") { return String(line.dropFirst(2)) }
        if line.hasPrefix("+ ") { return String(line.dropFirst(2)) }
        return nil
    }

    private static func parseOrdered(_ line: String) -> String? {
        var idx = line.startIndex
        var sawDigit = false
        while idx < line.endIndex, line[idx].isNumber {
            sawDigit = true
            idx = line.index(after: idx)
        }
        guard sawDigit, idx < line.endIndex, line[idx] == "." else { return nil }
        let afterDot = line.index(after: idx)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return String(line[line.index(after: afterDot)...])
    }
}
