import XCTest
@testable import Grux

/// THE FILE EVERY AGENT HANDOFF POINTS AT, SO IT HAS TO BE TRUE.
///
/// Each handoff Grux emits ends with a VERIFY section naming `grux status`. If this
/// document can be stale, partial, or quietly missing an id, then every one of those
/// sections is an instruction to check something that cannot be checked.
///
/// `mic-status.json` is the same pattern and already paid for both failure modes: it
/// reported the state from before the change that produced it, and it truncated on write so
/// a poller could read a half-written file. Both have a regression test here, driven against
/// a temporary file rather than the real one.
@MainActor
final class SetupStatusFileTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-status-\(UUID().uuidString)")
            .appendingPathComponent("setup-status.json")
    }

    private func read(_ url: URL) throws -> SetupStatusFile.Status {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SetupStatusFile.Status.self, from: data)
    }

    // MARK: - Completeness

    /// Every contract id appears, and the set is compared against `allCases` rather than a
    /// number. A count would pass while an id was swapped for another, and a consumer
    /// looking up an id it was told about would get nothing back with no error anywhere.
    func testEveryCapabilityIdIsPresentExactlyOnce() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(SetupStatusFile.write(to: url), "the write itself failed")

        let status = try read(url)
        let emitted = status.capabilities.map(\.id)
        let expected = SetupRequirement.allCases.map(\.rawValue)

        XCTAssertEqual(Set(emitted), Set(expected),
            "missing: \(Set(expected).subtracting(emitted).sorted()), "
            + "unexpected: \(Set(emitted).subtracting(expected).sorted())")
        XCTAssertEqual(emitted.count, Set(emitted).count, "an id was emitted twice")
        XCTAssertEqual(status.summary.capabilities, expected.count)
    }

    func testEveryFeatureIsPresentWithItsState() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        SetupStatusFile.write(to: url)
        let status = try read(url)

        XCTAssertEqual(Set(status.features.map(\.id)), Set(FeatureRegistry.rows.map(\.id)))
        let known = Set([FeatureState.ready, .needsSetup, .degraded, .unavailable,
                         .notChosen].map(\.rawValue))
        for f in status.features {
            XCTAssertTrue(known.contains(f.state), "\(f.id) has state \(f.state), not a contract state")
        }
        let speakers = status.features.first { $0.id == "speakers" }
        XCTAssertEqual(speakers?.dependsOn, ["meetings"],
                       "CR-35's dependency did not reach the machine surface")
    }

    /// The schema is what lets a consumer refuse a document it does not understand instead
    /// of guessing at a shape that changed under it.
    func testTheDocumentDeclaresItsSchemaAndWhenItWasWritten() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        SetupStatusFile.write(to: url)
        let status = try read(url)

        XCTAssertEqual(status.schema, SetupStatusFile.schemaVersion)
        XCTAssertFalse(status.generatedAt.isEmpty)
        XCTAssertNotNil(ISO8601DateFormatter().date(from: status.generatedAt),
                        "generatedAt is not parseable, so a reader cannot tell how old this is")
    }

    // MARK: - Honesty

    /// `self_attested` marks the answers nobody measured. It must be true for exactly the
    /// six steps that are somebody's word, and false for every key, permission and endpoint,
    /// which are all read from the machine. Getting this backwards in either direction is
    /// what makes a VERIFY section imply a check that never ran.
    func testSelfAttestedIsTrueForExactlyTheSixAndNothingElse() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        SetupStatusFile.write(to: url)
        let status = try read(url)

        let flagged = Set(status.capabilities.filter(\.selfAttested).map(\.id))
        let expected = Set(CapabilityResolver.selfAttestedSteps.map(\.rawValue))
        XCTAssertEqual(flagged, expected,
            "self_attested marks \(flagged.sorted()) but the resolver names \(expected.sorted())")
        XCTAssertEqual(flagged.count, 6)

        for cap in status.capabilities where cap.kind != "step" {
            XCTAssertFalse(cap.selfAttested,
                "\(cap.id) is a \(cap.kind) and every one of those is read from the machine")
        }
        for detected in CapabilityResolver.detectedSteps {
            XCTAssertFalse(flagged.contains(detected.rawValue),
                "\(detected.rawValue) is detected, so calling it self-attested understates it")
        }
    }

    /// A remediation on something already satisfied is noise a consumer has to know to
    /// ignore, and an absent one on something missing leaves an agent with no next action.
    func testRemediationAppearsOnlyWhereThereIsSomethingToDo() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        SetupStatusFile.write(to: url)
        let status = try read(url)

        for cap in status.capabilities {
            if cap.satisfied {
                XCTAssertNil(cap.remediation, "\(cap.id) is satisfied and still carries a remediation")
            } else {
                XCTAssertFalse(cap.remediation?.isEmpty ?? true,
                    "\(cap.id) is missing and offers no next action")
            }
        }
        XCTAssertEqual(status.summary.satisfied,
                       status.capabilities.filter(\.satisfied).count,
                       "the summary disagrees with the rows it summarises")
    }

    // MARK: - The two failure modes mic-status.json already paid for

    /// FAILURE MODE ONE: reporting the state from before the change.
    ///
    /// `mute()` and `unmute()` finish their real work in a detached task and the file was
    /// written the instant they returned, so a successful mute reported a live capture.
    /// `writeAfter` exists so a caller cannot make that mistake. This drives it with work
    /// that genuinely completes late and requires the document to describe the state
    /// afterwards, then proves the naive ordering would have failed by writing first.
    func testWriteAfterDescribesTheStateAfterTheWorkNotBefore() async throws {
        let step = SetupRequirement.stepYoutubeTranscriptsEnabled
        guard let key = CapabilityResolver.stepDefaultsKey(for: step) else {
            return XCTFail("no defaults key for \(step.rawValue)")
        }
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // The control: writing BEFORE the work sees the old answer. This is the bug.
        UserDefaults.standard.set(false, forKey: key)
        SetupStatusFile.write(to: url)
        let naive = try read(url).capabilities.first { $0.id == step.rawValue }
        XCTAssertEqual(naive?.satisfied, false, "control: expected the pre-change answer")

        // The fix: the write happens after the work has finished, however late that is.
        UserDefaults.standard.set(false, forKey: key)
        await SetupStatusFile.writeAfter(to: url) {
            try? await Task.sleep(nanoseconds: 60_000_000)
            UserDefaults.standard.set(true, forKey: key)
        }
        let after = try read(url).capabilities.first { $0.id == step.rawValue }
        XCTAssertEqual(after?.satisfied, true, """
            the document describes the state from before the work it was asked to describe,
            which is exactly the bug mic-status.json shipped with for weeks
            """)
    }

    /// FAILURE MODE TWO: truncating on write.
    ///
    /// A plain write empties the file first, so a reader polling in a loop can land in the
    /// gap and parse nothing. A caller polling this file is the intended use, so this races
    /// repeated writes against repeated reads and requires every read that finds a file to
    /// find a WHOLE one. A zero-byte or half-written document must never be observable.
    func testAReaderNeverSeesAPartialDocument() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        SetupStatusFile.write(to: url)

        let expected = SetupRequirement.allCases.count
        var reads = 0
        var partials = 0

        let writer = Task { @MainActor in
            for _ in 0..<40 { SetupStatusFile.write(to: url) }
        }
        for _ in 0..<400 {
            guard let data = try? Data(contentsOf: url) else { continue }
            reads += 1
            guard let decoded = try? JSONDecoder().decode(SetupStatusFile.Status.self, from: data),
                  decoded.capabilities.count == expected else {
                partials += 1
                continue
            }
        }
        await writer.value

        XCTAssertGreaterThan(reads, 50, "control: too few reads landed to prove anything")
        XCTAssertEqual(partials, 0,
            "\(partials) of \(reads) reads saw a truncated or half-written document, which is "
            + "the bug .atomic is there to prevent")
    }

    /// A PROCESS THAT IS NOT GRUX MAY NOT WRITE THE REAL FILE.
    ///
    /// Found by reading the artifact rather than by reasoning about it.
    /// `markStepCompleted` refreshes the status file and tests call it, so a `swift test`
    /// run wrote 16 KB into the operator's real `~/.grux/setup-status.json`, and the
    /// document it wrote said `"appVersion": "16.0"`, the xctest runner's version, because
    /// `Bundle.main` is the test host. A status file is the one document that must not be
    /// written by something that cannot answer for its contents.
    func testOnlyTheAppMayWriteTheRealFile() {
        XCTAssertFalse(SetupStatusFile.isRunningAsTheApp,
                       "control: this test process should not be Grux.app")
        XCTAssertFalse(SetupStatusFile.write(),
                       "a test process wrote the operator's real status file")

        // and it still writes wherever it is explicitly pointed
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(SetupStatusFile.write(to: url),
                      "the guard blocked an explicitly targeted write, which nothing asked for")
    }

    /// The version is a claim about which code produced this document, so a process that
    /// cannot make that claim must say so rather than reporting its host's version.
    func testAVersionItCannotVouchForIsNotReported() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        SetupStatusFile.write(to: url)
        let status = try? read(url)
        XCTAssertEqual(status?.appVersion, "not-the-app",
            "outside the app this reported \(status?.appVersion ?? "nil"), which is whatever "
            + "happened to be hosting the code")
    }

    /// The file lands where the rest of the machine interface already lives, beside the
    /// triggers and mic-status.json. A consumer should learn one directory, not two.
    func testItLivesBesideTheRestOfTheMachineInterface() {
        XCTAssertEqual(SetupStatusFile.url.lastPathComponent, "setup-status.json")
        XCTAssertEqual(SetupStatusFile.url.deletingLastPathComponent().lastPathComponent, ".grux")
    }
}

