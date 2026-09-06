import XCTest
@testable import Grux

/// The README's permission table, checked against the registry it claims to come from.
///
/// ## Why this exists
///
/// README.md carried a nine row permission table under the heading "What stops
/// working without it", and said underneath that the table "is derived from the
/// same feature registry the app reads at runtime, so it cannot drift from the
/// real behaviour". Nothing derived it and nothing checked it. It was typed once
/// and left.
///
/// Measured 2026-09-06 against `FeatureRegistry.rows`: three of the nine rows
/// were wrong. Automation, Accessibility and Notifications each named features
/// in the same shape the genuinely-required rows used, and all three are
/// required by NOTHING. Every feature that mentions them lists them as
/// `optional`, which means the feature opens and works without the grant. A
/// reader deciding which of nine system prompts to accept was being told three
/// of them were load bearing when they are not.
///
/// A sentence claiming a guarantee that nothing provides is worse than no
/// sentence, because it stops the next reader checking. So either the claim goes
/// or something makes it true. This is the something.
///
/// ## What it enforces
///
/// Both data columns, as exact sets, in both directions:
///
///   - **Required by** must name exactly the features whose `requires` list
///     contains that permission. Not a superset, not a subset.
///   - **What refusing costs you** must name exactly the features whose
///     `optional` list contains it. The prose around the names is free, because
///     the check looks for feature labels inside the cell rather than parsing
///     it as a list, but the SET of labels found has to match.
///
/// Adding a permission to a feature and not touching the README turns this red.
/// So does the reverse. That is the whole point.
///
/// ## The guard tests itself
///
/// `testTheParserFindsTheRealTable` fails if the table stops being found at all,
/// which is the failure that would otherwise make every assertion below vacuous:
/// a renamed heading or a reformatted table would yield zero rows, and zero rows
/// pass every loop in here silently. A guard that cannot fail is not a guard.
///
/// `@MainActor` because `FeatureRegistry` is, and the whole file reads it. Same
/// as `FeatureDependencyTests`, for the same reason.
@MainActor
final class PermissionTableTests: XCTestCase {

    // MARK: The nine permissions, and nothing else

    /// Every `perm` class capability. Derived from the enum rather than listed,
    /// so a tenth permission is a compile-time-visible gap here rather than a
    /// row nobody notices is missing from the README.
    private static var permissions: [SetupRequirement] {
        SetupRequirement.allCases.filter { $0.rawValue.hasPrefix("perm.") }
    }

    // MARK: Reading the README

