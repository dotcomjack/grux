import XCTest
@testable import Grux

// Pure-logic coverage for ResearchReportAssembler: URL normalization,
// source dedupe + citation numbering, single-pass citation remapping, section
// parsing, and final report assembly. The DeepResearchEngine network paths
// are deliberately not exercised here, everything below stays offline.
final class ResearchReportAssemblyTests: XCTestCase {

    private func src(_ url: String, title: String = "t", quote: String = "q") -> SourceDoc {
        SourceDoc(url: url, title: title, quote: quote)
    }

    // MARK: - normalizeURL

    func test_normalizeURL_dropsWWWFragmentAndTrailingSlash() {
        let a = ResearchReportAssembler.normalizeURL("https://www.Example.com/page/#section")
        let b = ResearchReportAssembler.normalizeURL("https://example.com/page")
        XCTAssertEqual(a, b)
    }

    func test_normalizeURL_keepsQueryDistinct() {
        let a = ResearchReportAssembler.normalizeURL("https://example.com/p?q=1")
        let b = ResearchReportAssembler.normalizeURL("https://example.com/p?q=2")
        XCTAssertNotEqual(a, b)
    }

    func test_normalizeURL_keepsRootSlash() {
        let a = ResearchReportAssembler.normalizeURL("https://example.com/")
        XCTAssertTrue(a.contains("example.com"))
    }

    // MARK: - dedupeAndNumber

    func test_dedupeAndNumber_noDuplicatesIsIdentity() {
        let sources = [src("https://a.com/1"), src("https://b.com/2"), src("https://c.com/3")]
        let (ordered, remap) = ResearchReportAssembler.dedupeAndNumber(sources)
        XCTAssertEqual(ordered.count, 3)
        XCTAssertEqual(remap, [1: 1, 2: 2, 3: 3])
    }

