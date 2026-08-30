import XCTest
@testable import Grux

/// Onboarding must not send a new user to a tab that does not exist.
///
/// This is not hypothetical. `83274f1` removed the analytics surface for the open
/// source release and deleted the Usage tab with it, correctly: it was PostHog
/// backed and dead on arrival for anybody but the original author. What it did
/// NOT do was update the first-run copy, which went on telling every new user
/// "Grux shows the running total on the Usage tab" for a tab that had been
/// deleted. The very first screen a stranger reads pointed them at nothing.
///
/// Nothing caught it because no test relates prose to the `Tab` enum, and the
/// enum is not greppable from a sentence. The sentence was also wrong in a second
/// way a spelling check would never find: Grux shows a per-send ESTIMATE in Chat,
/// never a running total anywhere.
///
/// The vocabulary is deliberately generous. It accepts the enum case names AND
/// the user-facing labels from both the sidebar and the registry, because copy
/// should say "the Local Models tab", which is the label, and not "the cookbook
/// tab", which is the key. A false failure here is cheap and a false pass is not.
@MainActor
final class OnboardingNamesRealTabsTests: XCTestCase {

    /// Every name a piece of copy may legitimately put in front of the word "tab".
    private func tabVocabulary() throws -> Set<String> {
        var vocab = Set<String>()

        let launchRoot = try Self.source(at: "Sources/Grux/LaunchRootView.swift")
        let enumBody = try XCTUnwrap(
            launchRoot.range(of: "enum Tab: Hashable { case ").map { r -> String in
                let after = launchRoot[r.upperBound...]
                let end = after.firstIndex(of: "}") ?? after.endIndex
                return String(after[..<end])
            },
            "could not parse the Tab enum; this test's anchor moved and it is now checking nothing"
        )
        for c in enumBody.split(separator: ",") {
            vocab.insert(c.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        XCTAssertGreaterThan(vocab.count, 20, "parsed \(vocab.count) tab cases, the enum format changed")

        for row in FeatureRegistry.rows { vocab.insert(row.label.lowercased()) }
        for group in SidebarIA.groups {
            for item in group.items { vocab.insert(item.label.lowercased()) }
        }
        return vocab
    }

    func testEveryTabOnboardingNamesActuallyExists() throws {
        let vocab = try tabVocabulary()
        var offenders: [String] = []

        for file in ["Sources/Grux/Onboarding/OnboardingSteps.swift",
                     "Sources/Grux/Onboarding/OnboardingView.swift"] {
            let body = try Self.source(at: file)
            for literal in Self.stringLiterals(in: body) {
                for name in Self.tabReferences(in: literal) where !vocab.contains(name.lowercased()) {
                    offenders.append("\(file.split(separator: "/").last!): \"\(name) tab\"")
                }
            }
        }

        XCTAssertTrue(offenders.isEmpty, """
            Onboarding sends a new user to a tab that does not exist:
              \(offenders.joined(separator: "\n  "))
            Either the tab was deleted and this copy was not updated, or the copy uses a name
            the sidebar does not show. Both read to a stranger as the app being broken.
            """)
    }

    /// The specific regression, named, so the reason survives even if somebody
    /// later loosens the general scan above.
    func testTheDeletedUsageTabIsNotAdvertisedAnywhere() throws {
        for file in ["Sources/Grux/Onboarding/OnboardingSteps.swift",
                     "Sources/Grux/Onboarding/OnboardingView.swift",
                     "Sources/Grux/SettingsView.swift"] {
            let body = try Self.source(at: file)
            for literal in Self.stringLiterals(in: body) {
                XCTAssertFalse(literal.contains("Usage tab"),
                    "\(file) still advertises the Usage tab, which 83274f1 deleted")
            }
        }
    }

    // MARK: - helpers

    private static func source(at relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac, the package root
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// String literals only. Scanning raw source would match identifiers and the
    /// doc comments in this very file, so the test would report on itself.
    private static func stringLiterals(in source: String) -> [String] {
        let re = try? NSRegularExpression(pattern: #""((?:[^"\\\n]|\\.)*)""#)
        let ns = source as NSString
        return re?.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) } ?? []
    }

    /// "<Capitalised Name> tab". Requires a capital so "on the tab, in place"
    /// and similar generic phrasing does not trip it.
    private static func tabReferences(in literal: String) -> [String] {
        let re = try? NSRegularExpression(pattern: #"\b([A-Z][A-Za-z]*(?: [A-Z][A-Za-z]*)?) tab\b"#)
        let ns = literal as NSString
        return re?.matches(in: literal, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) } ?? []
    }
}
