import XCTest
@testable import Grux

/// No surface a person reads may ask them to run a Terminal command.
///
/// This is a source scan rather than a behaviour test because the defect kept
/// coming back in a new file each time. Five instances were found by hand, in
/// five separate reviews, over the life of the capability registry work:
///
///   1. A tab's setup prompt, "defaults write com.gruxai.grux <a config key>"
///   2. `ReactorView`, a raw provider payload rendered as an error
///   3. `DomainMonitor`, three storage locations offered at once, one of them
///      an environment variable
///   4. A `static let` setup hint, the same sentence as 1, still reachable
///      through the error banner after the prompt above it was deleted
///   5. `SettingsView`, "Set with: defaults write com.gruxai.grux <a config key>
///      <a value>"
///
/// Each was fixed individually and the class survived every time, because
/// nothing stopped the next one from being typed. Jack's instruction was to stop
/// fixing instances and fix the class: catch it, and do not let it repeat more
/// than three times. It has repeated five, so this is the guard.
///
/// Developer comments are deliberately allowed. `defaults write` is genuinely
/// how a config key gets set during development, and documenting that next to
/// the code that reads it is useful. The rule is only that it must never reach a
/// rendered string.
final class NoTerminalInstructionsInUITests: XCTestCase {

    /// Substrings that mean somebody is being told to configure GRUX from a
    /// shell.
    ///
    /// Package-manager installs are deliberately NOT here, and the distinction
    /// is the rule rather than an exemption carved to make the test pass.
    /// `CookbookView` says to install Ollama, a separate program that Grux cannot
    /// install for you, so naming the command is the most useful thing that screen
    /// can do. (`PhonePairingView` used to be the second example, saying to install
    /// cloudflared. The tunnel was gutted and that string is gone, so the example
    /// went with it rather than being left here describing code that no longer
    /// exists.) `defaults write` is the opposite case: it configures Grux's own
    /// settings, which Grux can always offer as a field, so a Terminal
    /// instruction there is never the best available answer. Every one of the
    /// five historical instances was Grux configuring itself.
    /// Kept to exactly the command that actually caused the defect, five times.
    ///
    /// `sudo`, `chmod` and `launchctl` were on this list for one revision and
    /// every hit was noise: `ShellSafety` names `sudo` because it REFUSES it,
    /// and `IOSDoctor` names `sudo xcode-select` because that configures Xcode,
    /// which Grux cannot do for you. Neither is the defect. A guard that cries
    /// wolf gets deleted by the next person, so this one only claims what it can
    /// prove.
    private let bannedInUserFacingStrings = [
        "defaults write"
    ]

