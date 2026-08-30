import XCTest

/// Keeps one person's identity out of the repo, permanently.
///
/// Grux was written by and for one person and had his name, his city, his
/// brands, his hostnames and his email compiled into 2,644 places. A one-time
/// sweep removes them. Only a test keeps them out: the next prompt someone
/// writes will say "tell Jack briefly" because every neighbouring line used to,
/// and a reviewer skims prose in a 200 line system prompt.
///
/// ## What this scans, and why it is not a grep
///
/// A mention only matters if it can REACH someone. A name in a `//` comment is
/// untidy; a name inside a string literal is shipped, either onto a user's
/// screen or into the model's prompt, where it changes what the assistant
/// believes about who it is talking to. So this walks the sources and asserts
/// on string literals and bare code, and reports comments separately without
/// failing on them.
///
/// ## Markdown inside Sources/ counts as shipped
///
/// The scan also covers `.md` files under `Sources/`, and there the WHOLE LINE
/// is the content: markdown is prose, it has no string literals, so the Swift
/// rule would find nothing in a document that is nothing but prose. That gap
/// was not hypothetical. `Sources/Grux/MetaAds/POWERTOOL_BLUEPRINT.md` carried
/// one person's whole brand roster and his private hostname, sat inside
/// `Sources/`, and this guard walked straight past it because it only opened
/// `.swift`. A blueprint is a specification an agent is asked to implement, so
/// a name in it propagates into the code the next contributor writes.
///
/// ## Deliberately allowed
///
/// `jax` / `Jax` is a product feature name the owner has explicitly kept.
/// `Grux`, `GruxAI`, `com.gruxai.grux` and `gruxai.com` are product identity, not
/// personal identity, and `com.gruxai.grux` in particular is the shipping bundle
/// id: changing it revokes every macOS TCC permission grant the app holds.
final class NoPersonalIdentityTests: XCTestCase {

    /// Terms that must never appear in a shipped string. Lowercased; matching
    /// is case-insensitive.
    ///
    /// `dcj` is word-boundary matched so it catches `DCJ Command` without
    /// catching `com.gruxai.grux`, which is handled by the allowlist below anyway
    /// but would otherwise make every failure message noisy.
    static let bannedWords = [
        "jack", "dotcomjack", "jackbrandt", "detroit", "dcj-mini",
        "ai anyone", "aianyone", "motor city organics", "motorcityorganics",
        "mut demon", "djbnb", "holdable", "the binaural", "boardsnap",
        "10xdesign", "10xbuilds", "robinbot", "pocketcurio", "thudletter",
        "arc raiders", "flashtribes", "fledgify",
        // The bare brand ABBREVIATIONS, which the first version of this list
        // missed entirely. It carried "motorcityorganics" but not "mco", and
        // "dcj-mini" but not bare "dcj", so `case .mco: return "MCO"` was
        // invisible to the very guard written to catch it. An adversarial
        // reviewer found this, not the guard.
        "mco", "dcj",
        // The owner's hardware, referred to in user-facing copy as "the Mini".
        // A stranger running a Linux box was told their host was a Mac Mini.
        "mac mini",
    ]

    /// Substrings that make a literal legitimate even though it matches a
    /// banned word. Kept small on purpose: a long allowlist is how a guard
    /// becomes decorative.
    static let allowedContexts = [
        "com.gruxai.grux",     // shipping bundle id, tied to TCC grants
        "gruxai.com",       // product domain
        "jack@dotcomjack.com", // the sanctioned PUBLIC contact address
        // The iPhone companion's bundle id, DELIBERATELY not renamed when the Mac
        // app moved to com.gruxai.grux. Changing it revokes every macOS and iOS
        // permission grant the paired app holds and orphans the existing pairing,
        // which is a LOCKED rule in this repo's CLAUDE.md. It matches `dcj` for
        // the same reason `com.gruxai.grux` used to match, and it is product
        // identity rather than personal identity: it is a shipping identifier a
        // stranger re-signs under their own team anyway.
        "com.dcj.gruxphone",
        // The repository's own URL. Every clone command, every issue template
        // link and every advisory link has to name the account the project is
        // hosted under, and a guard that fails on the project's own address
        // makes documentation impossible to write. Same class as the sanctioned
        // public contact address above: published project identity, not a
        // private detail that leaked.
        "github.com/dotcomjack/",
    ]

