import XCTest
@testable import Grux

/// A getter that creates a directory is how folders appear in somebody's Documents for
/// features they have never opened.
///
/// This bug was found and fixed three times before anybody looked for the SHAPE. First
/// `~/Documents/Grux/backups`, from `BackupScheduler`'s init computing a fallback path for a
/// feature that ships off. Then, on the very next clean-machine run after that fix,
/// `~/Documents/Grux/design` appeared instead: `DesignStudioView` holds
/// `@ObservedObject private var store = DesignProjectStore.shared` as a property
/// initialiser, so building the view hierarchy at launch touches the store, whose init read a
/// creating getter. Two more of the same shape were then found by sweeping rather than by
/// waiting for a third machine to show one.
///
/// So the rule is enforced here instead of remembered: **naming a place is not making one.**
/// Create at the point of writing, where there is genuinely something to put in it.
///
/// Scoped to USER-VISIBLE destinations on purpose. A getter that creates under
/// ~/Library/Application Support/Grux or ~/.grux is creating Grux's own storage, which is
/// expected and which nobody browses. There are 27 of those and they are all fine. The
/// argument only applies where a person would see a folder appear.
final class NoSurpriseFoldersTests: XCTestCase {

    /// The one sanctioned exception, and why.
    ///
    /// `Persistence.iCloudMirrorDir` still creates. Nothing reaches it unless the workday
    /// log's iCloud mirror is switched on, which is off by default, and
    /// `WorkdayLogSwitchTests.testTheGuardsPrecedeTheDirectoryCreatingGetter` asserts the
    /// guard sits ahead of the getter in both of its two readers. Guarding the callers was
    /// chosen over splitting the getter because the property IS the feature there: the
    /// mirror has nowhere else to go.
    static let sanctioned: Set<String> = ["iCloudMirrorDir"]

