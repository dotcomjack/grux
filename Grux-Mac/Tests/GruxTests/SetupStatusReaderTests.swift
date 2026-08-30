import XCTest
@testable import Grux
import GruxSetupCore

/// EVERY WAY THE CLI CAN FAIL TO ANSWER IS A DESIGNED STATE.
///
/// "Grux has never run" and "your Grux is newer than this binary" need different things from
/// a person, and collapsing them into "could not read file" is how a CLI becomes something
/// you have to already understand before it helps you.
final class SetupStatusReaderTests: XCTestCase {

    private func temp() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("grux-read-\(UUID().uuidString)")
            .appendingPathComponent("setup-status.json")
    }

    private func write(_ raw: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try raw.write(to: url, atomically: true, encoding: .utf8)
    }

    func testAMissingFileIsNeverWrittenNotAnError() {
        let url = temp()
        guard case .failure(let e) = SetupStatusReader.read(from: url) else {
            return XCTFail("a file that does not exist parsed")
        }
        XCTAssertEqual(e, .neverWritten(path: url.path),
            "a fresh install is the EXPECTED state and must not read as corruption")
    }

    func testGarbageIsUnreadableNotEmpty() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try write("{ this is not json", to: url)
        guard case .failure(let e) = SetupStatusReader.read(from: url) else {
            return XCTFail("garbage parsed")
        }
        XCTAssertEqual(e, .unreadable(path: url.path))
    }

    /// A reader must refuse a schema it does not know rather than guess at a shape that
    /// changed under it, which is the whole reason the number is in the document.
    func testAFutureSchemaIsRefusedRatherThanGuessedAt() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let doc = SetupStatus(
            schema: SetupStatus.supportedSchema + 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: "9.9.9", capabilities: [], features: [],
            summary: .init(capabilities: 0, satisfied: 0, selfAttested: 0,
                           featuresReady: 0, featuresNeedingSetup: 0, featuresChosen: 0))
        try write(String(data: try JSONEncoder().encode(doc), encoding: .utf8)!, to: url)

        guard case .failure(let e) = SetupStatusReader.read(from: url) else {
            return XCTFail("a schema from the future was accepted")
        }
        XCTAssertEqual(e, .unsupportedSchema(found: SetupStatus.supportedSchema + 1,
                                             supported: SetupStatus.supportedSchema))
    }

    /// The control: a document this reader DOES understand must come back whole, or every
    /// refusal above proves nothing.
    func testAGoodDocumentRoundTrips() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let doc = SetupStatus(
            schema: SetupStatus.supportedSchema,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: "1.1.0",
            capabilities: [.init(id: "perm.microphone", kind: "perm", label: "Microphone",
                                 satisfied: false, selfAttested: false,
                                 remediation: "Turn it on.")],
            features: [.init(id: "meetings", label: "Meetings", tier: "core",
                             state: "needsSetup", missing: ["perm.microphone"],
                             requires: ["perm.microphone"], optional: [], steps: [],
                             optionalSteps: [], anyOf: [], dependsOn: [])],
            summary: .init(capabilities: 1, satisfied: 0, selfAttested: 0,
                           featuresReady: 0, featuresNeedingSetup: 1, featuresChosen: 1))
        try write(String(data: try JSONEncoder().encode(doc), encoding: .utf8)!, to: url)

        guard case .success(let read) = SetupStatusReader.read(from: url) else {
            return XCTFail("a valid document was refused")
        }
        XCTAssertEqual(read, doc, "the document changed shape crossing the file")
    }

    /// A document written by another process can be old, and a person asking what Grux needs
    /// after installing something wants to know if this predates that.
    func testAgeIsReadableAndAnUnparseableStampIsNil() {
        let base = SetupStatus(schema: 1, generatedAt: "", appVersion: "1.1.0",
                               capabilities: [], features: [],
                               summary: .init(capabilities: 0, satisfied: 0, selfAttested: 0,
                                              featuresReady: 0, featuresNeedingSetup: 0,
                                              featuresChosen: 0))
        var fresh = base
        let now = Date()
        fresh.generatedAt = ISO8601DateFormatter().string(from: now.addingTimeInterval(-600))
        let age = SetupStatusReader.age(of: fresh, now: now)
        XCTAssertNotNil(age)
        XCTAssertEqual(age ?? 0, 600, accuracy: 2)

        var broken = base
        broken.generatedAt = "yesterday-ish"
        XCTAssertNil(SetupStatusReader.age(of: broken),
                     "an unparseable stamp must be nil so the caller can say so, not zero")
    }

    /// The app writes this document and the CLI reads it. If the two types ever diverge the
    /// CLI silently loses fields, so the app's writer is decoded through the CLI's type.
    @MainActor
    func testTheAppsWriterAndTheCLIsReaderAgreeOnTheShape() throws {
        let url = temp()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(SetupStatusFile.write(to: url), "the app's writer failed")

        guard case .success(let read) = SetupStatusReader.read(from: url) else {
            return XCTFail("the CLI could not read what the app just wrote")
        }
        XCTAssertEqual(read.capabilities.count, SetupRequirement.allCases.count)
        XCTAssertEqual(read.features.count, FeatureRegistry.rows.count)
        XCTAssertEqual(read.summary.selfAttested,
                       CapabilityResolver.selfAttestedSteps.count,
                       "the self_attested count did not survive the crossing")
    }
}