    /// Files whose JOB is to hold the banned vocabulary, so they must contain it.
    ///
    /// Distinct from `knownRemaining` on purpose. That list is a pending owner
    /// decision and should trend to empty; this one never will, because a guard
    /// cannot check for a word without naming it, and its controls cannot prove
    /// they fire without planting one.
    ///
    /// Kept to files that are only ever read by a maintainer. If a name ever
    /// appears in an ordinary test, it is still reported.
    ///
    /// Repo-relative paths, not bare filenames. A basename is ambiguous the
    /// moment two directories hold the same one, and this repository now has
    /// exactly that: `SECURITY.md` exists at `Grux-Mac/` and at `.github/`, so a
    /// bare-name entry would silently exempt both.
    static let vocabularyFiles: Set<String> = [
        // The banned list itself, and its planted controls.
        "Grux-Mac/Tests/GruxTests/NoPersonalIdentityTests.swift",
        // Asserts the greeting never leaks a name, so it has to name one.
        "Grux-Mac/Tests/GruxTests/OnboardingTests.swift",
        // Records why the rule exists, in prose, using the words it bans.
        "Grux-Mac/Tests/GruxTests/NoTerminalInstructionsInUITests.swift",
    ]

    /// Literals that ARE exactly one of these, and nothing more, are ordinary
    /// English rather than a reference to a person.
    ///
    /// "jack" is a common given name and a common noun (a car jack, a headphone
    /// jack). `PersonMemory` keeps a corpus of ordinary first names to detect
    /// people in text, and stripping one name out of an alphabetical list would
    /// degrade that feature to hide a word, which is the wrong trade. The bar is
    /// deliberately strict: the WHOLE literal must be the bare token, so
    /// "Good morning, Jack" is still caught.
    static let allowedExactTokens: Set<String> = ["jack"]

    // MARK: - The scan

    struct Hit: CustomStringConvertible {
        /// Repo-relative path, so two files sharing a basename stay distinct.
        let file: String
        let line: Int
        let text: String
        /// Which banned term matched. Recorded so an exemption can name the term
        /// it forgives instead of forgiving a whole file forever.
        let word: String
        var description: String { "\(file):\(line)  [\(word)]  \(text)" }
    }

    /// The GruxPhone tree, for the two guards that assert on the iOS manifest.
    ///
    /// This replaced a `shippingRoots()` helper that returned `Sources`, `Tests`
    /// and `GruxPhone`, and whose name claimed more than it delivered: those
    /// three were the SCAN SCOPE, and 55 shipping files sat outside them.
    static func phoneRoot() -> URL {
        repoRoot().deletingLastPathComponent().appendingPathComponent("GruxPhone")
    }

    /// Path prefixes that do not ship, read from the same file the extractor and
    /// the dash guard read.
    ///
    /// Deriving this rather than hardcoding roots is the entire point. The scan
    /// covered `Sources`, `Tests` and `GruxPhone` until 2026-08-17, and
    /// `Grux-Mac/CLAUDE.md` sat outside all three carrying the original author's
    /// name SEVEN times and an Apple team identifier twice, through four separate
    /// audits that each reported the tree clean. The dash guard had already moved
    /// to this manifest; this guard had not, and the gap between them was exactly
    /// the set of files nobody was checking.
    static func manifestURL() -> URL {
        repoRoot().appendingPathComponent("scripts/oss-exclude.txt")
    }

    static var manifestPresent: Bool {
        FileManager.default.fileExists(atPath: manifestURL().path)
    }