/// A Mac that has never run Grux gets a status file before anything can block.
///
/// Measured on a Mac Mini that had never had Grux installed: the app launched, logged three
/// lines, and stopped. `~/.grux/setup-status.json` was still absent four minutes later and
/// the fire-setup-status trigger produced nothing either, so every read in the CLI answered
/// "Grux has not written its setup status yet, open Grux once and run this again" to
/// somebody who had just done exactly that. Permanently.
///
/// `KeychainServiceMigrator.runOnce()` enumerates Keychain items, which needs the login
/// keychain unlocked, and macOS raised a modal naming `grux-vault`, one of the service
/// strings in that migrator's own rename table. On a Mac whose account password was ever
/// reset through an Apple ID the login keychain keeps the OLD password, so the dialog cannot
/// be answered and launch never gets past it.
///
/// This is a source scan because the thing being asserted is an ORDER inside a launch
/// sequence that cannot be run in a test host.
final class LaunchWritesStatusBeforeAnythingBlockingTests: XCTestCase {

    private func appSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Grux/GruxApp.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheFirstContactWriteComesBeforeTheKeychainMigration() throws {
        let source = try appSource()

        // ANCHORED ON THE REAL CALL SITE, NOT THE FIRST MATCH. `KeychainServiceMigrator`
        // is called twice in this file, and the earlier one is inside the `if isSmokeTest`
        // branch, which is the very branch a launch write hid in once before. Matching the
        // first occurrence compared the fix against a code path a normal launch never takes.
        guard let migrateComment = source.range(
            of: "// Move any Keychain items still filed under a previous service name.") else {
            return XCTFail("the normal launch keychain migration is gone, or its comment "
                + "moved, so this scan is not looking at the launch path any more")
        }
        guard let migrate = source.range(of: "KeychainServiceMigrator.runOnce()",
                                         range: migrateComment.upperBound..<source.endIndex)
        else {
            return XCTFail("the keychain migration is gone from launch, so this proves nothing")
        }
        guard let guarded = source.range(
            of: "if !FileManager.default.fileExists(atPath: SetupStatusFile.url.path) {") else {
            return XCTFail("launch no longer writes a status file before the migration. A Mac "
                + "that has never run Grux gets no setup document at all if anything between "
                + "here and the later write raises a modal, and every CLI read then tells the "
                + "owner to open Grux, which they have already done.")
        }
        XCTAssertLessThan(guarded.lowerBound, migrate.lowerBound,
            "the first contact write moved BELOW the keychain migration, which is the "
            + "ordering that made a fresh Mac unusable from the terminal")

        // The write itself has to be inside that guard, not merely near it.
        let after = source[guarded.upperBound...]
        let closeAt = after.range(of: "}")?.lowerBound ?? after.endIndex
        XCTAssertTrue(after[after.startIndex..<closeAt].contains("SetupStatusFile.write()"),
            "the guard is there and writes nothing")
    }

