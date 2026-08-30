import Foundation

// Deep research data model. A ResearchJob is one end-to-end run of the
// DeepResearchEngine pipeline: plan, gather, synthesize, report. Pure data
// plus the pure report-assembly logic live here so citation numbering and
// report assembly are unit-testable with zero network.

// MARK: - Phases

enum ResearchPhase: String, Codable {
    case queued
    case planning
    case gathering
    case synthesizing
    case done
    case failed

    var label: String {
        switch self {
        case .queued: return "Queued"
        case .planning: return "Planning"
        case .gathering: return "Gathering"
        case .synthesizing: return "Synthesizing"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }

    var isTerminal: Bool { self == .done || self == .failed }
}

// MARK: - Source document

// One web source that fed the report. `quote` is the short extract that was
// actually shown to the model, kept so the sources list can show provenance.
struct SourceDoc: Codable, Identifiable, Hashable {
    var id: UUID
    var url: String
    var title: String
    var quote: String
    var angle: String

    init(id: UUID = UUID(), url: String, title: String, quote: String, angle: String = "") {
        self.id = id
        self.url = url
        self.title = title
        self.quote = quote
        self.angle = angle
    }
}

// MARK: - Report section

struct ReportSection: Codable, Hashable {
    var heading: String
    var body: String

    init(heading: String, body: String) {
        self.heading = heading
        self.body = body
    }
}

// MARK: - Job

struct ResearchJob: Codable, Identifiable {
    var id: UUID
    var question: String
    var title: String
    var createdAt: Date
    var completedAt: Date?
    var phase: ResearchPhase
    var angles: [String]
    var sources: [SourceDoc]
    var reportMarkdown: String
    var progressLines: [String]
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        question: String,
        title: String = "",
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        phase: ResearchPhase = .queued,
        angles: [String] = [],
        sources: [SourceDoc] = [],
        reportMarkdown: String = "",
        progressLines: [String] = [],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.question = question
        self.title = title
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.phase = phase
        self.angles = angles
        self.sources = sources
        self.reportMarkdown = reportMarkdown
        self.progressLines = progressLines
        self.errorMessage = errorMessage
    }

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.count > 70 ? String(q.prefix(70)) + "…" : q
    }
}

// MARK: - Report assembly (pure logic)

// All citation-numbering and report-assembly rules. Everything in here is a
// pure function over value types so GruxTests can pin the behavior down.
enum ResearchReportAssembler {