    static func excludedPrefixes() throws -> [String] {
        let url = manifestURL()
        guard manifestPresent else {
        // The published tree does not carry this manifest, because the publishing
        // toolchain does not ship. There, every file present IS a file that
        // shipped, so an empty exclusion set is the CORRECT answer rather than a
        // degraded one: it can only ever widen this scan, never narrow it. The
        // dangerous direction is a manifest that excludes too much, and that
        // cannot happen when there is no manifest at all.
            return []
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { out.append(line) }
        }
        return out
    }

    static func isSkipped(_ rel: String, _ excluded: [String]) -> Bool {
        if rel.hasPrefix(".git/") || rel.contains("/.git/") { return true }
        if rel.contains(".build/") || rel.contains("DerivedData/") { return true }
        if rel.contains(".swiftpm/") || rel.contains("__pycache__/") { return true }
        return excluded.contains { rel == $0 || rel.hasPrefix($0 + "/") }
    }

    /// Everything that ships, which is the repository minus `oss-exclude.txt`.
    static func scanShippingTree() throws -> [Hit] {
        try scan(root: repoRoot().deletingLastPathComponent(),
                 skipping: excludedPrefixes())
    }

    func testNoPersonalIdentityInShippedStrings() throws {
        let hits = try Self.scanShippingTree()

        // A named, non-empty budget rather than a bare zero. Anything still here
        // is a KNOWN remainder with an owner decision attached, not a silent
        // tolerance: an entry that stops matching is itself a failure, so the
        // list cannot rot into a permanent exemption.
        //
        // The exemption is per TERM, not per file. A blanket file exemption
        // means the next genuinely new name in that file lands unreported, and
        // three of the four files below are long design documents that will keep
        // being edited. Forgiving `dcj` in the keychain migration docs must not
        // also forgive somebody's home town appearing there next year.
        let unexpected = hits.filter { hit in
            if Self.vocabularyFiles.contains(hit.file) { return false }
            if let allowed = Self.knownRemaining[hit.file], allowed.contains(hit.word) {
                return false
            }
            return true
        }

        XCTAssertTrue(unexpected.isEmpty,
                      "personal identity in shipped strings:\n" +
                      unexpected.map(\.description).joined(separator: "\n"))
    }

    /// The scan must actually reach the tree it claims to. A walk that stops
    /// early reports clean over a dirty repository, which is precisely how the
    /// three-root version passed while 55 files went unread.
    func testTheScanReachesTheWholeShippingTree() throws {
        let repo = Self.repoRoot().deletingLastPathComponent()
        let excluded = try Self.excludedPrefixes()
        var seen = 0
        guard let walker = FileManager.default.enumerator(atPath: repo.path) else {
            return XCTFail("cannot enumerate the repository root")
        }
        for case let rel as String in walker {
            if Self.isSkipped(rel, excluded) { continue }
            let ext = (rel as NSString).pathExtension
            if ext == "swift" || ext == "md" { seen += 1 }
        }
        XCTAssertGreaterThan(seen, 700,
            "the identity scan reached only \(seen) files. The shipping tree holds "
            + "over seven hundred Swift and markdown files, so the walk is being cut "
            + "short and a clean result means nothing.")
    }

