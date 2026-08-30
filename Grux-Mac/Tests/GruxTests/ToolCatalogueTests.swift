import XCTest
@testable import Grux

/// Pins the size and shape of the tool catalogue `ChatService.allTools()`
/// advertises to the model.
///
/// ## Why a count needs a test at all
///
/// The first line of `README.md` sells this app on two numbers, and only one of
/// them was guarded. `FeatureRegistry` has exactly 39 rows and
/// `FeatureRegistryContractTests.testRowSetsMatchExactly` asserts that, so the
/// feature count cannot drift without a red suite. The tool count had nothing.
/// `allTools()` assembles its result at runtime from a 36 entry literal plus 25
/// `claudeTools()` groups, so any commit that adds or drops a single tool moved
/// the real number and left the README claiming the old one.
///
/// ## The count in here is the measured one, and the README now agrees
///
/// Measured 2026-08-26 by walking every `ClaudeTool(name:)` construction that
/// `allTools()` can reach: 36 declared inline in `ChatService`, 80 more across
/// the 25 appended groups, 116 total. Every one of those groups except
/// `MCPManager` returns a flat array literal with no branch in it, so the number
/// is deterministic rather than a sample.
///
/// The README's first line says one hundred sixteen too, brought up in db9b6d0
/// from the seventy nine it had carried while the catalogue grew under it. This
/// test still does not READ the README: a pin that derived its number from the
/// sentence would follow the sentence into its next mistake, and one that
/// asserted agreement would go red for a copy edit. It pins the measured count
/// and quotes the README line in the failure message so whoever moves either
/// number knows the two move together.
///
/// ## MCP servers contribute zero here, on purpose
///
/// `MCPManager.shared.claudeTools()` is the one group assembled from live state
/// rather than a literal. It reads `toolsByServer`, which stays empty until
/// `bootstrap()` starts a server, and nothing in this suite calls `bootstrap()`.
/// So the catalogue a test process sees is exactly the built in one, and the
/// count above is stable. If MCP tools are ever wired into a test they arrive
/// namespaced `mcp_<slug>_<tool>`, and `MCPToolNaming.slug(forServerName:)`
/// joins slug words with a hyphen rather than an underscore, so the naming
/// assertion below would need an explicit exemption for that prefix before it
/// could be trusted.
@MainActor
final class ToolCatalogueTests: XCTestCase {

    /// The measured size of the catalogue. Moving this is a deliberate act: see
    /// the failure message for the other line that has to move with it.
    private static let expectedToolCount = 116

    func testCatalogueCountIsPinned() {
        let tools = ChatService.allTools()
        XCTAssertEqual(tools.count, Self.expectedToolCount, """
            The tool catalogue changed size: \(tools.count) tools, this test expected \
            \(Self.expectedToolCount).

            Two things have to move together, and this is the only place that says so.

            1. `expectedToolCount` in this file.
            2. The first line of README.md, which currently reads:
               "Thirty nine features and one hundred sixteen tools in one native window."

            The two agree today (the README said seventy nine until db9b6d0 brought it \
            to the measured 116). Whoever changed the catalogue updates BOTH, the pinned \
            number here and the README sentence, to the same new number.

            The feature half of that sentence is guarded separately by \
            FeatureRegistryContractTests.
            """)
    }

    /// A duplicate name is a real bug, not a tidiness issue. The tools array goes
    /// on the wire as the `tools` parameter of the Anthropic request, and a name
    /// is the only handle the model has: two entries sharing one name means the
    /// model picks a schema at random and `dispatchTool` routes every call to
    /// whichever `case` the switch reaches first. Nothing else in the tree checks
    /// this, and the catalogue is assembled from 26 places that cannot see each
    /// other's names.
    func testEveryToolNameIsUnique() {
        let names = ChatService.allTools().map(\.name)
        var seen: Set<String> = []
        var duplicates: [String] = []
        for name in names where !seen.insert(name).inserted {
            duplicates.append(name)
        }
        XCTAssertTrue(duplicates.isEmpty, """
            Duplicate tool names in ChatService.allTools(): \(duplicates.sorted()).

            The model sees one name per tool, so a collision means it cannot address \
            the second one at all and dispatch silently answers with the first. Rename \
            one of them in the group that owns it.
            """)
    }

    /// Every one of the 116 names is lower snake case: a leading lowercase letter,
    /// then lowercase letters, digits and single underscores. That was measured,
    /// not assumed, so this assertion starts green. It exists because the groups
    /// are separate files and a contributor working only in, say, `NotesTool` has
    /// no view of the convention the other 25 places follow, which is exactly how
    /// a `createNote` arrives beside `create_note` and reads as sloppy to the
    /// first stranger who lists the tools.
    func testEveryToolNameFollowsTheSnakeCaseConvention() {
        let convention = try! NSRegularExpression(pattern: "^[a-z][a-z0-9]*(_[a-z0-9]+)*$")
        let offenders = ChatService.allTools().map(\.name).filter { name in
            let range = NSRange(location: 0, length: (name as NSString).length)
            return convention.firstMatch(in: name, range: range) == nil
        }
        XCTAssertTrue(offenders.isEmpty, """
            Tool names that break the lower snake case convention every other tool \
            follows: \(offenders.sorted()).

            Expected shape: a lowercase letter, then lowercase letters, digits and \
            single underscores, for example `create_note` or `start_workflow_v2`. \
            No camelCase, no hyphens, no leading or trailing underscore.
            """)
    }

    /// `allTools()` builds a fresh array on every call rather than returning a
    /// stored one, and the result is handed to `assemblePendingContext` on every
    /// turn. If two calls in the same process disagreed then the pinned count
    /// above would be a coin flip and, worse, the prompt cache prefix would break
    /// mid conversation. Assert the whole ordered name list, not just the size,
    /// because a stable count with a reshuffled order is the same cache miss.
    func testCatalogueIsStableAcrossCalls() {
        let first = ChatService.allTools().map(\.name)
        let second = ChatService.allTools().map(\.name)
        XCTAssertEqual(first, second, """
            ChatService.allTools() returned a different list on the second call in \
            the same process. The catalogue is assembled at runtime, so something in \
            it is reading mutable state. Both the pinned count and the prompt cache \
            prefix depend on this being deterministic.
            """)
    }
}