    func test_dedupeAndNumber_duplicateCollapsesToFirstSeen() {
        let sources = [
            src("https://a.com/x"),
            src("https://www.a.com/x/"),     // dupe of 1 after normalization
            src("https://b.com/y")
        ]
        let (ordered, remap) = ResearchReportAssembler.dedupeAndNumber(sources)
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].url, "https://a.com/x")
        XCTAssertEqual(ordered[1].url, "https://b.com/y")
        XCTAssertEqual(remap, [1: 1, 2: 1, 3: 2])
    }

    func test_dedupeAndNumber_preservesFirstSeenOrderAcrossAngles() {
        let sources = [
            src("https://one.com"),
            src("https://two.com"),
            src("https://two.com"),
            src("https://three.com"),
            src("https://one.com")
        ]
        let (ordered, remap) = ResearchReportAssembler.dedupeAndNumber(sources)
        XCTAssertEqual(ordered.map(\.url), ["https://one.com", "https://two.com", "https://three.com"])
        XCTAssertEqual(remap, [1: 1, 2: 2, 3: 2, 4: 3, 5: 1])
    }

    func test_dedupeAndNumber_emptyInput() {
        let (ordered, remap) = ResearchReportAssembler.dedupeAndNumber([])
        XCTAssertTrue(ordered.isEmpty)
        XCTAssertTrue(remap.isEmpty)
    }

    // MARK: - remapCitations

    func test_remapCitations_rewritesMappedNumbers() {
        let out = ResearchReportAssembler.remapCitations(
            in: "Costs fell 40% [2] while output rose [3].",
            using: [2: 1, 3: 2]
        )
        XCTAssertEqual(out, "Costs fell 40% [1] while output rose [2].")
    }

    func test_remapCitations_swapDoesNotCascade() {
        // A naive sequential string replace would turn [1] -> [2] -> [1].
        let out = ResearchReportAssembler.remapCitations(
            in: "first [1] second [2]",
            using: [1: 2, 2: 1]
        )
        XCTAssertEqual(out, "first [2] second [1]")
    }

    func test_remapCitations_leavesUnmappedNumbersAlone() {
        let out = ResearchReportAssembler.remapCitations(
            in: "known [1] unknown [9]",
            using: [1: 4]
        )
        XCTAssertEqual(out, "known [4] unknown [9]")
    }

    func test_remapCitations_handlesMultiDigitAndAdjacent() {
        let out = ResearchReportAssembler.remapCitations(
            in: "stacked [10][11] end",
            using: [10: 1, 11: 2]
        )
        XCTAssertEqual(out, "stacked [1][2] end")
    }

    func test_remapCitations_ignoresNonNumericBrackets() {
        let text = "see [note] and [TODO]"
        let out = ResearchReportAssembler.remapCitations(in: text, using: [1: 2])
        XCTAssertEqual(out, text)
    }

    // MARK: - parseSections

    func test_parseSections_titleAndHeadings() {
        let md = """
        # AI Hardware in 2026

        ## Executive Summary

        Demand outpaces supply [1].

        ## Market Landscape

        Three players dominate [2][3].
        """
        let (title, sections) = ResearchReportAssembler.parseSections(md)
        XCTAssertEqual(title, "AI Hardware in 2026")
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].heading, "Executive Summary")
        XCTAssertEqual(sections[0].body, "Demand outpaces supply [1].")
        XCTAssertEqual(sections[1].heading, "Market Landscape")
    }

    func test_parseSections_preambleBecomesHeadinglessSection() {
        let md = "Just a paragraph with no headings."
        let (title, sections) = ResearchReportAssembler.parseSections(md)
        XCTAssertEqual(title, "")
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].heading, "")
        XCTAssertEqual(sections[0].body, md)
    }

    // The synthesis model commonly emits a conversational lead-in before the
    // "# Title". The old guard required the title on the first non-blank line,
    // so on drift the title was lost and assemble() produced two H1 lines.
    func test_parseSections_capturesTitleAfterPreamble() {
        let md = """
        Sure, here's the report.

        # Best Espresso Machines 2026

        ## Executive Summary

        The top pick is the X1 [1].
        """
        let (title, sections) = ResearchReportAssembler.parseSections(md)
        XCTAssertEqual(title, "Best Espresso Machines 2026", "title survives a conversational preamble")
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].heading, "Executive Summary")
        // Assembled report must have exactly one H1.
        let assembled = ResearchReportAssembler.assemble(
            title: title, question: "best espresso machines",
            sections: sections, sources: [])
        let h1Count = assembled.components(separatedBy: "\n").filter {
            $0.hasPrefix("# ") && !$0.hasPrefix("## ")
        }.count
        XCTAssertEqual(h1Count, 1, "assembled report must not contain a duplicate H1")
    }

    // When the model bolds "Executive Summary" instead of using a ## heading,
    // executiveSummary used to return the label itself, which then poisoned
    // SemanticMemory. It must skip the label and return the real first answer.
    func test_executiveSummary_skipsBoldHeadingLabel() {
        let md = """
        # T

        **Executive Summary**

        The answer is forty-two [1].
        """
        let summary = ResearchReportAssembler.executiveSummary(from: md)
        XCTAssertEqual(summary, "The answer is forty-two [1].")
        XCTAssertNotEqual(summary, "**Executive Summary**")
    }

    // MARK: - stripModelSourcesSection

    func test_stripModelSourcesSection_dropsTrailingBibliography() {
        let md = """
        ## Findings

        Fact [1].

        ## Sources

        1. something the model invented
        """
        let out = ResearchReportAssembler.stripModelSourcesSection(md)
        XCTAssertTrue(out.contains("Fact [1]."))
        XCTAssertFalse(out.lowercased().contains("invented"))
        XCTAssertFalse(out.contains("## Sources"))
    }

    func test_stripModelSourcesSection_noopWithoutBibliography() {
        let md = "## Findings\n\nFact [1]."
        XCTAssertEqual(ResearchReportAssembler.stripModelSourcesSection(md), md)
    }

    // MARK: - assemble

    func test_assemble_buildsTitleSectionsAndNumberedSources() {
        let sections = [
            ReportSection(heading: "Executive Summary", body: "Answer first [1]."),
            ReportSection(heading: "Detail", body: "More depth [2].")
        ]
        let sources = [
            src("https://a.com", title: "Alpha"),
            src("https://b.com", title: "Beta")
        ]
        let out = ResearchReportAssembler.assemble(
            title: "Report Title",
            question: "fallback?",
            sections: sections,
            sources: sources
        )
        XCTAssertTrue(out.hasPrefix("# Report Title"))
        XCTAssertTrue(out.contains("## Executive Summary"))
        XCTAssertTrue(out.contains("## Detail"))
        XCTAssertTrue(out.contains("## Sources"))
        XCTAssertTrue(out.contains("1. [Alpha](https://a.com)"))
        XCTAssertTrue(out.contains("2. [Beta](https://b.com)"))
        // Sources list comes after the body sections.
        let sourcesIdx = out.range(of: "## Sources")!.lowerBound
        let detailIdx = out.range(of: "## Detail")!.lowerBound
        XCTAssertTrue(detailIdx < sourcesIdx)
    }

    func test_assemble_fallsBackToQuestionWhenTitleEmpty() {
        let out = ResearchReportAssembler.assemble(
            title: "",
            question: "What changed?",
            sections: [ReportSection(heading: "", body: "Body.")],
            sources: []
        )
        XCTAssertTrue(out.hasPrefix("# What changed?"))
        XCTAssertFalse(out.contains("## Sources"))
    }

    func test_assemble_headinglessSectionRendersBodyOnly() {
        let out = ResearchReportAssembler.assemble(
            title: "T",
            question: "q",
            sections: [ReportSection(heading: "", body: "Plain body.")],
            sources: []
        )
        XCTAssertTrue(out.contains("Plain body."))
        XCTAssertFalse(out.contains("## \n"))
    }

    // MARK: - executiveSummary

    func test_executiveSummary_prefersExecutiveSection() {
        let md = """
        # T

        ## Background

        Setup text.

        ## Executive Summary

        The short answer is yes [1].

        More detail in a second paragraph.
        """
        let out = ResearchReportAssembler.executiveSummary(from: md)
        XCTAssertEqual(out, "The short answer is yes [1].")
    }

    func test_executiveSummary_fallsBackToFirstParagraph() {
        let md = "## Findings\n\nFirst paragraph wins.\n\nSecond paragraph."
        XCTAssertEqual(ResearchReportAssembler.executiveSummary(from: md), "First paragraph wins.")
    }

    // MARK: - end-to-end assembly (dedupe + remap + assemble)

    func test_pipeline_renumberingFlowsIntoAssembledReport() {
        // Two angles, three raw sources, the middle one a duplicate of the first.
        let raw = [
            src("https://a.com/x", title: "Alpha"),
            src("https://www.a.com/x/", title: "Alpha dupe"),
            src("https://b.com/y", title: "Beta")
        ]
        let (ordered, remap) = ResearchReportAssembler.dedupeAndNumber(raw)
        let note = "Claim one [1]. Claim two [2]. Claim three [3]."
        let renumbered = ResearchReportAssembler.remapCitations(in: note, using: remap)
        XCTAssertEqual(renumbered, "Claim one [1]. Claim two [1]. Claim three [2].")

        let out = ResearchReportAssembler.assemble(
            title: "T",
            question: "q",
            sections: [ReportSection(heading: "Findings", body: renumbered)],
            sources: ordered
        )
        XCTAssertTrue(out.contains("1. [Alpha](https://a.com/x)"))
        XCTAssertTrue(out.contains("2. [Beta](https://b.com/y)"))
        XCTAssertFalse(out.contains("Alpha dupe"))
        // No citation in the body exceeds the number of listed sources.
        XCTAssertFalse(out.contains("[3]"))
    }
}
