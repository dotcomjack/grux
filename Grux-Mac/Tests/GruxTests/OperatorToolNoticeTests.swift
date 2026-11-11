import XCTest
@testable import Grux

/// The notice that admits four surfaces are somebody else's tooling.
///
/// The failure this guards against is not a crash, it is a LIE THAT AGES. The
/// prompts name real files, and a file that gets renamed six months from now
/// turns a helpful prompt into an instruction to read something that is not
/// there. That would be worse than the bare empty state it replaced, because it
/// wastes a reader's turn and reads as carelessness. So the paths are checked
/// against the disk rather than trusted.
@MainActor
final class OperatorToolNoticeTests: XCTestCase {

    // MARK: - Agreement with the registry

    func testEveryOperatorToolIsARealRegistryRow() {
        let ids = Set(FeatureRegistry.rows.map(\.id))
        for tool in OperatorTool.all {
            XCTAssertTrue(ids.contains(tool.id),
                "\(tool.id) is not a FeatureRegistry row id. Note the table is keyed on the "
                + "ROW id, not the sidebar tab key: meta.ads not metaAds.")
        }
    }

    func testLabelsMatchTheRegistry() {
        for tool in OperatorTool.all {
            let row = FeatureRegistry.rows.first { $0.id == tool.id }
            XCTAssertEqual(tool.label, row?.label,
                "\(tool.id) calls itself \(tool.label) here and \(row?.label ?? "nothing") in "
                + "the registry, so the sidebar and the notice would disagree.")
        }
    }

    /// THE BIDIRECTIONAL HALF, and the reason this whole component exists.
    ///
    /// These four get the notice precisely BECAUSE CapabilityGate cannot reach
    /// them: a row with no blocking requirement is `.ready`, so the gate is a
    /// no-op and the tab falls through to whatever it renders empty. If somebody
    /// later gives one of them a blocking requirement, the gate starts firing and
    /// the reader would meet a setup card AND this notice for the same surface.
    /// That is the moment to reconsider, so the test fails and says so.
    func testOperatorToolsHaveNoBlockingRequirements() {
        for tool in OperatorTool.all {
            guard let row = FeatureRegistry.rows.first(where: { $0.id == tool.id }) else {
                XCTFail("\(tool.id) has no registry row"); continue
            }
            XCTAssertTrue(row.blocking.isEmpty,
                "\(tool.id) now blocks on \(row.blocking). CapabilityGate will fire for it, so "
                + "it would show a setup card and this notice at once. Pick one.")
        }
    }

    func testIdsAreUniqueAndTheListIsTheFourKnownTools() {
        XCTAssertEqual(Set(OperatorTool.all.map(\.id)).count, OperatorTool.all.count,
                       "duplicate id in OperatorTool.all")
        XCTAssertEqual(Set(OperatorTool.all.map(\.id)),
                       ["social", "meta.ads", "feature.review"],
                       "the operator tool set changed. That is allowed, but it is a decision: "
                       + "update this expectation deliberately rather than to make a test pass.")
    }

    // MARK: - The prompts

    func testPromptsAreUsableAsHandedOver() {
        for tool in OperatorTool.all {
            XCTAssertFalse(tool.prompt.isEmpty, "\(tool.id) has no prompt")
            XCTAssertFalse(tool.plainly.isEmpty, "\(tool.id) says nothing plainly")
            // The bracket is the tailoring. Without it the reader sends a generic
            // request and gets a generic answer, which is the thing this is for.
            XCTAssertTrue(tool.prompt.contains("[") && tool.prompt.contains("]"),
                "\(tool.id) prompt has no bracketed blank, so nothing asks the reader what "
                + "their business actually is")
            // A coding agent that does not know which project it is looking at will
            // guess, so every prompt names the app.
            XCTAssertTrue(tool.prompt.contains("Grux AI"),
                "\(tool.id) prompt does not say which app it is about")
            // THE UPSTREAM HALF OF ShippedBundleHygieneTests. These strings compile
            // into the binary, so a prompt naming the author puts his handle in the
            // shipped bundle. That test caught it once, 44 seconds into a full run,
            // by scanning a Mach-O. Catching it here instead is instant and points
            // at the file that actually has to change. Needle assembled at runtime
            // so this test file is not itself a leak.
            let handle = "dotcom" + "jack"
            XCTAssertFalse(tool.prompt.lowercased().contains(handle),
                "\(tool.id) prompt names the author, which ships inside the binary")
            XCTAssertTrue(tool.prompt.contains("Sources/Grux/"),
                "\(tool.id) prompt sends an agent looking without naming a file")
        }
    }

