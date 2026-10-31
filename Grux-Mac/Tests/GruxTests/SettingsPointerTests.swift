import XCTest
@testable import Grux

/// EVERY "SETTINGS, X" NAMES A PLACE A PERSON CAN FIND.
///
/// Found on sense pass 5 (D74, 2026-10-30): the Presets help said a local
/// preset "needs a discovered local server (Settings, Offline mode)". Settings
/// has five panes and none is called Offline mode; the switch is a section
/// inside Models. The same scan found "Settings, Upgrades" and "Settings,
/// Model & API" (tabs folded away in the 5-pane consolidation) and "Open
/// Settings, Privacy and Security, Full Disk Access", which is a place in
/// macOS's System Settings, not Grux's.
///
/// The rule: in copy, a capitalised place right after "Settings, " (or after
/// "Settings, then " or "Settings, under ") is one of the panes the Settings
/// window lists, read live from `SettingsPane`, so a pane renamed later turns
/// every stale pointer red at once.
final class SettingsPointerTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The pointers in `text` whose place is not a Settings pane.
    static func strayPointers(in text: String, file: String) -> [String] {
        let panes = SettingsPane.allCases.map(\.label)
        var out: [String] = []
        for (n, line) in text.components(separatedBy: "\n").enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            // The arrow form too: "Settings \u{2192} Upgrades" slipped past a
            // scan for the comma alone (wave 18 review).
            for separator in ["Settings, ", "Settings \u{2192} ", "Settings -> "] {
            var search = line.startIndex..<line.endIndex
            while let hit = line.range(of: separator, range: search) {
                search = hit.upperBound..<line.endIndex
                let before = line[line.startIndex..<hit.lowerBound]
                if before.hasSuffix("System ") || before.hasSuffix("Xcode \u{2192} ") { continue }
                var rest = Substring(line[hit.upperBound...])
                for lead in ["then ", "under "] where rest.hasPrefix(lead) {
                    rest = rest.dropFirst(lead.count)
                }
                guard let first = rest.first, first.isUppercase else { continue }
                let named = panes.contains { pane in
                    guard rest.hasPrefix(pane) else { return false }
                    let after = rest.dropFirst(pane.count).first
                    return after.map { !$0.isLetter } ?? true
                }
                if !named { out.append("\(file):\(n + 1): \(trimmed)") }
            }
            }
        }
        return out
    }

    func testEveryPointerInTheAppNamesASettingsPane() throws {
        let sources = root.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 100, "Sources did not load")
        var stray: [String] = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            // Every line but a comment: the line of a multi-line literal
            // carries no quote mark (wave 18 review, SlackTool's description).
            stray += Self.strayPointers(in: text, file: url.lastPathComponent)
        }
        // The heal map has to hold the old words to recognise them; nothing
        // else may. Read live, so a key that is not an old seed is not exempt.
        let oldSeeds = PresetStore.seededNoteFixes.keys
        stray.removeAll { line in
            line.hasPrefix("PresetStore.swift:") && oldSeeds.contains { line.contains("\"\($0)\":") }
        }
        XCTAssertEqual(stray, [], "These point at a Settings place that does not exist:\n" + stray.joined(separator: "\n"))
    }

    func testTheReadmeNamesPlacesThatExist() throws {
        let readme = try String(contentsOf: root.deletingLastPathComponent().appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertEqual(Self.strayPointers(in: readme, file: "README.md"), [])
        // "Pull a model and Grux will use it" was untrue: with no key, chat
        // reads localModelFoundButNotRouted until Offline mode is turned on.
        let flat = readme.replacingOccurrences(of: "\n", with: " ")
        XCTAssertFalse(flat.contains("picks it up automatically"),
                       "The README promises a local model is used with no step; Offline mode must be turned on")
        XCTAssertTrue(flat.contains("Settings, Models"), "The README names where Offline mode is")
        // Local Models is a page reached by asking for it, not a tab (wave 18 review).
        XCTAssertFalse(flat.contains("Local Models tab"), "The README names a Local Models tab")
    }

    func testTheScannerCatchesAPlantedPointer() {
        let planted = """
        let a = "Enable it in Settings, Upgrades."
        let b = "Open Settings, Privacy and Security, Full Disk Access"
        let c = "Turn it on in Settings, under Data & Capabilities, in the section"
        let ok1 = "Open System Settings, Privacy and Security, Microphone"
        let ok2 = "Add one in Settings, Models, Offline mode (local model)."
        let ok3 = "Settings, then Models, downloads one"
        let ok4 = "Check the key in Settings, then retry."
        let ok5 = "Settings, Data & Security, Security"
        let d = "Add it under Settings \u{2192} Upgrades."
        let e = "Open Settings \u{2192} Privacy \u{2192} Microphone and enable Grux"
            Requires their Slack connection set up in \\
            Settings -> Integrations. Returns ok
        let ok6 = "Grant it in System Settings \u{2192} Privacy & Security \u{2192} Automation"
        let ok7 = "Install one via Xcode \u{2192} Settings \u{2192} Platforms."
        let ok8 = "Add one in Settings \u{2192} Models."
        // Settings, Upgrades in a comment is not copy.
        """
        XCTAssertEqual(Self.strayPointers(in: planted, file: "planted").count, 6)
    }

    /// The Offline / Private preset is seeded ONCE and saved, so an install
    /// seeded before the fix keeps the old pointer in its own presets file
    /// unless the store heals it on load.
    @MainActor
    func testASeededPresetWithTheOldPointerIsHealedOnLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("presets.json")
        let old = Preset(name: "Offline / Private", kind: .chat, systemPrompt: "x", providerOverride: "local",
                         notes: "Pinned to the local model. Slower, but private. Needs a discovered local server (Settings, Offline mode).")
        let mine = Preset(name: "Mine", kind: .chat, systemPrompt: "y",
                          notes: "My own words (Settings, Offline mode).")
        let payload = PresetFilePayload(seeded: true, presets: [old, mine])
        Persistence.save(payload, to: url)
        let store = PresetStore(fileURL: url)
        let healed = try XCTUnwrap(store.preset(named: "Offline / Private"))
        XCTAssertEqual(Self.strayPointers(in: "\"\(healed.notes)\"", file: "preset"), [])
        XCTAssertTrue((healed.notes).contains("Settings, Models"))
        // A person's own words are theirs, whatever they say.
        XCTAssertEqual(store.preset(named: "Mine")?.notes, "My own words (Settings, Offline mode).")
    }
}
