import XCTest
@testable import Grux

/// The assistant is renameable and most of the interface did not know.
///
/// `config.assistantName` defaults to "Jax", and Settings states the product
/// decision plainly: *"renaming the assistant does not rename the app or its
/// tabs"*. So "Jax HQ" and "Jax Command" are TAB NAMES and correctly frozen,
/// while a sentence about the assistant ACTING is not.
///
/// Measured 2026-08-22, 28 user-facing strings described the assistant by that
/// hardcoded default: the approvals empty state said "Jax pauses and asks here",
/// the notification banner said "Jax needs you", the decision gate said "Jax
/// never moves money on its own". Rename your assistant to Ada and every one of
/// them still said Jax. The setting worked in the prompt, where the assistant
/// calls itself the new name, and nowhere the user could see.
///
/// ## Why this is not a blanket search for the word
///
/// A naive scan flags "Jax HQ" and would push somebody into renaming a tab,
/// which is exactly the change the product decided against. The rule below
/// removes the two tab names FIRST and only then asks whether a bare mention
/// survives, which is the distinction that makes this checkable at all.
final class AssistantNamingTests: XCTestCase {

    /// Files whose "Jax" is legitimately hardcoded, each for a stated reason.
    /// A path is only ever added here with one.
    private static let exemptFiles: [String: String] = [
        "Models.swift": "holds the literal default value of config.assistantName",
        "UserIdentity.swift": "holds the fallback the accessor returns when unset",
        "SidebarModel.swift": "the two tab labels, which never rename",
        "FeatureRegistry.swift": "registry labels for the two tabs",
        "JaxTestHarness.swift": "an internal diagnostic harness, not user-facing copy",
        "ConfidenceStressTest.swift": "an internal diagnostic, not user-facing copy",
        "FeatureReviewEngine.swift": "a provenance string recording who built a feature",
        "SettingsView.swift": "carries the sentence that EXPLAINS the default, which has to name it",
    ]

