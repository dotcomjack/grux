import XCTest
@testable import Grux
@testable import GruxAgentCore

// Backstop + confinement hardening (2026-06-16 incident prevention).
//
// 1. LiveTreeTripwire must match the REAL package source prefix
//    (Grux-Mac/Sources/), not a root-level Sources/ that never exists.
// 2. SwarmWorker.sandboxDecision must never carve a write rule that re-opens a
//    protected live build tree, and must refuse to spawn when the writable
//    root is an ancestor of a protected tree.
final class LiveTreeTripwireTests: XCTestCase {

    // The 2026-06-16 drop signature: a stray file under Grux-Mac/Sources/Grux/
    // is detected; a bare Sources/ path (the old wrong prefix) is not, because
    // the package does not live at the worktree root.
    func testStraySourceDropIsDetected() {
        XCTAssertTrue(LiveTreeTripwire.isSourceDrop("Grux-Mac/Sources/Grux/CognitiveMap/Map.swift"))
        XCTAssertTrue(LiveTreeTripwire.isSourceDrop("Grux-Mac/Sources/"))
        // Old (wrong) prefix and unrelated paths must NOT match.
        XCTAssertFalse(LiveTreeTripwire.isSourceDrop("Sources/Grux/CognitiveMap/Map.swift"))
        XCTAssertFalse(LiveTreeTripwire.isSourceDrop("Grux-Mac/Package.swift"))
        XCTAssertFalse(LiveTreeTripwire.isSourceDrop("README.md"))
    }
}

// Every path in this suite is built under a per-test scratch directory. Nothing
// here describes the layout of the machine running the tests.
//
// That is a correctness requirement, not tidiness. `protectedBuildRoots()` reads
// `GRUX_REPO_ROOT` and returns EMPTY on any normal install, so a test that let
// the default apply would exercise the no-protection path on most machines while
// reading as though it proved the confinement rules. `sandboxDecision` takes
// `protectedRoots` as a parameter for exactly this reason; these tests pass it.
final class SwarmSandboxConfinementTests: XCTestCase {

    private var scratch: String = ""

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("grux-sandbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Resolve once, here. On macOS `/var` is a symlink to `/private/var`, and
        // `sandboxDecision` canonicalises every path it is handed, so an
        // unresolved literal would never match the paths it emits into the
        // profile and the subpath assertions would silently pass by never
        // finding their needle.
        scratch = (base.path as NSString).resolvingSymlinksInPath
    }

    override func tearDownWithError() throws {
        if !scratch.isEmpty {
            try? FileManager.default.removeItem(atPath: scratch)
        }
    }

    // A protected tree that is ALSO sanctioned (it carries a ".worktrees" path
    // segment). Without that, protection would not be the only thing capable of
    // refusing the carve, and every assertion below could pass for the wrong
    // reason: an unsanctioned root is refused whether it is protected or not.
    private var protectedTree: String { scratch + "/.worktrees/live" }

    // A writable root that IS a protected live tree must not be carved, and the
    // emitted profile must NOT contain an ALLOW rule for that tree. It DOES
    // (correctly) appear in the deny block under the deny-last design, so the
    // assertion checks that any occurrence sits after the deny marker, never in
    // the allow carve above it.
    func testProtectedRootIsNotCarved() {
        let d = SwarmWorker.sandboxDecision(writableRoot: protectedTree,
                                            protectedRoots: [protectedTree])
        XCTAssertFalse(d.carved)
        XCTAssertFalse(d.fatalMisconfig)
        let denyMarker = d.profile.range(of: "(deny file-write*")
        XCTAssertNotNil(denyMarker, "profile must have a deny block")
        let occ = d.profile.range(of: "(subpath \"\(protectedTree)\")")
        XCTAssertNotNil(occ, "the protected tree must appear in the profile at all")
        if let occ, let deny = denyMarker {
            XCTAssertTrue(occ.lowerBound >= deny.lowerBound,
                          "live tree may only appear in the deny block, never the allow carve")
        }
    }