    private static func sourceFiles() -> [URL] {
        let root = LaunchConsentGateTests.repoRoot().appendingPathComponent("Sources")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Every `static var <name>: URL` whose body creates a directory, paired with its body.
    private static func creatingGetters(in text: String) -> [(name: String, body: String)] {
        var out: [(String, String)] = []
        var search = text.startIndex
        while let r = text.range(of: "static var ", range: search..<text.endIndex) {
            search = r.upperBound
            guard let brace = text.range(of: "{", range: r.upperBound..<text.endIndex),
                  let colon = text.range(of: ": URL", range: r.upperBound..<brace.lowerBound)
            else { continue }
            let name = String(text[r.upperBound..<colon.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard !name.contains(" "), !name.isEmpty else { continue }
            var depth = 1
            var i = brace.upperBound
            while i < text.endIndex, depth > 0 {
                if text[i] == "{" { depth += 1 } else if text[i] == "}" { depth -= 1 }
                i = text.index(after: i)
            }
            out.append((name, String(text[brace.upperBound..<i])))
        }
        return out
    }

    private static func isUserVisible(_ body: String) -> Bool {
        body.contains("\"Documents\"") || body.contains("CloudDocs") || body.contains("Desktop")
    }

    // MARK: - The control

    /// The parser is the part that can silently find nothing and make the assertion below
    /// vacuous, so it is driven in both directions on known text first.
    func testTheParserFindsACreatingGetterAndIgnoresAPlainOne() {
        let sample = """
        static var makes: URL {
            let dir = home.appendingPathComponent("Documents").appendingPathComponent("Grux")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        static var names: URL {
            home.appendingPathComponent("Documents").appendingPathComponent("Grux")
        }
        """
        let found = Self.creatingGetters(in: sample)
        XCTAssertEqual(found.count, 2, "the parser did not find both getters")
        let creating = found.filter { $0.body.contains("createDirectory") }
        XCTAssertEqual(creating.map(\.name), ["makes"],
                       "the parser must tell a getter that creates from one that only names")
        XCTAssertTrue(Self.isUserVisible(creating[0].body))
    }

    /// And it finds a real population in the real tree, or the rule below proves nothing.
    func testTheSweepFindsTheKnownPopulation() {
        var creating = 0
        for f in Self.sourceFiles() {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            creating += Self.creatingGetters(in: text).filter { $0.body.contains("createDirectory") }.count
        }
        XCTAssertGreaterThan(creating, 15,
                             "the sweep found only \(creating) creating getters in the whole "
                             + "tree, which is too few to be right, so this test proves nothing")
    }

    // MARK: - The rule

    func testNoGetterCreatesAFolderSomebodyWouldSee() throws {
        var offenders: [String] = []
        for f in Self.sourceFiles() {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for (name, body) in Self.creatingGetters(in: text)
            where body.contains("createDirectory") && Self.isUserVisible(body) {
                guard !Self.sanctioned.contains(name) else { continue }
                offenders.append("\(name) in \(f.lastPathComponent)")
            }
        }
        XCTAssertEqual(offenders, [],
                       "these create a folder in a place the person can see, just by being "
                       + "read: \(offenders.joined(separator: ", ")). Name the place in the "
                       + "getter and create it where something is actually written.")
    }
}

/// A KEYCHAIN READ MUST NOT BE ABLE TO PUT A PASSWORD DIALOG ON SOMEBODY'S SCREEN.
///
/// `SecItemCopyMatching` asks macOS to unlock the keychain holding the item, and macOS
/// answers by prompting whoever is there. `SetupStatusFile.write()` runs at launch and
/// resolves every `key.*` capability through `CapabilityResolver`, so a launch performs a
/// dozen keychain reads before anybody has touched anything.
///
/// This was reported, believed fixed, and was not. `KeychainServiceMigrator` got the skip
/// flag and a comment explaining exactly this failure. Nothing generalised it. On the first
/// launch of 1.2.1 on the Mac Mini, a screenshot of its actual screen showed
/// "Grux OS wants to use the "grux-vault" keychain. Please enter the keychain password."
/// sitting over everything, from a different file.
///
/// A sweep then found 42 SecItem calls across ten files, and the migrator held the only four
/// skip flags in the tree. The rule is enforced here now rather than remembered in one file's
/// comment.
final class KeychainNeverPromptsTests: XCTestCase {

    private static func swiftFiles() -> [URL] {
        let root = LaunchConsentGateTests.repoRoot().appendingPathComponent("Sources")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// The control. A sweep that finds nothing makes the rule below vacuous.
    ///
    /// It counts the GUARDED helper's callers rather than raw calls, because the refactor
    /// that made this rule enforceable is exactly what drove the raw count down to one. An
    /// earlier version of this control asserted on raw calls and broke the moment the fix
    /// landed, which is the control correctly noticing that the population moved.
    func testTheSweepFindsTheKeychainCallsItIsSupposedTo() {
        var guarded = 0, raw = 0
        for f in Self.swiftFiles() {
            guard let t = try? String(contentsOf: f, encoding: .utf8) else { continue }
            guarded += t.components(separatedBy: "KeychainStore.copyMatching(").count - 1
            raw += t.components(separatedBy: "SecItemCopyMatching(").count - 1
        }
        XCTAssertGreaterThan(guarded, 8,
                             "found only \(guarded) calls through the guarded helper, which is "
                             + "too few to be right, so this test proves nothing")
        XCTAssertGreaterThan(raw, 0, "and the raw API is still referenced somewhere, or the "
                             + "rule below is asserting about nothing")
    }

    /// Every file that READS a keychain value must skip the UI at least as many times as it
    /// asks for data back.
    ///
    /// ONE FILE IN THE `Grux` MODULE MAY CALL `SecItemCopyMatching`, and that file applies
    /// the flag. Everything else goes through `KeychainStore.copyMatching`.
    ///
    /// THE FIRST TWO VERSIONS OF THIS TEST WERE NOT TESTS. Both counted read queries against
    /// skip flags per file, and both stayed green against planted defects. The first was
    /// inflated by its own prose, because the comment explaining the rule names the constant.
    /// Stripping comments fixed that and it STILL stayed green, because `KeychainStore` shares
    /// one `neverPrompt` constant across several queries: the arithmetic says "guarded" while
    /// an individual query is not. Counting cannot answer this question.
    ///
    /// So the code changed instead of the test. There is now one call site, and "is there
    /// exactly one" is a thing a grep can answer without ambiguity.
    func testNothingCallsTheRawKeychainReadExceptTheOnePlaceThatGuardsIt() {
        var callers: [String] = []
        for f in Self.swiftFiles() {
            guard f.path.contains("/Grux/"), !f.path.contains("/GruxShellCore/") else { continue }
            guard let raw = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let code = raw.components(separatedBy: "\n")
                .map(LaunchConsentGateTests.stripComment).joined(separator: "\n")
            guard code.contains("SecItemCopyMatching(") else { continue }
            if f.lastPathComponent != "KeychainStore.swift" {
                callers.append(f.lastPathComponent)
            }
        }
        XCTAssertEqual(callers, [],
                       "these call SecItemCopyMatching directly, so their queries can raise a "
                       + "keychain password dialog: \(callers.joined(separator: ", ")). Use "
                       + "KeychainStore.copyMatching, which applies kSecUseAuthenticationUISkip.")
    }

    /// AND IT SEARCHES ONLY THE DEFAULT KEYCHAIN, which is the half the skip flag could not
    /// cover and the actual cause of the dialog Jack reported twice.
    ///
    /// A query with no search list traverses EVERY keychain in the login session's list.
    /// Both Macs this was measured on carried a custom keychain created by an unrelated local
    /// tool: creating one adds it to the search list, and it is locked with a password of its
    /// own rather than the login password, so every Grux keychain read walked into it and
    /// macOS asked for a password the person genuinely does not know.
    ///
    /// Measured against the real login keychain on this machine before trusting it:
    /// unconstrained 10 items, constrained 10 items, same status. Constraining hides nothing,
    /// which is expected because `SecItemAdd` with no keychain named writes to the default one.
    func testTheReadIsConfinedToTheKeychainGruxActuallyWritesTo() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/KeychainStore.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let code = raw.components(separatedBy: "\n")
            .map(LaunchConsentGateTests.stripComment).joined(separator: "\n")
        XCTAssertTrue(code.contains("kSecMatchSearchList"),
                      "reads no longer name a search list, so they traverse every keychain in "
                      + "the login session's list and any locked one raises a password dialog")
        let src = raw.components(separatedBy: "\n")
        let body = try XCTUnwrap(
            LaunchConsentGateTests.bodyLines(of: "func copyMatching", in: src))
        XCTAssertFalse(
            LaunchConsentGateTests.lines(containing: "onlyOurOwnKeychain", in: src)
                .filter { body.contains($0) }.isEmpty,
            "the one read call site does not confine its search")
    }

    /// And the one sanctioned caller really does apply the flag, so the rule above is not
    /// pointing at a file that guards nothing.
    func testTheOneSanctionedCallerAppliesTheFlag() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/KeychainStore.swift")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let code = raw.components(separatedBy: "\n")
            .map(LaunchConsentGateTests.stripComment).joined(separator: "\n")
        let calls = code.components(separatedBy: "SecItemCopyMatching(").count - 1
        XCTAssertEqual(calls, 1,
                       "KeychainStore should hold exactly one raw call, found \(calls)")
        XCTAssertTrue(code.contains("kSecUseAuthenticationUISkip"),
                      "the one caller does not apply the skip flag")
        let helper = try XCTUnwrap(code.range(of: "func copyMatching"))
        let body = code[helper.upperBound...].prefix(400)
        XCTAssertTrue(body.contains("withoutUI"),
                      "copyMatching does not route its query through withoutUI")
    }

    /// And the launch-time status write is the specific path that made this urgent, so the
    /// store it goes through is named rather than left implicit.
    func testTheStoreTheLaunchPathUsesCarriesTheFlag() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/KeychainStore.swift")
        let t = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(t.contains("kSecUseAuthenticationUISkip"),
                      "KeychainStore is what CapabilityResolver calls for every key.* "
                      + "capability while SetupStatusFile.write() runs at launch")
    }
}

/// The inject-chat file is a command channel, so its permissions are part of the posture.
///
/// Anything written to ~/.grux/inject-chat.txt reaches `ChatService.send()` and therefore a
/// model with tools. It was created with the default mask, which leaves it world readable, so
/// a line sitting in it before the 0.8 second timer picked it up was legible to any other
/// account on the Mac. The control socket it now shares a switch with has always been 0600.
final class InjectChatPermissionsTests: XCTestCase {

    func testTheInjectChatFileIsOwnerOnly() throws {
        let url = LaunchConsentGateTests.repoRoot()
            .appendingPathComponent("Sources/Grux/GruxApp.swift")
        let src = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        // A WINDOW, NOT bodyLines. The first version used the brace-counting body locator
        // and it returned nil here, so the test failed for a reason that had nothing to do
        // with permissions. `stripComment` truncates a line at `//`, and this function's body
        // contains a URL-shaped literal, so the counter loses the braces after it and never
        // finds the closing one. Anchoring on the file being created is exact and needs no
        // brace counting.
        let created = try XCTUnwrap(
            LaunchConsentGateTests.lines(containing: "inject-chat.txt", in: src).first,
            "the inject-chat file is not created here any more")
        let window = src[created...min(created + 12, src.count - 1)].joined(separator: "\n")
        XCTAssertTrue(window.contains("posixPermissions: 0o600"),
                      "the inject-chat file is created with the default mask, so a command "
                      + "waiting in it is readable by every account on the Mac")
    }
}
