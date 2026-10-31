import XCTest
@testable import Grux

/// "All the settings tabs should be consistent padding/margin."
///
/// That was not adjustable when it was asked for, because the panes did not
/// share a number to adjust: nine sub-panes, four container shapes, six
/// hand-written `.padding()` calls. The fix is structural, so the test is too.
/// It does not check that the padding is a particular value, it checks that
/// there is only one place a value could be written.
final class SettingsChromeTests: XCTestCase {

    private func codeLines(_ path: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(path)
        // Comment lines are dropped WHOLE rather than truncated at "//".
        // Truncating is how a sibling test lost a brace after a URL-shaped
        // literal and started returning nil.
        return try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// Every Form in the Settings window wears the same chrome.
    ///
    /// This is the invariant that makes the panes agree. A new sub-pane that
    /// forgets it is the exact regression that produced the reported bug, and it
    /// now costs a red test rather than a screenshot on somebody's Mac Mini.
    func testEveryFormInSettingsRoutesThroughTheSharedChrome() throws {
        let lines = try codeLines("Sources/Grux/SettingsView.swift")
        let forms = lines.filter { $0.contains("Form {") }.count
        let chromed = lines.filter { $0.contains(".modifier(SettingsFormChrome())") }.count

        // Anti-vacuity: a scan that finds nothing must not read as a pass.
        XCTAssertGreaterThan(forms, 0, "No Form found. The scan is broken, not the file.")
        XCTAssertEqual(chromed, forms,
                       "\(forms) Form blocks, \(chromed) wearing SettingsFormChrome. "
                        + "Every Form in this file routes through the shared chrome.")
    }

    /// The chrome has to actually set the style, or it is a no-op that passes.
    ///
    /// `.formStyle(.grouped)` is the half that fixes the label column rendering
    /// outside the pane. Without it the test above would still pass on six Forms
    /// that all look equally wrong.
    func testTheSharedChromeSetsTheGroupedFormStyle() throws {
        let lines = try codeLines("Sources/Grux/SettingsView.swift")
        guard let i = lines.firstIndex(where: {
            $0.contains("private struct SettingsFormChrome: ViewModifier")
        }) else {
            return XCTFail("SettingsFormChrome was renamed or removed.")
        }
        let body = lines[i ..< min(i + 12, lines.count)].joined(separator: "\n")
        XCTAssertTrue(body.contains(".formStyle(.grouped)"),
                      "The shared chrome no longer sets a form style, so the columns "
                        + "layout is back and labels render outside the pane.")
    }

    /// The sub-panes that live in their OWN files have to agree too.
    ///
    /// The shared chrome only reaches the Forms declared inside SettingsView.
    /// Four sub-panes delegate to a view in another file, and those were exactly
    /// where the inconsistency survived: measured on the Mini 2026-08-30, Data &
    /// Security rendered its content 73pt left of where General started and 80pt
    /// wider, because BackupView was a bare ScrollView with its own padding and
    /// hand-rolled title-plus-Divider section headers.
    ///
    /// PresetsView is deliberately NOT in this list. It is a master-detail list
    /// and editor, not a settings form, and dressing it as one would be making
    /// two different things look the same rather than making one thing
    /// consistent.
    func testDelegatedSettingsPanesUseTheSameGroupedStyle() throws {
        let panes = [
            "Sources/Grux/Backup/BackupView.swift",
            "Sources/Grux/Security/SecuritySettingsView.swift",
            "Sources/Grux/Settings/TerminalSessionsSettingsView.swift",
            "Sources/Grux/DesignSystem/AppearanceSettingsView.swift",
        ]
        for path in panes {
            let lines = try codeLines(path)
            XCTAssertTrue(lines.contains { $0.contains(".formStyle(.grouped)") },
                          "\(path) does not set .formStyle(.grouped), so its tab will not "
                            + "match the others.")
        }
    }

    /// No pane may go back to hand-rolling its own padding on a Form.
    func testNoFormCarriesItsOwnBarePadding() throws {
        let lines = try codeLines("Sources/Grux/SettingsView.swift")
        let bare = lines.enumerated().filter {
            $0.element.trimmingCharacters(in: .whitespaces) == ".padding()"
                || $0.element.trimmingCharacters(in: .whitespaces) == "}.padding()"
        }
        XCTAssertTrue(bare.isEmpty,
                      "Bare .padding() is back at line(s) \(bare.map { $0.offset + 1 }). "
                        + "Padding belongs in SettingsFormChrome.")
    }

    /// D89 (sense pass 7): a grouped Form promotes a field's title to the row label, so
    /// Security read "host, e.g. example.com" beside an empty field, the example posing as the
    /// setting's name. In a Settings form the title names the setting and an example, or the
    /// shape of a value ("sk_..."), goes in `prompt:`, where it sits in the field as a hint.
    /// Every file whose views render inside a Settings form is listed, including the sections
    /// Settings, Models embeds (wave 22: the list missed them), and a title on the next line counts.
    func testNoSettingsFieldIsTitledWithAnExample() throws {
        let files = [
            "Sources/Grux/SettingsView.swift",
            "Sources/Grux/Backup/BackupView.swift",
            "Sources/Grux/Security/SecuritySettingsView.swift",
            "Sources/Grux/Settings/TerminalSessionsSettingsView.swift",
            "Sources/Grux/DesignSystem/AppearanceSettingsView.swift",
            "Sources/Grux/Settings/CapabilityCredentialsSection.swift",
            "Sources/Grux/Backend/ModelConfigView.swift",
            "Sources/Grux/MCP/MCPRegistryView.swift",
        ]
        let title = try NSRegularExpression(pattern: #"(TextField|SecureField)\(\s*"([^"]*)""#)
        for path in files {
            let code = try codeLines(path).joined(separator: "\n")
            let range = NSRange(code.startIndex..., in: code)
            for m in title.matches(in: code, range: range) {
                let text = (code as NSString).substring(with: m.range(at: 2))
                let lower = text.lowercased()
                XCTAssertFalse(lower.contains("e.g.") || lower.contains("for example") || text.hasSuffix("\u{2026}"),
                               "\(path): a field titled \"\(text)\" shows the example as its label")
            }
        }
    }

    /// W22-P3 item 10: MCP's Env hint said "comma or newline separated" in a
    /// one-line field, where Return saves instead of starting a line. A hint on
    /// a single-line field never asks for a newline or one entry per line.
    func testNoOneLineFieldAsksForNewlines() throws {
        let files = [
            "Sources/Grux/SettingsView.swift",
            "Sources/Grux/Backup/BackupView.swift",
            "Sources/Grux/Security/SecuritySettingsView.swift",
            "Sources/Grux/Settings/TerminalSessionsSettingsView.swift",
            "Sources/Grux/DesignSystem/AppearanceSettingsView.swift",
            "Sources/Grux/Settings/CapabilityCredentialsSection.swift",
            "Sources/Grux/Backend/ModelConfigView.swift",
            "Sources/Grux/MCP/MCPRegistryView.swift",
        ]
        for path in files {
            XCTAssertEqual(Self.oneLineFieldsAskingForNewlines(try codeLines(path).joined(separator: "\n")), [],
                           "\(path): a one-line field asks for newlines")
        }
    }

    /// Wave 23 round 1: the scan read only the line holding `TextField(`, while fields here
    /// put `prompt:` on the next line, and it missed "its own line".
    func testTheNewlineHintGuardReadsTheWholeCall() {
        let offenders = [
            "TextField(\"Env\", text: $x,\n    prompt: Text(\"KEY=value, one per line\"))",
            #"TextField("Hosts", text: $x, prompt: Text("each on its own line"))"#,
            #"TextField("Env", text: $x, prompt: Text("KEY=value, comma or newline separated"))"#,
            "TextField(\n    \"Hosts (optional)\",\n    text: $x,\n    prompt: Text(\"one host per line\")\n)",
            // Round 2: other words for a line, an escape, a space before the paren.
            #"TextField("Hosts", text: $x, prompt: Text("one host on each line"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("hosts on separate lines"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("line-separated hosts"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("one per row"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("press Return between hosts"))"#,
            #"TextField("Env", text: $x, prompt: Text("KEY=value\nOTHER=value"))"#,
            #"TextField ("Hosts", text: $x, prompt: Text("one per line"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("one per line"), axis: .horizontal)"#,
            // Round 3: every escape for a line break, a real one, "linebreak", and a vertical
            // neighbour in the same group excusing nothing.
            ##"TextField("Env", text: $x, prompt: Text(#"KEY=value\#nOTHER=value"#))"##,
            #"TextField("Env", text: $x, prompt: Text("KEY=value\u{0A}OTHER=value"))"#,
            #"TextField("Env", text: $x, prompt: Text("KEY=value\rOTHER=value"))"#,
            "TextField(\"Env\", text: $x, prompt: Text(\"\"\"\n    KEY=value\n    OTHER=value\n    \"\"\"))",
            #"TextField("Hosts", text: $x, prompt: Text("linebreak-separated hosts"))"#,
            "AnyView(Group {\n    TextField(\"Notes\", text: $n, axis: .vertical)\n    TextField(\"Hosts\", text: $h, prompt: Text(\"one per line\"))\n})",
            // Round 4: the Return and Enter keys in any phrasing, and a secure field.
            #"TextField("Hosts", text: $x, prompt: Text("press the Return key after each host"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("hit the Enter key between hosts"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("hosts separated by Return"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Return-separated hosts"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Shift-Return for another host"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("multiline list of hosts"))"#,
            #"SecureField("Keys", text: $x, prompt: Text("one key per line"))"#,
            // Round 5: Enter the key after "press", whatever follows.
            #"TextField("Hosts", text: $x, prompt: Text("Press Enter one more time between hosts"))"#,
            // Round 6: Enter the key anywhere but as a hint's first word before its object.
            #"TextField("Hosts", text: $x, prompt: Text("Enter-separated hosts"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Separate hosts with Enter or commas"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Comma or Enter separated"))"#,
            // Round 7: Enter before a hyphen, a comma or any word that is not its object.
            #"TextField("Hosts", text: $x, prompt: Text("Enter-delimited hosts"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Enter separates hosts"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Enter-terminated entries"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Enter adds another host"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Enter, Tab or comma between hosts"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Press ") + Text("Enter once per host"))"#,
            // Round 8: Enter the key mid-sentence before punctuation or an object-like word.
            #"TextField("Hosts", text: $x, prompt: Text("Separate hosts with Enter. The first one is the default"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Separate hosts with Enter (one per host)"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Add a host, then use Enter; any number works"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Pressing Enter a second time adds a host"))"#,
            // Round 9: Enter before any word that is not its object, whatever its ending.
            #"TextField("Hosts", text: $x, prompt: Text("Enter always adds another host"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Enter appends a host"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Enter advances to the next host"))"#,
            #"TextField("Hosts", text: $x, prompt: Text("Enter has to follow each host"))"#,
        ]
        for code in offenders {
            XCTAssertFalse(Self.oneLineFieldsAskingForNewlines(code).isEmpty, "passed the hint guard: \(code)")
        }
        for code in ["TextField(\"Notes\", text: $x,\n    prompt: Text(\"one per line\"), axis: .vertical)",
                     #"TextField("Env", text: $x, prompt: Text("KEY=value, OTHER=value"))"#,
                     "TextField(\"Env\", text: $x)\nText(\"Separate entries per line in the file.\")",
                     // Round 3 P3: ordinary copy, and a caption beside the field in its group.
                     #"TextField("Key", text: $x, prompt: Text("Enter your key"))"#,
                     #"TextField("Command line", text: $x)"#,
                     // Round 5 P3: Enter the verb before any noun, and "returns" in a description.
                     #"SecureField("API key", text: $x, prompt: Text("Enter API key"))"#,
                     #"TextField("Port", text: $x, prompt: Text("Enter port number"))"#,
                     // Round 8 P3: a title that is a key word, and a plural object.
                     #"TextField("Type", text: $x, prompt: Text("Enter a value"))"#,
                     // Round 9 P3: "Re-enter" is the verb.
                     #"SecureField("Passphrase", text: $x, prompt: Text("Re-enter your passphrase"))"#,
                     #"TextField("Key command", text: $x, prompt: Text("Shell command that returns your key"))"#,
                     "Group {\n    TextField(\"Env\", text: $e)\n    Text(\"One per line in the file.\")\n}"] {
            XCTAssertEqual(Self.oneLineFieldsAskingForNewlines(code), [], code)
        }
    }

    /// Every `TextField` and `SecureField` call read by its own parentheses (`SwiftSource.calls`:
    /// a `prompt:` on a later line, any spacing, never a neighbour in the same group): unless the
    /// field is `axis: .vertical`, none of its words names a line, a row, a paragraph, the Return
    /// key or the Enter key (not the verb), and none holds a line break (typed in a `"""` literal or as `\n`,
    /// `\#n`, `\r`, `\u{0A}`).
    static func oneLineFieldsAskingForNewlines(_ code: String) -> [String] {
        let lineWords: Set<String> = ["line", "lines", "newline", "newlines", "row", "rows", "return",
                                      "multiline", "paragraph", "paragraphs", "carriage"]
        // "Enter" the verb ("Enter your key", "Re-enter your passphrase") asks for nothing; the
        // key does. The verb is only a literal's own first word, then one space and an object
        // word; Enter anywhere else, last, before punctuation ("Enter-delimited", "with Enter.
        // The first") or before any other word ("Enter adds", "Enter always adds") is the key.
        let objects: Set<String> = ["your", "a", "an", "the", "it", "this", "that", "one", "any", "here",
                                    "text", "name", "api", "token", "port", "url", "password", "passphrase",
                                    "email", "value", "number", "code", "address", "host", "hostname",
                                    "username", "user", "id", "path", "command", "secret", "label", "title",
                                    "message", "query", "model", "server", "endpoint"]
        func enterIsTheKey(_ text: String) -> Bool {
            let rx = try! NSRegularExpression(pattern: #"(?i)\benter\b"#)
            let ns = text as NSString
            for m in rx.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let before = ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces)
                let after = ns.substring(from: m.range.location + m.range.length)
                let next = after.dropFirst().prefix(while: \.isLetter).lowercased()
                let opens = before.isEmpty || before.lowercased() == "re-"
                let isVerb = opens && after.hasPrefix(" ") && objects.contains(next)
                if !isVerb { return true }
            }
            return false
        }
        let breaks = ##"\\#*(?:n|r|u\{0*[aAdD]\})|\n|\r"##
        let fields = SwiftSource.calls(named: "TextField", in: code) + SwiftSource.calls(named: "SecureField", in: code)
        return fields.compactMap { call -> String? in
            guard call.code.range(of: #"axis:\s*\.vertical"#, options: .regularExpression) == nil else { return nil }
            let words = call.literals.map(\.text).joined(separator: " ")
            let plain = words.replacingOccurrences(of: #"command[\s-]line"#, with: " ", options: [.regularExpression, .caseInsensitive])
            let runs = SwiftSource.letterWords(plain)
            let enterKey = call.literals.contains { enterIsTheKey($0.text) }
            let asks = call.literals.contains { $0.text.range(of: breaks, options: .regularExpression) != nil }
                || runs.contains(where: { lineWords.contains($0) || $0.hasPrefix("linebreak") || $0.hasPrefix("linefeed") })
                || enterKey
            return asks ? "line \(call.line): \(words)" : nil
        }
    }
}
