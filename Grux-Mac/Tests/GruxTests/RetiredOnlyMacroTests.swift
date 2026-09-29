import XCTest
@testable import Grux

/// A macro whose EVERY step was a retired action must stop answering its phrase.
///
/// Terminal Focus left with its two macro actions. A macro that also did other things
/// keeps doing them (`RetiredMacroKindTests`). A macro that did nothing else, like
/// `overlay_on` and `overlay_off` on the owner's Mac, would decode with no steps and keep
/// matching "overlay on" while doing nothing. So it is set aside: out of the live list,
/// named once where macros are managed, and kept on disk so it can be recovered.
@MainActor
final class RetiredOnlyMacroTests: XCTestCase {

    private var dir: URL!
    private var file: URL { dir.appendingPathComponent("macros.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("retired-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let retired = MacroAction.retiredKinds.sorted()
        let json = """
        [
          {"name": "overlay_on", "triggers": ["overlay on"], "description": "", "actions": [
            {"action": {"kind": "\(retired[0])"}, "enabled": true}, {"kind": "\(retired[1])"}]},
          {"name": "cockpit", "triggers": ["cockpit"], "description": "", "actions": [
            {"action": {"kind": "launchApp", "name": "Notes"}, "enabled": true},
            {"action": {"kind": "\(retired[0])"}, "enabled": true}]},
          {"name": "dashboard", "triggers": ["dashboard"], "description": "", "actions": [
            {"action": {"kind": "openURL", "url": "https://example.com"}, "enabled": true}]},
          {"name": "draft", "triggers": [], "description": "", "actions": []}
        ]
        """
        try Data(json.utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func loaded() -> VoiceMacroRegistry {
        let r = VoiceMacroRegistry(fileURL: file)
        r.load()
        return r
    }

    func testAMacroWhoseEveryStepWasRetiredIsSetAside() {
        let r = loaded()
        XCTAssertEqual(r.macros.map(\.name), ["cockpit", "dashboard", "draft"])
        XCTAssertEqual(r.setAside, ["overlay_on"])
        XCTAssertEqual(r.macros.first { $0.name == "cockpit" }?.actions.map(\.action),
                       [.launchApp(name: "Notes")], "a macro with other steps keeps them")
    }

    /// THE CONTROL: a macro with no steps at all is somebody's unfinished command, not a
    /// retired one, and must stay.
    func testABlankMacroIsNotSetAside() {
        XCTAssertTrue(loaded().macros.contains { $0.name == "draft" })
    }

    func testItsPhraseNoLongerMatches() {
        let r = loaded()
        let router = VoiceCommandRouter(
            engine: DecisionEngine(keyLookup: { "" }, ledger: DecisionLedger(storeURL: nil)),
            threshold: { 0.7 }, macros: { r.macros })
        let ids = Set(router.vocabulary().map(\.id))
        XCTAssertTrue(ids.contains("macro:dashboard"), "control: a live macro is not offered")
        XCTAssertFalse(ids.contains("macro:overlay_on"), "a macro with nothing left to do still answers its phrase")
        XCTAssertNil(r.find(name: "overlay_on"))
    }

    /// Nothing is deleted from disk: an edit to another macro writes the set-aside one
    /// back unchanged, and the next load sets it aside again.
    func testSavingKeepsTheSetAsideMacroOnDisk() throws {
        let r = loaded()
        var dash = try XCTUnwrap(r.macros.first { $0.name == "dashboard" })
        dash.description = "edited"
        r.upsert(dash)

        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        let kept = try XCTUnwrap(raw.first { $0["name"] as? String == "overlay_on" },
                                 "the set-aside macro was deleted from disk by an unrelated edit")
        XCTAssertEqual((kept["actions"] as? [Any])?.count, 2, "its steps were not written back as they were")

        let again = loaded()
        XCTAssertEqual(again.setAside, ["overlay_on"])
        XCTAssertEqual(again.macros.first { $0.name == "dashboard" }?.description, "edited")
    }

    /// A new live macro that reuses the set-aside name answers its phrase, and the notice
    /// stops claiming that name is silent. The set-aside one stays on disk.
    func testANewLiveMacroWithTheSameNameIsNotReportedAsSilent() throws {
        let r = loaded()
        r.upsert(Macro(name: "overlay_on", triggers: ["overlay on"], description: "",
                       rawActions: [.openURL(url: "https://example.com")]))
        XCTAssertEqual(r.setAside, [], "the notice would say overlay_on is silent while a live one answers")
        XCTAssertNotNil(r.find(name: "overlay_on"))
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(raw.filter { $0["name"] as? String == "overlay_on" }.count, 2,
                       "the set-aside macro left the disk when a live one took its name")
    }

    func testTheNoticeNamesTheMacrosAndSaysWhy() throws {
        XCTAssertNil(CommandsView.setAsideNotice([]))
        let line = try XCTUnwrap(CommandsView.setAsideNotice(["overlay_on", "overlay_off"]))
        XCTAssertTrue(line.contains("overlay_on") && line.contains("overlay_off"), line)
        XCTAssertTrue(line.contains("Terminal Focus"), "the line does not say why: \(line)")
        XCTAssertFalse(line.contains("\n"), "more than one line: \(line)")
    }
}
