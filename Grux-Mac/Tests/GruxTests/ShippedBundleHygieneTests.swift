import XCTest

/// What actually ends up inside Grux.app, checked against what the package
/// actually depends on.
///
/// This exists because PostHog was removed from `Package.swift` and
/// `Package.resolved`, the binary linked none of it, every source grep came back
/// clean, and `PostHog_PostHog.bundle` was STILL being shipped inside
/// `/Applications/Grux.app`, carrying a `PrivacyInfo.xcprivacy` that declares
/// data collection by a dependency the app no longer has.
///
/// The cause: SwiftPM regenerates the resource bundles the current graph needs
/// and never deletes the ones it does not, and `build.sh` copied every
/// `.build/release/*.bundle` it found. So a removed dependency's manifest
/// survives every rebuild, indefinitely, while all the obvious checks pass.
///
/// For an app whose entire promise is that it phones nobody, a stale privacy
/// manifest is a false declaration about the exact thing users are being asked
/// to trust. Source-level greps cannot see it. Only the artifact can.
final class ShippedBundleHygieneTests: XCTestCase {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GruxTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Grux-Mac
    }

    /// Package identities the manifest actually declares, lowercased.
    private static func declaredDependencies() throws -> Set<String> {
        let pkg = try String(contentsOf: repoRoot().appendingPathComponent("Package.swift"),
                            encoding: .utf8)
        var names = Set<String>()
        let re = try NSRegularExpression(pattern: #"\.package\([^)]*url:\s*"([^"]+)""#)
        let ns = pkg as NSString
        for m in re.matches(in: pkg, range: NSRange(location: 0, length: ns.length)) {
            let url = ns.substring(with: m.range(at: 1))
            let last = url.split(separator: "/").last.map(String.init) ?? ""
            names.insert(last.replacingOccurrences(of: ".git", with: "").lowercased())
        }
        return names
    }

    /// Bundles a SwiftPM build legitimately produces for a dependency, named
    /// `<Package>_<Target>.bundle`. Transitive dependencies are allowed, so this
    /// is a denylist of KNOWN-DEAD packages rather than an allowlist of live
    /// ones: an allowlist would fail every time a dependency gained a transitive
    /// child, which is noise, and noise gets muted.
    private static let retiredPackages = ["posthog", "plcrashreporter"]

    func testNoResourceBundleFromARetiredDependencyIsStaged() throws {
        // `.build/release` is a SYMLINK to `.build/<triple>/release`, so resolve
        // it before listing. An unresolved read returns nothing rather than
        // erroring, and the first version of this test swallowed that into a
        // skip: it reported "no release build present" while two bundles sat
        // right there. A check that skips itself is a check that never runs.
        let releaseDir = Self.repoRoot()
            .appendingPathComponent(".build/release")
            .resolvingSymlinksInPath()

        try XCTSkipUnless(FileManager.default.fileExists(atPath: releaseDir.path),
                          "no release build present to inspect")

        let contents = try FileManager.default.contentsOfDirectory(
            at: releaseDir, includingPropertiesForKeys: nil)
        // THE CONTROL, CORRECTED. This asserted that BUNDLES exist, which made a
        // clean build directory a failure: the package declares no resources, so
        // zero bundles is the CORRECT end state and precisely what this test
        // wants to see. It went red the moment anybody ran a release build, for
        // a tree that was in exactly the right condition.
        //
        // What genuinely needs proving is that the path RESOLVED, because an
        // unresolved read returns an empty list and would pass no matter what
        // shipped, which is the silent-skip failure the comment above describes.
        XCTAssertFalse(contents.isEmpty,
            "the release directory resolved to nothing, so this test is looking in the wrong "
            + "place and would pass no matter what shipped")

        let bundles = contents.filter { $0.pathExtension == "bundle" }

        for b in bundles {
            let name = b.lastPathComponent.lowercased()
            for retired in Self.retiredPackages {
                XCTAssertFalse(name.contains(retired),
                    "\(b.lastPathComponent) belongs to \(retired), which this package no longer "
                    + "depends on. SwiftPM does not delete bundles for removed dependencies, so "
                    + "build.sh must prune .build/release/*.bundle before building or this ships.")
            }
        }
    }

    /// The manifest must not name a retired dependency either. Cheap, and it is
    /// the file the bundle check is ultimately protecting.
    func testManifestDoesNotDeclareARetiredDependency() throws {
        let declared = try Self.declaredDependencies()
        XCTAssertFalse(declared.isEmpty, "parsed zero dependencies; the Package.swift parser is wrong")
        for retired in Self.retiredPackages {
            XCTAssertFalse(declared.contains { $0.contains(retired) },
                "Package.swift still declares \(retired)")
        }
    }

    /// The INSTALLED app must not carry the builder's home directory.
    ///
    /// SwiftPM generates a `resource_bundle_accessor.swift` per resource-bearing
    /// target and hardcodes the absolute build path as a fallback, so
    /// `/Users/<builder>/...` ships inside the binary. It is dead code, since
    /// the bundle is copied into Contents/Resources and resolves first, but the
    /// string is readable by anyone who runs `strings` on the download. For an
    /// open source release that is a gratuitous leak of a username and a
    /// directory layout.
    ///
    /// build.sh overwrites them with an equal-length placeholder before signing.
    /// Measured: 809 occurrences in one build, of which `strings` surfaced one,
    /// so a spot check with `strings | grep` understates this by three orders of
    /// magnitude.
    func testInstalledAppCarriesNoBuilderHomePath() throws {
        let installed = URL(fileURLWithPath: "/Applications/Grux.app/Contents/MacOS/Grux")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: installed.path),
                          "Grux is not installed; nothing to inspect")

        let data = try Data(contentsOf: installed)
        let found = Self.occurrences(of: "/Users/", in: data)
        XCTAssertEqual(found, 0,
            "the installed binary contains \(found) absolute /Users/ path(s). build.sh must "
            + "redact SwiftPM's embedded build paths before codesign, or every download "
            + "carries the builder's home directory.")
    }

    /// The author's name must not appear in the app's own code or strings.
    ///
    /// ## SCOPE WARNING, and it is a limit of the method not of the intent
    ///
    /// A raw byte scan reliably finds EMBEDDED PATHS and CERTIFICATE CONTENT. It
    /// proved both: 1327 build paths that `strings` reduced to one, and the
    /// `organizationName` of the signing certificate.
    ///
    /// It does NOT reliably find Swift string literals. Attempts to plant one and
    /// watch this fail did not reproduce: an unused `static let` is dead-stripped,
    /// and even a live 77-byte literal returned from a reachable property did not
    /// appear as searchable bytes. Independently, "Good morning" and "Still up",
    /// which are live literals in `HomeBriefingModel.greeting`, return ZERO on the
    /// same scan while a live sidebar label returned ten. So release-mode Swift does
    /// not store these uniformly in a contiguous, byte-searchable form.
    ///
    /// **Therefore this test is NOT the guard against a name in a shipped string.**
    /// `NoPersonalIdentityTests` is, at the source level, and that one IS
    /// mutation-proved: planting `"Good morning, <name>"` into a `GruxPhone`
    /// literal makes it fail. This test is the guard against the name arriving by
    /// a route source inspection cannot see, which is a real and separate risk,
    /// and it is the check that found the build-path leak.
    ///
    /// Recorded rather than quietly kept, because a test whose failure has never
    /// been demonstrated is a claim, not a check, and this file exists to make
    /// exactly that distinction.
    ///
    /// Scoped to exclude the `LC_CODE_SIGNATURE` blob, and that exclusion is a
    /// fact about code signing rather than a convenience. Every signed macOS app
    /// embeds its signing certificate, and an Apple-issued certificate carries
    /// the developer account's legal name in its `organizationName` field
    /// (`O=...`). It is signed BY APPLE, so it cannot be altered without
    /// invalidating the signature, and shipping unsigned code is not an option:
    /// Gatekeeper refuses it outright.
    ///
    /// Measured on the shipped binary: exactly one occurrence, at offset
    /// 55,458,543, inside a signature region running from 55,342,368. Occurrences
    /// outside that region: ZERO. So the invariant worth asserting is not "the
    /// name appears nowhere in the file", which is unachievable, but "the name
    /// appears nowhere WE control", which is both achievable and the real
    /// requirement.
    func testTheAuthorsNameAppearsNowhereWeControl() throws {
        let installed = URL(fileURLWithPath: "/Applications/Grux.app/Contents/MacOS/Grux")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: installed.path),
                          "Grux is not installed; nothing to inspect")
        let data = try Data(contentsOf: installed)

        // Find the signature region via otool, so the boundary is read from the
        // Mach-O rather than hardcoded from one measurement.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        p.arguments = ["-l", installed.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()

        var sigStart = data.count
        if let cmd = out.range(of: "LC_CODE_SIGNATURE") {
            let tail = out[cmd.upperBound...]
            if let off = tail.range(of: "dataoff ") {
                let digits = tail[off.upperBound...].prefix { $0.isNumber }
                sigStart = Int(digits) ?? data.count
            }
        }
        XCTAssertLessThan(sigStart, data.count,
            "could not locate LC_CODE_SIGNATURE, so this test would scan the whole file "
            + "including the certificate and fail for the wrong reason")

        // Needles ASSEMBLED at runtime, so this file does not itself contain the
        // strings it bans. Without that, `NoPersonalIdentityTests` reports this
        // very test as a leak, which it did on the first run: a guard holding its
        // vocabulary as literals is indistinguishable from the thing it hunts.
        // Same trick NoTelemetryInSourcesTests uses, and it beats adding another
        // exemption, because an exemption is a hole and this is not.
        let first = "J" + "ack"
        let last = "Br" + "andt"
        let needles = [
            first + " " + last,
            (first + last).lowercased(),
            "dotcom" + first.lowercased(),
            "Det" + "roit",
        ]
        let code = data.prefix(sigStart)
        for needle in needles {
            let count = Self.occurrences(of: needle, in: code,
                                         allowed: NoPersonalIdentityTests.allowedContexts)
            XCTAssertEqual(count, 0,
                "\"\(needle)\" appears \(count) time(s) in the app's own code or strings, "
                + "outside the code-signature blob")
        }
    }

    /// Every position where `needle`'s bytes start in `data`, overlapping ones
    /// included, which is what the byte-by-byte loop this replaced counted.
    ///
    /// `memmem` rather than a Swift loop: these scans read the whole 63 MB
    /// installed binary, and in the debug build tests run in, slicing an Array at
    /// every offset and `Data.ranges(of:)` took 32 s and 47 s of a 787 s suite
    /// (measured 2026-10-22). Same bytes, same count, in milliseconds.
    ///
    /// A hit that sits inside one of `allowed`, byte for byte, is not counted. That
    /// is how the scan honours the sanctioned public strings in
    /// `banned-vocabulary.json`'s `allowed_contexts`, the same list the source guard
    /// reads: the 3.1 About credit links `https://dotcomjack.com` and the agent work
    /// order clones `github.com/dotcomjack/grux`, so every installed 3.1 build failed
    /// this scan while the suite that passed had read an older install. A bare name
    /// is still counted.
    static func occurrences(of needle: String, in data: Data, allowed: [String] = []) -> Int {
        let pattern = Array(needle.utf8)
        guard !pattern.isEmpty else { return 0 }
        // Each context containing the needle, with every offset the needle sits at in it.
        let covers: [([UInt8], Int)] = allowed.flatMap { context -> [([UInt8], Int)] in
            let c = Array(context.utf8)
            guard c.count >= pattern.count else { return [] }
            return (0...(c.count - pattern.count))
                .filter { Array(c[$0..<($0 + pattern.count)]) == pattern }
                .map { (c, $0) }
        }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var found = 0
            var offset = 0
            while offset + pattern.count <= raw.count,
                  let hit = memmem(base + offset, raw.count - offset, pattern, pattern.count) {
                let at = base.distance(to: UnsafeRawPointer(hit))
                let excused = covers.contains { context, k in
                    at - k >= 0 && at - k + context.count <= raw.count
                        && memcmp(base + (at - k), context, context.count) == 0
                }
                if !excused { found += 1 }
                offset = at + 1
            }
            return found
        }
    }

    /// The counter both binary scans rest on: every start, overlapping ones too, one
    /// at the very end, none in too short a buffer, and a slice counts only its own
    /// bytes (the signature scan hands it a prefix).
    func testOccurrencesCountsEveryStartTheOldLoopCounted() {
        let text = Data("/Users/Users/x/Users/".utf8)
        XCTAssertEqual(Self.occurrences(of: "/Users/", in: text), 3)
        XCTAssertEqual(Self.occurrences(of: "/Users/", in: text.dropFirst()), 2)
        XCTAssertEqual(Self.occurrences(of: "/Users/", in: text.prefix(12)), 1)
        XCTAssertEqual(Self.occurrences(of: "/Users/", in: Data("/User".utf8)), 0)
        XCTAssertEqual(Self.occurrences(of: "aa", in: Data("aaaa".utf8)), 3)
        XCTAssertEqual(Self.occurrences(of: "/Users/", in: Data()), 0)
        // A sanctioned context forgives the hit inside it and no other.
        // (A neutral word: the counter is generic, and a banned one written here
        // would be the identity guard's next hit.)
        let mixed = Data("credit https://acme.example and a bare acme".utf8)
        XCTAssertEqual(Self.occurrences(of: "acme", in: mixed), 2)
        XCTAssertEqual(Self.occurrences(of: "acme", in: mixed, allowed: ["https://acme.example"]), 1)
        // A context cut off by the end of the buffer does not excuse anything.
        XCTAssertEqual(Self.occurrences(of: "acme", in: Data("https://acme".utf8),
                                        allowed: ["https://acme.example"]), 1)
    }

    /// build.sh must keep the prune. Without it the bundle check above passes on
    /// a clean checkout and the shipped app still carries whatever was left in
    /// .build from a previous graph.
    func testBuildScriptPrunesStaleBundlesBeforeBuilding() throws {
        let script = try String(contentsOf: Self.repoRoot().appendingPathComponent("build.sh"),
                                encoding: .utf8)
        guard let prune = script.range(of: "rm -rf .build/release/*.bundle"),
              let build = script.range(of: "swift build -c release") else {
            return XCTFail("build.sh no longer prunes stale resource bundles before building")
        }
        XCTAssertTrue(prune.lowerBound < build.lowerBound,
            "the prune must run BEFORE swift build, or it deletes the bundles this build just made")
    }
}