    /// `Grux-Mac/Tests/GruxTests/X.swift` -> repo root is four levels up.
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
            .deletingLastPathComponent()   // repo root
    }

    private struct Row {
        let permission: String
        let requiredBy: String
        let refusingCosts: String
    }

    /// The parsed permission table, or an empty array if it cannot be found.
    ///
    /// Deliberately returns empty rather than throwing, so the self-test below
    /// is the single place that decides an unparseable table is a failure. Every
    /// other test asserts non-emptiness through it.
    private func parseTable() throws -> [Row] {
        let url = repoRoot().appendingPathComponent("README.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)

        guard let header = lines.firstIndex(where: {
            $0.hasPrefix("| Permission | Required by | What refusing costs you |")
        }) else { return [] }

        var rows: [Row] = []
        // Skip the header and the `|---|---|---|` separator beneath it.
        for line in lines.dropFirst(header + 2) {
            guard line.hasPrefix("|") else { break }
            let cells = line
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard cells.count == 3 else { break }
            rows.append(Row(permission: cells[0], requiredBy: cells[1], refusingCosts: cells[2]))
        }
        return rows
    }

    // MARK: The guard's own floor

    func testTheParserFindsTheRealTable() throws {
        let rows = try parseTable()
        XCTAssertEqual(
            rows.count, Self.permissions.count,
            """
            The README permission table did not parse into \(Self.permissions.count) rows, it \
            parsed into \(rows.count).

            Every other assertion in this file loops over those rows, so zero rows is \
            not a pass, it is a silent hole. The parser looks for a line that begins:

                | Permission | Required by | What refusing costs you |

            followed by a separator row and then one row per permission. If you \
            reformatted the table or renamed a column, update the parser in this file \
            in the same commit.
            """
        )
    }

    // MARK: The two columns

    func testRequiredByNamesExactlyTheFeaturesThatRequireIt() throws {
        let rows = try parseTable()
        XCTAssertFalse(rows.isEmpty, "no rows parsed, see testTheParserFindsTheRealTable")

        for permission in Self.permissions {
            guard let row = rows.first(where: { $0.permission == permission.label }) else {
                XCTFail("""
                    README permission table has no row for "\(permission.label)" \
                    (\(permission.rawValue)). Every `perm.` capability needs one.
                    """)
                continue
            }

            let truth = Set(
                FeatureRegistry.rows
                    .filter { $0.requires.contains(permission) }
                    .map(\.label)
            )
            let claimed = Self.featureLabels(mentionedIn: row.requiredBy)

            if truth.isEmpty {
                XCTAssertEqual(
                    row.requiredBy, "Nothing",
                    """
                    README says "\(permission.label)" is required by "\(row.requiredBy)", \
                    but no feature in FeatureRegistry lists it under `requires`. Every \
                    feature that mentions it lists it as `optional`, which means the \
                    feature opens and works without the grant.

                    The cell should read exactly: Nothing
                    """
                )
            } else {
                XCTAssertEqual(
                    claimed, truth,
                    """
                    README's "Required by" cell for "\(permission.label)" does not match \
                    FeatureRegistry.

                      README says:   \(claimed.sorted().joined(separator: ", "))
                      registry says: \(truth.sorted().joined(separator: ", "))

                    Fix whichever is wrong. If you added or removed the permission from a \
                    feature's `requires` list, the README row moves in the same commit.
                    """
                )
            }
        }
    }

    func testRefusingCostsNamesExactlyTheFeaturesThatListItOptional() throws {
        let rows = try parseTable()
        XCTAssertFalse(rows.isEmpty, "no rows parsed, see testTheParserFindsTheRealTable")

        for permission in Self.permissions {
            guard let row = rows.first(where: { $0.permission == permission.label }) else {
                continue   // already reported by the test above
            }

            let truth = Set(
                FeatureRegistry.rows
                    .filter { $0.optional.contains(permission) }
                    .map(\.label)
            )
            let claimed = Self.featureLabels(mentionedIn: row.refusingCosts)

            XCTAssertEqual(
                claimed, truth,
                """
                README's "What refusing costs you" cell for "\(permission.label)" does not \
                name the same features FeatureRegistry lists as `optional`.

                  README names:  \(claimed.sorted().joined(separator: ", "))
                  registry says: \(truth.sorted().joined(separator: ", "))

                The prose in the cell is free. The set of FEATURE LABELS inside it is \
                not: it has to be exactly the features that degrade without this \
                permission, because that cell is the reader's only account of what \
                saying no actually costs.
                """
            )
        }
    }

    // MARK: The prose above the table

    func testTheFiveClaimIsTheRealCount() throws {
        let url = repoRoot().appendingPathComponent("README.md")
        let text = try String(contentsOf: url, encoding: .utf8)

        let required = Self.permissions.filter { permission in
            FeatureRegistry.rows.contains { $0.requires.contains(permission) }
        }

        XCTAssertEqual(
            required.count, 5,
            """
            \(required.count) permissions are required by at least one feature, not five: \
            \(required.map(\.label).sorted().joined(separator: ", ")).

            The README sentence above the table says "only five are required by anything \
            at all". Move both together.
            """
        )
        XCTAssertTrue(
            text.contains("only five are required by anything at all"),
            """
            The sentence above the permission table stopped saying "only five are \
            required by anything at all". \(required.count) is the measured number. If you \
            reworded it, reword this assertion too rather than deleting it.
            """
        )
    }

    // MARK: Helpers

    /// Every registry feature label that appears as a whole phrase in `cell`.
    ///
    /// Longest label first, and each match is consumed, so "Focus log" cannot
    /// also be counted as a match for a hypothetical "Focus". Without that,
    /// overlapping labels would inflate the claimed set and the comparison would
    /// fail for a reason that has nothing to do with the README being wrong.
    private static func featureLabels(mentionedIn cell: String) -> Set<String> {
        var haystack = cell
        var found: Set<String> = []
        for label in FeatureRegistry.rows.map(\.label).sorted(by: { $0.count > $1.count }) {
            guard let range = haystack.range(of: label) else { continue }
            found.insert(label)
            haystack.replaceSubrange(range, with: String(repeating: " ", count: label.count))
        }
        return found
    }
}
