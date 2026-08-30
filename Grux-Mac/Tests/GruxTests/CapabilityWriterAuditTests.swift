import XCTest
@testable import Grux

/// Four defects in one day, all the same shape: a readiness check consulting a
/// value that nothing updates.
///
/// The onboarding migration read a Keychain key as proof of completion. The
/// Notifications card read a cache nothing refreshed. The Automation card read a
/// UserDefaults key with NO WRITER ANYWHERE, so it was false forever. The key
/// gate read a status code and threw away the only case that mattered. Every one
/// of them told somebody they were set up, or refused to notice that they were,
/// and every one was invisible until a person hit it by hand on a Mac Mini.
///
/// An audit of all 41 requirements after those fixes came back clean: `key.*`
/// reads the Keychain, `endpoint.*` reads config, seven of nine permissions hit a
/// live system API, and five of ten steps are live probes. Exactly two answers
/// are STORED, which is exactly the surface this file guards. The point is not
/// the audit, which is already spent. The point is that the next requirement
/// somebody adds cannot quietly reintroduce the pattern.
final class CapabilityWriterAuditTests: XCTestCase {

    private func resolverSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/Onboarding/CapabilityResolver.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func codeLines(_ src: String) -> [String] {
        src.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    /// EVERY stored answer must have something that writes it.
    ///
    /// This is the Automation bug stated as a rule. `automationObservedKey` was
    /// read in one place, declared in another, and set in none, and
    /// `UserDefaults.bool` on an unset key is `false`, so the Automation card
    /// could not be satisfied by any action a user could take.
    ///
    /// Comment lines are dropped whole, because the rationale above the read now
    /// discusses the very key it reads and a naive scan would count prose.
    func testEveryStoredCapabilityAnswerHasAWriter() throws {
        let lines = codeLines(try resolverSource())

        // The named constants a read can reference.
        let declared = lines.compactMap { line -> String? in
            guard line.contains("static let"), line.contains("Key = \"") else { return nil }
            return line.split(separator: " ").first { $0.hasSuffix("Key") }.map(String.init)
        }
        XCTAssertFalse(declared.isEmpty, "Found no key constants. The scan is broken.")

        for key in declared {
            let reads = lines.filter { $0.contains("bool(forKey: \(key))") }
            guard !reads.isEmpty else { continue }   // declared but unread is harmless
            let writes = lines.filter {
                $0.contains("UserDefaults.standard.set") && $0.contains("forKey: \(key)")
            }
            XCTAssertFalse(writes.isEmpty,
                           "\(key) is READ as a capability answer and never written. That is "
                            + "the Automation bug exactly: the answer is false forever and no "
                            + "grant a user makes can change it.")
        }
    }

    /// The step family reads and writes through the SAME key derivation.
    ///
    /// Steps do not use a named constant; the key is computed per requirement.
    /// So the guard above cannot see them, and the thing that matters instead is
    /// that `markStepCompleted` writes where `isSatisfied` reads. If those two
    /// ever derived a key differently, every step would read false forever while
    /// the writes landed somewhere nothing consults.
    func testStepsAreWrittenWhereTheyAreRead() throws {
        let src = try resolverSource()
        let lines = codeLines(src)

        let derivations = lines.filter { $0.contains("stepDefaultsKey(for:") }
        XCTAssertGreaterThanOrEqual(
            derivations.count, 2,
            "The step read and the step write no longer share a key derivation, so a step "
                + "can be written to a key nothing reads.")

        // And the reader must actually consult it rather than a literal.
        guard let readIndex = lines.firstIndex(where: { $0.contains("bool(forKey: key)") })
        else { return XCTFail("The generic step read was removed or renamed.") }
        let above = lines[max(0, readIndex - 4)..<readIndex].joined(separator: "\n")
        XCTAssertTrue(above.contains("stepDefaultsKey(for: requirement)"),
                      "The step read no longer derives its key from the requirement.")
    }

    /// Only the answers that genuinely cannot be read live may be stored.
    ///
    /// A ceiling, not a count for its own sake. Notifications is callback-based
    /// and Automation is per-target and would prompt, so both have to be cached;
    /// everything else has a synchronous system API and must use it. A third
    /// stored answer appearing here means somebody cached something that did not
    /// need caching, which is how the first two went stale in the first place.
    func testNothingNewIsAnsweredFromStorage() throws {
        let lines = codeLines(try resolverSource())
        let stored = lines.filter { $0.contains("bool(forKey:") }
            .filter { !$0.contains("forKey: key)") }   // the step family, covered above
            .filter { !$0.contains("previous:") }      // reading its own prior verdict
        XCTAssertEqual(
            stored.count, 2,
            "Expected exactly two stored capability answers, notifications and automation, "
                + "and found \(stored.count): \(stored.map { $0.trimmingCharacters(in: .whitespaces) })")
    }
}