    /// Every `Sources/Grux/...` path a prompt names must exist. This is the test
    /// that stops the prompts rotting: a rename that misses this file fails here
    /// rather than in a stranger's terminal.
    func testEveryPathNamedInAPromptExistsOnDisk() throws {
        let root = Self.packageRoot()
        for tool in OperatorTool.all {
            for path in Self.sourcePaths(in: tool.prompt) {
                let url = root.appendingPathComponent(path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                    "\(tool.id) prompt tells an agent to read \(path), which does not exist. "
                    + "A prompt naming a moved file is worse than no prompt.")
            }
        }
    }

    /// Proves the path extractor is not vacuously passing. A checker that finds
    /// nothing agrees with every prompt, including a broken one.
    func testThePathExtractorActuallyFindsPaths() {
        let found = OperatorTool.all.flatMap { Self.sourcePaths(in: $0.prompt) }
        XCTAssertGreaterThanOrEqual(found.count, OperatorTool.all.count,
            "extracted only \(found.count) paths from \(OperatorTool.all.count) prompts, so "
            + "the existence test above is checking almost nothing")
        XCTAssertTrue(Self.sourcePaths(in: "read Sources/Grux/Nope/Missing.swift please")
                        == ["Sources/Grux/Nope/Missing.swift"],
                      "the extractor cannot pull a path out of a plain sentence")
    }

    // MARK: - Helpers

    /// Pulls every `Sources/Grux/...` path out of prose. Stops at whitespace and
    /// at the punctuation that ends a sentence, so a trailing comma or full stop
    /// is not read as part of the filename.
    // MARK: - The chat handover (D116 item 7)

    /// Every prompt asks for source read, a rebuild and a test run, which only an
    /// agent does. Chat on its own (a local model, or a key with Agents signed out)
    /// answers it with a reply that cannot act, so the button waits on Agents.
    func testOpenInChatIsOfferedOnlyWhenChatAndAgentsBothWork() {
        let ready = "Ready"
        XCTAssertTrue(OperatorTool.offersChatHandover(chatReady: true, agentsChosen: true, agentsStatus: ready))
        XCTAssertNil(OperatorTool.chatHandoverNote(chatReady: true, agentsChosen: true, agentsStatus: ready))
        for status in ["Needs a Claude sign-in", "Needs 1 thing", "Needs 2 things"] {
            XCTAssertFalse(OperatorTool.offersChatHandover(chatReady: true, agentsChosen: true, agentsStatus: status),
                           "chat was offered a code rebuild while Agents reads \(status)")
        }
        XCTAssertFalse(OperatorTool.offersChatHandover(chatReady: true, agentsChosen: false, agentsStatus: ready),
                       "chat was offered a code rebuild with Agents turned off")
        for chosen in [true, false] {
            XCTAssertFalse(OperatorTool.offersChatHandover(chatReady: false, agentsChosen: chosen, agentsStatus: ready))
            // With chat not usable, copying is the whole story; no second dead end.
            XCTAssertNil(OperatorTool.chatHandoverNote(chatReady: false, agentsChosen: chosen, agentsStatus: ready))
        }
    }

    func testTheNoteSaysWhatAgentsStillNeeds() {
        XCTAssertEqual(OperatorTool.chatHandoverNote(chatReady: true, agentsChosen: true,
                                                     agentsStatus: "Needs a Claude sign-in"),
                       "Grux chat can make this change once Agents can run. Agents needs a Claude sign-in.")
        XCTAssertEqual(OperatorTool.chatHandoverNote(chatReady: true, agentsChosen: true,
                                                     agentsStatus: "Needs 2 things"),
                       "Grux chat can make this change once Agents can run. Agents needs 2 things.")
        XCTAssertEqual(OperatorTool.chatHandoverNote(chatReady: true, agentsChosen: false,
                                                     agentsStatus: "Ready"),
                       "Grux chat can make this change once Agents can run. Agents is turned off.")
    }

    /// The view asks the rule above with this Mac's answers, not the chat tab alone.
    func testTheViewGatesTheButtonOnTheRule() throws {
        let src = try String(contentsOf: Self.packageRoot()
            .appendingPathComponent("Sources/Grux/Onboarding/OperatorToolNotice.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("if OperatorTool.offersChatHandover("),
                      "the Open in Grux chat button is not gated on offersChatHandover")
        XCTAssertTrue(src.contains("OperatorTool.chatHandoverNote("),
                      "the view never shows why the chat handover is missing")
        XCTAssertTrue(src.contains("YourGrux.status(\"agents\")"),
                      "the view does not read Agents' status from the rule first run uses")
    }

    static func sourcePaths(in text: String) -> [String] {
        var out: [String] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            guard token.hasPrefix("Sources/Grux/") else { continue }
            let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)"))
            if !trimmed.isEmpty { out.append(String(trimmed)) }
        }
        return out
    }

    static func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)     // .../Grux-Mac/Tests/GruxTests/ThisFile.swift
            .deletingLastPathComponent()    // .../Grux-Mac/Tests/GruxTests
            .deletingLastPathComponent()    // .../Grux-Mac/Tests
            .deletingLastPathComponent()    // .../Grux-Mac
    }
}
