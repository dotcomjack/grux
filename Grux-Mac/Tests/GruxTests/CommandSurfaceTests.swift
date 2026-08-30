import XCTest

/// The command surface grows by a decision, never by somebody adding a struct.
///
/// `docs/cli-grammar.md` section 5 is the source of truth: three tables, every row marked
/// `shipped` or `planned`. This reads that file and the registration site in `main.swift`
/// and requires them to agree EXACTLY, both directions.
///
/// Why both directions matters. One direction catches an undocumented command, which is the
/// obvious risk. The other catches a row somebody marked `shipped` while writing the doc,
/// ahead of the code, which is the risk that actually bites: the file then reads as a
/// description of a working program and is a description of an intention.
final class CommandSurfaceTests: XCTestCase {

    /// The package root, from this file rather than from a working directory, because a
    /// test's working directory is not something the test gets to choose.
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/GruxTests/CommandSurfaceTests.swift
            .deletingLastPathComponent()      // Tests/GruxTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // the package
    }

    // MARK: - Reading the doc

    /// Split one markdown table row into cells.
    ///
    /// `\|` is an ESCAPED pipe and is not a cell boundary. Splitting naively drops any row
    /// whose command shows alternatives, which is how `grux list` disappeared from this
    /// check the first time it ran. The positive control caught it; without that control the
    /// suite would have been green over a parser that could not see a row it had to see.
    private func cells(of line: some StringProtocol) -> [String] {
        let sentinel = "\u{0}"
        return line
            .replacingOccurrences(of: "\\|", with: sentinel)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map {
                $0.replacingOccurrences(of: sentinel, with: "|")
                  .trimmingCharacters(in: .whitespaces)
            }
    }

    /// Every `| \`grux <name> ...\` | shipped |` row, by name.
    private func documented() throws -> (shipped: Set<String>, planned: Set<String>) {
        let url = Self.packageRoot.appendingPathComponent("docs/cli-grammar.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        var shipped = Set<String>(), planned = Set<String>()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            // | `grux doctor` | shipped | Is this Mac able to run Grux at all. |
            let cells = cells(of: line)
            guard cells.count >= 4 else { continue }
            guard cells[1].hasPrefix("`grux "), cells[1].hasSuffix("`") else { continue }
            let name = cells[1]
                .dropFirst("`grux ".count).dropLast()
                .split(separator: " ").first.map(String.init) ?? ""
            guard !name.isEmpty else { continue }
            switch cells[2] {
            case "shipped": shipped.insert(name)
            case "planned": planned.insert(name)
            default: XCTFail("row for `grux \(name)` says \"\(cells[2])\", "
                             + "which is neither shipped nor planned")
            }
        }
        return (shipped, planned)
    }

    // MARK: - Reading the binary's registration

    /// The names `grux --help` will print, derived from the registration site.
    ///
    /// ArgumentParser derives a command's name by lowercasing the type unless the type
    /// declares `commandName:`. The parse models both, because modelling only the first
    /// would have missed `Cost`, which names itself.
    private func registered() throws -> Set<String> {
        let url = Self.packageRoot.appendingPathComponent("Sources/GruxCLI/main.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        guard let open = source.range(of: "subcommands: [") else {
            XCTFail("no subcommands array in main.swift")
            return []
        }
        guard let close = source.range(of: "]", range: open.upperBound..<source.endIndex) else {
            XCTFail("the subcommands array is never closed")
            return []
        }
        let types = source[open.upperBound..<close.lowerBound]
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasSuffix(".self") }
            .map { String($0.dropLast(".self".count)) }

        XCTAssertFalse(types.isEmpty, "parsed no subcommands, so this test proves nothing")

        // An explicit commandName wins. Find each `struct X` and look inside it.
        //
        // THE DECLARATIONS ARE NOT IN main.swift. They are one per file under Commands/, and
        // the first version of this searched only main.swift, so `explicitName` returned nil
        // for all of them and every name came from lowercasing the type. That was invisible
        // while every type happened to lowercase to its own command name, and it means the
        // check could not have caught a `commandName:` that disagreed with the doc. Two
        // commands broke the coincidence and exposed it: `SupportBundle` is `support-bundle`
        // and `AgentCommand` is `agent`, neither of which any lowercasing produces.
        let corpus = try commandSources()
        var names = Set<String>()
        for type in types {
            names.insert(explicitName(of: type, in: corpus) ?? type.lowercased())
        }
        return names
    }

    /// Every file that can declare a `ParsableCommand`, concatenated.
    ///
    /// Joined with a newline so `explicitName`'s "\nstruct X" anchor still matches a type
    /// declared on a file's first line.
    private func commandSources() throws -> String {
        let fm = FileManager.default
        let root = Self.packageRoot.appendingPathComponent("Sources/GruxCLI")
        var parts = [try String(contentsOf: root.appendingPathComponent("main.swift"),
                                encoding: .utf8)]
        let dir = root.appendingPathComponent("Commands")
        for name in try fm.contentsOfDirectory(atPath: dir.path).sorted()
        where name.hasSuffix(".swift") {
            parts.append(try String(contentsOf: dir.appendingPathComponent(name),
                                    encoding: .utf8))
        }
        // THE POSITIVE CONTROL. A parser that reads no files agrees with everything.
        XCTAssertGreaterThan(parts.count, 20,
            "read \(parts.count) command sources, so the layout moved and this proves nothing")
        return "\n" + parts.joined(separator: "\n")
    }

    /// The `commandName:` a type declares, if it declares one.
    ///
    /// Scoped to the text between this type's declaration and the next top level one, so a
    /// `commandName` belonging to a different struct is never attributed to this one. The
    /// root `Grux` names itself "grux" and would otherwise be a very confusing match.
    private func explicitName(of type: String, in source: String) -> String? {
        guard let decl = source.range(of: "\nstruct \(type): ParsableCommand {") else { return nil }
        let rest = source[decl.upperBound...]
        let end = rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex
        let body = rest[rest.startIndex..<end]
        guard let key = body.range(of: "commandName: \"") else { return nil }
        let after = body[key.upperBound...]
        guard let quote = after.firstIndex(of: "\"") else { return nil }
        return String(after[after.startIndex..<quote])
    }

    // MARK: - The assertion

    func testTheDocumentedSurfaceAndTheBuiltSurfaceAreTheSameSet() throws {
        let (shipped, planned) = try documented()
        let built = try registered()

        let undocumented = built.subtracting(shipped)
        XCTAssertTrue(undocumented.isEmpty,
            "these commands are in the binary and not marked shipped in "
            + "docs/cli-grammar.md: \(undocumented.sorted().joined(separator: ", ")). "
            + "Add the row, or mark the existing row shipped.")

        let claimed = shipped.subtracting(built)
        XCTAssertTrue(claimed.isEmpty,
            "docs/cli-grammar.md says these are shipped and nothing registers them: "
            + "\(claimed.sorted().joined(separator: ", ")). "
            + "The file is describing an intention as if it were a program.")

        // A planned command that also exists is a row nobody updated.
        let stale = planned.intersection(built)
        XCTAssertTrue(stale.isEmpty,
            "these are built but still marked planned: "
            + "\(stale.sorted().joined(separator: ", "))")
    }

    /// The table has to actually contain rows, or every assertion above is vacuously true.
    /// A parser that silently matches nothing is the classic way a green check means nothing,
    /// so this is the positive control: it fails if the format ever drifts out from under it.
    func testTheDocIsActuallyBeingParsed() throws {
        let (shipped, planned) = try documented()
        XCTAssertGreaterThanOrEqual(shipped.count, 9,
            "parsed \(shipped.count) shipped rows, so the table format changed")
        XCTAssertGreaterThanOrEqual(shipped.count + planned.count, 40,
            "parsed \(shipped.count + planned.count) rows total, so the table format changed")
        XCTAssertTrue(shipped.contains("doctor"), "the parser cannot see a row it must see")
        XCTAssertTrue(shipped.isDisjoint(with: planned),
            "a command is listed as both shipped and planned")
    }

    /// No command is documented twice under a different status, and none is documented in a
    /// table it does not belong to. Cheap, and it catches a copy-paste when the surface
    /// triples in size.
    func testNoCommandIsListedTwice() throws {
        let url = Self.packageRoot.appendingPathComponent("docs/cli-grammar.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        var seen: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let cells = cells(of: line)
            guard cells.count >= 4, cells[1].hasPrefix("`grux "), cells[1].hasSuffix("`"),
                  cells[2] == "shipped" || cells[2] == "planned" else { continue }
            let name = String(cells[1].dropFirst("`grux ".count).dropLast()
                .split(separator: " ").first ?? "")
            seen[name, default: 0] += 1
        }
        let dupes = seen.filter { $0.value > 1 }.keys.sorted()
        XCTAssertTrue(dupes.isEmpty, "listed more than once: \(dupes.joined(separator: ", "))")
    }
}