    private var sourcesDirectory: URL {
        // Tests/GruxTests/<this file> -> up three -> Grux-Mac, then Sources.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private func swiftFiles() throws -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        let walker = fm.enumerator(at: sourcesDirectory,
                                   includingPropertiesForKeys: nil)
        while let item = walker?.nextObject() as? URL {
            if item.pathExtension == "swift" { out.append(item) }
        }
        return out
    }

    /// The scan must actually find the source tree. Without this the test passes
    /// by walking an empty directory, which is the same vacuous shape as a suite
    /// that collects zero tests and exits 0.
    func testScanReachesTheSourceTree() throws {
        let files = try swiftFiles()
        XCTAssertGreaterThan(files.count, 100,
                             "expected the Grux source tree at \(sourcesDirectory.path); "
                             + "found \(files.count) Swift files, so the scan below proves nothing")
    }

    /// Scans STRING LITERALS, not SwiftUI constructors.
    ///
    /// The constructor-shaped version of this test was written first and it was
    /// too narrow to catch its own motivating bugs. Three of the five instances
    /// never appear inside a `Text(...)`: `DomainMonitor` assigned its sentence
    /// to a `@Published var lastError`, `UsageQuery.setupHint` was a `static
    /// let`, and both reached the screen one hop later. A scan that only looks
    /// where the string is DRAWN misses every string that is drawn somewhere
    /// else, which is most of them.
    ///
    /// So the rule is about the literal itself: a sentence that says `defaults
    /// write` is a Terminal instruction no matter which variable carries it to
    /// the window.
    /// The double-quoted runs on a line, which is what a person might read.
    ///
    /// Scanning whole LINES instead flagged `static let service =
    /// "com.gruxai.grux"` and the bare defaults keys beside it, such as
    /// `"grux.github.repos"`, the constant definitions themselves. Those are the
    /// key names the app stores things under. They have to say what they say, and
    /// nobody reads them.
    private func literals(in line: String) -> [String] {
        var out: [String] = []
        var current: String?
        for ch in line {
            if ch == "\"" {
                if let done = current { out.append(done); current = nil } else { current = "" }
            } else if current != nil {
                current?.append(ch)
            }
        }
        return out
    }

    /// A sentence, as opposed to an identifier or a path fragment. Three spaces
    /// is enough to separate "Set with: defaults write com.gruxai.grux ..." from
    /// "grux.github.repos".
    private func readsAsProse(_ literal: String) -> Bool {
        literal.filter { $0 == " " }.count >= 3
    }

    private func offences(matching banned: [String], label: String) throws -> [String] {
        var found: [String] = []

        for file in try swiftFiles() {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (index, rawLine) in text.components(separatedBy: .newlines).enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)

                // Developer comments are allowed, see the note on the type.
                if line.hasPrefix("//") || line.hasPrefix("*") { continue }

                for literal in literals(in: line) where readsAsProse(literal) {
                    guard let hit = banned.first(where: { literal.contains($0) }) else { continue }
                    found.append("\(file.lastPathComponent):\(index + 1) \(label) '\(hit)': \(literal)")
                }
            }
        }
        return found
    }

    func testNoUserFacingStringAsksForATerminalCommand() throws {
        let found = try offences(matching: bannedInUserFacingStrings, label: "contains")

        XCTAssertTrue(found.isEmpty,
                      "a string is telling somebody to open a Terminal to configure Grux. Give "
                      + "them a field or a button instead, or route the feature through the "
                      + "capability registry so the shared setup card speaks for it.\n"
                      + found.joined(separator: "\n"))
    }

    /// The other half of the same class: an internal IDENTIFIER is not an
    /// instruction. A person cannot act on `goDaddyApiKey`, because it names a
    /// slot inside the app rather than anything they can see.
    ///
    /// Naming the Keychain itself is deliberately allowed, and the first version
    /// of this test got that wrong. It flagged ten lines including "Tokens are
    /// stored in your macOS Keychain. Nothing is sent to a server" and "Grux
    /// stores it in your Mac's Keychain and sends it nowhere else". Those are not
    /// jargon leaking into the UI, they are the privacy promise, and the Keychain
    /// is an application the user can open. Deleting those sentences to satisfy a
    /// linter would have made the app worse and less honest in order to make a
    /// test green.
    ///
    /// The distinction that survives: the STORE may be named, because it
    /// reassures. The SLOT may not, because it instructs and cannot be followed.
    func testNoUserFacingStringNamesAnInternalIdentifier() throws {
        // `UserDefaults.standard` was here and came out: the only hits were
        // `ConventionAuditRunner`, whose reports are ABOUT source code, so
        // naming an API is the report's content rather than jargon leaking into
        // a user's way. Concrete key names stay, since those are the ones a
        // person was being asked to go and set.
        let identifiers = ["com.gruxai.grux",
                           "goDaddyApiKey", "goDaddyApiSecret",
                           "GODADDY_API_"]
        let found = try offences(matching: identifiers, label: "names")

        XCTAssertTrue(found.isEmpty,
                      "a user-facing string names an internal identifier.\n"
                      + found.joined(separator: "\n"))
    }
}