    /// A string is a violation when a bare mention survives removing the tab
    /// names. Returns the offending literals.
    ///
    /// LINE BASED, WORD BOUNDED, AND COMMENT AWARE, and every one of those three
    /// is a bug this detector shipped with on its first run. Pairing quotes
    /// across a whole file captures the CODE BETWEEN two unrelated strings, so it
    /// reported things like `" retrieval hits the right context. if state.config"`
    /// as user copy. Matching the substring rather than the word flags
    /// `JaxProfile.shared`, `JaxTime.ago` and `JaxGoalsSection`, which are type
    /// names and not the assistant. And comments discussing the assistant are not
    /// copy anybody reads. The first version reported 23 offenders and every one
    /// was a false positive.
    static func hardcodedAssistantMentions(in source: String) -> [String] {
        var out: [String] = []
        for rawLine in source.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") || line.hasPrefix("///") || line.hasPrefix("*") { continue }
            guard line.contains("Jax") else { continue }

            for literal in Self.stringLiterals(on: line) {
                // Interpolations are code, not copy.
                var stripped = literal
                while let r = stripped.range(of: #"\\\([^)]*\)"#, options: .regularExpression) {
                    stripped.removeSubrange(r)
                }
                stripped = stripped.replacingOccurrences(of: "Jax HQ", with: "")
                stripped = stripped.replacingOccurrences(of: "Jax Command", with: "")
                if Self.containsBareWordJax(stripped) { out.append(literal) }
            }
        }
        return out
    }

    /// Double quoted literals on ONE line, respecting backslash escapes.
    private static func stringLiterals(on line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inside = false
        var escaped = false
        for ch in line {
            if escaped { if inside { current.append(ch) }; escaped = false; continue }
            if ch == "\\" { escaped = true; if inside { current.append(ch) }; continue }
            if ch == "\"" {
                if inside { out.append(current); current = "" }
                inside.toggle()
                continue
            }
            if inside { current.append(ch) }
        }
        return out
    }

    /// "Jax" as a whole word. `JaxProfile` and `JaxTime` are type names.
    private static func containsBareWordJax(_ s: String) -> Bool {
        let chars = Array(s)
        let needle = Array("Jax")
        var i = 0
        while i + needle.count <= chars.count {
            if Array(chars[i..<(i + needle.count)]) == needle {
                let beforeOK = i == 0 || !(chars[i - 1].isLetter || chars[i - 1].isNumber || chars[i - 1] == "_")
                let after = i + needle.count
                let afterOK = after >= chars.count || !(chars[after].isLetter || chars[after].isNumber || chars[after] == "_")
                if beforeOK && afterOK { return true }
            }
            i += 1
        }
        return false
    }

    /// CONTROLS, because this detector decides what counts as a bug and a
    /// detector that answers "clean" to everything is the failure mode every
    /// scan in this repo has hit at least once.
    func testTheDetectorItselfWorks() {
        XCTAssertEqual(
            Self.hardcodedAssistantMentions(in: #"Text("Jax pauses and asks here.")"#),
            ["Jax pauses and asks here."],
            "control: a bare assistant mention must be caught")

        XCTAssertTrue(
            Self.hardcodedAssistantMentions(in: #"Text("Jax HQ")"#).isEmpty,
            "control: a tab name must NOT be flagged, or this test pushes somebody to rename a tab")

        XCTAssertTrue(
            Self.hardcodedAssistantMentions(in: #"Text("queued to Jax HQ for your one-tap yes")"#).isEmpty,
            "control: a tab name inside a longer sentence is still a tab name")

        XCTAssertEqual(
            Self.hardcodedAssistantMentions(in: #"Text("Jax plans and queues it to Jax HQ")"#),
            ["Jax plans and queues it to Jax HQ"],
            "control: one string can hold BOTH, and the assistant half still has to be caught")

        XCTAssertTrue(
            Self.hardcodedAssistantMentions(in: #"Text("\(UserIdentity.assistantName) pauses here.")"#).isEmpty,
            "control: copy that already reads the setting is not a violation")

        // The three false positives the first version of this detector produced.
        XCTAssertTrue(
            Self.hardcodedAssistantMentions(in: #"let x = JaxProfile.shared.persona"#).isEmpty,
            "control: JaxProfile is a type name, not the assistant")
        XCTAssertTrue(
            Self.hardcodedAssistantMentions(in: #"Text("started \(JaxTime.ago(item.addedAt))")"#).isEmpty,
            "control: JaxTime is a type name inside an interpolation, not copy")
        XCTAssertTrue(
            Self.hardcodedAssistantMentions(in: "// did Jax already learn this word").isEmpty,
            "control: a comment is not copy anybody reads")
        XCTAssertTrue(
            Self.hardcodedAssistantMentions(in: #"Text("one") ; let jaxish = 1 ; Text("two")"#).isEmpty,
            "control: the code BETWEEN two literals is not a literal")
    }

    // MARK: - The sweep

    func testNoUserFacingCopyHardcodesTheAssistantsName() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")

        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("cannot walk \(root.path)")
        }

        var scanned = 0
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            scanned += 1
            if Self.exemptFiles[url.lastPathComponent] != nil { continue }
            let src = try String(contentsOf: url, encoding: .utf8)
            for literal in Self.hardcodedAssistantMentions(in: src) {
                offenders.append("\(url.lastPathComponent): \"\(literal.prefix(64))\"")
            }
        }

        XCTAssertGreaterThan(scanned, 100, "the walk found almost no Swift files, so it proved nothing")
        XCTAssertEqual(offenders, [],
                       "these name the assistant by its default instead of reading it, so they are wrong the moment "
                       + "somebody renames it:\n  " + offenders.joined(separator: "\n  "))
    }

    /// Every exemption states why. A path added without a reason is a path
    /// somebody wanted to stop thinking about.
    func testEveryExemptionHasAReason() {
        for (file, reason) in Self.exemptFiles {
            XCTAssertGreaterThan(reason.count, 20, "\(file) is exempt with no real reason given")
        }
    }
}
