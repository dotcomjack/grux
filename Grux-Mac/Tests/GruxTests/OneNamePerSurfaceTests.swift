import XCTest
@testable import Grux

/// D212 item 4 (sense pass 32, `logs/s32-shots/mailbox-1.png`): the pane bar and
/// the Recent chip say "Mail", and the card under them said "Mailbox needs one more
/// thing" and "Add a mail account in Mail" while it stood in Mail; Now read "Set up
/// Mailbox" and the capability answer "One step away: Mailbox." A stranger reads two
/// names for one place. The rail's label is the name: every line that names a
/// surface takes it from there.
@MainActor
final class OneNamePerSurfaceTests: XCTestCase {

    /// The class: a feature the rail shows is called what the rail calls it, so
    /// its setup card, its Now row, `grux next` and the capability answer agree
    /// with the pane bar.
    func test_everyRailSurfaceIsCalledWhatTheRailCallsIt() {
        for entry in SidebarIA.railOrder {
            guard let row = FeatureRegistry.row(forTab: entry.key), row.id == entry.key else { continue }
            XCTAssertEqual(row.label, entry.label,
                           "the rail says \(entry.label) and the feature registry says \(row.label)")
        }
    }

    func test_theMailCardHeadlineSaysMail() {
        let label = FeatureRegistry.row(id: "mailbox")?.label ?? ""
        let copy = CapabilitySetupCard.copy(featureLabel: label, blocking: [.endpointImap], listedEntries: 1,
                                            missing: [.endpointImap], signInExpired: false)
        XCTAssertEqual(copy.headline, "Mail needs one more thing")
    }

    /// The card stands in Mail, beside its own Set it up button: it does not send
    /// the person to Mail. `grux next` keeps the contract's line, which says where.
    func test_theMailCardLineDoesNotSendThePersonWhereTheyAre() {
        let line = CapabilitySetupCard.line(for: .endpointImap, featureKey: "mailbox")
        XCTAssertFalse(line.contains("in Mail"), line)
        XCTAssertTrue(line.hasSuffix("Set it up opens the form."), line)
        XCTAssertTrue(line.contains("app password"), line)
        XCTAssertTrue(SetupRequirement.endpointImap.remediation.contains("in Mail"),
                      "the CLI line still names where the form is")
    }

    /// No line Grux shows or says points at a place called "Mailbox": the source
    /// holds no string literal with the word (type names such as `MailboxView`
    /// and calls such as `listMailboxes()` are not words in a literal).
    func test_noLinePointsAtMailbox() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertGreaterThan(files.count, 100)
        let word = try NSRegularExpression(pattern: #"\bMailbox\b(?![A-Za-z(])"#)
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") { continue }
                // The odd-numbered pieces between quotes are inside a literal.
                let pieces = line.components(separatedBy: "\"")
                for (n, piece) in pieces.enumerated() where n % 2 == 1 {
                    let range = NSRange(piece.startIndex..., in: piece)
                    if word.firstMatch(in: piece, range: range) != nil {
                        found.append("\(file.lastPathComponent):\(i + 1): \(piece)")
                    }
                }
            }
        }
        XCTAssertEqual(found, [], "a line names Mailbox where the rail says Mail")
    }
}
