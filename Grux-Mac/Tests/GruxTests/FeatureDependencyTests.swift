import XCTest
@testable import Grux

/// A FEATURE CAN BE UNUSABLE BECAUSE ANOTHER FEATURE IS OFF, AND NO CAPABILITY SAYS SO.
///
/// `speakers` declares no requirement at all. What it needs is not a credential or a
/// permission, it is Meetings actually running: Speakers names the voices in a meeting, so
/// with Meetings off it is a working screen with nothing in it and every capability-based
/// check calls it `ready`. Somebody who picks Speakers and not Meetings has produced a
/// selection that cannot do what they asked for, and the four capability lists cannot see it.
///
/// CR-35 added `dependsOn` for exactly that. These tests keep the Swift arrays and the
/// section 5.6 table honest about each other, which is the same row-by-row rule the rest of
/// the registry already lives under.
@MainActor
final class FeatureDependencyTests: XCTestCase {

    /// `Grux-Mac/Tests/GruxTests/X.swift` -> repo root is four levels up.
    private func registryDoc() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("docs/feature-registry.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The section 5.6 table, as feature id -> the ids it depends on.
    private func documentedDependencies() throws -> [String: [String]] {
        let doc = try registryDoc()
        guard let start = doc.range(of: "### 5.6 Feature dependencies") else {
            XCTFail("section 5.6 is gone from the registry document")
            return [:]
        }
        let rest = doc[start.upperBound...]
        let body = rest.range(of: "\n## ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)

        var out: [String: [String]] = [:]
        for line in body.split(separator: "\n") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { continue }
            let raw = cells[1]
            guard raw.hasPrefix("`"), raw.hasSuffix("`") else { continue }
            let id = String(raw.dropFirst().dropLast())
            let deps = cells[2]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("`") && $0.hasSuffix("`") }
                .map { String($0.dropFirst().dropLast()) }
            guard !deps.isEmpty else { continue }
            out[id] = deps
        }
        return out
    }

    private var swiftDependencies: [String: [String]] {
        var out: [String: [String]] = [:]
        for row in FeatureRegistry.rows where !row.dependsOn.isEmpty {
            out[row.id] = row.dependsOn
        }
        return out
    }

    /// Rule 3. Both directions, so neither side can grow a dependency the other has not
    /// heard of. A one-way check would let the Swift declare a relation the document never
    /// records, which is the drift every other registry test exists to prevent.
    func testTheDocumentAndTheSwiftAgree() throws {
        let doc = try documentedDependencies()
        let swift = swiftDependencies

        XCTAssertFalse(doc.isEmpty,
                       "control: parsed no rows out of section 5.6, so this proves nothing")

        XCTAssertEqual(Set(doc.keys), Set(swift.keys),
            "section 5.6 lists \(doc.keys.sorted()) and the Swift declares \(swift.keys.sorted())")

        for (id, docDeps) in doc {
            XCTAssertEqual(docDeps.sorted(), (swift[id] ?? []).sorted(),
                           "\(id) dependsOn drifted between the document and the Swift")
        }
    }

    /// Rule 1. A dependency on a feature that does not exist is a typo that would otherwise
    /// sit there forever, because nothing else in the app ever reads these strings.
    func testEveryDependencyNamesARealFeature() {
        let known = Set(FeatureRegistry.rows.map(\.id))
        for row in FeatureRegistry.rows {
            for dep in row.dependsOn {
                XCTAssertTrue(known.contains(dep),
                    "\(row.id) depends on \(dep), which is not a feature in this registry")
            }
        }
    }

    /// Rule 2. A cycle makes "turn on what this needs" unanswerable, and a self-dependency
    /// makes a feature permanently blocked on itself.
    func testThereAreNoCycles() {
        var edges: [String: [String]] = [:]
        for row in FeatureRegistry.rows { edges[row.id] = row.dependsOn }

        var visiting: Set<String> = []
        var done: Set<String> = []
        var cycle: [String] = []

        func walk(_ id: String, _ path: [String]) {
            if done.contains(id) { return }
            if visiting.contains(id) {
                if cycle.isEmpty { cycle = path + [id] }
                return
            }
            visiting.insert(id)
            for next in edges[id] ?? [] { walk(next, path + [id]) }
            visiting.remove(id)
            done.insert(id)
        }
        for row in FeatureRegistry.rows { walk(row.id, []) }

        XCTAssertTrue(cycle.isEmpty, "dependency cycle: \(cycle.joined(separator: " -> "))")
    }

    /// The relation this was added for, named so a regression says which one vanished.
    /// If Speakers ever declares a real capability that implies Meetings, delete this and
    /// say why in section 5.6, in that order.
    func testSpeakersStillDependsOnMeetings() {
        let speakers = FeatureRegistry.rows.first { $0.id == "speakers" }
        XCTAssertEqual(speakers?.dependsOn, ["meetings"],
            "Speakers names the voices in a meeting. Without Meetings it is a working screen "
            + "with nothing in it, and no capability in its four lists expresses that.")
        XCTAssertEqual(speakers?.blocking, [],
            "control: if Speakers gained a blocking capability, the dependency might now be "
            + "derivable and this whole field would need revisiting")
    }

    /// Almost every row has none, and that is the point: the default keeps thirty eight
    /// declarations untouched. A test that let the count drift silently would not notice a
    /// dependency added with no document row, since the agreement test only walks what each
    /// side already declares.
    func testOnlyTheDeclaredRowsCarryADependency() {
        let withDeps = FeatureRegistry.rows.filter { !$0.dependsOn.isEmpty }.map(\.id).sorted()
        XCTAssertEqual(withDeps, ["speakers"],
            "the set of features with dependencies changed to \(withDeps). Add the row to "
            + "section 5.6 and update this list together, or the two drift apart.")
    }
}