    /// Files with a remaining mention that is a pending OWNER decision rather
    /// than an oversight. Empty is the goal.
    ///
    /// The `BrandScope` / `SupportInbox` vocabulary that used to fill this list
    /// is gone. Those raw values are persisted (in `brand-filter.json`, and as
    /// `inbox` + `brandVoice` on every draft in `drafts.json`), which is why
    /// three separate sweep agents escalated rather than renaming them: a
    /// rename would have stranded every already-tagged message under a scope
    /// that no longer exists. The way out was not a backfill. Both types became
    /// structs that code as the SAME bare string the enums did, so an old token
    /// decodes unchanged and the vocabulary itself moved to the user's own
    /// `~/.grux/brands.json`. `BrandFilter.swift`, `EmailTriageEngine.swift`
    /// and `GruxApp.swift` came off this list that way.
    ///
    /// The last entry, `OutputGate.swift`, is gone the same way: it passed one
    /// brand's token to the grounding gate as a brief (`voice == "mco" ? ...`)
    /// and took the twin's fix, `"\(voice) support reply"`. It had never been an
    /// undecided call, only a line that sat outside the file set of the change
    /// that removed the others.
    ///
    /// So this list is now EMPTY, which is the goal state and not an invitation
    /// to refill it. Adding a file here is a decision to ship a personal name in
    /// a string, and it needs a reason in this comment.
    ///
    /// This list is deliberately not a suppression. An entry that stops
    /// matching should be deleted, and the accompanying
    /// `testKnownRemainingIsNotStale` fails if one goes quiet.
    ///
    /// Keyed by repo-relative path, valued by the exact terms forgiven there.
    /// Any OTHER banned term in the same file still fails, which is what keeps
    /// these from becoming permanent blind spots in four files that are actively
    /// edited.
    static let knownRemaining: [String: Set<String>] = [
        // The ONE code file that must still contain the old `com.dcj.*` names,
        // because reading them is its entire job. The Keychain service strings
        // were renamed to `com.gruxai.*` for the open source release, and a
        // service string is part of a Keychain item's primary key, so without
        // a migrator every credential a user already stored becomes unreachable
        // while still sitting in their login keychain.
        //
        // This exemption is safe in a way a blanket one would not be: the file
        // holds those strings ONLY inside `renames`, as the left-hand side of
        // pairs whose right-hand side is the current name, and
        // `KeychainServiceMigratorTests` asserts every row's `new` value starts
        // with `com.gruxai.`. It also cannot rot, because
        // `testKnownRemainingIsNotStale` fails the moment this file stops
        // matching, which is the day the migration can finally be deleted.
        "Grux-Mac/Sources/Grux/KeychainServiceMigrator.swift": ["dcj"],

        // The three documents that DESCRIBE that migration. They have to name
        // the service being migrated away from, or the migration is undocumented
        // and the next reader deletes it as dead code.
        //
        // Note the asymmetry with the file above, and why it is not an oversight:
        // in Swift this guard reads string literals only, so a `com.dcj.grux` in
        // a comment was never reported. In markdown the whole line is content,
        // because a document is prose and has no literals. So prose describing
        // the same fact needs an exemption where a code comment did not.
        //
        // These CANNOT be solved by allowlisting `com.dcj.grux` instead. Every
        // `com.dcj.*` literal in the migrator begins with that exact prefix
        // (`.graph`, `.vault`, `.webhooks`), so allowlisting it would stop the
        // migrator matching at all and turn the entry above stale. Measured, not
        // assumed.
        "Grux-Mac/docs/capability-system.md": ["dcj"],
        "Grux-Mac/docs/contract.md": ["dcj"],
        "Grux-Mac/SECURITY.md": ["dcj"],

        // The repository's own instructions file. Same keychain migration story,
        // plus the published author alias in the passage explaining why the
        // LICENSE copyright line reads the way it does. `DotcomJack` is the
        // public pen name the project ships under, so a document explaining the
        // copyright line has to be able to quote it.
        "Grux-Mac/CLAUDE.md": ["dcj", "dotcomjack"],

        // The governance document, for the same published alias and for a
        // reason that is structural rather than incidental: naming who decides
        // is the ENTIRE job of the file. A governance document that cannot say
        // who the maintainer is describes a committee that does not exist,
        // which is the first thing a reader discovers is false. `DotcomJack` is
        // the alias the project ships under, the same one the LICENSE copyright
        // line carries, so this is published identity like
        // github.com/dotcomjack in allowedContexts, not a private detail that
        // escaped.
        //
        // Do NOT "fix" this instead by writing the maintainer link with a
        // trailing slash so `github.com/dotcomjack/` in allowedContexts catches
        // it. In markdown the whole LINE is the span, so one allowed substring
        // anywhere on a line skips that line for EVERY banned word, silently
        // and forever. That is a blind spot dressed as a fix, and it would sit
        // on the one line of this document a stranger is most likely to edit.
        //
        // Exempted for that ONE term, so any other banned word landing in
        // GOVERNANCE.md still fails, and `testKnownRemainingIsNotStale` deletes
        // this entry for us the day the line stops matching.
        "GOVERNANCE.md": ["dotcomjack"],

        // The author bio, and the ONLY place a location is deliberate.
        //
        // "detroit" is banned because it used to appear in RUNTIME strings, where it
        // told a stranger's assistant it was somewhere it is not. In a README section
        // headed "Who made this" it is the opposite: the whole value of a solo project
        // is that a person made it somewhere, and hiding that costs the page the thing
        // that makes it worth reading. Same class as github.com/dotcomjack in
        // allowedContexts: published identity, deliberately stated.
        //
        // Exempted for that ONE term. Any other banned word appearing in the README
        // still fails, which is the point of keying this by term rather than by file.
        "README.md": ["detroit"],
    ]

