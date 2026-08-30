import XCTest
@testable import Grux

/// The needs-setup count must not move on its own.
///
/// The sidebar shows "N features need setup" and it read 7 in one run and 8 in
/// another, minutes apart, with no user action in between. A count that changes
/// by itself is worse than no count: it teaches the reader that the number is
/// noise, and the whole point of the registry is that the number is the truth.
///
/// Permissions are resolved LIVE and that is deliberate, so some movement is
/// legitimate: granting Screen Recording in System Settings SHOULD drop the count
/// within a second. What must never happen is the answer changing while nothing
/// changed. These tests separate those two cases.
@MainActor
final class CapabilityStabilityTests: XCTestCase {

    /// Resolving twice in a row, with nothing in between, must agree for every
    /// one of the 40 capabilities. A disagreement here is a resolver that is
    /// reading something racy, cached inconsistently, or timing out.
    func testResolvingTwiceInARowAgrees() {
        var disagreed: [String] = []
        for req in SetupRequirement.allCases {
            let a = CapabilityResolver.isSatisfied(req)
            let b = CapabilityResolver.isSatisfied(req)
            if a != b { disagreed.append("\(req.rawValue): \(a) then \(b)") }
        }
        XCTAssertTrue(disagreed.isEmpty,
                      "a capability answered differently twice in a row with nothing changed "
                      + "in between:\n" + disagreed.joined(separator: "\n"))
    }

    /// Same for the derived count the sidebar actually renders.
    func testTheCountIsStableAcrossRepeatedReads() {
        let counts = (0..<5).map { _ in FeatureRegistry.featuresNeedingSetup.count }
        XCTAssertEqual(Set(counts).count, 1,
                       "the needs-setup count moved across five consecutive reads: \(counts)")
    }

    /// Names the features currently needing setup. Not an assertion about WHICH,
    /// since that is machine specific and rightly so, but it prints the list so a
    /// count that moves between runs can be diffed instead of guessed at. The
    /// assertion is only that the list and the count describe the same thing.
    func testTheListAndTheCountDescribeTheSameSet() {
        let rows = FeatureRegistry.featuresNeedingSetup
        let names = rows.map(\.id).sorted()
        print("NEEDS-SETUP (\(rows.count)): \(names.joined(separator: ", "))")
        for row in rows {
            let missing = FeatureRegistry.missing(forTab: row.id).map(\.rawValue)
            print("    \(row.id) <- \(missing.joined(separator: ", "))")
            XCTAssertFalse(missing.isEmpty,
                           "\(row.id) is counted as needing setup but nothing is missing from it")
        }
        XCTAssertEqual(rows.count, names.count)
    }

    /// A capability with an alternate source is the likeliest thing to flap,
    /// because its answer depends on state outside the Keychain: a file that can
    /// be moved, an environment that differs per process, a server that can stop.
    /// This does not forbid that, it just makes the exposure visible.
    func testAlternateSourcesAgreeWithThemselvesTwiceInARow() {
        for req in SetupRequirement.allCases {
            guard let alt = CapabilityResolver.alternateSource(for: req) else { continue }
            XCTAssertEqual(alt(), alt(), "\(req.rawValue) alternate source is not stable")
        }
    }
}
