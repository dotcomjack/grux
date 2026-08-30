import XCTest
@testable import Grux

/// Every action that destroys something must ask first.
///
/// The audit that produced this found 33 destructive controls and only 7 files in
/// the entire app using a confirmation. `Reset all settings` wiped the whole
/// config on one click. `Clear memory` emptied semantic memory on one click.
/// `Remove` on a credential deleted a key that, for Anthropic, is shown exactly
/// once at creation and cannot be read back.
///
/// A source scan rather than a behaviour test, for the same reason the
/// Terminal-instruction guard is one: the failure is somebody adding the 34th
/// button, and nothing about the 33 fixed ones stops that.
///
/// ## Three shapes are acceptable
///
/// 1. `DestructiveButton`, which carries its own dialog.
/// 2. A button that DEFERS, setting a `pending`/`deleting`/`showConfirm` value
///    that a dialog on the parent view reads. This is the required shape inside a
///    `.contextMenu` or swipe action, because those dismiss when tapped and take
///    an attached dialog with them.
/// 3. A button INSIDE a `confirmationDialog` or `.alert` closure, which is the
///    confirmation itself.
///
/// ## And one is explicitly not a defect
///
/// Cheap, reversible actions that destroy no data. Clearing a search box or
/// deselecting a preset loses nothing. Putting a dialog on those is worse than
/// leaving them alone: it trains people to confirm without reading, which is
/// exactly what makes the real dialogs stop working.
final class DestructiveActionsGuardTests: XCTestCase {

    /// Verbs that suggest something is destroyed.
    private let destructiveVerbs = ["Delete", "Reset", "Remove", "Clear", "Wipe",
                                    "Erase", "Restore", "Revoke", "Disconnect",
                                    "Forget", "Purge", "Unpair", "Rotate"]

    /// Labels that match a destructive verb but destroy NOTHING. Each is listed
    /// with what it actually does, so the list cannot quietly grow into a way of
    /// silencing real findings.
    private let harmless: Set<String> = [
        "Clear search",     // empties a text field
        "Clear Snooze",     // un-snoozes, restores notifications
        "Clear preset",     // deselects, the preset still exists
        "Clear active",     // deselects, the preset still exists
        "Reset to all",     // widens a filter back to everything
        "Reset to ⌥⌘T",     // restores a default hotkey
        "Reset",            // appearance and slider resets, no stored data
        "Restore defaults", // capture exclusion list back to shipped defaults
        "Clear filters",
        "Clear"
    ]

    private var sourcesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    private func swiftFiles() throws -> [URL] {
        var out: [URL] = []
        let walker = FileManager.default.enumerator(at: sourcesDirectory,
                                                    includingPropertiesForKeys: nil)
        while let item = walker?.nextObject() as? URL {
            if item.pathExtension == "swift" { out.append(item) }
        }
        return out
    }

    /// The scan must reach the tree, or everything below passes by walking nothing.
    func testScanReachesTheSourceTree() throws {
        XCTAssertGreaterThan(try swiftFiles().count, 100,
                             "expected the Grux sources at \(sourcesDirectory.path)")
    }

    func testEveryDestructiveButtonAsksFirst() throws {
        var unguarded: [String] = []

        for file in try swiftFiles() {
            guard file.lastPathComponent != "DestructiveActionsGuardTests.swift",
                  file.lastPathComponent != "DestructiveButton.swift",
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: .newlines)

            // Line ranges covered by a confirmation closure. A button in here IS
            // the confirmation.
            var guarded: [ClosedRange<Int>] = []
            for (i, line) in lines.enumerated() {
                guard line.contains("confirmationDialog(") || line.contains(".alert(") else { continue }
                let indent = line.prefix(while: { $0 == " " }).count
                var end = min(i + 60, lines.count - 1)
                for j in (i + 1)...min(i + 60, lines.count - 1) {
                    let t = lines[j]
                    if !t.trimmingCharacters(in: .whitespaces).isEmpty,
                       t.prefix(while: { $0 == " " }).count <= indent,
                       t.trimmingCharacters(in: .whitespaces).hasPrefix("}") { end = j; break }
                }
                guarded.append(i...end)
            }

            for (i, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                // `DestructiveButton("Delete"` and `DestructiveMenuButton("Delete"`
                // both contain the substring `Button("`, so a naive match flags
                // the very components that fix this. They ARE the guarded shape.
                if line.contains("DestructiveButton(") || line.contains("DestructiveMenuButton(") {
                    continue
                }
                guard line.contains("Button(\"") else { continue }
                guard let label = line.components(separatedBy: "\"").dropFirst().first else { continue }
                guard destructiveVerbs.contains(where: { label.contains($0) }) else { continue }
                if harmless.contains(label) { continue }
                if guarded.contains(where: { $0.contains(i) }) { continue }

                // Deferring to a dialog on the parent is the correct shape inside
                // a context menu, so a button that only sets state is fine.
                let window = lines[i...min(i + 4, lines.count - 1)].joined(separator: "\n")
                if window.range(of: #"(pending|deleting|showing|confirm)\w*\s*=\s*"#,
                                options: [.regularExpression, .caseInsensitive]) != nil { continue }

                unguarded.append("\(file.lastPathComponent):\(i + 1) \"\(label)\": \(line.prefix(90))")
            }
        }

        XCTAssertTrue(unguarded.isEmpty,
                      "a destructive action fires with no confirmation. Use DestructiveButton, or "
                      + "set a pending value and put the dialog on the parent view (required inside "
                      + "a context menu, which dismisses and takes an attached dialog with it). If "
                      + "it genuinely destroys nothing, add its exact label to `harmless` with a "
                      + "note saying what it does.\n"
                      + unguarded.joined(separator: "\n"))
    }

    /// A dialog that says "Are you sure?" and nothing else is a speed bump, not a
    /// question: it tells the reader nothing they did not know and trains them to
    /// confirm without reading, which is what stops the real ones working.
    func testConfirmationsNameWhatIsLost() throws {
        var vague: [String] = []
        for file in try swiftFiles() {
            guard file.lastPathComponent != "DestructiveActionsGuardTests.swift",
                  let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (i, raw) in text.components(separatedBy: .newlines).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                for weak in ["Are you sure", "are you sure"] where line.contains(weak) {
                    vague.append("\(file.lastPathComponent):\(i + 1): \(line.prefix(80))")
                }
            }
        }
        XCTAssertTrue(vague.isEmpty,
                      "name what is lost instead.\n" + vague.joined(separator: "\n"))
    }
}