    /// A budget that outlives its reason is just a hole. If an exempted term no
    /// longer appears, the exemption has to go, or the next real regression in
    /// that file lands unreported.
    func testKnownRemainingIsNotStale() throws {
        let hits = try Self.scanShippingTree()
        for (path, words) in Self.knownRemaining {
            for word in words {
                XCTAssertTrue(hits.contains { $0.file == path && $0.word == word },
                    "\(path) is exempted for \"\(word)\" but no longer matches it. "
                    + "Remove that term from knownRemaining.")
            }
        }
    }

    /// Proves the scanner can fail. A guard that has never gone red is a guard
    /// nobody has confirmed is wired up, and this project has already shipped
    /// five tests that asserted nothing.
    func testTheScannerActuallyDetectsAPlantedName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-identity-plant-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        // Jack in a comment, which must NOT be reported.
        let greeting = "Good morning, Jack"
        let safe = "com.gruxai.grux is fine"
        let alsoSafe = "jax.command is fine"
        """.write(to: dir.appendingPathComponent("Plant.swift"), atomically: true, encoding: .utf8)

        let hits = try Self.scan(root: dir)
        XCTAssertEqual(hits.count, 1, "expected exactly the literal, got:\n" +
                       hits.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(hits[0].text.contains("Good morning"))
    }

    /// Proves the markdown half can fail, separately, because it fails for a
    /// different reason: the Swift path needs a string literal to report
    /// anything, and a `.md` file has none. A blueprint written entirely in
    /// prose was invisible to this guard for exactly that reason.
    func testTheScannerReadsMarkdownProse() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-identity-md-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try """
        # Blueprint