    // Canonical form for dedupe: lowercase scheme/host, drop "www.", drop the
    // fragment, drop a single trailing slash on the path.
    static func normalizeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hashIdx = s.firstIndex(of: "#") {
            s = String(s[..<hashIdx])
        }
        guard var comps = URLComponents(string: s) else {
            return s.lowercased()
        }
        comps.scheme = comps.scheme?.lowercased()
        var host = (comps.host ?? "").lowercased()
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        comps.host = host
        if comps.path.hasSuffix("/") && comps.path.count > 1 {
            comps.path = String(comps.path.dropLast())
        }
        return comps.string ?? s.lowercased()
    }

    // Dedupe sources by normalized URL while preserving first-seen order.
    // Returns the unique ordered list plus a remap from each ORIGINAL 1-based
    // position to its FINAL 1-based citation number.
    static func dedupeAndNumber(_ sources: [SourceDoc]) -> (ordered: [SourceDoc], remap: [Int: Int]) {
        var seen: [String: Int] = [:]   // normalized URL -> final number
        var ordered: [SourceDoc] = []
        var remap: [Int: Int] = [:]
        for (i, src) in sources.enumerated() {
            let key = normalizeURL(src.url)
            if let existing = seen[key] {
                remap[i + 1] = existing
            } else {
                ordered.append(src)
                let final = ordered.count
                seen[key] = final
                remap[i + 1] = final
            }
        }
        return (ordered, remap)
    }

    // Rewrite inline citation markers like [3] using the remap, in a single
    // pass so swap mappings (1 -> 2, 2 -> 1) never cascade. Numbers without a
    // mapping are left untouched.
    static func remapCitations(in text: String, using remap: [Int: Int]) -> String {
        guard !remap.isEmpty,
              let re = try? NSRegularExpression(pattern: #"\[(\d{1,3})\]"#) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges > 1 else { return }
            let numStr = ns.substring(with: match.range(at: 1))
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let old = Int(numStr), let new = remap[old] {
                out += "[\(new)]"
            } else {
                out += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // The synthesis model is told NOT to emit its own bibliography, but models
    // drift. Drop any trailing "## Sources" / "## References" section so the
    // canonical numbered list we append is the only one.
    static func stripModelSourcesSection(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces).lowercased()
            if t.hasPrefix("## sources") || t.hasPrefix("## references") || t.hasPrefix("## bibliography") {
                return lines[..<i].joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Split a synthesized markdown report into (title, sections). The first
    // "# " line becomes the title; "## " lines open sections; any preamble
    // before the first section becomes a heading-less section.
    static func parseSections(_ markdown: String) -> (title: String, sections: [ReportSection]) {
        var title = ""
        var sections: [ReportSection] = []
        var currentHeading = ""
        var currentBody: [String] = []

        func flush() {
            let body = currentBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty || !currentHeading.isEmpty {
                sections.append(ReportSection(heading: currentHeading, body: body))
            }
            currentBody = []
        }

        // The synthesis model often emits a conversational lead-in before the
        // "# Title" ("Sure, here's the report."). Capture the FIRST `# ` line
        // that appears before any `## ` section as the title and discard the
        // preamble, rather than requiring the title on the very first non-blank
        // line (which lost the title and produced a duplicate H1 on drift).
        var titleCaptured = false
        for line in markdown.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !titleCaptured, sections.isEmpty, t.hasPrefix("# "), !t.hasPrefix("## ") {
                title = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                titleCaptured = true
                currentBody = []  // drop any preamble that preceded the title
                continue
            }
            if t.hasPrefix("## ") {
                titleCaptured = true  // no title before the first section: stop scanning
                flush()
                currentHeading = String(t.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            currentBody.append(line)
        }
        flush()
        return (title, sections)
    }

    // Build the final report markdown: title, sections in order, then the
    // canonical numbered sources list. Citation numbers in section bodies are
    // expected to already match the order of `sources`.
    static func assemble(title: String, question: String, sections: [ReportSection], sources: [SourceDoc]) -> String {
        var out: [String] = []
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.append("# \(t.isEmpty ? question : t)")
        for section in sections {
            if !section.heading.isEmpty {
                out.append("## \(section.heading)")
            }
            if !section.body.isEmpty {
                out.append(section.body)
            }
        }
        if !sources.isEmpty {
            out.append("## Sources")
            var rows: [String] = []
            for (i, src) in sources.enumerated() {
                let name = src.title.trimmingCharacters(in: .whitespacesAndNewlines)
                rows.append("\(i + 1). [\(name.isEmpty ? src.url : name)](\(src.url))")
            }
            out.append(rows.joined(separator: "\n"))
        }
        return out.joined(separator: "\n\n")
    }

    // First paragraph under "## Executive Summary" when present, otherwise the
    // first non-heading paragraph. Used for the chat tool's short answer.
    static func executiveSummary(from markdown: String) -> String {
        let (_, sections) = parseSections(markdown)
        if let exec = sections.first(where: { $0.heading.lowercased().contains("executive") }) {
            return firstContentParagraph(of: exec.body)
        }
        for section in sections where !section.body.isEmpty {
            let p = firstContentParagraph(of: section.body)
            if !p.isEmpty { return p }
        }
        return ""
    }

    // True when a paragraph is nothing but a bold/plain "Executive Summary"
    // label (e.g. "**Executive Summary**"). When the synthesis model bolds the
    // label instead of using a `## ` heading, parseSections never makes an
    // "executive" section, so the label itself would otherwise be returned and
    // persisted into SemanticMemory as the researched answer.
    private static func isHeadingLabel(_ paragraph: String) -> Bool {
        let stripped = paragraph
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return stripped == "executive summary" || stripped == "summary"
    }

    // First non-empty paragraph that is not merely a heading label.
    private static func firstContentParagraph(of text: String) -> String {
        for raw in text.components(separatedBy: "\n\n") {
            let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty, !isHeadingLabel(p) else { continue }
            return p
        }
        return ""
    }
}
