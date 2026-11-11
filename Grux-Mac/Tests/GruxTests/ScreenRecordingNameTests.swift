import XCTest
@testable import Grux

/// D116 item 5 (sense pass 11, 2026-11-01): one macOS permission had three
/// names on one screen. The status bar said "Needs screen access", Settings
/// offered "Request screen recording…", the Focus log said "screen recording"
/// and setup cards said "Screen Recording". A stranger looking in System
/// Settings finds "Screen Recording", so that is the one name. Every string
/// literal in the app and the CLI is read, comments out, so a new "screen
/// access" or a lowercase "screen recording" turns this red.
final class ScreenRecordingNameTests: XCTestCase {
    /// Whole literals where another spelling is right, each with its reason.
    private static let rightWord: [(file: String, piece: String)] = [
        ("SettingsSearchRegistry.swift", "screen recording"),  // a lowercase search keyword, never shown
        // The stamp macOS puts on a recording's file name, matched by file naming, never shown.
        ("FileNamingRules.swift",
         #"^(img[_-][0-9]|pxl_[0-9]|dsc[f_]?[0-9]|screenshot[ _-]?[0-9]|screen shot [0-9]|cleanshot [0-9]|screen recording [0-9])"#),
    ]

    private static func sources() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var out: [(String, String)] = []
        for module in ["Grux", "GruxCLI"] {
            guard let walker = FileManager.default.enumerator(at: root.appendingPathComponent(module),
                                                              includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                out.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return out
    }

    /// "screen access" in any case, or "screen recording" spelled any way but
    /// "Screen Recording".
    static func namesItAnotherWay(_ text: String) -> Bool {
        if text.range(of: #"(?i)screen\s+access(?![A-Za-z])"#, options: .regularExpression) != nil { return true }
        var from = text.startIndex
        while let r = text.range(of: #"(?i)screen\s+recording"#, options: .regularExpression, range: from..<text.endIndex) {
            if text[r] != "Screen Recording" { return true }
            from = r.upperBound
        }
        return false
    }

    func test_theMatcherReadsEveryForm() {
        for yes in ["Needs screen access", "Grant Screen Access", "Request screen recording…",
                    "macOS has not allowed screen recording.", "SCREEN RECORDING", "Screen recording is off"] {
            XCTAssertTrue(Self.namesItAnotherWay(yes), yes)
        }
        for no in ["Needs Screen Recording", "Grant Screen Recording", "screenshot", "Screen Recording, and enable Grux.",
                   "on-screen accessibility"] {
            XCTAssertFalse(Self.namesItAnotherWay(no), no)
        }
    }

    func test_thePermissionHasOneName() throws {
        let files = try Self.sources()
        XCTAssertGreaterThan(files.count, 300, "the scan read almost nothing; the path is wrong")
        var hits: [String] = []
        for (name, text) in files {
            for lit in SwiftSource.literals(text) where Self.namesItAnotherWay(lit.text)
                && !Self.rightWord.contains(where: { $0.file == name && lit.text == $0.piece }) {
                hits.append("\(name):\(lit.line) \(lit.text.prefix(90))")
            }
        }
        XCTAssertEqual(hits, [], "say Screen Recording, the name System Settings shows:\n" + hits.joined(separator: "\n"))
    }

    /// W32-P3 item 3: a path to the permission named the pane "Screen
    /// Recording" ("System Settings → Privacy & Security → Screen Recording →
    /// Grux"), and from macOS 15 the pane is "Screen & System Audio Recording",
    /// with the app listed as Grux AI. A path names the pane the way
    /// `CapabilityRequest.settingsPath` does, measured on this Mac.
    static func namesTheOldPane(_ text: String) -> Bool {
        text.range(of: #"(?i)privacy\s+(and|&)\s+security\W+screen\s+recording"#, options: .regularExpression) != nil
    }

    @MainActor
    func test_aPathNamesThePaneMacOSShows() throws {
        XCTAssertTrue(Self.namesTheOldPane("Open System Settings, Privacy and Security, Screen Recording, and enable Grux."))
        XCTAssertTrue(Self.namesTheOldPane("System Settings → Privacy & Security → Screen Recording → Grux."))
        XCTAssertFalse(Self.namesTheOldPane("System Settings > Privacy & Security > Screen & System Audio Recording"))
        var hits: [String] = []
        for (name, text) in try Self.sources() {
            for lit in SwiftSource.literals(text) where Self.namesTheOldPane(lit.text) {
                hits.append("\(name):\(lit.line) \(lit.text.prefix(90))")
            }
        }
        XCTAssertEqual(hits, [], "name the pane as CapabilityRequest.settingsPath does:\n" + hits.joined(separator: "\n"))
        XCTAssertEqual(CapabilityRequest.settingsPath(for: .permScreenRecording),
                       "System Settings > Privacy & Security > Screen & System Audio Recording")
    }

    /// The setup card's line and `grux why` read the contract's sentence, so
    /// it names the same pane and the app as the list shows it.
    @MainActor
    func test_theContractSentenceNamesThePaneAndTheApp() {
        for req in [SetupRequirement.permScreenRecording, .permSystemAudio] {
            XCTAssertTrue(req.remediation.contains("System Settings, Privacy & Security, Screen & System Audio Recording"),
                          req.remediation)
            XCTAssertTrue(req.remediation.contains("Grux AI"), req.remediation)
        }
    }

    /// The vision tool's refusal is read back to a person by the model.
    @MainActor
    func test_theVisionRefusalNamesThePane() {
        XCTAssertTrue(VisionTool.notGrantedLine.contains(CapabilityRequest.settingsPath(for: .permScreenRecording)),
                      VisionTool.notGrantedLine)
        XCTAssertTrue(VisionTool.notGrantedLine.contains("Grux AI"), VisionTool.notGrantedLine)
    }
}