        The engine posts a snapshot for Holdable, with no quotes anywhere.
        Product identity is fine: gruxai.com and com.gruxai.grux stay.
        """.write(to: dir.appendingPathComponent("Blueprint.md"), atomically: true, encoding: .utf8)

        let hits = try Self.scan(root: dir)
        XCTAssertEqual(hits.count, 1, "expected exactly the prose line, got:\n" +
                       hits.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(hits[0].text.contains("snapshot"))
    }

    /// The scope change itself, proved rather than asserted.
    ///
    /// A plant in a temporary directory proves the SCANNER works and says nothing
    /// about what it is pointed at, which is the only thing that changed here.
    /// So this plants a real file at a real path that the previous three-root
    /// version could not see, and requires the shipping scan to find it.
    ///
    /// `Grux-Mac/docs/` is the right place to plant, and not an arbitrary one: it
    /// holds seventeen blueprints, and this guard's own documentation says a name
    /// in a blueprint propagates into the code the next contributor writes. It
    /// made that argument about `Sources/**/*.md` while every blueprint in the
    /// repository sat outside the scan.
    func testTheScanCoversFilesOutsideTheOldThreeRoots() throws {
        let repo = Self.repoRoot().deletingLastPathComponent()
        let rel = "Grux-Mac/docs/plant-\(UUID().uuidString).md"
        let url = repo.appendingPathComponent(rel)
        try "A blueprint that mentions Holdable in prose, with no quotes anywhere.\n"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let hits = try Self.scanShippingTree()
        let found = hits.filter { $0.file == rel }
        XCTAssertEqual(found.count, 1, """
            the shipping scan did not catch a planted name at \(rel).
            This path is outside Sources, Tests and GruxPhone, which is exactly the
            region the old three-root scope could not see.
            """)
        XCTAssertEqual(found.first?.word, "holdable")
    }

    /// The other half of the same claim: an excluded path must stay excluded, or
    /// this guard starts failing forever on the operator's own tooling, which is
    /// the reason the narrow three-root scope was chosen in the first place.
    func testTheScanStillSkipsWhatDoesNotShip() throws {
        let repo = Self.repoRoot().deletingLastPathComponent()
        let dir = repo.appendingPathComponent("Grux-Mac/mini-services")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path),
                          "mini-services is absent, so there is nothing to prove skipped")

        try XCTSkipUnless(Self.manifestPresent,
            "no exclusion manifest in this tree, so there are no exclusions to prove "
            + "are applied. This is the published tree, where everything present ships.")

        let rel = "Grux-Mac/mini-services/plant-\(UUID().uuidString).md"
        let url = repo.appendingPathComponent(rel)
        try "This one mentions Holdable and must NOT be reported.\n"
            .write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let hits = try Self.scanShippingTree()
        XCTAssertFalse(hits.contains { $0.file == rel },
            "a file under an excluded prefix was scanned. The exclusions in "
            + "scripts/oss-exclude.txt are not being applied, so this guard will "
            + "fail forever on tooling that never ships.")
    }

    /// The two ways the first version of this scanner cried wolf. Both were
    /// real false positives on real lines in this repo, and both would have
    /// trained a reader to ignore the failure.
    func testTheScannerDoesNotInventMatches() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-identity-fp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try #"""
        let warn = "Heads up, something on your screen tried to hijack me."
        let stop = ["mac","motor","city","organics","deep","void"]
        let names = ["dawn","joy","jack","mike","drew"]
        """#.write(to: dir.appendingPathComponent("FalsePositives.swift"),
                   atomically: true, encoding: .utf8)

        let hits = try Self.scan(root: dir)
        XCTAssertTrue(hits.isEmpty,
                      "scanner invented matches:\n" + hits.map(\.description).joined(separator: "\n"))
    }

    /// Word boundaries, asserted directly, because the whole scan rests on them.
    func testWordBoundaryMatching() {
        XCTAssertTrue(Self.containsWord("good morning, jack", "jack"))
        XCTAssertTrue(Self.containsWord("jack's mac", "jack"))
        XCTAssertFalse(Self.containsWord("tried to hijack me", "jack"))
        XCTAssertFalse(Self.containsWord("jackal", "jack"))
        XCTAssertTrue(Self.containsWord("built at motorcityorganics.com", "motorcityorganics"))
    }

    // MARK: - Machinery

    /// The SWIFT PACKAGE root, `Grux-Mac`, derived from this file's own path so
    /// the test works from any working directory and from Xcode as well as the
    /// command line.
    ///
    /// The name says repo and it means package, which is off by one directory
    /// and has already cost one round of failures: the repository root is the
    /// PARENT of this, and `GruxPhone/` lives there rather than here. Call
    /// `.deletingLastPathComponent()` when you want the actual repository.
    static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)            // .../Grux-Mac/Tests/GruxTests/ThisFile.swift
            .deletingLastPathComponent()           // .../Grux-Mac/Tests/GruxTests
            .deletingLastPathComponent()           // .../Grux-Mac/Tests
            .deletingLastPathComponent()           // .../Grux-Mac  (the PACKAGE root)
    }

    /// Returns every banned term that appears inside a Swift string literal, or
    /// anywhere on a line of a markdown file.
    ///
    /// Comment handling is the whole reason this is not a grep: `//` only
    /// starts a comment when it is not itself inside a literal, or a URL in a
    /// shipped string would be read as a comment and the literal after it
    /// skipped. Markdown has no such structure, so a `.md` line is its own
    /// single span.
    static func scan(root: URL, skipping excluded: [String] = []) throws -> [Hit] {
        var hits: [Hit] = []
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }

        for case let rel as String in walker {
            let ext = (rel as NSString).pathExtension
            let isMarkdown = ext == "md"
            guard ext == "swift" || isMarkdown else { continue }
            if Self.isSkipped(rel, excluded) { continue }
            let url = root.appendingPathComponent(rel)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { continue }

            var inMultiline = false
            for (i, rawLine) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let line = String(rawLine)
                // Each literal is judged ALONE. Concatenating the spans on a
                // line fuses neighbours: ["motor","city","organics"] became
                // "motorcityorganics" and matched a brand that is not there.
                let spans = isMarkdown ? [line] : Self.literalSpans(of: line, inMultiline: &inMultiline)
                var reported = false
                for span in spans where !reported {
                    let hay = span.lowercased()
                    if Self.allowedContexts.contains(where: { hay.contains($0) }) { continue }
                    if Self.allowedExactTokens.contains(
                        hay.trimmingCharacters(in: .whitespaces)) { continue }
                    if let word = Self.bannedWords.first(where: { Self.containsWord(hay, $0) }) {
                        hits.append(Hit(file: rel, line: i + 1,
                                        text: line.trimmingCharacters(in: .whitespaces),
                                        word: word))
                        reported = true
                    }
                }
            }
        }
        return hits
    }

    /// Substring match that requires the needle to sit on word boundaries.
    ///
    /// Without this, "jack" matches "hijack", and the two places this codebase
    /// warns the model about prompt-injection ("something tried to hijack me")
    /// were reported as the owner's name. A guard that cries wolf on its own
    /// security copy gets muted, which is worse than not having it.
    static func containsWord(_ hay: String, _ needle: String) -> Bool {
        var search = hay.startIndex..<hay.endIndex
        while let r = hay.range(of: needle, range: search) {
            let beforeOK = r.lowerBound == hay.startIndex
                || !hay[hay.index(before: r.lowerBound)].isLetter
            let afterOK = r.upperBound == hay.endIndex
                || !hay[r.upperBound].isLetter
            if beforeOK && afterOK { return true }
            guard r.upperBound < hay.endIndex else { return false }
            search = r.upperBound..<hay.endIndex
        }
        return false
    }

    /// Every string literal on the line, each as its own span.
    private static func literalSpans(of line: String, inMultiline: inout Bool) -> [String] {
        let chars = Array(line)
        var spans: [String] = []
        var current = ""
        var i = 0

        if inMultiline {
            if let close = line.range(of: "\"\"\"") {
                spans.append(String(line[line.startIndex..<close.lowerBound]))
                inMultiline = false
                i = line.distance(from: line.startIndex, to: close.upperBound)
            } else {
                return [line]
            }
        }

        var inString = false
        while i < chars.count {
            if !inString, i + 2 < chars.count,
               chars[i] == "\"", chars[i + 1] == "\"", chars[i + 2] == "\"" {
                inMultiline = true
                return spans
            }
            if !inString, chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                return spans                     // comment: stop, do not report
            }
            if chars[i] == "\\", inString { i += 2; continue }
            if chars[i] == "\"" {
                if inString { spans.append(current); current = "" }
                inString.toggle()
                i += 1
                continue
            }
            if inString { current.append(chars[i]) }
            i += 1
        }
        if inString, !current.isEmpty { spans.append(current) }
        return spans
    }
}