    /// And the ORIGINAL ordering is still honoured for a machine that has run before, which
    /// is what stops this fix publishing a stale document on an upgrade: the unconditional
    /// write still sits after both migrators.
    func testTheAccurateWriteStillFollowsBothMigrators() throws {
        let source = try appSource()
        // Same anchor, same reason: the smoke test branch calls both of these too.
        guard let comment = source.range(
                of: "// Move any Keychain items still filed under a previous service name."),
              let service = source.range(of: "KeychainServiceMigrator.runOnce()",
                                         range: comment.upperBound..<source.endIndex),
              let legacy = source.range(of: "KeychainMigrator.runOnce()",
                                        range: service.upperBound..<source.endIndex) else {
            return XCTFail("a migrator is missing from the launch path, so this proves nothing")
        }
        // The write that is NOT inside the first contact guard.
        let tail = source[legacy.upperBound...]
        guard let accurate = tail.range(of: "SetupStatusFile.write()") else {
            return XCTFail("nothing writes the status after the migrators any more, so an "
                + "upgrading Mac keeps whatever the first contact write guessed")
        }
        XCTAssertLessThan(service.lowerBound, legacy.lowerBound,
            "the service migrator must run before the legacy one")
        XCTAssertLessThan(legacy.upperBound, accurate.lowerBound)
    }
}
