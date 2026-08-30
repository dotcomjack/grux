import XCTest
@testable import GruxSetupCore

/// `grux keys` cannot print a secret, and lists sort the way a person reads.
final class KeysNeverPrintAValueTests: XCTestCase {

    /// The file with its COMMENTS STRIPPED.
    ///
    /// The first version scanned the raw text and failed on `Keys.swift`, because its doc
    /// comment explains why the command does NOT use `KeychainStore`. Naming the thing you
    /// are avoiding is exactly what a good comment does, and a check that punishes it
    /// teaches people to write worse ones. The property being asserted is about what the
    /// CODE reaches for, so the prose comes out first.
    private static func code(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/GruxCLI/Commands/\(name)")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// CANNOT, not "does not". The command reads the status document, which records that a
    /// credential is present and never records what it is, so there is no value in reach.
    /// Going to the Keychain instead would put one in reach, which is the change this
    /// forbids.
    func testTheKeysCommandNeverTouchesACredentialStore() throws {
        let source = try Self.code("Keys.swift")

        for forbidden in ["KeychainStore", "SecItemCopyMatching", "kSecReturnData",
                          "kSecClassGenericPassword"] {
            XCTAssertFalse(source.contains(forbidden),
                "grux keys references \(forbidden), which puts a credential VALUE within "
                + "reach of a command whose entire promise is that it cannot read one")
        }
        XCTAssertTrue(source.contains("SetupStatusReader.read()"),
            "grux keys no longer reads the status document, so the property that makes it "
            + "safe by construction may no longer hold")
    }

    /// And no flag exists that could ask for one.
    func testNoFlagAsksForAValue() throws {
        let source = try Self.code("Keys.swift")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, line) in lines.enumerated() where line.contains("@Flag") || line.contains("@Option") {
            let window = (line + " " + (i + 1 < lines.count ? lines[i + 1] : "")).lowercased()
            for word in ["value", "secret", "reveal", "show", "plain", "unmask"] {
                XCTAssertFalse(window.contains(word),
                    "grux keys grew a `\(word)` flag, and the command promises in its own "
                    + "help that no flag makes it print a secret")
            }
        }
    }

    /// EVERY list a person reads sorts case insensitively.
    ///
    /// A plain `<` on a String is an ASCII comparison, so a label starting lowercase files
    /// after every uppercase one. Measured: exactly one capability label starts lowercase
    /// ("fal.ai API key"), which put it after "Web search API key" in what claimed to be an
    /// alphabetical list. Six sort sites existed; this holds all of them.
    func testNoUserFacingListSortsByAscii() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/GruxCLI")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return XCTFail("could not read the CLI sources") }

        var offenders: [String] = []
        var checked = 0
        for case let url as URL in e where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            checked += 1
            for (i, line) in text.split(separator: "\n").enumerated() {
                guard line.contains("sorted") else { continue }
                // A comparison on a label or name, without lowercasing either side.
                guard line.contains(".label <") || line.contains(".name <")
                        || line.contains(".label }") && line.contains("<") else { continue }
                guard !line.contains("lowercased") else { continue }
                offenders.append("\(url.lastPathComponent):\(i + 1)")
            }
        }
        XCTAssertGreaterThan(checked, 10, "scanned \(checked) files, so this proves nothing")
        XCTAssertTrue(offenders.isEmpty,
            "these sort a user-facing list by ASCII, so a lowercase label files last: "
            + offenders.joined(separator: ", "))
    }

    /// The control: an ASCII sort really does misorder the real data.
    func testAnAsciiSortActuallyMisordersTheseLabels() {
        let labels = ["Web search API key", "fal.ai API key", "Anthropic API key"]
        XCTAssertNotEqual(labels.sorted(), labels.sorted { $0.lowercased() < $1.lowercased() },
            "an ASCII sort and a case-insensitive one agree on this sample, so the test "
            + "above is guarding nothing")
        XCTAssertEqual(labels.sorted().last, "fal.ai API key",
            "ASCII no longer files a lowercase label last, so the bug this guards is gone")
    }
}