    // An ANCESTOR of a protected tree is a fatal misconfig: the worker must
    // refuse to spawn rather than carve the live tree open.
    func testAncestorOfProtectedRootIsFatal() {
        let d = SwarmWorker.sandboxDecision(writableRoot: scratch,
                                            protectedRoots: [protectedTree])
        XCTAssertTrue(d.fatalMisconfig)
        XCTAssertFalse(d.carved)
    }

    // A path INSIDE a protected tree is refused a carve (not fatal, temp only).
    func testInsideProtectedRootIsNotCarved() {
        let inside = protectedTree + "/Sources/Grux"
        let d = SwarmWorker.sandboxDecision(writableRoot: inside,
                                            protectedRoots: [protectedTree])
        XCTAssertFalse(d.carved)
        XCTAssertFalse(d.fatalMisconfig)
    }

    // A repo that is simply not on the sanctioned allowlist is refused a carve,
    // with nothing protected at all. This is the ordinary case for any directory
    // a user points a worker at by mistake.
    func testUnsanctionedRepoIsNotCarved() {
        let d = SwarmWorker.sandboxDecision(writableRoot: scratch + "/some-other-app",
                                            protectedRoots: [])
        XCTAssertFalse(d.carved)
        XCTAssertFalse(d.fatalMisconfig)
    }

    // A legitimate general swarm rootDir under ~/Documents/Grux/swarms carves.
    // This one is deliberately home-relative: that prefix is the product's own
    // published convention (isSanctionedWritableRoot), not a machine's layout.
    func testGeneralSwarmRootIsCarved() {
        let root = NSHomeDirectory() + "/Documents/Grux/swarms/my-swarm-abc123"
        let d = SwarmWorker.sandboxDecision(writableRoot: root, protectedRoots: [])
        XCTAssertTrue(d.carved)
        XCTAssertFalse(d.fatalMisconfig)
    }

    // A legitimate Foundry upgrade worktree carves, and the deny block is
    // emitted AFTER the allow carve so protected roots always win by SBPL
    // last-match-wins. The protected root here is a DIFFERENT tree, which is
    // what makes the ordering meaningful: a carve and a deny both exist.
    func testFoundryWorktreeCarvesAndDenyComesLast() {
        let wt = scratch + "/.worktrees/upgrade-abc123"
        let d = SwarmWorker.sandboxDecision(writableRoot: wt,
                                            protectedRoots: [scratch + "/live"])
        XCTAssertTrue(d.carved)
        let allowIdx = d.profile.range(of: "(allow file-write*")
        let denyIdx = d.profile.range(of: "(deny file-write*")
        XCTAssertNotNil(allowIdx)
        XCTAssertNotNil(denyIdx)
        if let a = allowIdx, let de = denyIdx {
            XCTAssertTrue(a.lowerBound < de.lowerBound,
                          "deny block must follow the allow carve so it wins last-match-wins")
        }
    }

    // With nothing protected, no deny block may be emitted at all. A filterless
    // `(deny file-write*)` is NOT a no-op: measured against sandbox-exec it
    // denies every write except those a filtered allow above it names, which
    // would strip real workers of the cache and npm writes the (allow default)
    // baseline exists to grant them.
    func testNoProtectedRootsEmitsNoDenyBlock() {
        let d = SwarmWorker.sandboxDecision(writableRoot: scratch + "/.worktrees/upgrade-abc123",
                                            protectedRoots: [])
        XCTAssertTrue(d.carved)
        XCTAssertNil(d.profile.range(of: "(deny file-write*"),
                     "an empty protected set must omit the deny block entirely")
    }

    // The shipped default protects nothing unless the operator has said where
    // their source tree is. This is what makes Grux installable by someone who
    // has no checkout at all, and it is the behaviour every test above opts out
    // of by passing protectedRoots explicitly.
    func testDefaultProtectedRootsAreEmptyWithoutTheEnvVar() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["GRUX_REPO_ROOT"]?.isEmpty == false,
                      "GRUX_REPO_ROOT is set in this environment, so the default is legitimately non-empty")
        XCTAssertTrue(SwarmWorker.protectedBuildRoots().isEmpty)
    }
}
