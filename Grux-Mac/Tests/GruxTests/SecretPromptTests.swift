import XCTest
@testable import GruxSetupCore

/// A credential may only enter Grux through a terminal, with the echo off.
///
/// Never a flag: it lands in shell history and in `ps` output, readable by every process on
/// the machine. Never an environment variable: it is inherited by every child process.
/// Neither can be taken back once it has happened, and somebody pasting a key has no reason
/// to expect either.
final class SecretPromptTests: XCTestCase {

    /// IT REFUSES A PIPE RATHER THAN READING ONE.
    ///
    /// A piped secret came from a file, a history entry, or another process's arguments,
    /// which are the three places this exists to keep it out of. Accepting it quietly would
    /// make the whole design decorative. The suite runs without a TTY, so this is the real
    /// path rather than a simulation of it.
    func testItRefusesWhenNothingIsAttached() {
        XCTAssertEqual(isatty(STDIN_FILENO), 0,
            "this test host HAS a terminal, so the assertion below is not exercising the "
            + "refusal path")
        XCTAssertThrowsError(try SecretPrompt.read("secret: ")) { error in
            XCTAssertEqual(error as? SecretPrompt.Failure, .notATerminal,
                "a secret was read from something that is not a terminal")
        }
    }

    /// The failure cases are distinct, because they need different responses. Cancelled is a
    /// person changing their mind; empty is a person pressing return by accident; not a
    /// terminal is a script that cannot be helped by retrying.
    func testTheFailuresAreDistinguishable() {
        let all: [SecretPrompt.Failure] = [.notATerminal, .cancelled, .empty]
        XCTAssertEqual(Set(all.map(String.init(describing:))).count, 3,
            "two failure cases are indistinguishable, so a caller cannot respond correctly")
    }
}

/// The `connect` command's surface, checked as text.
final class ConnectTakesNoSecretArgumentTests: XCTestCase {

    private func code(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/GruxCLI/Commands/\(name)")
        let raw = try String(contentsOf: url, encoding: .utf8)
        return raw.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// NO OPTION CARRIES THE VALUE, and the only argument is the service NAME.
    ///
    /// `@OptionGroup` is not `@Option`, and the difference is the whole reason this test now
    /// FOLLOWS the group instead of banning the word. A substring check for "@Option" also
    /// matches "@OptionGroup", so adding the shared `--no-input` group to every command
    /// turned this red on a declaration that carries no value at all. Banning the word would
    /// have been the weaker test in both directions: it fires on a group that is harmless,
    /// and it says nothing about a group that is not, since an OptionGroup can introduce any
    /// option it likes into this command's surface without the word `@Option` ever appearing
    /// in Connect.swift.
    ///
    /// So: no `@Option` declared here, AND no `@Option` in any group this command composes.
    func testConnectDeclaresNoOptionAtAll() throws {
        let source = try code("Connect.swift")
        let direct = source.replacingOccurrences(of: "@OptionGroup", with: "")
        XCTAssertFalse(direct.contains("@Option"),
            "grux connect declares an @Option. The command's entire promise is that a "
            + "credential cannot arrive as an argument, so any option here is suspect and a "
            + "value-carrying one is the bug this guards against.")

        // Follow every group it composes, and hold that file to the same rule.
        var groups: [String] = []
        var rest = Substring(source)
        while let at = rest.range(of: "@OptionGroup var ") {
            let after = rest[at.upperBound...]
            guard let colon = after.range(of: ": ") else { break }
            let type = after[colon.upperBound...]
                .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !type.isEmpty { groups.append(String(type)) }
            rest = after
        }
        XCTAssertFalse(groups.isEmpty,
            "found no @OptionGroup in Connect.swift, so the follow below checks nothing. "
            + "If the group was removed on purpose, delete this half of the test.")
        for type in Set(groups) {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/GruxCLI/\(type).swift")
            let groupSource = try String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            // STRIP THE GROUP WORD, THEN LOOK. An earlier version matched on "@Option "
            // with a trailing space to avoid hitting "@OptionGroup", and real Swift is
            // written `@Option(name:` with no space, so it would have missed every actual
            // declaration. Found by planting: the plant only failed the test because it had
            // been written in the one shape the check could see.
            XCTAssertFalse(groupSource.replacingOccurrences(of: "@OptionGroup", with: "")
                                      .contains("@Option"),
                "\(type), composed into grux connect, declares a value-carrying @Option. "
                + "Every option in a group is an option on this command, and this command "
                + "promises that no argument can carry a credential.")
        }
    }

    /// And it reads through the prompt rather than rolling its own.
    func testConnectReadsThroughTheSharedPrompt() throws {
        let source = try code("Connect.swift")
        XCTAssertTrue(source.contains("SecretPrompt.read"),
            "grux connect no longer reads through SecretPrompt, so the echo-off guarantee "
            + "and the refusal to read from a pipe may no longer hold")
        XCTAssertFalse(source.contains("ProcessInfo.processInfo.environment"),
            "grux connect reads the environment, which is where a secret must never come "
            + "from: an environment variable is inherited by every child process")
    }
}
